import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/gamebanana/gb_file.dart';
import '../../models/gamebanana/gb_mod.dart';
import '../archive_service.dart';
import '../log/confirmations.dart';
import '../log/logger.dart';
import '../writes_in_flight.dart';
import 'download_exceptions.dart';
import 'download_handle.dart';
import 'download_job.dart';
import 'download_progress.dart';
import 'download_request.dart';
import 'download_service.dart';
import 'queue_policy.dart';
import 'update_job.dart';

final Logger _log = Logger('update');

/// The mod-archive downloader.
///
/// Shared rather than per-screen so the resume bookkeeping in
/// `<appData>/downloads` has a single owner, and so a download survives the
/// user navigating away from the screen that started it.
///
/// Lives here rather than in the `state_providers.dart` registry because
/// [DownloadQueue] is its only consumer and the two would otherwise import each
/// other. The registry carries a pointer.
final downloadServiceProvider = Provider<DownloadService>((ref) {
  final service = DownloadService();
  ref.onDispose(service.close);
  return service;
});

/// Every transfer the app is making, in the order it was asked for.
///
/// One instance for the whole session. Nothing here is persisted: a queue
/// restored from disk would start re-fetching files on launch, and the partials
/// on disk are already the durable half — an interrupted job is resumed by
/// asking for it again, not by remembering that it was asked for.
final downloadQueueProvider =
    NotifierProvider<DownloadQueue, List<DownloadJob>>(DownloadQueue.new);

/// The update run as the Updates page, the panel, the deck and the badge count it.
final updateRunSummaryProvider =
    Provider<UpdateRunSummary>((ref) => summariseUpdateRun(ref.watch(downloadQueueProvider)));

/// The update job of a mod, by folder id, for its Updates row:
/// the one going, else the last that ended, with what it came to for that mod.
final updateJobOfModProvider = Provider.family<ModUpdateState?, String>(
  (ref, modId) => updateJobOfMod(ref.watch(downloadQueueProvider), modId),
);

/// How an update download ended, told to [DownloadQueue.endUpdate].
sealed class UpdateEnd {
  const UpdateEnd();
}

/// The update wrote the mod: the row is Finished with [outcome].
class UpdateWritten extends UpdateEnd {
  const UpdateWritten(this.outcome, {this.mods = const <String>[]});

  /// [JobOutcome.updated], [JobOutcome.reinstalled] or [JobOutcome.baseInstalled].
  final JobOutcome outcome;

  /// The mod folders it wrote, the one the row's Show opens first.
  final List<String> mods;
}

/// The user declined or cancelled the update: the row leaves the list.
class UpdateDeclined extends UpdateEnd {
  const UpdateDeclined();
}

/// The update failed after its bytes landed: the row is a failure with the flow's own [headline].
class UpdateFailed extends UpdateEnd {
  const UpdateFailed(this.headline);

  final String headline;
}

/// Runs downloads with a concurrency cap, and remembers what each one was for.
///
/// **The queue moves bytes and nothing else.** What happens when a transfer
/// lands — importing the archive, saying where it went — belongs to
/// `DownloadQueueHost`, a widget mounted above the tabs: those steps need
/// localized strings and can raise a dialog, and neither is available here. The
/// handover is the [DownloadJobState.downloaded] state, which is why that is a
/// real state rather than an instant.
///
/// That split is what makes backgrounding possible at all: a tab's
/// `BuildContext` dies on the next tab switch, so work that outlives the press
/// which started it cannot be owned by a tab. See `docs/downloads.md` §8.
class DownloadQueue extends Notifier<List<DownloadJob>> {
  final Map<int, DownloadHandle> _handles = {};
  final Map<int, StreamSubscription<DownloadProgress>> _subscriptions = {};
  final Map<int, Completer<DownloadResult>> _completions = {};

  /// Paused jobs whose Resume came before the stop their pause asked for, resumed once it lands.
  final Set<int> _resumeAfterStop = {};

  /// When each update job entered the stage it is in, for the per-stage timings in the log.
  final Map<int, DateTime> _stageSince = {};
  int _nextSeq = 1;

  @override
  List<DownloadJob> build() {
    ref.onDispose(_shutdown);
    return const [];
  }

  DownloadService get _service => ref.read(downloadServiceProvider);

