import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_file.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_mod.dart';
import 'package:mod_manager_flutter/services/download/download_job.dart';
import 'package:mod_manager_flutter/services/download/download_progress.dart';
import 'package:mod_manager_flutter/services/download/download_request.dart';
import 'package:mod_manager_flutter/services/download/queue_policy.dart';

/// The queue's decisions, with no queue, no network and no clock.
///
/// These are the parts that decide *what runs* and *what the user is offered*,
/// which is where a queue goes quietly wrong: a cap that leaks, a slot that is
/// never released, a retry button on a job that is still running.
void main() {
  var nextSeq = 0;

  DownloadJob job({
    DownloadJobState state = DownloadJobState.queued,
    DownloadIntent intent = DownloadIntent.install,
    int? fileId,
    int? expectedSize,
    int? received,
    int? total,
    double? rate,
    Object? error,
    bool resumed = false,
    Object? prepared,
    InstallWait? wait,
    GbMod? mod,
    JobOutcome? outcome,
    List<String> installed = const [],
  }) {
    final seq = ++nextSeq;
    return DownloadJob(
      seq: seq,
      request: DownloadRequest(
        url: Uri.parse('https://gamebanana.com/dl/${fileId ?? seq}'),
        expectedSize: expectedSize,
      ),
      intent: intent,
      subject: 'mod $seq',
      file: GbFile(idRow: fileId ?? seq),
      mod: mod,
      state: state,
      error: error,
      resumed: resumed,
      prepared: prepared,
      wait: wait,
      outcome: outcome,
      installed: installed,
      progress: received == null && rate == null
          ? null
          : DownloadProgress(
              state: DownloadState.downloading,
              received: received ?? 0,
              total: total,
              bytesPerSecond: rate,
            ),
    );
  }

  setUp(() => nextSeq = 0);

  group('admissions', () {
    test('starts up to the cap and no further', () {
      final jobs = [job(), job(), job()];
      expect(admissions(jobs, concurrency: 2).map((j) => j.seq), [1, 2]);
    });

    test('counts what is already running against the cap', () {
      final jobs = [job(state: DownloadJobState.running), job(), job()];
      expect(admissions(jobs, concurrency: 2).map((j) => j.seq), [2]);
    });

    test('an install does not hold a slot', () {
      // The whole reason `holdsConnection` is narrower than `isActive`: an
      // unpack is disk and CPU, and idling the network behind one would make a
      // queue slower than no queue.
      final jobs = [
        job(state: DownloadJobState.installing),
        job(state: DownloadJobState.downloaded),
        job(),
        job(),
      ];
      expect(admissions(jobs, concurrency: 2).map((j) => j.seq), [3, 4]);
    });

    test('a foreground job is never blocked by the cap', () {
      // The modal dialog it runs behind covers the panel, so parking it would
      // leave the user watching "waiting for a slot" with no way to reach the
      // transfers they would have to cancel.
      final jobs = [
        job(state: DownloadJobState.running),
        job(state: DownloadJobState.running),
        job(intent: DownloadIntent.callerHandles),
      ];
      expect(admissions(jobs, concurrency: 2).map((j) => j.seq), [3]);
    });

    test('but it still closes the door behind it', () {
      final jobs = [
        job(state: DownloadJobState.running),
        job(intent: DownloadIntent.callerHandles),
        job(),
      ];
      // Admitting the foreground job takes the count to 2, so the background
      // one behind it waits — the exemption is a bypass on the way in, not a
      // permanently raised ceiling.
      expect(admissions(jobs, concurrency: 2).map((j) => j.seq), [2]);
    });

    test('terminal jobs free their slot', () {
      final jobs = [
        job(state: DownloadJobState.done),
        job(state: DownloadJobState.failed),
        job(),
      ];
      expect(admissions(jobs, concurrency: 2).map((j) => j.seq), [3]);
    });

    test('a paused job holds no slot and is never started by itself', () {
      final jobs = [job(state: DownloadJobState.paused), job(state: DownloadJobState.running), job()];
      expect(admissions(jobs, concurrency: 2).map((j) => j.seq), [3]);
    });

    test('a resumed job goes first of the queued ones', () {
      // A retry keeps its seq, so a queued job can be older than the one the user paused and resumed.
      final jobs = [job(), job(), job(resumed: true)];
      expect(admissions(jobs, concurrency: 1).map((j) => j.seq), [3]);
    });

    test('order is the order they were asked for', () {
      final jobs = [job(), job(), job(), job()];
      expect(admissions(jobs, concurrency: 3).map((j) => j.seq), [1, 2, 3]);
    });
  });

  group('activeJobForFile', () {
    test('finds a job still working on that file', () {
      final jobs = [job(fileId: 10, state: DownloadJobState.running)];
      expect(activeJobForFile(jobs, 10)?.seq, 1);
    });

    test('ignores finished ones, so a failure can be asked for again', () {
      final jobs = [
        job(fileId: 10, state: DownloadJobState.failed),
        job(fileId: 11, state: DownloadJobState.done),
      ];
      expect(activeJobForFile(jobs, 10), isNull);
      expect(activeJobForFile(jobs, 11), isNull);
    });

    test('a job waiting on the host still counts', () {
      // It has an archive on disk that something is about to consume. Starting a
      // second transfer of the same file would write the same `.part` and the
      // same resume record, which is how two streams become one corrupt archive.
      final jobs = [job(fileId: 10, state: DownloadJobState.downloaded)];
      expect(activeJobForFile(jobs, 10)?.seq, 1);
    });
  });

  group('nextAwaitingHost', () {
    test('hands over the oldest downloaded job', () {
      final jobs = [
        job(state: DownloadJobState.running),
        job(state: DownloadJobState.downloaded),
        job(state: DownloadJobState.downloaded),
      ];
      expect(nextAwaitingHost(jobs)?.seq, 2);
    });

    test('nothing while an install is in flight', () {
      final jobs = [
        job(state: DownloadJobState.installing),
        job(state: DownloadJobState.downloaded),
      ];
      expect(nextAwaitingHost(jobs), isNull);
    });

    test('a job that has waited goes ahead of jobs that have not', () {
      final jobs = [
        job(state: DownloadJobState.downloaded),
        job(state: DownloadJobState.downloaded, prepared: Object()),
      ];
      expect(nextAwaitingHost(jobs)?.seq, 2);
    });

    test('a waiting job does not hold the slot', () {
      final jobs = [
        job(state: DownloadJobState.waiting, wait: const InstallWait(InstallQuestion.patch)),
        job(state: DownloadJobState.downloaded),
      ];
      expect(nextAwaitingHost(jobs)?.seq, 2);
    });

    test('never a job whose caller owns what happens next', () {
      final jobs = [
        job(
          state: DownloadJobState.downloaded,
          intent: DownloadIntent.callerHandles,
        ),
      ];
      expect(nextAwaitingHost(jobs), isNull);
    });
  });

  group('rowActions', () {
    List<DownloadRowAction> of(DownloadJob j, [List<DownloadJob>? all]) => rowActions(j, all ?? [j]);

    test('a running background transfer pauses or cancels, an update download only cancels', () {
      expect(of(job(state: DownloadJobState.running)), [DownloadRowAction.pause, DownloadRowAction.cancel]);
      expect(of(job(state: DownloadJobState.running, intent: DownloadIntent.callerHandles)), [DownloadRowAction.cancel]);
    });

    test('a paused one resumes or cancels, a queued one is removed from the queue', () {
      expect(of(job(state: DownloadJobState.paused)), [DownloadRowAction.resume, DownloadRowAction.cancel]);
      expect(of(job()), [DownloadRowAction.removeFromQueue]);
    });

    test("a waiting one offers its question's button and Don't install, or Open mod page for a password", () {
      expect(
        of(job(state: DownloadJobState.waiting, wait: const InstallWait(InstallQuestion.severalFolders))),
        [DownloadRowAction.answer, DownloadRowAction.dontInstall],
      );
      expect(
        of(job(state: DownloadJobState.waiting, wait: const InstallWait(InstallQuestion.password), mod: const GbMod(idRow: 1))),
        [DownloadRowAction.answer, DownloadRowAction.openModPage],
      );
    });

    test('offers nothing mid-install or while an update is written', () {
      // Between the unpack and the import there is no safe stopping point, so
      // there is no button that could honestly be offered.
      expect(of(job(state: DownloadJobState.installing)), isEmpty);
      expect(of(job(state: DownloadJobState.updating, intent: DownloadIntent.callerHandles)), isEmpty);
    });

    test('a job whose bytes have landed can still be called off', () {
      expect(of(job(state: DownloadJobState.downloaded)), [DownloadRowAction.cancel]);
    });

    test('a finished install of one mod offers Turn on while it is off, Show once it is on, and nothing while it is written', () {
      final done = job(state: DownloadJobState.done, outcome: JobOutcome.installed, installed: const ['Ellen A']);
      expect(rowActions(done, [done], modIsOn: (_) => false), [DownloadRowAction.turnOn]);
      expect(rowActions(done, [done], modIsOn: (_) => true), [DownloadRowAction.show]);
      expect(rowActions(done, [done], modIsOn: (_) => false, modBeingWritten: (_) => true), isEmpty);
      final several = job(state: DownloadJobState.done, outcome: JobOutcome.installed, installed: const ['A', 'B']);
      expect(of(several), isEmpty);
    });

    test('an update or a saved archive offers Show, an install that put nothing in nothing', () {
      expect(of(job(state: DownloadJobState.done, outcome: JobOutcome.updated)), [DownloadRowAction.show]);
      expect(of(job(state: DownloadJobState.done, outcome: JobOutcome.saved)), [DownloadRowAction.show]);
      expect(of(job(state: DownloadJobState.done, outcome: JobOutcome.nothingInstalled)), isEmpty);
    });

    test('offers a retry for a failed transfer', () {
      expect(of(job(state: DownloadJobState.failed)), [DownloadRowAction.retry]);
    });

    test('no retry while another job is already fetching that file', () {
      // Reachable straight through the UI: a failed row stays in the panel by
      // design, the user presses Download again, and two rows now carry the same
      // mod name. `DownloadQueue.retry` refuses the second transfer, and a
      // button that silently does nothing is worse than a row that plainly reads
      // as history.
      final stale = job(fileId: 7, state: DownloadJobState.failed);
      final fresh = job(fileId: 7, state: DownloadJobState.running);
      expect(of(stale, [stale, fresh]), [DownloadRowAction.dismiss]);
      // …and it comes back once that job is over.
      expect(of(stale), [DownloadRowAction.retry]);
    });

    test('no retry for an install failure — the bytes were fine — nor for an update', () {
      // Re-fetching two hundred megabytes to hit the same `7z` error is not a
      // fix, so the row is one to read rather than to press.
      final broken = job(
        state: DownloadJobState.failed,
        error: const InstallFailure("Couldn't extract the archive"),
      );
      expect(of(broken), [DownloadRowAction.dismiss]);
      expect(of(job(state: DownloadJobState.failed, intent: DownloadIntent.callerHandles)), [DownloadRowAction.dismiss]);
    });
  });

  group('aggregateProgress', () {
    test('weighs by bytes, not by job count', () {
      final jobs = [
        job(state: DownloadJobState.running, received: 0, total: 1000),
        job(state: DownloadJobState.running, received: 10, total: 10),
      ];
      // Averaged per job this would read 50%. It is 10 of 1010 bytes.
      expect(aggregateProgress(jobs).fraction, closeTo(10 / 1010, 1e-9));
    });

    test('has no fraction when any active job has no known size', () {
      final jobs = [
        job(state: DownloadJobState.running, received: 5, total: 10),
        job(state: DownloadJobState.running, received: 5),
      ];
      final progress = aggregateProgress(jobs);
      expect(progress.total, isNull);
      expect(progress.fraction, isNull);
      // But what has arrived is still known, and is what the card falls back to.
      expect(progress.received, 10);
    });

    test('falls back to the size the mod page published', () {
      // `_nFilesize` is exactly the eventual Content-Length, so it is a
      // denominator from the first frame rather than only once headers land.
      final jobs = [job(state: DownloadJobState.queued, expectedSize: 400)];
      expect(aggregateProgress(jobs).fraction, 0);
    });

    test('counts a job waiting on the host as whole', () {
      final jobs = [
        job(state: DownloadJobState.downloaded, expectedSize: 100),
        job(state: DownloadJobState.running, received: 0, total: 100),
      ];
      expect(aggregateProgress(jobs).fraction, 0.5);
    });

    test('is empty with nothing active, so the ring never sticks at 100%', () {
      final jobs = [job(state: DownloadJobState.done, expectedSize: 100)];
      final progress = aggregateProgress(jobs);
      expect(progress.isEmpty, isTrue);
      expect(progress.fraction, isNull);
    });

    test('sums the rates of the transfers in flight', () {
      // The throughput the user is actually getting, not one connection's share
      // of it.
      final jobs = [
        job(state: DownloadJobState.running, received: 0, total: 100, rate: 10),
        job(state: DownloadJobState.running, received: 0, total: 100, rate: 30),
        // Not transferring, so it contributes no rate even if it has one on
        // record from before it finished.
        job(state: DownloadJobState.installing, expectedSize: 100, rate: 99),
      ];
      expect(aggregateProgress(jobs).bytesPerSecond, 40);
    });

    test('derives the ETA from what is left over the combined rate', () {
      final jobs = [
        job(state: DownloadJobState.running, received: 0, total: 100, rate: 10),
        job(state: DownloadJobState.queued, expectedSize: 100),
      ];
      // 200 bytes to go at 10 B/s — the *queue's* ETA, not the running job's,
      // because the queue finishes when the last byte lands.
      expect(aggregateProgress(jobs).eta, const Duration(seconds: 20));
    });

    test('gives no ETA without a total to subtract from', () {
      final jobs = [job(state: DownloadJobState.running, received: 5, rate: 10)];
      expect(aggregateProgress(jobs).eta, isNull);
    });

    test('names the one job it is about, and refuses to for several', () {
      // What keeps a count-bearing card from claiming one arbitrary mod's
      // portrait — the same rule the bulk reports follow.
      expect(aggregateProgress([job()]).only, isNotNull);
      expect(aggregateProgress([job(), job()]).only, isNull);
    });

    test('leaves out a paused and a waiting job, as nothing of either is moving', () {
      final jobs = [
        job(state: DownloadJobState.paused, received: 50, total: 100),
        job(state: DownloadJobState.waiting, expectedSize: 100),
        job(state: DownloadJobState.running, received: 25, total: 100),
      ];
      final progress = aggregateProgress(jobs);
      expect(progress.active.map((j) => j.seq), [3]);
      expect(progress.fraction, 0.25);
    });

    test('counts an update download as whole once its bytes are handed over', () {
      final progress = aggregateProgress([
        job(state: DownloadJobState.updating, intent: DownloadIntent.callerHandles, expectedSize: 10),
      ]);
      expect(progress.fraction, 1);
      expect(progress.installing, isTrue);
    });

    test('separates "bytes are moving" from "an archive is unpacking"', () {
      final unpacking = aggregateProgress([
        job(state: DownloadJobState.installing, expectedSize: 10),
      ]);
      expect(unpacking.transferring, isFalse);
      expect(unpacking.installing, isTrue);
    });
  });

  test('the counts: in progress or queued with paused included, waiting, and failed', () {
    final jobs = [
      job(),
      job(state: DownloadJobState.running),
      job(state: DownloadJobState.paused),
      job(state: DownloadJobState.downloaded),
      job(state: DownloadJobState.installing),
      job(state: DownloadJobState.updating),
      job(state: DownloadJobState.waiting),
      job(state: DownloadJobState.waiting),
      job(state: DownloadJobState.done),
      job(state: DownloadJobState.failed),
    ];
    expect(activeJobCount(jobs), 6);
    expect(waitingJobCount(jobs), 2);
    expect(failedJobCount(jobs), 1);
  });

  test('the states: only running holds a connection, only done and failed are terminal', () {
    for (final state in DownloadJobState.values) {
      expect(state.holdsConnection, state == DownloadJobState.running, reason: state.name);
      expect(state.isTerminal, state == DownloadJobState.done || state == DownloadJobState.failed, reason: state.name);
      expect(state.isActive, !state.isTerminal, reason: state.name);
    }
  });
}
