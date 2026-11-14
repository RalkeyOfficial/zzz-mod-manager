import 'package:flutter/foundation.dart' show setEquals;

import '../../models/mod_download.dart';
import 'download_job.dart';
import 'update_job.dart';

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

// The four limits of an update run (`docs/update-runs.md` §4.1): constants with no setting, until a measured run says otherwise (§4.5).

/// D: update downloads at once, in a pool of their own beside [kDownloadConcurrency], so at most five connections.
const int kUpdateDownloadConcurrency = 3;

/// L, by number: update jobs ahead of the install ([isAheadOfInstall]).
const int kUpdateLookaheadCount = 3;

/// L, by size: 1 GiB of the listed sizes of the update jobs ahead of the install together, the one being admitted included.
const int kUpdateLookaheadBytes = 1024 * 1024 * 1024;

// U and I are honoured by the policy below, but `DownloadQueueHost` runs one loop per lane and awaits each job,
// so both are 1 in practice whatever they say.
// Raising either needs a host that runs jobs side by side, and its tests (U9).

/// U: update unpacks at once.
const int kUpdateUnpackConcurrency = 1;

/// The unpacked archives allowed to wait for the install, the one being unpacked counted as one already.
const int kUpdateUnpackedWaiting = 1;

/// I: writes into the mods folder at once, one chain for Browse installs and update writes.
const int kInstallChainConcurrency = 1;

/// Which of [jobs] should be started now.
///
/// Pure, and deliberately the only place the caps are applied:
/// the queue calls this after **every** state change rather than starting jobs from the several places one can finish,
/// so "a slot freed up" has one meaning and one implementation.
///
/// Two pools. Every job but an update's is in the first, oldest first, with two rules, and the second is the subtle one:
///
/// - a queued job starts while fewer than [concurrency] jobs of the pool hold a connection;
/// - a [DownloadJob.bypassesCap] job starts regardless. It still *counts*
///   towards the cap once running, so admitting one closes the door behind it
///   rather than raising the ceiling permanently.
///
/// A resumed job goes first of the queued ones: it was running when the user paused it.
///
/// Update jobs are the second pool ([updateAdmissions]).
List<DownloadJob> admissions(
  List<DownloadJob> jobs, {
  int concurrency = kDownloadConcurrency,
  int updateConcurrency = kUpdateDownloadConcurrency,
  int lookaheadCount = kUpdateLookaheadCount,
  int lookaheadBytes = kUpdateLookaheadBytes,
}) {
  var running = jobs.where((j) => j.state.holdsConnection && !j.isUpdate).length;
  final starting = <DownloadJob>[];

  // `jobs` is already in enqueue order (the queue only ever appends), so this
  // is first-in-first-out without a sort. Sorting by `seq` here would hide a
  // future caller that reorders the list.
  for (final job in [...jobs.where((j) => j.resumed), ...jobs.where((j) => !j.resumed)]) {
    if (job.state != DownloadJobState.queued || job.isUpdate) continue;
    if (job.bypassesCap) {
      starting.add(job);
      running++;
      continue;
    }
    if (running >= concurrency) continue;
    starting.add(job);
    running++;
  }
  return [
    ...starting,
    ...updateAdmissions(
      jobs,
      concurrency: updateConcurrency,
      lookaheadCount: lookaheadCount,
      lookaheadBytes: lookaheadBytes,
    ),
  ];
}

/// The update jobs to start downloading now: the jobs of [updateLine] that [updateHolds] holds nothing back.
List<DownloadJob> updateAdmissions(
  List<DownloadJob> jobs, {
  int concurrency = kUpdateDownloadConcurrency,
  int lookaheadCount = kUpdateLookaheadCount,
  int lookaheadBytes = kUpdateLookaheadBytes,
}) {
  final holds = updateHolds(jobs, concurrency: concurrency, lookaheadCount: lookaheadCount, lookaheadBytes: lookaheadBytes);
  return [for (final job in updateLine(jobs)) if (!holds.containsKey(job.seq)) job];
}

/// Why a job in [updateLine] is not started now.
enum UpdateHold {
  /// An earlier job of the run has not finished with its folder. It waits in line without holding a place.
  folder,

  /// The lookahead refuses it, or refused a job ahead of it in line.
  lookahead,

  /// The download pool is full.
  pool,
}

