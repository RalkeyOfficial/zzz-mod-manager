import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as path;

import '../../utils/path_helper.dart';
import 'download_exceptions.dart';
import 'download_handle.dart';
import 'download_paths.dart';
import 'download_progress.dart';
import 'download_pump.dart';
import 'download_request.dart';
import 'download_transport.dart';
import 'inline_download_pump.dart';
import 'isolate_download_pump.dart';
import 'partial_download.dart';
import 'rate_estimator.dart';
import 'resume_policy.dart';

/// Downloads mod archives into `<appData>/downloads`, resumably.
///
/// The shape of this is dictated by measurements against the real CDN: files
/// reach 1.24 GB, a degraded node serves at 0.08 MB/s for ~25 minutes, and node
/// assignment is deterministic per file so retrying cannot route around it. The
/// consequences run through everything below — resume is a first-class path
/// rather than polish, the timeout is a **stall** timeout rather than a total
/// duration, and progress reports a rate so the user can tell a slow download
/// from a dead one.
///
/// **Every decision lives here; only the socket→disk pump does not.** Reading
/// the socket on the root isolate costs ~2.3 ms per event, which caps a download
/// at ~3 MB/s regardless of the network — so that part, and only that part, is
/// behind the [DownloadPump] seam and normally runs on a spawned isolate. See
/// [DownloadPump] for the measurements. Resume, promotion, the stall timer and
/// the rate estimate all stay on this isolate, because they are judgements and
/// judgements are where the subtle bugs are.
///
/// Everything is injectable — pump, transport, directory, clock, sink opener —
/// so the whole class is testable with no network and no real waiting.
class DownloadService {
  DownloadService({
    DownloadPump? pump,
    DownloadTransport? transport,
    Directory? directory,
    DateTime Function()? now,
    IOSink Function(File file, FileMode mode)? openSink,
    this.stallTimeout = const Duration(seconds: 60),
    this.progressInterval = const Duration(milliseconds: 500),
    ResumePolicy policy = const ResumePolicy(),
  })  : assert(
          pump == null || transport == null,
          'Pass a pump or a transport, not both — they name the same layer.',
        ),
        assert(
          openSink == null || transport != null,
          'openSink only reaches the inline pump; a worker cannot receive a '
          'closure. Pass a transport alongside it.',
        ),
        _pump = pump ??
            (transport != null
                ? InlineDownloadPump(transport, openSink: openSink)
                : IsolateDownloadPump()),
        _paths = DownloadPaths(
          directory ?? Directory(PathHelper.getDownloadsPath()),
        ),
        _now = now ?? DateTime.now,
        _policy = policy;

  final DownloadPump _pump;
  final DownloadPaths _paths;
  final DateTime Function() _now;
  final ResumePolicy _policy;

  /// Abort only after this long with **zero** bytes received.
  ///
  /// Never a total-duration limit: a legitimate transfer can take far longer
  /// than any ceiling worth setting, and cancelling those is worse than waiting.
  final Duration stallTimeout;

  final Duration progressInterval;

  /// Runs that have not finished yet, so [close] can reach their workers.
  ///
  /// Without this the isolate pump would outlive its owner: there is no client
  /// on this isolate to close, so a `close()` that only spoke to the pump would
  /// be a silent no-op while every in-flight worker kept its socket.
  final Set<_Run> _runs = <_Run>{};

  bool _swept = false;

  /// Clears junk left by crashes and abandoned downloads. Runs once, lazily.
  Future<void> _sweepOnce() async {
    if (_swept) return;
    _swept = true;
    try {
      await _paths.sweep(now: _now());
    } catch (_) {
      // Housekeeping must never block a download.
    }
  }

  /// Starts (or resumes) a download and returns a handle to watch and cancel it.
  DownloadHandle start(DownloadRequest request) {
    final progress = StreamController<DownloadProgress>.broadcast();
    final completer = Completer<DownloadResult>();
    final run = _Run(
      service: this,
      request: request,
      progress: progress,
      completer: completer,
    );
    _runs.add(run);

    unawaited(run.execute());

    // A caller may cancel without ever awaiting `done`, which is legitimate.
    // Marking the future handled keeps that from being reported as an unhandled
    // async error; real listeners still receive the error normally.
    completer.future.ignore();

    return DownloadHandle(
      progress: progress.stream,
      done: completer.future,
      onCancel: run.cancel,
    );
  }

  /// Stops everything this service owns.
  ///
  /// Fire-and-forget by necessity — `ref.onDispose` takes a `void Function()`,
  /// so there is nowhere to await. That is acceptable rather than merely
  /// tolerated: a partial left by an interrupted write is a valid prefix, which
  /// is exactly what the next resume needs. Partials are kept, not deleted; the
  /// app closing is the case `DownloadHandle.cancel` keeps them for.
  void close() {
    _pump.close().ignore();
    for (final run in List<_Run>.of(_runs)) {
      run.cancel().ignore();
    }
  }
}

