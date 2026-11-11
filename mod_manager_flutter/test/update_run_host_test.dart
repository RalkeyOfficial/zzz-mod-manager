import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_file.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_mod.dart';
import 'package:mod_manager_flutter/models/install_result.dart';
import 'package:mod_manager_flutter/screens/components/download_queue_host.dart';
import 'package:mod_manager_flutter/screens/dialogs/install_archive_flow.dart';
import 'package:mod_manager_flutter/services/download/download_handle.dart';
import 'package:mod_manager_flutter/services/download/download_job.dart';
import 'package:mod_manager_flutter/services/download/download_queue.dart';
import 'package:mod_manager_flutter/services/download/download_request.dart';
import 'package:mod_manager_flutter/services/download/queue_policy.dart';
import 'package:mod_manager_flutter/services/download/update_job.dart';
import 'package:mod_manager_flutter/services/writes_in_flight.dart';

import 'support/held_write.dart';
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

  ProviderContainer seeded(List<DownloadJob> jobs) {
    final container = ProviderContainer(overrides: [downloadQueueProvider.overrideWith(() => SeededQueue(jobs))]);
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
}

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

  /// The folders each write was told to skip, by job.
  final Map<int, Set<String>> skips = {};

  final Map<int, Completer<UpdateStageResult>> _prepares = {};
  final Map<int, Completer<UpdateStageResult>> _writes = {};

  Future<UpdateStageResult> prepare(ProviderContainer container, DownloadJob job) {
    prepared.add(job.seq);
    preparedWith.add(job.prepared);
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

  void wrote(int seq) => _writes[seq]!.complete(const UpdateStageWritten(JobOutcome.updated));
  void writeAsks(int seq, UpdateQuestionKind question) => _writes[seq]!.complete(UpdateStageAsks(UpdateWait(question)));
  void writeFails(int seq, UpdateFailure failure) => _writes[seq]!.complete(UpdateStageFailed(failure));
  void writeThrows(int seq) => _writes[seq]!.completeError(const FileSystemException('the volume went away'));
}
