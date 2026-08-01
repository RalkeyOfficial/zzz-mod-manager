import 'package:mod_manager_flutter/services/http/http_transport.dart';

/// A scripted [HttpTransport] for offline tests.
///
/// Responses are queued per-url so a test can express "429, then 200" — which
/// is the only way to test reactive backoff without waiting on a real server.
/// Every request is recorded, because most of what needs asserting about the
/// client is *how many* requests it made and *what url and headers* it sent,
/// not just the value it returned.
class FakeHttpTransport implements HttpTransport {
  /// Every url requested, in order. Length is the call count.
  final List<Uri> requests = <Uri>[];

  /// The headers sent with each request, index-aligned with [requests].
  final List<Map<String, String>> sentHeaders = <Map<String, String>>[];

  final Map<String, List<_Scripted>> _queues = <String, List<_Scripted>>{};
  _Scripted? _fallback;

  bool closed = false;

  int get callCount => requests.length;

  /// Requests matching [url] return [body]. Repeats indefinitely unless a
  /// later [enqueue] supplies something more specific.
  void stub(
    Uri url, {
    String body = '{}',
    int statusCode = 200,
    Map<String, String> headers = const {},
  }) {
    _queues.putIfAbsent(_key(url), () => <_Scripted>[]).add(
          _Scripted(
            HttpResponse(statusCode: statusCode, body: body, headers: headers),
            repeating: true,
          ),
        );
  }

  /// Queues a **single** response for [url], consumed by the next matching
  /// request. Use several calls to script a sequence.
  void enqueue(
    Uri url, {
    String body = '{}',
    int statusCode = 200,
    Map<String, String> headers = const {},
    Object? error,
  }) {
    _queues.putIfAbsent(_key(url), () => <_Scripted>[]).add(
          _Scripted(
            HttpResponse(statusCode: statusCode, body: body, headers: headers),
            error: error,
          ),
        );
  }

  /// Queues a transport-level failure (no connectivity, TLS, timeout).
  void enqueueError(Uri url, Object error) => enqueue(url, error: error);

  /// Response for any url with nothing scripted. Without one, an unexpected
  /// request fails the test loudly rather than quietly returning `{}`.
  void stubAnything({String body = '{}', int statusCode = 200}) {
    _fallback = _Scripted(
      HttpResponse(statusCode: statusCode, body: body),
      repeating: true,
    );
  }

  /// Matching ignores the query string's *order* by keying on the full url —
  /// the client builds params in a fixed order, so this stays deterministic.
  String _key(Uri url) => url.toString();

  @override
  Future<HttpResponse> get(
    Uri url, {
    Map<String, String> headers = const {},
    Duration timeout = const Duration(seconds: 30),
  }) async {
    requests.add(url);
    sentHeaders.add(Map<String, String>.from(headers));

    final queue = _queues[_key(url)];
    final scripted = _next(queue) ?? _fallback;
    if (scripted == null) {
      throw StateError(
        'FakeHttpTransport got an unscripted request:\n  $url\n'
        'Scripted urls:\n${_queues.keys.map((k) => '  $k').join('\n')}',
      );
    }
    if (scripted.error != null) throw scripted.error!;
    return scripted.response;
  }

  _Scripted? _next(List<_Scripted>? queue) {
    if (queue == null || queue.isEmpty) return null;
    final head = queue.first;
    if (!head.repeating) queue.removeAt(0);
    return head;
  }

  @override
  void close() => closed = true;
}

class _Scripted {
  _Scripted(this.response, {this.error, this.repeating = false});

  final HttpResponse response;
  final Object? error;
  final bool repeating;
}