  /// Asks for a file, or hands back the job already fetching it.
  ///
  /// De-duplicated on the **file id** rather than the url, because that is the
  /// identity GameBanana guarantees and it is what a double-click on the same
  /// row means. Only non-terminal jobs count: pressing Download again after a
  /// failure is a request to retry, not a duplicate. A paused job for the file is
  /// resumed, since the press asks for the file, and from then on does what this
  /// press asks: its intent, its character and its Turn on.
  DownloadJob enqueue({
    required GbFile file,
    required String subject,
    required DownloadIntent intent,
    GbMod? mod,
    String? characterId,
    bool turnOn = false,
  }) {
    final existing = activeJobForFile(state, file.idRow);
    if (existing != null) {
      if (existing.state == DownloadJobState.paused) {
        _replace(
          existing.seq,
          (j) => j.pressedAgain(
            intent: intent,
            subject: subject,
            mod: mod,
            characterId: characterId,
            turnOn: turnOn,
          ),
        );
        resume(existing.seq);
        return _jobOf(existing.seq)!;
      }
      return existing;
    }
    return _add(file: file, subject: subject, intent: intent, mod: mod, characterId: characterId, turnOn: turnOn);
  }

  /// Adds an update job for [file] that writes the mods of [task] (`docs/update-runs.md` §1), or answers null when it adds nothing.
  ///
  /// A mod whose layer is already in a job of the run that has not ended is left out, so a second press for it adds nothing.
  /// Mods picked with the same file are one job: one download, one unpack and one write per folder, in order.
  /// A pick for a file that an update job is still fetching, or that has landed and not been unpacked, joins that job ([joinsUpdateJob]);
  /// one for a file any other job holds adds nothing, since two transfers of one file share a `.part`.
  ///
  /// A job added while the run is halted is held back by the same halt.
  DownloadJob? enqueueUpdate({
    required GbFile file,
    required String subject,
    required UpdateTask task,
    String? characterId,
  }) =>
      enqueueUpdates([UpdateEnqueue(file: file, subject: subject, task: task, characterId: characterId)]).single;

  /// [enqueueUpdate] for every file of one press, answering each one's job or null in the same order they came in.
  ///
  /// The jobs are all in line before any starts, so the smallest file of the press starts first whatever order they came in.
  /// A press's bases are asked for before its patches, so a folder's pipeline writes its base first.
  List<DownloadJob?> enqueueUpdates(List<UpdateEnqueue> presses) {
    int rank(UpdateEnqueue press) => press.task.mods.every((mod) => mod.isPatchLayer) ? 1 : 0;
    final order = [for (var i = 0; i < presses.length; i++) i]
      ..sort((a, b) {
        final byLayer = rank(presses[a]).compareTo(rank(presses[b]));
        return byLayer != 0 ? byLayer : a.compareTo(b);
      });
    final added = List<DownloadJob?>.filled(presses.length, null);
    for (final i in order) {
      added[i] = _enqueueUpdate(presses[i]);
    }
    _pump();
    return [for (final job in added) job == null ? null : _jobOf(job.seq)];
  }

  DownloadJob? _enqueueUpdate(UpdateEnqueue press) {
    final UpdateEnqueue(:file, :subject, :task, :characterId) = press;
    final mods = <UpdateMod>[];
    for (final mod in task.mods) {
      if (layerInRun(state, mod) || mods.any(mod.sameLayerAs)) continue;
      mods.add(mod);
    }
    if (mods.isEmpty) return null;

    final existing = activeJobForFile(state, file.idRow);
    if (existing != null) {
      if (!joinsUpdateJob(existing)) {
        _log.info('update not added, its file is already in another job',
            fields: {'mod': mods.first.modId, 'file_id': file.idRow});
        return null;
      }
      _replace(existing.seq, (j) => j.copyWith(update: j.update!.withMods([...j.update!.mods, ...mods])));
      return _jobOf(existing.seq);
    }

    return _add(
      file: file,
      subject: subject,
      intent: DownloadIntent.update,
      characterId: characterId,
      update: task.withMods(mods),
      halt: currentHalt(state),
      pump: false,
    );
  }

  DownloadJob _add({
    required GbFile file,
    required String subject,
    required DownloadIntent intent,
    GbMod? mod,
    String? characterId,
    bool turnOn = false,
    UpdateTask? update,
    UpdateHalt? halt,
    bool pump = true,
  }) {
    // Unique among the jobs in the list, whatever put them there.
    for (final job in state) {
      if (job.seq >= _nextSeq) _nextSeq = job.seq + 1;
    }
    final seq = _nextSeq++;
    final raw = file.downloadUrl ?? 'https://gamebanana.com/dl/${file.idRow}';
    final url = Uri.tryParse(raw);

    if (url == null) {
      // Arrives as a failed row rather than as a null return. Callers read a
      // null as "already reported", so refusing quietly here would make pressing
      // Download do nothing at all — and a panel that omits the one job which
      // could not start is the same silence one layer down.
      final job = DownloadJob(
        seq: seq,
        request: DownloadRequest(url: Uri()),
        intent: intent,
        subject: subject,
        file: file,
        mod: mod,
        characterId: characterId,
        turnOn: turnOn,
        state: DownloadJobState.failed,
        error: DownloadNetworkException('Unusable download url: $raw'),
        finishedAt: DateTime.now(),
        update: update,
      );
      state = [...state, job];
      _completerFor(seq).completeError(job.error!);
      return job;
    }

    final job = DownloadJob(
      seq: seq,
      request: DownloadRequest(
        url: url,
        suggestedFilename: file.file,
        fileId: file.idRow,
        // `_nFilesize` is exactly the eventual Content-Length, so it is a
        // reliable progress denominator from the first frame.
        expectedSize: file.filesize,
        expectedMd5: file.md5Checksum,
      ),
      intent: intent,
      subject: subject,
      file: file,
      mod: mod,
      characterId: characterId,
      turnOn: turnOn,
      update: update,
      halt: halt,
    );
    state = [...state, job];
    _completerFor(seq);
    if (pump) _pump();
    return job;
  }

