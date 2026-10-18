import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/screens/components/character_hero.dart';

import 'support/library_override.dart';
import 'support/localized_harness.dart';

/// The header above a character's mods, at the width the page has beside the character list and the details panel.
void main() {
  Future<void> pumpHero(WidgetTester tester, String groupId, {required double width}) async {
    await pumpLocalized(
      tester,
      Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: width,
          child: CharacterHero(groupId: groupId, onFindMods: () {}, onAddMod: () {}),
        ),
      ),
      overrides: [
        libraryOf([ModInfo(id: 'a', name: 'a', characterId: groupId, isActive: true)]),
      ],
    );
    expectBuilt(CharacterHero);
  }

  testWidgets('the longest name fits a narrow page', (tester) async {
    // "SOLDIER 0 - ANBY DEMARA" is about 700px at full size.
    await pumpHero(tester, 'solder0anby', width: 500);

    expect(tester.takeException(), isNull);
    expect(find.text('SOLDIER 0 - ANBY DEMARA'), findsOneWidget);
    final name = tester.getRect(find.text('SOLDIER 0 - ANBY DEMARA'));
    expect(name.right, lessThanOrEqualTo(500), reason: 'scaled down rather than cut off');
  });

  testWidgets('holds together at the narrowest page', (tester) async {
    // An 800px window less the sidebar (216) and the character list (280).
    await pumpHero(tester, 'solder0anby', width: 304);

    expect(tester.takeException(), isNull);
    expect(find.text('Find mods'), findsOneWidget);
    expect(find.text('Add mod'), findsOneWidget);
    expect(find.textContaining('Silver Squad'), findsOneWidget, reason: 'the faction line ellipsises rather than going');
  });
}
