/// Failures the download service can raise.
///
/// Typed rather than a bare `Exception('HTTP 500')` because the call site
/// genuinely treats them differently: a cancellation is silent, a stall gets a
/// "try again" message, and a 404 does not.
///
/// These carry developer-facing text only. The UI maps them onto l10n keys.
library;

sealed class DownloadException implements Exception {
  const DownloadException(this.message);

  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// The user pressed Cancel. Not an error — call sites should swallow it rather
/// than showing a failure message.
class DownloadCancelledException extends DownloadException {
  const DownloadCancelledException([super.message = 'Download cancelled']);
}

/// No bytes arrived for the stall window.
///
/// Note this is emphatically **not** "the download took too long": a legitimate
/// transfer over a degraded CDN node can run for 25 minutes and must be allowed
/// to. Only a complete absence of progress counts.
class DownloadStalledException extends DownloadException {
  const DownloadStalledException(super.message, {required this.stallTimeout});

  final Duration stallTimeout;
}

/// The server answered with a status we can't proceed from.
class DownloadHttpException extends DownloadException {
  const DownloadHttpException(
    super.message, {
    required this.statusCode,
    this.retryable = false,
  });

  final int statusCode;

  /// Whether trying again later is plausible (5xx) or pointless (404).
  final bool retryable;
}

/// The request never produced a response: no connectivity, DNS, TLS, timeout.
class DownloadNetworkException extends DownloadException {
  const DownloadNetworkException(super.message, {this.cause});

  final Object? cause;
}

/// Writing to disk failed — permissions, or the volume filled up mid-transfer.
class DownloadWriteException extends DownloadException {
  const DownloadWriteException(super.message, {this.cause});

  final Object? cause;
}

/// A preflight check found less free space than the file needs.
///
/// Only raised where free space is actually knowable; Dart exposes no portable
/// API for it, so the check is best-effort and skipped when unavailable.
class InsufficientSpaceException extends DownloadException {
  const InsufficientSpaceException(
    super.message, {
    required this.requiredBytes,
    this.availableBytes,
  });

  final int requiredBytes;
  final int? availableBytes;
}
