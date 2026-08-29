/// What the caller knows about a file it wants.
///
/// Only [url] is required: a caller may know nothing but a link. Every caller
/// today comes from a `GbFile` and fills the rest in, but the service must keep
/// working without them — a paste-a-url install has a url and nothing else, and
/// each absent field costs a specific thing named below rather than failing.
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
