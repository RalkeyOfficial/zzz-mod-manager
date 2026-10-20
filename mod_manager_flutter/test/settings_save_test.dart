import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/screens/settings_screen.dart';
import 'package:mod_manager_flutter/services/api_service.dart';
import 'package:mod_manager_flutter/services/platform_service.dart';
import 'package:mod_manager_flutter/services/platform_service_windows.dart';
import 'package:path/path.dart' as p;

import 'support/fake_windows_link_calls.dart';
import 'support/localized_harness.dart';
import 'support/temp_library.dart';

/// **Saving the paths in Settings.** The Mod library can't be ZZMI's Mods folder, and a library change that leaves
/// some links behind names those mods.
void main() {
  late TempLibrary temp;
  late ProviderContainer container;

  Future<void> pumpSettings(WidgetTester tester, {PlatformService? platform}) async {
    await tester.runAsync(() async {
      temp = await TempLibrary.create(prefix: 'zzz_settings_save_', platform: platform);
      container = ProviderContainer(overrides: temp.overrides);
      await ApiService.initialize(container: container);
    });
    addTearDown(container.dispose);
    await pumpLocalized(tester, const SettingsScreen(), container: container, settle: false);
    // The config is read from disk once the page is up.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump(const Duration(seconds: 1));
    expectBuilt(SettingsScreen);
  }

  Finder libraryField() => find.byWidgetPredicate((w) => w is TextField && w.controller?.text == temp.mods.path);

  /// Presses Save through the button's own handler: the staggered entrance leaves it where a tap misses it.
  Future<void> save(WidgetTester tester) async {
    final button = tester.widget<ButtonStyleButton>(
      find.ancestor(of: find.text('Save configuration'), matching: find.byWidgetPredicate((w) => w is ButtonStyleButton)),
    );
    await tester.runAsync(() async {
      button.onPressed!();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets('ZZMI\'s Mods folder as the Mod library is refused with a reason, and not saved', (tester) async {
    await pumpSettings(tester);
    expect(libraryField(), findsOneWidget);
    await tester.enterText(libraryField(), temp.saveMods.path);

    await save(tester);

    expect(find.text("That folder can't be the Mod library"), findsOneWidget);
    expect(find.textContaining("is ZZMI's Mods folder"), findsOneWidget);
    expect(temp.config.modsPath, temp.mods.path);
  });

  testWidgets('mods whose links could not follow are counted in the title and named in the body', (tester) async {
    await pumpSettings(tester);
    final newRoot = p.join(temp.root.path, 'moved');
    await tester.runAsync(() async {
      for (final name in ['Ellen', 'Lucy']) {
        temp.write(name, '$name.ini', '[TextureOverrideBody]\nps-t0 = R\n');
        await temp.service.activateMod(name);
        File(p.join(newRoot, name, '$name.ini'))
          ..createSync(recursive: true)
          ..writeAsStringSync('[TextureOverrideBody]\nps-t0 = R\n');
      }
      await Process.run('chmod', ['000', p.join(newRoot, 'Lucy')]);
    });
    addTearDown(() => Process.run('chmod', ['755', p.join(newRoot, 'Lucy')]));
    try {
      Directory(p.join(newRoot, 'Lucy')).listSync();
      markTestSkipped('chmod does not stop reads for this user');
      return;
    } on FileSystemException {
      // Unreadable, as the test needs.
    }
    await tester.enterText(libraryField(), newRoot);

    await save(tester);

    expect(find.text("1 mod couldn't be linked to the new library folder"), findsOneWidget);
    expect(find.text('Lucy'), findsOneWidget);
    expect(temp.config.modsPath, newRoot);
  });

  testWidgets('a mod Windows can only link to a network library with Developer Mode is told so, and named only there',
      (tester) async {
    // No Developer Mode, and only the new library is on the network.
    final calls = FakeWindowsLinkCalls()
      ..symlinks = false
      ..onNetwork = ((path) => path.contains('moved'));
    await pumpSettings(tester, platform: WindowsPlatformService(calls: calls));
    final newRoot = p.join(temp.root.path, 'moved');
    final link = p.join(temp.saveMods.path, 'Ellen');
    await tester.runAsync(() async {
      temp.write('Ellen', 'Ellen.ini', '[TextureOverrideBody]\nps-t0 = R\n');
      Directory(p.join(newRoot, 'Ellen')).createSync(recursive: true);
      // Listed from the disk, and a link to the fake.
      Directory(link).createSync();
      calls.links[link] = (kind: 'junction', target: p.join(temp.mods.path, 'Ellen'));
    });
    await tester.enterText(libraryField(), newRoot);

    await save(tester);

    expect(find.text("Couldn't link to a network folder"), findsOneWidget);
    expect(
      find.text('Ellen: a mod on a network folder can only be turned on with Windows Developer Mode on.'),
      findsOneWidget,
    );
    expect(find.textContaining("couldn't be linked to the new library folder"), findsNothing);
    expect(calls.links[link]?.kind, 'junction');
  });
}
