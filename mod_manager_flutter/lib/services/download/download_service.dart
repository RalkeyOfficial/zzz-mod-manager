import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as path;

import '../../utils/path_helper.dart';
import '../archive_hash.dart';
import 'download_exceptions.dart';
import 'download_handle.dart';
import 'download_paths.dart';
import 'download_progress.dart';
import 'download_request.dart';
import 'download_transport.dart';
import 'io_download_transport.dart';
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
/// Everything is injectable — transport, directory, clock, sink opener — so the
/// whole class is testable with no network and no real waiting.
class DownloadService {
  DownloadService({
    DownloadTransport? transport,
    Directory? directory,
    DateTime Function()? now,
    IOSink Function(File file, FileMode mode)? openSink,
    this.stallTimeout = const Duration(seconds: 60),
    this.progressInterval = const Duration(milliseconds: 500),
    ResumePolicy policy = const ResumePolicy(),
  })  : _transport = transport ?? IoDownloadTransport(),
        _paths = DownloadPaths(
          directory ?? Directory(PathHelper.getDownloadsPath()),
        ),
        _now = now ?? DateTime.now,
        _openSink = openSink ?? _defaultOpenSink,
        _policy = policy;

  final DownloadTransport _transport;
  final DownloadPaths _paths;
  final DateTime Function() _now;
  final IOSink Function(File file, FileMode mode) _openSink;
  final ResumePolicy _policy;

  /// Abort only after this long with **zero** bytes received.
  ///
  /// Never a total-duration limit: a legitimate transfer can take far longer
  /// than any ceiling worth setting, and cancelling those is worse than waiting.
  final Duration stallTimeout;

  final Duration progressInterval;

  bool _swept = false;

  static IOSink _defaultOpenSink(File file, FileMode mode) =>
      file.openWrite(mode: mode);

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

  void close() => _transport.close();
}

