import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/core/palette.dart';
import 'package:mod_manager_flutter/screens/components/character_pick.dart';
import 'package:mod_manager_flutter/screens/components/character_tile.dart';
import 'package:mod_manager_flutter/utils/zzz_characters.dart';

import 'support/localized_harness.dart';

/// The pill that shows a mod's character and the list it opens.
void main() {
  String? picked;

  Future<void> pump(WidgetTester tester, {String? groupId = 'ellen', bool offerUnassigned = true, Brightness brightness = Brightness.dark}) async {
    picked = null;
    await pumpLocalized(
      tester,
      Align(
        alignment: Alignment.topLeft,
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: SizedBox(
            width: 300,
            child: CharacterPick(groupId: groupId, offerUnassigned: offerUnassigned, onChanged: (id) => picked = id),
          ),
        ),
      ),
      brightness: brightness,
    );
    expectBuilt(CharacterPick);
  }

  Future<void> openList(WidgetTester tester) async {
    await tester.tap(find.byType(CharacterPick));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
  }


  testWidgets('shows the character on its tile, in a 36px pill', (tester) async {
    await pump(tester);

    expect(find.text('Ellen Joe'), findsOneWidget);
    expect(tester.widget<CharacterTile>(find.byType(CharacterTile)).groupId, 'ellen');
    expect(tester.getSize(find.byType(CharacterPick)).height, 36);
    expect(tester.getSize(find.byType(CharacterPick)).width, 300);
  });

  testWidgets('with no choice made, is amber and asks for one', (tester) async {
    await pump(tester, groupId: null);

    final palette = ZenithPalette.dark(AccentChoice.violet);
    expect(find.text('Choose a character or type'), findsOneWidget);
    expect(find.byType(CharacterTile), findsNothing);
    expect(tester.widget<Text>(find.text('Choose a character or type')).style!.color, palette.needsPick.foreground);
    final material = tester.widget<Material>(find.descendant(of: find.byType(CharacterPick), matching: find.byType(Material)).first);
    expect(material.color, palette.needsPick.background);
  });

  group('the list', () {
    testWidgets('opens under the pill, with Unassigned, the types, then the agents A to Z', (tester) async {
      await pump(tester);
      await openList(tester);

      final pill = tester.getRect(find.byType(CharacterPick));
      expect(tester.getTopLeft(find.byType(TextField)).dy, greaterThan(pill.bottom));
      expect(find.text('TYPES'), findsOneWidget);
      expect(find.text('AGENTS'), findsOneWidget);
      double y(String label) => tester.getTopLeft(find.text(label).last).dy;
      expect(y('Unassigned'), lessThan(y('TYPES')));
      expect(y('TYPES'), lessThan(y('UI')));
      expect(y('Misc'), lessThan(y('AGENTS')));
      expect(y('AGENTS'), lessThan(y('Alexandrina Sebastiane')));
      expect(y('Alexandrina Sebastiane'), lessThan(y('Alice Thymefield')));
    });

    testWidgets('marks the current one with a check', (tester) async {
      await pump(tester);
      await openList(tester);

      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    });

    testWidgets('leaves Unassigned out when it is not offered', (tester) async {
      await pump(tester, offerUnassigned: false);
      await openList(tester);

      expect(find.text('Unassigned'), findsNothing);
    });

    testWidgets('a press on a row picks it and closes the list', (tester) async {
      await pump(tester);
      await openList(tester);
      await tester.tap(find.text('Texture'));
      await tester.pumpAndSettle();

      expect(picked, 'cat_texture');
      expect(find.byType(TextField), findsNothing);
    });

    testWidgets('Unassigned picks the unknown id', (tester) async {
      await pump(tester);
      await openList(tester);
      await tester.tap(find.text('Unassigned'));
      await tester.pumpAndSettle();

      expect(picked, unknownCharacterId);
    });

    testWidgets('the search narrows by name, and Enter picks the first match', (tester) async {
      await pump(tester);
      await openList(tester);
      await tester.enterText(find.byType(TextField), 'miya');
      await tester.pumpAndSettle();

      expect(find.text('Hoshimi Miyabi'), findsOneWidget);
      expect(find.text('Texture'), findsNothing);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(picked, 'miyabi');
    });

    testWidgets('a search that matches nothing says so', (tester) async {
      await pump(tester);
      await openList(tester);
      await tester.enterText(find.byType(TextField), 'zzzzqq');
      await tester.pumpAndSettle();

      expect(find.text('No characters or types match'), findsOneWidget);
    });

    testWidgets('the arrow keys move the hot row and Enter picks it', (tester) async {
      await pump(tester);
      await openList(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(picked, 'cat_ui', reason: 'Unassigned, then UI');
    });

    testWidgets('Escape closes the list and picks nothing', (tester) async {
      await pump(tester);
      await openList(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(picked, isNull);
      expect(find.byType(TextField), findsNothing);
    });
  });

  testWidgets('Arrow Down on the focused pill opens the list', (tester) async {
    await pump(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsOneWidget);
  });
}
