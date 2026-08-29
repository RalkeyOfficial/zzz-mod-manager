import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/l10n/app_localizations.dart';
import 'package:mod_manager_flutter/screens/components/notification_overlay.dart';

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
/// The tree is **always** wrapped in a `ProviderScope`, whether or not
/// [overrides] are given. It used to be conditional, which turned any widget
/// that gained a `ref` into a `Bad state: No ProviderScope found` in every test
/// that had no reason to pass overrides — a failure about the harness, not
/// about the widget. Pass [overrides] to substitute fakes so nothing reaches
/// the network.
/// Pass [container] instead of [overrides] when the test needs to read provider
/// state back afterwards. It becomes the **root** scope rather than one nested
/// inside the widget under test — which is not a detail: notifications are
/// rendered by a host mounted above `home`, so a container nested below it is a
/// second, invisible stack. A widget raising `context.notify` inside one would
/// write to a queue nothing is watching, and the test would assert against an
/// empty screen.
Future<void> pumpLocalized(
  WidgetTester tester,
  Widget child, {
  Locale locale = const Locale('en'),
  List<Override>? overrides,
  ProviderContainer? container,
  Size surfaceSize = const Size(1200, 800),

  /// Pass false for a tree that contains an **indeterminate** progress
  /// indicator. Those animate forever, so `pumpAndSettle` never returns and the
  /// test fails as a timeout that says nothing about the widget. A single pump
  /// still builds everything; what it gives up is the rebuild-loop check below,
  /// which is why it is opt-in rather than the default.
  bool settle = true,
}) async {
  assert(
    container == null || overrides == null,
    'a container brings its own overrides; passing both silently drops these',
  );
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
    // Exactly how `main.dart` mounts it, so a test that triggers a notification
    // renders one — `find.text` over a message is then the same assertion in a
    // test as it is on screen. Without it every `context.notify` call in a
    // widget under test would land in the provider and show nothing.
    builder: (context, child) => NotificationHost(child: child!),
    home: Scaffold(body: child),
  );

  await tester.pumpWidget(
    container != null
        ? UncontrolledProviderScope(container: container, child: app)
        : ProviderScope(overrides: overrides ?? const [], child: app),
  );
  // A rebuild loop shows up here as a pumpAndSettle timeout rather than as a
  // failed expectation, which is the point of settling instead of pumping once.
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
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