  /// Completes with the archive, or throws a `DownloadException`.
  ///
  /// The seam [DownloadIntent.callerHandles] is built on. Safe to await for a
  /// job that has already finished — the completer outlives the transfer and is
  /// only dropped when the row is cleared.
  Future<DownloadResult> completionOf(int seq) => _completerFor(seq).future;

  /// Progress for one job, for a caller that wants to watch it directly rather
  /// than through the panel. Empty and closed once the job is terminal.
  Stream<DownloadProgress> progressOf(int seq) =>
      _handles[seq]?.progress ?? const Stream<DownloadProgress>.empty();

  /// Stops a job, whether it has started or not, and takes its row off the list.
  ///
  /// What it stops is deleted: the partial of a running, paused or resumed transfer,
  /// the archive of one whose bytes have landed, and what a waiting or answered install kept.
  /// This is an explicit user cancel, and leaving several hundred megabytes in a folder
  /// they do not manage is the surprising half of "stop". It records no error: the
  /// user asked for it.
  ///
  /// **An installing job, and an update job that is unpacking or writing, cannot be cancelled** ([DownloadJob.cancellable]),
  /// and the refusal belongs here rather than only in the button that does not offer it.
  /// Between the unpack and the import there is no safe stopping point,
  /// and this method's own archive delete below would pull the file out from under a running extraction.
  /// An update job that is unpacked and waits for the install lane can be cancelled: it holds only its unpack.
  Future<void> cancel(int seq) async {
    final job = _jobOf(seq);
    if (job == null || !job.cancellable) return;
    if (job.state == DownloadJobState.waiting && !job.isUpdate) return decline(seq);

    final handle = _handles[seq];
    // A paused job can still hold its handle while the stop its pause asked for comes back, and cancelling that
    // handle again does nothing.
    if (handle != null && job.state != DownloadJobState.paused) {
      await handle.cancel(deletePartial: true);
      return;
    }

    // Not started, paused, resumed and back in line, or finished and waiting on the host. No transfer to unwind,
    // so removing it here is the only thing that moves it.
    _resumeAfterStop.remove(seq);
    _completeError(seq, const DownloadCancelledException());
    _drop(seq);
    _pump();
    await _discard(job, handle);
  }

  /// Deletes what [job], taken off the list, held: its transfer and partial, its archive, its unpacked folders.
  ///
  /// A job cancelled *after* the bytes landed still has an archive in `<appData>/downloads`, or the folders an answered question kept,
  /// and nothing else will ever come for them, since the install that would have consumed them is what is being called off.
  /// So they go now, for the same reason a cancelled transfer deletes its partial.
  Future<void> _discard(DownloadJob job, DownloadHandle? handle) async {
    if (handle != null) {
      // A running transfer is stopped here, its job already gone, so what it reports reaches nothing.
      // A paused one's stop is waited for, so the partial is not deleted under its last write.
      // Either may have landed its last byte first, and that archive goes too.
      if (job.state == DownloadJobState.running) await handle.cancel(deletePartial: true);
      final landed = await handle.done.then<File?>((result) => result.file, onError: (Object _) => null);
      await _deleteFile(landed);
    }
    // A job sent to the end of the line by a stall still has the partial the stall left.
    if (job.state == DownloadJobState.paused || job.resumed || (job.deferred && job.state == DownloadJobState.queued)) {
      await _service.discardPartial(job.request);
    }
    await _deleteFile(job.archive);
    await ArchiveService.deleteExtraction(job.unpacked);
  }

  /// Stops a running background transfer and keeps its partial, freeing its slot for the next queued job.
  ///
  /// Marked first, so the stop that comes back reads as the pause rather than as a cancel. A transfer whose last
  /// byte lands as this is pressed finishes: the archive is on disk, and that wins.
  Future<void> pause(int seq) async {
    final job = _jobOf(seq);
    final handle = _handles[seq];
    if (job == null || !job.pausable || handle == null) return;
    _replace(seq, (j) => j.copyWith(state: DownloadJobState.paused));
    await handle.cancel(deletePartial: false);
  }

