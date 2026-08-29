/// Which wording a count needs, per locale.
///
/// Counted strings are a `_single` / `_plural` key pair chosen in Dart. That is
/// correct for English, and **wrong for Ukrainian at 2–4**: the language has
/// three forms, so "2 модів" reads as "2 of-mods" where it should be "2 моди".
/// The bug is not in any one string — it is in the code that picks between two
/// keys when the locale needs three.
///
/// So the choice moves here, keyed on the locale rather than on `count == 1`,
/// and the suffixes stay the ones already in the JSON files (`_single` /
/// `_plural`) with `_few` added for the middle form. Renaming all three to
/// CLDR's `one` / `few` / `many` would be tidier and would rewrite 27 key pairs
/// across two files for no behavioural gain.
///
/// Pure and Flutter-free so the arithmetic — which is where this kind of rule
/// goes wrong, at 11–14 and again at 111–114 — can be tested directly.
library;

/// The key suffix for [count] in [languageCode].
///
/// Returns `_single`, `_few` or `_plural`. Any locale without an explicit rule
/// gets English's two-form behaviour, which is the right default: it is what a
/// new locale's JSON will have been written against.
String pluralSuffix(String languageCode, int count) {
  // Defensive rather than expected — every count here is a length or a tally —
  // but the modulo arithmetic below is meaningless on a negative.
  final n = count.abs();

  return switch (languageCode) {
    // Ukrainian, per CLDR. The `% 100` guards are the whole difference between
    // this and a naive `% 10` rule: 11–14 take the *many* form even though 11
    // ends in 1 and 12–14 end in 2–4, and the same holds at 111–114.
    'uk' => switch ((n % 10, n % 100)) {
        (1, != 11) => '_single',
        (>= 2 && <= 4, final h) when h < 12 || h > 14 => '_few',
        _ => '_plural',
      },
    _ => n == 1 ? '_single' : '_plural',
  };
}

/// Locales whose plural rules use the middle `_few` form.
///
/// The l10n key test reads this: a `_few` key is **required** in these locales
/// and must **not** exist in the others, where it would be a second string
/// saying the same thing as `_plural` and free to drift from it.
const Set<String> pluralFewLocales = {'uk'};
