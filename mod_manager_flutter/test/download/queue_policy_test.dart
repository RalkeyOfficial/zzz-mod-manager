import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_file.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_mod.dart';
import 'package:mod_manager_flutter/models/mod_download.dart';
import 'package:mod_manager_flutter/services/download/download_exceptions.dart';
import 'package:mod_manager_flutter/services/download/download_job.dart';
import 'package:mod_manager_flutter/services/download/download_progress.dart';
import 'package:mod_manager_flutter/services/download/download_request.dart';
import 'package:mod_manager_flutter/services/download/queue_policy.dart';
import 'package:mod_manager_flutter/services/download/update_job.dart';

import '../support/update_jobs.dart';

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

  group('the lanes of an update run', () {
    /// An update job of [size] MB for the folder [modId] (by default its own), at [state] and, while updating, [step].
    DownloadJob update(
      int size, {
      DownloadJobState state = DownloadJobState.queued,
      UpdateStep? step,
      String? modId,
      DownloadKey? layer,
      bool waited = false,
      bool deferred = false,
      UpdateHalt? halt,
    }) {
      final seq = ++nextSeq;
      return updateJob(
        seq,
        state: state,
        step: step,
        size: size * mb,
        mods: [UpdateMod(modId: modId ?? 'mod$seq', layer: layer ?? DownloadKey.base(seq))],
        waited: waited,
        deferred: deferred,
        halt: halt,
      );
    }

    DownloadJob unpacking(int size) => update(size, state: DownloadJobState.updating, step: UpdateStep.unpacking);
    DownloadJob unpacked(int size, {String? modId}) =>
        update(size, state: DownloadJobState.updating, step: UpdateStep.unpacked, modId: modId);
    DownloadJob writing(int size) => update(size, state: DownloadJobState.updating, step: UpdateStep.writing);

    List<int> admitted(List<DownloadJob> jobs) => [for (final j in admissions(jobs)) j.seq];

    /// The jobs ahead of the install, by listed size in MB.
    List<int> ahead(List<DownloadJob> jobs) =>
        [for (final j in jobs) if (isAheadOfInstall(j)) (j.file.filesize ?? 0) ~/ mb];

    group('D, update downloads at once', () {
      for (final (queued, starts) in [(1, 1), (2, 2), (3, 3), (4, 3)]) {
        test('$queued queued, $starts start', () {
          final jobs = [for (var i = 0; i < queued; i++) update(10)];
          expect(admissions(jobs), hasLength(starts));
        });
      }

      test('in a pool of their own: two Browse downloads running take none of its places', () {
        final jobs = [
          job(state: DownloadJobState.running),
          job(state: DownloadJobState.running),
          job(),
          update(10),
          update(10),
          update(10),
        ];
        expect(admitted(jobs), [4, 5, 6], reason: 'five connections at most, and the third Browse job waits');
      });

      test('an update never bypasses a cap, and its running jobs hold no Browse place', () {
        final jobs = [
          update(10, state: DownloadJobState.running),
          update(10, state: DownloadJobState.running),
          update(10, state: DownloadJobState.running),
          update(10),
          job(),
          job(),
        ];
        expect(admitted(jobs), [5, 6]);
        expect(jobs[3].bypassesCap, isFalse);
      });

      test('a value of D other than three is honoured', () {
        final jobs = [for (var i = 0; i < 4; i++) update(10)];
        for (final d in [1, 2, 3, 4]) {
          expect(updateAdmissions(jobs, concurrency: d, lookaheadCount: 10), hasLength(d), reason: 'D = $d');
        }
      });
    });

    group('L, the lookahead', () {
      test('counts every job between the start of its download and the end of its install', () {
        final jobs = [
          update(10),
          update(10, state: DownloadJobState.running),
          update(10, state: DownloadJobState.downloaded),
          unpacking(10),
          unpacked(10),
          writing(10),
          update(10, state: DownloadJobState.waiting),
          update(10, state: DownloadJobState.done),
          update(10, state: DownloadJobState.failed),
          job(state: DownloadJobState.running),
        ];
        expect([for (final j in jobs) isAheadOfInstall(j)],
            [false, true, true, true, true, true, true, false, false, false]);
      });

      test('admits nothing more once three are ahead, whatever their size', () {
        final jobs = [update(1, state: DownloadJobState.downloaded), unpacked(1), writing(1), update(1)];
        expect(admitted(jobs), isEmpty);
      });

      test('admits a job only while the sizes ahead, its own included, fit in 1 GB', () {
        expect(admitted([update(900, state: DownloadJobState.running), update(200)]), isEmpty);
        expect(admitted([update(900, state: DownloadJobState.running), update(100)]), [4]);
      });

      test('always admits one when none is ahead, however large', () {
        expect(admitted([update(1229)]), [1]);
        expect(lookaheadAdmits(aheadCount: 0, aheadBytes: 0, size: 5 * 1024 * mb), isTrue);
        expect(lookaheadAdmits(aheadCount: 1, aheadBytes: 20 * mb, size: 1229 * mb), isFalse);
      });

      test('a 1.2 GB file after smaller ones waits until nothing is ahead, then runs alone', () {
        final big = update(1229);
        final small = [update(20), update(40), update(80)];
        expect(admitted([big, ...small]), [2, 3, 4], reason: 'smallest first, and the large one does not fit beside them');

        final installed = [for (final j in small) j.copyWith(state: DownloadJobState.done)];
        final late = update(10);
        expect(admitted([big, ...installed, late]), [late.seq], reason: 'the 10 MB file is smaller and goes first');

        final running = big.copyWith(state: DownloadJobState.running);
        expect(admitted([running, ...installed, update(10)]), isEmpty, reason: 'nothing fits beside 1.2 GB');
      });

      test('a job waiting on a question keeps its place', () {
        final jobs = [
          update(10, state: DownloadJobState.waiting),
          update(10, state: DownloadJobState.waiting),
          update(10, state: DownloadJobState.waiting),
          update(10),
        ];
        expect(admitted(jobs), isEmpty, reason: 'three questions fill the lookahead, and the run waits for answers');
        expect(nextUpdateToUnpack(jobs), isNull, reason: 'a question holds no unpack');
      });
    });

    test('the five-mod picture: 20, 40, 80, 200 and 300 MB', () {
      var jobs = [update(300), update(20), update(200), update(80), update(40)];
      DownloadJob of(int size) => jobs.firstWhere((j) => j.file.filesize == size * mb);
      void move(int size, DownloadJobState state, [UpdateStep? step]) => jobs = [
            for (final j in jobs)
              if (j.file.filesize == size * mb) j.copyWith(state: state, updateStep: step) else j,
          ];
      void start() {
        for (final j in admissions(jobs)) {
          move((j.file.filesize ?? 0) ~/ mb, DownloadJobState.running);
        }
        expect(ahead(jobs).length, lessThanOrEqualTo(3));
      }

      start();
      expect(ahead(jobs), unorderedEquals([20, 40, 80]), reason: 'the first three start together, 140 MB');

      move(20, DownloadJobState.downloaded);
      start();
      expect(nextUpdateToUnpack(jobs)?.seq, of(20).seq);
      move(20, DownloadJobState.updating, UpdateStep.unpacking);
      move(40, DownloadJobState.downloaded);
      expect(nextUpdateToUnpack(jobs), isNull, reason: 'one unpack at a time');
      move(20, DownloadJobState.updating, UpdateStep.unpacked);
      expect(nextUpdateToWrite(jobs)?.seq, of(20).seq);
      move(20, DownloadJobState.updating, UpdateStep.writing);
      expect(nextUpdateToUnpack(jobs)?.seq, of(40).seq, reason: 'the 40 MB archive is unpacked while 20 installs');
      move(40, DownloadJobState.updating, UpdateStep.unpacked);
      start();
      expect(ahead(jobs), unorderedEquals([20, 40, 80]), reason: '200 MB waits for the 20 MB install to end');

      move(20, DownloadJobState.done);
      start();
      expect(of(200).state, DownloadJobState.running, reason: 'a place opened');
      expect(of(300).state, DownloadJobState.queued);

      move(40, DownloadJobState.updating, UpdateStep.writing);
      move(40, DownloadJobState.done);
      start();
      expect(of(300).state, DownloadJobState.running);
      expect(ahead(jobs), unorderedEquals([80, 200, 300]));
    });

    group('why a queued job is not admitted, as its row says it', () {
      test('with the pool full, the first in line held by the lookahead waits for an install, not downloads next', () {
        final jobs = [for (var i = 0; i < 3; i++) update(10, state: DownloadJobState.running), update(10)];
        expect(updateHolds(jobs)[jobs.last.seq], UpdateHold.lookahead);
        expect(updateQueuedPlace(jobs.last, jobs), isA<WaitsForInstall>());
      });

      test('with the pool full and the lookahead admitting it, the first in line downloads next', () {
        final jobs = [for (var i = 0; i < 3; i++) update(10, state: DownloadJobState.running), update(10)];
        expect(updateHolds(jobs, lookaheadCount: 5)[jobs.last.seq], UpdateHold.pool);
        expect(updateQueuedPlace(jobs.last, jobs, lookaheadCount: 5), isA<DownloadsNext>());
      });

      test('the admissions are the jobs the walk holds nothing back, and the line behind a refusal waits too', () {
        final jobs = [update(400, state: DownloadJobState.running), update(500), update(700), update(10, deferred: true)];
        final holds = updateHolds(jobs);
        expect(admitted(jobs), [jobs[1].seq]);
        expect(holds[jobs[2].seq], UpdateHold.lookahead);
        expect(holds[jobs[3].seq], UpdateHold.lookahead, reason: 'the line stops at the first job it refuses');
        expect(updateQueuedPlace(jobs[3], jobs), isA<AheadOfIt>());
      });
    });

    group('the order of work', () {
      test('smallest listed file first, then in the order asked for', () {
        expect([for (final j in updateLine([update(300), update(20), update(20), update(80)])) j.seq], [2, 3, 4, 1]);
      });

      test('a stalled file goes to the end of the line', () {
        expect([for (final j in updateLine([update(20, deferred: true), update(300), update(80)])) j.seq], [3, 2, 1]);
      });

      test('a job a halt holds back is not in line', () {
        const halt = UpdateHalt(cause: UpdateFailure(UpdateFailureKind.noSpace), bySeq: 99);
        expect(updateLine([update(20, halt: halt), update(30)]).map((j) => j.seq), [2]);
        expect(admitted([update(20, halt: halt)]), isEmpty);
      });

      test('the jobs a halt holds at a gate are last at work, behind a transfer that goes on', () {
        const halt = UpdateHalt(cause: UpdateFailure(UpdateFailureKind.noSpace), bySeq: 99);
        final jobs = [
          update(10, state: DownloadJobState.updating, step: UpdateStep.unpacked, halt: halt),
          update(10, state: DownloadJobState.downloaded, halt: halt),
          update(10, state: DownloadJobState.running, halt: halt),
          update(10, halt: halt),
        ];
        final running = jobs[2].seq;
        expect(updatesInOrderOfWork(jobs).first.seq, running);
        expect([for (final j in updatesInOrderOfWork(jobs)) j.seq].skip(1), [jobs[0].seq, jobs[1].seq, jobs[3].seq]);
      });
    });

    group('U, the unpack lane', () {
      test('one unpack at a time', () {
        expect(nextUpdateToUnpack([unpacking(10), update(10, state: DownloadJobState.downloaded)]), isNull);
      });

      test('with one unpacked archive waiting for the install, no other unpack starts', () {
        expect(nextUpdateToUnpack([writing(10), unpacked(10), update(10, state: DownloadJobState.downloaded)]), isNull);
      });

      test('while an install runs and none waits, the next is unpacked', () {
        expect(nextUpdateToUnpack([writing(10), update(10, state: DownloadJobState.downloaded)])?.seq, 2);
      });

      test('an answered job goes ahead of the ones that have not waited, and smaller before larger otherwise', () {
        final jobs = [
          update(10, state: DownloadJobState.downloaded),
          update(300, state: DownloadJobState.downloaded, waited: true),
        ];
        expect(nextUpdateToUnpack(jobs)?.seq, 2);
        expect(
          nextUpdateToUnpack([update(300, state: DownloadJobState.downloaded), update(20, state: DownloadJobState.downloaded)])
              ?.seq,
          4,
        );
      });

      test('nothing is unpacked once the app is closing, or while a halt holds the job', () {
        expect(nextUpdateToUnpack([update(10, state: DownloadJobState.downloaded)], closing: true), isNull);
        const halt = UpdateHalt(cause: UpdateFailure(UpdateFailureKind.snapshotFailed), bySeq: 99);
        expect(nextUpdateToUnpack([update(10, state: DownloadJobState.downloaded, halt: halt)]), isNull);
      });
    });

    group('one write pipeline per folder', () {
      test('the second job of a folder waits until the first has ended, even when it landed first', () {
        final base = update(200, state: DownloadJobState.running, modId: 'Ellen', layer: const DownloadKey.base(1));
        final patch =
            update(5, state: DownloadJobState.downloaded, modId: 'Ellen', layer: const DownloadKey.patch(2));
        expect(folderPipelineFree(patch, [base, patch]), isFalse);
        expect(nextUpdateToUnpack([base, patch]), isNull);

        final ended = base.copyWith(state: DownloadJobState.done);
        expect(nextUpdateToUnpack([ended, patch])?.seq, patch.seq);
      });

      test('other folders go on', () {
        final ellen = update(200, state: DownloadJobState.waiting, modId: 'Ellen');
        final lycaon = update(5, state: DownloadJobState.downloaded, modId: 'Lycaon');
        expect(nextUpdateToUnpack([ellen, lycaon])?.seq, lycaon.seq);
      });

      test('a base and its patch over 1 GiB together: the base downloads first, alone, and the patch after it', () {
        final base = update(900, modId: 'Ellen', layer: const DownloadKey.base(1));
        final patch = update(150, modId: 'Ellen', layer: const DownloadKey.patch(2));
        expect(admitted([base, patch]), [base.seq], reason: 'the smaller patch is passed over, holding no place');

        final landed = base.copyWith(state: DownloadJobState.downloaded);
        expect(admitted([landed, patch]), isEmpty, reason: 'the patch waits for the base to end');
        expect(admitted([base.copyWith(state: DownloadJobState.done), patch]), [patch.seq]);
      });

      test('three bases with their patches never fill the lookahead with patches that cannot go on', () {
        final pairs = [
          for (final name in ['Ellen', 'Lycaon', 'Nicole'])
            (
              update(300, modId: name, layer: DownloadKey.base(++nextSeq)),
              update(5, modId: name, layer: DownloadKey.patch(++nextSeq)),
            ),
        ];
        final jobs = [for (final (base, patch) in pairs) ...[base, patch]];
        expect(admitted(jobs), [for (final (base, _) in pairs) base.seq]);
      });

      test('a later job of a folder that landed before an earlier one came back holds no place', () {
        // Tried again: the base is back in line while its patch is already unpacked.
        final base = update(50, modId: 'Ellen', layer: const DownloadKey.base(1), deferred: true);
        final patch = update(10,
            state: DownloadJobState.updating,
            step: UpdateStep.unpacked,
            modId: 'Ellen',
            layer: const DownloadKey.patch(2));
        final other = update(10, state: DownloadJobState.downloaded, modId: 'Lycaon');
        expect(isHeldByPipeline(patch, [base, patch, other]), isTrue);
        expect(nextUpdateToWrite([base, patch, other]), isNull, reason: 'the patch waits for its base');
        expect(nextUpdateToUnpack([base, patch, other])?.seq, other.seq, reason: 'and does not take the one place');
        expect(admitted([base, patch, other]), [base.seq]);

        final landed = base.copyWith(state: DownloadJobState.downloaded);
        expect(nextUpdateToUnpack([landed, patch])?.seq, landed.seq, reason: 'the held patch leaves the place free');
        final unpackedBase = landed.copyWith(state: DownloadJobState.updating, updateStep: UpdateStep.unpacked);
        expect(nextUpdateToWrite([unpackedBase, patch, other])?.seq, unpackedBase.seq, reason: 'base first, then patch');
      });
    });

    group('I, the install chain', () {
      test('an update writing holds a Browse install back, and a Browse install holds an update write back', () {
        expect(nextForInstallChain([writing(10), job(state: DownloadJobState.downloaded)]), isNull);
        expect(nextForInstallChain([job(state: DownloadJobState.installing), unpacked(10)]), isNull);
      });

      test('an unpacked update and a landed install: the one asked for first', () {
        final jobs = [unpacked(10), job(state: DownloadJobState.downloaded)];
        expect(nextForInstallChain(jobs)?.seq, jobs.first.seq);
        expect(nextForInstallChain(jobs.reversed.toList())?.seq, jobs.first.seq);
      });

      test('nothing starts its write once the app is closing', () {
        expect(nextForInstallChain([unpacked(10)], closing: true), isNull);
        expect(nextForInstallChain([job(state: DownloadJobState.downloaded)], closing: true), isNull);
        expect(nextAwaitingHost([job(state: DownloadJobState.downloaded)], closing: true), isNull);
      });

      test('a Browse install never picks an update job up', () {
        expect(nextAwaitingHost([update(10, state: DownloadJobState.downloaded)]), isNull);
      });
    });

    test('an update job is never pausable', () {
      expect(update(10, state: DownloadJobState.running).pausable, isFalse);
      expect(rowActions(update(10, state: DownloadJobState.running), const []), [DownloadRowAction.cancel]);
    });

    test('Cancel is offered exactly where the queue can cancel', () {
      expect(unpacked(10).cancellable, isTrue);
      expect(rowActions(unpacked(10), const []), [DownloadRowAction.cancel]);
      for (final busy in [unpacking(10), writing(10), job(state: DownloadJobState.installing)]) {
        expect(busy.cancellable, isFalse);
        expect(rowActions(busy, const []), isEmpty);
      }
    });

    test('a failure after the download offers no Try again', () {
      final unpackFailed = update(10, state: DownloadJobState.failed).copyWith(
        error: const UpdateFailure(UpdateFailureKind.unpackFailed),
      );
      expect(rowActions(unpackFailed, [unpackFailed]), [DownloadRowAction.dismiss]);
    });

    test('the halt of the run is one rule, read off the jobs that have not ended', () {
      const first = UpdateHalt(cause: UpdateFailure(UpdateFailureKind.noSpace), bySeq: 1);
      const ended = UpdateHalt(cause: UpdateFailure(UpdateFailureKind.snapshotFailed), bySeq: 2);
      expect(currentHalt([update(10, state: DownloadJobState.done, halt: ended), update(10, halt: first)]), same(first));
      expect(currentHalt([update(10)]), isNull);
    });

    test('a pick joins a job of its file only before the file is unpacked or the job has waited', () {
      expect(joinsUpdateJob(update(10)), isTrue);
      expect(joinsUpdateJob(update(10, state: DownloadJobState.running)), isTrue);
      expect(joinsUpdateJob(update(10, state: DownloadJobState.downloaded)), isTrue);
      expect(joinsUpdateJob(update(10, state: DownloadJobState.downloaded, waited: true)), isFalse);
      expect(joinsUpdateJob(unpacking(10)), isFalse);
      expect(joinsUpdateJob(unpacked(10)), isFalse);
      expect(joinsUpdateJob(job()), isFalse, reason: 'a Browse download of the same file');
    });

    test('a finished row: Show for a patch added, nothing for a skipped or undone one', () {
      for (final (outcome, actions) in [
        (JobOutcome.patchAdded, [DownloadRowAction.show]),
        (JobOutcome.skipped, <DownloadRowAction>[]),
        (JobOutcome.undone, <DownloadRowAction>[]),
      ]) {
        final done = update(10, state: DownloadJobState.done).copyWith(outcome: outcome);
        expect(rowActions(done, [done]), actions, reason: outcome.name);
      }
    });

    test('what halts a run: the disk, never one mod of its own', () {
      expect(haltsUpdateRun(const InsufficientSpaceException('', requiredBytes: 2, availableBytes: 1)), isTrue);
      expect(haltsUpdateRun(const DownloadWriteException('')), isTrue);
      for (final kind in UpdateFailureKind.values) {
        final halts = {
          UpdateFailureKind.noSpace,
          UpdateFailureKind.snapshotFailed,
          UpdateFailureKind.writtenPartway,
          UpdateFailureKind.writeInterrupted,
        }.contains(kind);
        expect(haltsUpdateRun(UpdateFailure(kind)), halts, reason: kind.name);
      }
      expect(haltsUpdateRun(const DownloadHttpException('gone', statusCode: 404)), isFalse);
      expect(haltsUpdateRun(const DownloadStalledException('', stallTimeout: Duration(seconds: 60))), isFalse);
    });

    test('the run summary and the job of a mod', () {
      const halt = UpdateHalt(cause: UpdateFailure(UpdateFailureKind.noSpace), bySeq: 3);
      final jobs = [
        update(10, modId: 'Ellen', halt: halt),
        update(10, state: DownloadJobState.waiting, modId: 'Lycaon'),
        update(10, state: DownloadJobState.failed, modId: 'Nicole'),
        update(10, state: DownloadJobState.done, modId: 'Ellen'),
        unpacked(10, modId: 'Anby'),
        job(state: DownloadJobState.running),
      ];
      final summary = summariseUpdateRun(jobs);
      expect((summary.live, summary.asking, summary.done, summary.failed), (2, 1, 1, 1));
      expect(summary.halt, same(halt));
      expect(summariseUpdateRun([job()]).isEmpty, isTrue);

      expect(updateJobOfMod(jobs, 'Ellen')?.job.seq, jobs.first.seq,
          reason: 'the one going wins over the one that ended');
      expect(updateJobOfMod(jobs, 'Ellen')?.result, isNull, reason: 'it has not ended');
      expect(updateJobOfMod(jobs, 'Nicole')?.job.state, DownloadJobState.failed);
      expect(updateJobOfMod(jobs, 'Rina'), isNull);
    });

    test("a mod's row reads its own result, not its job's", () {
      final ellen = baseOf('Ellen', 1);
      final alt = baseOf('Ellen Alt', 2);
      final job = updateJob(1, state: DownloadJobState.done, mods: [ellen, alt]).copyWith(
        outcome: JobOutcome.updated,
        modResults: [
          UpdateModResult.written(ellen),
          const UpdateModResult.skipped(UpdateMod(modId: 'Ellen Alt', layer: DownloadKey.base(2)),
              UpdateSkipReason.beingWritten),
        ],
      );
      expect(updateJobOfMod([job], 'Ellen')?.result?.end, UpdateModEnd.written);
      expect(updateJobOfMod([job], alt.modId)?.result?.skipReason, UpdateSkipReason.beingWritten);
    });
  });
}
