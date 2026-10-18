import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/screens/components/mod_details_panel.dart';

import 'support/library_override.dart';
import 'support/localized_harness.dart';

/// The details panel folds a long description to three lines, with More and Less (`docs/library-screen.md` §12).
void main() {
  const description = 'Winter version of the maid uniform, with a long coat, a white hairpin and three stocking '
      'colours.\n\nPair it with the white hairpin: the black one clips through the hood when the coat is up.\n\n'
      'Keys: Alt 1 toggles the coat, Alt 2 cycles the hairpin, Alt 3 cycles the stockings.\n\n'
      'Made for the current version of the game.';
  final mod = ModInfo(
    id: 'Winter Maid',
    name: 'Winter Maid',
    characterId: 'ellen',
    isActive: false,
    description: description,
  );

  Future<void> pumpPanel(WidgetTester tester) async {
    final container = ProviderContainer(overrides: [libraryOf([mod])]);
    addTearDown(container.dispose);
    await pumpLocalized(
      tester,
      ModDetailsPanel(
        mod: mod,
        onClose: () {},
        onToggle: () {},
        onFavoriteToggle: () {},
        onEdit: () {},
        onOpenFolder: () {},
        onCheckForUpdate: () {},
        onResolveOrigin: () {},
        onDelete: () {},
        noteWriter: (_, _) async => true,
      ),
      container: container,
      surfaceSize: const Size(1200, 1600),
    );
    expectBuilt(ModDetailsPanel);
  }

  /// The box the folded description is clipped to.
  double shownHeight(WidgetTester tester) =>
      tester.getSize(find.ancestor(of: find.byType(MarkdownBody), matching: find.byType(ClipRect)).first).height;

  testWidgets('folds a long description without overflowing', (tester) async {
    await pumpPanel(tester);

    // A layout overflow is reported as an exception, so a description squeezed into three lines would fail here.
    expect(tester.takeException(), isNull);
    expect(find.text('More'), findsOneWidget);
    expect(shownHeight(tester), lessThan(100), reason: 'three lines, not the whole description');
  });

  testWidgets('More shows all of it, and Less folds it again', (tester) async {
    await pumpPanel(tester);
    final folded = shownHeight(tester);

    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(shownHeight(tester), greaterThan(folded));
    expect(find.text('Less'), findsOneWidget);

    await tester.tap(find.text('Less'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(shownHeight(tester), folded);
  });
}
