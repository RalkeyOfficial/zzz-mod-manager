import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'plural_rules.dart';

class AppLocalizations {
  final Locale locale;
  late final Map<String, dynamic> _localizedValues;

  AppLocalizations(this.locale);

  static const LocalizationsDelegate<AppLocalizations> delegate = _AppLocalizationsDelegate();

  static AppLocalizations of(BuildContext context) {
    final AppLocalizations? result = Localizations.of<AppLocalizations>(context, AppLocalizations);
    assert(result != null, 'AppLocalizations has not been initialized.');
    return result!;
  }

  Future<void> load() async {
    final jsonString = await rootBundle.loadString('assets/l10n/${locale.languageCode}.json');
    final Map<String, dynamic> jsonMap = json.decode(jsonString) as Map<String, dynamic>;
    _localizedValues = jsonMap;
  }

  String t(String key, {Map<String, String>? params, String? fallback}) {
    final segments = key.split('.');
    dynamic current = _localizedValues;

    for (final segment in segments) {
      if (current is Map<String, dynamic> && current.containsKey(segment)) {
        current = current[segment];
      } else {
        return fallback ?? key;
      }
    }

    if (current is String) {
      var value = current;
      if (params != null) {
        params.forEach((placeholder, replacement) {
          value = value.replaceAll('{$placeholder}', replacement);
        });
      }
      return value;
    }

    return fallback ?? key;
  }

  /// A counted string, picking the wording [count] needs in this locale.
  ///
  /// Call this rather than appending `_single` / `_plural` at the call site.
  /// That choice is `count == 1` in English and a three-way rule in Ukrainian
  /// ([pluralSuffix]), and a call site that spells it out can only ever get one
  /// language right.
  ///
  /// **A missing `_few` falls back to `_plural`**, so a locale that has grown a
  /// third form but not yet the string for it reads exactly as it did before
  /// rather than rendering a raw dotted key — which is what `t` does with a key
  /// that isn't there, silently. `test/l10n_keys_test.dart` is what stops that
  /// fallback becoming permanent.
  String plural(String baseKey, int count, {Map<String, String>? params}) {
    final suffix = pluralSuffix(locale.languageCode, count);
    final key = '$baseKey$suffix';
    if (suffix != '_plural' && !_has(key)) {
      return t('${baseKey}_plural', params: params);
    }
    return t(key, params: params);
  }

  /// Whether [key] resolves to a string in this locale's bundle.
  bool _has(String key) {
    dynamic current = _localizedValues;
    for (final segment in key.split('.')) {
      if (current is! Map<String, dynamic> || !current.containsKey(segment)) {
        return false;
      }
      current = current[segment];
    }
    return current is String;
  }
}

class _AppLocalizationsDelegate extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) => const ['en', 'uk'].contains(locale.languageCode);

  @override
  Future<AppLocalizations> load(Locale locale) async {
    final localizations = AppLocalizations(locale);
    await localizations.load();
    return localizations;
  }

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

extension AppLocalizationsExtension on BuildContext {
  AppLocalizations get loc => AppLocalizations.of(this);
}
