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
///
/// A resumed job goes first of the queued ones: it was running when the user paused it.
List<DownloadJob> admissions(
  List<DownloadJob> jobs, {
  int concurrency = kDownloadConcurrency,
}) {
  var running = jobs.where((j) => j.state.holdsConnection).length;
  final starting = <DownloadJob>[];

  // `jobs` is already in enqueue order (the queue only ever appends), so this
  // is first-in-first-out without a sort. Sorting by `seq` here would hide a
  // future caller that reorders the list.
  for (final job in [...jobs.where((j) => j.resumed), ...jobs.where((j) => !j.resumed)]) {
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
/// Terminal jobs are ignored on purpose: a finished or failed row is history,
/// and refusing to re-download something that failed is the opposite of what the
/// user pressing it again is asking for.
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
/// runs `7z` and writes into the mods folder through a service held as a
/// singleton. Two of those interleaving would race on both.
///
/// **A job that has waited goes ahead of jobs that have not.** Its user has just
/// answered its question, and is at the screen for what follows.
DownloadJob? nextAwaitingHost(List<DownloadJob> jobs) {
  if (jobs.any((j) => j.state == DownloadJobState.installing)) return null;
  DownloadJob? first;
  for (final job in jobs) {
    if (job.state != DownloadJobState.downloaded) continue;
    if (job.intent == DownloadIntent.callerHandles) continue;
    if (job.prepared != null || job.password != null) return job;
    first ??= job;
  }
  return first;
}

/// A control on a panel row. Which ones a row offers falls out of the state, which is why [rowActions] is a function
/// rather than a per-state widget branch.
enum DownloadRowAction {
  /// Stop a background transfer and keep its partial.
  pause,

  /// Put a paused transfer back in line.
  resume,

  /// Stop it. Deletes the partial, or the archive once the bytes have landed — an explicit stop that quietly left
  /// half a gigabyte behind would be the surprising half.
  cancel,

  /// Take a job that has not started off the queue.
  removeFromQueue,

  /// The waiting question's own button: Enter password, Install anyway, Pick folders… or Choose….
  answer,

  /// End a waiting install: what it kept is deleted and the row leaves the list.
  dontInstall,

  /// Open the download's mod page in Browse, where the author usually puts an archive's password.
  openModPage,

  /// Turn on the one mod the install created.
  turnOn,

  /// Show the mod in the Characters view, or the folder a saved archive is in.
  show,

  /// Fetch it again. Offered only where fetching again can help: a stalled or
  /// refused transfer.
  retry,

  /// Take a failed row off the list. Nothing is undone; it is already over.
  dismiss,
}

/// The controls [job] gets, given everything else in the queue: up to two, in the order they are drawn.
///
/// None while an install is between its unpack and its import, or an update is being written, where there is no
/// safe stopping point. For a finished install of one folder, [modIsOn] says whether that mod is on and
/// [modBeingWritten] whether its folder is being written; Turn on is offered while it is off and not being written,
/// Show once it is on.
///
/// Two answers depend on the rest of the list, so this takes it rather than looking at one job in isolation:
///
/// - **A failure that another job is already re-fetching offers no retry.**
///   Pressing it would be refused by [DownloadQueue.retry] — one transfer per
///   file id, or two of them share a `.part` — and a button that silently does
///   nothing is worse than the row simply being history.
/// - **An install failure offers no retry either.** The bytes were fine; what
///   failed was the unpack, and re-fetching two hundred megabytes to hit the
///   same error is not a fix. Neither does an update's: the update flow that
///   would consume a fresh download is gone.
List<DownloadRowAction> rowActions(
  DownloadJob job,
  List<DownloadJob> jobs, {
  bool Function(String modId)? modIsOn,
  bool Function(String modId)? modBeingWritten,
}) =>
    switch (job.state) {
      DownloadJobState.queued => const [DownloadRowAction.removeFromQueue],
      DownloadJobState.running => job.pausable
          ? const [DownloadRowAction.pause, DownloadRowAction.cancel]
          : const [DownloadRowAction.cancel],
      DownloadJobState.paused => const [DownloadRowAction.resume, DownloadRowAction.cancel],
      DownloadJobState.downloaded => const [DownloadRowAction.cancel],
      DownloadJobState.waiting => job.wait?.question == InstallQuestion.password
          ? [DownloadRowAction.answer, if (job.mod != null) DownloadRowAction.openModPage]
          : const [DownloadRowAction.answer, DownloadRowAction.dontInstall],
      DownloadJobState.installing || DownloadJobState.updating => const [],
      DownloadJobState.done => _finishedActions(job, modIsOn, modBeingWritten),
      DownloadJobState.failed => job.error is InstallFailure ||
              job.intent == DownloadIntent.callerHandles ||
              activeJobForFile(jobs, job.file.idRow) != null
          ? const [DownloadRowAction.dismiss]
          : const [DownloadRowAction.retry],
    };

List<DownloadRowAction> _finishedActions(
  DownloadJob job,
  bool Function(String modId)? modIsOn,
  bool Function(String modId)? modBeingWritten,
) {
  switch (job.outcome) {
    case JobOutcome.installed:
      if (job.installed.length != 1) return const [];
      final mod = job.installed.single;
      if (modIsOn?.call(mod) ?? false) return const [DownloadRowAction.show];
      if (modBeingWritten?.call(mod) ?? false) return const [];
      return const [DownloadRowAction.turnOn];
    case JobOutcome.updated:
    case JobOutcome.reinstalled:
    case JobOutcome.baseInstalled:
    case JobOutcome.saved:
      return const [DownloadRowAction.show];
    case JobOutcome.nothingInstalled:
    case null:
      return const [];
  }
}

/// The downloads in progress or waiting for a slot, paused included: the sidebar's plain count. A queued job has not
/// started, but it is certainly not finished. A waiting job is counted by [waitingJobCount] instead.
int activeJobCount(List<DownloadJob> jobs) =>
    jobs.where((j) => j.state.isActive && j.state != DownloadJobState.waiting).length;

/// The downloads waiting for the user's answer.
int waitingJobCount(List<DownloadJob> jobs) =>
    jobs.where((j) => j.state == DownloadJobState.waiting).length;

/// The failed rows still in the list.
int failedJobCount(List<DownloadJob> jobs) =>
    jobs.where((j) => j.state == DownloadJobState.failed).length;

/// Everything still in flight, as one figure.
///
/// One aggregation, two readers — the sidebar button's ring and the Working
/// progress notification — so the button and the card can never disagree about
/// how far along the queue is.
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
///
/// A paused job and one waiting for the user are left out, as nothing of either is moving.
QueueProgress aggregateProgress(List<DownloadJob> jobs) {
  final active = [
    for (final job in jobs)
      if (job.state.isActive && job.state != DownloadJobState.paused && job.state != DownloadJobState.waiting) job,
  ];
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
    final landed = job.state == DownloadJobState.downloaded ||
        job.state == DownloadJobState.installing ||
        job.state == DownloadJobState.updating;
    if (landed) installing = true;

    final size = job.progress?.total ?? job.request.expectedSize;
    if (size == null || size <= 0) {
      sizeKnown = false;
    } else {
      total += size;
    }

    if (landed) {
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
