import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_file.dart';
import 'package:mod_manager_flutter/screens/dialogs/update_confirm_dialog.dart';
import 'package:mod_manager_flutter/services/patch_detection.dart';
import 'package:mod_manager_flutter/services/update_apply/stale_ini.dart';
import 'package:mod_manager_flutter/services/update_apply/update_applier.dart';
import 'package:mod_manager_flutter/services/update_apply/update_layout.dart';

import 'support/localized_harness.dart';

/// The last screen before an update touches a live install.
///
/// What is worth pinning is not the layout but the promises: it says what it is
/// about to do *before* doing it, it refuses rather than guessing where the
/// layout cannot be reconciled, and the one question it asks comes back as an
/// answer the caller can act on.
void main() {
  final mod = ModInfo(
    id: 'Ellen',
    name: 'Ellen',
    characterId: 'ellen',
    isActive: false,
  );
  const file = GbFile(idRow: 42, file: 'ellen_v2.zip', description: 'Main file');

  UpdatePreview preview({
    UpdateLayoutProblem? problem,
    List<String> unused = const [],
    List<String> missing = const [],
    List<StaleIni> stale = const [],
    List<String> kept = const [],
  }) =>
      UpdatePreview(
        layout: UpdateLayout(
          mappings: problem == null
              ? const [UpdateFolderMapping(source: 'Ellen', targetSubPath: '')]
              : const [],
          problem: problem,
          unused: unused,
        ),
        sources: const {},
        patch: PatchAssessment(
          missing: missing,
          required: missing.length,
          hasIni: true,
        ),
        staleInis: StaleIniAssessment(stale: stale, keptUndecidable: kept),
      );

  Future<UpdateConfirmChoice?> open(
    WidgetTester tester,
    UpdatePreview value, {
    Size surfaceSize = const Size(1200, 800),
  }) async {
    UpdateConfirmChoice? choice;
    var opened = false;
    await pumpLocalized(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            opened = true;
            choice = await showUpdateConfirmDialog(
              context,
              mod: mod,
              file: file,
              preview: value,
            );
          },
          child: const Text('open'),
        ),
      ),
      surfaceSize: surfaceSize,
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(opened, isTrue);
    return choice;
  }

  testWidgets('states the snapshot and the accepted keybind loss up front',
      (tester) async {
    await open(tester, preview());
    expectBuilt(AlertDialog);
    // Both are promises the update path's design rests on, so both have to be
    // on screen before the user can consent.
    expect(find.textContaining('A copy of this mod'), findsOneWidget);
    expect(find.textContaining('rebound any keys'), findsOneWidget);
    expect(find.text('Update'), findsWidgets);
  });

  testWidgets('cancelling answers nothing', (tester) async {
    UpdateConfirmChoice? choice;
    await pumpLocalized(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            choice = await showUpdateConfirmDialog(
              context,
              mod: mod,
              file: file,
              preview: preview(),
            );
          },
          child: const Text('open'),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(choice, isNull);
  });

  testWidgets('a patch-shaped download warns that the folder is mixed',
      (tester) async {
    await open(tester, preview(missing: ['body.dds', 'hair.dds']));
    expect(find.textContaining('This download is a patch'), findsOneWidget);
    expect(find.textContaining('none of the 2 file'), findsOneWidget);
  });

  testWidgets('the stale-.ini question defaults to removing it',
      (tester) async {
    UpdateConfirmChoice? choice;
    await pumpLocalized(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            choice = await showUpdateConfirmDialog(
              context,
              mod: mod,
              file: file,
              preview: preview(
                stale: const [StaleIni(path: 'ellen.ini', sharedResources: 2)],
                kept: const ['lycaon.ini'],
              ),
            );
          },
          child: const Text('open'),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.textContaining('ellen.ini'), findsOneWidget);
    // The one the rule refused to touch is named too, and never as something
    // to delete: it belongs to a second mod merged into the same folder.
    expect(find.textContaining('Left alone: lycaon.ini'), findsOneWidget);

    await tester.tap(find.text('Update').last);
    await tester.pumpAndSettle();
    expect(choice?.removeStaleInis, isTrue);
  });

  testWidgets('unticking it comes back as a refusal, not a silent default',
      (tester) async {
    UpdateConfirmChoice? choice;
    await pumpLocalized(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            choice = await showUpdateConfirmDialog(
              context,
              mod: mod,
              file: file,
              preview: preview(
                stale: const [StaleIni(path: 'ellen.ini', sharedResources: 2)],
              ),
            );
          },
          child: const Text('open'),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    // The dialog scrolls, and the question sits below the fold once every
    // notice is present — a tap on an off-screen checkbox is silently swallowed.
    await tester.ensureVisible(find.byType(Checkbox));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Update').last);
    await tester.pumpAndSettle();
    expect(choice?.removeStaleInis, isFalse);
  });

  testWidgets('an unreconcilable layout offers no way to proceed',
      (tester) async {
    // The asymmetry is the design: an "install anyway" button here would be
    // inviting the user to guess where the app refused to.
    await open(tester, preview(problem: UpdateLayoutProblem.layoutUnknown));
    expect(find.text('Update'), findsNothing);
    expect(find.textContaining('only you can say'), findsOneWidget);
  });

  testWidgets('it fits the narrowest window with every warning showing',
      (tester) async {
    // The second toolbar row has produced two overflow bugs in this app, both
    // found by a test rather than a user. This dialog carries more variable
    // text than that row ever did.
    await open(
      tester,
      preview(
        missing: const ['body.dds'],
        unused: const ['previews'],
        stale: const [StaleIni(path: 'a_very_long_old_name.ini', sharedResources: 9)],
        kept: const ['another_mod_merged_in_here.ini'],
      ),
      surfaceSize: const Size(480, 900),
    );
    expect(tester.takeException(), isNull);
  });
}
