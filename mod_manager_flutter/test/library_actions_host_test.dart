import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_file.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_mod.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_update.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/screens/components/library_actions_host.dart';
import 'package:mod_manager_flutter/screens/components/mods_toolbar.dart';
import 'package:mod_manager_flutter/screens/components/tracking_nudge.dart';
import 'package:mod_manager_flutter/services/origin_write.dart';
import 'package:mod_manager_flutter/services/update_check.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

import 'support/library_override.dart';
import 'support/localized_harness.dart';
import 'support/origin_shorthand.dart';

/// The whole-library check runs in [LibraryActionsHost], above the pages, so it outlives the toolbar it was started
/// from, and one pass runs at a time.
void main() {
  late ProviderContainer container;
  late ValueNotifier<bool> toolbarShown;
  late Completer<List<GbMod>> response;
  late int fetches;

  final library = [
    // File 99 is not among what mod 1 offers, so the check finds an update.
    ModInfo(
      id: 'stale',
      name: 'stale',
      characterId: 'ellen',
      isActive: false,
      origin: originFixture(
        modId: 1,
        modIdConfidence: OriginConfidence.user,
        fileId: 99,
        versionConfidence: OriginConfidence.user,
        provenance: OriginProvenance.downloaded,
      ),
    ),
    // Untracked, so the reminder and its button are on screen.
    ModInfo(id: 'bare', name: 'bare', characterId: 'ellen', isActive: false),
  ];

  Future<void> pumpHost(WidgetTester tester, {OriginWriter? originWriter}) async {
    container = ProviderContainer(overrides: [libraryOf(library)]);
    addTearDown(container.dispose);
    container.read(selectedCharacterIdProvider.notifier).state = 'ellen';
    toolbarShown = ValueNotifier(true);
    addTearDown(toolbarShown.dispose);
    response = Completer();
    fetches = 0;

    await pumpLocalized(
      tester,
      LibraryActionsHost(
        updateFetcher: (ids) {
          fetches++;
          return response.future;
        },
        updatesFetcher: (_) async => const <GbUpdate>[],
        originWriter: originWriter ?? (_, _) async => OriginWriteResult.writeFailed,
        child: ValueListenableBuilder<bool>(
          valueListenable: toolbarShown,
          builder: (_, shown, _) => shown
              ? ModsToolbar(originWriter: (_, _) async => OriginWriteResult.writeFailed)
              : const Text('another page'),
        ),
      ),
      container: container,
    );
    expectBuilt(ModsToolbar);
  }

  Future<void> startCheck(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Library'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Check for updates'));
    // Not settled: the spinner on the menu button turns for as long as the request is out. Two frames, since the
    // entry's press lands after the first one's build.
    await tester.pump();
    await tester.pump();
  }

  /// The ⋯ button, found by its tooltip since its icon is a spinner while the check runs.
  IconButton menuButton(WidgetTester tester) =>
      tester.widget<IconButton>(find.ancestor(of: find.byTooltip('Library'), matching: find.byType(IconButton)));

  OutlinedButton nudgeButton(WidgetTester tester) =>
      tester.widget<OutlinedButton>(find.descendant(of: find.byType(TrackingNudge), matching: find.byType(OutlinedButton)));

  void answer() => response.complete([
    GbMod(idRow: 1, name: 'Ellen Swimsuit', files: [GbFile(idRow: 10, file: 'e.zip', dateAdded: DateTime.utc(2026))]),
  ]);

  testWidgets('a check outlives the toolbar it was started from', (tester) async {
    await pumpHost(tester);
    await startCheck(tester);
    expect(fetches, 1);

    // The user looks at another page while the request is out.
    toolbarShown.value = false;
    await tester.pump();
    expect(find.byType(ModsToolbar), findsNothing);

    answer();
    await tester.pumpAndSettle();

    expect(container.read(modUpdateChecksProvider)['stale']?.outcome, UpdateOutcome.updateAvailable);
    expect(find.text('1 mod has an update'), findsOneWidget, reason: 'the report is the host\'s, not the toolbar\'s');
    expect(container.read(libraryCheckRunningProvider), isFalse);
  });

  testWidgets("a check saves each download's page title on its sidecar", (tester) async {
    // So the details panel names the downloads after a restart, without a request.
    final written = <String, ModOrigin?>{};
    await pumpHost(
      tester,
      originWriter: (modId, update) async {
        written[modId] = update(library.firstWhere((mod) => mod.id == modId).origin);
        return OriginWriteResult.written;
      },
    );
    await startCheck(tester);
    answer();
    await tester.pumpAndSettle();

    expect(written.keys, ['stale'], reason: 'only the mod the page names');
    expect(written['stale']?.base?.name, 'Ellen Swimsuit');
  });

  testWidgets('while it runs, nothing can start another', (tester) async {
    await pumpHost(tester);
    await startCheck(tester);
    expect(container.read(libraryCheckRunningProvider), isTrue);

    expect(menuButton(tester).onPressed, isNull, reason: 'the library menu is disabled');
    expect(nudgeButton(tester).onPressed, isNull, reason: "the reminder's button is disabled");

    // A request from anywhere else is ignored rather than raced into the same results.
    final actions = LibraryActionsHost.of(tester.element(find.byType(ModsToolbar)));
    unawaited(actions.checkForUpdates());
    unawaited(actions.sortOutTracking());
    await tester.pump();
    expect(fetches, 1);

    answer();
    await tester.pumpAndSettle();
    expect(container.read(libraryCheckRunningProvider), isFalse);
    expect(menuButton(tester).onPressed, isNotNull);
    expect(nudgeButton(tester).onPressed, isNotNull);
  });
}
