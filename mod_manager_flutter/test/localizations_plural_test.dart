import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/l10n/app_localizations.dart';

/// `AppLocalizations.plural` against the **real** JSON bundles.
///
/// `plural_rules_test.dart` pins the arithmetic; this pins that the suffix it
/// returns actually reaches a string, which is the half that fails silently —
/// `t` renders a missing key as its own dotted path, with no exception.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppLocalizations en;
  late AppLocalizations uk;

  setUpAll(() async {
    en = AppLocalizations(const Locale('en'));
    await en.load();
    uk = AppLocalizations(const Locale('uk'));
    await uk.load();
  });

  /// A rendered string that still contains a dot-and-underscore key shape never
  /// reached a translation.
  void expectResolved(String value, String base) {
    expect(value, isNot(startsWith(base)),
        reason: '"$value" is the raw key — nothing was found for it');
    expect(value, isNotEmpty);
  }

  test('English picks singular at one and plural everywhere else', () {
    expect(en.plural('mods.update.bulk_found', 1, params: {'count': '1'}),
        '1 mod has an update');
    expect(en.plural('mods.update.bulk_found', 3, params: {'count': '3'}),
        '3 mods have updates');
    expect(en.plural('mods.update.bulk_found', 0, params: {'count': '0'}),
        '0 mods have updates');
  });

  test('Ukrainian uses the middle form at 2–4', () {
    // The bug this whole change exists for: "2 модів" is the genitive plural
    // and reads as "2 of-mods". At 2–4 the noun takes its nominative plural.
    expect(uk.plural('mods.update.bulk_found', 2, params: {'count': '2'}),
        '2 моди мають оновлення');
    expect(uk.plural('mods.update.bulk_found', 5, params: {'count': '5'}),
        '5 модів мають оновлення');
    expect(uk.plural('mods.update.bulk_found', 1, params: {'count': '1'}),
        '1 мод має оновлення');
  });

  test('Ukrainian gets the teens right, where a %10 rule would not', () {
    // 12 ends in 2 but is not the middle form; 22 is.
    expect(uk.plural('mods.update.bulk_found', 12, params: {'count': '12'}),
        '12 модів мають оновлення');
    expect(uk.plural('mods.update.bulk_found', 22, params: {'count': '22'}),
        '22 моди мають оновлення');
    expect(uk.plural('mods.update.bulk_found', 21, params: {'count': '21'}),
        '21 мод має оновлення');
  });

  test('a string with no _few falls back to _plural rather than a raw key', () {
    // Most Ukrainian strings phrase the count as "модів: 3", which no numeral
    // affects, so they have no `_few` — and must still render.
    for (final n in [1, 2, 3, 5, 12, 22]) {
      final value =
          uk.plural('mods.update.bulk_checked', n, params: {'count': '$n'});
      expectResolved(value, 'mods.update.bulk_checked');
    }
    // Same count in both, so only the *key* chosen can differ: without a `_few`
    // the middle form must resolve to the very same wording as `_plural`.
    expect(uk.plural('mods.update.bulk_checked', 3, params: {'count': 'N'}),
        uk.plural('mods.update.bulk_checked', 5, params: {'count': 'N'}),
        reason: 'without a _few, 3 and 5 must reach the same string');
  });

  test('every pluralised key resolves in both locales at every form', () {
    // The sweep that would have caught a half-added `_few`, and that catches a
    // `_single` or `_plural` going missing from one locale.
    const bases = [
      'downloads.notification_title',
      'marketplace.install_success_title',
      'mods.assume_current.confirm',
      'mods.assume_current.done',
      'mods.assume_current.title',
      'mods.bulk_resolve.apply',
      'mods.bulk_resolve.done_title',
      'mods.import.success',
      'mods.update.bulk_checked',
      'mods.update.bulk_failed',
      'mods.update.bulk_found',
      'mods.update.launch_checked',
      'mods.update_apply.keybinds_heading',
      'mods.update_apply.remove_stale',
      'settings.auto_tag.tag',
    ];
    for (final loc in [en, uk]) {
      for (final base in bases) {
        for (final n in [0, 1, 2, 5, 11, 21, 22]) {
          expectResolved(loc.plural(base, n, params: {'count': '$n'}), base);
        }
      }
    }
  });
}
