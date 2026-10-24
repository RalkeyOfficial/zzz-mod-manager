import '../l10n/app_localizations.dart';
import 'relative_time.dart';

/// How long ago [instant] was, in words: "3 days ago", "1 week ago", "just now". [relativeAge] picks the unit.
String relativeAgeLabel(AppLocalizations loc, DateTime instant, DateTime now) {
  final age = relativeAge(instant, now: now);
  final params = {'count': '${age.count}'};
  return switch (age.unit) {
    RelativeUnit.justNow => loc.t('time.just_now'),
    RelativeUnit.minutes => loc.plural('time.minutes_ago', age.count, params: params),
    RelativeUnit.hours => loc.plural('time.hours_ago', age.count, params: params),
    RelativeUnit.days => loc.plural('time.days_ago', age.count, params: params),
    RelativeUnit.weeks => loc.plural('time.weeks_ago', age.count, params: params),
    RelativeUnit.months => loc.plural('time.months_ago', age.count, params: params),
    RelativeUnit.years => loc.plural('time.years_ago', age.count, params: params),
  };
}
