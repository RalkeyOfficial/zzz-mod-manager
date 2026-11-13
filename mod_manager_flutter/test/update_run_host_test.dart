import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_file.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_mod.dart';
import 'package:mod_manager_flutter/models/install_result.dart';
import 'package:mod_manager_flutter/models/mod_download.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/screens/components/download_queue_host.dart';
import 'package:mod_manager_flutter/screens/components/downloads_panel.dart';
import 'package:mod_manager_flutter/screens/components/question_parts.dart';
import 'package:mod_manager_flutter/screens/components/update_run_words.dart';
import 'package:mod_manager_flutter/screens/dialogs/install_archive_flow.dart';
import 'package:mod_manager_flutter/services/download/download_handle.dart';
import 'package:mod_manager_flutter/services/download/download_job.dart';
import 'package:mod_manager_flutter/services/download/download_queue.dart';
import 'package:mod_manager_flutter/services/download/download_request.dart';
import 'package:mod_manager_flutter/services/download/queue_policy.dart';
import 'package:mod_manager_flutter/services/download/update_job.dart';
import 'package:mod_manager_flutter/services/log/log_sinks.dart';
import 'package:mod_manager_flutter/services/log/logger.dart';
import 'package:mod_manager_flutter/services/update_apply/update_applier.dart' show UpdateWriteStep;
import 'package:mod_manager_flutter/services/update_apply/update_layout.dart';
import 'package:mod_manager_flutter/services/update_apply/update_prepare.dart';
import 'package:mod_manager_flutter/services/update_apply/update_run_stages.dart';
import 'package:mod_manager_flutter/services/update_check.dart';
import 'package:mod_manager_flutter/services/writes_in_flight.dart';
import 'package:mod_manager_flutter/utils/notifications.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart' show downloadsPanelRequestProvider, modUpdateChecksProvider;

import 'support/held_write.dart';
import 'support/library_override.dart';
import 'support/localized_harness.dart';
import 'support/log_capture.dart';
import 'support/origin_shorthand.dart';
import 'support/recording_service.dart';
import 'support/seeded_queue.dart';
import 'support/temp_library.dart';
import 'support/update_jobs.dart';