/// One download attempt. Holds the mutable state that would otherwise clutter
/// the service, and guarantees every exit path releases the pump session.
class _Run {
  _Run({
    required this.service,
    required this.request,
    required this.progress,
    required this.completer,
  });

  final DownloadService service;
  final DownloadRequest request;
  final StreamController<DownloadProgress> progress;
  final Completer<DownloadResult> completer;

  late final DownloadPaths _paths = service._paths;
  final RateEstimator _rate = RateEstimator();

  /// The connection currently open, if any. Assigned the instant it exists —
  /// including when a cancel has already given up waiting for it — because an
  /// unreferenced session is a worker nothing can ever shut down.
  PumpSession? _session;

  Timer? _stallTimer;
  Timer? _progressTimer;
  bool _stallActive = false;

  /// Completes when [cancel] is called, so a connect in flight can be abandoned
  /// without waiting out the connect timeout.
  final Completer<void> _cancelSignal = Completer<void>();

  /// Why the drain was stopped early, when it was.
  ///
  /// A stall interrupts the pump *gracefully* — the partial has to survive, or
  /// every stall would cost the user a restart — so the drain comes back looking
  /// like a short but successful transfer. The reason is recorded here and
  /// raised afterwards rather than thrown from inside the pump, which is what
  /// keeps teardown to a single path.
  DownloadStalledException? _stallError;

  bool _cancelled = false;
  bool _deletePartialOnCancel = false;
  int _received = 0;
  int _resumedFrom = 0;
  int? _total;

  late final String _filename = DownloadPaths.sanitizeFilename(
    request.suggestedFilename ?? path.basename(request.url.path),
    fallback:
        'mod_${request.fileId ?? 'download'}${path.extension(request.url.path)}',
  );

  Future<void> execute() async {
    try {
      await service._sweepOnce();
      final result = await _download();
      _emit(DownloadState.completed);
      if (!completer.isCompleted) completer.complete(result);
    } catch (error) {
      final state = error is DownloadCancelledException
          ? DownloadState.cancelled
          : DownloadState.failed;
      if (_cancelled && _deletePartialOnCancel) {
        await _discardPartial(
          _paths.partFile(_filename),
          _paths.recordFile(_filename),
        );
      }
      _emit(state, error: error);
      if (!completer.isCompleted) completer.completeError(error);
    } finally {
      _stopStallTimer();
      _progressTimer?.cancel();
      await _session?.shutdown();
      service._runs.remove(this);
      if (!progress.isClosed) await progress.close();
    }
  }