/// Why each job of [updateLine] that is not started now waits, by `seq`; a job that is started is not in it.
/// The one walk of the line that both [updateAdmissions] and a queued row's words ([updateQueuedPlace]) read.
///
/// In line order: a job whose folder an earlier job of the run has not finished with is passed over,
/// so the lookahead never fills with jobs that cannot go on.
/// The line stops at the first job the lookahead refuses ([lookaheadAdmits]), and every job behind it waits for the lookahead too.
/// The line is smallest first, so only a job sent to the end of it (a stalled or retried one) could otherwise pass a large file the lookahead refused,
/// and a large file runs alone once nothing is ahead.
/// A job the lookahead admits waits for the pool while [concurrency] update jobs are downloading.
Map<int, UpdateHold> updateHolds(
  List<DownloadJob> jobs, {
  int concurrency = kUpdateDownloadConcurrency,
  int lookaheadCount = kUpdateLookaheadCount,
  int lookaheadBytes = kUpdateLookaheadBytes,
}) {
  var running = jobs.where((j) => j.isUpdate && j.state.holdsConnection).length;
  final ahead = [
    for (final job in jobs)
      if (isAheadOfInstall(job) && !isHeldByPipeline(job, jobs)) job,
  ];
  var aheadCount = ahead.length;
  var aheadBytes = ahead.fold(0, (sum, job) => sum + listedSize(job));
  var stopped = false;
  final holds = <int, UpdateHold>{};
  for (final job in updateLine(jobs)) {
    if (!folderPipelineFree(job, jobs)) {
      holds[job.seq] = UpdateHold.folder;
      continue;
    }
    final size = listedSize(job);
    stopped = stopped ||
        !lookaheadAdmits(
          aheadCount: aheadCount,
          aheadBytes: aheadBytes,
          size: size,
          maxCount: lookaheadCount,
          maxBytes: lookaheadBytes,
        );
    if (stopped) {
      holds[job.seq] = UpdateHold.lookahead;
    } else if (running >= concurrency) {
      holds[job.seq] = UpdateHold.pool;
    } else {
      running++;
      aheadCount++;
      aheadBytes += size;
    }
  }
  return holds;
}

/// The size a job's file lists on GameBanana, 0 when it lists none.
int listedSize(DownloadJob job) => job.file.filesize ?? 0;

/// Whether [job] is ahead of the install under the lookahead:
/// an update job from the start of its download to the end of its install, or until it is skipped, fails or is removed.
/// A transfer arriving, a landed archive, one being unpacked, one unpacked and waiting for the install, and one waiting on a question are all ahead.
bool isAheadOfInstall(DownloadJob job) =>
    job.isUpdate &&
    switch (job.state) {
      DownloadJobState.running ||
      DownloadJobState.paused ||
      DownloadJobState.downloaded ||
      DownloadJobState.waiting ||
      DownloadJobState.updating =>
        true,
      _ => false,
    };

/// L: whether one more job of [size] may start downloading with [aheadCount] jobs of [aheadBytes] ahead of the install.
/// Both caps must hold, the job being admitted counted in the bytes,
/// and one job is always admitted when none is ahead, so a file over the byte cap on its own cannot wait forever.
bool lookaheadAdmits({
  required int aheadCount,
  required int aheadBytes,
  required int size,
  int maxCount = kUpdateLookaheadCount,
  int maxBytes = kUpdateLookaheadBytes,
}) {
  if (aheadCount == 0) return true;
  return aheadCount < maxCount && aheadBytes + size <= maxBytes;
}

/// The queued update jobs in the order they start: smallest listed file first, so the first mods are updated within seconds,
/// a job sent to the end of the line ([DownloadJob.deferred]) after every other, and equal sizes in the order they were asked for.
/// A job a halt holds back is not in line.
List<DownloadJob> updateLine(List<DownloadJob> jobs) {
  final line = [
    for (final job in jobs)
      if (job.isUpdate && job.state == DownloadJobState.queued && job.halt == null) job,
  ];
  line.sort((a, b) {
    if (a.deferred != b.deferred) return a.deferred ? 1 : -1;
    final bySize = listedSize(a).compareTo(listedSize(b));
    return bySize != 0 ? bySize : a.seq.compareTo(b.seq);
  });
  return line;
}

