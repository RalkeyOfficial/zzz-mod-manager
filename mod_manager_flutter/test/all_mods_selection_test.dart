import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/services/platform_service.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

import 'support/all_mods_harness.dart';
import 'support/origin_shorthand.dart';

/// Ticking rows on the All mods table: a Shift-click range over rows that can't be ticked, and the selection bar in
/// the smallest window (`docs/library-screen.md` §16).
void main() {
  ModInfo mod(String name, {String characterId = 'ellen'}) =>
      ModInfo(id: name, name: name, characterId: characterId, isActive: false);

  /// Sorted by name, so the rows read in the order the test names them.
  void sortByName(ProviderContainer container) =>
      container.read(allModsSortProvider.notifier).state = const AllModsSort(AllModsColumn.name, descending: false);

  Future<void> shiftTick(WidgetTester tester, String name) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tap(rowBox(name));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
  }

  group('a Shift-click range', () {
    testWidgets('ticks the mods across a Folder missing row, which has no box', (tester) async {
      final container = await pumpAllModsTable(
        tester,
        [mod('a'), mod('c'), mod('e'), mod('f')],
        overrides: [
          deadModLinksProvider.overrideWith((ref) async => const [DeadModLink(name: 'b', target: '/media/drive/b')]),
        ],
      );
      sortByName(container);
      await tester.pumpAndSettle();
      expect(find.text('b'), findsOneWidget);
      expect(rowBox('b'), findsNothing);

      await tick(tester, ['a']);
      await shiftTick(tester, 'e');

      expect(tester.takeException(), isNull);
      expect(container.read(allModsSelectionProvider), {'a', 'c', 'e'});
    });

    testWidgets('clears the mods it spans when the box pressed is cleared', (tester) async {
      final container = await pumpAllModsTable(tester, [mod('a'), mod('b'), mod('c'), mod('d')]);
      sortByName(container);
      await tester.pumpAndSettle();
      await tick(tester, ['a', 'b', 'c', 'd']);

      await tick(tester, ['b']);
      await shiftTick(tester, 'd');

      expect(container.read(allModsSelectionProvider), {'a'});
    });

    testWidgets("leaves a folded group's rows alone", (tester) async {
      final container = await pumpAllModsTable(tester, [
        mod('anby one', characterId: 'anby'),
        mod('ellen one'),
        mod('ellen two'),
        mod('miyabi one', characterId: 'miyabi'),
      ]);
      container.read(allModsGroupingProvider.notifier).state = AllModsGrouping.character;
      await tester.pumpAndSettle();
      // Headings in the character list's order: Anby, Ellen, Miyabi.
      await tester.tap(find.byType(AnimatedRotation).at(1));
      await tester.pumpAndSettle();
      expect(find.text('ellen one'), findsNothing);

      await tick(tester, ['anby one']);
      await shiftTick(tester, 'miyabi one');

      expect(container.read(allModsSelectionProvider), {'anby one', 'miyabi one'});
    });

    testWidgets('in a grouped table follows the order on screen', (tester) async {
      // By name the table runs b, c, d; grouped, Ellen's b and d sit together above the UI group's c.
      final container = await pumpAllModsTable(tester, [mod('b'), mod('c', characterId: 'cat_ui'), mod('d')]);
      sortByName(container);
      container.read(allModsGroupingProvider.notifier).state = AllModsGrouping.character;
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.text('d')).dy, lessThan(tester.getTopLeft(find.text('c')).dy));

      await tick(tester, ['b']);
      await shiftTick(tester, 'd');

      expect(container.read(allModsSelectionProvider), {'b', 'd'}, reason: 'c is below the range on screen');
    });
  });

  group('the selection bar at the minimum window', () {
    // 800x600 less the sidebar, with a mod that asks "Which file?" ticked, so every button the bar can show is on it.
    final library = [
      ModInfo(
        id: 'asks',
        name: 'asks',
        characterId: 'ellen',
        isActive: false,
        origin: originFixture(
          modId: 1,
          modIdConfidence: OriginConfidence.inferred,
          provenance: OriginProvenance.importedFolder,
          installedAt: DateTime.utc(2026, 5, 8, 12),
        ),
      ),
    ];

    testWidgets('is icons in English too, and labelled in a wider window', (tester) async {
      await pumpAllModsTable(tester, library, surfaceSize: const Size(584, 600));
      await tick(tester, ['asks']);

      expect(barButton('Mark 1 as current'), findsNothing);
      expect(find.byTooltip('Mark 1 as current'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.binding.setSurfaceSize(const Size(1000, 600));
      await tester.pumpAndSettle();
      expect(barButton('Mark 1 as current'), findsOneWidget);
    });

    testWidgets("keeps its form whatever is ticked, Mark as current or not", (tester) async {
      final mods = [...library, ModInfo(id: 'plain', name: 'plain', characterId: 'ellen', isActive: false)];
      await pumpAllModsTable(tester, mods, surfaceSize: const Size(584, 600));
      await tick(tester, ['plain']);
      expect(find.byTooltip('Delete'), findsOneWidget, reason: 'icons without the Mark button too');

      // Wide enough for the labels with every shown mod ticked and Mark showing.
      await tester.binding.setSurfaceSize(const Size(900, 600));
      await tester.pumpAndSettle();
      expect(barButton('Delete'), findsOneWidget);
      await tick(tester, ['asks']);
      expect(barButton('Mark 1 as current'), findsOneWidget, reason: 'the Mark button showing changes nothing');
    });

    testWidgets("Tab never lands on the labelled bar's buttons while it shows icons", (tester) async {
      await pumpAllModsTable(tester, library, surfaceSize: const Size(584, 600));
      await tick(tester, ['asks']);

      var reachedShownDelete = false;
      for (var i = 0; i < 60; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        final focused = FocusManager.instance.primaryFocus?.context;
        final button = focused?.findAncestorWidgetOfExactType<OutlinedButton>();
        final label = button?.child is Text ? (button!.child! as Text).data : null;
        expect(label, isNot('Delete'), reason: 'press $i reached the hidden Delete');
        if (focused?.findAncestorWidgetOfExactType<IconButton>()?.tooltip == 'Delete') reachedShownDelete = true;
      }
      expect(reachedShownDelete, isTrue, reason: "the shown bar's Delete is reachable");
    });

    // Labelled, the bar is 578.2px wide in English and 727.0px in Ukrainian with this one mod, and it needs 24px to
    // spare each side: labels from a page of 627px in English and 776px in Ukrainian, icons a pixel below. The page
    // is the window less the 216px sidebar.
    for (final (width, labelled) in [(627.0, true), (626.0, false)]) {
      testWidgets('in English is ${labelled ? 'labelled' : 'icons'} on a page ${width.round()}px wide', (tester) async {
        await pumpAllModsTable(tester, library, surfaceSize: Size(width, 600));
        await tick(tester, ['asks']);

        expect(barButton('Mark 1 as current'), labelled ? findsOneWidget : findsNothing);
        expect(find.byTooltip('Mark 1 as current'), labelled ? findsNothing : findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    for (final (width, labelled) in [(776.0, true), (775.0, false)]) {
      testWidgets('in Ukrainian is ${labelled ? 'labelled' : 'icons'} on a page ${width.round()}px wide', (tester) async {
        await pumpAllModsTable(tester, library, locale: const Locale('uk'), surfaceSize: Size(width, 600));
        await tester.tap(find.byType(Checkbox).at(1));
        await tester.pumpAndSettle();

        expect(barButton('Позначити 1 як актуальний'), labelled ? findsOneWidget : findsNothing);
        expect(find.byTooltip('Позначити 1 як актуальний'), labelled ? findsNothing : findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets("greys out its actions while a mod's switch press lands", (tester) async {
      final container = await pumpAllModsTable(tester, library);
      await tick(tester, ['asks']);
      final landed = Completer<void>();
      final press = container.read(libraryTogglesProvider.notifier).run('asks', () => landed.future);
      await tester.pump();

      expect(tester.widget<OutlinedButton>(barButton('Delete')).onPressed, isNull);
      expect(container.read(allModsBulkRunningProvider), isFalse, reason: "that flag greys out the mods' switches");

      landed.complete();
      await press;
      await tester.pump();
      expect(tester.widget<OutlinedButton>(barButton('Delete')).onPressed, isNotNull);
    });

    testWidgets(
      'fits in Ukrainian',
      (tester) async {
        await pumpAllModsTable(tester, library, locale: const Locale('uk'), surfaceSize: const Size(584, 600));
        expect(tester.takeException(), isNull, reason: 'the page fits before anything is ticked');
        // The row's box is labelled in Ukrainian, so it is found by place: the header's box comes first.
        await tester.tap(find.byType(Checkbox).at(1));
        await tester.pumpAndSettle();

        // Too wide with its labels, so the actions are icons, each named by its tooltip.
        expect(barButton('Позначити 1 як актуальний'), findsNothing);
        expect(find.byTooltip('Позначити 1 як актуальний'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  });
}