  /// [attempt] guards the single internal retry described below.
  Future<DownloadResult> _download({int attempt = 1}) async {
    await _paths.directory.create(recursive: true);

    final filename = _filename;
    final partFile = _paths.partFile(filename);
    final recordFile = _paths.recordFile(filename);

    var record = await _resumableRecord(recordFile, partFile, filename);
    final onDisk = record == null ? 0 : await _sizeOf(partFile);

    _emit(DownloadState.connecting);
    if (_cancelled) throw const DownloadCancelledException();

    final session = await _open(onDisk, record?.etag);

    // Cancel can land *during* the connect, which is exactly when the user is
    // looking at "connecting" and pressing the button. Without this check the
    // run carried on: it opened the sink, dropped every chunk, and promoted an
    // empty file under the archive's final name.
    if (_cancelled) {
      await session.shutdown();
      throw const DownloadCancelledException();
    }

    final decision = service._policy.decide(
      statusCode: session.statusCode,
      bytesOnDisk: onDisk,
      contentLength: session.contentLength,
      contentRange: session.contentRange,
      etag: session.etag,
    );

    if (decision.action == ResumeAction.fail) {
      await session.shutdown();
      throw DownloadHttpException(
        decision.reason,
        statusCode: session.statusCode,
        retryable: decision.retryable,
      );
    }

    if (decision.action == ResumeAction.complete) {
      // The server says we already hold every byte. Nothing to transfer.
      await session.shutdown();
      _received = onDisk;
      _total = decision.totalSize ?? onDisk;
      final promoted = await _promote(partFile, filename);
      await PartialDownload.delete(recordFile);
      return DownloadResult(
        file: promoted,
        totalBytes: _received,
        etag: decision.etag ?? record?.etag,
        resumed: true,
      );
    }

    // A 416 that doesn't mean "already complete" means the partial we hold is
    // unusable — but this response carries no body to write, so simply
    // "restarting" here would promote a zero-byte file. Clear the partial and
    // make one fresh request with no range. Bounded to a single retry so a
    // server answering 416 unconditionally can't loop.
    if (session.statusCode == 416 && decision.action == ResumeAction.restart) {
      await session.shutdown();
      await _discardPartial(partFile, recordFile);
      if (attempt >= 2) {
        throw const DownloadHttpException(
          'Server rejected the byte range twice',
          statusCode: 416,
        );
      }
      return _download(attempt: attempt + 1);
    }

    final appending = decision.action == ResumeAction.append;
    if (!appending) {
      // Clear the partial **before** the record is written, not by truncating
      // as the body starts. A crash between the two would otherwise leave a
      // record advertising the new download's size and validator beside the old
      // download's bytes — and the next run would resume from there, appending
      // the new file's tail onto the old file's head. That is precisely the
      // plausible-looking, silently broken archive `resume_policy.dart` exists
      // to prevent, reached around the back.
      await _discardPartial(partFile, recordFile);
      record = null;
    }

    _resumedFrom = appending ? onDisk : 0;
    _received = _resumedFrom;
    _total = decision.totalSize ?? request.expectedSize;

    record = (record ?? PartialDownload(
      url: request.url.toString(),
      filename: filename,
      fileId: request.fileId,
      startedAt: service._now(),
    ))
        .copyWith(
      expectedSize: _total,
      etag: decision.etag,
      updatedAt: service._now(),
    );
    await record.write(recordFile);

    // Only hashed when this attempt writes every byte. On a resume the earlier
    // bytes never passed through this process, so there is nothing honest to
    // accumulate and the hash is left to the extraction step.
    final md5 = await _streamToDisk(session, partFile, hashMd5: !appending);

    final promoted = await _promote(partFile, filename);
    await PartialDownload.delete(recordFile);

    return DownloadResult(
      file: promoted,
      // From the file rather than the counter. They agree on every ordinary
      // path, and where they can't the file is the one telling the truth.
      totalBytes: await _sizeOf(promoted),
      etag: decision.etag,
      md5: md5,
      resumed: _resumedFrom > 0,
    );
  }

  /// Returns the stored record only when it genuinely describes the partial we
  /// have. Anything inconsistent is cleared, because starting over is always
  /// correct while resuming onto mismatched bytes is not.
  Future<PartialDownload?> _resumableRecord(
    File recordFile,
    File partFile,
    String filename,
  ) async {
    final record = await PartialDownload.read(recordFile);
    if (record == null) {
      await _discardPartial(partFile, recordFile);
      return null;
    }
    if (record.url != request.url.toString()) {
      await _discardPartial(partFile, recordFile);
      return null;
    }
    final size = await _sizeOf(partFile);
    if (size <= 0) {
      await _discardPartial(partFile, recordFile);
      return null;
    }
    final expected = record.expectedSize;
    if (expected != null && size > expected) {
      // More bytes than the file has: corrupt. Never try to resume from here.
      await _discardPartial(partFile, recordFile);
      return null;
    }
    return record;
  }

  Future<PumpSession> _open(int onDisk, String? etag) async {
    final headers = <String, String>{};
    if (onDisk > 0) {
      headers['range'] = 'bytes=$onDisk-';
      // Ask the server to honour the range only if the file hasn't changed.
      // The ETag is stable across CDN nodes, so landing on a different one
      // won't spuriously restart the transfer.
      if (etag != null) headers['if-range'] = etag;
    }

    final Future<PumpSession> pending;
    try {
      pending = service._pump.open(request.url, headers: headers);
    } catch (error) {
      throw DownloadNetworkException(
        'Could not reach ${request.url}',
        cause: error,
      );
    }

    // Take ownership of the session the moment it exists, even if the race
    // below has already given up on it. A cancel during connect would otherwise
    // leave a worker nothing holds a reference to, still opening the socket.
    unawaited(pending.then(
      (session) {
        _session = session;
        if (_cancelled) unawaited(session.shutdown());
      },
      onError: (Object _) {
        // Reported by the race below; handled here only so the second listener
        // doesn't turn it into an unhandled async error.
      },
    ));

    try {
      // Racing the cancel matters: a connect can take the full 20 s timeout,
      // and making the user watch that out after pressing Cancel is the sort of
      // unresponsiveness they read as a hang.
      return await Future.any<PumpSession>([
        pending,
        _cancelSignal.future
            .then<PumpSession>((_) => throw const DownloadCancelledException()),
      ]);
    } on DownloadException {
      rethrow;
    } catch (error) {
      throw DownloadNetworkException(
        'Could not reach ${request.url}',
        cause: error,
      );
    }
  }

