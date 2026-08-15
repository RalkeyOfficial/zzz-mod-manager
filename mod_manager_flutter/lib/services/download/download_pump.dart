/// The seam between [DownloadService] and whatever actually reads the socket.
///
/// **Why this exists at all**, because it is not obvious and someone will
/// otherwise flatten it back into the service: on the root isolate the event
/// loop is the Flutter engine's UI task runner, and every socket read event
/// costs ~2.3 ms there. Chunks arrive as ~8158-byte TLS records, so that is a
/// hard ~3 MB/s ceiling no matter how fast the server is. The same download
/// code on a spawned isolate measured **17.4 MB/s at 0.45 ms/chunk** in the same
/// process and the same seconds — a 5.3–5.9× speedup. See
/// `../../CLAUDE.md` § "The download layer".
///
/// So the pump is the part that has to be able to live somewhere other than the
/// root isolate. Everything above it — [ResumePolicy], `DownloadPaths`,
/// `PartialDownload`, promote/sweep, the stall timer, `RateEstimator` — stays on
/// the main isolate, because every one of those is a *decision* and decisions
/// are where the subtle bugs live.
library;

import 'download_transport.dart';

/// What one drain produced.
class PumpOutcome {
  const PumpOutcome({required this.bytesWritten, this.md5});

  /// Bytes written by **this** drain, not counting any resumed prefix already
  /// on disk. The service adds its own `resumedFrom` to get a total.
  final int bytesWritten;

  /// md5 over exactly the bytes this drain wrote, or null when it wasn't asked
  /// for. Only meaningful when the drain wrote the whole file.
  final String? md5;
}

/// One opened connection, whose body has not been read yet.
///
/// Deliberately two-phase: the service has to see [statusCode] and [headers]
/// and run [ResumePolicy] **before** any byte is written, because that is what
/// decides append/restart/complete/fail.
abstract class PumpSession {
  int get statusCode;

  /// Bytes in *this* response — for a `206` the length of the returned span,
  /// not the size of the whole file. `-1` when unknown.
  int get contentLength;

  /// Response headers with **lower-cased** keys, unparsed.
  ///
  /// Raw rather than pre-parsed so `ContentRange.parse` stays the one parser and
  /// `ResumePolicy.decide` keeps taking exactly what it takes today.
  Map<String, String> get headers;

  String? get etag => headers['etag'];

  ContentRange? get contentRange => ContentRange.parse(headers['content-range']);

  /// Streams the body onto the **end** of the file at [partPath].
  ///
  /// Always appends. There is deliberately no "truncate" mode: a restart means
  /// the *service* deletes the partial before it gets here, which closes a
  /// window where a crash between writing the resume record and truncating the
  /// file would leave a record describing the new download beside the old
  /// download's bytes — and the next resume would append one onto the other.
  ///
  /// [onBytes] reports bytes written by this drain so far. It is a **counter**,
  /// reported occasionally; it is never per-chunk, because a per-chunk message
  /// to the root isolate would pay exactly the scheduling cost this whole seam
  /// exists to avoid.
  ///
  /// [onBodyEnded] fires when the socket is done but before the sink is flushed
  /// and closed. The service uses it to stop the stall timer, so a multi-second
  /// flush of a gigabyte-sized file cannot be mistaken for a dead transfer.
  Future<PumpOutcome> drainTo(
    String partPath, {
    required bool hashMd5,
    required void Function(int bytesWritten) onBytes,
    required void Function() onBodyEnded,
  });

  /// The **one** teardown, safe to call in any state and any number of times.
  ///
  /// Returns only once the sink is flushed and closed and the connection is
  /// released, which is what lets the caller rename or delete the partial file
  /// immediately afterwards. Windows refuses both operations on a file that is
  /// still open, and Linux hides the same mistake by unlinking a still-written
  /// inode — so "the pump has definitely let go" has to be something the caller
  /// can await rather than assume.
  Future<void> shutdown();
}

/// Opens byte-stream requests. Implementations must not retry or cache.
abstract class DownloadPump {
  /// Issues a GET and returns **as soon as the headers arrive**; the body is
  /// left unread.
  ///
  /// Only transport-level failure throws (no connectivity, DNS, TLS, connect
  /// timeout). Any HTTP status — including 4xx and 5xx — comes back as a normal
  /// [PumpSession] for the caller to interpret.
  Future<PumpSession> open(
    Uri url, {
    Map<String, String> headers = const {},
    Duration connectTimeout = const Duration(seconds: 20),
  });

  Future<void> close();
}
