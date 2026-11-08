import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/core/palette.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/installed_file.dart';
import 'package:mod_manager_flutter/models/mod_download.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/screens/components/zenith_menu.dart';
import 'package:mod_manager_flutter/screens/dialogs/mod_context_menu.dart';

import 'support/localized_harness.dart';
import 'support/origin_shorthand.dart';

/// What a mod's right-click menu lists in each state, what its header says, and that its keys reach the mod.
void main() {
  late List<String> ran;

  ModMenuActions actions({bool withMakePatch = false}) => ModMenuActions(
    toggle: () => ran.add('toggle'),
    toggleFavorite: () => ran.add('favorite'),
    edit: () => ran.add('edit'),
    openFolder: () => ran.add('folder'),
    checkForUpdate: () => ran.add('check'),
    reinstall: () => ran.add('reinstall'),
    updateTracking: () => ran.add('tracking'),
    removePatch: (patch) => ran.add('remove ${patch.modId}'),
    delete: () => ran.add('delete'),
    makePatch: withMakePatch ? () => ran.add('make patch') : null,
  );

  ModInfo mod({bool active = false, bool favorite = false, ModOrigin? origin, String characterId = 'ellen'}) => ModInfo(
    id: 'Winter Maid',
    name: 'Winter Maid',
    characterId: characterId,
    isActive: active,
    isFavorite: favorite,
    origin: origin,
  );

  Future<void> open(
    WidgetTester tester,
    ModInfo mod, {
    bool withMakePatch = false,
    Map<int, String> patchNames = const {},
    Brightness brightness = Brightness.dark,
  }) async {
    ran = [];
    await pumpLocalized(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => showModContextMenu(context, mod, const Offset(200, 100), actions(withMakePatch: withMakePatch), patchNames: patchNames),
          child: const Text('open'),
        ),
      ),
      brightness: brightness,
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expectBuilt(ZenithMenuSurface);
  }

  List<String> labels(WidgetTester tester) => [
    for (final row in tester.widgetList<ZenithMenuRow>(find.byType(ZenithMenuRow))) row.label,
  ];

  ModOrigin tracked({int? fileId = 10, OriginTracking tracking = OriginTracking.auto, List<ModDownload> patches = const []}) => originFixture(
    modId: 100,
    modIdConfidence: OriginConfidence.exact,
    fileId: fileId,
    versionConfidence: OriginConfidence.exact,
    tracking: tracking,
    patches: patches,
  );

  testWidgets('a tracked mod that is on and a favourite lists the canvas entries in its order', (tester) async {
    await open(tester, mod(active: true, favorite: true, origin: tracked()), withMakePatch: true);

    expect(labels(tester), [
      'Turn off',
      'Remove from favorites',
      'Edit info…',
      'Open in file explorer',
      'Check for updates',
      'Reinstall this file…',
      'Update tracking…',
      'Make this a patch for…',
      'Delete…',
    ]);
    expect(find.text('Ellen Joe · tracked on GameBanana'), findsOneWidget);
    for (final shortcut in ['Space', 'F', 'E', 'Del']) {
      expect(find.text(shortcut), findsOneWidget);
    }
  });

  testWidgets('a mod that is off and not a favourite says Turn on and Add to favorites', (tester) async {
    await open(tester, mod());

    expect(labels(tester).take(2), ['Turn on', 'Add to favorites']);
    expect(find.text('Ellen Joe · Not tracked'), findsOneWidget);
  });

  testWidgets('a mod tracking is switched off for is Local, and has nothing to check', (tester) async {
    await open(tester, mod(origin: tracked(tracking: OriginTracking.off)));

    expect(find.text('Ellen Joe · Local'), findsOneWidget);
    expect(labels(tester), isNot(contains('Reinstall this file…')));
  });

  testWidgets('Check for updates needs a remote identity, and Reinstall a recorded file', (tester) async {
    await open(tester, mod(origin: tracked(fileId: null)));

    expect(labels(tester), contains('Check for updates'));
    expect(labels(tester), isNot(contains('Reinstall this file…')));
  });

  testWidgets('Make this a patch for… is absent until its flow is wired', (tester) async {
    await open(tester, mod());

    expect(labels(tester), isNot(contains('Make this a patch for…')));
  });

  group('Remove patch', () {
    InstalledFile added(String path) => InstalledFile(path: path, role: InstalledFileRole.added);

    testWidgets('one patch is one plain entry that removes it', (tester) async {
      await open(tester, mod(origin: tracked(patches: [patchFixture(modId: 1001, files: [added('a.dds')])])), withMakePatch: true);

      final all = labels(tester);
      expect(all, contains('Remove patch…'));
      expect(all.indexOf('Remove patch…'), all.indexOf('Make this a patch for…') + 1, reason: 'after Make this a patch');
      await tester.tap(find.text('Remove patch…'));
      await tester.pumpAndSettle();
      expect(ran, ['remove 1001']);
    });

    testWidgets('several are named, by the page when the session has it and by id when not', (tester) async {
      final origin = tracked(patches: [
        patchFixture(modId: 1001, files: [added('a.dds')]),
        patchFixture(modId: 1002, files: [added('b.dds')]),
      ]);
      await open(tester, mod(origin: origin), patchNames: {1001: 'Ellen Fix'});

      expect(find.text('Remove patch: Ellen Fix'), findsOneWidget);
      expect(find.text('Remove patch: #1002'), findsOneWidget);
    });
  });

  testWidgets('nothing the canvas moved elsewhere is in the menu', (tester) async {
    await open(
      tester,
      mod(active: true, origin: tracked(patches: [patchFixture(modId: 1001, files: [InstalledFile(path: 'a', role: InstalledFileRole.added)])])),
      withMakePatch: true,
    );

    for (final gone in ['Details', 'Edit', 'Rename', 'Open source page', 'Restore a previous version…']) {
      expect(labels(tester), isNot(contains(gone)));
    }
    expect(labels(tester).where((l) => l.startsWith('Edit keybinds')), isEmpty);
  });

  testWidgets('Delete is in redText, in either theme', (tester) async {
    for (final brightness in Brightness.values) {
      await open(tester, mod(), brightness: brightness);
      final palette = ZenithPalette.forBrightness(brightness, AccentChoice.violet);

      expect(tester.widget<Text>(find.text('Delete…')).style!.color, palette.redText);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
    }
  });

  group('the keys reach the mod', () {
    for (final (key, name, expected) in [
      (LogicalKeyboardKey.space, 'Space', 'toggle'),
      (LogicalKeyboardKey.keyF, 'F', 'favorite'),
      (LogicalKeyboardKey.keyE, 'E', 'edit'),
      (LogicalKeyboardKey.delete, 'Del', 'delete'),
    ]) {
      testWidgets('$name runs $expected', (tester) async {
        await open(tester, mod());
        await tester.sendKeyEvent(key);
        await tester.pumpAndSettle();

        expect(ran, [expected]);
      });
    }

    testWidgets('a row press runs its entry', (tester) async {
      await open(tester, mod(origin: tracked()));
      await tester.tap(find.text('Update tracking…'));
      await tester.pumpAndSettle();

      expect(ran, ['tracking']);
    });
  });
}
