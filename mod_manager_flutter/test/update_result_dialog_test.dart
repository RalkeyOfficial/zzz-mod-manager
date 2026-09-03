import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_file.dart';
import 'package:mod_manager_flutter/screens/dialogs/update_result_dialog.dart';
import 'package:mod_manager_flutter/services/update_apply/keybind_changes.dart';
import 'package:mod_manager_flutter/services/update_apply/update_applier.dart';
import 'package:mod_manager_flutter/services/update_apply/update_target.dart';

import 'support/localized_harness.dart';

/// The dialog that reports what an update did.
///
/// It exists to answer three separate questions — what landed, what you lost,
/// how to undo it — and its first version ran them together into a paragraph
/// and a bare list, which read as a pile of facts. What is pinned here is that
/// each is headed, and that the "what you lost" block is **absent** when
/// nothing was lost.
void main() {
  final mod = ModInfo(
    id: 'Ellen',
    name: 'Ellen',
    characterId: 'ellen',
    isActive: false,
  );
  const file = GbFile(idRow: 42, file: 'ellen_v2.zip');

  UpdateApplyResult result({
    List<KeybindChange> changes = const [],
    List<String> removed = const [],
    bool reactivated = false,
  }) =>
      UpdateApplyResult(
        snapshot: null,
        filesWritten: 12,
        removedInis: removed,
        keybindChanges: changes,
        reactivated: reactivated,
      );

  Future<void> open(
    WidgetTester tester,
    UpdateApplyResult value, {
    Size surfaceSize = const Size(1200, 800),
    bool reinstall = false,
  }) async {
    await pumpLocalized(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => showUpdateResultDialog(
            context,
            mod: mod,
            file: file,
            result: value,
            reinstall: reinstall,
          ),
          child: const Text('open'),
        ),
      ),
      surfaceSize: surfaceSize,
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expectBuilt(AlertDialog);
  }

  testWidgets('it heads what changed, and always offers the way back',
      (tester) async {
    await open(tester, result());
    expect(find.text('What changed'), findsOneWidget);
    expect(find.textContaining('Restore a previous version'), findsOneWidget);
  });

  testWidgets('a repair says the mod was reinstalled', (tester) async {
    // Nothing was updated — the version on disk is the version that went on —
    // and the headline is the only place that can say which act this was.
    await open(tester, result(), reinstall: true);
    expect(find.text('Ellen reinstalled'), findsOneWidget);
    expect(find.text('Ellen updated'), findsNothing);
  });

  testWidgets('no hotkey moved means no hotkey section at all', (tester) async {
    // The common case, and the reason this is a diff rather than an inventory:
    // a section that appears every time is one people learn to skip.
    await open(tester, result());
    expect(find.textContaining('hotkey'), findsNothing);
    expect(find.textContaining('hotkeys'), findsNothing);
  });

  testWidgets('a moved hotkey is a headed section with before and after',
      (tester) async {
    await open(
      tester,
      result(
        changes: const [
          KeybindChange(
            section: 'KeySkin',
            displayName: 'Skin',
            before: 'F7',
            after: 'F9',
            kind: KeybindChangeKind.rebound,
          ),
        ],
      ),
    );
    expect(find.text('1 hotkey changed'), findsOneWidget);
    // The explanation is the whole point of the section: a bare list of keys
    // told the reader nothing about why they were looking at it.
    expect(find.textContaining('Nothing was carried over'), findsOneWidget);
    expect(find.text('Skin'), findsOneWidget);
    expect(find.text('F7'), findsOneWidget);
    expect(find.text('F9'), findsOneWidget);
  });

  testWidgets('a dropped hotkey says so rather than showing a blank',
      (tester) async {
    await open(
      tester,
      result(
        changes: const [
          KeybindChange(
            section: 'KeyGlow',
            displayName: 'Glow',
            before: 'F8',
            kind: KeybindChangeKind.removed,
          ),
        ],
      ),
    );
    expect(find.text('gone'), findsOneWidget);
  });

  testWidgets('it fits the narrowest window with every section showing',
      (tester) async {
    await open(
      tester,
      result(
        removed: const ['a_very_long_leftover_name.ini'],
        reactivated: true,
        changes: const [
          KeybindChange(
            section: 'KeySkin',
            displayName: 'Skin',
            before: 'ctrl alt F7',
            after: 'ctrl alt shift F9',
            kind: KeybindChangeKind.rebound,
          ),
        ],
      ),
      surfaceSize: const Size(480, 900),
    );
    expect(tester.takeException(), isNull);
  });

  /// **One download written into several folders**, reported per folder.
  ///
  /// A group write is not all-or-nothing — each folder has its own snapshot and
  /// its own copy — so which ones landed is the report, and a total could not
  /// say it.
  group('one archive written into several folders', () {
    Future<void> openGroup(
      WidgetTester tester,
      List<AppliedUpdate> others, {
      Size surfaceSize = const Size(1200, 900),
    }) async {
      await pumpLocalized(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showUpdateResultDialog(
              context,
              mod: mod,
              file: file,
              result: result(),
              others: others,
            ),
            child: const Text('open'),
          ),
        ),
        surfaceSize: surfaceSize,
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    ModInfo other(String id) =>
        ModInfo(id: id, name: id, characterId: 'ellen', isActive: false);

    testWidgets('counts them and names each folder', (tester) async {
      await openGroup(tester, [
        AppliedUpdate(mod: other('Ellen Blue'), result: result()),
        AppliedUpdate(mod: other('Ellen Red'), result: result()),
      ]);
      expectBuilt(AlertDialog);

      expect(find.text('3 mods updated'), findsOneWidget);
      expect(find.text('Ellen'), findsOneWidget);
      expect(find.text('Ellen Blue'), findsOneWidget);
      expect(find.text('Ellen Red'), findsOneWidget);
    });

    testWidgets('a folder that failed is named and counted out',
        (tester) async {
      await openGroup(tester, [
        AppliedUpdate(
          mod: other('Ellen Blue'),
          result: const UpdateApplyResult(
            snapshot: null,
            filesWritten: 0,
            removedInis: [],
            keybindChanges: [],
            reactivated: false,
            failure: UpdateApplyFailure.copy,
          ),
        ),
      ]);

      expect(find.text('1 mod updated'), findsOneWidget,
          reason: 'one of the two landed, and the count says which happened');
      expect(find.text('Ellen Blue'), findsOneWidget);
      expect(find.text('The update failed part-way'), findsOneWidget);
      // Every fact in the ordinary block describes a write that landed, so a
      // failure showing "0 files written" would read as a successful no-op.
      expect(find.text('0 file(s) copied into the mod folder'), findsNothing);
    });

    testWidgets('every folder failing does not report a success',
        (tester) async {
      // The one case the headline can be wrong in: a single failure goes out as
      // a notification and never reaches this dialog, so a group is the only
      // way to get here with nothing written. `_modBlock` is careful not to
      // print "0 files written" beside a failure; a tick over "0 mods updated"
      // would undo that.
      await pumpLocalized(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showUpdateResultDialog(
              context,
              mod: mod,
              file: file,
              result: const UpdateApplyResult(
                snapshot: null,
                filesWritten: 0,
                removedInis: [],
                keybindChanges: [],
                reactivated: false,
                failure: UpdateApplyFailure.snapshot,
              ),
              others: [
                AppliedUpdate(
                  mod: other('Ellen Blue'),
                  result: const UpdateApplyResult(
                    snapshot: null,
                    filesWritten: 0,
                    removedInis: [],
                    keybindChanges: [],
                    reactivated: false,
                    failure: UpdateApplyFailure.copy,
                  ),
                ),
              ],
            ),
            child: const Text('open'),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('Nothing was updated'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle_outline), findsNothing);
      expect(find.byIcon(Icons.error_outline), findsWidgets);
    });

    testWidgets('each folder keeps its own hotkey diff', (tester) async {
      // The one place the update path's accepted loss becomes visible, so it is
      // per folder rather than summarised: the keys that changed in one mod are
      // not the keys that changed in another.
      await openGroup(tester, [
        AppliedUpdate(
          mod: other('Ellen Blue'),
          result: result(changes: const [
            KeybindChange(
              section: 'KeySkin',
              displayName: 'Blue skin',
              before: 'F7',
              after: 'F9',
              kind: KeybindChangeKind.rebound,
            ),
          ]),
        ),
      ]);

      expect(find.text('Blue skin'), findsOneWidget);
      expect(find.text('1 hotkey changed'), findsOneWidget);
    });

    testWidgets('the way back is stated once, not per folder', (tester) async {
      await openGroup(tester, [
        AppliedUpdate(mod: other('Ellen Blue'), result: result()),
        AppliedUpdate(mod: other('Ellen Red'), result: result()),
      ]);

      expect(find.textContaining('Restore a previous version'), findsOneWidget);
    });

    testWidgets('it fits the narrowest window with four folders showing',
        (tester) async {
      await openGroup(
        tester,
        [
          AppliedUpdate(
            mod: other('Ellen Blue with a very long folder name'),
            result: result(
              removed: const ['a_very_long_leftover_name.ini'],
              reactivated: true,
            ),
          ),
          AppliedUpdate(mod: other('Ellen Red'), result: result()),
          AppliedUpdate(
            mod: other('Ellen Green'),
            result: const UpdateApplyResult(
              snapshot: null,
              filesWritten: 0,
              removedInis: [],
              keybindChanges: [],
              reactivated: false,
              failure: UpdateApplyFailure.snapshot,
            ),
          ),
        ],
        surfaceSize: const Size(480, 900),
      );

      expect(tester.takeException(), isNull);
    });
  });
}
