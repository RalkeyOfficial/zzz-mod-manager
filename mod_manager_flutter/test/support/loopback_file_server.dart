import 'dart:async';
import 'dart:io';

/// A real HTTP server on `127.0.0.1`, for the one thing a fake transport cannot
/// test: the spawned-isolate pump.
///
/// A fake `DownloadTransport` is not sendable across an isolate boundary, so the
/// isolate pump has to talk to *something* real. This is hermetic all the same —
/// it binds to loopback on an ephemeral port and never reaches the network, so
/// the suite still runs offline.
class LoopbackFileServer {
  LoopbackFileServer._(this._server, this.body);

  final HttpServer _server;

  /// The bytes `/file.bin` serves. Deterministic, so a test can compare.
  final List<int> body;

  /// Stable across responses, so `If-Range` behaves like the real CDN's.
  static const String etag = '"loopback-1"';

  /// How much of the body `/trickle.bin` hands over before going quiet.
  static const int trickleBytes = 4096;

  /// Whether `/trickle.bin` still goes quiet. Flip it to false and the same url
  /// starts behaving like `/file.bin`, which is how a stalled transfer and the
  /// resume that finishes it can be staged against **one** url — the resume
  /// record is keyed on it, so two urls would simply start over.
  bool stalling = true;

  static Future<LoopbackFileServer> start({int size = 2 * 1024 * 1024}) async {
    final body = List<int>.generate(size, (i) => (i * 31 + 7) % 256);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final instance = LoopbackFileServer._(server, body);
    unawaited(server.forEach(instance._handle).catchError((Object _) {}));
    return instance;
  }

  /// `/file.bin` — the whole body, honouring `Range`.
  /// `/trickle.bin` — [trickleBytes] and then silence, with a `Content-Length`
  /// promising more. This is how a stall and a mid-transfer cancel are staged.
  /// `/missing.bin` — 404.
  Uri uri(String path) => Uri.parse('http://127.0.0.1:${_server.port}$path');

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      switch (request.uri.path) {
        case '/missing.bin':
          response.statusCode = 404;
          await response.close();
        case '/trickle.bin' when stalling:
          final start = _openSpan(request, response);
          // Without `bufferOutput = false` the response sits in Dart's outbound
          // buffer until the promised `Content-Length` is satisfied — which
          // never happens here, so the client would see a connection that
          // delivered nothing at all rather than one that delivered some and
          // then went quiet.
          response.bufferOutput = false;
          response.add(body.sublist(start, start + trickleBytes));
          await response.flush();
        // Deliberately never closed: the client keeps waiting, which is what a
        // stalled CDN node looks like from inside the pump.
        default:
          final start = _openSpan(request, response);
          response.add(body.sublist(start));
          await response.close();
      }
    } catch (_) {
      // The client hung up; nothing here is under test.
    }
  }

  /// Writes the status and headers for whatever span was asked for, and returns
  /// the offset the body should start at.
  ///
  /// `Content-Length` is always set explicitly. Left to itself the server falls
  /// back to chunked encoding, and the client then reports `contentLength` as
  /// -1 — which is an input `ResumePolicy` reads.
  int _openSpan(HttpRequest request, HttpResponse response) {
    final header = request.headers.value('range');
    final match =
        header == null ? null : RegExp(r'bytes=(\d+)-').firstMatch(header);
    final start = match == null ? 0 : int.parse(match.group(1)!);

    response.headers.set('etag', etag);
    if (start > 0) {
      response.statusCode = 206;
      response.headers.set(
        'content-range',
        'bytes $start-${body.length - 1}/${body.length}',
      );
    } else {
      response.statusCode = 200;
    }
    response.contentLength = body.length - start;
    return start;
  }
}
