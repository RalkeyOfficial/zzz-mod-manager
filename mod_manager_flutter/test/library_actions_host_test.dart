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
import 'package:mod_manager_flutter/screens/all_mods/all_mods_view.dart';
import 'package:mod_manager_flutter/screens/components/library_actions_host.dart';
import 'package:mod_manager_flutter/services/origin_write.dart';
import 'package:mod_manager_flutter/services/update_check.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

import 'support/all_mods_harness.dart';
import 'support/library_override.dart';
import 'support/localized_harness.dart';
import 'support/origin_shorthand.dart';

/// The whole-library check runs in [LibraryActionsHost], above the pages, so it outlives the All mods page it was
/// started from, and one pass runs at a time.
void main() {
  late ProviderContainer container;
  late ValueNotifier<bool> pageShown;
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
    // Untracked, so the tracking screen has a row for it.
    ModInfo(id: 'bare', name: 'bare', characterId: 'ellen', isActive: false),
  ];

  Future<void> pumpHost(WidgetTester tester, {OriginWriter? originWriter}) async {
    container = ProviderContainer(overrides: [libraryOf(library)]);
    addTearDown(container.dispose);
    pageShown = ValueNotifier(true);
    addTearDown(pageShown.dispose);
    response = Completer();
    fetches = 0;

    await loadTableFonts(tester);
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
          valueListenable: pageShown,
          builder: (_, shown, _) => shown ? allModsViewForTest() : const Text('another page'),
        ),
      ),
      container: container,
      surfaceSize: const Size(1400, 900),
    );
    expectBuilt(AllModsView);
  }

  Finder checkAll() => find.widgetWithText(OutlinedButton, 'Check all for updates');

  Future<void> startCheck(WidgetTester tester) async {
    await tester.tap(checkAll());
    // Not settled: the button's spinner turns for as long as the request is out.
    await tester.pump();
    await tester.pump();
  }

  // Dated, as every real record is: an undated one is a withheld mod's blank, and the check fetches its profile.
  void answer() => response.complete([
    GbMod(
      idRow: 1,
      name: 'Ellen Swimsuit',
      dateAdded: DateTime.utc(2025),
      files: [GbFile(idRow: 10, file: 'e.zip', dateAdded: DateTime.utc(2026))],
    ),
  ]);

  testWidgets('a check outlives the page it was started from', (tester) async {
    await pumpHost(tester);
    await startCheck(tester);
    expect(fetches, 1);

    // The user looks at another page while the request is out.
    pageShown.value = false;
    await tester.pump();
    expect(find.byType(AllModsView), findsNothing);

    answer();
    await tester.pumpAndSettle();

    expect(container.read(modUpdateChecksProvider)['stale']?.outcome, UpdateOutcome.updateAvailable);
    expect(find.text('1 mod has an update'), findsOneWidget, reason: 'the report is the host\'s, not the page\'s');
    expect(find.text('Checked 2 mods.'), findsOneWidget, reason: 'a page request no test stubbed would read "couldn\'t be checked"');
    expect(container.read(libraryCheckRunningProvider), isFalse);
  });

  testWidgets('says which mods it has reached while it runs, and keeps them checked once it ends', (tester) async {
    await pumpHost(tester);
    // Each time the progress changes, whether the session's verdict on the mod it reached was in by then.
    final seen = <String>[];
    container.listen(
      libraryCheckProgressProvider,
      (_, reached) => seen.add('${reached.toList()} ${container.read(modUpdateChecksProvider).containsKey('stale')}'),
    );
    await startCheck(tester);
    answer();
    await tester.pumpAndSettle();

    expect(seen, ['[stale] false', '[] true'], reason: 'the verdict lands before the progress is cleared, so the mod never reads unchecked in between');
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

  testWidgets("checking some mods doesn't count as checking the library", (tester) async {
    await pumpHost(tester);
    final actions = LibraryActionsHost.of(tester.element(find.byType(AllModsView)));
    unawaited(actions.checkMods([library.first]));
    await tester.pump();
    answer();
    await tester.pumpAndSettle();

    expect(container.read(modUpdateChecksProvider)['stale']?.outcome, UpdateOutcome.updateAvailable);
    expect(container.read(knownModPagesProvider).keys, [1], reason: 'the page is shown');
    expect(container.read(modUpdateRecordsProvider), isEmpty);
    expect(container.read(libraryCheckedAtProvider), isNull);

    // So Sort out tracking runs a check of its own rather than calling every other mod unreached.
    unawaited(actions.sortOutTracking());
    await tester.pump();
    expect(fetches, 2);
    await tester.pumpAndSettle();
  });

  testWidgets("checking some mods refreshes a page the whole check holds, so the newer one shows", (tester) async {
    await pumpHost(tester);
    container.read(modUpdateRecordsProvider.notifier).state = {1: GbMod(idRow: 1, name: 'Old title')};
    final actions = LibraryActionsHost.of(tester.element(find.byType(AllModsView)));
    unawaited(actions.checkMods([library.first]));
    await tester.pump();
    answer();
    await tester.pumpAndSettle();

    expect(container.read(knownModPagesProvider)[1]?.name, 'Ellen Swimsuit');
    expect(container.read(modUpdateRecordsProvider).keys, [1], reason: 'no record added for a page it did not hold');
  });

  testWidgets('while it runs, nothing can start another', (tester) async {
    await pumpHost(tester);
    await startCheck(tester);
    expect(container.read(libraryCheckRunningProvider), isTrue);

    expect(tester.widget<OutlinedButton>(checkAll()).onPressed, isNull, reason: 'the check button is disabled');
    expect(find.descendant(of: checkAll(), matching: find.byType(CircularProgressIndicator)), findsOneWidget);

    // A request from anywhere else is ignored rather than raced into the same results.
    final actions = LibraryActionsHost.of(tester.element(find.byType(AllModsView)));
    unawaited(actions.checkForUpdates());
    unawaited(actions.sortOutTracking());
    await tester.pump();
    expect(fetches, 1);

    answer();
    await tester.pumpAndSettle();
    expect(container.read(libraryCheckRunningProvider), isFalse);
    expect(tester.widget<OutlinedButton>(checkAll()).onPressed, isNotNull);
  });
}