/// One download attempt. Holds the mutable state that would otherwise clutter
/// the service, and guarantees every exit path closes the sink and releases the
/// connection.
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

  StreamSubscription<List<int>>? _sub;
  IOSink? _sink;
  Timer? _stallTimer;
  Timer? _progressTimer;
  Md5Accumulator? _digest;

  /// Completes when the body stream ends, errors, stalls, or is cancelled.
  /// Held on the run so [cancel] can unblock a transfer in flight — without
  /// this, cancelling the subscription would leave the run awaiting a future
  /// nothing ever completes.
  Completer<void>? _finished;

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
      _stallTimer?.cancel();
      _progressTimer?.cancel();
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

    final response = await _open(onDisk, record?.etag);
    final decision = service._policy.decide(
      statusCode: response.statusCode,
      bytesOnDisk: onDisk,
      contentLength: response.contentLength,
      contentRange: response.contentRange,
      etag: response.etag,
    );

    if (decision.action == ResumeAction.fail) {
      await response.discard();
      throw DownloadHttpException(
        decision.reason,
        statusCode: response.statusCode,
        retryable: decision.retryable,
      );
    }

    if (decision.action == ResumeAction.complete) {
      // The server says we already hold every byte. Nothing to transfer.
      await response.discard();
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
    if (response.statusCode == 416 && decision.action == ResumeAction.restart) {
      await response.discard();
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
    _resumedFrom = appending ? onDisk : 0;
    _received = _resumedFrom;
    _total = decision.totalSize ?? request.expectedSize;

    // Only meaningful when this attempt writes every byte. On a resume the
    // earlier bytes never passed through this process, so there is nothing
    // honest to accumulate and the hash is left to the extraction step.
    _digest = appending ? null : Md5Accumulator();

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

    await _streamToDisk(response, partFile, appending: appending);

    final promoted = await _promote(partFile, filename);
    await PartialDownload.delete(recordFile);

    return DownloadResult(
      file: promoted,
      totalBytes: _received,
      etag: decision.etag,
      md5: _digest?.close(),
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

  Future<DownloadResponse> _open(int onDisk, String? etag) async {
    final headers = <String, String>{};
    if (onDisk > 0) {
      headers['range'] = 'bytes=$onDisk-';
      // Ask the server to honour the range only if the file hasn't changed.
      // The ETag is stable across CDN nodes, so landing on a different one
      // won't spuriously restart the transfer.
      if (etag != null) headers['if-range'] = etag;
    }
    try {
      return await service._transport.open(request.url, headers: headers);
    } on DownloadException {
      rethrow;
    } catch (error) {
      throw DownloadNetworkException(
        'Could not reach ${request.url}',
        cause: error,
      );
    }
  }

  Future<void> _streamToDisk(
    DownloadResponse response,
    File partFile, {
    required bool appending,
  }) async {
    final finished = Completer<void>();
    _finished = finished;
    _sink = service._openSink(
      partFile,
      appending ? FileMode.append : FileMode.write,
    );

    _emit(DownloadState.downloading);
    _rate.add(_received);
    _startStallTimer(finished);
    _progressTimer = Timer.periodic(
      service.progressInterval,
      (_) => _emit(DownloadState.downloading),
    );

    late final StreamSubscription<List<int>> sub;
    sub = response.body.listen(
      (chunk) {
        if (_cancelled) return;
        try {
          _sink!.add(chunk);
        } catch (error) {
          _fail(finished, DownloadWriteException('Write failed', cause: error));
          return;
        }
        _digest?.add(chunk);
        _received += chunk.length;
        _rate.add(_received);
        _restartStallTimer(finished);
        // Backpressure. Without this the socket keeps delivering while the disk
        // falls behind and the difference buffers in memory. `sink.add` is not
        // awaitable, so pausing on the flush is what applies the brake.
        sub.pause(_sink!.flush());
      },
      onError: (Object error, StackTrace stack) {
        _fail(finished, error);
      },
      onDone: () {
        if (!finished.isCompleted) finished.complete();
      },
      cancelOnError: true,
    );
    _sub = sub;

    try {
      await finished.future;
    } finally {
      _finished = null;
      _stallTimer?.cancel();
      _progressTimer?.cancel();
      await _sub?.cancel();
      _sub = null;
      // Always close the sink, on every path. The old inline downloader leaked
      // it on every error, which is how partial writes stayed unflushed.
      await _closeSink();
    }
  }

  void _startStallTimer(Completer<void> finished) {
    _stallTimer = Timer(service.stallTimeout, () {
      _fail(
        finished,
        DownloadStalledException(
          'No data for ${service.stallTimeout.inSeconds}s',
          stallTimeout: service.stallTimeout,
        ),
      );
    });
  }

  void _restartStallTimer(Completer<void> finished) {
    _stallTimer?.cancel();
    _startStallTimer(finished);
  }

  void _fail(Completer<void> finished, Object error) {
    if (finished.isCompleted) return;
    finished.completeError(error);
  }

  Future<void> _closeSink() async {
    final sink = _sink;
    _sink = null;
    if (sink == null) return;
    try {
      await sink.flush();
      await sink.close();
    } catch (_) {
      // Already broken; the error that got us here is the one worth reporting.
    }
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
  /// lets [execute]'s normal error path close the sink, release the connection
  /// and — when asked — delete the partial. One teardown path is far easier to
  /// keep correct than two racing ones.
  Future<void> cancel({bool deletePartial = false}) async {
    if (!_cancelled) {
      _cancelled = true;
      _deletePartialOnCancel = deletePartial;
      _stallTimer?.cancel();

      final finished = _finished;
      if (finished != null && !finished.isCompleted) {
        // Unblocks the transfer; without this the run would await a future that
        // nothing ever completes and hang for the life of the app.
        finished.completeError(const DownloadCancelledException());
      } else if (!completer.isCompleted) {
        // Cancelled before the body started; nothing is streaming to interrupt.
        _emit(DownloadState.cancelled);
        completer.completeError(const DownloadCancelledException());
        if (_deletePartialOnCancel) {
          await _discardPartial(
            _paths.partFile(_filename),
            _paths.recordFile(_filename),
          );
        }
      }
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
