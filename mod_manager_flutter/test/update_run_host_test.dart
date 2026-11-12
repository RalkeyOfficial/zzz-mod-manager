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
import 'package:mod_manager_flutter/screens/components/download_queue_host.dart';
import 'package:mod_manager_flutter/screens/dialogs/install_archive_flow.dart';
import 'package:mod_manager_flutter/services/download/download_handle.dart';
import 'package:mod_manager_flutter/services/download/download_job.dart';
import 'package:mod_manager_flutter/services/download/download_queue.dart';
import 'package:mod_manager_flutter/services/download/download_request.dart';
import 'package:mod_manager_flutter/services/download/queue_policy.dart';
import 'package:mod_manager_flutter/services/download/update_job.dart';
import 'package:mod_manager_flutter/services/log/log_format.dart';
import 'package:mod_manager_flutter/services/log/log_level.dart';
import 'package:mod_manager_flutter/services/log/log_record.dart';
import 'package:mod_manager_flutter/services/log/log_sinks.dart';
import 'package:mod_manager_flutter/services/log/logger.dart';
import 'package:mod_manager_flutter/services/update_apply/update_applier.dart' show UpdateWriteStep;
import 'package:mod_manager_flutter/services/update_apply/update_layout.dart';
import 'package:mod_manager_flutter/services/update_apply/update_prepare.dart';
import 'package:mod_manager_flutter/services/update_apply/update_run_stages.dart';
import 'package:mod_manager_flutter/services/writes_in_flight.dart';
import 'package:mod_manager_flutter/utils/notifications.dart';

import 'support/held_write.dart';
import 'support/library_override.dart';
import 'support/localized_harness.dart';
import 'support/seeded_queue.dart';
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

  setUp(() {
    stages = _Stages();
    installed = [];
    installing = null;
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

    container.read(downloadQueueProvider.notifier).answerUpdate(1, prepared: 'picked');
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
    Future<void> answer(WidgetTester t, ProviderContainer container, int seq) async {
      unawaited(container.read(downloadQuestionsProvider).answer(seq));
      await frames(t);
    }

    testWidgets('a patch-shaped file waits as Needs you with only Skip, opens nothing and is never written', (t) async {
      final container = seeded([landed(1, 10)]);
      await host(t, container);
      stages.asks(1, UpdateQuestionKind.patchShaped);
      await frames(t);

      final job = jobOf(container, 1);
      expect(cards(container).where((n) => n.kind == NotificationKind.needsYou), hasLength(1));
      expect(rowActions(job, container.read(downloadQueueProvider)), [DownloadRowAction.skipUpdate]);
      await answer(t, container, 1);
      expect(find.byType(Dialog), findsNothing);

      await t.runAsync(() => container.read(downloadQueueProvider.notifier).skipUpdate(1));
      await frames(t);
      expect(jobOf(container, 1).outcome, JobOutcome.skipped);
      expect(stages.written, isEmpty, reason: 'a patch-shaped file is never written by the update');
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
      final capture = _Capture();
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
                UpdateFolderChoice(path: '/tmp/x/PastelBurnice', name: 'PastelBurnice', looksLikeMod: true),
                UpdateFolderChoice(path: '/tmp/x/Previews', name: 'Previews', looksLikeMod: false),
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
      expect(find.text('Which folders are Pastel Burnice?'), findsOneWidget);
      await t.tap(find.widgetWithText(FilledButton, 'Update'));
      await frames(t);

      expect(stages.prepared, [1, 1]);
      final kept = stages.preparedWith.last! as UpdateRunKept;
      expect(kept.pickedFolders, ['/tmp/x/PastelBurnice']);
      expect(kept.unpacked, same(unpack), reason: 'the archive is not unpacked twice');
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
                UpdateFolderChoice(path: '/tmp/x/A', name: 'A', looksLikeMod: true),
                UpdateFolderChoice(path: '/tmp/x/B', name: 'B', looksLikeMod: true),
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

class _Capture extends LogSink {
  final records = <LogRecord>[];

  @override
  LogFormat get format => LogFormat.file;

  @override
  LogLevel get threshold => LogLevel.debug;

  @override
  void write(LogRecord record, String line) => records.add(record);
}

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
