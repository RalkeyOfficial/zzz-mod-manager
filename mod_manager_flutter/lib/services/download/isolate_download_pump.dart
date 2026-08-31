import 'dart:async';
import 'dart:isolate';

import '../../core/constants.dart';
import '../log/logger.dart';
import 'download_exceptions.dart';
import 'download_pump.dart';
import 'download_transport.dart';
import 'inline_download_pump.dart';
import 'io_download_transport.dart';
import 'pump_body.dart';

/// The production [DownloadPump]: one short-lived isolate per connection.
///
/// This is the fix for the ~3 MB/s ceiling described on [DownloadPump]. The
/// worker owns the socket **and** the file writes, and reports progress as an
/// occasional counter — it must never forward chunks, because a port message to
/// the root isolate pays the very scheduling cost we are escaping, so a worker
/// that relayed bytes would be an elaborate way to change nothing.
///
/// The worker builds its own [IoDownloadTransport] rather than receiving one:
/// an `HttpClient` cannot cross an isolate boundary, and re-deriving the client
/// settings here would be a second HTTP configuration free to drift from the
/// real one. Two of those settings are load-bearing (see that class).
class IsolateDownloadPump implements DownloadPump {
  IsolateDownloadPump({String? userAgent})
      : _userAgent = userAgent ?? AppConstants.httpUserAgent;

  final String _userAgent;

  /// Built only if a spawn ever fails. See [open].
  InlineDownloadPump? _fallback;

  @override
  Future<PumpSession> open(
    Uri url, {
    Map<String, String> headers = const {},
    Duration connectTimeout = const Duration(seconds: 20),
  }) async {
    final events = ReceivePort();
    final lifecycle = ReceivePort();
    final Isolate isolate;
    try {
      isolate = await Isolate.spawn<_WorkerRequest>(
        _downloadWorker,
        _WorkerRequest(
          reply: events.sendPort,
          url: url.toString(),
          headers: Map<String, String>.from(headers),
          connectTimeoutMicros: connectTimeout.inMicroseconds,
          userAgent: _userAgent,
        ),
        onExit: lifecycle.sendPort,
        onError: lifecycle.sendPort,
        debugName: 'download-pump',
      );
    } catch (error) {
      events.close();
      lifecycle.close();
      // Thread exhaustion or OOM. A ~3 MB/s download is the status quo and is
      // strictly better than a failed one, so drop to the inline pump for this
      // attempt rather than surfacing an error nobody can act on. This doubles
      // as the kill switch if the isolate path ever misbehaves in the field.
      Logger('download.pump').warning(
        'isolate spawn failed, downloading inline',
        error: error,
      );
      final fallback = _fallback ??= InlineDownloadPump(
        IoDownloadTransport(userAgent: _userAgent),
      );
      return fallback.open(url, headers: headers, connectTimeout: connectTimeout);
    }

    final session = _IsolateSession(isolate, events, lifecycle);
    // The connect has no other watchdog: the service's stall timer only starts
    // once bytes are expected, so a worker that dies before its first message
    // would otherwise block the run for the life of the app.
    await session.awaitHandshake(connectTimeout + const Duration(seconds: 10));
    return session;
  }

  @override
  Future<void> close() async => _fallback?.close();
}

// ---------------------------------------------------------------------------
// Wire protocol
//
// Tagged `List<Object?>`s rather than objects, in both directions. Everything
// crossing a port is a String, an int, a bool, a Map of those, or a SendPort —
// nothing whose sendability has to be argued about.
// ---------------------------------------------------------------------------

/// worker → main, first thing: the port to send commands back on.
const String _kPort = 'port';

/// worker → main: `[status, contentLength, headers]`, before any byte is written.
const String _kHead = 'head';

/// worker → main: cumulative bytes written by this drain.
const String _kBytes = 'bytes';

/// worker → main: the socket is done, the sink is not yet flushed.
const String _kBodyEnded = 'bodyEnded';

/// worker → main, last thing: `[bytesWritten, md5]`.
const String _kDone = 'done';

/// worker → main: `[kind, message, cause]`.
///
/// A tuple of strings, never a reconstructed exception. `DownloadException`'s
/// `cause` is an `Object?`, so its sendability cannot be argued for in general —
/// and `SendPort.send` on an unsendable graph throws *synchronously inside the
/// worker*, which would kill it silently on exactly the error path. `onError`
/// only ever delivers strings anyway, so strings is the shape both paths share.
const String _kError = 'error';

/// main → worker: `[partPath, hashMd5]`.
const String _kProceed = 'proceed';

/// main → worker: stop, flush, close, exit.
const String _kShutdown = 'shutdown';

const String _kindNetwork = 'network';
const String _kindWrite = 'write';