  /// Puts a paused job back in line, first of the queued ones. The service resumes from the partial under the
  /// resume policy.
  ///
  /// Pressed before the stop the pause asked for has come back, it waits for that stop: a transfer started now would
  /// write into the same `.part` as the one still stopping.
  void resume(int seq) {
    final job = _jobOf(seq);
    if (job == null || job.state != DownloadJobState.paused) return;
    if (_handles.containsKey(seq)) {
      _resumeAfterStop.add(seq);
      return;
    }
    _replace(seq, (j) => j.copyWith(state: DownloadJobState.queued, resumed: true));
    _pump();
  }

  /// Tries a failed job again, from the beginning of its life.
  ///
  /// Keeps its `seq`, so it holds its place in the panel instead of jumping to
  /// the bottom as a stranger. A partial left on disk is still picked up — that
  /// is the download service's business, not the queue's.
  ///
  /// **Refused while something else is fetching the same file**, on exactly the
  /// rule [enqueue] follows and for exactly the same reason: two transfers of
  /// one file share a `.part` and a resume record in a shared directory, and
  /// append two streams into a corrupt archive that still looks plausible. A
  /// stale failed row beside a fresh job for the same file is not a contrived
  /// case — the failed row stays in the panel by design, and pressing Download
  /// again is what a user does with it.
  ///
  /// An update job goes to the end of the line, held by the run's halt if it is halted,
  /// and is refused while another job of the run holds one of its layers.
  void retry(int seq) {
    final job = _jobOf(seq);
    if (job == null || !job.isTerminal) return;
    if (activeJobForFile(state, job.file.idRow) != null) return;
    if (job.isUpdate && job.update!.mods.any((mod) => layerInRun(state, mod))) return;
    _completions.remove(seq);
    _completerFor(seq);
    final halt = currentHalt(state);
    _replace(seq, (j) => j.isUpdate ? j.restarted(deferred: true, halt: halt) : j.restarted());
    _pump();
  }

  /// Drops a single row. Only a terminal one — removing a running job would
  /// leave a worker nothing can reach.
  void remove(int seq) {
    final job = _jobOf(seq);
    if (job == null || !job.isTerminal) return;
    _drop(seq);
  }

  /// Drops every finished row, leaving whatever is still working.
  void clearFinished() {
    for (final job in state.where((j) => j.isTerminal)) {
      _forget(job.seq);
    }
    state = state.where((j) => !j.isTerminal).toList();
  }

  // ── The host's half ────────────────────────────────────────────────────────

  /// Claims the next job for the install chain ([nextForInstallChain]):
  /// a Browse install, marked [DownloadJobState.installing], or an update run's write, marked [UpdateStep.writing].
  ///
  /// Claim-and-mark in one call, deliberately: as two, a rebuild between them
  /// would let a second pass pick the same job up, and the whole reason installs
  /// are serialised is that two of them cannot safely overlap.
  ///
  /// Nothing is claimed once the app is closing (`WritesInFlight.closing`), read here rather than through a write's zone,
  /// so a claim made from inside a tracked write is held back too.
  DownloadJob? claimNextForHost() {
    final job = nextForInstallChain(state, closing: WritesInFlight.shared.closing);
    if (job == null) return null;
    if (job.isUpdate) {
      _timeStage(job, 'waited_for_install');
      _replace(job.seq, (j) => j.copyWith(updateStep: UpdateStep.writing));
    } else {
      _replace(job.seq, (j) => j.copyWith(state: DownloadJobState.installing, installStage: InstallStage.unpacking));
    }
    return _jobOf(job.seq);
  }

  /// Claims the next landed update job to unpack and preview ([nextUpdateToUnpack]), marking it [UpdateStep.unpacking].
  /// None once the app is closing, since nothing it found could be written.
  DownloadJob? claimNextUpdateUnpack() {
    final job = nextUpdateToUnpack(state, closing: WritesInFlight.shared.closing);
    if (job == null) return null;
    _timeStage(job, 'waited_for_unpack');
    _replace(job.seq, (j) => j.copyWith(state: DownloadJobState.updating, updateStep: UpdateStep.unpacking));
    return _jobOf(job.seq);
  }

