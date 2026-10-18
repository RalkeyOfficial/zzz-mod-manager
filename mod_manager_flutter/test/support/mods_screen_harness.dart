import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/screens/components/library_actions_host.dart';
import 'package:mod_manager_flutter/screens/mods_screen.dart';
import 'package:mod_manager_flutter/services/origin_write.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

import 'library_override.dart';
import 'localized_harness.dart';
import 'temp_library.dart';

/// Mounts the Library page the way `main.dart` does, under a [LibraryActionsHost], and hands back its container.
///
/// [selected] is the character list's row, set as the app would before any click: [characterPickedByUserProvider]
/// stays false. The tracking reminder is dismissed unless [showTrackingNudge].
///
/// The list on screen is [mods], held in memory ([libraryOf]); a rescan leaves it as it is. [temp] is where every
/// write lands: `ApiService` points at it, so a toggle, a favourite or a note reaches a real folder and a real
/// `config.json` that are not the developer's. The backups listing is empty rather than read from `<appData>`.
///
/// Nothing reaches the network: both update fetchers throw if called.
Future<ProviderContainer> pumpModsScreen(
  WidgetTester tester,
  TempLibrary temp,
  List<ModInfo> mods, {
  String? selected,
  Size surfaceSize = const Size(1200, 800),
  bool showTrackingNudge = false,
}) async {
  final container = ProviderContainer(
    overrides: [
      libraryOf(mods),
      ...temp.overrides,
      modBackupsProvider.overrideWith((ref) async => <String>{}),
    ],
  );
  addTearDown(container.dispose);
  container.read(selectedCharacterIdProvider.notifier).state = selected;
  // Out of the way unless asked for: most tests here are about the grid and the panel.
  container.read(trackingNudgeDismissedProvider.notifier).state = !showTrackingNudge;

  await pumpLocalized(
    tester,
    LibraryActionsHost(
      updateFetcher: (_) async => throw StateError('no fetch expected'),
      updatesFetcher: (_) async => throw StateError('no fetch expected'),
      originWriter: (_, _) async => OriginWriteResult.writeFailed,
      child: const ModsScreen(),
    ),
    container: container,
    surfaceSize: surfaceSize,
  );
  expectBuilt(ModsScreen);
  return container;
}

/// The character page's one scroll view, which holds the header, the filter row and the grid.
Finder pageScrollable() =>
    find.descendant(of: find.byType(CustomScrollView), matching: find.byType(Scrollable)).first;

/// The character page's scroll position.
ScrollPosition pagePosition(WidgetTester tester) => tester.state<ScrollableState>(pageScrollable()).position;

/// The card of the mod with folder id [id], as the grid keys it.
Finder cardOf(String id) => find.byKey(ValueKey('mod_$id'));
