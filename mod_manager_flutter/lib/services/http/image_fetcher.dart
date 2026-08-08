import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../core/constants.dart';

/// Fetches image **bytes**.
///
/// A second, deliberately tiny seam beside [HttpTransport], rather than a
/// `bytes` method added to it. `HttpTransport` hands back a decoded `String`
/// because everything above it is JSON, and widening that interface would put a
/// binary body on the one type every GameBanana test fakes. This is the narrow
/// role the metadata autofill needs and nothing more — the same reasoning that
/// gave `ModMetadataRepository` a `ModCharacterTagStore` instead of the whole
/// `ConfigService`.
///
/// It is not the file downloader either: that exists for multi-hundred-megabyte
/// archives and earns its ranges, resume and backpressure. A preview image is
/// ~115–310 KB, so a plain GET with a timeout is the right size of tool.
abstract class ImageFetcher {
  /// Returns the bytes, or **null** on any failure.
  ///
  /// Null rather than a throw because every caller's answer is the same: skip
  /// this image. A gallery that arrives one image short is a far better outcome
  /// than an install that reports failure after the mod is already in place.
  Future<Uint8List?> fetch(Uri url);
}

/// The real [ImageFetcher], over `package:http`.
class HttpImageFetcher implements ImageFetcher {
  HttpImageFetcher({http.Client? client, Duration? timeout})
      : _client = client ?? http.Client(),
        _timeout = timeout ?? const Duration(seconds: 20);

  final http.Client _client;

  /// Per-image, so one unlucky request cannot hold an install open.
  ///
  /// A total-duration timeout is wrong for a *download* (a legitimate archive
  /// over a degraded CDN node runs ~25 minutes — see `docs/gamebanana-api.md`
  /// §8), but a preview image is a few hundred KB: even the slowest node
  /// measured, at 0.08 MB/s, would deliver one inside this.
  final Duration _timeout;

  @override
  Future<Uint8List?> fetch(Uri url) async {
    try {
      final response = await _client
          .get(url, headers: {'User-Agent': AppConstants.httpUserAgent})
          .timeout(_timeout);
      if (response.statusCode != 200) return null;
      final bytes = response.bodyBytes;
      return bytes.isEmpty ? null : bytes;
    } catch (e) {
      return null;
    }
  }
}