  /// Settles an update job's stage, the unpack lane's or the install lane's, from what it came to.
  ///
  /// [UpdateStageReady] waits for the install lane.
  /// [UpdateStageAsks] waits for the user, out of both lanes and still ahead of the install under the lookahead.
  /// The rest end the job, with what came of each of its mods, and a failure every later job would share halts the run ([haltsUpdateRun]).
  /// An ended job's unpacked folders and its archive are deleted, except an archive that could not be unpacked, which is kept as an install keeps one.
  /// Every settle admits what a place freed up.
  ///
  /// A job Cancel all reached while its stage ran ([DownloadJob.stopOnSettle]) does not go on:
  /// a result that would keep it going drops it and deletes what it holds, one that ends it is kept, and its failure halts nothing.
  void settleUpdate(int seq, UpdateStageResult result) {
    final job = _jobOf(seq);
    if (job == null || !job.isUpdate || job.state != DownloadJobState.updating) return;
    final writing = job.updateStep == UpdateStep.writing;
    if (!writing) _timeStage(job, 'unpack_and_preview');
    // Only the unpack makes a job ready and only the write writes one; the other way round would loop the job.
    if ((result is UpdateStageReady && writing) || (result is UpdateStageWritten && !writing)) {
      result = UpdateStageFailed(
        UpdateFailure(UpdateFailureKind.other, cause: StateError('${result.runtimeType} from the wrong lane')),
      );
    }
    if (job.stopOnSettle && (result is UpdateStageReady || result is UpdateStageAsks)) {
      final held = switch (result) {
        UpdateStageReady(:final prepared) || UpdateStageAsks(:final prepared) => _unpackedOf(prepared),
        _ => const <String>[],
      };
      _drop(seq);
      _pump();
      unawaited(_discard(job.copyWith(unpacked: [...job.unpacked, ...held]), null));
      return;
    }

    switch (result) {
      case UpdateStageReady(:final prepared):
        _replace(
          seq,
          (j) => j
              .copyWith(updateStep: UpdateStep.unpacked, prepared: prepared, unpacked: _unpackedOf(prepared))
              .withNoQuestion(),
        );
      case UpdateStageAsks(:final wait, :final prepared):
        _stageSince.remove(seq);
        _replace(
          seq,
          (j) => j
              .copyWith(state: DownloadJobState.waiting, prepared: prepared, unpacked: _unpackedOf(prepared))
              .withUpdateWait(wait),
        );
      case UpdateStageWritten(:final outcome, :final results, :final report):
        final all = _modResults(job, results, (mod, _) => UpdateModResult.written(mod));
        _end(job, keepArchive: false);
        markDone(
          seq,
          outcome: outcome,
          installed: [for (final r in all) if (r.end == UpdateModEnd.written) r.mod.modId],
          filedUnder: job.characterId,
        );
        _replace(seq, (j) => j.copyWith(report: report, modResults: all));
      case UpdateStageSkipped(:final reason, :final results):
        final all = _modResults(
          job,
          results,
          (mod, first) => UpdateModResult.skipped(mod, first ? reason : UpdateSkipReason.sharedFileNotWritten),
        );
        _end(job, keepArchive: false);
        markDone(seq, outcome: JobOutcome.skipped);
        _replace(seq, (j) => j.copyWith(skipReason: reason, modResults: all));
      case UpdateStageFailed(:final failure, :final results, :final report):
        final all = _modResults(job, results, (mod, _) => UpdateModResult(mod, UpdateModEnd.failed, failure: failure));
        _end(job, keepArchive: failure.kind == UpdateFailureKind.unpackFailed);
        markFailed(seq, failure);
        _replace(seq, (j) => j.copyWith(report: report, modResults: all));
        if (failure.haltsRun && !job.stopOnSettle) _haltUpdates(seq, failure);
    }
    _pump();
  }

  /// The end of [job]'s stages: its clock stops, and what it holds on disk goes.
  void _end(DownloadJob job, {required bool keepArchive}) {
    _stageSince.remove(job.seq);
    unawaited(ArchiveService.deleteExtraction(job.unpacked));
    if (!keepArchive) unawaited(_deleteFile(job.archive));
  }

  /// What came of each of [job]'s mods: [given] where the stage said, [otherwise] for the rest, in the job's order.
  static List<UpdateModResult> _modResults(
    DownloadJob job,
    List<UpdateModResult> given,
    UpdateModResult Function(UpdateMod mod, bool first) otherwise,
  ) =>
      [
        for (final (i, mod) in job.update!.mods.indexed)
          given.where((result) => result.mod.sameLayerAs(mod)).firstOrNull ?? otherwise(mod, i == 0),
      ];

  /// The unpacked folders a stage's kept state holds, the one place the queue learns what to delete.
  static List<String> _unpackedOf(Object? prepared) =>
      prepared is HoldsUnpack ? prepared.unpackedFolders : const <String>[];

  /// An update question was answered, as [markAnswered] for an install:
  /// the job goes back in line for the unpack lane with [prepared], what the stage keeps with the answer, ahead of the jobs that have not waited.
  /// [password] is held for the unpack it was given for.
  void answerUpdate(int seq, {Object? prepared, String? password}) {
    if (_jobOf(seq)?.isUpdate != true) return;
    markAnswered(seq, prepared: prepared, password: password);
  }

