import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/screens/components/mod_card_widget.dart';
import 'package:mod_manager_flutter/screens/components/zenith_switch.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

import 'support/localized_harness.dart';
import 'support/mods_screen_harness.dart';
import 'support/temp_library.dart';

/// A mod card keeps its identity in the Library's own grid when the mod's state or the grid's order changes.
///
/// The grid is a `SliverGrid` built on demand, which matches children by position unless it is told how to find a
/// key. A card that takes over whichever card was at its old position after a sort shows that card's hover and focus
/// for the wrong mod, and a card rebuilt from scratch by a toggle drops the hover the pointer is still giving it.
void main() {
  late TempLibrary temp;

  setUp(() async {
    temp = await TempLibrary.create(prefix: 'zzz_card_identity_');
  });

  ModInfo mod(String id, {bool isActive = false}) => ModInfo(id: id, name: id, characterId: 'ellen', isActive: isActive);

  State cardState(WidgetTester tester, String id) =>
      tester.state(find.descendant(of: cardOf(id), matching: find.byType(ModCardWidget)));

  List<String> order(WidgetTester tester) => [
    for (final card in tester.widgetList<ModCardWidget>(find.byType(ModCardWidget))) card.mod.id,
  ];

  testWidgets('a sort keeps each card with its mod', (tester) async {
    final container = await pumpModsScreen(tester, temp, [mod('A'), mod('B'), mod('C')], selected: 'ellen');
    container.read(modSortProvider.notifier).state = ModSort.nameAsc;
    await tester.pumpAndSettle();
    expect(order(tester), ['A', 'B', 'C']);
    final a = cardState(tester, 'A');
    final c = cardState(tester, 'C');

    container.read(modSortProvider.notifier).state = ModSort.nameDesc;
    await tester.pumpAndSettle();

    expect(order(tester), ['C', 'B', 'A']);
    expect(identical(cardState(tester, 'A'), a), isTrue, reason: "A's card moved with it");
    expect(identical(cardState(tester, 'C'), c), isTrue, reason: "C's card moved with it");
  });

  testWidgets('a filter that drops a card keeps the others', (tester) async {
    final container = await pumpModsScreen(
      tester,
      temp,
      [mod('A'), mod('B', isActive: true), mod('C', isActive: true)],
      selected: 'ellen',
    );
    container.read(modSortProvider.notifier).state = ModSort.nameAsc;
    await tester.pumpAndSettle();
    final c = cardState(tester, 'C');

    // C moves from the third place to the second.
    container.read(modGridFilterProvider.notifier).state = ModGridFilter.active;
    await tester.pumpAndSettle();

    expect(order(tester), ['B', 'C']);
    expect(identical(cardState(tester, 'C'), c), isTrue);
  });

  testWidgets('toggling a mod does not rebuild its card from scratch', (tester) async {
    temp.createMod('Ellen Swimsuit');
    temp.write('Ellen Swimsuit', 'Ellen Swimsuit.ini', '[TextureOverrideBody]\n');
    final container = await pumpModsScreen(tester, temp, [mod('Ellen Swimsuit'), mod('Ellen Maid')]);
    final before = cardState(tester, 'Ellen Swimsuit');

    await tapWithIo(tester, find.descendant(of: cardOf('Ellen Swimsuit'), matching: find.byType(ZenithSwitch)));

    expect(container.read(modsProvider).firstWhere((m) => m.id == 'Ellen Swimsuit').isActive, isTrue);
    expect(
      identical(cardState(tester, 'Ellen Swimsuit'), before),
      isTrue,
      reason: 'the card was re-created, so its hover state was thrown away',
    );
    expect(
      tester.widget<ModCardWidget>(find.descendant(of: cardOf('Ellen Swimsuit'), matching: find.byType(ModCardWidget)))
          .mod
          .isActive,
      isTrue,
      reason: 'the new state still has to reach the card through its props',
    );
  });

  testWidgets('a different mod still gets a different card', (tester) async {
    // The other direction: keys that are too stable would let one mod's card be reused for another, which is how
    // a grid shows the wrong artwork.
    final container = await pumpModsScreen(tester, temp, [mod('Ellen Swimsuit'), mod('Ellen Maid', isActive: true)]);
    final swimsuit = cardState(tester, 'Ellen Swimsuit');

    container.read(modGridFilterProvider.notifier).state = ModGridFilter.active;
    await tester.pumpAndSettle();

    expect(order(tester), ['Ellen Maid']);
    expect(identical(cardState(tester, 'Ellen Maid'), swimsuit), isFalse);
  });
}
