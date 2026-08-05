/// How long ago something happened, as a count plus a unit.
///
/// Pure and locale-free on purpose: it returns *what* to say, never the words.
/// The caller turns a [RelativeAge] into text through the l10n table, so the
/// thresholds can be unit-tested without a `BuildContext` and the wording can be
/// translated without touching the arithmetic.
library;

/// The coarsest unit that still reads sensibly for a given distance in time.
enum RelativeUnit {
  /// Under a minute — rendered as a phrase, with no count.
  justNow,
  minutes,
  hours,
  days,
  weeks,
  months,
  years;

  /// Suffix of the l10n key (`time.<key>`).
  String get l10nKey => name;
}

/// A count and its unit. [count] is 0 only for [RelativeUnit.justNow].
typedef RelativeAge = ({int count, RelativeUnit unit});

/// Days per month/year used for the coarse buckets.
///
/// Deliberately approximate. "5 months ago" is a *rough* statement, and doing
/// real calendar arithmetic here would add month-length and leap-year handling to
/// buy precision nobody reads off a mod card.
const int _daysPerMonth = 30;
const int _daysPerYear = 365;

/// Bucketises the distance from [instant] to [now].
///
/// Boundaries are inclusive at the lower end: exactly 60 seconds is `1 minute`,
/// exactly 7 days is `1 week`. Written out because off-by-one at a boundary is the
/// classic bug here and the tests pin every one of them.
///
/// **A future [instant] collapses to [RelativeUnit.justNow]** rather than
/// producing a negative count. That is not paranoia: these timestamps come from
/// someone else's server, so a few seconds of skew is routine, and "in -3 days"
/// is worse than "just now".
RelativeAge relativeAge(DateTime instant, {required DateTime now}) {
  final delta = now.difference(instant);
  if (delta.isNegative || delta.inSeconds < 60) {
    return (count: 0, unit: RelativeUnit.justNow);
  }
  if (delta.inMinutes < 60) {
    return (count: delta.inMinutes, unit: RelativeUnit.minutes);
  }
  if (delta.inHours < 24) {
    return (count: delta.inHours, unit: RelativeUnit.hours);
  }

  final days = delta.inDays;
  if (days < 7) return (count: days, unit: RelativeUnit.days);
  if (days < _daysPerMonth) {
    return (count: days ~/ 7, unit: RelativeUnit.weeks);
  }

  final months = days ~/ _daysPerMonth;
  if (months < 12) return (count: months, unit: RelativeUnit.months);

  // Guarded with a floor of 1: at 364 days the month bucket already reads 12,
  // which must become "1y" rather than "0y" even though 364 / 365 truncates to
  // zero. Without this the card would claim a year-old mod is "0y" old.
  final years = days ~/ _daysPerYear;
  return (count: years < 1 ? 1 : years, unit: RelativeUnit.years);
}