  /// Skip, at an update question: [decline] for an update job, whose row stays as skipped.
  Future<void> skipUpdate(int seq) async {
    if (_jobOf(seq)?.isUpdate != true) return;
    await decline(seq);
  }

  /// An update job's write was undone. The row stays, as [JobOutcome.undone].
  void markUndone(int seq) {
    final job = _jobOf(seq);
    if (job == null || !job.isUpdate || job.state != DownloadJobState.done) return;
    _replace(seq, (j) => j.copyWith(outcome: JobOutcome.undone));
  }

  /// Continue, on a halted run: every job the halt held back goes on from where it stopped.
  /// No job of the list keeps the halt, ended ones included.
  void continueUpdates() {
    if (!state.any((j) => j.halt != null)) return;
    _log.info('update run continued');
    state = [for (final job in state) job.halt == null ? job : job.withHalt(null)];
    _pump();
  }

  /// Cancel all: every update job that can stop ([DownloadJob.cancellable]) leaves the list in one change,
  /// and what each held is deleted, as [cancel] does to one.
  /// A job unpacking or writing is let finish its stage ([DownloadJob.stopOnSettle]):
  /// an unpack that lands is deleted and not written, and a write ends as it ends.
  /// The halt ends with the run it held.
  Future<void> cancelAllUpdates() async {
    final stopping = [for (final job in state) if (job.isUpdate && job.cancellable) job];
    final finishing = {
      for (final job in state)
        if (job.isUpdate && !job.isTerminal && !job.cancellable) job.seq,
    };
    if (stopping.isEmpty && finishing.isEmpty && !state.any((job) => job.halt != null)) return;
    _log.info('update run cancelled', fields: {'jobs': stopping.length, 'finishing': finishing.length});

    final handles = {for (final job in stopping) job.seq: _handles[job.seq]};
    final gone = {for (final job in stopping) job.seq};
    for (final seq in gone) {
      _completeError(seq, const DownloadCancelledException());
      _forget(seq);
    }
    // No job of the list keeps a halt, ended ones included, so nothing a later Try again or press reads is stale.
    state = [
      for (final job in state)
        if (!gone.contains(job.seq))
          (finishing.contains(job.seq) ? job.copyWith(stopOnSettle: true) : job).withHalt(null),
    ];
    _pump();
    await Future.wait([for (final job in stopping) _discard(job, handles[job.seq])]);
  }

  /// Holds back every update job that has not ended, [bySeq]'s failure being one every later job would share.
  void _haltUpdates(int bySeq, Object cause) {
    final halt = UpdateHalt(cause: cause, bySeq: bySeq);
    _log.warning('update run halted', error: cause, fields: {'job': bySeq});
    state = [
      for (final job in state)
        if (job.isUpdate && !job.isTerminal && job.halt == null) job.withHalt(halt) else job,
    ];
  }

  /// Logs how long [job] spent in the stage it is leaving, and starts the clock on the next.
  ///
  /// The first real runs are the measurement the update limits wait for (`docs/update-runs.md` §4.5),
  /// so each stage's seconds are in the log: the download, the waits for the unpack and the install lanes, and the unpack and preview.
  /// The write stage times the write and its steps itself, since only it knows whether a write started.
  void _timeStage(DownloadJob job, String stage) {
    if (!job.isUpdate) return;
    final now = DateTime.now();
    final since = _stageSince[job.seq];
    _stageSince[job.seq] = now;
    if (since == null) return;
    _log.info('update stage ended', fields: {
      'mod': job.update!.primary.modId,
      'stage': stage,
      'seconds': now.difference(since).inMilliseconds / 1000,
    });
  }

  /// The step an installing job is on, for its panel row.
  void installStage(int seq, InstallStage stage) {
    final job = _jobOf(seq);
    if (job == null || job.state != DownloadJobState.installing) return;
    _replace(seq, (j) => j.copyWith(installStage: stage));
  }

  /// An install stopped at [wait] and frees the install slot. [prepared] is what it kept, [unpacked] the folders it
  /// holds in the temp folder. A password given for this run is dropped, whatever the outcome.
  void markWaiting(
    int seq,
    InstallWait wait, {
    Object? prepared,
    List<String> unpacked = const <String>[],
  }) =>
      _replace(
        seq,
        (j) => j
            .copyWith(state: DownloadJobState.waiting, prepared: prepared, unpacked: unpacked)
            .withWait(wait),
      );

  /// The question was answered and the install goes back in line for the slot, ahead of jobs that have not waited.
  /// [password] is held for the unpack it was given for.
  void markAnswered(int seq, {Object? prepared, String? password}) {
    final job = _jobOf(seq);
    if (job == null || job.state != DownloadJobState.waiting) return;
    _replace(
      seq,
      (j) => j
          .copyWith(state: DownloadJobState.downloaded, prepared: prepared, waited: true)
          .withNoQuestion(password: password),
    );
    _pump();
  }

