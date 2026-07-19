import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/screens/dialogs/import_selection_dialog.dart';

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
}