/// Whether [job]'s folders are free of every update job asked for before it that has not ended.
/// A folder has one write pipeline at a time, so a base and a patch of one folder run one after the other, in the order asked for.
/// `DownloadQueue.enqueueUpdates` asks for a press's bases before its patches, so within a press that is base first.
bool folderPipelineFree(DownloadJob job, List<DownloadJob> jobs) {
  final folders = job.update?.folders ?? const <String>{};
  if (folders.isEmpty) return true;
  for (final other in jobs) {
    if (other.seq >= job.seq || !other.isUpdate || other.isTerminal) continue;
    if (other.update!.folders.any(folders.contains)) return false;
  }
  return true;
}

/// Whether [job] has landed or been unpacked and waits for an earlier job of its folder to end.
///
/// The admission keeps a job out of the line while its folder is held,
/// so this happens only when the earlier job came after it went past the line: it was tried again, or a pick of an earlier job's file joined it.
/// Such a job counts under neither the lookahead nor the one unpacked place, since it cannot go on until the earlier job has,
/// and counting it would let it hold the very places that job needs.
bool isHeldByPipeline(DownloadJob job, List<DownloadJob> jobs) =>
    job.isUpdate &&
    (job.state == DownloadJobState.downloaded || _isUpdateAt(job, UpdateStep.unpacked)) &&
    !folderPipelineFree(job, jobs);

/// The update jobs in the unpack and install lanes go in this order:
/// one that waited on a question first, then the smaller, then the one asked for first.
int _laneOrder(DownloadJob a, DownloadJob b) {
  if (a.hasWaited != b.hasWaited) return a.hasWaited ? -1 : 1;
  final bySize = listedSize(a).compareTo(listedSize(b));
  return bySize != 0 ? bySize : a.seq.compareTo(b.seq);
}

bool _isUpdateAt(DownloadJob job, UpdateStep step) =>
    job.isUpdate && job.state == DownloadJobState.updating && job.updateStep == step;

/// U: the next landed update job to unpack and preview, or null.
///
/// None while [closing], while [concurrency] unpacks run, or while the archives unpacking and unpacked together reach [waiting]:
/// what an unpack produces is the one archive allowed to wait for the install.
/// An unpacked job held by its folder's pipeline ([isHeldByPipeline]) does not count.
/// A job a halt holds back, or whose folder an earlier job of the run has not finished with, waits.
DownloadJob? nextUpdateToUnpack(
  List<DownloadJob> jobs, {
  bool closing = false,
  int concurrency = kUpdateUnpackConcurrency,
  int waiting = kUpdateUnpackedWaiting,
}) {
  if (closing) return null;
  final unpacking = jobs.where((j) => _isUpdateAt(j, UpdateStep.unpacking)).length;
  final unpacked =
      jobs.where((j) => _isUpdateAt(j, UpdateStep.unpacked) && !isHeldByPipeline(j, jobs)).length;
  if (unpacking >= concurrency || unpacking + unpacked >= waiting) return null;
  final candidates = [
    for (final job in jobs)
      if (job.isUpdate &&
          job.state == DownloadJobState.downloaded &&
          job.halt == null &&
          folderPipelineFree(job, jobs))
        job,
  ]..sort(_laneOrder);
  return candidates.firstOrNull;
}

/// How many writes into the mods folder are running: a Browse install, or an update job writing.
int _installChainBusy(List<DownloadJob> jobs) =>
    jobs.where((j) => j.state == DownloadJobState.installing || _isUpdateAt(j, UpdateStep.writing)).length;

/// I: the next unpacked update job to write, or null while the install chain is full or [closing].
DownloadJob? nextUpdateToWrite(
  List<DownloadJob> jobs, {
  bool closing = false,
  int concurrency = kInstallChainConcurrency,
}) {
  if (closing || _installChainBusy(jobs) >= concurrency) return null;
  final candidates = [
    for (final job in jobs)
      if (_isUpdateAt(job, UpdateStep.unpacked) && job.halt == null && folderPipelineFree(job, jobs)) job,
  ]..sort(_laneOrder);
  return candidates.firstOrNull;
}

/// The next job for the install chain, a Browse install or an update's write, or null.
///
/// One that waited on a question goes first, then the one asked for first.
/// Nothing starts once [closing]: the app is about to exit, and a write it began would be cut off.
DownloadJob? nextForInstallChain(
  List<DownloadJob> jobs, {
  bool closing = false,
  int concurrency = kInstallChainConcurrency,
}) {
  final install = nextAwaitingHost(jobs, closing: closing, concurrency: concurrency);
  final update = nextUpdateToWrite(jobs, closing: closing, concurrency: concurrency);
  if (install == null || update == null) return install ?? update;
  if (install.hasWaited != update.hasWaited) return install.hasWaited ? install : update;
  return install.seq < update.seq ? install : update;
}