  /// The unpack a password was given for has run, so the password is dropped, whatever the unpack came to.
  void dropPassword(int seq) {
    final job = _jobOf(seq);
    if (job == null || job.password == null) return;
    _replace(seq, (j) => j.withWait(j.wait));
  }

  /// A dialog was answered in part and the install still waits, now at [wait], keeping the answers in [prepared].
  void keepWaiting(int seq, InstallWait wait, {Object? prepared}) {
    final job = _jobOf(seq);
    if (job == null || job.state != DownloadJobState.waiting) return;
    _replace(seq, (j) => j.copyWith(prepared: prepared).withWait(wait));
  }

  /// Don't install: what the waiting job kept is deleted, its archive or its unpacked folders, and the row leaves
  /// the list. For an update run's job it is Skip, whose row stays.
  Future<void> decline(int seq) async {
    final job = _jobOf(seq);
    if (job == null || job.state != DownloadJobState.waiting) return;
    logConfirmation(job.isUpdate ? 'update.question' : 'install.question',
        accepted: false,
        subject: job.subject,
        fields: {'question': (job.updateWait?.question ?? job.wait?.question)?.name});
    if (job.isUpdate) {
      final all = _modResults(job, const [], (mod, _) => UpdateModResult.skipped(mod, UpdateSkipReason.skippedByUser));
      markDone(seq, outcome: JobOutcome.skipped);
      _replace(
        seq,
        (j) => j.copyWith(skipReason: UpdateSkipReason.skippedByUser, modResults: all).withNoQuestion(),
      );
    } else {
      _completeError(seq, const DownloadCancelledException());
      _drop(seq);
    }
    _pump();
    await _deleteFile(job.archive);
    await ArchiveService.deleteExtraction(job.unpacked);
  }

  /// Finished: [outcome], the mod folders it [installed], where it [filedUnder], and for an install that put nothing
  /// in, the result's [headline].
  void markDone(
    int seq, {
    JobOutcome? outcome,
    List<String> installed = const <String>[],
    String? filedUnder,
    String? headline,
  }) =>
      _replace(
        seq,
        (j) => j
            .copyWith(
              state: DownloadJobState.done,
              outcome: outcome,
              installed: installed,
              filedUnder: filedUnder,
              headline: headline,
              unpacked: const <String>[],
              finishedAt: DateTime.now(),
            )
            .withWait(null)
            .withHalt(null),
      );

  /// The install found nothing to do and nothing to report, so its row leaves the list as a declined one does.
  void markGone(int seq) => _drop(seq);

  /// Failed: [error]. An ended job is held by no halt, so a Try again later takes the run's halt as it is then.
  void markFailed(int seq, Object error) => _replace(
        seq,
        (j) => j
            .copyWith(
              state: DownloadJobState.failed,
              error: error,
              unpacked: const <String>[],
              finishedAt: DateTime.now(),
            )
            .withWait(null)
            .withHalt(null),
      );

  // ── The update flow's half ─────────────────────────────────────────────────

  /// The step an update download is on, while its flow unpacks, asks and writes.
  void updateStep(int seq, UpdateStep step) {
    final job = _jobOf(seq);
    if (job == null || job.state != DownloadJobState.updating) return;
    _replace(seq, (j) => j.copyWith(updateStep: step));
  }

  /// Ends an update download, which the update flow does on every path once its bytes are handed over.
  void endUpdate(int seq, UpdateEnd end) {
    final job = _jobOf(seq);
    if (job == null || job.state != DownloadJobState.updating) return;
    switch (end) {
      case UpdateWritten(:final outcome, :final mods):
        markDone(seq, outcome: outcome, installed: mods, filedUnder: job.characterId);
      case UpdateDeclined():
        _drop(seq);
      case UpdateFailed(:final headline):
        markFailed(seq, InstallFailure(headline));
    }
  }

  // ── Internals ──────────────────────────────────────────────────────────────

  /// Starts whatever the policy admits. Called after **every** state change, so
  /// "a slot freed up" has one implementation rather than one per way a job can
  /// end.
  void _pump() {
    for (final job in admissions(state)) {
      _start(job);
    }
  }

  void _start(DownloadJob job) {
    final seq = job.seq;
    final handle = _service.start(job.request);
    _handles[seq] = handle;
    if (job.isUpdate) _stageSince[seq] = DateTime.now();
    _replace(seq, (j) => j.copyWith(state: DownloadJobState.running, resumed: false));

    // A handle let go of — its job cancelled while paused, or cleared — has nothing left to report to: its job may be
    // gone, or running again on a handle of its own.
    bool current() => identical(_handles[seq], handle);

    _subscriptions[seq] = handle.progress.listen(
      (p) {
        if (current()) _replace(seq, (j) => j.copyWith(progress: p));
      },
      // The failure is reported through `done`; this listener exists only so a
      // stream error is not raised as an unhandled one.
      onError: (Object _) {},
    );

    unawaited(handle.done.then(
      (result) {
        if (current()) _finishedTransfer(seq, result);
      },
      onError: (Object error) {
        if (current()) _failedTransfer(seq, error);
      },
    ));
  }

