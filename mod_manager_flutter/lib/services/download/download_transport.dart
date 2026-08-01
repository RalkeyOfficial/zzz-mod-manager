/// The seam between the download service and the network.
///
/// A sibling of `services/http/http_transport.dart`, deliberately separate: that
/// one returns a fully-decoded `String`, which is exactly wrong for a 1.24 GB
/// archive. This one returns headers plus an **unread stream**, so the service
/// can write bytes to disk as they arrive, apply backpressure, and resume from
/// an offset.
///
/// Like its sibling it is deliberately **dumb**: it composes no `Range`, no
/// `If-Range`, does no retry, no resume logic and no file I/O. All of that lives
/// in the service above, which is what lets a fake assert on the exact headers
/// that were sent.
library;

/// A parsed `Content-Range` response header.
class ContentRange {
  const ContentRange({this.start, this.end, this.total});

  /// First byte of the returned span. Null for the unsatisfiable form.
  final int? start;

  /// Last byte of the returned span, inclusive. Null for the unsatisfiable form.
  final int? end;

  /// Total size of the whole resource, null when the server said `*`.
  final int? total;

  /// Whether this is the `bytes * /total` form a 416 carries.
  bool get isUnsatisfiedForm => start == null && end == null;

  static final RegExp _satisfied =
      RegExp(r'^\s*bytes\s+(\d+)\s*-\s*(\d+)\s*/\s*(\d+|\*)\s*$');
  static final RegExp _unsatisfied =
      RegExp(r'^\s*bytes\s+\*\s*/\s*(\d+|\*)\s*$');

  /// Parses `bytes 100-999/1000` or `bytes * /1000`. Null when absent or
  /// unrecognised — a malformed header must not throw mid-download.
  static ContentRange? parse(String? header) {
    if (header == null) return null;

    final unsatisfied = _unsatisfied.firstMatch(header);
    if (unsatisfied != null) {
      return ContentRange(total: int.tryParse(unsatisfied.group(1)!));
    }

    final match = _satisfied.firstMatch(header);
    if (match == null) return null;
    return ContentRange(
      start: int.tryParse(match.group(1)!),
      end: int.tryParse(match.group(2)!),
      total: int.tryParse(match.group(3)!),
    );
  }

  @override
  String toString() => 'ContentRange(start: $start, end: $end, total: $total)';
}

/// A response whose body has not been read yet.
class DownloadResponse {
  DownloadResponse({
    required this.statusCode,
    required this.body,
    this.contentLength = -1,
    this.headers = const {},
    Future<void> Function()? onDiscard,
  }) : _onDiscard = onDiscard;

  final int statusCode;

  /// Bytes in *this* response — for a `206` that is the length of the returned
  /// span, not the size of the whole file. `-1` when unknown.
  final int contentLength;

  /// Response headers with **lower-cased** keys.
  final Map<String, String> headers;

  /// The unread body.
  ///
  /// Implementations must return a stream whose `pause()` reaches the socket.
  /// Re-emitting through a `StreamController` would silently destroy
  /// backpressure and let a fast network outrun a slow disk.
  final Stream<List<int>> body;

  final Future<void> Function()? _onDiscard;

  String? get etag => headers['etag'];

  ContentRange? get contentRange => ContentRange.parse(headers['content-range']);

  bool get isPartial => statusCode == 206;

  /// Releases the connection without reading the body — used when the status
  /// alone decides the outcome (a 416, or an error we're about to throw on).
  Future<void> discard() async => _onDiscard == null ? null : await _onDiscard();
}

/// Opens byte-stream requests. Implementations must not retry or cache.
abstract class DownloadTransport {
  /// Issues a GET and returns **as soon as the headers arrive**; the body is
  /// left unread.
  ///
  /// Only transport-level failure throws (no connectivity, DNS, TLS, connect
  /// timeout). Any HTTP status — including 4xx and 5xx — comes back as a normal
  /// [DownloadResponse] for the caller to interpret.
  Future<DownloadResponse> open(
    Uri url, {
    Map<String, String> headers = const {},
    Duration connectTimeout = const Duration(seconds: 20),
  });

  void close();
}
