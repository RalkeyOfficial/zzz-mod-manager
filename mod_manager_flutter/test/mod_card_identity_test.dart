import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/screens/components/mods_grouped_view.dart';

import 'support/localized_harness.dart';

/// A mod card keeps its identity when the mod's *state* changes.
///
/// The card key used to be `mod_<id>_<isActive>`, so toggling a mod re-keyed it
/// and Flutter tore the element down and built a new one. What that cost is
/// invisible in a screenshot and obvious in use: `_ModCardWidgetState.isHovered`
/// went with it, so the card you had just clicked dropped its hover lift and did
/// not get it back until the pointer left and came back.
///
/// Pinned by identity rather than by reading the key, because the key is the
/// mechanism and the surviving `State` is the property that matters.
void main() {
  ModInfo mod(String id, {bool isActive = false}) => ModInfo(
        id: id,
        name: id,
        characterId: 'ellen',
        isActive: isActive,
      );

  /// A stand-in for the real card: the screen owns that wiring and injects it,
  /// so the grouped view can be exercised without `ApiService`.
  Widget card(ModInfo m) => _ProbeCard(label: m.id, isActive: m.isActive);

  Future<void> pump(WidgetTester tester, List<ModInfo> mods) => pumpLocalized(
        tester,
        ModsGroupedView(
          visibleSkins: mods,
          isFiltering: false,
          addModCard: const SizedBox.shrink(),
          modCardBuilder: card,
        ),
      );

  testWidgets('toggling a mod does not rebuild its card from scratch',
      (tester) async {
    await pump(tester, [mod('Ellen Swimsuit')]);
    expectBuilt(ModsGroupedView);

    final before = tester.state<_ProbeCardState>(find.byType(_ProbeCard));
    before.touched = true;

    await pump(tester, [mod('Ellen Swimsuit', isActive: true)]);

    final after = tester.state<_ProbeCardState>(find.byType(_ProbeCard));
    expect(
      identical(before, after),
      isTrue,
      reason: 'the card was re-created, so its hover state was thrown away',
    );
    expect(after.touched, isTrue, reason: 'state did not survive the toggle');
    expect(
      after.widget.isActive,
      isTrue,
      reason: 'the new state still has to reach the card through its props',
    );
  });

  testWidgets('a different mod still gets a different card', (tester) async {
    // The other direction: keys that are too *stable* would let one mod's card
    // be reused for another, which is how a grid shows the wrong artwork.
    await pump(tester, [mod('Ellen Swimsuit')]);
    final before = tester.state<_ProbeCardState>(find.byType(_ProbeCard));

    await pump(tester, [mod('Miyabi Student')]);
    final after = tester.state<_ProbeCardState>(find.byType(_ProbeCard));

    expect(identical(before, after), isFalse);
  });
}

class _ProbeCard extends StatefulWidget {
  const _ProbeCard({required this.label, required this.isActive});

  final String label;
  final bool isActive;

  @override
  State<_ProbeCard> createState() => _ProbeCardState();
}

class _ProbeCardState extends State<_ProbeCard> {
  /// Stands in for anything the real card holds that a rebuild would lose —
  /// `isHovered` above all.
  bool touched = false;

  @override
  Widget build(BuildContext context) => Text(widget.label);
}
