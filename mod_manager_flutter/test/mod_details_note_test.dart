import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/screens/components/mod_details_panel.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

import 'support/library_override.dart';
import 'support/localized_harness.dart';

/// The details panel's note has no Save button: it is saved when typing pauses, and on the way out
/// (`docs/library-screen.md` §11).
void main() {
  final ellen = ModInfo(id: 'Ellen Maid', name: 'Ellen Maid', characterId: 'ellen', isActive: false);
  final miyabi = ModInfo(id: 'Miyabi Kimono', name: 'Miyabi Kimono', characterId: 'miyabi', isActive: false);

  late ProviderContainer container;
  late List<(String, String)> writes;

  /// What the writer answers. Saved, unless a test says otherwise.
  Future<bool> Function() saved = () async => true;
  setUp(() => saved = () async => true);

  Widget panel(ModInfo mod) => ModDetailsPanel(
    mod: mod,
    onClose: () {},
    onToggle: () {},
    onFavoriteToggle: () {},
    onEdit: () {},
    onOpenFolder: () {},
    onCheckForUpdate: () {},
    onResolveOrigin: () {},
    onDelete: () {},
    noteWriter: (modId, note) {
      writes.add((modId, note));
      return saved();
    },
  );

  Future<void> pumpPanel(WidgetTester tester, ModInfo mod, {Map<String, String> notes = const {}}) async {
    // The library is held in memory: the panel's size row reads it, and a real scan would reach ApiService.
    container = ProviderContainer(overrides: [libraryOf([ellen, miyabi])]);
    addTearDown(container.dispose);
    container.read(modNotesProvider.notifier).state = notes;
    writes = [];
    await pumpLocalized(tester, panel(mod), container: container, surfaceSize: const Size(1200, 1600));
    expectBuilt(ModDetailsPanel);
  }

  Finder noteField() => find.byType(TextField);

  testWidgets('shows the saved note', (tester) async {
    await pumpPanel(tester, ellen, notes: {'Ellen Maid': 'with the white hairpin'});
    expect(find.text('with the white hairpin'), findsOneWidget);
  });

  testWidgets('saves once typing pauses', (tester) async {
    await pumpPanel(tester, ellen);

    await tester.enterText(noteField(), 'with the white hairpin');
    await tester.pump(const Duration(milliseconds: 300));
    expect(writes, isEmpty, reason: 'still typing');

    await tester.pump(const Duration(milliseconds: 600));
    expect(writes, [('Ellen Maid', 'with the white hairpin')]);

    await tester.pump(const Duration(seconds: 2));
    expect(writes, hasLength(1), reason: 'an unchanged note is not saved again');
  });

  testWidgets('saves an unsaved note when the panel moves to another mod', (tester) async {
    await pumpPanel(tester, ellen, notes: {'Miyabi Kimono': 'the blue one'});
    await tester.enterText(noteField(), 'half written');

    // The same panel, now on another mod: the note field is keyed by the mod, so the old one is disposed.
    await pumpLocalized(tester, panel(miyabi), container: container, surfaceSize: const Size(1200, 1600));
    expect(writes, [('Ellen Maid', 'half written')]);
    expect(find.text('the blue one'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    expect(writes, hasLength(1), reason: "the pending timer was the old field's and went with it");
  });

  testWidgets('saves an unsaved note when the panel closes', (tester) async {
    await pumpPanel(tester, ellen);

    await tester.enterText(noteField(), 'half written');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));

    expect(writes, [('Ellen Maid', 'half written')]);
  });

  testWidgets('a save that fails on the way out is still reported', (tester) async {
    saved = () async => false;
    await pumpPanel(tester, ellen);
    await tester.enterText(noteField(), 'half written');

    // The panel goes, the notifications stay.
    await pumpLocalized(tester, const SizedBox(), container: container, surfaceSize: const Size(1200, 1600));
    await tester.pumpAndSettle();

    expect(writes, [('Ellen Maid', 'half written')]);
    expect(find.text('Note not saved'), findsOneWidget);
    expect(find.text('Ellen Maid'), findsOneWidget, reason: 'the notification names the mod');
  });

  testWidgets('a note still being written shows when the panel comes back to its mod', (tester) async {
    // The write never finishes: what the field shows is what was published before it started.
    saved = () => Completer<bool>().future;
    await pumpPanel(tester, ellen);
    await tester.enterText(noteField(), 'half written');

    await pumpLocalized(tester, panel(miyabi), container: container, surfaceSize: const Size(1200, 1600));
    await pumpLocalized(tester, panel(ellen), container: container, surfaceSize: const Size(1200, 1600));

    expect(writes, [('Ellen Maid', 'half written')]);
    expect(find.text('half written'), findsOneWidget);
    expect(container.read(modNotesProvider), {'Ellen Maid': 'half written'});
  });

  testWidgets('a note emptied is taken off the mod', (tester) async {
    await pumpPanel(tester, ellen, notes: {'Ellen Maid': 'kept'});

    await tester.enterText(noteField(), '');
    await tester.pump(const Duration(seconds: 1));

    expect(writes, [('Ellen Maid', '')]);
    expect(container.read(modNotesProvider), isEmpty);
  });

  testWidgets('a panel closed with the note unchanged writes nothing', (tester) async {
    await pumpPanel(tester, ellen, notes: {'Ellen Maid': 'kept'});
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    expect(writes, isEmpty);
  });
}
