/// What the caller knows about a file it wants.
///
/// Only [url] is required. The GameBanana-derived fields are optional because
/// the marketplace is still a webview today: it intercepts a CDN url and knows
/// nothing else about the file. The native browser will fill them in, and
/// nothing about the service changes when it does.
class DownloadRequest {
  const DownloadRequest({
    required this.url,
    this.suggestedFilename,
    this.fileId,
    this.expectedSize,
    this.expectedMd5,
  });

  final Uri url;

  /// Preferred final name. Sanitized before use — it is untrusted input.
  final String? suggestedFilename;

  /// GameBanana file id (`_idRow`), when known.
  final int? fileId;

  /// `_nFilesize`, which is exactly the eventual `Content-Length`. Useful as a
  /// progress denominator before the first response and for a preflight
  /// free-space check.
  final int? expectedSize;

  /// `_sMd5Checksum` from the mod page, when known.
  ///
  /// Recorded for later matching only. It is **not** verified against the
  /// download and grants no trust: md5 is cryptographically broken, so a match
  /// means "byte-identical to the file on the mod page", nothing more.
  final String? expectedMd5;
}
