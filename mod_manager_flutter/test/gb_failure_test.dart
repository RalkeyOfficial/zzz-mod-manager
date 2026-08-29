import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_exceptions.dart';
import 'package:mod_manager_flutter/services/gamebanana/gb_failure.dart';

/// The classifier behind both browser screens' error state.
///
/// Real exception instances rather than mocks — these are value types with no
/// I/O, so a fake would only be a worse copy of the thing under test.
///
/// The pair worth reading together is `notFound` and everything else. Three of
/// the four kinds can come good on the next press; a removed mod cannot, and the
/// whole reason this decision left the widgets is that it must be answered once
/// rather than twice.
void main() {
  GbApiException api({String? code, int? status}) => GbApiException(
        'server english that must never reach a screen',
        code: code,
        statusCode: status,
      );

  group('classification', () {
    test('a request that never produced a response is offline', () {
      expect(
        describeGbFailure(const GbNetworkException('SocketException')).kind,
        GbFailureKind.offline,
      );
    });

    test('a back-off is its own kind, with or without a Retry-After', () {
      // The header is usually absent even on a real 429 — GameBanana publishes
      // no rate-limit headers — so the classification cannot depend on it.
      expect(
        describeGbFailure(const GbRateLimitException('429')).kind,
        GbFailureKind.rateLimited,
      );
      expect(
        describeGbFailure(
          const GbRateLimitException('429', retryAfter: Duration(seconds: 30)),
        ).kind,
        GbFailureKind.rateLimited,
      );
    });

    test('a 503 reaches us as a back-off, not as a server error', () {
      // The mapper folds 503 into GbRateLimitException alongside 429, so this
      // pins the classification against someone splitting them later.
      expect(
        describeGbFailure(const GbRateLimitException('503', statusCode: 503))
            .kind,
        GbFailureKind.rateLimited,
      );
    });

    group('not found', () {
      test('by status alone', () {
        expect(describeGbFailure(api(status: 404)).kind, GbFailureKind.notFound);
      });

      test('by NO_SUCH_RECORD, which is what a missing mod answers', () {
        expect(
          describeGbFailure(api(code: 'NO_SUCH_RECORD', status: 404)).kind,
          GbFailureKind.notFound,
        );
      });

      test('by NO_SUCH_ROUTE', () {
        expect(
          describeGbFailure(api(code: 'NO_SUCH_ROUTE')).kind,
          GbFailureKind.notFound,
        );
      });
    });

    test('a 400 is our own bad request, not a missing mod', () {
      expect(
        describeGbFailure(api(code: 'INPUT_ERRORS', status: 400)).kind,
        GbFailureKind.generic,
      );
    });

    test('an unreadable body is generic', () {
      expect(
        describeGbFailure(const GbFormatException('not JSON')).kind,
        GbFailureKind.generic,
      );
    });

    test('a bug of ours lands somewhere honest rather than throwing again', () {
      // What `AsyncValue.error` hands over is `Object`, so anything at all can
      // arrive here — and an error state that throws while rendering is the one
      // outcome that leaves the user with nothing.
      expect(describeGbFailure(StateError('oops')).kind, GbFailureKind.generic);
      expect(describeGbFailure('a bare string').kind, GbFailureKind.generic);
    });
  });

  group('canRetry', () {
    test('is withheld on notFound and nowhere else', () {
      for (final kind in GbFailureKind.values) {
        expect(
          GbFailure(kind).canRetry,
          kind != GbFailureKind.notFound,
          reason: 'retry offered for the wrong kinds: $kind',
        );
      }
    });

    test('a removed mod offers no retry', () {
      expect(describeGbFailure(api(status: 404)).canRetry, isFalse);
    });

    test('every recoverable failure does', () {
      expect(
        describeGbFailure(const GbNetworkException('offline')).canRetry,
        isTrue,
      );
      expect(
        describeGbFailure(const GbRateLimitException('429')).canRetry,
        isTrue,
      );
      expect(
        describeGbFailure(const GbFormatException('junk')).canRetry,
        isTrue,
      );
    });
  });

  test('the failure carries nothing from the wire', () {
    // `GbException.message` is server English marked "not for display" on the
    // model itself. The type is the enforcement: there is nowhere on GbFailure
    // to put it, which is why this unit returns a kind rather than lines.
    final failure = describeGbFailure(api(status: 500));
    expect(failure.kind, GbFailureKind.generic);
    expect(
      failure.toString(),
      isNot(contains('server english')),
      reason: 'wire text leaked into the classified failure',
    );
  });
}
