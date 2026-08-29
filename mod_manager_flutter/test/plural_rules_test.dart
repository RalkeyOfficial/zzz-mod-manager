import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/l10n/plural_rules.dart';

/// The count → wording rule, per locale.
///
/// Ukrainian is the reason this exists and it is also where the arithmetic goes
/// wrong: the teens are the exception that a `% 10` rule alone gets backwards,
/// and they come back at 111–114. Every one of those is pinned below.
void main() {
  group('English', () {
    test('one is singular, everything else is not', () {
      expect(pluralSuffix('en', 1), '_single');
      for (final n in [0, 2, 3, 5, 11, 21, 100]) {
        expect(pluralSuffix('en', n), '_plural', reason: 'at $n');
      }
    });
  });

  group('Ukrainian', () {
    // The three forms, spelled out with the noun that produced the bug report:
    //   _single  1 мод
    //   _few     2 моди
    //   _plural  5 модів
    void expectSuffix(String suffix, List<int> counts) {
      for (final n in counts) {
        expect(pluralSuffix('uk', n), suffix, reason: 'at $n');
      }
    }

    test('ends in 1', () {
      expectSuffix('_single', [1, 21, 31, 41, 101, 121, 1001]);
    });

    test('ends in 2, 3 or 4', () {
      expectSuffix('_few', [2, 3, 4, 22, 23, 24, 102, 104, 1002]);
    });

    test('everything else, including zero', () {
      expectSuffix('_plural', [0, 5, 6, 9, 10, 20, 25, 30, 100, 1000]);
    });

    test('the teens are the exception, and they repeat every hundred', () {
      // 11 ends in 1 but is not singular; 12–14 end in 2–4 but are not few.
      // This is the half a naive `% 10` rule gets wrong, and it is wrong again
      // at 111–114 — which is why the rule tests `% 100` rather than the teens
      // literally.
      expectSuffix('_plural', [11, 12, 13, 14, 111, 112, 113, 114]);
    });
  });

  group('an unknown locale', () {
    test('falls back to English two-form behaviour', () {
      // The right default: a new locale's JSON is written with `_single` and
      // `_plural` and nothing else, so asking it for `_few` would render a raw
      // dotted key.
      expect(pluralSuffix('de', 1), '_single');
      expect(pluralSuffix('de', 3), '_plural');
      expect(pluralSuffix('', 3), '_plural');
    });

    test('is not in the few-form set', () {
      expect(pluralFewLocales, contains('uk'));
      expect(pluralFewLocales, isNot(contains('en')));
    });
  });

  test('a negative count does not fall through the modulo rules', () {
    // No caller passes one — these are lengths and tallies — but the arithmetic
    // is meaningless on a negative and `-1 % 10` is not `1` in every language.
    expect(pluralSuffix('uk', -1), '_single');
    expect(pluralSuffix('uk', -3), '_few');
    expect(pluralSuffix('en', -1), '_single');
  });
}