  void _finishedTransfer(int seq, DownloadResult result) {
    _releaseConnection(seq);
    // The last byte landed as the pause was pressed: the archive is on disk, and that wins over the Resume.
    _resumeAfterStop.remove(seq);
    final job = _jobOf(seq);
    if (job == null) return;
    _timeStage(job, 'download');
    // `callerHandles` is handed to the update flow the moment the bytes land,
    // and stays on the panel until that flow ends it.
    final next = job.intent == DownloadIntent.callerHandles
        ? DownloadJobState.updating
        : DownloadJobState.downloaded;
    _replace(seq, (j) => j.copyWith(state: next, result: result));
    _completeWith(seq, result);
    _pump();
  }

  void _failedTransfer(int seq, Object error) {
    _releaseConnection(seq);
    final job = _jobOf(seq);
    if (error is DownloadCancelledException) {
      if (job?.state == DownloadJobState.paused) {
        // The stop the pause asked for. The partial stays, and so does the row, unless Resume came first.
        if (_resumeAfterStop.remove(seq)) return resume(seq);
        _pump();
        return;
      }
      // **A cancel records no error and leaves the list.** It is not one — the
      // user asked for it — so `error != null` means "something went wrong"
      // everywhere.
      _completeError(seq, error);
      _drop(seq);
    } else if (job != null && job.isUpdate && error is DownloadStalledException && !job.stalled) {
      // A degraded node costs only the job on it: the job goes to the end of the line, its partial kept to resume from.
      // A second stall fails it.
      _log.info('update download stalled, sent to the end of the line', fields: {'mod': job.update!.primary.modId});
      _stageSince.remove(seq);
      _replace(seq, (j) => j.restarted(deferred: true, stalled: true, halt: j.halt));
    } else {
      _stageSince.remove(seq);
      _replace(
        seq,
        (j) => j.copyWith(state: DownloadJobState.failed, error: error, finishedAt: DateTime.now()).withHalt(null),
      );
      _completeError(seq, error);
      if (job != null && job.isUpdate && haltsUpdateRun(error)) _haltUpdates(seq, error);
    }
    _pump();
  }

  void _releaseConnection(int seq) {
    _subscriptions.remove(seq)?.cancel();
    _handles.remove(seq);
  }

  /// Deletes an archive a job's bytes landed as, when there is one. The file, never the shared directory.
  static Future<void> _deleteFile(File? archive) async {
    if (archive == null) return;
    try {
      if (await archive.exists()) await archive.delete();
    } catch (_) {
      // The launch sweep in `DownloadPaths` collects it later.
    }
  }

  Completer<DownloadResult> _completerFor(int seq) =>
      _completions.putIfAbsent(seq, () {
        final completer = Completer<DownloadResult>();
        // Most jobs are never awaited — an install is watched through the panel,
        // not through a future. Marking it handled keeps a failure from being
        // reported as an unhandled async error; a real listener still gets it.
        completer.future.ignore();
        return completer;
      });

  void _completeWith(int seq, DownloadResult result) {
    final completer = _completerFor(seq);
    if (!completer.isCompleted) completer.complete(result);
  }

  void _completeError(int seq, Object error) {
    final completer = _completions[seq];
    if (completer != null && !completer.isCompleted) completer.completeError(error);
  }

  /// Takes a row off the list, whatever its state.
  void _drop(int seq) {
    _forget(seq);
    state = [...state]..removeWhere((j) => j.seq == seq);
  }

  void _forget(int seq) {
    _releaseConnection(seq);
    _completions.remove(seq);
    _resumeAfterStop.remove(seq);
    _stageSince.remove(seq);
  }

  DownloadJob? _jobOf(int seq) {
    for (final job in state) {
      if (job.seq == seq) return job;
    }
    return null;
  }

  void _replace(int seq, DownloadJob Function(DownloadJob) update) {
    state = [
      for (final job in state)
        if (job.seq == seq) update(job) else job,
    ];
  }

  /// Cancels every subscription but **keeps the partials**: the app closing is
  /// exactly the case a resumable partial exists for, and the download service
  /// makes the same choice for the same reason.
  void _shutdown() {
    for (final subscription in _subscriptions.values) {
      subscription.cancel();
    }
    _subscriptions.clear();
    for (final handle in _handles.values) {
      handle.cancel().ignore();
    }
    _handles.clear();
    _completions.clear();
  }
}
