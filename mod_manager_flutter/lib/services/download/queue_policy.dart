import 'download_job.dart';

/// How many transfers may hold a connection at once.
///
/// **Two, and the reason is not throughput.** `gamebanana-api.md` §8 measured
/// that a CDN node is assigned deterministically per file and that opening more
/// connections to one file does not make it arrive faster — so concurrency buys
/// nothing on a single download and no claim is made that it does. What it buys
/// is that a file served by a degraded node at 0.08 MB/s for twenty-five minutes
/// does not hold up everything queued behind it. Two is the smallest number that
/// delivers that.
///
/// Higher was not measured, so it is not chosen. Each connection also costs a
/// spawned isolate ([DownloadPump]), which is the other reason not to raise it
/// on a guess.
const int kDownloadConcurrency = 2;

/// Which of [jobs] should be started now, oldest first.
///
/// Pure, and deliberately the only place the cap is applied — the queue calls
/// this after **every** state change rather than starting jobs from the several
/// places one can finish, so "a slot freed up" has one meaning and one
/// implementation.
///
/// Two rules, and the second is the subtle one:
///
/// - a queued job starts while fewer than [concurrency] jobs hold a connection;
/// - a [DownloadJob.bypassesCap] job starts regardless. It still *counts*
///   towards the cap once running, so admitting one closes the door behind it
///   rather than raising the ceiling permanently.
List<DownloadJob> admissions(
  List<DownloadJob> jobs, {
  int concurrency = kDownloadConcurrency,
}) {
  var running = jobs.where((j) => j.state.holdsConnection).length;
  final starting = <DownloadJob>[];

  // `jobs` is already in enqueue order (the queue only ever appends), so this
  // is first-in-first-out without a sort. Sorting by `seq` here would hide a
  // future caller that reorders the list.
  for (final job in jobs) {
    if (job.state != DownloadJobState.queued) continue;
    if (job.bypassesCap) {
      starting.add(job);
      running++;
      continue;
    }
    if (running >= concurrency) continue;
    starting.add(job);
    running++;
  }
  return starting;
}

/// The job already covering [fileId], if any — so pressing Download twice does
/// not fetch the same archive twice.
///
/// Terminal jobs are ignored on purpose: a finished, failed or cancelled row is
/// history, and refusing to re-download something that failed is the opposite of
/// what the user pressing it again is asking for.
DownloadJob? activeJobForFile(List<DownloadJob> jobs, int fileId) {
  for (final job in jobs) {
    if (job.isTerminal) continue;
    if (job.file.idRow == fileId) return job;
  }
  return null;
}

/// The next job the host should pick up, or null.
///
/// One at a time, and that is a rule rather than a simplification: installing
/// runs `7z`, writes into the mods folder through a service held as a singleton,
/// and can raise a dialog. Two of those interleaving would race on all three.
DownloadJob? nextAwaitingHost(List<DownloadJob> jobs) {
  if (jobs.any((j) => j.state == DownloadJobState.installing)) return null;
  for (final job in jobs) {
    if (job.state != DownloadJobState.downloaded) continue;
    if (job.intent == DownloadIntent.callerHandles) continue;
    return job;
  }
  return null;
}

/// The single control a panel row offers.
///
/// One, never two: a row is three lines tall and a pair of buttons on it reads
/// as a decision the user has to make about a transfer they only wanted to
/// watch. Which one it is falls out of the state, which is why this is a
/// function rather than a per-state widget branch.
enum DownloadRowAction {
  /// Stop it. Deletes the partial — an explicit stop that quietly left half a
  /// gigabyte behind would be the surprising half.
  cancel,

  /// Fetch it again. Offered only where fetching again can help: a stalled or
  /// refused transfer.
  retry,

  /// Take the row off the list. Nothing is undone; it is already over.
  dismiss,

  /// Nothing to offer — the host is mid-install, and interrupting it between
  /// the unpack and the import is the one moment there is no safe stopping
  /// point.
  none,
}

