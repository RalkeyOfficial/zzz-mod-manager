import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/l10n/app_localizations.dart';

/// Wraps a widget in a `MaterialApp` whose localizations are **already loaded**.
///
/// Needed because `AppLocalizations.delegate` reads its JSON from the asset bundle
/// asynchronously, and `pumpAndSettle` does *not* wait for real async I/O — it pumps
/// until no more frames are scheduled, which happens long before a bundle read
/// finishes. The result is a `Localizations` widget that renders an empty box
/// forever, with **no exception**: every `find` returns nothing and every
/// "did it overflow?" assertion passes vacuously.
///
/// So the load is done up front through [WidgetTester.runAsync] (the only place real
/// async work is allowed in a widget test) and handed back through a delegate that
/// returns a [SynchronousFuture]. The tree is then fully built on the first frame,
/// deterministically.
///
/// Always assert something is actually on screen after pumping — see
/// [expectBuilt] — so a future harness regression fails loudly instead of quietly
/// making tests meaningless.
/// [overrides] wraps the tree in a `ProviderScope`, for widgets that read Riverpod
/// providers — pass fakes so nothing reaches the network.
Future<void> pumpLocalized(
  WidgetTester tester,
  Widget child, {
  Locale locale = const Locale('en'),
  List<Override>? overrides,
  Size surfaceSize = const Size(1200, 800),
}) async {
  await tester.binding.setSurfaceSize(surfaceSize);
  addTearDown(() => tester.binding.setSurfaceSize(null));

  AppLocalizations? loaded;
  await tester.runAsync(() async {
    final localizations = AppLocalizations(locale);
    await localizations.load();
    loaded = localizations;
  });
  assert(loaded != null, 'localizations failed to load for $locale');

  final app = MaterialApp(
    locale: locale,
    localizationsDelegates: [_PreloadedLocalizations(loaded!)],
    supportedLocales: [locale],
    home: Scaffold(body: child),
  );

  await tester.pumpWidget(
    overrides == null ? app : ProviderScope(overrides: overrides, child: app),
  );
  // A rebuild loop shows up here as a pumpAndSettle timeout rather than as a
  // failed expectation, which is the point of settling instead of pumping once.
  await tester.pumpAndSettle();
}

/// Guards against a vacuous test: fails if the subtree under test never built.
void expectBuilt(Type widgetType) {
  expect(
    find.byType(widgetType),
    findsOneWidget,
    reason: '$widgetType did not build — assertions about it would be meaningless',
  );
}

class _PreloadedLocalizations extends LocalizationsDelegate<AppLocalizations> {
  const _PreloadedLocalizations(this._loaded);

  final AppLocalizations _loaded;

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<AppLocalizations> load(Locale locale) =>
      SynchronousFuture<AppLocalizations>(_loaded);

  @override
  bool shouldReload(_) => false;
}
