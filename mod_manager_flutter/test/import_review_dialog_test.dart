import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/screens/components/character_pick.dart';
import 'package:mod_manager_flutter/screens/components/zenith_switch.dart';
import 'package:mod_manager_flutter/screens/dialogs/import_review_dialog.dart';
import 'package:mod_manager_flutter/services/import_review.dart';

import 'support/localized_harness.dart';

/// The review a drop opens before anything is copied (`docs/importing-mods.md` §2 to §4).
void main() {
  ImportItem item(
    String name, {
    String? guess,
    ImportSourceKind kind = ImportSourceKind.folder,
    String? label,
    int? bytes,
  }) => ImportItem(
    id: name,
    sources: ['/drop/$name'],
    label: label ?? name,
    kind: kind,
    name: name,
    bytes: bytes,
    guessedCharacter: guess,
  );

  // The canvas's three rows: a clean archive, one the library already has, and one with no character.
  List<ImportItem> canvasItems() => [
    item(
      'Winter Maid Uniform',
      guess: 'ellen',
      kind: ImportSourceKind.archive,
      label: 'EllenMaidWinter_v1_4.zip',
      bytes: 186 * 1024 * 1024,
    ),
    item(
      'Shark Hoodie Recolor',
      guess: 'ellen',
      kind: ImportSourceKind.archive,
      label: 'SharkHoodie_2.1.7z',
      bytes: 142 * 1024 * 1024,
    ),
    item('new_outfit_final', bytes: 77 * 1024 * 1024),
  ];

  List<ExistingMod> library({bool busy = false, DateTime? installedAt}) => [
    ExistingMod(
      id: 'Shark Hoodie Recolor',
      characterId: 'ellen',
      installedAt: installedAt ?? DateTime(2026, 8, 12),
      busy: busy,
    ),
  ];

  ImportReviewResult? result;
  var closed = false;
  final turnedOn = <bool>[];

  Future<void> open(
    WidgetTester tester,
    List<ImportItem> items, {
    List<ExistingMod>? existing,
    Brightness brightness = Brightness.dark,
  }) async {
    result = null;
    closed = false;
    turnedOn.clear();
    await pumpLocalized(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            result = await showImportReviewDialog(
              context,
              items: items,
              library: existing ?? const [],
              turnOnWriter: (on) async => turnedOn.add(on),
            );
            closed = true;
          },
          child: const Text('open'),
        ),
      ),
      brightness: brightness,
      surfaceSize: const Size(1000, 900),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expectBuilt(ImportReviewDialog);
  }

  Finder confirm() => find.byKey(const ValueKey('import_confirm'));

  bool confirmEnabled(WidgetTester tester) => tester.widget<FilledButton>(confirm()).onPressed != null;

  /// Files the row's pill under [name] through its popover.
  Future<void> pick(WidgetTester tester, int row, String name) async {
    await tester.tap(find.byType(CharacterPick).at(row));
    await tester.pumpAndSettle();
    await tester.tap(find.text(name).last);
    await tester.pumpAndSettle();
  }

  group('the canvas\'s three rows', () {
    testWidgets('say what each one is, and what the library already has', (tester) async {
      await open(tester, canvasItems(), existing: library());

      expect(find.text('Import 3 mods'), findsOneWidget);
      expect(
        find.text('Check where each one goes. Names, characters and types are guessed from the files.'),
        findsOneWidget,
      );
      expect(find.text('EllenMaidWinter_v1_4.zip · 186 MB'), findsOneWidget);
      expect(find.text('new_outfit_final/ · folder · 77.0 MB'), findsOneWidget);
      expect(find.text('Ellen Joe already has a mod with this name, installed 2026-08-12.'), findsOneWidget);
      expect(find.text('Update it'), findsOneWidget);
      expect(find.text('Keep both'), findsOneWidget);
      expect(find.text('A copy of the current mod is saved first, then its files are replaced with these.'), findsOneWidget);
      expect(find.text('Choose a character or type'), findsOneWidget, reason: 'the row with no character asks');
      expect(find.text('Turn on after import'), findsOneWidget);
    });

    testWidgets('keep Import off, and say why under the card, until the third row has a character', (tester) async {
      await open(tester, canvasItems(), existing: library());

      expect(confirmEnabled(tester), isFalse);
      expect(find.text('Import 3'), findsOneWidget);
      expect(find.text('Choose a character or type for new_outfit_final to continue'), findsOneWidget);

      await pick(tester, 2, 'Unassigned');

      expect(confirmEnabled(tester), isTrue);
      expect(find.byKey(const ValueKey('import_blocked')), findsNothing);
    });

    testWidgets('answer with every row as it stands, Update it as it was preselected', (tester) async {
      await open(tester, canvasItems(), existing: library());
      await pick(tester, 2, 'Unassigned');

      await tester.tap(confirm());
      await tester.pumpAndSettle();

      expect(closed, isTrue);
      final rows = result!.rows;
      expect(rows.map((r) => r.finalName), ['Winter Maid Uniform', 'Shark Hoodie Recolor', 'new_outfit_final']);
      expect(rows.map((r) => r.updates), [false, true, false]);
      expect(rows.map((r) => r.character), ['ellen', 'ellen', 'unknown']);
      expect(result!.turnOn, isFalse);
    });
  });

  group('a mod the library already has', () {
    testWidgets('Keep both says what it will be added as, and Update it takes it back', (tester) async {
      await open(tester, canvasItems(), existing: library());

      await tester.tap(find.text('Keep both'));
      await tester.pumpAndSettle();
      expect(find.text('It will be added as Shark Hoodie Recolor (2).'), findsOneWidget);
      expect(find.text('A copy of the current mod is saved first, then its files are replaced with these.'), findsNothing);

      await tester.tap(find.text('Update it'));
      await tester.pumpAndSettle();
      expect(find.text('A copy of the current mod is saved first, then its files are replaced with these.'), findsOneWidget);
    });

    testWidgets('a name edited away from the existing mod is a plain new mod, and edited back is a clash again', (tester) async {
      await open(tester, canvasItems(), existing: library());
      final field = find.byKey(const ValueKey('import_name_Shark Hoodie Recolor'));

      await tester.enterText(field, 'Shark Hoodie Recolor 2');
      await tester.pumpAndSettle();
      expect(find.text('Update it'), findsNothing);

      await tester.enterText(field, 'shark hoodie recolor');
      await tester.pumpAndSettle();
      expect(find.text('Update it'), findsOneWidget, reason: 'the library is flat and the match ignores letter case');
    });

    testWidgets('a mod being written offers only Keep both, and says why', (tester) async {
      await open(tester, canvasItems(), existing: library(busy: true));

      expect(find.text('Update it'), findsNothing);
      expect(find.text('Keep both'), findsOneWidget);
      expect(
        find.text(
          "Shark Hoodie Recolor is being changed right now, so it can't be updated. Keep both, or import again once that's done.",
        ),
        findsOneWidget,
      );
    });

    testWidgets('a mod that has no install date is not given one', (tester) async {
      await open(
        tester,
        [item('Shark Hoodie Recolor', guess: 'ellen')],
        existing: [const ExistingMod(id: 'Shark Hoodie Recolor', characterId: 'ellen')],
      );

      expect(find.text('Ellen Joe already has a mod with this name.'), findsOneWidget);
    });

    testWidgets('a mod filed under a type says the library has it, not the type', (tester) async {
      await open(
        tester,
        [item('Menu Skin', guess: 'cat_ui')],
        existing: [ExistingMod(id: 'Menu Skin', characterId: 'cat_ui', installedAt: DateTime(2026, 8, 12))],
      );

      expect(find.text('Your library already has a mod with this name, installed 2026-08-12.'), findsOneWidget);
    });

    testWidgets('a patch on it that nothing records is said before the write', (tester) async {
      await open(
        tester,
        [item('Shark Hoodie Recolor', guess: 'ellen')],
        existing: [const ExistingMod(id: 'Shark Hoodie Recolor', characterId: 'ellen', flattensPatch: true)],
      );

      expect(find.textContaining('A patch is on this mod and nothing records which files are its'), findsOneWidget);

      await tester.tap(find.text('Keep both'));
      await tester.pumpAndSettle();
      expect(find.textContaining('A patch is on this mod'), findsNothing, reason: 'the existing mod is not touched');
    });
  });

  group('names', () {
    testWidgets('two rows with one name are told apart, and stop the import', (tester) async {
      await open(tester, [item('One', guess: 'ellen'), item('Two', guess: 'ellen')]);

      await tester.enterText(find.byKey(const ValueKey('import_name_Two')), 'One');
      await tester.pumpAndSettle();

      expect(find.text('Two of these have the same name.'), findsNWidgets(2));
      expect(confirmEnabled(tester), isFalse);
      expect(find.text('Fix the name of One and 1 more to continue'), findsOneWidget);
    });

    testWidgets('an invalid name says so under its field', (tester) async {
      await open(tester, [item('Fine', guess: 'ellen')]);

      await tester.enterText(find.byType(TextField), 'a/b');
      await tester.pumpAndSettle();

      expect(find.text("Name contains invalid characters"), findsOneWidget);
      expect(confirmEnabled(tester), isFalse);
    });

    testWidgets('an empty name asks for one', (tester) async {
      await open(tester, [item('Fine', guess: 'ellen')]);

      await tester.enterText(find.byType(TextField), '');
      await tester.pumpAndSettle();

      expect(find.text('Give the mod a name.'), findsOneWidget);
      expect(confirmEnabled(tester), isFalse);
    });
  });

  group('the keyboard and the footer', () {
    testWidgets('Enter in a name field imports when it can', (tester) async {
      await open(tester, [item('Fine', guess: 'ellen')]);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(closed, isTrue);
      expect(result!.rows.single.finalName, 'Fine');
    });

    testWidgets('Enter does nothing while the import is off', (tester) async {
      await open(tester, [item('Fine')]);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(closed, isFalse);
    });

    testWidgets('Escape and Cancel answer nothing', (tester) async {
      await open(tester, [item('Fine', guess: 'ellen')]);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(closed, isTrue);
      expect(result, isNull);

      await open(tester, [item('Fine', guess: 'ellen')]);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(closed, isTrue);
      expect(result, isNull);
    });

    testWidgets('Turn on after import is saved when switched, and comes back in the answer', (tester) async {
      await open(tester, [item('Fine', guess: 'ellen')]);

      await tester.tap(find.byType(ZenithSwitch));
      await tester.pumpAndSettle();
      expect(turnedOn, [true]);

      await tester.tap(find.text('Turn on after import'));
      await tester.pumpAndSettle();
      expect(turnedOn, [true, false], reason: 'the label is the switch\'s too');

      await tester.tap(find.byType(ZenithSwitch));
      await tester.pumpAndSettle();
      await tester.tap(confirm());
      await tester.pumpAndSettle();
      expect(result!.turnOn, isTrue);
    });

    testWidgets('the button names the count, and one mod reads in the singular', (tester) async {
      await open(tester, [item('Fine', guess: 'ellen')]);

      expect(find.text('Import 1 mod'), findsOneWidget);
      expect(find.text('Import 1'), findsOneWidget);
    });
  });

  group('a combined mod', () {
    testWidgets('is one row that says how many folders it holds', (tester) async {
      await open(tester, [
        ImportItem(
          id: 'combined',
          sources: const ['/drop/Body', '/drop/Hair'],
          label: 'Ellen Set',
          kind: ImportSourceKind.combined,
          name: 'Ellen Set',
          bytes: 5 * 1024 * 1024,
          guessedCharacter: 'ellen',
        ),
      ]);

      expect(find.text('Import 1 mod'), findsOneWidget);
      expect(find.text('2 folders, combined · 5.0 MB'), findsOneWidget);
    });
  });

  group('in Ukrainian and on paper', () {
    testWidgets('the title takes the form the count asks for', (tester) async {
      result = null;
      await pumpLocalized(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showImportReviewDialog(
              context,
              items: [item('A', guess: 'ellen'), item('B', guess: 'ellen'), item('C', guess: 'ellen')],
              library: const [],
              turnOnWriter: (_) async {},
            ),
            child: const Text('open'),
          ),
        ),
        locale: const Locale('uk'),
        brightness: Brightness.light,
        surfaceSize: const Size(1000, 900),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('Імпортувати 3 моди'), findsOneWidget);
    });
  });
}
