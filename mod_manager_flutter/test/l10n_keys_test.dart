import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/l10n/plural_rules.dart';

/// Keeps the two locale files honest against the code.
///
/// Localization is the most repetitive cost in the marketplace/update plan, and it
/// fails *silently* in both directions: a key referenced in Dart but missing from a
/// JSON file renders as a raw dotted path in the UI, and a key left behind by deleted
/// UI is dead weight nobody notices. Neither shows up in `flutter analyze`, because
/// the keys are strings.
///
/// This replaces a throwaway script that was run by hand once. The check is worth
/// keeping because it already caught a real orphan — `marketplace.search`, stranded
/// when the search button became submit-on-enter.
void main() {
  /// `context.loc.t('a.b.c')` / `loc.t('a.b.c')`, single-quoted literals only.
  /// Interpolated keys (`'marketplace.sort_${sort.name}'`) are deliberately excluded
  /// and covered by [_interpolatedKeyPrefixes] instead.
  final callSite = RegExp(r"""\.t\(\s*'([^'$]+)'""");

  Map<String, String> flatten(Map<String, dynamic> json, [String prefix = '']) {
    final out = <String, String>{};
    json.forEach((key, value) {
      final path = prefix.isEmpty ? key : '$prefix.$key';
      if (value is Map<String, dynamic>) {
        out.addAll(flatten(value, path));
      } else {
        out[path] = '$value';
      }
    });
    return out;
  }

  Map<String, String> loadLocale(String code) {
    final file = File('assets/l10n/$code.json');
    expect(file.existsSync(), isTrue, reason: 'missing ${file.path}');
    return flatten(jsonDecode(file.readAsStringSync()) as Map<String, dynamic>);
  }

  Set<String> referencedKeys() {
    final keys = <String>{};
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      for (final match in callSite.allMatches(entity.readAsStringSync())) {
        keys.add(match.group(1)!);
      }
    }
    return keys;
  }

  /// Prefixes whose full keys are built by string interpolation, so the regex above
  /// cannot see them. Each entry is checked as "at least one key starts with this",
  /// which is weaker than an exact match but still catches a whole group going
  /// missing — e.g. renaming the `GbModSort` enum without renaming the keys.
  const interpolatedKeyPrefixes = <String>[
    'marketplace.sort_',
    // Chosen at runtime by a `_single` / `_plural` suffix on the count.
    'mods.assume_current.title_',
    'mods.assume_current.confirm_',
    'mods.assume_current.done_',
    'mods.bulk_resolve.apply_',
    'mods.bulk_resolve.done_',
    'mods.bulk_resolve.excluded_untracked_',
    'mods.bulk_resolve.already_known_',
    'mods.patch_install.destination_match_',
    'mods.update.bulk_found_',
    'mods.update.bulk_failed_',
    'mods.update.bulk_checked_',
    'mods.update.launch_checked_',
    'marketplace.content_filter_',
    'language_names.',
    // Chosen at runtime by a ternary *inside* `t(...)`, so the call-site regex
    // above sees `t(cond ? …` and matches nothing at all.
    'mods.snackbar.reload_success_',
    'mods.snackbar.reload_failure_',
    'mods.backups.restored_',
    'mods.backups.restore_failed_',
    'marketplace.install_success_title_',
  ];

  late Map<String, String> en;
  late Map<String, String> uk;
  late Set<String> referenced;

  setUpAll(() {
    en = loadLocale('en');
    uk = loadLocale('uk');
    referenced = referencedKeys();
  });

  test('the regex actually found call sites', () {
    // Guards the test itself: a refactor that changed how strings are looked up
    // would otherwise make every assertion below vacuously pass.
    expect(referenced.length, greaterThan(200));
  });

  test('every key referenced in lib/ exists in en.json', () {
    final missing = referenced.where((k) => !en.containsKey(k)).toList()..sort();
    expect(missing, isEmpty, reason: 'referenced in code, absent from en.json');
  });

  test('every key referenced in lib/ exists in uk.json', () {
    final missing = referenced.where((k) => !uk.containsKey(k)).toList()..sort();
    expect(missing, isEmpty, reason: 'referenced in code, absent from uk.json');
  });

  test('en and uk carry exactly the same keys', () {
    // A translated string that only exists in one locale is a UI that falls back to
    // a dotted path for half the users.
    //
    // `_few` is the one exception and it is a real asymmetry, not an oversight:
    // English has two plural forms and Ukrainian three, so the middle form
    // exists only where a locale's grammar has one. It is checked on its own
    // terms below.
    Set<String> comparable(Map<String, String> m) =>
        m.keys.where((k) => !k.endsWith('_few')).toSet();

    expect((comparable(en).difference(comparable(uk))).toList()..sort(), isEmpty,
        reason: 'in en.json only');
    expect((comparable(uk).difference(comparable(en))).toList()..sort(), isEmpty,
        reason: 'in uk.json only');
  });

  test('_few exists only where the locale has three plural forms', () {
    // English would render an identical second copy of `_plural`, free to drift
    // from it and never selected by `pluralSuffix`.
    for (final entry in {'en': en, 'uk': uk}.entries) {
      final few = entry.value.keys.where((k) => k.endsWith('_few'));
      if (pluralFewLocales.contains(entry.key)) continue;
      expect(few, isEmpty,
          reason: '${entry.key}.json has _few keys but two plural forms');
    }
  });

  test('a three-form locale interpolates the count in its _single strings too',
      () {
    // The trap this exists for, and it is invisible in English. There,
    // `_single` is reached at exactly 1, so hardcoding "1 mod" is correct. In
    // Ukrainian the same form is reached at **1, 21, 31, 101** — every count
    // ending in 1 but not 11 — so a hardcoded "1" silently reports the wrong
    // number, and a demonstrative ("this mod") drops the count entirely.
    //
    // The rule is therefore conditional on the _plural sibling: if the plural
    // wording names a count, the singular has to as well.
    for (final entry in {'en': en, 'uk': uk}.entries) {
      if (!pluralFewLocales.contains(entry.key)) continue;
      for (final key in entry.value.keys.where((k) => k.endsWith('_single'))) {
        final plural =
            entry.value['${key.substring(0, key.length - '_single'.length)}_plural'];
        if (plural == null || !plural.contains('{count}')) continue;
        expect(entry.value[key], contains('{count}'),
            reason: '${entry.key}.json $key is reached at 21, 31 and 101 too, '
                'so it cannot hardcode the number');
      }
    }
  });

  test('every _few key has the pair it is the middle of', () {
    // `_few` is optional — `AppLocalizations.plural` falls back to `_plural`
    // where a string's grammar doesn't change at 2–4, which is common (Ukrainian
    // often phrases the count as "модів: 3", which no numeral affects). What is
    // not allowed is a `_few` with no pair, which would be a string nothing can
    // reach at any other count.
    for (final entry in {'en': en, 'uk': uk}.entries) {
      for (final key in entry.value.keys.where((k) => k.endsWith('_few'))) {
        final base = key.substring(0, key.length - '_few'.length);
        expect(entry.value.containsKey('${base}_single'), isTrue,
            reason: '${entry.key}.json has $key but no ${base}_single');
        expect(entry.value.containsKey('${base}_plural'), isTrue,
            reason: '${entry.key}.json has $key but no ${base}_plural');
      }
    }
  });

  test('interpolated key groups are still populated', () {
    for (final prefix in interpolatedKeyPrefixes) {
      expect(en.keys.any((k) => k.startsWith(prefix)), isTrue,
          reason: 'no en.json keys under "$prefix"');
      expect(uk.keys.any((k) => k.startsWith(prefix)), isTrue,
          reason: 'no uk.json keys under "$prefix"');
    }
  });

  test('every _single key has a _plural sibling, and the reverse', () {
    // The count-dependent keys are assembled at runtime, so the call-site regex
    // above cannot see them and a half-added pair would fail only when a user
    // happened to have exactly one mod. This is the check that covers them.
    for (final entry in {'en': en, 'uk': uk}.entries) {
      for (final key in entry.value.keys) {
        for (final (have, want) in [('_single', '_plural'), ('_plural', '_single')]) {
          if (!key.endsWith(have)) continue;
          final sibling =
              '${key.substring(0, key.length - have.length)}$want';
          expect(entry.value.containsKey(sibling), isTrue,
              reason: '${entry.key}.json has $key but not $sibling');
        }
      }
    }
  });

  test('every _body key has a _title sibling', () {
    // A notification is a headline and a subject, and both are required at the
    // API — so a `_body` with no `_title` is a pair that was half-added, and it
    // would surface as a card whose headline is a raw dotted path.
    //
    // One direction only. The reverse would false-positive on every legitimate
    // non-notification `*_title` (`welcome.title`, `marketplace.download_title`,
    // `mods.bulk_resolve.section_identity`), and would need an allowlist that
    // rots. A `_title` whose `_body` was never added is already caught twice
    // over: `body` is required at the call site, and the "referenced in lib/"
    // check above catches the missing key.
    for (final entry in {'en': en, 'uk': uk}.entries) {
      for (final key in entry.value.keys) {
        if (!key.endsWith('_body')) continue;
        // A prefix match rather than an exact one, because a headline that
        // carries a count is itself a `_single`/`_plural` pair.
        final base = '${key.substring(0, key.length - '_body'.length)}_title';
        expect(entry.value.keys.any((k) => k.startsWith(base)), isTrue,
            reason: '${entry.key}.json has $key but no $base');
      }
    }
  });

  test('no placeholder or empty translations', () {
    for (final entry in {...en, ...uk}.entries) {
      expect(entry.value.trim(), isNotEmpty, reason: 'empty value for ${entry.key}');
    }
  });
}
