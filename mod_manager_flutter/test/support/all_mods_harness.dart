import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/core/type_scale.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/screens/all_mods/all_mods_view.dart';
import 'package:mod_manager_flutter/screens/components/library_actions_host.dart';
import 'package:mod_manager_flutter/services/origin_write.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

import 'library_override.dart';
import 'localized_harness.dart';

/// The All mods page with every callback a no-op unless given. Mount it under a `LibraryActionsHost`, which its
/// buttons reach, after [loadTableFonts].
AllModsView allModsViewForTest({
  OriginWriter? originWriter,
  void Function(ModInfo mod)? onShowUpdate,
  void Function(ModInfo mod)? onResolveOrigin,
}) =>
    AllModsView(
      onOpenPage: (_) {},
      onContextMenu: (_, _, _) {},
      onShowUpdate: onShowUpdate ?? (_) {},
      onResolveOrigin: onResolveOrigin ?? (_) {},
      originWriter: originWriter ?? (_, _) async => OriginWriteResult.writeFailed,
    );

bool _fontsLoaded = false;

/// Loads the app's UI and mono fonts, so the table's fixed-width cells are measured as the app draws them. The test
/// font draws every glyph a full em wide, which no column width is chosen for.
Future<void> loadTableFonts(WidgetTester tester) async {
  if (_fontsLoaded) return;
  await tester.runAsync(() async {
    final ui = FontLoader(kUiFont);
    for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      ui.addFont(rootBundle.load('assets/fonts/geist/Geist-$weight.ttf'));
    }
    final mono = FontLoader(kMonoFont);
    for (final weight in ['Regular', 'Medium', 'SemiBold']) {
      mono.addFont(rootBundle.load('assets/fonts/geist-mono/GeistMono-$weight.ttf'));
    }
    await Future.wait([ui.load(), mono.load()]);
  });
  _fontsLoaded = true;
}

/// Mounts the All mods page over [mods], held in memory, under a [LibraryActionsHost] whose fetchers throw, and
/// hands back its container. Pass a `TempLibrary`'s overrides in [overrides] for a test whose actions write.
Future<ProviderContainer> pumpAllModsTable(
  WidgetTester tester,
  List<ModInfo> mods, {
  List<Override> overrides = const [],
  Locale locale = const Locale('en'),
  Size surfaceSize = const Size(1400, 900),
}) async {
  final container = ProviderContainer(overrides: [libraryOf(mods), ...overrides]);
  addTearDown(container.dispose);

  await loadTableFonts(tester);
  await pumpLocalized(
    tester,
    LibraryActionsHost(
      updateFetcher: (_) async => throw StateError('no fetch expected'),
      updatesFetcher: (_) async => throw StateError('no fetch expected'),
      originWriter: (_, _) async => OriginWriteResult.writeFailed,
      child: allModsViewForTest(),
    ),
    locale: locale,
    container: container,
    surfaceSize: surfaceSize,
  );
  expectBuilt(AllModsView);
  return container;
}

/// A row's own box, by its English label.
Finder rowBox(String name) => find.byWidgetPredicate((w) => w is Checkbox && w.semanticLabel == 'Select $name');

/// A button on the selection bar.
Finder barButton(String label) => find.widgetWithText(OutlinedButton, label);

/// Ticks each of [names]' boxes in turn.
Future<void> tick(WidgetTester tester, List<String> names) async {
  for (final name in names) {
    await tester.tap(rowBox(name));
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

/// Presses [finder], which starts a bulk action that touches files, and waits in real time for it to end.
///
/// [tapWithIo] waits a fixed moment, which a run over several folders can outlast. An action that asks first holds
/// the flag while its dialog is open, so the bar's Delete is pressed with [tapWithIo] and the dialog's with this.
Future<void> pressBulk(WidgetTester tester, ProviderContainer container, Finder finder) async {
  await tester.runAsync(() async {
    await tester.tap(finder);
    for (var i = 0; i < 500 && container.read(allModsBulkRunningProvider); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  });
  expect(container.read(allModsBulkRunningProvider), isFalse, reason: 'the bulk action never finished');
  await tester.pumpAndSettle();
}
