import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/gamebanana/gb_file.dart';
import '../../models/gamebanana/gb_mod.dart';
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
  /// failure is a request to retry, not a duplicate.
  DownloadJob enqueue({
    required GbFile file,
    required String subject,
    required DownloadIntent intent,
    GbMod? mod,
    String? characterId,
  }) {
    final existing = activeJobForFile(state, file.idRow);
    if (existing != null) return existing;

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
        state: DownloadJobState.failed,
        error: DownloadNetworkException('Unusable download url: $raw'),
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

  /// Stops a job, whether it has started or not.
  ///
  /// The partial is deleted: this is an explicit user cancel, and leaving
  /// several hundred megabytes in a folder they do not manage is the surprising
  /// half of "stop".
  ///
  /// **An installing job cannot be cancelled**, and the refusal belongs here
  /// rather than only in the button that does not offer it. Between the unpack
  /// and the import there is no safe stopping point, and this method's own
  /// archive delete below would pull the file out from under a running
  /// extraction.
  Future<void> cancel(int seq) async {
    final job = _jobOf(seq);
    if (job == null ||
        job.isTerminal ||
        job.state == DownloadJobState.installing) {
      return;
    }

    final handle = _handles[seq];
    if (handle == null) {
      // Either never started, or finished and waiting on the host. No transfer
      // to unwind and no completer callback to wait for, so marking it here is
      // the only thing that moves it.
      //
      // A job cancelled *after* the bytes landed still has an archive in
      // `<appData>/downloads`, and nothing else will ever come for it — the
      // install that would have consumed it is what is being called off. So it
      // goes now, for the same reason a cancelled transfer deletes its partial.
      final archive = job.archive;
      if (archive != null) {
        try {
          if (await archive.exists()) await archive.delete();
        } catch (_) {
          // The sweep in `DownloadPaths` collects it later.
        }
      }
      _replace(seq, (j) => j.copyWith(state: DownloadJobState.cancelled));
      _completeError(seq, const DownloadCancelledException());
      _pump();
      return;
    }
    await handle.cancel(deletePartial: true);
  }

  /// Tries a failed or cancelled job again, from the beginning of its life.
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
    _forget(seq);
    state = [...state]..removeWhere((j) => j.seq == seq);
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
    _replace(job.seq, (j) => j.copyWith(state: DownloadJobState.installing));
    return _jobOf(job.seq);
  }

  void markDone(int seq) =>
      _replace(seq, (j) => j.copyWith(state: DownloadJobState.done));

  /// The user backed out of the install (the duplicate-archive question, the
  /// folder picker). Not a failure — nothing went wrong and there is nothing to
  /// retry from, since the archive is gone with it.
  void markCancelled(int seq) =>
      _replace(seq, (j) => j.copyWith(state: DownloadJobState.cancelled));

  void markFailed(int seq, Object error) => _replace(
        seq,
        (j) => j.copyWith(state: DownloadJobState.failed, error: error),
      );

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
    _replace(seq, (j) => j.copyWith(state: DownloadJobState.running));

    _subscriptions[seq] = handle.progress.listen(
      (p) => _replace(seq, (j) => j.copyWith(progress: p)),
      // The failure is reported through `done`; this listener exists only so a
      // stream error is not raised as an unhandled one.
      onError: (Object _) {},
    );

    unawaited(handle.done.then(
      (result) => _finishedTransfer(seq, result),
      onError: (Object error) => _failedTransfer(seq, error),
    ));
  }

  void _finishedTransfer(int seq, DownloadResult result) {
    _releaseConnection(seq);
    final job = _jobOf(seq);
    if (job == null) return;
    // `callerHandles` is done the moment the bytes land — the update flow owns
    // everything after, and parking it in `downloaded` would leave a row the
    // host is deliberately told to ignore sitting there forever.
    final next = job.intent == DownloadIntent.callerHandles
        ? DownloadJobState.done
        : DownloadJobState.downloaded;
    _replace(seq, (j) => j.copyWith(state: next, result: result));
    _completeWith(seq, result);
    _pump();
  }

  void _failedTransfer(int seq, Object error) {
    _releaseConnection(seq);
    if (error is DownloadCancelledException) {
      // **A cancel records no error.** It is not one — the user asked for it —
      // so `error != null` means "something went wrong" everywhere, and the
      // other cancel path (no handle, below) agrees. `state` is the thing to
      // ask about; [DownloadJob.error] is a detail of a failure.
      _replace(seq, (j) => j.copyWith(state: DownloadJobState.cancelled));
    } else {
      _replace(
        seq,
        (j) => j.copyWith(state: DownloadJobState.failed, error: error),
      );
    }
    _completeError(seq, error);
    _pump();
  }

  void _releaseConnection(int seq) {
    _subscriptions.remove(seq)?.cancel();
    _handles.remove(seq);
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
    final completer = _completerFor(seq);
    if (!completer.isCompleted) completer.completeError(error);
  }

  void _forget(int seq) {
    _releaseConnection(seq);
    _completions.remove(seq);
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