  /// Runs the transfer and returns the in-stream md5, when one was asked for.
  Future<String?> _streamToDisk(
    PumpSession session,
    File partFile, {
    required bool hashMd5,
  }) async {
    _emit(DownloadState.downloading);
    _rate.add(_received);
    _startStallTimer();
    _progressTimer = Timer.periodic(
      service.progressInterval,
      (_) => _emit(DownloadState.downloading),
    );

    try {
      final outcome = await session.drainTo(
        partFile.path,
        hashMd5: hashMd5,
        onBytes: _onBytes,
        // The socket is done, the sink is not yet flushed. Flushing a gigabyte
        // onto contended storage takes real time, and the stall timer must not
        // be running through it — a download that already finished must not be
        // able to time out.
        onBodyEnded: _stopStallTimer,
      );
      _received = _resumedFrom + outcome.bytesWritten;
      _rate.add(_received);

      final stalled = _stallError;
      if (stalled != null) throw stalled;
      if (_cancelled) throw const DownloadCancelledException();
      return outcome.md5;
    } finally {
      _stopStallTimer();
      _progressTimer?.cancel();
      _progressTimer = null;
      // Before the caller renames or deletes the partial. Windows refuses both
      // on a file something still holds open, and Linux hides the same mistake
      // by unlinking an inode that is still being written.
      await session.shutdown();
      _session = null;
    }
  }

  /// The pump reports a counter, not chunks. Only an **increase** counts as
  /// progress: the isolate pump posts on a fixed timer whether anything moved
  /// or not, and a tick that says the same number as last time is precisely
  /// what a stalled transfer looks like.
  void _onBytes(int bytesWritten) {
    final received = _resumedFrom + bytesWritten;
    if (received <= _received) return;
    _received = received;
    _rate.add(_received);
    _restartStallTimer();
  }

  void _startStallTimer() {
    _stallActive = true;
    _stallTimer = Timer(service.stallTimeout, () {
      _stallError = DownloadStalledException(
        'No data for ${service.stallTimeout.inSeconds}s',
        stallTimeout: service.stallTimeout,
      );
      // The one interrupt mechanism, shared with cancel. The drain stops
      // gracefully and flushes what it has, so the partial can still be
      // resumed; `_streamToDisk` raises the recorded reason afterwards.
      final session = _session;
      if (session != null) unawaited(session.shutdown());
    });
  }

  void _restartStallTimer() {
    if (!_stallActive) return;
    _stallTimer?.cancel();
    _startStallTimer();
  }

  void _stopStallTimer() {
    _stallActive = false;
    _stallTimer?.cancel();
    _stallTimer = null;
  }

  /// Moves the finished `.part` to its final name. A rename within the same
  /// directory, so no bytes are copied and the final name only ever appears
  /// once the file is whole.
  Future<File> _promote(File partFile, String filename) async {
    if (!await partFile.exists()) {
      throw DownloadWriteException('Downloaded file vanished: ${partFile.path}');
    }
    final target = await _paths.resolveCollision(filename);
    return partFile.rename(target.path);
  }

  Future<void> _discardPartial(File partFile, File recordFile) async {
    try {
      if (await partFile.exists()) await partFile.delete();
    } catch (_) {
      // Sweep will retry later.
    }
    await PartialDownload.delete(recordFile);
  }

  static Future<int> _sizeOf(File file) async {
    try {
      return await file.exists() ? await file.length() : 0;
    } catch (_) {
      return 0;
    }
  }

  /// Stops the download and waits for it to unwind.
  ///
  /// Deliberately does **not** tear things down itself: it signals the run and
  /// lets [execute]'s normal error path release the session and — when asked —
  /// delete the partial. One teardown path is far easier to keep correct than
  /// two racing ones.
  ///
  /// Shutting the session down is a signal too, not a teardown: the pump stops
  /// the drain *gracefully*, flushing and closing what it has written, because
  /// those bytes are what a later resume picks up from.
  Future<void> cancel({bool deletePartial = false}) async {
    if (!_cancelled) {
      _cancelled = true;
      _deletePartialOnCancel = deletePartial;
      _stopStallTimer();
      if (!_cancelSignal.isCompleted) _cancelSignal.complete();
      await _session?.shutdown();
    }
    // Let callers await cancel() and know the file system has settled.
    await completer.future.then<void>((_) {}, onError: (_) {});
  }

  void _emit(DownloadState state, {Object? error}) {
    if (progress.isClosed) return;
    progress.add(
      DownloadProgress(
        state: state,
        received: _received,
        total: _total,
        bytesPerSecond: _rate.bytesPerSecond,
        eta: _rate.etaFor(received: _received, total: _total),
        resumedFrom: _resumedFrom,
        error: error,
      ),
    );
  }
}
