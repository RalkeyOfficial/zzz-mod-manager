/// The single seam between our network code and the outside world.
///
/// Every test of the GameBanana layer runs against a fake implementation of
/// [HttpTransport], which is what lets the whole layer be tested with no
/// network at all. If a test here ever needs connectivity, this seam is in the
/// wrong place.
///
/// The interface is deliberately **narrow**: one method, plain values in and
/// out, no `package:http` types leaking through. That mirrors the pattern
/// `ModMetadataRepository` already uses — it declares the small role it needs
/// (`ModCharacterTagStore`) rather than depending on the whole `ConfigService`.
///
/// It is also deliberately **dumb**: no retries, no caching, no default
/// headers. All of that belongs to the client above it, so tests can assert on
/// it deterministically instead of trying to observe it through a transport.
library;

/// A completed HTTP response.
class HttpResponse {
  const HttpResponse({
    required this.statusCode,
    required this.body,
    this.headers = const {},
  });

  final int statusCode;

  /// The decoded body. Only used for JSON here — streamed downloads are a
  /// separate concern with different needs (ranges, resume, backpressure) and
  /// do not belong on this interface.
  final String body;

  /// Response headers with **lower-cased** keys.
  final Map<String, String> headers;

  bool get isSuccess => statusCode >= 200 && statusCode < 300;

  /// Reads `max-age` out of `cache-control`, when the server sent one.
  ///
  /// Used to mirror the server's own TTL rather than inventing our own.
  Duration? get maxAge {
    final control = headers['cache-control'];
    if (control == null) return null;
    final match = RegExp(r'max-age\s*=\s*(\d+)').firstMatch(control);
    if (match == null) return null;
    final seconds = int.tryParse(match.group(1)!);
    return seconds == null ? null : Duration(seconds: seconds);
  }

  /// Reads `retry-after` as a duration, when present. Only the delta-seconds
  /// form is handled; the HTTP-date form is rare and not worth the parser.
  Duration? get retryAfter {
    final seconds = int.tryParse(headers['retry-after']?.trim() ?? '');
    return seconds == null ? null : Duration(seconds: seconds);
  }
}

/// Performs HTTP GETs. Implementations must not retry or cache.
abstract class HttpTransport {
  /// Issues a GET.
  ///
  /// Throws on transport-level failure (no connectivity, DNS, TLS, timeout);
  /// any HTTP status, including 4xx and 5xx, is returned as a normal
  /// [HttpResponse] for the caller to interpret.
  Future<HttpResponse> get(
    Uri url, {
    Map<String, String> headers = const {},
    Duration timeout = const Duration(seconds: 30),
  });

  /// Releases any underlying resources.
  void close();
}
