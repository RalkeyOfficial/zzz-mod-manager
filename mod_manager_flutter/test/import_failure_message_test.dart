import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/l10n/app_localizations.dart';
import 'package:mod_manager_flutter/screens/components/import_failure_message.dart';
import 'package:mod_manager_flutter/services/import_result.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

/// What an import failure tells the user.
///
/// Each reason has to be distinguishable from the others and from a duplicate:
/// "these mods are already in your library" is certainly wrong for every one of
/// them, and it sends the user looking for a mod that was never installed.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppLocalizations en;

  setUpAll(() async {
    en = AppLocalizations(const Locale('en'));
    await en.load();
  });

  test('too little space names both figures', () {
    final lines = importFailureMessage(
      en,
      ImportFailure.notEnoughSpace,
      requiredBytes: 2254857830,
      availableBytes: 734003200,
    );

    expect(lines.body, contains('2.1 GB'));
    expect(lines.body, contains('700 MB'));
    expect(lines.body, contains('Nothing was installed'),
        reason: 'the library is untouched, and the user has to know that');
  });

  test('too little space with no figures falls back rather than saying null',
      () {
    final lines = importFailureMessage(en, ImportFailure.notEnoughSpace);

    expect(lines.body, isNot(contains('null')));
    expect(lines.title, isNot(contains('{')));
  });

  test('an unset library points at Settings, not at the disk', () {
    final lines = importFailureMessage(en, ImportFailure.libraryNotConfigured);

    expect(lines.body.toLowerCase(), contains('settings'));
  });

  test('an unset library offers Open Settings, which opens it', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final lines = importFailureMessage(en, ImportFailure.libraryNotConfigured, container: container);

    expect(lines.actions.map((a) => a.label), ['Open Settings']);
    lines.actions.single.onPressed();
    expect(container.read(destinationProvider), AppDestination.settings);
    expect(importFailureMessage(en, ImportFailure.copyFailed, container: container).actions, isEmpty,
        reason: 'only the setting is fixed in Settings');
  });

  test('no two reasons share a message', () {
    // Routing them through one string is what hid every actionable case, and it
    // looks correct at every call site.
    final titles = {
      for (final failure in ImportFailure.values)
        importFailureMessage(en, failure,
                requiredBytes: 10, availableBytes: 1)
            .title,
    };

    expect(titles, hasLength(ImportFailure.values.length));
  });

  test('every key it can reach resolves in both locales', () async {
    // `t` renders a missing key as its own dotted path, with no exception.
    final uk = AppLocalizations(const Locale('uk'));
    await uk.load();

    for (final loc in [en, uk]) {
      for (final failure in ImportFailure.values) {
        for (final withFigures in [true, false]) {
          final lines = importFailureMessage(
            loc,
            failure,
            requiredBytes: withFigures ? 10 : null,
            availableBytes: withFigures ? 1 : null,
          );
          expect(lines.title, isNot(startsWith('mods.')), reason: '$failure');
          expect(lines.body, isNot(startsWith('mods.')), reason: '$failure');
          expect(lines.body, isNot(contains('{')), reason: '$failure');
        }
      }
    }
  });
}
