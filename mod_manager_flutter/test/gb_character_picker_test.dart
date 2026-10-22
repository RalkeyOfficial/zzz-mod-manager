import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/core/palette.dart';
import 'package:mod_manager_flutter/models/gamebanana/gamebanana.dart';
import 'package:mod_manager_flutter/screens/components/character_avatar.dart';
import 'package:mod_manager_flutter/screens/components/marketplace/gb_character_picker.dart';
import 'package:mod_manager_flutter/services/gamebanana/remote_mod_metadata.dart';
import 'package:mod_manager_flutter/utils/marketplace_providers.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

import 'support/fixtures.dart';
import 'support/localized_harness.dart';

/// The Browse page's character picker on its own: the chip's looks, and the popover's search, letters, own
/// characters, picks and placement, against the live Character Skins roster.
void main() {
  final roster = parseBareList(loadGbFixture('categories_30305'), GbCategoryNode.fromJson);
  final sorted = [for (final node in roster) node.name!]..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  GbCategoryNode node(String name) => roster.firstWhere((n) => n.name == name);
  MarketplaceQuery picked(String name, {int? id}) =>
      const MarketplaceQuery().withCharacter(MarketplaceCharacter(id ?? node(name).idRow, name));

  Future<ValueNotifier<MarketplaceQuery>> pumpPicker(
    WidgetTester tester, {
    MarketplaceQuery initial = const MarketplaceQuery(),
    Map<String, LibraryGroupCounts> counts = const {},
    Size size = const Size(1200, 800),
  }) async {
    final query = ValueNotifier(initial);
    addTearDown(query.dispose);
    await pumpLocalized(
      tester,
      Padding(
        padding: const EdgeInsets.fromLTRB(32, 20, 32, 0),
        child: Align(
          alignment: Alignment.topLeft,
          child: ValueListenableBuilder(
            valueListenable: query,
            builder: (context, q, _) => GbCharacterPicker(query: q, onChanged: (next) => query.value = next),
          ),
        ),
      ),
      overrides: [
        categoryChildrenProvider.overrideWith((ref, id) async => roster),
        libraryGroupCountsProvider.overrideWithValue(counts),
      ],
      surfaceSize: size,
    );
    expectBuilt(GbCharacterPicker);
    return query;
  }

  Finder popover() => find.byWidgetPredicate((w) => w is Semantics && w.properties.label == 'Pick a character');

  Finder tile(String name) => find.descendant(of: popover(), matching: find.text(name));

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.byType(GbCharacterPicker));
    await tester.pumpAndSettle();
    expect(popover(), findsOneWidget);
  }

  Future<void> type(WidgetTester tester, String text) async {
    await tester.enterText(find.descendant(of: popover(), matching: find.byType(TextField)), text);
    await tester.pumpAndSettle();
  }

  group('the chip', () {
    testWidgets('reads "Any character" on a person disc, with no ×', (tester) async {
      await pumpPicker(tester);
      expect(tester.getSize(find.byType(GbCharacterPicker)), const Size(200, 30));
      expect(find.text('Any character'), findsOneWidget);
      final face = find.ancestor(of: find.byIcon(Icons.person_outline_rounded), matching: find.byType(Container));
      expect(tester.getSize(face.first), const Size(22, 22));
      expect(find.byIcon(Icons.close_rounded), findsNothing);
      expect(find.byIcon(Icons.expand_more_rounded), findsOneWidget);
    });

    testWidgets('a picked agent shows their portrait, their name and an ×, painted as selected', (tester) async {
      await pumpPicker(tester, initial: picked('Ellen Joe'));
      expect(find.text('Ellen Joe'), findsOneWidget);
      final portrait = tester.widget<Image>(find.byType(Image));
      expect((portrait.image as AssetImage).assetName, CharacterAvatar.assetPathFor('ellen'));
      expect(tester.getSize(find.byType(Image)), const Size(22, 22));
      final clear = find.ancestor(of: find.byIcon(Icons.close_rounded), matching: find.byType(Container)).first;
      expect(tester.getSize(clear), const Size(22, 22));
      expect(tester.getRect(clear).right, moreOrLessEquals(tester.getRect(find.byType(GbCharacterPicker)).right - 4));

      final chip = tester.widget<Container>(
        find.descendant(of: find.byType(GbCharacterPicker), matching: find.byType(Container)).first,
      );
      final fill = (chip.decoration! as BoxDecoration).color;
      expect(fill, ZenithPalette.dark(AccentChoice.violet).selected.background);
    });

    testWidgets('a picked category with no roster agent shows its initials on a neutral disc', (tester) async {
      await pumpPicker(tester, initial: picked('Nobody Known', id: 1));
      expect(find.text('Nobody Known'), findsOneWidget);
      expect(find.text('NK'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
      final disc = find.ancestor(of: find.text('NK'), matching: find.byType(Container)).first;
      expect(tester.getSize(disc), const Size(22, 22));
      final palette = ZenithPalette.dark(AccentChoice.violet);
      expect(
        (tester.widget<Container>(disc).decoration! as BoxDecoration).color,
        palette.element(ElementTone.neutral).background,
      );
    });

    testWidgets('the × clears the character and leaves Character on, without opening the popover', (tester) async {
      final query = await pumpPicker(tester, initial: picked('Ellen Joe'));
      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pumpAndSettle();
      expect(query.value.character, isNull);
      expect(query.value.typeId, kCharacterSkinsCategoryId);
      expect(popover(), findsNothing);
      expect(find.text('Any character'), findsOneWidget);
    });
  });

  group('the popover', () {
    testWidgets('opens under the chip at 720×440, with the search focused and every agent A to Z', (tester) async {
      await pumpPicker(tester);
      await open(tester);

      final chip = tester.getRect(find.byType(GbCharacterPicker));
      final panel = tester.getRect(popover());
      expect(panel.size, const Size(720, 440));
      expect(panel.left, chip.left);
      expect(panel.top, chip.bottom + 6);

      final field = tester.widget<EditableText>(find.descendant(of: popover(), matching: find.byType(EditableText)));
      expect(field.focusNode.hasFocus, isTrue);
      expect(find.text('Type a name'), findsOneWidget);
      expect(find.textContaining('picks the first', findRichText: true), findsOneWidget);
      expect(find.text('Enter'), findsOneWidget);
      expect(find.text('Every agent, A to Z'), findsOneWidget);
      expect(find.text('Your characters'), findsNothing, reason: 'the library has no mods');

      // The first tile, painted: a 60px face, and eight to a row at this width.
      final first = tester.getRect(tile(sorted[0]));
      final eighth = tester.getRect(tile(sorted[7]));
      final ninth = tester.getRect(tile(sorted[8]));
      expect(eighth.top, first.top);
      expect(ninth.top, greaterThan(first.top));
      final face = find.descendant(
        of: find.ancestor(of: tile(sorted[0]), matching: find.byType(Column)).first,
        matching: find.byType(ClipRRect),
      );
      expect(tester.getSize(face), const Size(60, 60));
    });

    testWidgets('typing filters by any part of a name, and Enter picks the first', (tester) async {
      final query = await pumpPicker(tester);
      await open(tester);
      await type(tester, 'ell');

      final matches = sorted.where((n) => n.toLowerCase().contains('ell')).toList();
      expect(matches.length, greaterThan(1));
      expect(find.text('${matches.length} found'), findsOneWidget);
      for (final name in matches) {
        expect(tile(name), findsOneWidget);
      }
      expect(tile('Anby Demara'), findsNothing);

      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(query.value.character?.name, matches.first);
      expect(query.value.typeId, kCharacterSkinsCategoryId);
      expect(popover(), findsNothing);
    });

    testWidgets('Tab goes from the search to the tiles, then to the rail', (tester) async {
      await pumpPicker(tester);
      await open(tester);
      Rect focused() => FocusManager.instance.primaryFocus!.rect;

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(focused().contains(tester.getCenter(tile(sorted[0]))), isTrue);

      for (var i = 1; i < sorted.length; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      }
      await tester.pumpAndSettle();
      expect(focused().contains(tester.getCenter(tile(sorted.last))), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(focused().contains(tester.getCenter(find.text('A'))), isTrue);
    });

    testWidgets('says so when nothing matches', (tester) async {
      await pumpPicker(tester);
      await open(tester);
      await type(tester, 'zzzz');
      expect(find.text('0 found'), findsOneWidget);
      expect(find.text('No agent matches “zzzz”.'), findsOneWidget);
    });

    testWidgets('a letter filters to names starting with it, and a second press lifts it', (tester) async {
      await pumpPicker(tester);
      await open(tester);
      await type(tester, 'ell');

      await tester.tap(find.text('Z'));
      await tester.pumpAndSettle();
      expect(find.text('Starting with Z'), findsOneWidget);
      final zs = sorted.where((n) => n.startsWith('Z')).toList();
      for (final name in zs) {
        expect(tile(name), findsOneWidget);
      }
      expect(tile('Ellen Joe'), findsNothing);
      final field = tester.widget<TextField>(find.descendant(of: popover(), matching: find.byType(TextField)));
      expect(field.controller!.text, isEmpty, reason: 'a letter clears the typed name');

      await tester.tap(find.text('Z'));
      await tester.pumpAndSettle();
      expect(find.text('Every agent, A to Z'), findsOneWidget);

      await tester.tap(find.text('Z'));
      await tester.pumpAndSettle();
      await type(tester, 'a');
      expect(find.text('Starting with Z'), findsNothing, reason: 'typing clears the letter');
    });

    testWidgets('a letter no name starts with is inert', (tester) async {
      expect(sorted.where((n) => n.startsWith('F')), isEmpty);
      await pumpPicker(tester);
      await open(tester);
      await tester.tap(find.text('F'));
      await tester.pumpAndSettle();
      expect(find.text('Every agent, A to Z'), findsOneWidget);
      expect(find.text('Starting with F'), findsNothing);
    });

    testWidgets('"Your characters" lists only the agents with mods, and hides while filtering', (tester) async {
      final ellen = RemoteModMetadata.characterIdForCategory('Ellen Joe')!;
      final miyabi = RemoteModMetadata.characterIdForCategory('Hoshimi Miyabi')!;
      await pumpPicker(
        tester,
        counts: {
          ellen: const LibraryGroupCounts(mods: 2),
          miyabi: const LibraryGroupCounts(mods: 1),
          'cat_ui': const LibraryGroupCounts(mods: 4),
        },
      );
      await open(tester);

      final heading = tester.getRect(find.text('Your characters'));
      final every = tester.getRect(find.text('Every agent, A to Z'));
      expect(heading.top, lessThan(every.top));
      // Above the A to Z grid, and in it.
      expect(tile('Ellen Joe'), findsNWidgets(2));
      expect(tile('Hoshimi Miyabi'), findsNWidgets(2));
      expect(tile('Anby Demara'), findsOneWidget);
      final yours = tester.getRect(tile('Ellen Joe').first);
      expect(yours.top, lessThan(every.top));

      await type(tester, 'a');
      expect(find.text('Your characters'), findsNothing);

      await type(tester, '');
      await tester.tap(find.text('E'));
      await tester.pumpAndSettle();
      expect(find.text('Your characters'), findsNothing);
    });

    testWidgets('pressing the picked tile clears the pick; another picks it', (tester) async {
      final query = await pumpPicker(tester, initial: picked('Ellen Joe'));
      await open(tester);
      await tester.tap(tile('Ellen Joe'));
      await tester.pumpAndSettle();
      expect(query.value.character, isNull);
      expect(query.value.typeId, kCharacterSkinsCategoryId, reason: 'Character stays on');
      expect(popover(), findsNothing);

      await open(tester);
      await tester.tap(tile('Anby Demara'));
      await tester.pumpAndSettle();
      expect(query.value.character?.name, 'Anby Demara');
      expect(query.value.character?.id, node('Anby Demara').idRow);
    });

    testWidgets('closes on Esc, on a click outside, and on the chip', (tester) async {
      await pumpPicker(tester);
      await open(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(popover(), findsNothing);

      await open(tester);
      await tester.tapAt(const Offset(1100, 700));
      await tester.pumpAndSettle();
      expect(popover(), findsNothing);

      await open(tester);
      await tester.tap(find.text('Any character'));
      await tester.pumpAndSettle();
      expect(popover(), findsNothing);
    });

    testWidgets('fits a narrow, short window, the whole rail included', (tester) async {
      // The window's least height.
      const size = Size(560, 500);
      await pumpPicker(tester, size: size);
      await open(tester);
      expect(tester.takeException(), isNull);

      final chip = tester.getRect(find.byType(GbCharacterPicker));
      final panel = tester.getRect(popover());
      expect(panel.left, chip.left);
      expect(panel.right, lessThanOrEqualTo(size.width - 32));
      expect(panel.width, size.width - 32 - chip.left);
      expect(panel.bottom, lessThanOrEqualTo(size.height));
      expect(panel.top, chip.bottom + 6);
      expect(tester.getRect(find.text('Z')).bottom, lessThanOrEqualTo(panel.bottom));
      expect(tester.getRect(find.text('A')).top, greaterThan(panel.top));

      // Fewer columns, none narrower than 76px.
      final first = tester.getRect(tile(sorted[0]));
      final rowMates = sorted.takeWhile((n) => tester.getRect(tile(n)).top == first.top).length;
      expect(rowMates, lessThan(8));
      expect(rowMates, greaterThan(1));
      final cell = find.ancestor(of: tile(sorted[0]), matching: find.byType(SizedBox)).first;
      expect(tester.getSize(cell).width, greaterThanOrEqualTo(76));
    });
  });
}
