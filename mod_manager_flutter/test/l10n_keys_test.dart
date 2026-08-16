import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

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
    'mods.update.bulk_found_',
    'marketplace.content_filter_',
    'language_names.',
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
    expect((en.keys.toSet().difference(uk.keys.toSet())).toList()..sort(), isEmpty,
        reason: 'in en.json only');
    expect((uk.keys.toSet().difference(en.keys.toSet())).toList()..sort(), isEmpty,
        reason: 'in uk.json only');
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

  test('no placeholder or empty translations', () {
    for (final entry in {...en, ...uk}.entries) {
      expect(entry.value.trim(), isNotEmpty, reason: 'empty value for ${entry.key}');
    }
  });
}
