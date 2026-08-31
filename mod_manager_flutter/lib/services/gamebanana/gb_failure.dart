/// What a failed GameBanana request means to the person looking at the screen.
///
/// The client raises four kinds of failure and the two browser screens used to
/// render two: offline, and "something went wrong". That collapse costs the user
/// the two answers that change what they do next — a back-off is worth waiting
/// out, and a mod that no longer exists is worth giving up on.
///
/// Pure and Flutter-free, modelled on `file_selection.dart`: the decision is
/// unit-testable against real exception instances, and the widget only renders
/// the outcome. **No l10n keys live here.** Nothing under `services/` holds user
/// text; the widget switches on [GbFailureKind], and because that switch is
/// exhaustive a fifth kind is a compile error at the one place that has to
/// answer for it.
library;

import '../../models/gamebanana/gb_exceptions.dart';

/// The answers worth telling apart.
enum GbFailureKind {
  /// No usable HTTP response at all — no connectivity, DNS, TLS, or a timeout.
  /// By far the most common failure, and not a bug.
  offline,

  /// The server asked us to slow down and the client's own retries are spent.
  /// Temporary by definition, which is the part the user needs told.
  rateLimited,

  /// The record is not there. Distinct from every other failure because it is
  /// the only one that will still be true in an hour.
  notFound,

  /// The server said `200` and sent nothing, and the client's retries are
  /// spent. Its own kind rather than [generic] because "we couldn't read what
  /// GameBanana sent" is untrue when nothing was sent, and because this one
  /// genuinely does clear up — see [GbEmptyResponseException].
  emptyResponse,

  /// Everything else: a malformed body, an error envelope we have no specific
  /// answer for, a bug of ours.
  generic,
}

/// The classified failure. Deliberately carries no message — see the library
/// note on [GbException] for why nothing from the wire may reach the screen.
class GbFailure {
  const GbFailure(this.kind);

  final GbFailureKind kind;

  /// Whether offering the user a retry is honest.
  ///
  /// Withheld on [GbFailureKind.notFound] and nowhere else. The other three can
  /// all come good on the next press; a removed mod cannot, and a button whose
  /// every press is guaranteed to fail is worse than no button — it invites the
  /// user to keep trying rather than telling them to stop.
  bool get canRetry => kind != GbFailureKind.notFound;
}

/// Classifies anything thrown by the GameBanana layer.
///
/// Takes `Object` rather than `GbException` because that is what an
/// `AsyncValue.error` hands over: a bug of ours arrives here as readily as a
/// typed failure, and it has to land somewhere honest rather than throw again
/// while rendering an error.
GbFailure describeGbFailure(Object error) {
  return GbFailure(switch (error) {
    GbNetworkException() => GbFailureKind.offline,
    GbRateLimitException() => GbFailureKind.rateLimited,
    GbEmptyResponseException() => GbFailureKind.emptyResponse,
    // `isNotFound` rather than a status comparison here: which of the API's
    // several 404 shapes arrived is the exception's business, not ours.
    GbApiException(isNotFound: true) => GbFailureKind.notFound,
    _ => GbFailureKind.generic,
  });
}
