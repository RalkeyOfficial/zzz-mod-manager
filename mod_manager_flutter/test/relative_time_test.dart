import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/utils/relative_time.dart';

/// Bucket boundaries for the card's "released / updated N ago" labels.
///
/// Almost every bug in this kind of function is an off-by-one at a threshold or a
/// truncation that reports zero, so each boundary is pinned from both sides.
void main() {
  final now = DateTime.utc(2026, 8, 5, 12, 0, 0);
  RelativeAge ageAfter(Duration ago) => relativeAge(now.subtract(ago), now: now);

  group('sub-minute', () {
    test('now is "just now" with no count', () {
      expect(ageAfter(Duration.zero),
          (count: 0, unit: RelativeUnit.justNow));
    });

    test('59 seconds is still just now', () {
      expect(ageAfter(const Duration(seconds: 59)).unit, RelativeUnit.justNow);
    });
  });

  group('boundaries, from both sides', () {
    test('60s becomes 1 minute', () {
      expect(ageAfter(const Duration(seconds: 60)),
          (count: 1, unit: RelativeUnit.minutes));
    });

    test('59 minutes stays minutes, 60 becomes 1 hour', () {
      expect(ageAfter(const Duration(minutes: 59)),
          (count: 59, unit: RelativeUnit.minutes));
      expect(ageAfter(const Duration(minutes: 60)),
          (count: 1, unit: RelativeUnit.hours));
    });

    test('23 hours stays hours, 24 becomes 1 day', () {
      expect(ageAfter(const Duration(hours: 23)),
          (count: 23, unit: RelativeUnit.hours));
      expect(ageAfter(const Duration(hours: 24)),
          (count: 1, unit: RelativeUnit.days));
    });

    test('6 days stays days, 7 becomes 1 week', () {
      expect(ageAfter(const Duration(days: 6)),
          (count: 6, unit: RelativeUnit.days));
      expect(ageAfter(const Duration(days: 7)),
          (count: 1, unit: RelativeUnit.weeks));
    });

    test('29 days is 4 weeks, 30 becomes 1 month', () {
      expect(ageAfter(const Duration(days: 29)),
          (count: 4, unit: RelativeUnit.weeks));
      expect(ageAfter(const Duration(days: 30)),
          (count: 1, unit: RelativeUnit.months));
    });

    test('the month bucket never reports 12 or more', () {
      // 364 days floors to 12 months arithmetically; it must roll over to a year
      // instead, and must not truncate to "0y".
      final almostAYear = ageAfter(const Duration(days: 364));
      expect(almostAYear.unit, RelativeUnit.years);
      expect(almostAYear.count, 1);
    });

    test('a year and beyond', () {
      expect(ageAfter(const Duration(days: 365)),
          (count: 1, unit: RelativeUnit.years));
      expect(ageAfter(const Duration(days: 729)),
          (count: 1, unit: RelativeUnit.years));
      expect(ageAfter(const Duration(days: 730)),
          (count: 2, unit: RelativeUnit.years));
    });
  });

  group('a future timestamp', () {
    test('collapses to just now rather than going negative', () {
      // These timestamps come from someone else's server; a little clock skew is
      // routine and "in -3 days" would be worse than "just now".
      expect(relativeAge(now.add(const Duration(seconds: 30)), now: now).unit,
          RelativeUnit.justNow);
      expect(relativeAge(now.add(const Duration(days: 400)), now: now),
          (count: 0, unit: RelativeUnit.justNow));
    });
  });

  group('never reports a zero count for a real unit', () {
    test('across a wide sweep of ages', () {
      // A zero count with a unit ("0d ago") is the visible symptom of a bad
      // truncation, so assert it can't happen at any age up to five years.
      for (var days = 0; days <= 365 * 5; days += 7) {
        final age = relativeAge(now.subtract(Duration(days: days)), now: now);
        if (age.unit == RelativeUnit.justNow) {
          expect(age.count, 0);
        } else {
          expect(age.count, greaterThan(0),
              reason: '$days days -> ${age.count} ${age.unit.name}');
        }
      }
    });
  });

  test('every unit has a distinct l10n key', () {
    final keys = RelativeUnit.values.map((u) => u.l10nKey).toSet();
    expect(keys.length, RelativeUnit.values.length);
  });

  group('against real captured timestamps', () {
    test('a mod added in 2024 and updated in 2026 reads years vs days', () {
      // Mirrors the first record of the captured Mod/Index page: added
      // 2024-07-14, updated 2026-08-01. The gap is the whole point of showing
      // both dates.
      final added = DateTime.utc(2024, 7, 14);
      final updated = DateTime.utc(2026, 8, 1);
      expect(relativeAge(added, now: now).unit, RelativeUnit.years);
      expect(relativeAge(added, now: now).count, 2);
      expect(relativeAge(updated, now: now).unit, RelativeUnit.days);
    });
  });
}