class _WorkerRequest {
  const _WorkerRequest({
    required this.reply,
    required this.url,
    required this.headers,
    required this.connectTimeoutMicros,
    required this.userAgent,
  });

  final SendPort reply;
  final String url;
  final Map<String, String> headers;
  final int connectTimeoutMicros;

  /// Passed rather than read from [AppConstants] inside the worker only so a
  /// test can assert what the real transport sends.
  final String userAgent;
}

/// How often the worker posts its byte counter.
///
/// Not tunable and not per-chunk: at ~8 KB a chunk, per-chunk reporting would
/// be ~3300 messages for a 27 MB file, each paying the root isolate's ~2.3 ms
/// event cost — i.e. exactly the bug. 200 ms is far below the 60 s stall window
/// and gives `RateEstimator` five samples a second, which is more than its
/// one-second minimum span needs.
const Duration _reportInterval = Duration(milliseconds: 200);

// ---------------------------------------------------------------------------
// The main-isolate side
// ---------------------------------------------------------------------------

class _IsolateSession implements PumpSession {
  _IsolateSession(this._isolate, this._events, this._lifecycle) {
    _events.listen(_onEvent);
    _lifecycle.listen(_onLifecycle);
  }

  final Isolate _isolate;
  final ReceivePort _events;
  final ReceivePort _lifecycle;

  final Completer<void> _head = Completer<void>();
  final Completer<void> _exited = Completer<void>();
  Completer<PumpOutcome>? _drain;

  SendPort? _commands;
  Future<void>? _shutdown;

  void Function(int)? _onBytes;
  void Function()? _onBodyEnded;

  int _statusCode = 0;
  int _contentLength = -1;
  Map<String, String> _headers = const {};

  @override
  int get statusCode => _statusCode;

  @override
  int get contentLength => _contentLength;

  @override
  Map<String, String> get headers => _headers;

  @override
  String? get etag => _headers['etag'];

  @override
  ContentRange? get contentRange => ContentRange.parse(_headers['content-range']);

  Future<void> awaitHandshake(Duration timeout) async {
    try {
      await _head.future.timeout(timeout);
    } catch (error) {
      await shutdown();
      rethrow;
    }
  }

  void _onEvent(dynamic raw) {
    final message = (raw as List).cast<Object?>();
    switch (message[0] as String) {
      case _kPort:
        _commands = message[1] as SendPort;
        // A shutdown that arrived before the worker was listening still has to
        // land, or the isolate would run the whole download unobserved.
        if (_shutdown != null) _commands!.send(const <Object?>[_kShutdown]);
      case _kHead:
        _statusCode = message[1] as int;
        _contentLength = message[2] as int;
        _headers = Map<String, String>.unmodifiable(
          (message[3] as Map).cast<String, String>(),
        );
        if (!_head.isCompleted) _head.complete();
      case _kBytes:
        _onBytes?.call(message[1] as int);
      case _kBodyEnded:
        _onBodyEnded?.call();
      case _kDone:
        _finishDrain(
          PumpOutcome(
            bytesWritten: message[1] as int,
            md5: message[2] as String?,
          ),
        );
      case _kError:
        _failWith(_exceptionFrom(message));
    }
  }

  void _onLifecycle(dynamic message) {
    // `onExit` sends null; `onError` sends [error, stackTrace] as Strings.
    if (message is List) {
      _failWith(DownloadNetworkException(
        'Download worker failed',
        cause: message.isEmpty ? null : '${message.first}',
      ));
      return;
    }
    if (!_exited.isCompleted) _exited.complete();
    // Deferred a turn on purpose. The worker's last message and its exit
    // notification are two separate deliveries, so failing here would race the
    // very result we are waiting for. By the time a timer scheduled now fires,
    // anything already queued has been delivered — and if a drain is *still*
    // outstanding then the worker really did die without answering.
    Timer.run(() {
      _failWith(const DownloadNetworkException('Download worker exited early'));
    });
  }

  void _finishDrain(PumpOutcome outcome) {
    final drain = _drain;
    _drain = null;
    if (drain != null && !drain.isCompleted) drain.complete(outcome);
  }

  void _failWith(Object error) {
    final drain = _drain;
    _drain = null;
    if (drain != null && !drain.isCompleted) drain.completeError(error);
    if (!_head.isCompleted) _head.completeError(error);
  }

  @override
  Future<PumpOutcome> drainTo(
    String partPath, {
    required bool hashMd5,
    required void Function(int bytesWritten) onBytes,
    required void Function() onBodyEnded,
  }) {
    _onBytes = onBytes;
    _onBodyEnded = onBodyEnded;
    final drain = Completer<PumpOutcome>();
    _drain = drain;
    _commands?.send(<Object?>[_kProceed, partPath, hashMd5]);
    return drain.future;
  }

