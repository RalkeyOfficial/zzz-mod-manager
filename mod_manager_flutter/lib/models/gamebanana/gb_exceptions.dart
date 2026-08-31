/// Failures the GameBanana layer can raise.
///
/// These carry **codes, never user-facing prose**. The API's own error messages
/// are server English and cannot be localized, so the UI maps a [GbException]
/// onto its own l10n keys rather than printing [GbApiException.code] or any
/// message from the wire.
library;

/// Base type for every failure originating in the GameBanana layer.
sealed class GbException implements Exception {
  const GbException(this.message);

  /// Developer-facing detail. Not for display — see the library note above.
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// The request never produced a usable HTTP response: no connectivity, DNS
/// failure, TLS failure, or a timeout.
class GbNetworkException extends GbException {
  const GbNetworkException(super.message, {this.cause});

  /// The underlying error, kept for logging.
  final Object? cause;
}

/// The server asked us to slow down (`429`) or was temporarily unavailable
/// (`503`), and the client's reactive retries were already exhausted.
class GbRateLimitException extends GbException {
  const GbRateLimitException(super.message, {this.statusCode, this.retryAfter});

  final int? statusCode;

  /// The `Retry-After` hint, when the server sent one. Normal responses carry
  /// no rate-limit headers at all, so this is usually null even on a real 429.
  final Duration? retryAfter;
}

/// The server claimed success and sent **nothing at all** — a `2xx` with an
/// empty body.
///
/// Not a format failure, though it arrives at the same place. Nothing was sent,
/// so there is no shape to have got wrong, and the two want different answers:
/// a malformed body will look the same on the next press, while this clears up
/// on its own.
///
/// **Measured, not theorised.** Mod 712159's `ProfilePage` answered `200` with
/// zero bytes twice in a row, and served 14,926 bytes of valid JSON for the same
/// url a minute later. The client retries it like a back-off and only raises
/// this once those are spent.
///
/// The damage it did was in the caching, not the request: an empty body kept for
/// the cache's ten minutes made one hiccup look like a mod whose page was
/// permanently broken, because every retry was served from memory without asking
/// again.
class GbEmptyResponseException extends GbException {
  const GbEmptyResponseException(super.message, {this.statusCode});

  final int? statusCode;
}

/// The server returned a structured error envelope
/// (`{"_sErrorCode": …, "_aErrorData": {…}}`).
///
/// Note this can arrive with a `200` as well as a `4xx`, so the client checks
/// the decoded body for `_sErrorCode` regardless of status.
class GbApiException extends GbException {
  const GbApiException(
    super.message, {
    required this.code,
    this.statusCode,
    this.fieldErrors = const {},
  });

  /// `_sErrorCode` — e.g. `INPUT_ERRORS`, `NO_SUCH_ROUTE`, `UNKNOWN_SORT`,
  /// `INVALID_FILTER_VALUE`, `INVALID_PERPAGE`. Null when the body carried no
  /// recognisable envelope.
  final String? code;

  final int? statusCode;

  /// `_aErrorData`, flattened to `field -> error`. For an `INPUT_ERRORS`
  /// response this names the offending parameter (`_sSort`, `_nPerpage`, …),
  /// which is the only thing that makes a 400 debuggable — the API never lists
  /// which values *would* have been accepted.
  final Map<String, GbFieldError> fieldErrors;

  /// Whether the mod/route simply doesn't exist.
  ///
  /// **The status check is what carries this**, and the codes are corroboration.
  /// A missing *record* answers `NO_SUCH_RECORD` and a missing *route*
  /// `NO_SUCH_ROUTE`, but both arrive as `404` — and apiv13 serves an unknown
  /// route as `200` + HTML with no code at all, so no list of codes is complete.
  /// See [`docs/gamebanana-api.md`](../../../../docs/gamebanana-api.md) §2.
  bool get isNotFound =>
      code == 'NO_SUCH_RECORD' || code == 'NO_SUCH_ROUTE' || statusCode == 404;
}

/// One entry of `_aErrorData`.
class GbFieldError {
  const GbFieldError({this.code, this.message});

  /// `_sErrorCode`, e.g. `UNKNOWN_SORT`.
  final String? code;

  /// `_sErrorMessage` — server English, for logs only.
  final String? message;

  @override
  String toString() => '${code ?? 'ERROR'}: ${message ?? ''}';
}

/// The response body was not the JSON shape we expected.
///
/// Covers a body that isn't JSON at all (a Cloudflare interstitial, an empty
/// body) and a body whose top level is the wrong shape — an envelope where a
/// bare array was expected, or vice versa. That confusion is worth failing
/// loudly on: silently treating one as the other surfaces much later as an
/// inexplicably empty results grid.
class GbFormatException extends GbException {
  const GbFormatException(super.message, {this.bodySnippet});

  /// A truncated prefix of the offending body, for logs.
  final String? bodySnippet;
}
