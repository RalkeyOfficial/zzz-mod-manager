import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_file.dart';
import 'package:mod_manager_flutter/models/mod_download.dart';
import 'package:mod_manager_flutter/screens/dialogs/update_modal.dart';
import 'package:mod_manager_flutter/services/download/download_exceptions.dart';
import 'package:mod_manager_flutter/services/download/download_job.dart';
import 'package:mod_manager_flutter/services/download/download_queue.dart';
import 'package:mod_manager_flutter/services/download/download_request.dart';
import 'package:mod_manager_flutter/services/download/update_job.dart';
import 'package:mod_manager_flutter/services/update_apply/update_applier.dart' show UpdateWriteStep;
import 'package:mod_manager_flutter/services/writes_in_flight.dart';
import 'package:path/path.dart' as p;

import '../support/download_queue_rig.dart';
import '../support/seeded_queue.dart';
import '../support/update_jobs.dart';

/// An update run's jobs in the real queue (`docs/update-runs.md` §4.1, §7):
/// what a press adds, the download pool, a whole run going through the lanes, a stall, the halt and Continue, Cancel all, Try again, and the queue's half of the lanes.
/// The lanes' stages are the test's own settles, as the host's seams are.
void main() {
  late DownloadQueueRig rig;
  late ProviderContainer container;

  final body = List<int>.generate(200, (i) => i % 256);

  setUp(() {
    rig = DownloadQueueRig();
    container = rig.container();
  });

  tearDown(() {
    WritesInFlight.shared.reopenForTests();
    container.dispose();
    rig.dispose();
  });

  DownloadQueue queue() => container.read(downloadQueueProvider.notifier);
  List<DownloadJob> jobs() => container.read(downloadQueueProvider);
  DownloadJob jobOf(int seq) => jobs().firstWhere((j) => j.seq == seq);
  bool gone(int seq) => jobs().every((j) => j.seq != seq);

  /// The queue, starting from [seeded] rather than empty. A queued job it admits fetches from the rig's transport.
  DownloadQueue seed(List<DownloadJob> seeded) {
    container.dispose();
    container = rig.container([downloadQueueProvider.overrideWith(() => SeededQueue(seeded))]);
    container.read(downloadQueueProvider);
    return queue();
  }

  GbFile fileFor(int fileId, {int? size}) => GbFile(
        idRow: fileId,
        file: 'mod$fileId.zip',
        filesize: size ?? body.length,
        downloadUrl: DownloadQueueRig.urlFor(fileId).toString(),
      );

  DownloadJob? enqueueUpdate(int fileId, List<UpdateMod> mods, {int? size}) =>
      queue().enqueueUpdate(file: fileFor(fileId, size: size), subject: mods.first.modId, task: UpdateTask(mods: mods));

  /// A file that arrives as soon as it is asked for.
  void instant(int fileId) => rig.transport.enqueue(DownloadQueueRig.urlFor(fileId), body: body);

  /// The host's two lanes, run by hand: every unpack the queue hands out comes back ready, and every write written.
  /// The order the writes were claimed in goes into [written].
  void drive(List<int> written) {
    for (var moved = true; moved;) {
      moved = false;
      final unpack = queue().claimNextUpdateUnpack();
      if (unpack != null) {
        queue().settleUpdate(unpack.seq, const UpdateStageReady());
        moved = true;
      }
      final write = queue().claimNextForHost();
      if (write != null) {
        written.add(write.seq);
        queue().settleUpdate(write.seq, const UpdateStageWritten(JobOutcome.updated));
        moved = true;
      }
    }
  }

  /// Drives the lanes until every update job has ended.
  Future<void> runToTheEnd(List<int> written) => waitUntil(() {
        drive(written);
        return jobs().every((j) => !j.isUpdate || j.isTerminal);
      }, 'every update job to end');

  /// The file ids in the order their transfers started.
  List<int> started() => [for (final url in rig.transport.requests) int.parse(url.pathSegments.last)];

  group('what a press adds', () {
    test('a second press for a layer already in the run adds nothing', () {
      rig.controlled(1);
      final first = enqueueUpdate(1, [baseOf('Ellen', 1)])!;
      expect(enqueueUpdate(2, [baseOf('Ellen', 1)]), isNull);
      expect(jobs(), hasLength(1));
      expect(first.intent, DownloadIntent.update);
    });

    test("Update N's second press for the same mod adds nothing, whichever newer file it picks", () {
      rig.controlled(1);
      final ellen = ModInfo(id: 'Ellen', name: 'Ellen', characterId: 'ellen', isActive: false, uid: 'u1');
      UpdatePick pick(int fileId) =>
          UpdatePick(modId: 'Ellen', file: fileFor(fileId), subject: const DownloadKey.base(100), published: const []);

      expect(queue().enqueueUpdates([updateEnqueueOf(pick(1), ellen)]).single, isNotNull);
      expect(queue().enqueueUpdates([updateEnqueueOf(pick(1), ellen)]).single, isNull);
      expect(queue().enqueueUpdates([updateEnqueueOf(pick(2), ellen)]).single, isNull);
      expect(jobs(), hasLength(1));
    });

    test('another layer of the same folder is a job of its own', () {
      rig.controlled(1);
      enqueueUpdate(1, [baseOf('Ellen', 1)]);
      expect(enqueueUpdate(2, [patchOf('Ellen', 2)]), isNotNull);
      expect(jobs(), hasLength(2));
    });

    test('mods picked with the same file are one job, written in the order picked', () {
      rig.controlled(1);
      final job = enqueueUpdate(1, [baseOf('Ellen', 1), baseOf('Ellen Alt', 2)])!;
      expect(enqueueUpdate(1, [baseOf('Ellen Swim', 3)])?.seq, job.seq);
      expect(jobs(), hasLength(1));
      expect(jobOf(job.seq).update!.mods.map((m) => m.modId), ['Ellen', 'Ellen Alt', 'Ellen Swim']);
    });

    test('a pick for a file a Browse download holds adds nothing', () {
      rig.controlled(1);
      queue().enqueue(file: fileFor(1), subject: 'Ellen', intent: DownloadIntent.install);
      expect(enqueueUpdate(1, [baseOf('Ellen', 1)]), isNull);
    });

    test('a pick for a file whose job has been unpacked adds nothing, since it could not join that unpack', () {
      seed([updateJob(1, state: DownloadJobState.updating, step: UpdateStep.unpacked)]);
      expect(enqueueUpdate(1, [baseOf('Lycaon', 7)]), isNull);
    });

    test('a press asks for its bases before its patches, whatever order they came in', () {
      rig.controlled(1);
      rig.controlled(2);
      final added = queue().enqueueUpdates([
        UpdateEnqueue(file: fileFor(1), subject: 'patch', task: UpdateTask(mods: [patchOf('Ellen', 1)])),
        UpdateEnqueue(file: fileFor(2), subject: 'base', task: UpdateTask(mods: [baseOf('Ellen', 2)])),
      ]);
      expect(added[1]!.seq, lessThan(added[0]!.seq));
    });

    test('a job added while the run is halted is held by the same halt', () {
      final seeded = seed([
        updateJob(101, state: DownloadJobState.updating, step: UpdateStep.writing),
        updateJob(102),
      ]);
      seeded.settleUpdate(101, const UpdateStageFailed(UpdateFailure(UpdateFailureKind.noSpace)));
      final added = enqueueUpdate(3, [baseOf('Nicole', 3)])!;
      expect(added.seq, greaterThan(102), reason: 'a new job is numbered above the seeded ones');
      expect(added.halt?.bySeq, 101);
      expect(jobOf(added.seq).state, DownloadJobState.queued, reason: 'not admitted while halted');
    });
  });

  group('the download pool', () {
    test('three update downloads beside two Browse downloads, smallest first, and none of them pauses', () async {
      for (var i = 1; i <= 6; i++) {
        rig.controlled(i);
      }
      queue().enqueue(file: fileFor(1), subject: 'browse 1', intent: DownloadIntent.install);
      queue().enqueue(file: fileFor(2), subject: 'browse 2', intent: DownloadIntent.install);
      // One press, its first pick the largest.
      queue().enqueueUpdates([
        for (final (fileId, size) in [(3, 300), (4, 20), (5, 80), (6, 40)])
          UpdateEnqueue(
            file: fileFor(fileId, size: size),
            subject: 'mod $fileId',
            task: UpdateTask(mods: [baseOf('mod$fileId', fileId)]),
          ),
      ]);
      await settle();
      final running = [for (final j in jobs()) if (j.state == DownloadJobState.running) j.seq];
      expect(running, unorderedEquals([1, 2, 4, 5, 6]), reason: 'the 300 one waits');
      expect(jobOf(4).pausable, isFalse);

      await queue().pause(4);
      expect(jobOf(4).state, DownloadJobState.running, reason: 'an update run has no Pause');
    });

    test('a stalled transfer goes to the end of the line once, and fails the second time', () async {
      rig.stallTimeout = const Duration(milliseconds: 100);
      rig.controlled(1);
      rig.controlled(1);
      final job = enqueueUpdate(1, [baseOf('Ellen', 1)])!;
      await waitUntil(() => jobOf(job.seq).stalled, 'the first stall');
      expect(jobOf(job.seq).deferred, isTrue);
      expect(jobOf(job.seq).state, isNot(DownloadJobState.failed));

      await waitUntil(() => jobOf(job.seq).state == DownloadJobState.failed, 'the second stall');
      expect(jobOf(job.seq).error, isA<DownloadStalledException>());
      expect(jobs().where((j) => j.halt != null), isEmpty, reason: 'a stall is one node, not the disk');
    });

    test('a job tried again goes to the end of the line and has its own stall to spare', () async {
      rig.stallTimeout = const Duration(milliseconds: 100);
      for (var i = 0; i < 4; i++) {
        rig.controlled(1);
      }
      final job = enqueueUpdate(1, [baseOf('Ellen', 1)])!;
      await waitUntil(() => jobOf(job.seq).state == DownloadJobState.failed, 'two stalls');

      queue().retry(job.seq);
      expect(jobOf(job.seq).deferred, isTrue);
      expect(jobOf(job.seq).stalled, isFalse);
      await waitUntil(() => jobOf(job.seq).stalled, 'the retried job stalls once');
      expect(jobOf(job.seq).state, isNot(DownloadJobState.failed), reason: 'its first stall sends it to the end again');
    });
  });

  group('a whole run through the lanes', () {
    test('the five-mod picture and a 1.2 GB file: every job is admitted, smallest first, the large one alone', () async {
      final sizes = {1: 1229, 2: 300, 3: 20, 4: 200, 5: 80, 6: 40};
      sizes.keys.forEach(instant);
      final starts = <int, Set<int>>{};
      container.listen(downloadQueueProvider, (_, next) {
        for (final job in next) {
          if (job.state == DownloadJobState.running && !starts.containsKey(job.seq)) {
            starts[job.seq] = {
              for (final other in next)
                if (other.seq != job.seq && other.isUpdate && !other.isTerminal && other.state != DownloadJobState.queued)
                  other.seq,
            };
          }
        }
      });
      queue().enqueueUpdates([
        for (final MapEntry(key: id, value: size) in sizes.entries)
          UpdateEnqueue(file: fileFor(id, size: size * mb), subject: 'mod $id', task: UpdateTask(mods: [baseOf('mod$id', id)])),
      ]);

      final written = <int>[];
      await runToTheEnd(written);

      expect([for (final seq in starts.keys) sizes[jobOf(seq).file.idRow]], [20, 40, 80, 200, 300, 1229],
          reason: 'the order the queue admitted them in');
      expect(written, hasLength(6));
      expect(jobs().every((j) => j.outcome == JobOutcome.updated), isTrue);
      expect(starts[1], isEmpty, reason: 'the 1.2 GB file runs with nothing else ahead');
    });

    test('a job that ends frees its place, and the next queued one starts', () async {
      rig.controlled(4);
      final seeded = seed([
        updateJob(1, state: DownloadJobState.updating, step: UpdateStep.writing),
        updateJob(2, state: DownloadJobState.updating, step: UpdateStep.unpacked),
        updateJob(3, state: DownloadJobState.downloaded),
        updateJob(4),
      ]);
      expect(jobOf(4).state, DownloadJobState.queued, reason: 'three are ahead');
      seeded.settleUpdate(1, const UpdateStageWritten(JobOutcome.updated));
      expect(jobOf(4).state, DownloadJobState.running);
    });

    test('a base over 1 GiB with its patch: the base first, the patch after it, and nothing is stuck', () async {
      instant(1);
      instant(2);
      queue().enqueueUpdates([
        UpdateEnqueue(file: fileFor(1, size: 150 * mb), subject: 'patch', task: UpdateTask(mods: [patchOf('Ellen', 1)])),
        UpdateEnqueue(file: fileFor(2, size: 900 * mb), subject: 'base', task: UpdateTask(mods: [baseOf('Ellen', 2)])),
      ]);
      final written = <int>[];
      await runToTheEnd(written);
      expect(started(), [2, 1]);
      expect([for (final seq in written) jobOf(seq).update!.primary.isPatchLayer], [false, true]);
    });

    test('Try again on a base while its patch is unpacked: the base is written first, and the run goes on', () async {
      instant(101);
      final seeded = seed([
        updateJob(101, state: DownloadJobState.failed, size: 50 * mb, mods: [baseOf('Ellen', 101)])
            .copyWith(error: const DownloadNetworkException('reset')),
        updateJob(102, state: DownloadJobState.updating, step: UpdateStep.unpacked, mods: [patchOf('Ellen', 102)]),
        updateJob(103, state: DownloadJobState.downloaded, mods: [baseOf('Lycaon', 103)]),
      ]);
      seeded.retry(101);
      final written = <int>[];
      await runToTheEnd(written);
      expect(written.indexOf(101), lessThan(written.indexOf(102)), reason: 'base before patch');
      expect(written, containsAll([101, 102, 103]));
    });
  });

  group('the halt', () {
    test('no room for a download stops the run, and Continue lets it go on', () async {
      final first = rig.controlled(1, contentLength: body.length);
      enqueueUpdate(1, [baseOf('Ellen', 1)]);
      await waitUntil(() => rig.transport.requests.isNotEmpty, 'the first transfer past its own space check');

      rig.freeSpace = 1;
      instant(2);
      enqueueUpdate(2, [baseOf('Lycaon', 2)]);
      await waitUntil(() => jobOf(2).state == DownloadJobState.failed, 'the refusal for space');
      expect(jobOf(2).error, isA<InsufficientSpaceException>());
      expect(jobOf(1).halt?.bySeq, 2, reason: 'the transfer under way finishes, held');

      rig.freeSpace = 1 << 40;
      first.add(body);
      unawaited(first.close());
      await waitUntil(() => jobOf(1).state == DownloadJobState.downloaded, 'the first to land');
      expect(queue().claimNextUpdateUnpack(), isNull);

      queue().continueUpdates();
      expect(queue().claimNextUpdateUnpack()?.seq, 1);
    });

    test('a failure every later job shares holds every job of the run that has not ended', () {
      rig.controlled(102);
      final seeded = seed([
        updateJob(101, state: DownloadJobState.updating, step: UpdateStep.writing),
        updateJob(102),
        updateJob(103, state: DownloadJobState.downloaded),
        updateJob(104, state: DownloadJobState.waiting),
        updateJob(105, state: DownloadJobState.updating, step: UpdateStep.unpacking),
      ]);
      seeded.settleUpdate(
        101,
        const UpdateStageFailed(UpdateFailure(UpdateFailureKind.noSpace, requiredBytes: 10, availableBytes: 2)),
      );
      expect(jobOf(101).state, DownloadJobState.failed);
      for (final seq in [102, 103, 104, 105]) {
        expect(jobOf(seq).halt?.bySeq, 101, reason: 'job $seq');
        expect((jobOf(seq).halt?.cause as UpdateFailure?)?.kind, UpdateFailureKind.noSpace);
      }
      expect(container.read(updateRunSummaryProvider).halt?.bySeq, 101);

      seeded.settleUpdate(105, const UpdateStageReady());
      expect(seeded.claimNextForHost(), isNull, reason: 'held back from the write');
      expect(seeded.claimNextUpdateUnpack(), isNull, reason: 'and from the unpack');

      seeded.continueUpdates();
      expect(jobs().every((j) => j.halt == null), isTrue);
      expect(seeded.claimNextForHost()?.seq, 105);
    });

    test("a failure of one mod's own stops nothing else", () {
      final seeded = seed([
        updateJob(101, state: DownloadJobState.updating, step: UpdateStep.unpacking),
        updateJob(102, state: DownloadJobState.downloaded),
      ]);
      seeded.settleUpdate(101, const UpdateStageFailed(UpdateFailure(UpdateFailureKind.unpackFailed)));
      expect(jobs().every((j) => j.halt == null), isTrue);
      expect(seeded.claimNextUpdateUnpack()?.seq, 102);
    });

    for (final over in ['every halted job ended', 'Cancel all']) {
      test('a job that failed while halted takes no halt into its Try again once the halt is over ($over)', () async {
        seed([
          updateJob(101, state: DownloadJobState.updating, step: UpdateStep.writing),
          if (over == 'Cancel all') updateJob(103, state: DownloadJobState.updating, step: UpdateStep.unpacking),
        ]);
        final transfer = rig.controlled(2, contentLength: 1000);
        final job = enqueueUpdate(2, [baseOf('B', 2)], size: 1000)!;
        await waitUntil(() => jobOf(job.seq).state == DownloadJobState.running, 'the transfer to start');

        queue().settleUpdate(101, const UpdateStageFailed(UpdateFailure(UpdateFailureKind.noSpace)));
        expect(jobOf(job.seq).halt?.bySeq, 101, reason: 'held while it downloads');

        transfer.addError(const SocketException('reset'));
        await waitUntil(() => jobOf(job.seq).isTerminal, 'the transfer to fail');
        expect(jobOf(job.seq).halt, isNull, reason: 'an ended job keeps no halt');

        if (over == 'Cancel all') {
          await queue().cancelAllUpdates();
          queue().settleUpdate(103, const UpdateStageReady());
        }
        expect(container.read(updateRunSummaryProvider).halt, isNull);
        expect(jobs().where((j) => j.halt != null), isEmpty);

        rig.controlled(2);
        queue().retry(job.seq);
        expect(jobOf(job.seq).halt, isNull, reason: 'nothing is halted now');
        expect(container.read(updateRunSummaryProvider).halt, isNull);

        rig.controlled(7);
        final pressed = enqueueUpdate(7, [baseOf('Nicole', 7)])!;
        expect(pressed.halt, isNull);
        expect(jobOf(pressed.seq).state, DownloadJobState.running, reason: 'the run is not stopped');
      });
    }

    test('Continue leaves no halt on any job of the list, ended ones included', () {
      final seeded = seed([
        updateJob(101, state: DownloadJobState.updating, step: UpdateStep.writing),
        updateJob(102, state: DownloadJobState.downloaded),
      ]);
      seeded.settleUpdate(101, const UpdateStageFailed(UpdateFailure(UpdateFailureKind.noSpace)));
      seeded.continueUpdates();
      expect(jobs().where((j) => j.halt != null), isEmpty);
    });

    test('Try again during a halt is held by it, so it does not write onto a full disk', () {
      final seeded = seed([
        updateJob(101, state: DownloadJobState.failed).copyWith(error: const DownloadNetworkException('reset')),
        updateJob(102, state: DownloadJobState.updating, step: UpdateStep.writing),
        updateJob(103),
      ]);
      seeded.settleUpdate(102, const UpdateStageFailed(UpdateFailure(UpdateFailureKind.noSpace)));
      seeded.retry(101);
      expect(jobOf(101).halt?.bySeq, 102, reason: 'the halt is live, held by job 103');
      expect(jobOf(101).state, DownloadJobState.queued, reason: 'not admitted');
    });
  });

  group('Cancel all', () {
    test('stops every job that can stop in one change, and an unpack in flight is deleted when it lands', () async {
      final seen = <List<int>>[];
      final seeded = seed([
        updateJob(101, state: DownloadJobState.updating, step: UpdateStep.writing),
        updateJob(102, state: DownloadJobState.updating, step: UpdateStep.unpacking),
        updateJob(103, state: DownloadJobState.updating, step: UpdateStep.unpacked),
        updateJob(104, state: DownloadJobState.downloaded),
        updateJob(105, state: DownloadJobState.waiting),
        updateJob(106),
        updateJob(107, state: DownloadJobState.done),
      ]);
      container.listen(downloadQueueProvider, (_, next) => seen.add([for (final j in next) j.seq]));
      await seeded.cancelAllUpdates();
      expect(seen.first, [101, 102, 107], reason: 'one change, and no job claimed or started between');

      seeded.settleUpdate(102, const UpdateStageReady());
      expect(gone(102), isTrue, reason: 'it lands and is not written');
      expect(seeded.claimNextForHost(), isNull);

      seeded.settleUpdate(101, const UpdateStageWritten(JobOutcome.updated));
      expect(jobOf(101).outcome, JobOutcome.updated, reason: 'a write in flight ends as it ends');
    });

    test('ends the halt: nothing is held, and the next press runs', () async {
      final seeded = seed([
        updateJob(101, state: DownloadJobState.updating, step: UpdateStep.writing),
        updateJob(102, state: DownloadJobState.updating, step: UpdateStep.unpacking),
        updateJob(103),
      ]);
      seeded.settleUpdate(101, const UpdateStageFailed(UpdateFailure(UpdateFailureKind.noSpace)));
      expect(container.read(updateRunSummaryProvider).halt, isNotNull);

      await seeded.cancelAllUpdates();
      expect(container.read(updateRunSummaryProvider).halt, isNull);
      seeded.settleUpdate(102, const UpdateStageFailed(UpdateFailure(UpdateFailureKind.noSpace)));
      expect(container.read(updateRunSummaryProvider).halt, isNull, reason: 'a cancelled job halts nothing');

      rig.controlled(7);
      final added = enqueueUpdate(7, [baseOf('Nicole', 7)])!;
      expect(added.halt, isNull);
      expect(jobOf(added.seq).state, DownloadJobState.running);
    });
  });

  group('the ends of a job', () {
    test('Skip at a question leaves the row as skipped; Cancel takes it off the list', () async {
      final seeded = seed([
        updateJob(1, state: DownloadJobState.waiting),
        updateJob(2, state: DownloadJobState.waiting),
      ]);
      await seeded.skipUpdate(1);
      expect(jobOf(1).outcome, JobOutcome.skipped);
      expect(jobOf(1).skipReason, UpdateSkipReason.skippedByUser);
      expect(jobOf(1).resultFor('mod1')?.skipReason, UpdateSkipReason.skippedByUser);
      await seeded.cancel(2);
      expect(gone(2), isTrue);
    });

    test('an undone row stays, and Clear finished takes finished rows away', () {
      final seeded = seed([updateJob(1, state: DownloadJobState.updating, step: UpdateStep.writing)]);
      seeded.settleUpdate(1, const UpdateStageWritten(JobOutcome.updated));
      expect(jobOf(1).installed, ['mod1']);
      seeded.markUndone(1);
      expect(jobOf(1).outcome, JobOutcome.undone);
      seeded.clearFinished();
      expect(gone(1), isTrue);
    });

    test("the Updates page's Clear finished takes only the run's finished rows", () {
      final seeded = seed([
        updateJob(1, state: DownloadJobState.done),
        updateJob(2, state: DownloadJobState.waiting),
        DownloadJob(
          seq: 3,
          request: DownloadRequest(url: Uri.parse('https://gamebanana.com/dl/3')),
          intent: DownloadIntent.install,
          subject: 'Browse 3',
          file: GbFile(idRow: 3),
          state: DownloadJobState.done,
        ),
      ]);
      seeded.clearFinished(updatesOnly: true);
      expect([for (final j in jobs()) j.seq], [2, 3]);
    });

    test('neither Clear finished takes a failed update, which only Remove from the list does', () {
      final seeded = seed([
        updateJob(1, state: DownloadJobState.failed),
        updateJob(2, state: DownloadJobState.done),
        DownloadJob(
          seq: 3,
          request: DownloadRequest(url: Uri.parse('https://gamebanana.com/dl/3')),
          intent: DownloadIntent.install,
          subject: 'Browse 3',
          file: GbFile(idRow: 3),
          state: DownloadJobState.failed,
        ),
      ]);
      seeded.clearFinished(updatesOnly: true);
      expect([for (final j in jobs()) j.seq], [1, 3]);
      seeded.clearFinished();
      expect([for (final j in jobs()) j.seq], [1], reason: 'a failed download is a Finished row, cleared as before');
      seeded.remove(1);
      expect(jobs(), isEmpty);
    });

    test('a writing job carries the part of its write that has started, and a new write starts without one', () {
      final seeded = seed([updateJob(1, state: DownloadJobState.updating, step: UpdateStep.writing)]);
      seeded.reportWriteStep(1, const UpdateWriting('mod1', UpdateWriteStep.replacingFiles));
      expect(jobOf(1).writing?.step, UpdateWriteStep.replacingFiles);

      seeded.settleUpdate(1, const UpdateStageAsks(UpdateWait(UpdateQuestionKind.unrecordedPatch)));
      seeded.reportWriteStep(1, const UpdateWriting('mod1', UpdateWriteStep.linking));
      expect(jobOf(1).writing?.step, UpdateWriteStep.replacingFiles, reason: 'only a writing job takes a step');
    });

    test('a job that ends before its unpack deletes its archive; one that could not be unpacked keeps it', () async {
      File archive(String name) => File(p.join(rig.temp.path, name))..writeAsStringSync('bytes');
      final gone = archive('gone.zip');
      final broken = archive('broken.zip');
      final seeded = seed([
        updateJob(1, state: DownloadJobState.updating, step: UpdateStep.unpacking, archive: gone),
        updateJob(2, state: DownloadJobState.updating, step: UpdateStep.unpacking, archive: broken),
      ]);
      seeded.settleUpdate(1, const UpdateStageSkipped(UpdateSkipReason.modGone));
      seeded.settleUpdate(2, const UpdateStageFailed(UpdateFailure(UpdateFailureKind.unpackFailed)));
      await waitUntil(() => !gone.existsSync(), 'the skipped job\'s archive to go');
      expect(broken.existsSync(), isTrue, reason: 'kept, as an install keeps one it could not unpack');
    });

    test('an answered question goes back to the unpack lane ahead of the jobs that have not waited', () {
      final seeded = seed([
        updateJob(1, state: DownloadJobState.downloaded),
        updateJob(2, state: DownloadJobState.waiting).withUpdateWait(const UpdateWait(UpdateQuestionKind.password)),
      ]);
      seeded.answerUpdate(2, asking: 0, prepared: 'the answer', password: 'secret');
      expect(jobOf(2).state, DownloadJobState.downloaded);
      expect(jobOf(2).hasWaited, isTrue);
      expect(jobOf(2).password, 'secret');
      final claimed = seeded.claimNextUpdateUnpack();
      expect(claimed?.seq, 2);
      expect(claimed?.prepared, 'the answer');

      seeded.settleUpdate(2, const UpdateStageReady());
      expect(jobOf(2).password, isNull, reason: 'a password goes once the unpack it was given for has run');
    });

    test('a question at the write leaves the install lane and keeps its place under the lookahead', () {
      final seeded = seed([updateJob(1, state: DownloadJobState.updating, step: UpdateStep.writing)]);
      seeded.settleUpdate(1, const UpdateStageAsks(UpdateWait(UpdateQuestionKind.folders)));
      expect(jobOf(1).state, DownloadJobState.waiting);
      expect(jobOf(1).updateWait?.question, UpdateQuestionKind.folders);
      expect(container.read(updateRunSummaryProvider).asking, 1);
      expect(container.read(updateJobOfModProvider('mod1'))?.job.seq, 1);
    });

    test("a mod's row is not told about a change to another job, and is told about one to its own", () {
      final seeded = seed([
        updateJob(1, state: DownloadJobState.updating, step: UpdateStep.unpacked),
        updateJob(2, state: DownloadJobState.updating, step: UpdateStep.writing),
      ]);
      final before = container.read(updateJobOfModProvider('mod1'));

      seeded.reportWriteStep(2, const UpdateWriting('mod2', UpdateWriteStep.replacingFiles));
      expect(container.read(updateJobOfModProvider('mod1')), before, reason: 'equal, so its row is not rebuilt');
      seeded.settleUpdate(1, const UpdateStageAsks(UpdateWait(UpdateQuestionKind.unrecordedPatch)));
      expect(container.read(updateJobOfModProvider('mod1')), isNot(before));
    });

    test('an answer or a Skip given to another question than the one the job waits on changes nothing', () async {
      final seeded = seed([
        updateJob(1, state: DownloadJobState.waiting).withUpdateWait(const UpdateWait(UpdateQuestionKind.password, asking: 2)),
      ]);
      expect(seeded.answerUpdate(1, asking: 1, password: 'secret'), isFalse);
      await seeded.skipUpdate(1, asking: 1);
      expect(jobOf(1).state, DownloadJobState.waiting);
      expect(jobOf(1).updateWait?.asking, 2);
      expect(jobOf(1).password, isNull);
      expect(jobOf(1).modResults, isEmpty);

      expect(seeded.answerUpdate(1, asking: 2, password: 'secret'), isTrue, reason: 'the question it does wait on');
      expect(jobOf(1).state, DownloadJobState.downloaded);
    });

    test('a mod skipped at its question while its job went on keeps that skip however the job ends', () async {
      for (final end in [
        const UpdateStageFailed(UpdateFailure(UpdateFailureKind.unpackGone)) as UpdateStageResult,
        const UpdateStageSkipped(UpdateSkipReason.modGone),
        UpdateStageSkipped(
          UpdateSkipReason.beingWritten,
          results: [for (final id in ['P', 'S']) UpdateModResult.skipped(baseOf(id, 1), UpdateSkipReason.beingWritten)],
        ),
      ]) {
        final mods = [baseOf('P', 1), baseOf('S', 1)];
        final seeded = seed([
          updateJob(1, state: DownloadJobState.waiting, mods: mods)
              .withUpdateWait(const UpdateWait(UpdateQuestionKind.patchShaped, modId: 'S')),
        ]);
        expect(
          seeded.answerUpdate(1, asking: 0, skipping: UpdateModResult.skipped(mods[1], UpdateSkipReason.skippedByUser)),
          isTrue,
        );
        expect(seeded.claimNextUpdateUnpack()?.seq, 1);
        seeded.settleUpdate(1, end);

        final job = jobOf(1);
        final s = job.resultFor('S')!;
        expect((s.end, s.skipReason), (UpdateModEnd.skipped, UpdateSkipReason.skippedByUser), reason: '$end');
        final p = job.resultFor('P')!;
        expect(
          (p.end, p.skipReason),
          switch (end) {
            UpdateStageFailed() => (UpdateModEnd.failed, null),
            UpdateStageSkipped(:final reason) => (UpdateModEnd.skipped, reason),
            _ => fail('$end'),
          },
          reason: 'the other mod ends as the stage said',
        );
      }
    });

    /// Job 1 for P and S, waiting on a question about [about], skipped there by the user, and claimed by the unpack lane again.
    DownloadQueue skippedAt(String about) {
      final mods = [baseOf('P', 1), baseOf('S', 1)];
      final seeded = seed([
        updateJob(1, state: DownloadJobState.waiting, mods: mods)
            .withUpdateWait(UpdateWait(UpdateQuestionKind.patchShaped, modId: about)),
      ]);
      final skipped = mods.firstWhere((m) => m.modId == about);
      expect(seeded.answerUpdate(1, asking: 0, skipping: UpdateModResult.skipped(skipped, UpdateSkipReason.skippedByUser)), isTrue);
      expect(seeded.claimNextUpdateUnpack()?.seq, 1);
      return seeded;
    }

    test("a job its stage skips as a whole takes its first mod's reason, here the user's Skip of it", () {
      skippedAt('P').settleUpdate(1, const UpdateStageSkipped(UpdateSkipReason.beingWritten));
      expect(jobOf(1).skipReason, UpdateSkipReason.skippedByUser);
      expect(jobOf(1).resultFor('S')?.skipReason, UpdateSkipReason.sharedFileNotWritten);
    });

    test("a job its stage skips as a whole takes the stage's reason when its first mod has none", () {
      final seeded = seed([updateJob(1, state: DownloadJobState.updating, step: UpdateStep.unpacking)]);
      seeded.settleUpdate(
        1,
        UpdateStageSkipped(
          UpdateSkipReason.beingWritten,
          results: [UpdateModResult(baseOf('mod1', 1), UpdateModEnd.refused, failure: const UpdateFailure(UpdateFailureKind.refused))],
        ),
      );
      expect(jobOf(1).resultFor('mod1')?.skipReason, isNull);
      expect(jobOf(1).skipReason, UpdateSkipReason.beingWritten);
    });

    test("the user's Skip of a mod wins over what the stage finds about it later: already updated, or ignored meanwhile", () {
      for (final end in [
        UpdateStageWritten(JobOutcome.updated, results: [
          UpdateModResult.written(baseOf('P', 1)),
          UpdateModResult.skipped(baseOf('S', 1), UpdateSkipReason.alreadyUpdated),
        ]) as UpdateStageResult,
        UpdateStageSkipped(UpdateSkipReason.ignoredMeanwhile, results: [
          UpdateModResult.skipped(baseOf('P', 1), UpdateSkipReason.ignoredMeanwhile),
          UpdateModResult.skipped(baseOf('S', 1), UpdateSkipReason.ignoredMeanwhile),
        ]),
      ]) {
        skippedAt('S').settleUpdate(1, end);
        final s = jobOf(1).resultFor('S')!;
        expect((s.end, s.skipReason), (UpdateModEnd.skipped, UpdateSkipReason.skippedByUser), reason: '$end');
      }
    });

    test('Skip with a reason of its own leaves the row skipped for it', () async {
      final seeded = seed([updateJob(1, state: DownloadJobState.waiting)]);
      await seeded.skipUpdate(1, reason: UpdateSkipReason.modGone);
      expect(jobOf(1).skipReason, UpdateSkipReason.modGone);
      expect(jobOf(1).resultFor('mod1')?.skipReason, UpdateSkipReason.modGone);
    });
  });

  group('closing', () {
    test('once the app is closing, no install and no update starts its write, and nothing is unpacked', () {
      final seeded = seed([
        updateJob(1, state: DownloadJobState.updating, step: UpdateStep.unpacked),
        updateJob(2, state: DownloadJobState.downloaded),
      ]);
      WritesInFlight.shared.close();
      expect(seeded.claimNextForHost(), isNull);
      expect(seeded.claimNextUpdateUnpack(), isNull);

      WritesInFlight.shared.reopenForTests();
      expect(seeded.claimNextForHost()?.seq, 1);
    });

    test('a claim made from inside a tracked write is held back too', () async {
      final seeded = seed([updateJob(1, state: DownloadJobState.updating, step: UpdateStep.unpacked)]);
      DownloadJob? claimed;
      await WritesInFlight.shared.track(() async {
        WritesInFlight.shared.close();
        claimed = seeded.claimNextForHost();
      });
      expect(claimed, isNull);
    });
  });
}