/// The halt holding the run, if one is: the halt of the first job that has not ended and carries one.
/// Every job a halt holds carries the same one, so which job it is read from matters only for being one rule.
UpdateHalt? currentHalt(List<DownloadJob> jobs) {
  for (final job in jobs) {
    if (job.isUpdate && !job.isTerminal && job.halt != null) return job.halt;
  }
  return null;
}

/// Whether a pick for [existing]'s file can join it: an update job that has not waited and whose bytes have not been unpacked.
/// A later pick could not join an unpack already made, and two transfers of one file share a `.part`.
bool joinsUpdateJob(DownloadJob existing) =>
    existing.isUpdate &&
    !existing.hasWaited &&
    (existing.state == DownloadJobState.queued ||
        existing.state == DownloadJobState.running ||
        existing.state == DownloadJobState.downloaded);

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

/// The next Browse install or saved archive the host should pick up, or null.
///
/// One at a time, and that is a rule rather than a simplification:
/// installing runs `7z` and writes into the mods folder through a service held as a singleton, and two of those interleaving would race on both.
/// An update's write is on the same chain, and nothing starts once [closing].
///
/// **A job that has waited goes ahead of jobs that have not.** Its user has just
/// answered its question, and is at the screen for what follows.
DownloadJob? nextAwaitingHost(
  List<DownloadJob> jobs, {
  bool closing = false,
  int concurrency = kInstallChainConcurrency,
}) {
  if (closing || _installChainBusy(jobs) >= concurrency) return null;
  DownloadJob? first;
  for (final job in jobs) {
    if (job.state != DownloadJobState.downloaded) continue;
    if (job.intent == DownloadIntent.callerHandles || job.isUpdate) continue;
    if (job.hasWaited) return job;
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

  /// End a waiting update: nothing is written, what it kept is deleted, and the row stays as skipped.
  skipUpdate,

  /// Update anyway, the answer to an update whose folder holds a patch nothing records, given on the row itself.
  updateAnyway,

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
/// None while an install is between its unpack and its import, or an update is being unpacked or written,
/// where there is no safe stopping point ([DownloadJob.cancellable]).
/// For a finished install of one folder, [modIsOn] says whether that mod is on and [modBeingWritten] whether its folder is being written;
/// Turn on is offered while it is off and not being written, Show once it is on.
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
      DownloadJobState.waiting when job.isUpdate => [
          job.updateWait?.question == UpdateQuestionKind.unrecordedPatch
              ? DownloadRowAction.updateAnyway
              : DownloadRowAction.answer,
          DownloadRowAction.skipUpdate,
        ],
      // A failed update is only taken off the list: no Try again is offered on it.
      DownloadJobState.failed when job.isUpdate => const [DownloadRowAction.dismiss],
      DownloadJobState.waiting => job.wait?.question == InstallQuestion.password
          ? [DownloadRowAction.answer, if (job.mod != null) DownloadRowAction.openModPage]
          : const [DownloadRowAction.answer, DownloadRowAction.dontInstall],
      DownloadJobState.installing ||
      DownloadJobState.updating =>
        job.cancellable ? const [DownloadRowAction.cancel] : const [],
      DownloadJobState.done => _finishedActions(job, modIsOn, modBeingWritten),
      DownloadJobState.failed => job.error is InstallFailure ||
              job.error is UpdateFailure ||
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
  // An update run's finished row offers Undo in this place, per mod, which reads more than the job (`docs/update-runs.md` §8).
  if (job.isUpdate) return const [];
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
    case JobOutcome.patchAdded:
    case JobOutcome.saved:
      return const [DownloadRowAction.show];
    case JobOutcome.nothingInstalled:
    case JobOutcome.skipped:
    case JobOutcome.undone:
    case null:
      return const [];
  }
}

/// An update run as the surfaces count it. The run has no object of its own: this is read off the jobs.
class UpdateRunSummary {
  const UpdateRunSummary({this.live = 0, this.asking = 0, this.done = 0, this.failed = 0, this.halt});

  static const UpdateRunSummary none = UpdateRunSummary();