/// `DownloadQueueHost`'s update drain, through the stage seam:
/// the order of the unpack and install lanes, one unpack with one waiting, one write on the chain shared with Browse installs,
/// a question leaving the lanes, the halt and Continue, Cancel all, the per-folder pipeline, the skip of a folder written elsewhere, and the closing gate.
/// No 7-Zip, mods folder or network: the stages are the test's.
void main() {
  late _Stages stages;
  late List<int> installed;

  /// While set, a Browse install ends when it completes.
  Completer<void>? installing;

  /// While set, the patch window's library ranking ends when it completes.
  Completer<void>? ranking;

  /// The hold of each ranking by the order it was started in, in place of [ranking]; null holds nothing.
  var rankings = <Completer<void>?>[];

  /// How many rankings were started.
  var rankCalls = 0;

  /// While set, a ranking throws.
  var rankingThrows = false;

  setUp(() {
    stages = _Stages();
    installed = [];
    installing = null;
    ranking = null;
    rankings = [];
    rankCalls = 0;
    rankingThrows = false;
  });
  tearDown(WritesInFlight.shared.reopenForTests);

  ProviderContainer seeded(List<DownloadJob> jobs, {List<ModInfo> library = const []}) {
    final container = ProviderContainer(
      overrides: [downloadQueueProvider.overrideWith(() => SeededQueue(jobs)), libraryOf(library)],
    );
    addTearDown(container.dispose);
    container.read(downloadQueueProvider);
    return container;
  }

  Future<void> frames(WidgetTester t) async {
    for (var i = 0; i < 5; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> host(WidgetTester t, ProviderContainer container) async {
    await pumpLocalized(
      t,
      DownloadQueueHost(
        installer: (context, ref, job) async {
          installed.add(job.seq);
          await installing?.future;
          return InstallEnds(InstallResult.success(['Mod ${job.seq}']));
        },
        asker: (context, ref, job) async => fail('nothing asks in this test'),
        updatePreparer: stages.prepare,
        updateWriter: stages.write,
        patchQuestioner: (container, job, mod, pick, finding) async {
          final call = rankCalls++;
          if (rankingThrows) throw StateError('the library could not be ranked');
          await (call < rankings.length ? rankings[call] : ranking)?.future;
          return updatePatchQuestion(container, job, mod, pick, finding);
        },
        child: const SizedBox.shrink(),
      ),
      container: container,
      settle: false,
    );
    await frames(t);
  }

  DownloadJob jobOf(ProviderContainer container, int seq) =>
      container.read(downloadQueueProvider).firstWhere((j) => j.seq == seq);

  DownloadJob landed(int seq, int sizeMb, {List<UpdateMod>? mods}) =>
      updateJob(seq, state: DownloadJobState.downloaded, size: sizeMb * mb, mods: mods);

  testWidgets('one unpack at a time with one waiting, and one write at a time', (t) async {
    final container = seeded([landed(1, 10), landed(2, 20), landed(3, 30)]);
    await host(t, container);
    expect(stages.prepared, [1]);

    stages.ready(1);
    await frames(t);
    expect(stages.written, [1]);
    expect(stages.prepared, [1, 2], reason: 'the next is unpacked while the first is written');

    stages.ready(2);
    await frames(t);
    expect(stages.prepared, [1, 2], reason: 'one unpacked archive waits, so no third unpack');
    expect(jobOf(container, 2).updateStep, UpdateStep.unpacked);

    stages.wrote(1);
    await frames(t);
    expect(jobOf(container, 1).outcome, JobOutcome.updated);
    expect(stages.written, [1, 2]);
    expect(stages.prepared, [1, 2, 3]);

    stages.ready(3);
    stages.wrote(2);
    await frames(t);
    stages.wrote(3);
    await frames(t);
    expect([for (final j in container.read(downloadQueueProvider)) j.outcome], everyElement(JobOutcome.updated));
  });

  testWidgets('the smaller landed file is unpacked first', (t) async {
    final container = seeded([landed(1, 300), landed(2, 20)]);
    await host(t, container);
    expect(stages.prepared, [2]);
  });

  testWidgets('an update write and a Browse install share one chain', (t) async {
    final container = seeded([landed(1, 10), _browse(2), _browse(3)]);
    installing = Completer<void>();
    await host(t, container);
    expect(installed, [2], reason: 'the install takes the chain while the update unpacks');
    stages.ready(1);
    await frames(t);
    expect(stages.written, isEmpty, reason: 'the write waits for the install');

    installing!.complete();
    installing = Completer<void>();
    await frames(t);
    expect(stages.written, [1], reason: 'asked for before the second install');
    expect(installed, [2]);

    stages.wrote(1);
    await frames(t);
    expect(installed, [2, 3]);
    installing!.complete();
    await frames(t);
    // Each install's result is a Done card, which closes on its own timer.
    await t.pump(const Duration(seconds: 6));
  });

  testWidgets('a question leaves the lanes, keeps its place, and its answer goes ahead of the jobs that have not waited',
      (t) async {
    final container = seeded([landed(1, 10), landed(2, 20), landed(3, 30)]);
    await host(t, container);
    stages.asks(1, UpdateQuestionKind.folders);
    await frames(t);
    expect(jobOf(container, 1).state, DownloadJobState.waiting);
    expect(isAheadOfInstall(jobOf(container, 1)), isTrue, reason: 'it keeps its place under the lookahead');
    expect(stages.prepared, [1, 2], reason: 'the unpack lane goes on without it');

    container
        .read(downloadQueueProvider.notifier)
        .answerUpdate(1, asking: jobOf(container, 1).updateWait!.asking, prepared: 'picked');
    stages.ready(2);
    await frames(t);
    expect(stages.written, [2]);
    expect(stages.prepared, [1, 2, 1], reason: 'the answered job before job 3');
    expect(stages.preparedWith.last, 'picked');
  });

  testWidgets('a question found at the write leaves the install lane, and the next write goes on', (t) async {
    final container = seeded([landed(1, 10), landed(2, 20)]);
    await host(t, container);
    stages.ready(1);
    await frames(t);
    stages.ready(2);
    await frames(t);
    stages.writeAsks(1, UpdateQuestionKind.unrecordedPatch);
    await frames(t);
    expect(jobOf(container, 1).state, DownloadJobState.waiting);
    expect(jobOf(container, 1).updateWait?.question, UpdateQuestionKind.unrecordedPatch);
    expect(stages.written, [1, 2]);
  });

  testWidgets('a failure every later job shares halts the run until Continue', (t) async {
    final container = seeded([landed(1, 10), landed(2, 20), landed(3, 30)]);
    await host(t, container);
    stages.ready(1);
    await frames(t);
    stages.ready(2);
    await frames(t);

    stages.writeFails(1, const UpdateFailure(UpdateFailureKind.noSpace, requiredBytes: 2, availableBytes: 1));
    await frames(t);
    expect(jobOf(container, 1).state, DownloadJobState.failed);
    expect(stages.written, [1], reason: 'the unpacked job is not written');
    expect(stages.prepared, [1, 2], reason: 'and nothing more is unpacked');
    expect(jobOf(container, 3).halt?.bySeq, 1);

    container.read(downloadQueueProvider.notifier).continueUpdates();
    await frames(t);
    expect(stages.written, [1, 2]);
    expect(stages.prepared, [1, 2, 3]);
  });

  testWidgets('a write that throws halts the run, since how far it got is not known', (t) async {
    final container = seeded([landed(1, 10), landed(2, 20)]);
    await host(t, container);
    stages.ready(1);
    await frames(t);
    stages.writeThrows(1);
    await frames(t);
    expect((jobOf(container, 1).error as UpdateFailure?)?.kind, UpdateFailureKind.writeInterrupted);
    expect(jobOf(container, 2).halt?.bySeq, 1);
  });

  testWidgets("a failure of one mod's own does not stop the others", (t) async {
    final container = seeded([landed(1, 10), landed(2, 20)]);
    await host(t, container);
    stages.prepareFails(1, const UpdateFailure(UpdateFailureKind.unpackFailed));
    await frames(t);
    expect(jobOf(container, 1).state, DownloadJobState.failed);
    expect(stages.prepared, [1, 2]);
    expect(jobOf(container, 2).halt, isNull);
  });

  group('Cancel all', () {
    testWidgets('takes every job that can stop off at once, and the host claims none of them on the way',
        (t) async {
      final container = seeded([
        _browse(1, state: DownloadJobState.installing),
        updateJob(3, state: DownloadJobState.updating, step: UpdateStep.unpacked),
        landed(4, 10),
      ]);
      await host(t, container);
      expect(stages.prepared, isEmpty, reason: 'one unpacked archive already waits');

      await t.runAsync(() => container.read(downloadQueueProvider.notifier).cancelAllUpdates());
      await frames(t);
      expect(stages.prepared, isEmpty, reason: 'the landed job left with the others and was never unpacked');
      expect([for (final j in container.read(downloadQueueProvider)) j.seq], [1]);
    });

    testWidgets('during a halt: the unpack in flight is deleted when it lands, and the halt ends', (t) async {
      final container = seeded([landed(1, 10), landed(2, 20), landed(3, 30)]);
      await host(t, container);
      stages.ready(1);
      await frames(t);
      expect(stages.prepared, [1, 2]);
      stages.writeFails(1, const UpdateFailure(UpdateFailureKind.noSpace));
      await frames(t);
      expect(container.read(updateRunSummaryProvider).halt, isNotNull);

      await t.runAsync(() => container.read(downloadQueueProvider.notifier).cancelAllUpdates());
      await frames(t);
      expect(container.read(updateRunSummaryProvider).halt, isNull, reason: 'Cancel all ends the halt');

      stages.ready(2);
      await frames(t);
      expect(stages.written, [1], reason: 'the unpack that landed after Cancel all is not written');
      expect([for (final j in container.read(downloadQueueProvider)) j.seq], [1]);
    });
  });

  testWidgets('a folder has one write pipeline: its second job waits for the first to end', (t) async {
    final container = seeded([
      landed(1, 200, mods: [baseOf('Ellen', 1)]),
      landed(2, 5, mods: [patchOf('Ellen', 2)]),
    ]);
    await host(t, container);
    expect(stages.prepared, [1], reason: 'the smaller patch waits for the base');
    stages.ready(1);
    await frames(t);
    expect(stages.prepared, [1]);
    stages.wrote(1);
    await frames(t);
    expect(stages.prepared, [1, 2]);
  });

  testWidgets('a folder being written elsewhere is skipped at its write, not waited for', (t) async {
    final container = seeded([
      landed(1, 10),
      landed(2, 20, mods: [baseOf('Ellen', 2), baseOf('Ellen Alt', 3)]),
    ]);
    final restores = [holdWrite(container, 'mod1'), holdWrite(container, 'Ellen Alt')];
    await host(t, container);
    stages.ready(1);
    await frames(t);
    expect(jobOf(container, 1).outcome, JobOutcome.skipped);
    expect(jobOf(container, 1).skipReason, UpdateSkipReason.beingWritten);
    expect(stages.written, isEmpty, reason: 'nothing is written into it');

    stages.ready(2);
    await frames(t);
    expect(stages.written, [2], reason: 'a shared archive is one write, of the folders that are free');
    expect(stages.skips[2], {'Ellen Alt'});
    for (final restore in restores) {
      await t.runAsync(restore.release);
    }
  });

  testWidgets('once the app is closing, nothing is unpacked and nothing starts its write', (t) async {
    final container = seeded([landed(1, 10), _browse(2)]);
    WritesInFlight.shared.close();
    await host(t, container);
    expect(stages.prepared, isEmpty);
    expect(installed, isEmpty);
  });

  group('the cards (docs/update-runs.md §5)', () {
    List<AppNotification> deck(ProviderContainer container) =>
        [for (final n in cards(container)) if (n.deck?.key == kUpdatesDeck && n.kind == NotificationKind.working) n];

    testWidgets('the jobs at work are one deck whose front card is the one furthest along', (t) async {
      final container = seeded([landed(1, 30), landed(2, 10)]);
      await host(t, container);
      expect(deck(container), hasLength(2));
      expect(deck(container).first.title, 'Updating mod 2', reason: 'the smaller file is unpacked first');
      expect(deck(container).first.body, 'Unpacking');
      expect(find.text('1 more updating'), findsOneWidget);

      stages.ready(2);
      await frames(t);
      container.read(downloadQueueProvider.notifier).reportWriteStep(
            2,
            const UpdateWriting('mod2', UpdateWriteStep.replacingFiles),
          );
      await frames(t);
      expect(deck(container).first.title, 'Updating mod 2');
      expect(deck(container).first.body, 'Installing · replacing the files');
      expect(deck(container).first.progress, isNull, reason: 'the write is a sweep, not a share');

      stages.wrote(2);
      await frames(t);
      expect(deck(container).single.title, 'Updating mod 1', reason: 'a job leaves the deck when it ends');
      await t.pump(const Duration(seconds: 6));
    });

    testWidgets("a run longer than the stack's backstop keeps every card of its deck, and its Done card", (t) async {
      const jobs = kKeptNotifications + 5;
      final container = seeded([for (var i = 1; i <= jobs; i++) landed(i, i)]);
      await host(t, container);
      expect(deck(container), hasLength(jobs), reason: 'none is dropped by the cap');
      expect(deck(container).first.title, 'Updating mod 1', reason: 'the front card still reads its job');
      expect(deck(container).first.body, 'Unpacking');
      expect(find.text('${jobs - 1} more updating'), findsOneWidget);

      stages.ready(1);
      await frames(t);
      stages.wrote(1);
      await frames(t);
      expect(cards(container).singleWhere((n) => n.kind == NotificationKind.done).title, 'mod 1 updated');
      expect(deck(container), hasLength(jobs - 1));
      expect(deck(container).first.title, 'Updating mod 2');
      await t.pump(const Duration(seconds: 6));
    });

    testWidgets('finished updates are counted on one card with Show, and each failure has its own', (t) async {
      final container = seeded([landed(1, 10), landed(2, 20), landed(3, 30)]);
      await host(t, container);
      stages.ready(1);
      await frames(t);
      stages.wrote(1);
      await frames(t);
      final done = cards(container).singleWhere((n) => n.kind == NotificationKind.done);
      expect(done.title, 'mod 1 updated');
      expect(done.body, 'The old file is kept as a snapshot.');
      expect(done.actions.single.label, 'Show');

      stages.ready(2);
      await frames(t);
      stages.prepareFails(3, const UpdateFailure(UpdateFailureKind.nothingToInstall));
      await frames(t);
      stages.wrote(2);
      await frames(t);

      final counted = cards(container).singleWhere((n) => n.kind == NotificationKind.done);
      expect(counted.title, '2 mods updated');
      expect(counted.subjects, ['mod 1', 'mod 2']);
      expect(counted.count, 2);
      expect([for (final a in counted.actions) a.label], ['Show'], reason: 'Show is about the list, so it stays');
      final failure = cards(container).singleWhere((n) => n.kind == NotificationKind.error);
      expect(failure.title, "Couldn't update mod 3");
      expect(failure.body, 'The file has no mod folder in it. Nothing was changed.');
      expect(jobOf(container, 2).outcome, JobOutcome.updated, reason: "one mod's failure leaves the others running");
      await t.pump(const Duration(seconds: 6));
    });

    testWidgets('a file put on top of its mod as a patch is told as a patch added, not as an update', (t) async {
      final container = seeded([landed(1, 10), landed(2, 20), landed(3, 30)]);
      await host(t, container);
      for (final seq in [1, 2]) {
        stages.ready(seq);
        await frames(t);
        stages.writes(
          seq,
          UpdateStageWritten(JobOutcome.patchAdded,
              results: [UpdateModResult.written(baseOf('mod$seq', seq), patchedInto: 'mod$seq')]),
        );
        await frames(t);
      }
      stages.ready(3);
      await frames(t);
      stages.wrote(3);
      await frames(t);

      final done = [for (final n in cards(container)) if (n.kind == NotificationKind.done) n];
      expect(done, hasLength(2), reason: 'a patch added and an update are counted apart');
      final patched = done.singleWhere((n) => n.subjects.contains('mod 1'));
      expect(patched.title, 'Patch added to 2 mods');
      expect(patched.subjects, ['mod 1', 'mod 2']);
      expect([for (final a in patched.actions) a.label], ['Show']);
      expect(done.where((n) => n.title == 'mod 3 updated'), hasLength(1),
          reason: 'only the mod whose file was replaced reads as updated');
      await t.pump(const Duration(seconds: 6));
    });

    testWidgets('a single patch added says where it went and how to take it out', (t) async {
      final container = seeded([landed(1, 10)]);
      await host(t, container);
      stages.ready(1);
      await frames(t);
      stages.writes(
        1,
        UpdateStageWritten(JobOutcome.patchAdded, results: [UpdateModResult.written(baseOf('mod1', 1), patchedInto: 'mod1')]),
      );
      await frames(t);
      final done = cards(container).singleWhere((n) => n.kind == NotificationKind.done);
      expect(done.title, 'Patch added to mod 1');
      expect(done.body, 'Your files stay, and you can take the patch out again from History.');
      await t.pump(const Duration(seconds: 6));
    });

    testWidgets('each mod that failed has its card: a refused one of a written job, and every mod of a failed transfer',
        (t) async {
      const rina = UpdateMod(modId: 'Rina', layer: DownloadKey.base(9));
      final container = seeded([
        landed(1, 10, mods: [baseOf('mod1', 1), rina]),
        updateJob(2, state: DownloadJobState.running, mods: [baseOf('mod2', 2), baseOf('Nicole', 2)]),
      ]);
      await host(t, container);
      stages.ready(1);
      await frames(t);
      stages.writes(
        1,
        UpdateStageWritten(JobOutcome.updated, results: [
          UpdateModResult.written(baseOf('mod1', 1)),
          const UpdateModResult(rina, UpdateModEnd.refused, failure: UpdateFailure(UpdateFailureKind.refused)),
        ]),
      );
      await frames(t);
      (container.read(downloadQueueProvider.notifier) as SeededQueue).put(2, DownloadJobState.failed);
      await frames(t);

      final failures = [for (final n in cards(container)) if (n.kind == NotificationKind.error) n.title];
      expect(failures, unorderedEquals(["Couldn't update Rina", "Couldn't update mod 2", "Couldn't update Nicole"]));
      await t.pump(const Duration(seconds: 6));
    });

    testWidgets('a job the halt holds after it landed says Stopped on its card, with no sweep', (t) async {
      const halt = UpdateHalt(cause: UpdateFailure(UpdateFailureKind.snapshotFailed), bySeq: 9);
      final container = seeded([
        updateJob(1, state: DownloadJobState.downloaded, halt: halt),
        updateJob(2, state: DownloadJobState.updating, step: UpdateStep.unpacked, halt: halt),
      ]);
      await host(t, container);
      expect(stages.prepared, isEmpty);
      for (final card in deck(container)) {
        expect(card.body, "Stopped: Couldn't save the old file as a snapshot. Nothing was changed.");
        expect(card.progress, 0);
      }
      expect(deck(container), hasLength(2));
    });

    testWidgets('a tick of a download the deck does not show leaves its cards as they are', (t) async {
      final container = seeded([landed(1, 10), _browse(2, state: DownloadJobState.running)]);
      await host(t, container);
      final front = deck(container).single;
      (container.read(downloadQueueProvider.notifier) as SeededQueue).tick();
      await frames(t);
      expect(deck(container).single, same(front));
    });

    testWidgets('a halt is one Error card that stays, in place of the failure that caused it', (t) async {
      final container = seeded([landed(1, 10), landed(2, 20)]);
      await host(t, container);
      stages.ready(1);
      await frames(t);
      stages.writeFails(1, const UpdateFailure(UpdateFailureKind.noSpace, requiredBytes: 2 * mb, availableBytes: mb));
      await frames(t);

      final errors = [for (final n in cards(container)) if (n.kind == NotificationKind.error) n];
      expect(errors.single.title, 'Updates stopped');
      expect(errors.single.body, 'mod 1: Not enough space — 2.0 MB needed, 1.0 MB free. Nothing was changed.');
      await t.pump(const Duration(minutes: 1));
      expect(cards(container).where((n) => n.title == 'Updates stopped'), hasLength(1), reason: 'it has no clock');
    });

    testWidgets("a halt names the mod whose write halted it, and the job's other failed mods have their cards",
        (t) async {
      final miyabi = baseOf('m2', 1, name: 'Miyabi');
      final soukaku = baseOf('m3', 1, name: 'Soukaku');
      final container = seeded(
        [landed(1, 10, mods: [baseOf('mod1', 1), miyabi, soukaku]), landed(2, 20)],
        library: [ModInfo(id: 'm2', name: 'Miyabi Fox', characterId: 'miyabi', isActive: false)],
      );
      await host(t, container);
      stages.ready(1);
      await frames(t);
      // Room for the first folder's snapshot and not the second's.
      final noRoom = UpdateFailure(UpdateFailureKind.noSpace, requiredBytes: 2 * mb, availableBytes: mb);
      stages.writes(
        1,
        UpdateStageFailed(noRoom, results: [
          UpdateModResult.written(baseOf('mod1', 1)),
          UpdateModResult(miyabi, UpdateModEnd.failed, failure: noRoom),
          UpdateModResult(soukaku, UpdateModEnd.refused, failure: UpdateFailure(UpdateFailureKind.refused)),
        ]),
      );
      await frames(t);

      expect(jobOf(container, 2).halt?.modId, 'm2');
      final errors = [for (final n in cards(container)) if (n.kind == NotificationKind.error) n];
      final halt = errors.singleWhere((n) => n.title == 'Updates stopped');
      expect(halt.body, 'Miyabi Fox: Not enough space — 2.0 MB needed, 1.0 MB free. Nothing was changed.');
      expect(halt.characterId, 'miyabi');
      expect([for (final n in errors) n.title], unorderedEquals(['Updates stopped', "Couldn't update Soukaku"]),
          reason: "the halt's card stands in only for the failure that caused it");
      expect(cards(container).singleWhere((n) => n.kind == NotificationKind.done).title, 'mod 1 updated');
      await t.pump(const Duration(seconds: 6));
    });

    testWidgets("a halt that covers a whole job names its first mod, and the job's other mods have their cards",
        (t) async {
      final container = seeded([
        landed(1, 10, mods: [baseOf('mod1', 1), baseOf('m2', 1, name: 'Miyabi'), baseOf('m3', 1, name: 'Soukaku')]),
        landed(2, 20),
      ]);
      await host(t, container);
      stages.prepareFails(1, const UpdateFailure(UpdateFailureKind.noSpace, requiredBytes: 2 * mb, availableBytes: mb));
      await frames(t);

      expect(jobOf(container, 2).halt?.modId, 'mod1');
      final errors = [for (final n in cards(container)) if (n.kind == NotificationKind.error) n];
      expect(errors.singleWhere((n) => n.title == 'Updates stopped').body,
          'mod 1: Not enough space — 2.0 MB needed, 1.0 MB free. Nothing was changed.');
      expect([for (final n in errors) n.title],
          unorderedEquals(['Updates stopped', "Couldn't update Miyabi", "Couldn't update Soukaku"]));
    });

    testWidgets('a write that throws during a later mod of its job names that mod on the halt', (t) async {
      final container = seeded([
        landed(1, 10, mods: [baseOf('mod1', 1), baseOf('m2', 1, name: 'Miyabi'), baseOf('m3', 1, name: 'Soukaku')]),
        landed(2, 20),
      ]);
      await host(t, container);
      stages.ready(1);
      await frames(t);
      container.read(downloadQueueProvider.notifier).reportWriteStep(
            1,
            const UpdateWriting('m2', UpdateWriteStep.replacingFiles),
          );
      stages.writeThrows(1);
      await frames(t);

      expect(jobOf(container, 2).halt?.modId, 'm2');
      final errors = [for (final n in cards(container)) if (n.kind == NotificationKind.error) n];
      expect(errors.singleWhere((n) => n.title == 'Updates stopped').body, startsWith('Miyabi: '));
      expect([for (final n in errors) n.title],
          unorderedEquals(['Updates stopped', "Couldn't update mod 1", "Couldn't update Soukaku"]));
    });
  });

  group('the questions the host asks (docs/update-runs.md §6)', () {
    /// The frames, after a turn of the real event loop: an answer started under `runAsync` goes on there once its window closes.
    Future<void> frames(WidgetTester t) async {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      for (var i = 0; i < 5; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
    }

    /// Presses Answer on job [seq] and lets the window open: a window that reads its folders first needs real time for it.
    Future<void> answer(WidgetTester t, ProviderContainer container, int seq) async {
      await t.runAsync(() async {
        unawaited(container.read(downloadQuestionsProvider).answer(seq));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await frames(t);
    }

    final kimono = ModInfo(id: 'mod1', name: 'Crimson Kimono', characterId: 'miyabi', isActive: true);
    final shrine = ModInfo(id: 'Shrine', name: 'Shrine Maiden', characterId: 'miyabi', isActive: false);
    const patchUnpack = UpdateUnpacked(root: null, folders: ['/tmp/x/CrimsonKimono'], archiveMd5: null);

    /// The patch question about Crimson Kimono, with what the unpack found.
    const patchAsks = UpdateStageAsks(
      UpdateWait(UpdateQuestionKind.patchShaped, modId: 'mod1'),
      prepared: UpdateRunKept(
        unpacked: patchUnpack,
        patchQuestion: UpdatePatchFinding(
          modId: 'mod1',
          sources: ['/tmp/x/CrimsonKimono'],
          missing: ['miyabibody.ib', 'miyabibody.vb'],
        ),
      ),
    );

    /// Job 1 waiting on the patch question about its mod.
    Future<ProviderContainer> patchQuestion(WidgetTester t, {List<UpdateMod>? mods}) async {
      final container = seeded([landed(1, 10, mods: mods)], library: [kimono, shrine]);
      await host(t, container);
      stages.answers(1, patchAsks);
      await frames(t);
      return container;
    }

    testWidgets('a patch-shaped file opens the patch window with "Put it on top" picked, and the answer goes back in line',
        (t) async {
      final container = await patchQuestion(t);
      expect(cards(container).where((n) => n.kind == NotificationKind.needsYou), hasLength(1));
      expect(rowActions(jobOf(container, 1), container.read(downloadQueueProvider)),
          [DownloadRowAction.answer, DownloadRowAction.skipUpdate]);

      await answer(t, container, 1);
      expect(find.text('This update looks like a patch'), findsOneWidget);
      expect(find.text('Put it on top of Crimson Kimono'), findsOneWidget);
      final onTop = t.widget<ChoiceCard>(find.widgetWithText(ChoiceCard, 'Put it on top of Crimson Kimono'));
      expect(onTop.selected, isTrue, reason: 'the user picked this file for this mod');
      expect(find.text('Add it to a different mod you have'), findsOneWidget);
      expect(find.text('Install it as a new mod, with the mod it patches'), findsNothing, reason: 'an update has a mod');

      await t.tap(find.widgetWithText(FilledButton, 'Put it on top'));
      await frames(t);
      expect(stages.prepared, [1, 1], reason: 'the answer goes back to the unpack lane');
      final kept = stages.preparedWith.last! as UpdateRunKept;
      expect((kept.answers['mod1']! as PlaceAsPatch).intoModId, 'mod1');
      expect(kept.unpacked, same(patchUnpack), reason: 'the archive is not unpacked twice');
      expect(stages.written, isEmpty, reason: 'nothing is written until the write lane');
    });

    testWidgets('a different mod has nothing picked for it, and the answer names the one the user picked', (t) async {
      final container = await patchQuestion(t);
      await answer(t, container, 1);
      await t.tap(find.text('Add it to a different mod you have'));
      await t.pump();
      expect(find.widgetWithText(PickRow, 'Shrine Maiden'), findsOneWidget);
      expect(find.widgetWithText(PickRow, 'Crimson Kimono'), findsNothing, reason: 'the mod itself is the other card');
      expect(t.widget<PickRow>(find.widgetWithText(PickRow, 'Shrine Maiden')).selected, isFalse);
      expect(t.widget<FilledButton>(find.widgetWithText(FilledButton, 'Patch')).onPressed, isNull);
      expect(find.text('Pick the mod to patch'), findsOneWidget);

      await t.tap(find.widgetWithText(PickRow, 'Shrine Maiden'));
      await t.pump();
      await t.tap(find.widgetWithText(FilledButton, 'Patch Shrine Maiden'));
      await frames(t);
      final kept = stages.preparedWith.last! as UpdateRunKept;
      expect((kept.answers['mod1']! as PlaceAsPatch).intoModId, 'Shrine');
    });

    testWidgets('closing the patch window leaves the question waiting, and its Skip ends the job', (t) async {
      final container = await patchQuestion(t);
      await answer(t, container, 1);
      await t.tap(find.byTooltip('Close'));
      await frames(t);
      expect(jobOf(container, 1).state, DownloadJobState.waiting, reason: 'closing answers later');
      expect(stages.prepared, [1]);

      await answer(t, container, 1);
      await t.runAsync(() async {
        await t.tap(find.text('Skip this update'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await frames(t);
      expect(jobOf(container, 1).outcome, JobOutcome.skipped);
      expect(jobOf(container, 1).resultFor('mod1')?.skipReason, UpdateSkipReason.skippedByUser);
      expect(stages.written, isEmpty, reason: 'a patch-shaped file is never written by the update');
    });

    testWidgets("Skip on a sibling's question skips that mod alone, and the job goes on with the others", (t) async {
      final container = seeded([
        landed(1, 10, mods: [baseOf('mod1', 1), baseOf('Shrine', 1)]),
      ], library: [kimono, shrine]);
      await host(t, container);
      stages.answers(
        1,
        const UpdateStageAsks(
          UpdateWait(UpdateQuestionKind.unrecordedPatch, modId: 'Shrine'),
          prepared: UpdateRunKept(unpacked: patchUnpack),
        ),
      );
      await frames(t);
      final job = jobOf(container, 1);
      expect(updatePhaseOf(job, 'Shrine'), isA<UpdateAsking>());
      expect(updatePhaseOf(job, 'mod1'), isA<UpdateInLine>(), reason: "only the sibling's row asks its question");

      await t.runAsync(() => skipUpdateQuestion(container, job));
      await frames(t);
      expect(stages.prepared, [1, 1], reason: 'the job goes back in line with the other mod');
      final kept = stages.preparedWith.last! as UpdateRunKept;
      expect(kept.answers['Shrine'], isA<SkipThisMod>());
      expect(kept.answers.containsKey('mod1'), isFalse);
    });

    testWidgets('the unrecorded-patch question asks Update anyway or Skip update, and Update anyway is kept as the answer',
        (t) async {
      final container = seeded([landed(1, 10)], library: [kimono]);
      await host(t, container);
      stages.answers(
        1,
        const UpdateStageAsks(
          UpdateWait(UpdateQuestionKind.unrecordedPatch, modId: 'mod1'),
          prepared: UpdateRunKept(unpacked: patchUnpack),
        ),
      );
      await frames(t);
      await answer(t, container, 1);
      expect(find.text('Crimson Kimono holds a patch as well'), findsOneWidget);
      expect(
        find.text('Nothing records which files came from the patch, so updating removes it from the folder. '
            'The saved copy keeps it.'),
        findsOneWidget,
      );
      expect(find.textContaining('holds a patch as well,'), findsNothing, reason: 'the body does not repeat the title');
      await t.tap(find.widgetWithText(FilledButton, 'Update anyway'));
      await frames(t);
      final kept = stages.preparedWith.last! as UpdateRunKept;
      expect(kept.answers['mod1'], isA<UpdateAnyway>());
    });

    testWidgets("the Needs you card's Answer on an install's already-installed question opens the panel, not an install",
        (t) async {
      final container = seeded([
        _browse(1, state: DownloadJobState.waiting).withWait(const InstallWait(InstallQuestion.alreadyInstalled)),
      ]);
      await host(t, container);
      final card = cards(container).singleWhere((n) => n.kind == NotificationKind.needsYou);
      final before = container.read(downloadsPanelRequestProvider);
      card.actions.first.onPressed();
      await frames(t);
      expect(container.read(downloadsPanelRequestProvider), before + 1, reason: "its answers are its row's two buttons");
      expect(jobOf(container, 1).state, DownloadJobState.waiting, reason: 'nothing was installed by the card');
    });

    testWidgets("the Needs you card's Answer opens the oldest question's window and stays", (t) async {
      final container = seeded([landed(1, 10), landed(2, 20)], library: [kimono]);
      await host(t, container);
      stages.answers(
        1,
        const UpdateStageAsks(
          UpdateWait(UpdateQuestionKind.unrecordedPatch, modId: 'mod1'),
          prepared: UpdateRunKept(unpacked: patchUnpack),
        ),
      );
      await frames(t);
      stages.asks(2, UpdateQuestionKind.password);
      await frames(t);

      final card = cards(container).singleWhere((n) => n.kind == NotificationKind.needsYou);
      expect([for (final a in card.actions) a.label], ['Answer', 'Open Downloads']);
      final answerAction = card.actions.first;
      expect(answerAction.closes, isFalse, reason: 'a window closed without an answer leaves the question waiting');
      await t.runAsync(() async {
        answerAction.onPressed();
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await frames(t);
      expect(find.text('Crimson Kimono holds a patch as well'), findsOneWidget, reason: 'job 1 waited first');
    });

    testWidgets('the password is asked again after a wrong one, closing it leaves it waiting, and Skip ends it',
        (t) async {
      final container = seeded([landed(1, 10)]);
      await host(t, container);
      stages.asks(1, UpdateQuestionKind.password);
      await frames(t);

      await answer(t, container, 1);
      expect(find.text("Enter the archive's password"), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Skip update'), findsOneWidget);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await frames(t);
      expect(jobOf(container, 1).state, DownloadJobState.waiting, reason: 'closing answers later');

      await answer(t, container, 1);
      await t.enterText(find.byType(TextField), 'nope');
      await t.pump();
      await t.tap(find.widgetWithText(FilledButton, 'Update'));
      await frames(t);
      expect(stages.prepared, [1, 1]);
      expect(stages.passwords.last, 'nope', reason: 'the password goes back in line with the job');

      stages.answers(1, const UpdateStageAsks(UpdateWait(UpdateQuestionKind.password, passwordFailed: true)));
      await frames(t);
      expect(jobOf(container, 1).password, isNull, reason: 'held only for the unpack it was given for');
      await answer(t, container, 1);
      expect(find.text("That password didn't open the archive."), findsOneWidget);
      await t.tap(find.widgetWithText(TextButton, 'Skip update'));
      await frames(t);
      expect(jobOf(container, 1).outcome, JobOutcome.skipped);
    });

    testWidgets("the password window's Skip is logged as one declined question, and Open mod page as none", (t) async {
      final capture = LogCapture();
      Log.install(LogRouter(sinks: [capture]));
      addTearDown(() => Log.install(LogRouter()));
      List<Map<String, Object?>> declines() => [
            for (final r in capture.records)
              if (r.message == 'answered' && r.fields['decision'] == 'declined') r.fields,
          ];

      final container = seeded([landed(1, 10)]);
      await host(t, container);
      stages.asks(1, UpdateQuestionKind.password);
      await frames(t);

      await answer(t, container, 1);
      await t.tap(find.text('Open mod page'));
      await frames(t);
      expect(jobOf(container, 1).state, DownloadJobState.waiting);
      expect(declines(), isEmpty, reason: 'going to read the password is not saying no');

      await answer(t, container, 1);
      await t.tap(find.widgetWithText(TextButton, 'Skip update'));
      await frames(t);
      expect(jobOf(container, 1).outcome, JobOutcome.skipped);
      expect([for (final d in declines()) d['action']], ['update.question']);
    });

    testWidgets("the folders are picked in the existing picker, and the pick goes back to the unpack lane", (t) async {
      final container = seeded(
        [landed(1, 10)],
        library: [ModInfo(id: 'mod1', name: 'Pastel Burnice', characterId: 'burnice', isActive: true)],
      );
      await host(t, container);
      const unpack = UpdateUnpacked(root: null, folders: ['/tmp/x/PastelBurnice', '/tmp/x/Previews'], archiveMd5: null);
      stages.answers(
        1,
        const UpdateStageAsks(
          UpdateWait(UpdateQuestionKind.folders),
          prepared: UpdateRunKept(
            unpacked: unpack,
            foldersQuestion: FoldersQuestion(
              problem: UpdateLayoutProblem.layoutUnknown,
              unpacked: unpack,
              choices: [
                UpdateFolderChoice(path: '/tmp/x/PastelBurnice', name: 'PastelBurnice'),
                UpdateFolderChoice(path: '/tmp/x/Previews', name: 'Previews'),
              ],
            ),
          ),
        ),
      );
      await frames(t);
      expect(jobOf(container, 1).state, DownloadJobState.waiting);
      expect(rowActions(jobOf(container, 1), container.read(downloadQueueProvider)),
          [DownloadRowAction.answer, DownloadRowAction.skipUpdate]);

      await answer(t, container, 1);
      expect(find.text('Pick what to install'), findsOneWidget);
      expect(find.text('YOU HAVE NOW'), findsOneWidget);
      expect(t.widget<FilledButton>(find.widgetWithText(FilledButton, 'Update Pastel Burnice')).onPressed, isNull,
          reason: 'nothing is ticked for the user');
      expect(find.text('Tick the folder that replaces it'), findsOneWidget);
      expect(find.text('Same name as your folder'), findsNothing, reason: "the folder is not named like the mod's id");
      await t.tap(find.text('PastelBurnice/'));
      await t.pump();
      expect(find.text('1 folder replaces Pastel Burnice'), findsOneWidget);
      await t.tap(find.widgetWithText(FilledButton, 'Update Pastel Burnice'));
      await frames(t);

      expect(stages.prepared, [1, 1]);
      final kept = stages.preparedWith.last! as UpdateRunKept;
      expect(kept.pickedFolders, ['/tmp/x/PastelBurnice']);
      expect(kept.unpacked, same(unpack), reason: 'the archive is not unpacked twice');
    });

    testWidgets('a folder pick is followed in the same sitting by the patch question it comes back with', (t) async {
      final container = seeded([landed(1, 10)], library: [kimono]);
      await host(t, container);
      const unpack = UpdateUnpacked(root: null, folders: ['/tmp/x/A', '/tmp/x/B'], archiveMd5: null);
      stages.answers(
        1,
        const UpdateStageAsks(
          UpdateWait(UpdateQuestionKind.folders, modId: 'mod1'),
          prepared: UpdateRunKept(
            unpacked: unpack,
            foldersQuestion: FoldersQuestion(
              problem: UpdateLayoutProblem.layoutUnknown,
              unpacked: unpack,
              choices: [
                UpdateFolderChoice(path: '/tmp/x/A', name: 'A'),
                UpdateFolderChoice(path: '/tmp/x/B', name: 'B'),
              ],
            ),
          ),
        ),
      );
      await frames(t);
      await answer(t, container, 1);
      await t.tap(find.text('A/'));
      await t.pump();
      await t.tap(find.widgetWithText(FilledButton, 'Update Crimson Kimono'));
      await frames(t);
      expect(stages.prepared, [1, 1]);

      await t.runAsync(() async {
        stages.answers(
          1,
          const UpdateStageAsks(
            UpdateWait(UpdateQuestionKind.unrecordedPatch, modId: 'mod1'),
            prepared: UpdateRunKept(unpacked: unpack, pickedFolders: ['/tmp/x/A']),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await frames(t);
      expect(find.text('Crimson Kimono holds a patch as well'), findsOneWidget,
          reason: 'the question after the pick is asked without another press');
    });

    testWidgets("the folders window's Skip this update ends the job", (t) async {
      final container = seeded([landed(1, 10)], library: [kimono]);
      await host(t, container);
      const unpack = UpdateUnpacked(root: null, folders: ['/tmp/x/A', '/tmp/x/B'], archiveMd5: null);
      stages.answers(
        1,
        const UpdateStageAsks(
          UpdateWait(UpdateQuestionKind.folders, modId: 'mod1'),
          prepared: UpdateRunKept(
            unpacked: unpack,
            foldersQuestion: FoldersQuestion(
              problem: UpdateLayoutProblem.layoutUnknown,
              unpacked: unpack,
              choices: [
                UpdateFolderChoice(path: '/tmp/x/A', name: 'A'),
                UpdateFolderChoice(path: '/tmp/x/B', name: 'B'),
              ],
            ),
          ),
        ),
      );
      await frames(t);
      await answer(t, container, 1);
      await t.runAsync(() async {
        await t.tap(find.text('Skip this update'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await frames(t);
      expect(jobOf(container, 1).outcome, JobOutcome.skipped);
    });

    /// Answer on job 1's folders question, its first mod in a folder [library] no longer has under that name.
    Future<DownloadJob> answerForAMissingMod(WidgetTester t, List<ModInfo> library) async {
      const first = UpdateMod(modId: 'mod1', layer: DownloadKey.base(1), uid: 'u1');
      final container = seeded([landed(1, 10, mods: [first, baseOf('Ellen', 1)])], library: library);
      await host(t, container);
      const unpack = UpdateUnpacked(root: null, folders: ['/tmp/x/A', '/tmp/x/B'], archiveMd5: null);
      stages.answers(
        1,
        const UpdateStageAsks(
          UpdateWait(UpdateQuestionKind.folders),
          prepared: UpdateRunKept(
            unpacked: unpack,
            foldersQuestion: FoldersQuestion(
              problem: UpdateLayoutProblem.layoutUnknown,
              unpacked: unpack,
              choices: [
                UpdateFolderChoice(path: '/tmp/x/A', name: 'A'),
                UpdateFolderChoice(path: '/tmp/x/B', name: 'B'),
              ],
            ),
          ),
        ),
      );
      await frames(t);

      await t.runAsync(() => container.read(downloadQuestionsProvider).answer(1));
      await frames(t);
      expect(find.byType(Dialog), findsNothing);
      final job = jobOf(container, 1);
      expect(job.outcome, JobOutcome.skipped);
      return job;
    }

    final ellen = ModInfo(id: 'Ellen', name: 'Ellen', characterId: 'ellen', isActive: false, uid: 'u2');

    testWidgets('Answer on a folders question whose mod has left the library skips it as gone, the others as sharing it',
        (t) async {
      final job = await answerForAMissingMod(t, [ellen]);
      expect(job.skipReason, UpdateSkipReason.modGone);
      expect(job.resultFor('mod1')?.skipReason, UpdateSkipReason.modGone);
      expect(job.resultFor('Ellen')?.skipReason, UpdateSkipReason.sharedFileNotWritten,
          reason: 'Ellen is still there; her file was not written because the mod it was asked for is gone');
    });

    testWidgets('Answer on a folders question whose mod was renamed skips it as renamed', (t) async {
      final renamed = ModInfo(id: 'mod1 Renamed', name: 'mod1 Renamed', characterId: 'ellen', isActive: false, uid: 'u1');
      final job = await answerForAMissingMod(t, [ellen, renamed]);
      expect(job.skipReason, UpdateSkipReason.folderRenamed);
      expect(job.resultFor('Ellen')?.skipReason, UpdateSkipReason.sharedFileNotWritten);
    });

    testWidgets("Skip on the last mod left ends the job with each mod's own reason, and only the user's Skip is a declined question",
        (t) async {
      final capture = LogCapture();
      Log.install(LogRouter(sinks: [capture]));
      addTearDown(() => Log.install(LogRouter()));
      int declines() => capture.records.where((r) => r.message == 'answered' && r.fields['decision'] == 'declined').length;

      final container = seeded([
        landed(1, 10, mods: [baseOf('mod1', 1), baseOf('Shrine', 1), baseOf('Ellen', 1)]),
      ], library: [kimono, shrine, ellen]);
      await host(t, container);
      stages.answers(
        1,
        const UpdateStageAsks(
          UpdateWait(UpdateQuestionKind.unrecordedPatch, modId: 'mod1'),
          prepared: UpdateRunKept(unpacked: patchUnpack),
        ),
      );
      await frames(t);

      // A reason the answer found about the first mod skips it alone, and is not the user saying no.
      await t.runAsync(() => skipUpdateQuestion(container, jobOf(container, 1), reason: UpdateSkipReason.modGone));
      await frames(t);
      expect(declines(), 0);
      stages.answers(
        1,
        const UpdateStageAsks(
          UpdateWait(UpdateQuestionKind.unrecordedPatch, modId: 'Shrine'),
          prepared: UpdateRunKept(unpacked: patchUnpack, answers: {'mod1': SkipThisMod(UpdateSkipReason.modGone)}),
        ),
      );
      await frames(t);
      await t.runAsync(() => skipUpdateQuestion(container, jobOf(container, 1)));
      await frames(t);
      expect(declines(), 1);
      stages.answers(
        1,
        const UpdateStageAsks(
          UpdateWait(UpdateQuestionKind.unrecordedPatch, modId: 'Ellen'),
          prepared: UpdateRunKept(unpacked: patchUnpack, answers: {
            'mod1': SkipThisMod(UpdateSkipReason.modGone),
            'Shrine': SkipThisMod(),
          }),
        ),
      );
      await frames(t);

      await t.runAsync(() => skipUpdateQuestion(container, jobOf(container, 1)));
      await frames(t);
      final job = jobOf(container, 1);
      expect(job.outcome, JobOutcome.skipped);
      expect(job.resultFor('mod1')?.skipReason, UpdateSkipReason.modGone, reason: 'the earlier reason survives');
      expect(job.resultFor('Shrine')?.skipReason, UpdateSkipReason.skippedByUser);
      expect(job.resultFor('Ellen')?.skipReason, UpdateSkipReason.skippedByUser);
      expect(job.skipReason, UpdateSkipReason.modGone, reason: "the job's reason is its first mod's");
      expect(declines(), 2);
    });

    testWidgets('a skip of the last mod left for a reason the answer found is logged with that mod', (t) async {
      final capture = LogCapture();
      Log.install(LogRouter(sinks: [capture]));
      addTearDown(() => Log.install(LogRouter()));
      final container = seeded([
        landed(1, 10, mods: [baseOf('mod1', 1), baseOf('Shrine', 1)]),
      ], library: [kimono, shrine]);
      await host(t, container);
      stages.answers(
        1,
        const UpdateStageAsks(
          UpdateWait(UpdateQuestionKind.unrecordedPatch, modId: 'Shrine'),
          prepared: UpdateRunKept(unpacked: patchUnpack, answers: {'mod1': SkipThisMod()}),
        ),
      );
      await frames(t);

      await t.runAsync(() => skipUpdateQuestion(container, jobOf(container, 1), reason: UpdateSkipReason.ignoredMeanwhile));
      await frames(t);
      expect(jobOf(container, 1).outcome, JobOutcome.skipped);
      expect([for (final r in capture.records) if (r.message == 'update skipped at its question') r.fields['mod']], ['Shrine']);
    });

    testWidgets('while an answered job is waited for, the other questions can be answered', (t) async {
      final container = seeded([landed(1, 10), landed(2, 20, mods: [baseOf('Shrine', 2)])], library: [kimono, shrine]);
      await host(t, container);
      stages.asks(1, UpdateQuestionKind.password);
      await frames(t);
      stages.answers(
        2,
        const UpdateStageAsks(
          UpdateWait(UpdateQuestionKind.unrecordedPatch, modId: 'Shrine'),
          prepared: UpdateRunKept(unpacked: patchUnpack),
        ),
      );
      await frames(t);

      await answer(t, container, 1);
      await t.enterText(find.byType(TextField), 'secret');
      await t.pump();
      await t.tap(find.widgetWithText(FilledButton, 'Update'));
      await frames(t);
      expect(stages.prepared, [1, 2, 1], reason: 'the answered job is back in line, and not back yet');

      await answer(t, container, 2);
      expect(find.text('Shrine Maiden holds a patch as well'), findsOneWidget,
          reason: 'the wait for the answered job holds no other Answer back');
    });

    testWidgets('an answer given in a window whose question was skipped meanwhile is dropped, and says nothing', (t) async {
      final capture = LogCapture();
      Log.install(LogRouter(sinks: [capture]));
      addTearDown(() => Log.install(LogRouter()));
      final container = await patchQuestion(t, mods: [baseOf('mod1', 1), baseOf('Shrine', 1)]);
      await answer(t, container, 1);
      expect(find.text('This update looks like a patch'), findsOneWidget);

      // Skip on that mod's row while its window is open: the job goes on with Shrine and stops at a question about it.
      await t.runAsync(() => skipUpdateQuestion(container, jobOf(container, 1)));
      await frames(t);
      expect(jobOf(container, 1).resultFor('mod1')?.skipReason, UpdateSkipReason.skippedByUser,
          reason: "the skipped mod's row reads skipped at once");
      expect(updatePhaseOf(jobOf(container, 1), 'mod1'), isNull);
      stages.answers(
        1,
        const UpdateStageAsks(
          UpdateWait(UpdateQuestionKind.unrecordedPatch, modId: 'Shrine'),
          prepared: UpdateRunKept(unpacked: patchUnpack, answers: {'mod1': SkipThisMod()}),
        ),
      );
      await frames(t);
      expect(stages.prepared, [1, 1]);

      await t.tap(find.widgetWithText(FilledButton, 'Put it on top'));
      await frames(t);
      final job = jobOf(container, 1);
      expect(job.state, DownloadJobState.waiting, reason: 'the question about Shrine still waits');
      expect(job.updateWait?.modId, 'Shrine');
      expect((job.prepared! as UpdateRunKept).answers['mod1'], isA<SkipThisMod>(), reason: 'the Skip stands');
      expect(stages.prepared, [1, 1], reason: 'the dropped answer sent nothing back in line');
      expect(cards(container).where((n) => n.kind == NotificationKind.error), isEmpty);
      expect([for (final r in capture.records) if (r.fields['action'] == 'update.patch') r.fields], isEmpty,
          reason: 'an answer the queue refused is not logged as given');
    });

    testWidgets('a window whose question was skipped while it was read does not open', (t) async {
      ranking = Completer<void>();
      final container = await patchQuestion(t, mods: [baseOf('mod1', 1), baseOf('Shrine', 1)]);
      await answer(t, container, 1);
      expect(find.text('This update looks like a patch'), findsNothing, reason: 'the library is still being ranked');

      await t.runAsync(() => skipUpdateQuestion(container, jobOf(container, 1)));
      await frames(t);
      expect(stages.prepared, [1, 1]);
      await t.runAsync(() async => ranking!.complete());
      await frames(t);
      expect(find.text('This update looks like a patch'), findsNothing);
      expect(jobOf(container, 1).resultFor('mod1')?.skipReason, UpdateSkipReason.skippedByUser);
    });

    int inHand(ProviderContainer container) => container.read(downloadQuestionsProvider).questionsInHand;

    testWidgets('a second Answer for a question still being read does nothing, so the window the user closed does not open again',
        (t) async {
      final first = Completer<void>();
      final second = Completer<void>();
      rankings = [first, second];
      final container = await patchQuestion(t);
      await answer(t, container, 1);
      await answer(t, container, 1);
      expect(rankCalls, 1, reason: 'the second press reads nothing');

      await t.runAsync(() async => first.complete());
      await frames(t);
      expect(find.text('This update looks like a patch'), findsOneWidget);
      await t.tap(find.byTooltip('Close'));
      await frames(t);
      await t.runAsync(() async => second.complete());
      await frames(t);
      expect(find.text('This update looks like a patch'), findsNothing, reason: 'it does not open again by itself');
      expect(jobOf(container, 1).state, DownloadJobState.waiting);
    });

    testWidgets("the Needs you card's Answer for the question whose window is open does nothing", (t) async {
      final slow = Completer<void>();
      rankings = [null, slow];
      final container = await patchQuestion(t);
      await answer(t, container, 1);
      expect(find.text('This update looks like a patch'), findsOneWidget);

      final card = cards(container).singleWhere((n) => n.kind == NotificationKind.needsYou);
      await t.runAsync(() async {
        card.actions.first.onPressed();
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await frames(t);
      expect(rankCalls, 1, reason: 'the question is already being answered');
      await t.tap(find.byTooltip('Close'));
      await frames(t);
      await t.runAsync(() async => slow.complete());
      await frames(t);
      expect(find.text('This update looks like a patch'), findsNothing);
    });

    testWidgets("an Answer pressed while the window's Skip is still being stored does nothing", (t) async {
      late TempLibrary temp;
      await t.runAsync(() async {
        temp = await TempLibrary.create(prefix: 'zzz_update_host_');
        temp.write('mod1', 'mod1.ini', '[TextureOverrideBody]\nhash = 1\n');
      });
      final service = RecordingService(temp);
      final container = ProviderContainer(overrides: [
        downloadQueueProvider.overrideWith(
          () => SeededQueue([landed(1, 10, mods: [baseOf('mod1', 1), baseOf('Shrine', 1)])]),
        ),
        libraryOf([kimono, shrine]),
        ...service.overrides,
      ]);
      addTearDown(container.dispose);
      container.read(downloadQueueProvider);
      await host(t, container);
      stages.answers(1, patchAsks);
      await frames(t);
      await answer(t, container, 1);
      expect(find.text('This update looks like a patch'), findsOneWidget);

      // The Skip reads the mod's sidecar before it is stored.
      final reading = service.holdNextOriginRead = Completer<void>();
      await t.runAsync(() async {
        await t.tap(find.text('Skip this update'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await frames(t);
      expect(jobOf(container, 1).updateWait?.modId, 'mod1', reason: 'the Skip is not stored yet');

      await answer(t, container, 1);
      expect(find.text('This update looks like a patch'), findsNothing, reason: 'the question is being skipped');

      await t.runAsync(() async => reading.complete());
      await frames(t);
      expect(jobOf(container, 1).resultFor('mod1')?.skipReason, UpdateSkipReason.skippedByUser);
      expect(find.byType(Dialog), findsNothing);
      expect(inHand(container), 0);
    });

    group('a question is let go once its press ends', () {
      testWidgets('by closing its window', (t) async {
        final container = await patchQuestion(t);
        await answer(t, container, 1);
        await t.tap(find.byTooltip('Close'));
        await frames(t);
        expect(inHand(container), 0);
        await answer(t, container, 1);
        expect(find.text('This update looks like a patch'), findsOneWidget, reason: 'its next Answer opens it');
      });

      testWidgets('by an answer', (t) async {
        final container = await patchQuestion(t);
        await answer(t, container, 1);
        await t.tap(find.widgetWithText(FilledButton, 'Put it on top'));
        await frames(t);
        expect(stages.prepared, [1, 1]);
        expect(inHand(container), 0);
      });

      testWidgets('by its Skip', (t) async {
        final container = await patchQuestion(t);
        await answer(t, container, 1);
        await t.runAsync(() async {
          await t.tap(find.text('Skip this update'));
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
        await frames(t);
        expect(jobOf(container, 1).outcome, JobOutcome.skipped);
        expect(inHand(container), 0);
      });

      testWidgets('by a read that throws', (t) async {
        rankingThrows = true;
        final container = await patchQuestion(t);
        await answer(t, container, 1);
        expect(find.byType(Dialog), findsNothing);
        expect(inHand(container), 0);

        rankingThrows = false;
        await answer(t, container, 1);
        expect(rankCalls, 2);
        expect(find.text('This update looks like a patch'), findsOneWidget, reason: 'the question can be asked again');
      });

      testWidgets('by its job ending while it is read', (t) async {
        ranking = Completer<void>();
        final container = await patchQuestion(t);
        await answer(t, container, 1);
        expect(inHand(container), 1);
        await t.runAsync(() => container.read(downloadQueueProvider.notifier).cancelAllUpdates());
        await frames(t);
        await t.runAsync(() async => ranking!.complete());
        await frames(t);
        expect(find.byType(Dialog), findsNothing);
        expect(inHand(container), 0);
      });
    });

    group('a Skip pressed in a window whose question was skipped meanwhile is dropped, and logs nothing', () {
      const folders = UpdateUnpacked(root: null, folders: ['/tmp/x/A', '/tmp/x/B'], archiveMd5: null);
      final cases = <(String, UpdateStageAsks, String, String)>[
        ('update.patch', patchAsks, 'This update looks like a patch', 'Skip this update'),
        (
          'update.layout',
          const UpdateStageAsks(
            UpdateWait(UpdateQuestionKind.folders, modId: 'mod1'),
            prepared: UpdateRunKept(
              unpacked: folders,
              foldersQuestion: FoldersQuestion(
                problem: UpdateLayoutProblem.layoutUnknown,
                unpacked: folders,
                choices: [
                  UpdateFolderChoice(path: '/tmp/x/A', name: 'A'),
                  UpdateFolderChoice(path: '/tmp/x/B', name: 'B'),
                ],
              ),
            ),
          ),
          'Pick what to install',
          'Skip this update',
        ),
        (
          'update.unrecorded_patch',
          const UpdateStageAsks(
            UpdateWait(UpdateQuestionKind.unrecordedPatch, modId: 'mod1'),
            prepared: UpdateRunKept(unpacked: patchUnpack),
          ),
          'Crimson Kimono holds a patch as well',
          'Skip update',
        ),
      ];
      for (final (action, asks, title, skip) in cases) {
        testWidgets(action, (t) async {
          final capture = LogCapture();
          Log.install(LogRouter(sinks: [capture]));
          addTearDown(() => Log.install(LogRouter()));
          final container = seeded([
            landed(1, 10, mods: [baseOf('mod1', 1), baseOf('Shrine', 1)]),
          ], library: [kimono, shrine]);
          await host(t, container);
          stages.answers(1, asks);
          await frames(t);
          await answer(t, container, 1);
          expect(find.text(title), findsOneWidget);

          // Skip on its row while the window is open. The folders question skips the whole job; the others go on to a question about Shrine.
          await t.runAsync(() => skipUpdateQuestion(container, jobOf(container, 1)));
          await frames(t);
          final live = !jobOf(container, 1).isTerminal;
          if (live) {
            stages.answers(
              1,
              const UpdateStageAsks(
                UpdateWait(UpdateQuestionKind.unrecordedPatch, modId: 'Shrine'),
                prepared: UpdateRunKept(unpacked: patchUnpack, answers: {'mod1': SkipThisMod()}),
              ),
            );
            await frames(t);
          }

          await t.runAsync(() async {
            await t.tap(find.text(skip));
            await Future<void>.delayed(const Duration(milliseconds: 50));
          });
          await frames(t);
          if (live) expect(jobOf(container, 1).updateWait?.modId, 'Shrine', reason: 'the stale Skip changed nothing');
          expect([for (final r in capture.records) if (r.fields['action'] == action) r.fields], isEmpty);
          expect(
            [for (final r in capture.records) if (r.fields['action'] == 'update.question') r.fields['mod']],
            ['mod1'],
            reason: "only the row's Skip is logged",
          );
        });
      }
    });

    testWidgets("a window's Skip the queue takes is logged once, as the question's declined answer", (t) async {
      final capture = LogCapture();
      Log.install(LogRouter(sinks: [capture]));
      addTearDown(() => Log.install(LogRouter()));
      final container = await patchQuestion(t, mods: [baseOf('mod1', 1), baseOf('Shrine', 1)]);
      await answer(t, container, 1);
      await t.runAsync(() async {
        await t.tap(find.text('Skip this update'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await frames(t);
      expect(jobOf(container, 1).resultFor('mod1')?.skipReason, UpdateSkipReason.skippedByUser);
      final patch = [for (final r in capture.records) if (r.fields['action'] == 'update.patch') r.fields];
      expect(patch, hasLength(1));
      expect(patch.single['decision'], 'declined');
      expect(patch.single.containsKey('dismissed'), isFalse);
    });

    /// Job 1 waiting on the patch question about Crimson Kimono, its ranking held, and job 2 on the unrecorded-patch question about Shrine Maiden.
    Future<ProviderContainer> twoQuestions(WidgetTester t) async {
      ranking = Completer<void>();
      final container = seeded([landed(1, 10), landed(2, 20, mods: [baseOf('Shrine', 2)])], library: [kimono, shrine]);
      await host(t, container);
      stages.answers(1, patchAsks);
      await frames(t);
      stages.answers(
        2,
        const UpdateStageAsks(
          UpdateWait(UpdateQuestionKind.unrecordedPatch, modId: 'Shrine'),
          prepared: UpdateRunKept(unpacked: patchUnpack),
        ),
      );
      await frames(t);
      return container;
    }

    testWidgets("another Answer pressed while a question is still read opens its window, and two windows never open together",
        (t) async {
      final container = await twoQuestions(t);
      await answer(t, container, 1);
      expect(find.text('This update looks like a patch'), findsNothing, reason: 'the library is still being ranked');

      await answer(t, container, 2);
      expect(find.text('Shrine Maiden holds a patch as well'), findsOneWidget, reason: 'the reads hold no other Answer back');
      expect(container.read(downloadQuestionsProvider).questionsInHand, 2, reason: 'each question is in hand on its own');
      await t.runAsync(() async => ranking!.complete());
      await frames(t);
      expect(find.text('This update looks like a patch'), findsNothing, reason: 'one window at a time');
      expect(jobOf(container, 1).state, DownloadJobState.waiting, reason: 'its question waits for its own Answer');

      await t.tap(find.widgetWithText(FilledButton, 'Update anyway'));
      await frames(t);
      await answer(t, container, 1);
      expect(find.text('This update looks like a patch'), findsOneWidget);
    });

    testWidgets('a patch question pressed while another window is open does not rank the library', (t) async {
      final container = await twoQuestions(t);
      await answer(t, container, 2);
      expect(find.text('Shrine Maiden holds a patch as well'), findsOneWidget);
      await answer(t, container, 1);
      expect(rankCalls, 0, reason: 'its window could not open, so nothing is read for it');
      expect(container.read(downloadQuestionsProvider).questionsInHand, 1);
    });

    testWidgets("the Downloads panel's Update anyway is answered while another question's window is open", (t) async {
      final container = await twoQuestions(t);
      ranking!.complete();
      await answer(t, container, 1);
      expect(find.text('This update looks like a patch'), findsOneWidget);

      await t.runAsync(() async {
        unawaited(container.read(downloadQuestionsProvider).updateAnyway(2));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await frames(t);
      expect(stages.prepared, [1, 2, 2], reason: 'the answer went back in line');
      expect((stages.preparedWith.last! as UpdateRunKept).answers['Shrine'], isA<UpdateAnyway>());
      expect(find.text('This update looks like a patch'), findsOneWidget, reason: 'the open window is left as it is');
    });

    group("a mod skipped at its question while the job went on keeps that skip however the job ends", () {
      /// Job 1 for Crimson Kimono and Shrine Maiden, Shrine Maiden skipped at its question, and the job back in line.
      Future<ProviderContainer> shrineSkipped(WidgetTester t) async {
        final container = seeded([landed(1, 10, mods: [baseOf('mod1', 1), baseOf('Shrine', 1)])], library: [kimono, shrine]);
        await host(t, container);
        stages.answers(
          1,
          const UpdateStageAsks(
            UpdateWait(UpdateQuestionKind.unrecordedPatch, modId: 'Shrine'),
            prepared: UpdateRunKept(unpacked: patchUnpack),
          ),
        );
        await frames(t);
        await t.runAsync(() => skipUpdateQuestion(container, jobOf(container, 1)));
        await frames(t);
        expect(stages.prepared, [1, 1]);
        expect(jobOf(container, 1).resultFor('Shrine')?.skipReason, UpdateSkipReason.skippedByUser);
        return container;
      }

      List<String> errorTitles(ProviderContainer container) =>
          [for (final n in cards(container)) if (n.kind == NotificationKind.error) n.title];

      testWidgets('a failed stage', (t) async {
        final container = await shrineSkipped(t);
        stages.prepareFails(1, const UpdateFailure(UpdateFailureKind.unpackGone));
        await frames(t);
        final job = jobOf(container, 1);
        expect(job.state, DownloadJobState.failed);
        expect(job.resultFor('Shrine')?.skipReason, UpdateSkipReason.skippedByUser);
        expect(job.resultFor('mod1')?.end, UpdateModEnd.failed, reason: 'the other mod fails as the stage did');
        expect(errorTitles(container), ["Couldn't update Crimson Kimono"], reason: 'no failure is told for the skipped mod');
      });

      testWidgets('its first mod renamed', (t) async {
        final container = await shrineSkipped(t);
        stages.answers(1, const UpdateStageSkipped(UpdateSkipReason.folderRenamed));
        await frames(t);
        final job = jobOf(container, 1);
        expect(job.outcome, JobOutcome.skipped);
        expect(job.resultFor('Shrine')?.skipReason, UpdateSkipReason.skippedByUser, reason: 'not "a shared file not written"');
        expect(job.resultFor('mod1')?.skipReason, UpdateSkipReason.folderRenamed);
        expect(errorTitles(container), isEmpty);
      });

      testWidgets('every folder being written elsewhere at its write', (t) async {
        final container = await shrineSkipped(t);
        // Held from the real event loop, so the tear-down that lets go of them can end them.
        final holds = await t.runAsync(() async => [holdWrite(container, 'mod1'), holdWrite(container, 'Shrine')]);
        for (final hold in holds!) {
          addTearDown(hold.release);
        }
        stages.ready(1);
        await frames(t);
        final job = jobOf(container, 1);
        expect(stages.written, isEmpty);
        expect(job.outcome, JobOutcome.skipped);
        expect(job.resultFor('Shrine')?.skipReason, UpdateSkipReason.skippedByUser, reason: 'not "being changed"');
        expect(job.resultFor('mod1')?.skipReason, UpdateSkipReason.beingWritten);
        expect(errorTitles(container), isEmpty);
      });
    });

    group('the same sitting, in fake time', () {
      /// Job 1 waiting on the unrecorded-patch question, answered Update anyway from its window, all in fake time.
      Future<ProviderContainer> answeredUpdateAnyway(WidgetTester t) async {
        final container = seeded([landed(1, 10)], library: [kimono]);
        await host(t, container);
        stages.answers(
          1,
          const UpdateStageAsks(
            UpdateWait(UpdateQuestionKind.unrecordedPatch, modId: 'mod1'),
            prepared: UpdateRunKept(unpacked: patchUnpack),
          ),
        );
        await t.pump();
        unawaited(container.read(downloadQuestionsProvider).answer(1));
        await t.pump();
        await t.pump(const Duration(milliseconds: 500));
        await t.tap(find.widgetWithText(FilledButton, 'Update anyway'));
        await t.pump();
        await t.pump(const Duration(milliseconds: 500));
        expect(stages.prepared, [1, 1]);
        return container;
      }

      testWidgets('a question the answered job comes back with within 20 seconds opens at once', (t) async {
        final container = await answeredUpdateAnyway(t);
        await t.pump(const Duration(seconds: 15));
        stages.asks(1, UpdateQuestionKind.password);
        await t.pump();
        await t.pump(const Duration(milliseconds: 500));
        expect(jobOf(container, 1).state, DownloadJobState.waiting);
        expect(find.text("Enter the archive's password"), findsOneWidget);
      });

      testWidgets('one it comes back with after 20 seconds waits for its own Answer', (t) async {
        final container = await answeredUpdateAnyway(t);
        await t.pump(const Duration(seconds: 21));
        stages.asks(1, UpdateQuestionKind.password);
        await t.pump();
        await t.pump(const Duration(milliseconds: 500));
        expect(jobOf(container, 1).state, DownloadJobState.waiting);
        expect(find.text("Enter the archive's password"), findsNothing);
      });
    });

    testWidgets("the Downloads panel's Update anyway answers its row's question, with no window", (t) async {
      final container = seeded([landed(1, 10)], library: [kimono]);
      await pumpLocalized(
        t,
        DownloadQueueHost(
          installer: (context, ref, job) async => fail('nothing installs in this test'),
          asker: (context, ref, job) async => fail('nothing asks in this test'),
          updatePreparer: stages.prepare,
          updateWriter: stages.write,
          child: Align(
            alignment: Alignment.centerRight,
            child: SizedBox(width: DownloadsPanel.width, height: 1000, child: const DownloadsPanel()),
          ),
        ),
        container: container,
        surfaceSize: const Size(1200, 1100),
        settle: false,
      );
      await frames(t);
      stages.answers(
        1,
        const UpdateStageAsks(
          UpdateWait(UpdateQuestionKind.unrecordedPatch, modId: 'mod1'),
          prepared: UpdateRunKept(unpacked: patchUnpack),
        ),
      );
      await frames(t);

      await t.runAsync(() async {
        await t.tap(find.widgetWithText(OutlinedButton, 'Update anyway'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await frames(t);
      expect(find.byType(Dialog), findsNothing, reason: 'the row is the answer');
      expect(stages.prepared, [1, 1]);
      expect((stages.preparedWith.last! as UpdateRunKept).answers['mod1'], isA<UpdateAnyway>());
    });

    testWidgets('Answer on a question whose update was ignored meanwhile opens nothing and skips it', (t) async {
      late TempLibrary temp;
      await t.runAsync(() async {
        temp = await TempLibrary.create(prefix: 'zzz_update_host_');
        temp.write('mod1', 'mod1.ini', '[TextureOverrideBody]\nhash = 1\n');
        await temp.writeOrigin(
          'mod1',
          originFixture(modId: 1, modIdConfidence: OriginConfidence.exact, fileId: 5),
        );
      });
      final container = ProviderContainer(overrides: [
        downloadQueueProvider.overrideWith(() => SeededQueue([landed(1, 10, mods: [baseOf('mod1', 1, heldFileId: 5)])])),
        libraryOf([kimono]),
        ...RecordingService(temp).overrides,
      ]);
      addTearDown(container.dispose);
      container.read(downloadQueueProvider);
      container.read(modUpdateChecksProvider.notifier).state = {
        'mod1': const UpdateCheck(outcome: UpdateOutcome.updateAvailable, dismissed: true, subject: DownloadKey.base(1)),
      };
      await host(t, container);
      stages.answers(
        1,
        const UpdateStageAsks(
          UpdateWait(UpdateQuestionKind.unrecordedPatch, modId: 'mod1'),
          prepared: UpdateRunKept(unpacked: patchUnpack),
        ),
      );
      await frames(t);

      await answer(t, container, 1);
      expect(find.byType(Dialog), findsNothing, reason: 'nothing is asked about an update the user ignored');
      final job = jobOf(container, 1);
      expect(job.outcome, JobOutcome.skipped);
      expect(job.resultFor('mod1')?.skipReason, UpdateSkipReason.ignoredMeanwhile);
      expect(stages.written, isEmpty);
    });
  });
}

List<AppNotification> cards(ProviderContainer container) => container.read(notificationsProvider);

/// A Browse install whose file has landed, or at [state].
DownloadJob _browse(int seq, {DownloadJobState state = DownloadJobState.downloaded}) => DownloadJob(
      seq: seq,
      request: DownloadRequest(url: Uri.parse('https://gamebanana.com/dl/$seq')),
      intent: DownloadIntent.install,
      subject: 'Browse $seq',
      file: GbFile(idRow: seq),
      mod: GbMod(idRow: 1000 + seq, name: 'Browse $seq'),
      state: state,
      result: DownloadResult(file: File('/nonexistent/browse$seq.zip'), totalBytes: 1),
    );

/// The two stages of an update job, each run ending when the test says.
class _Stages {
  /// Every job a stage was started for, in order.
  final List<int> prepared = [];
  final List<int> written = [];

  /// What each preparation was handed as kept, in order.
  final List<Object?> preparedWith = [];

  /// The password each preparation was handed, in order.
  final List<String?> passwords = [];

  /// The folders each write was told to skip, by job.
  final Map<int, Set<String>> skips = {};

  final Map<int, Completer<UpdateStageResult>> _prepares = {};
  final Map<int, Completer<UpdateStageResult>> _writes = {};

  Future<UpdateStageResult> prepare(ProviderContainer container, DownloadJob job) {
    prepared.add(job.seq);
    preparedWith.add(job.prepared);
    passwords.add(job.password);
    return (_prepares[job.seq] = Completer<UpdateStageResult>()).future;
  }

  Future<UpdateStageResult> write(ProviderContainer container, DownloadJob job, {Set<String> skip = const {}}) {
    written.add(job.seq);
    skips[job.seq] = skip;
    return (_writes[job.seq] = Completer<UpdateStageResult>()).future;
  }

  void ready(int seq) => _prepares[seq]!.complete(const UpdateStageReady());
  void asks(int seq, UpdateQuestionKind question) => _prepares[seq]!.complete(UpdateStageAsks(UpdateWait(question)));
  void prepareFails(int seq, UpdateFailure failure) => _prepares[seq]!.complete(UpdateStageFailed(failure));

  /// The unpack ends with [result], for a question that carries what the stage keeps.
  void answers(int seq, UpdateStageResult result) => _prepares[seq]!.complete(result);

  void wrote(int seq) => _writes[seq]!.complete(const UpdateStageWritten(JobOutcome.updated));

  /// The write ends with [result], for a job of several mods.
  void writes(int seq, UpdateStageResult result) => _writes[seq]!.complete(result);
  void writeAsks(int seq, UpdateQuestionKind question) => _writes[seq]!.complete(UpdateStageAsks(UpdateWait(question)));
  void writeFails(int seq, UpdateFailure failure) => _writes[seq]!.complete(UpdateStageFailed(failure));
  void writeThrows(int seq) => _writes[seq]!.completeError(const FileSystemException('the volume went away'));
}
