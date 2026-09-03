import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_file.dart';
import 'package:mod_manager_flutter/screens/dialogs/update_confirm_dialog.dart';
import 'package:mod_manager_flutter/services/patch_detection.dart';
import 'package:mod_manager_flutter/services/update_apply/sibling_group.dart';
import 'package:mod_manager_flutter/services/update_apply/stale_ini.dart';
import 'package:mod_manager_flutter/services/update_apply/update_applier.dart';
import 'package:mod_manager_flutter/services/update_apply/update_layout.dart';
import 'package:mod_manager_flutter/services/update_apply/update_target.dart';

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
    bool flattensPatch = false,
    bool reinstall = false,
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
              flattensPatch: flattensPatch,
              reinstall: reinstall,
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

  testWidgets('a patch it cannot put back is said before anything is written',
      (tester) async {
    // **The one loss on this screen not already paid for by a rule.** A patch
    // whose files are on record is set aside and placed back over the new
    // version; this folder's are not, so the update replaces whatever it ships
    // the same names for. Invisible afterwards — the folder looks complete
    // either way — so it has to be here or the trade is not one.
    await open(tester, preview(), flattensPatch: true);

    expect(find.textContaining('holds a patch as well'), findsOneWidget);
    expect(find.text('Update'), findsWidgets,
        reason: 'still offered: the update is what they want and the copy is '
            'the way back');
  });

  testWidgets('an ordinary update says nothing of the kind', (tester) async {
    await open(tester, preview());
    expect(find.textContaining('holds a patch as well'), findsNothing);
  });

  testWidgets('a repair asks to reinstall, not to update', (tester) async {
    // The same write, and the user asked for a different thing: "Update Ellen?"
    // in front of a reinstall reads as an offer of something newer, which is
    // the one thing a repair is not.
    await open(tester, preview(), reinstall: true);

    expect(find.text('Reinstall Ellen?'), findsOneWidget);
    expect(find.text('Reinstall'), findsWidgets);
    expect(find.text('Update Ellen?'), findsNothing);
    // Everything below the headline describes the write, which is identical.
    expect(find.textContaining('A copy of this mod'), findsOneWidget);
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

  // ------------------------------------------------- one archive, several mods

  /// **The other mods one archive installed**, offered on the same screen
  /// because one download covers all of them.
  ///
  /// The property the whole group rests on is that nothing here changes the
  /// single-mod screen — which the tests above assert by still passing — so
  /// these pin the additions and the two states that are easy to get wrong: a
  /// blocked primary must not take its siblings down, and every row unticked
  /// must not offer a write.
  group('one archive going into several folders', () {
    ModInfo sibling(String id) => ModInfo(
          id: id,
          name: id,
          characterId: 'ellen',
          isActive: false,
        );

    UpdateTarget target(
      String id, {
      List<StaleIni> stale = const [],
      List<String> missing = const [],
      bool flattensPatch = false,
      UpdateLayoutProblem? problem,
      SiblingCaution? caution,
    }) =>
        UpdateTarget(
          mod: sibling(id),
          preview: preview(
            stale: stale,
            missing: missing,
            problem: problem,
          ),
          flattensPatch: flattensPatch,
          caution: caution,
        );

    /// Opens the dialog and hands back the box the answer lands in — the answer
    /// itself does not exist until the test presses the button.
    Future<List<UpdateConfirmChoice>> openGroup(
      WidgetTester tester, {
      UpdatePreview? primary,
      List<UpdateTarget> siblings = const [],
      List<SiblingRefused> refused = const [],
      List<String> otherFolders = const [],
      Size surfaceSize = const Size(1200, 900),
    }) async {
      final answers = <UpdateConfirmChoice>[];
      await pumpLocalized(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              final choice = await showUpdateConfirmDialog(
                context,
                mod: mod,
                file: file,
                preview: primary ?? preview(),
                siblings: siblings,
                refused: refused,
                otherFolders: otherFolders,
              );
              if (choice != null) answers.add(choice);
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

    testWidgets('counts the folders it writes and lists every one',
        (tester) async {
      await openGroup(tester, siblings: [target('Ellen Blue')]);
      expectBuilt(AlertDialog);

      expect(find.text('Update 2 mods from this archive?'), findsOneWidget);
      expect(find.text('Ellen'), findsWidgets);
      expect(find.text('Ellen Blue'), findsOneWidget);
      expect(find.text('Update 2 mods'), findsOneWidget);
    });

    testWidgets('every row starts ticked, because one download covers them all',
        (tester) async {
      await openGroup(
        tester,
        siblings: [target('Ellen Blue'), target('Ellen Red')],
      );

      final boxes = tester.widgetList<CheckboxListTile>(
        find.byType(CheckboxListTile),
      );
      expect(boxes.length, 3);
      expect(boxes.every((box) => box.value == true), isTrue);
    });

    testWidgets('unticking one comes back as a smaller set, not a default',
        (tester) async {
      // The point of the row being the user's: a mod they want left alone has
      // to stay on the version it has, and the caller has to be told which.
      final answers =
          await openGroup(tester, siblings: [target('Ellen Blue')]);

      await tester.tap(find.text('Ellen Blue'));
      await tester.pumpAndSettle();
      expect(find.text('Update 1 mod'), findsOneWidget);

      await tester.tap(find.text('Update 1 mod'));
      await tester.pumpAndSettle();

      expect(answers.single.accepted, {'Ellen'});
    });

    testWidgets('leaving them all ticked comes back as all of them',
        (tester) async {
      final answers = await openGroup(
        tester,
        siblings: [target('Ellen Blue'), target('Ellen Red')],
      );

      await tester.tap(find.text('Update 3 mods'));
      await tester.pumpAndSettle();

      expect(answers.single.accepted, {'Ellen', 'Ellen Blue', 'Ellen Red'});
    });

    testWidgets('every row unticked offers no write at all', (tester) async {
      await openGroup(tester, siblings: [target('Ellen Blue')]);

      await tester.tap(find.text('Ellen'));
      await tester.tap(find.text('Ellen Blue'));
      await tester.pumpAndSettle();

      final button = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(button.onPressed, isNull,
          reason: 'a coherent state to be in, and the way out is Cancel');
    });

    testWidgets('a folder holding something newer is offered unticked',
        (tester) async {
      // Writing it would roll it back a version, in a screen that never showed
      // which version it was on — so it is offered rather than refused, and
      // unticked rather than done to them.
      final answers = await openGroup(
        tester,
        siblings: [target('Ellen Blue', caution: SiblingCaution.holdsNewer)],
      );

      expect(find.textContaining('would go back a version'), findsOneWidget);
      expect(find.text('Update 1 mod'), findsOneWidget);

      await tester.tap(find.text('Update 1 mod'));
      await tester.pumpAndSettle();
      expect(answers.single.accepted, {'Ellen'},
          reason: 'the cautioned folder is left alone unless it is ticked');
    });

    testWidgets('a folder whose updates are ignored is offered unticked',
        (tester) async {
      await openGroup(
        tester,
        siblings: [target('Ellen Blue', caution: SiblingCaution.dismissed)],
      );

      expect(find.textContaining("you're ignoring"), findsOneWidget);
      final boxes = tester
          .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
          .toList();
      expect(boxes.first.value, isTrue, reason: 'the primary');
      expect(boxes.last.value, isFalse, reason: 'the ignored sibling');
    });

    testWidgets('a cautioned folder can still be ticked deliberately',
        (tester) async {
      // The archive is already downloaded, so refusing outright would hide a
      // mod the user may well want now.
      final answers = await openGroup(
        tester,
        siblings: [target('Ellen Blue', caution: SiblingCaution.holdsNewer)],
      );

      await tester.tap(find.text('Ellen Blue'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Update 2 mods'));
      await tester.pumpAndSettle();

      expect(answers.single.accepted, {'Ellen', 'Ellen Blue'});
    });

    testWidgets('a member that is not offered says why', (tester) async {
      await openGroup(
        tester,
        siblings: [target('Ellen Blue')],
        refused: [
          SiblingRefused(
            mod: sibling('Ellen Red'),
            reason: SiblingRefusal.alreadyCurrent,
          ),
        ],
      );

      expect(find.textContaining('already has this version'), findsOneWidget);
      expect(find.text('Update 2 mods'), findsOneWidget,
          reason: 'the refused one is not one of the two being written');
    });

    testWidgets('a blocked primary does not take its siblings down with it',
        (tester) async {
      // The mod the user pressed the button on cannot be reconciled with the
      // archive, and the sibling can. Refusing both would waste a download that
      // is already on disk and is correct for one of them.
      await openGroup(
        tester,
        primary: preview(problem: UpdateLayoutProblem.layoutChanged),
        siblings: [target('Ellen Blue')],
      );

      expect(find.text('Update Ellen Blue?'), findsOneWidget,
          reason: 'the headline names the mod that is actually changing');
      expect(find.textContaining('no longer matches'), findsNothing);
    });

    testWidgets('nothing writable is the refusing state, and only that',
        (tester) async {
      await openGroup(
        tester,
        primary: preview(problem: UpdateLayoutProblem.layoutChanged),
        siblings: [
          target('Ellen Blue', problem: UpdateLayoutProblem.layoutChanged),
        ],
      );

      expect(find.textContaining('no longer matches'), findsOneWidget);
      expect(find.byType(FilledButton), findsNothing);
    });

    testWidgets('a contested primary is refused like any other member',
        (tester) async {
      // Two of the user's mods recorded the same folder of this archive. Being
      // the one they pressed the button on is not evidence of which it became.
      //
      // **The refused list is the only channel for this**, and that is the
      // point: the primary's own preview cannot carry a refusal that needs two
      // folders to see, and a second parameter carrying it is one a caller can
      // forget — which is exactly how the folder got written anyway.
      await openGroup(
        tester,
        refused: [
          SiblingRefused(mod: mod, reason: SiblingRefusal.sourceCollision),
        ],
      );

      expect(find.textContaining('the same folder'), findsOneWidget);
      expect(find.byType(FilledButton), findsNothing,
          reason: 'listing the primary as refused must make it unwritable');
    });

    testWidgets('a contested primary is not offered alongside a clear sibling',
        (tester) async {
      // The sibling proceeds; the contested primary must not be ticked beside
      // it just because its own folder looks fine from where it stands.
      await openGroup(
        tester,
        siblings: [target('Ellen Blue')],
        refused: [
          SiblingRefused(mod: mod, reason: SiblingRefusal.sourceCollision),
        ],
      );

      expect(find.text('Update Ellen Blue?'), findsOneWidget);
      final boxes = tester.widgetList<CheckboxListTile>(
        find.byType(CheckboxListTile),
      );
      expect(boxes.length, 1, reason: 'only the sibling is writable');
    });

    testWidgets('the leftover question is asked once for the whole group',
        (tester) async {
      await openGroup(
        tester,
        primary: preview(
          stale: const [StaleIni(path: 'ellen_old.ini', sharedResources: 3)],
        ),
        siblings: [
          target('Ellen Blue', stale: const [
            StaleIni(path: 'blue_old.ini', sharedResources: 3),
          ]),
        ],
      );

      // One checkbox for the leftovers, naming the folders rather than the
      // files: the same filename in two mods is two files.
      expect(find.textContaining('Remove 2 leftover .ini files from'),
          findsOneWidget);
      expect(find.textContaining('Ellen, Ellen Blue'), findsOneWidget);
    });

    testWidgets('unticking a folder takes its leftovers out of the count',
        (tester) async {
      await openGroup(
        tester,
        primary: preview(
          stale: const [StaleIni(path: 'ellen_old.ini', sharedResources: 3)],
        ),
        siblings: [
          target('Ellen Blue', stale: const [
            StaleIni(path: 'blue_old.ini', sharedResources: 3),
          ]),
        ],
      );

      await tester.tap(find.text('Ellen Blue'));
      await tester.pumpAndSettle();

      // Down to one folder, so it names the file again.
      expect(find.textContaining('ellen_old.ini'), findsOneWidget);
    });

    testWidgets('a folder nothing writes is named as exactly that',
        (tester) async {
      // Two wordings this must not use. The single-mod one calls it "not part
      // of this mod", which for a group describes another of the user's mods —
      // and "belongs to no mod of yours" is false for a refused member's
      // folder, which this list also contains. What is true of every entry is
      // that nothing being written is that folder.
      await openGroup(
        tester,
        siblings: [target('Ellen Blue')],
        otherFolders: const ['previews'],
      );

      expect(find.textContaining("won't be installed"), findsOneWidget);
      expect(find.textContaining("isn't part of this mod"), findsNothing);
      expect(find.textContaining('belong to no mod'), findsNothing);
    });

    testWidgets('a refused member\'s folder is not called nobody\'s',
        (tester) async {
      // The same screen says "Ellen Blue — already has this version" two
      // sections above, so claiming its folder belongs to no mod of theirs
      // contradicts it.
      await openGroup(
        tester,
        refused: [
          SiblingRefused(
            mod: sibling('Ellen Blue'),
            reason: SiblingRefusal.alreadyCurrent,
          ),
        ],
        otherFolders: const ['Ellen Blue'],
      );

      expect(find.textContaining('already has this version'), findsOneWidget);
      expect(find.textContaining('belong to no mod'), findsNothing);
    });

    testWidgets('a patch it cannot put back names which folders', (tester) async {
      await openGroup(
        tester,
        siblings: [target('Ellen Blue', flattensPatch: true)],
      );

      expect(find.textContaining('Ellen Blue hold a patch'), findsOneWidget);
    });

    testWidgets('it fits the narrowest window with four folders showing',
        (tester) async {
      await openGroup(
        tester,
        primary: preview(
          stale: const [StaleIni(path: 'ellen_old.ini', sharedResources: 3)],
        ),
        siblings: [
          target('Ellen Blue with a very long folder name',
              missing: const ['body.dds']),
          target('Ellen Red', flattensPatch: true),
          target('Ellen Green', stale: const [
            StaleIni(path: 'green_old.ini', sharedResources: 3),
          ]),
        ],
        refused: [
          SiblingRefused(
            mod: sibling('Ellen Gold'),
            reason: SiblingRefusal.sourceCollision,
          ),
        ],
        otherFolders: const ['previews'],
        surfaceSize: const Size(480, 900),
      );

      expect(tester.takeException(), isNull);
    });
  });
}