  /// Update jobs still going to do something without the user: queued, downloading, unpacking, waiting for the install or writing.
  final int live;

  /// Update jobs waiting on a question.
  final int asking;

  /// Update jobs that ended without failing, skipped and undone ones included.
  final int done;

  final int failed;

  /// What stopped the run, while it is stopped.
  final UpdateHalt? halt;

  bool get isEmpty => live == 0 && asking == 0 && done == 0 && failed == 0;
}

UpdateRunSummary summariseUpdateRun(List<DownloadJob> jobs) {
  var live = 0;
  var asking = 0;
  var done = 0;
  var failed = 0;
  for (final job in jobs) {
    if (!job.isUpdate) continue;
    switch (job.state) {
      case DownloadJobState.waiting:
        asking++;
      case DownloadJobState.done:
        done++;
      case DownloadJobState.failed:
        failed++;
      default:
        live++;
    }
  }
  return UpdateRunSummary(live: live, asking: asking, done: done, failed: failed, halt: currentHalt(jobs));
}

/// One mod's place in an update run, for its row: the job, and once the job has ended what it came to for this mod.
class ModUpdateState {
  const ModUpdateState(this.job, this.result);

  final DownloadJob job;

  /// Null while the job has not ended, unless this mod was skipped at its question while the job goes on.
  /// A job writes some of its mods and not others, so the job's own outcome is not this mod's.
  final UpdateModResult? result;

  // The queue replaces only the jobs that change, so the same job object means nothing about this mod's row changed,
  // and a tick of another download does not rebuild it.
  @override
  bool operator ==(Object other) =>
      other is ModUpdateState && identical(other.job, job) && identical(other.result, result);

  @override
  int get hashCode => Object.hash(identityHashCode(job), identityHashCode(result));
}

/// The update job of the mod [modId] for its row: the one still going if there is one,
/// else the last that ended and is still in the list, with what it came to for this mod.
ModUpdateState? updateJobOfMod(List<DownloadJob> jobs, String modId) {
  DownloadJob? ended;
  for (final job in jobs.reversed) {
    if (!job.isUpdate || !job.update!.folders.contains(modId)) continue;
    if (!job.isTerminal) return ModUpdateState(job, job.resultFor(modId));
    ended ??= job;
  }
  return ended == null ? null : ModUpdateState(ended, ended.resultFor(modId));
}

/// Whether Clear finished takes [job] off the list: an ended job, except a failed update, which waits in Needs your
/// attention until Remove from the list.
bool clearedByClearFinished(DownloadJob job) =>
    job.isTerminal && !(job.isUpdate && job.state == DownloadJobState.failed);

/// Whether a job of the run that has not ended already holds [mod]'s layer: a second press for it adds nothing.
bool layerInRun(List<DownloadJob> jobs, UpdateMod mod) => jobs.any(
      (job) => job.isUpdate && !job.isTerminal && job.update!.mods.any(mod.sameLayerAs),
    );

/// Every layer [layerInRun] holds, as one value that compares equal while the layers do, so a provider selecting it
/// is not told about a progress tick.
LayersInRun layersInRun(List<DownloadJob> jobs) => LayersInRun({
      for (final job in jobs)
        if (job.isUpdate && !job.isTerminal)
          for (final mod in job.update!.mods) (mod.modId, mod.layer),
    });

class LayersInRun {
  const LayersInRun(this._layers);

  final Set<(String, DownloadKey)> _layers;

  bool get isEmpty => _layers.isEmpty;

  bool contains(String modId, DownloadKey layer) => _layers.contains((modId, layer));

  @override
  bool operator ==(Object other) => other is LayersInRun && setEquals(other._layers, _layers);

  @override
  int get hashCode => Object.hashAllUnordered(_layers);
}

/// How far along an update job is, lower first: what the Updating group of the panel and the deck's front card go by
/// (`docs/update-runs.md` §4.6). Writing, then unpacked and waiting for the write, then unpacking, then landed, then
/// downloading, then waiting. A job the halt holds at a gate (landed, unpacked or in line) is with the waiting, last.
int _workRank(DownloadJob job) => switch (job.state) {
      _ when job.halt != null && _heldAtGate(job) => 5,
      DownloadJobState.updating => switch (job.updateStep) {
          UpdateStep.writing => 0,
          UpdateStep.unpacked => 1,
          _ => 2,
        },
      DownloadJobState.downloaded => 3,
      DownloadJobState.running || DownloadJobState.paused => 4,
      _ => 5,
    };

