import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/screens/components/character_list.dart';
import 'package:mod_manager_flutter/screens/components/zenith_controls.dart';
import 'package:mod_manager_flutter/services/update_check.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';
import 'package:mod_manager_flutter/utils/zzz_characters.dart';

import 'support/library_override.dart';
import 'support/localized_harness.dart';

/// The Library's character list is the roster, not a summary of the library: an agent with no mods has a row too.
void main() {
  late ProviderContainer container;
  late List<(String, String)> retagged;

  ModInfo mod(String id, String characterId, {bool isActive = false}) =>
      ModInfo(id: id, name: id, characterId: characterId, isActive: isActive);

  /// [dragged] puts a draggable mod beside the list, standing in for a card of the grid.
  Future<void> pumpList(WidgetTester tester, List<ModInfo> mods, {ModInfo? dragged}) async {
    container = ProviderContainer(overrides: [libraryOf(mods)]);
    addTearDown(container.dispose);
    retagged = [];
    await pumpLocalized(
      tester,
      Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          height: 760,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              CharacterList(onRetag: (mod, groupId) => retagged.add((mod.id, groupId))),
              if (dragged != null)
                Align(
                  alignment: Alignment.topLeft,
                  child: Draggable<ModInfo>(
                    data: dragged,
                    feedback: const SizedBox.square(dimension: 40),
                    child: const SizedBox(width: 120, height: 60, child: Text('the card')),
                  ),
                ),
            ],
          ),
        ),
      ),
      container: container,
    );
    expectBuilt(CharacterList);
  }

  Future<Finder> rowOf(WidgetTester tester, String id) async {
    final row = find.byKey(ValueKey('character_$id'));
    // Scrolls down only, so callers ask for rows in list order.
    await tester.dragUntilVisible(row, find.byType(ListView), const Offset(0, -200));
    return row;
  }

  /// A row, without scrolling to it: only for a list filtered short enough to build every row it has.
  Finder anyRow(String id) => find.byKey(ValueKey('character_$id'), skipOffstage: false);

  Finder chip(String label) => find.widgetWithText(ZenithChip, label);

  /// The chip's texts other than its label: its count, when it shows one.
  List<String> chipCount(WidgetTester tester, String label) => [
    for (final text in tester.widgetList<Text>(find.descendant(of: chip(label), matching: find.byType(Text))))
      if (text.data != label) text.data!,
  ];

  testWidgets('lists every agent, including the ones with no mods', (tester) async {
    await pumpList(tester, [ModInfo(id: 'a', name: 'Winter Maid', characterId: 'ellen', isActive: true)]);

    // The five other types come first, above the roster.
    for (final id in ['cat_ui', unknownCharacterId]) {
      final row = await rowOf(tester, id);
      expect(row, findsOneWidget, reason: '$id has no row');
      expect(find.descendant(of: row, matching: find.text('No mods yet')), findsOneWidget, reason: id);
    }
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('character_$unknownCharacterId'))).dy,
      lessThan(tester.getTopLeft(find.byKey(ValueKey('character_${zzzCharacterIds.first}'))).dy),
      reason: 'the other types sit above the agents',
    );

    final first = await rowOf(tester, zzzCharacterIds.first);
    expect(find.descendant(of: first, matching: find.text('No mods yet')), findsOneWidget);
    double opacityOf(Finder row) => tester.widget<Opacity>(find.descendant(of: row, matching: find.byType(Opacity)).first).opacity;
    expect(opacityOf(first), lessThan(1), reason: 'a row with no mods is dimmed');

    final ellen = await rowOf(tester, 'ellen');
    expect(find.descendant(of: ellen, matching: find.text('Ellen Joe')), findsOneWidget);
    expect(find.descendant(of: ellen, matching: find.text('1 mod · 1 active')), findsOneWidget);
    expect(opacityOf(ellen), 1);

    for (final id in ['miyabi', zzzCharacterIds.last]) {
      final row = await rowOf(tester, id);
      expect(row, findsOneWidget, reason: '$id has no row');
      expect(find.descendant(of: row, matching: find.text('No mods yet')), findsOneWidget, reason: id);
    }
  });

  testWidgets('tapping a row selects it', (tester) async {
    await pumpList(tester, [ModInfo(id: 'a', name: 'Winter Maid', characterId: 'ellen', isActive: false)]);
    expect(container.read(selectedCharacterIdProvider), isNull);
    expect(container.read(currentCharacterIdProvider), 'ellen');

    await tester.tap(await rowOf(tester, 'miyabi'));
    await tester.pump();

    expect(container.read(selectedCharacterIdProvider), 'miyabi');
    expect(container.read(currentCharacterIdProvider), 'miyabi');
  });

  group('dropping a card on a row', () {
    Future<void> dragOnto(WidgetTester tester, Finder row) async {
      final gesture = await tester.startGesture(tester.getCenter(find.text('the card')));
      await tester.pump();
      await gesture.moveTo(tester.getCenter(row));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
    }

    testWidgets('files the mod under that row', (tester) async {
      final maid = mod('Winter Maid', 'ellen');
      await pumpList(tester, [maid], dragged: maid);

      await dragOnto(tester, await rowOf(tester, 'miyabi'));

      expect(retagged, [('Winter Maid', 'miyabi')]);
    });

    testWidgets('on Unassigned unassigns it', (tester) async {
      final maid = mod('Winter Maid', 'ellen');
      await pumpList(tester, [maid], dragged: maid);

      await dragOnto(tester, await rowOf(tester, unknownCharacterId));

      expect(retagged, [('Winter Maid', unknownCharacterId)]);
    });

    testWidgets('on the row it is already under does nothing', (tester) async {
      final maid = mod('Winter Maid', 'ellen');
      await pumpList(tester, [maid], dragged: maid);

      await dragOnto(tester, await rowOf(tester, 'ellen'));

      expect(retagged, isEmpty);
    });
  });

  group('the filter field', () {
    testWidgets('keeps the rows whose name matches', (tester) async {
      await pumpList(tester, [mod('a', 'ellen')]);

      await tester.enterText(find.byType(TextField), 'miya');
      await tester.pumpAndSettle();

      expect(anyRow('miyabi'), findsOneWidget);
      expect(anyRow('ellen'), findsNothing);
      expect(anyRow(unknownCharacterId), findsNothing);
    });

    testWidgets('says so when nothing matches', (tester) async {
      await pumpList(tester, [mod('a', 'ellen')]);

      await tester.enterText(find.byType(TextField), 'nobody by this name');
      await tester.pumpAndSettle();

      expect(find.text('No character matches'), findsOneWidget);
      expect(find.byType(ListView), findsNothing);
    });

    testWidgets('clearing it brings the roster back', (tester) async {
      await pumpList(tester, [mod('a', 'ellen')]);

      await tester.enterText(find.byType(TextField), 'miya');
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '');
      await tester.pumpAndSettle();

      expect(await rowOf(tester, 'ellen'), findsOneWidget);
      expect(await rowOf(tester, zzzCharacterIds.last), findsOneWidget);
    });
  });

  group('the chips', () {
    final library = [
      mod('Winter Maid', 'ellen', isActive: true),
      mod('Swimsuit', 'ellen'),
      mod('Kimono', 'miyabi'),
      mod('Hud', 'cat_ui'),
    ];

    testWidgets('Has mods keeps the rows with a mod', (tester) async {
      await pumpList(tester, library);

      await tester.tap(chip('Has mods'));
      await tester.pumpAndSettle();

      expect(container.read(characterListFilterProvider), CharacterListFilter.hasMods);
      for (final id in ['ellen', 'miyabi', 'cat_ui']) {
        expect(anyRow(id), findsOneWidget, reason: id);
      }
      for (final id in ['lycaon', unknownCharacterId, 'cat_audio']) {
        expect(anyRow(id), findsNothing, reason: id);
      }
    });

    testWidgets('Active keeps the rows with a mod turned on', (tester) async {
      await pumpList(tester, library);

      await tester.tap(chip('Active'));
      await tester.pumpAndSettle();

      expect(anyRow('ellen'), findsOneWidget);
      expect(anyRow('miyabi'), findsNothing);
      expect(anyRow('cat_ui'), findsNothing);
    });

    testWidgets('Updates keeps the rows the last check flagged', (tester) async {
      await pumpList(tester, library);
      container.read(modUpdateChecksProvider.notifier).state = {
        'Kimono': const UpdateCheck(outcome: UpdateOutcome.updateAvailable),
      };

      await tester.tap(chip('Updates'));
      await tester.pumpAndSettle();

      expect(anyRow('miyabi'), findsOneWidget);
      expect(anyRow('ellen'), findsNothing);
    });

    testWidgets('All shows every row again', (tester) async {
      await pumpList(tester, library);

      await tester.tap(chip('Has mods'));
      await tester.pumpAndSettle();
      await tester.tap(chip('All'));
      await tester.pumpAndSettle();

      expect(await rowOf(tester, unknownCharacterId), findsOneWidget);
      expect(await rowOf(tester, 'lycaon'), findsOneWidget);
    });

    testWidgets('Updates shows no count before a check, and the rows flagged after', (tester) async {
      await pumpList(tester, library);
      // "0" before a check would say the library was looked at and is clean.
      expect(chipCount(tester, 'Updates'), isEmpty);

      // Two of Ellen's mods and one of Miyabi's: two rows, three mods.
      container.read(modUpdateChecksProvider.notifier).state = {
        'Winter Maid': const UpdateCheck(outcome: UpdateOutcome.updateAvailable),
        'Swimsuit': const UpdateCheck(outcome: UpdateOutcome.possiblyOutdated),
        'Kimono': const UpdateCheck(outcome: UpdateOutcome.updateAvailable),
        'Hud': const UpdateCheck(outcome: UpdateOutcome.upToDate),
      };
      await tester.pumpAndSettle();

      expect(chipCount(tester, 'Updates'), ['2']);
    });

    testWidgets('Updates counts zero once a check has run and found nothing', (tester) async {
      await pumpList(tester, library);
      container.read(modUpdateChecksProvider.notifier).state = {
        'Kimono': const UpdateCheck(outcome: UpdateOutcome.upToDate),
      };
      await tester.pumpAndSettle();

      expect(chipCount(tester, 'Updates'), ['0']);
    });
  });
}
