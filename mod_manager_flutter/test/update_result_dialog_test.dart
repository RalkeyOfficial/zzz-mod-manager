import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_file.dart';
import 'package:mod_manager_flutter/screens/dialogs/update_result_dialog.dart';
import 'package:mod_manager_flutter/services/update_apply/keybind_changes.dart';
import 'package:mod_manager_flutter/services/update_apply/update_applier.dart';

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
}