/// Which control [job] gets, given everything else in the queue.
///
/// Two of the four answers depend on the rest of the list, so this takes it
/// rather than looking at one job in isolation:
///
/// - **A failure that another job is already re-fetching offers no retry.**
///   Pressing it would be refused by [DownloadQueue.retry] — one transfer per
///   file id, or two of them share a `.part` — and a button that silently does
///   nothing is worse than the row simply being history.
/// - **An install failure offers no retry either.** The bytes were fine; what
///   failed was the unpack, and re-fetching two hundred megabytes to hit the
///   same error is not a fix. It is a row to read and dismiss.
DownloadRowAction rowAction(DownloadJob job, List<DownloadJob> jobs) =>
    switch (job.state) {
      DownloadJobState.queued ||
      DownloadJobState.running ||
      DownloadJobState.downloaded =>
        DownloadRowAction.cancel,
      DownloadJobState.installing => DownloadRowAction.none,
      DownloadJobState.failed =>
        job.error is InstallFailure || activeJobForFile(jobs, job.file.idRow) != null
            ? DownloadRowAction.dismiss
            : DownloadRowAction.retry,
      DownloadJobState.done || DownloadJobState.cancelled =>
        DownloadRowAction.dismiss,
    };

/// How many jobs are still going to do something. Drives the panel's badge, so
/// it counts the queue as the user reads it — a queued job has not started, but
/// it is certainly not finished.
int activeJobCount(List<DownloadJob> jobs) =>
    jobs.where((j) => j.state.isActive).length;

/// Everything still in flight, as one figure.
///
/// One aggregation, two readers — the title bar's ring and the pinned progress
/// notification — so the button and the card can never disagree about how far
/// along the queue is.
class QueueProgress {
  const QueueProgress({
    required this.active,
    required this.transferring,
    required this.installing,
    required this.received,
    this.total,
    this.bytesPerSecond,
    this.eta,
  });

  static const QueueProgress none = QueueProgress(
    active: <DownloadJob>[],
    transferring: false,
    installing: false,
    received: 0,
  );

  /// Every job still going to do something, in queue order.
  final List<DownloadJob> active;

  /// At least one job holds a connection, i.e. bytes are actually moving.
  final bool transferring;

  /// At least one archive is being unpacked or imported.
  final bool installing;

  final int received;

  /// Null when **any** active job's size is unknown — a partial total would
  /// make the fraction jump the moment the missing size landed.
  final int? total;

  /// Summed across the transfers in flight, so it is the throughput the user is
  /// actually getting rather than one connection's share of it.
  final double? bytesPerSecond;

  final Duration? eta;

  bool get isEmpty => active.isEmpty;

  /// The one job this is about, when there is only one. Null for a queue of
  /// several, which is what keeps a count-bearing message from claiming one
  /// arbitrary mod's portrait.
  DownloadJob? get only => active.length == 1 ? active.single : null;

  /// Completion in 0..1, or null when it cannot honestly be given — in which
  /// case the UI shows an indeterminate indicator rather than inventing a
  /// number.
  double? get fraction {
    final size = total;
    if (size == null || size <= 0) return null;
    return (received / size).clamp(0.0, 1.0);
  }
}

/// Sums the queue.
///
/// **Weighed by bytes, never averaged over jobs** — a 1.2 GB archive and a 4 MB
/// one are not half the work each. A job whose bytes have landed counts as
/// whole: what is left of it is an unpack, which reports no progress of its own.
QueueProgress aggregateProgress(List<DownloadJob> jobs) {
  final active = [for (final job in jobs) if (job.state.isActive) job];
  if (active.isEmpty) return QueueProgress.none;

  var received = 0;
  var total = 0;
  var sizeKnown = true;
  var rate = 0.0;
  var rateKnown = false;
  var transferring = false;
  var installing = false;

  for (final job in active) {
    if (job.state.holdsConnection) transferring = true;
    if (job.state == DownloadJobState.downloaded ||
        job.state == DownloadJobState.installing) {
      installing = true;
    }

    final size = job.progress?.total ?? job.request.expectedSize;
    if (size == null || size <= 0) {
      sizeKnown = false;
    } else {
      total += size;
    }

    if (job.state == DownloadJobState.downloaded ||
        job.state == DownloadJobState.installing) {
      received += size ?? 0;
    } else {
      received += job.progress?.received ?? 0;
    }

    if (job.state.holdsConnection) {
      final jobRate = job.progress?.bytesPerSecond;
      if (jobRate != null) {
        rate += jobRate;
        rateKnown = true;
      }
    }
  }

  final knownTotal = sizeKnown && total > 0 ? total : null;
  // Derived here rather than taken from any one job: a per-job ETA describes
  // that transfer, and the queue finishes when the *last* byte lands.
  final eta = (knownTotal != null && rateKnown && rate > 0)
      ? Duration(
          seconds: ((knownTotal - received) / rate).clamp(0, 86400 * 7).round())
      : null;

  return QueueProgress(
    active: active,
    transferring: transferring,
    installing: installing,
    received: received,
    total: knownTotal,
    bytesPerSecond: rateKnown ? rate : null,
    eta: eta,
  );
}
