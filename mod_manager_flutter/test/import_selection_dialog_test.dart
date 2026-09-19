import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/screens/dialogs/import_selection_dialog.dart';

import 'support/localized_harness.dart';

void main() {
  // Regression test for the single-folder aliasing bug: resolveImportSelection
  // must return a fresh list, not the caller's own. Both call sites do
  // `folderPaths..clear()..addAll(plan.folders)`; if plan.folders aliased the
  // argument, that cleared the list and dropped the only folder — surfacing as
  // a false "Mods already exist or an error occurred" with nothing installed.
  testWidgets('single-folder plan does not alias the input list',
      (tester) async {
    late ImportPlan? plan;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return TextButton(
              onPressed: () async {
                final folders = ['/tmp/extract/Grace-HazekerRedux'];
                plan = await resolveImportSelection(
                  context,
                  folders,
                  defaultCombinedName: 'Grace-HazekerRedux',
                );
                // Emulate the caller: mutate the ORIGINAL list.
                folders
                  ..clear()
                  ..addAll(plan!.folders);
              },
              child: const Text('go'),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();

    expect(plan, isNotNull);
    expect(plan!.combine, isFalse);
    expect(plan!.folders, ['/tmp/extract/Grace-HazekerRedux']);
  });

  /// The picker an update opens when nothing records which of the archive's folders are the mod.
  /// Same list and pre-ticking as the import; no separate-or-combined choice, since an update lands in one folder.
  group('single-mod mode', () {
    const choices = [
      ImportFolderChoice(path: '/x/Ellen', name: 'Ellen', looksLikeMod: true),
      ImportFolderChoice(path: '/x/previews', name: 'previews', looksLikeMod: false),
    ];

    Future<List<ImportSelection?>> open(
      WidgetTester tester, {
      Size surfaceSize = const Size(1200, 800),
      Set<String>? preselected,
    }) async {
      final answers = <ImportSelection?>[];
      await pumpLocalized(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              answers.add(await showImportSelectionDialog(
                context,
                choices,
                defaultCombinedName: 'Ellen',
                singleMod: true,
                preselected: preselected,
                title: 'Which folders are Ellen?',
                intro: 'Only you can say.',
                confirmLabel: 'Update',
              ));
            },
            child: const Text('open'),
          ),
        ),
        surfaceSize: surfaceSize,
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return answers;
    }

    testWidgets('offers no separate-or-combined choice and no name field',
        (tester) async {
      await open(tester);
      expectBuilt(AlertDialog);

      expect(find.text('Which folders are Ellen?'), findsOneWidget);
      expect(find.text('Only you can say.'), findsOneWidget);
      expect(find.byType(RadioListTile<bool>), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(find.text('Update'), findsOneWidget);
    });

    testWidgets('pre-ticks the folders holding a .ini and returns the ticked ones',
        (tester) async {
      final answers = await open(tester);

      await tester.tap(find.text('Update'));
      await tester.pumpAndSettle();

      expect(answers.single!.folders, ['/x/Ellen']);
      expect(answers.single!.combine, isFalse);
    });

    testWidgets('a caller\'s own pre-tick replaces the .ini rule', (tester) async {
      final answers = await open(tester, preselected: {'/x/previews'});

      await tester.tap(find.text('Update'));
      await tester.pumpAndSettle();

      expect(answers.single!.folders, ['/x/previews']);
    });

    testWidgets('ticking a second folder returns both', (tester) async {
      final answers = await open(tester);

      await tester.tap(find.text('previews'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Update'));
      await tester.pumpAndSettle();

      expect(answers.single!.folders, ['/x/Ellen', '/x/previews']);
    });

    testWidgets('cancelling answers nothing', (tester) async {
      final answers = await open(tester);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(answers.single, isNull);
    });

    testWidgets('fits the narrowest window', (tester) async {
      await open(tester, surfaceSize: const Size(480, 900));
      expect(tester.takeException(), isNull);
    });
  });
}
