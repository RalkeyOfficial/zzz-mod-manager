import 'dart:io';

import 'download_pump.dart';
import 'download_transport.dart';
import 'pump_body.dart';

/// A [DownloadPump] that reads the socket on the **calling** isolate.
///
/// Two jobs, and they are not the same job:
///
/// - It is the **test** pump. Every download test injects a
///   [DownloadTransport] and runs with no network at all; a fake transport
///   cannot cross an isolate boundary, so this is the only implementation those
///   tests can use. `openSink` lives here for the same reason.
/// - It is the **fallback** pump. If `Isolate.spawn` fails, a 3 MB/s download is
///   the status quo and strictly better than a failed one.
///
/// It is *not* what production normally uses: on the root isolate this is the
/// ~3 MB/s path the whole seam exists to get off. See [DownloadPump].
class InlineDownloadPump implements DownloadPump {
  InlineDownloadPump(
    this._transport, {
    IOSink Function(File file, FileMode mode)? openSink,
  }) : _openSink = openSink;

  final DownloadTransport _transport;
  final IOSink Function(File file, FileMode mode)? _openSink;

  @override
  Future<PumpSession> open(
    Uri url, {
    Map<String, String> headers = const {},
    Duration connectTimeout = const Duration(seconds: 20),
  }) async {
    final response = await _transport.open(
      url,
      headers: headers,
      connectTimeout: connectTimeout,
    );
    return _InlineSession(response, _openSink);
  }

  @override
  Future<void> close() async => _transport.close();
}

class _InlineSession implements PumpSession {
  _InlineSession(this._response, this._openSink);

  final DownloadResponse _response;
  final IOSink Function(File file, FileMode mode)? _openSink;

  final PumpInterrupt _interrupt = PumpInterrupt();

  /// The in-flight drain, so [shutdown] can wait for the sink to be flushed and
  /// closed rather than merely asking it to stop.
  Future<void>? _draining;

  bool _drained = false;
  Future<void>? _shutdown;

  @override
  int get statusCode => _response.statusCode;

  @override
  int get contentLength => _response.contentLength;

  @override
  Map<String, String> get headers => _response.headers;

  @override
  String? get etag => _response.etag;

  @override
  ContentRange? get contentRange => _response.contentRange;

  @override
  Future<PumpOutcome> drainTo(
    String partPath, {
    required bool hashMd5,
    required void Function(int bytesWritten) onBytes,
    required void Function() onBodyEnded,
  }) {
    _drained = true;
    final work = pumpResponseToFile(
      _response,
      partPath,
      hashMd5: hashMd5,
      onBytes: onBytes,
      onBodyEnded: onBodyEnded,
      interrupt: _interrupt,
      openSink: _openSink,
    );
    // Tracked, not awaited: `shutdown` needs to know when the sink has actually
    // let go of the file, and it must not care whether the drain succeeded.
    _draining = work.then<void>((_) {}, onError: (Object _) {});
    return work;
  }

  /// Memoised, so the several call sites that all reach for it — cancel, a
  /// stall, the 416 retry, the success path's `finally` — cannot race each
  /// other into two half-teardowns.
  @override
  Future<void> shutdown() => _shutdown ??= _teardown();

  Future<void> _teardown() async {
    _interrupt.set();
    await _draining;
    // Only when the body was never read: releasing a connection whose body we
    // already consumed would be a second read of a finished stream.
    if (!_drained) await _response.discard();
  }
}