  /// Memoised, so the several call sites that all reach for it — cancel, a
  /// stall, the 416 retry, the success path's `finally` — cannot race each
  /// other into two half-teardowns.
  @override
  Future<void> shutdown() => _shutdown ??= _teardown();

  Future<void> _teardown() async {
    _commands?.send(const <Object?>[_kShutdown]);
    try {
      await _exited.future.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      // A wedged worker must not hang a cancel, and killing one cannot corrupt
      // the partial: the sink only ever appends, and each underlying write
      // either happened or did not, so the `.part` is always a valid **prefix**
      // of the file. A kill can lose a tail, never interleave — and nothing
      // upstream trusts the byte counter over `File.length()` anyway.
      _isolate.kill(priority: Isolate.immediate);
      await _exited.future
          .timeout(const Duration(seconds: 2))
          .catchError((Object _) {});
    } finally {
      _failWith(const DownloadCancelledException());
      _events.close();
      _lifecycle.close();
    }
  }
}

/// Maps an error tuple back onto the sealed hierarchy.
///
/// There is deliberately no isolate-specific subclass: `DownloadException` is
/// `sealed`, so a new member would open every exhaustive switch over it for no
/// user-visible gain. An HTTP status never travels this way either — those come
/// back as an ordinary head message for `ResumePolicy` to judge.
DownloadException _exceptionFrom(List<Object?> message) {
  final text = message[2] as String;
  final cause = message[3] as String?;
  return (message[1] as String) == _kindWrite
      ? DownloadWriteException(text, cause: cause)
      : DownloadNetworkException(text, cause: cause);
}

// ---------------------------------------------------------------------------
// The worker
// ---------------------------------------------------------------------------

/// Runs on the spawned isolate. Nothing here may touch Flutter — no platform
/// channels, no `PathHelper`, no providers — which is why every path it needs
/// arrives as a plain `String`.
Future<void> _downloadWorker(_WorkerRequest request) async {
  final commands = ReceivePort();
  final transport = IoDownloadTransport(userAgent: request.userAgent);
  final interrupt = PumpInterrupt();
  final firstCommand = Completer<List<Object?>>();

  commands.listen((dynamic raw) {
    final message = (raw as List).cast<Object?>();
    if (message[0] == _kShutdown) interrupt.set();
    if (!firstCommand.isCompleted) firstCommand.complete(message);
  });

  // Every exit runs through here: an open `ReceivePort` or a live `HttpClient`
  // keep-alive connection is enough to keep an isolate alive forever, which
  // would leak one worker per download.
  Never finish(List<Object?> message) {
    commands.close();
    transport.close();
    // Terminates immediately — which is why the cleanup above is *not* in a
    // `finally`. `Isolate.exit` does not run those.
    Isolate.exit(request.reply, message);
  }

  request.reply.send(<Object?>[_kPort, commands.sendPort]);

  final DownloadResponse response;
  try {
    response = await transport.open(
      Uri.parse(request.url),
      headers: request.headers,
      connectTimeout: Duration(microseconds: request.connectTimeoutMicros),
    );
  } catch (error) {
    finish(<Object?>[
      _kError,
      _kindNetwork,
      'Could not reach ${request.url}',
      '$error',
    ]);
  }

  request.reply.send(<Object?>[
    _kHead,
    response.statusCode,
    response.contentLength,
    response.headers,
  ]);

  final command = await firstCommand.future;
  if (command[0] != _kProceed) {
    await response.discard();
    finish(const <Object?>[_kDone, 0, null]);
  }

  final partPath = command[1] as String;
  final hashMd5 = command[2] as bool;

  var written = 0;
  // Starts at 0, not -1: "nothing has arrived yet" is not progress, and posting
  // it would only tell the main isolate what it already assumed.
  var reported = 0;
  final ticker = Timer.periodic(_reportInterval, (_) {
    if (written == reported) return;
    reported = written;
    request.reply.send(<Object?>[_kBytes, written]);
  });

  try {
    final outcome = await pumpResponseToFile(
      response,
      partPath,
      hashMd5: hashMd5,
      onBytes: (bytes) => written = bytes,
      onBodyEnded: () => request.reply.send(const <Object?>[_kBodyEnded]),
      interrupt: interrupt,
    );
    ticker.cancel();
    finish(<Object?>[_kDone, outcome.bytesWritten, outcome.md5]);
  } catch (error) {
    ticker.cancel();
    finish(<Object?>[
      _kError,
      error is DownloadWriteException ? _kindWrite : _kindNetwork,
      error is DownloadException ? error.message : 'Transfer failed',
      '$error',
    ]);
  }
}
