import '../../models/gamebanana/gb_exceptions.dart';
import '../../models/gamebanana/gb_page.dart';
import '../http/http_transport.dart';

/// Turns a raw [HttpResponse] into a typed [GbException], or lets it through.
///
/// Split out from the client so the precedence below is readable in one place
/// and testable without a transport. The order matters, and one rule is easy to
/// miss: **the API can serve an error envelope with a `200`**, so the decoded
/// body is checked for `_sErrorCode` regardless of status.
class GameBananaErrorMapper {
  const GameBananaErrorMapper();

  /// Statuses worth retrying. Note what is *absent*: a `400` is a bug in our
  /// own url building, and retrying it just makes the same mistake three times.
  static bool isRetryable(int statusCode) =>
      statusCode == 429 || statusCode == 503;

  /// Throws if [response] represents a failure; returns the body otherwise.
  String bodyOrThrow(HttpResponse response) {
    if (isRetryable(response.statusCode)) {
      throw GbRateLimitException(
        'Server asked us to back off (HTTP ${response.statusCode})',
        statusCode: response.statusCode,
        retryAfter: response.retryAfter,
      );
    }

    if (response.statusCode >= 400) {
      throw _envelopeError(response) ??
          GbApiException(
            'HTTP ${response.statusCode}',
            code: null,
            statusCode: response.statusCode,
            fieldErrors: const {},
          );
    }

    // A 2xx can still carry an error envelope. Cheap insurance.
    final masked = _envelopeError(response);
    if (masked != null) throw masked;

    // **Success with nothing in it.** Checked after the status codes above, so a
    // `404` that also sent nothing stays not-found: an empty body is only
    // interesting when the server claimed it had answered. Raised here rather
    // than left to the JSON layer because the client can retry this one, and
    // because "we couldn't read it" is the wrong thing to tell anybody about a
    // body that does not exist.
    if (response.body.trim().isEmpty) {
      throw GbEmptyResponseException(
        'HTTP ${response.statusCode} with an empty body',
        statusCode: response.statusCode,
      );
    }

    return response.body;
  }

  /// Parses `{_sErrorCode, _sErrorMessage, _aErrorData}`, or null when the body
  /// isn't that shape (including when it isn't JSON at all — an error page from
  /// a proxy shouldn't turn into a confusing format error here).
  GbApiException? _envelopeError(HttpResponse response) {
    final Object? decoded;
    try {
      decoded = gbDecode(response.body);
    } on GbFormatException {
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;

    final code = decoded['_sErrorCode'];
    if (code is! String || code.isEmpty) return null;

    final fieldErrors = <String, GbFieldError>{};
    final data = decoded['_aErrorData'];
    if (data is Map) {
      data.forEach((field, detail) {
        if (field is! String || detail is! Map) return;
        fieldErrors[field] = GbFieldError(
          code: detail['_sErrorCode'] as String?,
          message: detail['_sErrorMessage'] as String?,
        );
      });
    }

    final message = decoded['_sErrorMessage'];
    return GbApiException(
      message is String && message.isNotEmpty ? message : code,
      code: code,
      statusCode: response.statusCode,
      fieldErrors: fieldErrors,
    );
  }
}