/// Whether [job] is at a gate a halt stops it at: in line, landed, or unpacked and waiting for the write.
/// A transfer or an unpack under way goes on to the next gate.
bool _heldAtGate(DownloadJob job) => switch (job.state) {
      DownloadJobState.queued || DownloadJobState.paused || DownloadJobState.downloaded => true,
      DownloadJobState.updating => job.updateStep == UpdateStep.unpacked,
      _ => false,
    };

/// The update jobs still at work without the user (not waiting on a question, not ended), in the order of work:
/// the furthest along first, a download by how much has arrived, and the queued ones in the order they start, then the
/// ones a halt holds. Ties go by the order they were asked for.
List<DownloadJob> updatesInOrderOfWork(List<DownloadJob> jobs) {
  final line = {for (final (i, job) in updateLine(jobs).indexed) job.seq: i};
  final working = [
    for (final job in jobs)
      if (job.isUpdate && !job.isTerminal && job.state != DownloadJobState.waiting) job,
  ];
  int byPlace(DownloadJob a, DownloadJob b) {
    final rank = _workRank(a).compareTo(_workRank(b));
    if (rank != 0) return rank;
    if (_workRank(a) == 4) {
      final arrived = (b.progress?.fraction ?? 0).compareTo(a.progress?.fraction ?? 0);
      if (arrived != 0) return arrived;
    }
    if (_workRank(a) == 5) {
      final place = (line[a.seq] ?? line.length).compareTo(line[b.seq] ?? line.length);
      if (place != 0) return place;
    }
    return a.seq.compareTo(b.seq);
  }

  return working..sort(byPlace);
}

/// What a queued update job waits for, for its dimmed row (`docs/update-runs.md` §4.6, §10).
sealed class UpdateQueuedPlace {
  const UpdateQueuedPlace();
}

/// First in line: it starts as soon as a download slot frees.
final class DownloadsNext extends UpdateQueuedPlace {
  const DownloadsNext();
}

/// [count] queued jobs start before it.
final class AheadOfIt extends UpdateQueuedPlace {
  const AheadOfIt(this.count);

  final int count;
}

/// First in line and held by the lookahead (or by an earlier job of its folder) while something ahead of it is moving.
final class WaitsForInstall extends UpdateQueuedPlace {
  const WaitsForInstall();
}

/// First in line and held by the lookahead, with every job ahead of it waiting on a question: nothing frees a place
/// until the user answers.
final class WaitsForAnswers extends UpdateQueuedPlace {
  const WaitsForAnswers();
}

/// Held by the run's halt.
final class StoppedBy extends UpdateQueuedPlace {
  const StoppedBy(this.halt);

  final UpdateHalt halt;
}

/// Where the queued update job [job] stands, given everything else in the queue.
/// [holds] is [updateHolds] of [jobs] when the caller has it already, as a list of rows does once for all of them.
UpdateQueuedPlace updateQueuedPlace(
  DownloadJob job,
  List<DownloadJob> jobs, {
  Map<int, UpdateHold>? holds,
  int concurrency = kUpdateDownloadConcurrency,
  int lookaheadCount = kUpdateLookaheadCount,
  int lookaheadBytes = kUpdateLookaheadBytes,
}) {
  if (job.halt case final halt?) return StoppedBy(halt);
  holds ??= updateHolds(jobs, concurrency: concurrency, lookaheadCount: lookaheadCount, lookaheadBytes: lookaheadBytes);
  final hold = holds[job.seq];
  UpdateQueuedPlace held() {
    final ahead = [
      for (final other in jobs)
        if (isAheadOfInstall(other) && !isHeldByPipeline(other, jobs)) other,
    ];
    return ahead.isNotEmpty && ahead.every((j) => j.state == DownloadJobState.waiting)
        ? const WaitsForAnswers()
        : const WaitsForInstall();
  }

  // Passed over in line until the earlier job of its folder has ended.
  if (hold == UpdateHold.folder) return held();
  final line = [for (final j in updateLine(jobs)) if (holds[j.seq] != UpdateHold.folder) j];
  final place = line.indexWhere((j) => j.seq == job.seq);
  if (place > 0) return AheadOfIt(place);
  return hold == UpdateHold.lookahead ? held() : const DownloadsNext();
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
