import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/gamebanana/gb_file.dart';
import '../../models/gamebanana/gb_mod.dart';
import '../archive_service.dart';
import '../log/confirmations.dart';
import 'download_exceptions.dart';
import 'download_handle.dart';
import 'download_job.dart';
import 'download_progress.dart';
import 'download_request.dart';
import 'download_service.dart';
import 'queue_policy.dart';

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
    );
    state = [...state, job];
    _completerFor(seq);
    _pump();
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
  /// **An installing or updating job cannot be cancelled**, and the refusal belongs here
  /// rather than only in the button that does not offer it. Between the unpack
  /// and the import there is no safe stopping point, and this method's own
  /// archive delete below would pull the file out from under a running
  /// extraction.
  Future<void> cancel(int seq) async {
    final job = _jobOf(seq);
    if (job == null ||
        job.isTerminal ||
        job.state == DownloadJobState.installing ||
        job.state == DownloadJobState.updating) {
      return;
    }
    if (job.state == DownloadJobState.waiting) return decline(seq);

    final handle = _handles[seq];
    // A paused job can still hold its handle while the stop its pause asked for comes back, and cancelling that
    // handle again does nothing.
    if (handle != null && job.state != DownloadJobState.paused) {
      await handle.cancel(deletePartial: true);
      return;
    }

    // Not started, paused, resumed and back in line, or finished and waiting on the host. No transfer to unwind,
    // so removing it here is the only thing that moves it.
    //
    // A job cancelled *after* the bytes landed still has an archive in `<appData>/downloads`, or the folders an
    // answered question kept, and nothing else will ever come for them — the install that would have consumed them
    // is what is being called off. So they go now, for the same reason a cancelled transfer deletes its partial.
    _resumeAfterStop.remove(seq);
    _completeError(seq, const DownloadCancelledException());
    _drop(seq);
    _pump();
    if (handle != null) {
      // The pause's stop, waited for so the partial is not deleted under its last write. A transfer whose last byte
      // landed instead left an archive, which goes too.
      final landed = await handle.done.then<File?>((result) => result.file, onError: (Object _) => null);
      await _deleteFile(landed);
    }
    if (job.state == DownloadJobState.paused || job.resumed) {
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
  void retry(int seq) {
    final job = _jobOf(seq);
    if (job == null || !job.isTerminal) return;
    if (activeJobForFile(state, job.file.idRow) != null) return;
    _completions.remove(seq);
    _completerFor(seq);
    _replace(seq, (j) => j.restarted());
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

  /// Claims the next job for the host, marking it [DownloadJobState.installing].
  ///
  /// Claim-and-mark in one call, deliberately: as two, a rebuild between them
  /// would let a second pass pick the same job up, and the whole reason installs
  /// are serialised is that two of them cannot safely overlap.
  DownloadJob? claimNextForHost() {
    final job = nextAwaitingHost(state);
    if (job == null) return null;
    _replace(job.seq, (j) => j.copyWith(state: DownloadJobState.installing, installStage: InstallStage.unpacking));
    return _jobOf(job.seq);
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
      (j) => j.copyWith(state: DownloadJobState.downloaded, prepared: prepared).withWait(null, password: password),
    );
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
  /// the list.
  Future<void> decline(int seq) async {
    final job = _jobOf(seq);
    if (job == null || job.state != DownloadJobState.waiting) return;
    logConfirmation('install.question',
        accepted: false, subject: job.subject, fields: {'question': job.wait?.question.name});
    _completeError(seq, const DownloadCancelledException());
    _drop(seq);
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
            .withWait(null),
      );

  /// The install found nothing to do and nothing to report, so its row leaves the list as a declined one does.
  void markGone(int seq) => _drop(seq);

  void markFailed(int seq, Object error) => _replace(
        seq,
        (j) => j
            .copyWith(
              state: DownloadJobState.failed,
              error: error,
              unpacked: const <String>[],
              finishedAt: DateTime.now(),
            )
            .withWait(null),
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
    } else {
      _replace(
        seq,
        (j) => j.copyWith(state: DownloadJobState.failed, error: error, finishedAt: DateTime.now()),
      );
      _completeError(seq, error);
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
