import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_file.dart';
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
      state: state,
      error: error,
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
        job(state: DownloadJobState.cancelled),
        job(),
      ];
      expect(admissions(jobs, concurrency: 2).map((j) => j.seq), [4]);
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

  group('rowAction', () {
    test('offers a retry only for a failure', () {
      final failed = job(state: DownloadJobState.failed);
      expect(rowAction(failed, [failed]), DownloadRowAction.retry);

      final cancelled = job(state: DownloadJobState.cancelled);
      expect(rowAction(cancelled, [cancelled]), DownloadRowAction.dismiss);

      final done = job(state: DownloadJobState.done);
      expect(rowAction(done, [done]), DownloadRowAction.dismiss);
    });

    test('offers nothing mid-install', () {
      // Between the unpack and the import there is no safe stopping point, so
      // there is no button that could honestly be offered.
      final installing = job(state: DownloadJobState.installing);
      expect(rowAction(installing, [installing]), DownloadRowAction.none);
    });

    test('a job whose bytes have landed can still be called off', () {
      final downloaded = job(state: DownloadJobState.downloaded);
      expect(rowAction(downloaded, [downloaded]), DownloadRowAction.cancel);
    });

    test('no retry while another job is already fetching that file', () {
      // Reachable straight through the UI: a failed row stays in the panel by
      // design, the user presses Download again, and two rows now carry the same
      // mod name. `DownloadQueue.retry` refuses the second transfer, and a
      // button that silently does nothing is worse than a row that plainly reads
      // as history.
      final stale = job(fileId: 7, state: DownloadJobState.failed);
      final fresh = job(fileId: 7, state: DownloadJobState.running);
      expect(rowAction(stale, [stale, fresh]), DownloadRowAction.dismiss);
      // …and it comes back once that job is over.
      expect(rowAction(stale, [stale]), DownloadRowAction.retry);
    });

    test('no retry for an install failure — the bytes were fine', () {
      // Re-fetching two hundred megabytes to hit the same `7z` error is not a
      // fix, so the row is one to read rather than to press.
      final broken = job(
        state: DownloadJobState.failed,
        error: const InstallFailure("Couldn't extract the archive"),
      );
      expect(rowAction(broken, [broken]), DownloadRowAction.dismiss);
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

    test('separates "bytes are moving" from "an archive is unpacking"', () {
      final unpacking = aggregateProgress([
        job(state: DownloadJobState.installing, expectedSize: 10),
      ]);
      expect(unpacking.transferring, isFalse);
      expect(unpacking.installing, isTrue);
    });
  });

  test('activeJobCount counts everything not finished', () {
    final jobs = [
      job(),
      job(state: DownloadJobState.running),
      job(state: DownloadJobState.downloaded),
      job(state: DownloadJobState.installing),
      job(state: DownloadJobState.done),
      job(state: DownloadJobState.failed),
      job(state: DownloadJobState.cancelled),
    ];
    expect(activeJobCount(jobs), 4);
  });
}
