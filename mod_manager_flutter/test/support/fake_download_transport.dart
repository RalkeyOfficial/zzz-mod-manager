import 'dart:async';

import 'package:mod_manager_flutter/services/download/download_transport.dart';

/// A scripted [DownloadTransport] for offline tests.
///
/// Mirrors `FakeHttpTransport`: responses queue per-url so a test can express
/// "interrupted, then resumed", and every request is recorded because most of
/// what needs asserting is *which headers were sent* — a resume is only correct
/// if it carried `range` and `if-range`.
class FakeDownloadTransport implements DownloadTransport {
  /// Every url opened, in order.
  final List<Uri> requests = <Uri>[];

  /// Headers sent with each request, index-aligned with [requests].
  final List<Map<String, String>> sentHeaders = <Map<String, String>>[];

  final Map<String, List<_Scripted>> _queues = <String, List<_Scripted>>{};

  bool closed = false;

  int get callCount => requests.length;

  /// The header map of the most recent request.
  Map<String, String> get lastHeaders => sentHeaders.last;

  /// Queues one response returning [body] in chunks of [chunkSize].
  ///
  /// When [failAfter] is set the stream emits that many bytes and then errors,
  /// which is how an interrupted transfer is simulated.
  void enqueue(
    Uri url, {
    List<int> body = const [],
    int statusCode = 200,
    Map<String, String> headers = const {},
    int chunkSize = 8,
    int? failAfter,
    int? contentLength,
    Object? openError,
    Duration? openDelay,
  }) {
    _queues.putIfAbsent(url.toString(), () => <_Scripted>[]).add(
          _Scripted(
            statusCode: statusCode,
            body: body,
            headers: headers,
            chunkSize: chunkSize,
            failAfter: failAfter,
            contentLength: contentLength ?? body.length,
            openError: openError,
            openDelay: openDelay,
          ),
        );
  }

  /// Queues a response whose body the test drives by hand — needed for stall,
  /// cancel and backpressure, where timing is the thing under test.
  void enqueueControlled(
    Uri url,
    StreamController<List<int>> controller, {
    int statusCode = 200,
    Map<String, String> headers = const {},
    int contentLength = -1,
  }) {
    _queues.putIfAbsent(url.toString(), () => <_Scripted>[]).add(
          _Scripted(
            statusCode: statusCode,
            headers: headers,
            controller: controller,
            contentLength: contentLength,
          ),
        );
  }

  /// Queues a transport-level failure (no connectivity, TLS, connect timeout).
  void enqueueError(Uri url, Object error) => enqueue(url, openError: error);

  /// True once a queued response's body has been discarded rather than read.
  final List<Uri> discarded = <Uri>[];

  @override
  Future<DownloadResponse> open(
    Uri url, {
    Map<String, String> headers = const {},
    Duration connectTimeout = const Duration(seconds: 20),
  }) async {
    requests.add(url);
    sentHeaders.add(Map<String, String>.from(headers));

    final queue = _queues[url.toString()];
    if (queue == null || queue.isEmpty) {
      throw StateError(
        'FakeDownloadTransport got an unscripted request:\n  $url\n'
        'Scripted urls:\n${_queues.keys.map((k) => '  $k').join('\n')}',
      );
    }
    // Always consume. A "last one repeats" shortcut would silently re-serve an
    // interrupted response to a resume attempt, which reads as a service bug.
    final scripted = queue.removeAt(0);
    // Holds the response back so a test can act while the run is still
    // "connecting" — the window a real CDN spends on two redirect hops, and the
    // one a user pressing Cancel is most likely to be in.
    if (scripted.openDelay != null) {
      await Future<void>.delayed(scripted.openDelay!);
    }
    if (scripted.openError != null) throw scripted.openError!;

    return DownloadResponse(
      statusCode: scripted.statusCode,
      contentLength: scripted.contentLength,
      headers: scripted.headers,
      body: scripted.stream(),
      onDiscard: () async => discarded.add(url),
    );
  }

  @override
  void close() => closed = true;
}

class _Scripted {
  _Scripted({
    required this.statusCode,
    required this.headers,
    required this.contentLength,
    this.body = const [],
    this.chunkSize = 8,
    this.failAfter,
    this.controller,
    this.openError,
    this.openDelay,
  });

  final int statusCode;
  final List<int> body;
  final Map<String, String> headers;
  final int chunkSize;
  final int? failAfter;
  final int contentLength;
  final StreamController<List<int>>? controller;
  final Object? openError;
  final Duration? openDelay;

  Stream<List<int>> stream() {
    final driven = controller;
    if (driven != null) return driven.stream;

    // A generator, so the consumer's backpressure genuinely governs how fast
    // bytes are produced — the same property the real socket has.
    return () async* {
      var sent = 0;
      for (var i = 0; i < body.length; i += chunkSize) {
        final end = (i + chunkSize).clamp(0, body.length);
        final chunk = body.sublist(i, end);
        if (failAfter != null && sent + chunk.length > failAfter!) {
          final remaining = failAfter! - sent;
          if (remaining > 0) yield chunk.sublist(0, remaining);
          throw const SocketExceptionStub();
        }
        sent += chunk.length;
        yield chunk;
      }
    }();
  }
}

/// Stands in for a `dart:io` SocketException without importing it.
class SocketExceptionStub implements Exception {
  const SocketExceptionStub();

  @override
  String toString() => 'SocketExceptionStub: connection interrupted';
}
