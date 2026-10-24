import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/screens/components/settings/folders_section.dart';
import 'package:mod_manager_flutter/services/api_service.dart';
import 'package:mod_manager_flutter/services/platform_service.dart';
import 'package:mod_manager_flutter/services/platform_service_windows.dart';
import 'package:mod_manager_flutter/utils/notifications.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';
import 'package:path/path.dart' as p;

import 'support/fake_windows_link_calls.dart';
import 'support/localized_harness.dart';
import 'support/temp_library.dart';

/// **Changing the folders in Settings.** A pick applies at once. The Mod library can't be ZZMI's Mods folder, and a
/// library change that leaves some links behind names those mods.
void main() {
  late TempLibrary temp;
  late ProviderContainer container;

  Future<void> pumpFolders(WidgetTester tester, {required String Function() pick, PlatformService? platform}) async {
    await tester.runAsync(() async {
      temp = await TempLibrary.create(prefix: 'zzz_settings_save_', platform: platform);
      // The real lookup runs a process with a timeout, which a widget test's clock leaves pending.
      container = ProviderContainer(overrides: [
        ...temp.overrides,
        libraryFreeSpaceProvider.overrideWith((ref) async => 212 * 1024 * 1024 * 1024),
      ]);
      await ApiService.initialize(container: container);
    });
    addTearDown(container.dispose);
    await pumpLocalized(
      tester,
      FoldersSection(picker: () async => pick()),
      container: container,
    );
    expectBuilt(FoldersSection);
  }

  /// The library row's Change button: the second, under the ZZMI folder's.
  Finder changeLibrary() => find.widgetWithText(OutlinedButton, 'Change').last;

  testWidgets('shows both folders and what the ZZMI folder holds', (tester) async {
    await pumpFolders(tester, pick: () => '');
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();

    expect(find.text('ZZMI folder'), findsOneWidget);
    expect(find.text('Mod library'), findsOneWidget);
    expect(container.read(modsPathProvider), temp.mods.path);
    expect(find.byType(OutlinedButton), findsNWidgets(2));
    expect(find.text('Open'), findsOneWidget, reason: 'the library can be opened, and only it');
    expect(find.textContaining('free on this drive'), findsOneWidget);
  });

  test('a folder holding d3dx.ini is looked up as ZZMI, and one without is not', () async {
    final zzmi = Directory.systemTemp.createTempSync('zzz_settings_places_');
    addTearDown(() => zzmi.deleteSync(recursive: true));
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(zzmiPathProvider.notifier).state = zzmi.path;
    final held = container.listen(zzmiPlacesProvider, (_, _) {});
    addTearDown(held.close);

    expect(await container.read(zzmiPlacesProvider.future), isNull, reason: 'no d3dx.ini yet');

    File(p.join(zzmi.path, 'd3dx.ini')).writeAsStringSync('[Rendering]\noverride_directory = ShaderFixes\n');
    container.invalidate(zzmiPlacesProvider);
    final places = await container.read(zzmiPlacesProvider.future);
    expect(places, isNotNull);
    expect(places!.shaders, endsWith('ShaderFixes'));
  });

  group('the ZZMI row', () {
    Future<void> pumpRow(WidgetTester tester, {required bool found, String zzmi = '/home/al/Games/XXMI/ZZMI'}) async {
      final container = ProviderContainer(overrides: [
        zzmiPlacesProvider.overrideWith((ref) async => found ? (links: '$zzmi/Mods', shaders: '$zzmi/ShaderFixes') : null),
        libraryFreeSpaceProvider.overrideWith((ref) async => null),
      ]);
      addTearDown(container.dispose);
      container.read(zzmiPathProvider.notifier).state = zzmi;
      await pumpLocalized(tester, const FoldersSection(), container: container);
    }

    testWidgets('says the folder is found when d3dx.ini is there', (tester) async {
      await pumpRow(tester, found: true);

      expect(find.text('d3dx.ini and Mods folder found'), findsOneWidget);
      expect(find.textContaining("doesn't look like ZZMI"), findsNothing);
    });

    testWidgets('warns when it is not', (tester) async {
      await pumpRow(tester, found: false);

      expect(find.text('d3dx.ini and Mods folder found'), findsNothing);
      expect(find.textContaining("doesn't look like ZZMI"), findsOneWidget);
    });

    testWidgets('asks for a folder when none is chosen', (tester) async {
      await pumpRow(tester, found: false, zzmi: '');

      expect(find.text('No ZZMI folder chosen.'), findsOneWidget);
    });
  });

  testWidgets('ZZMI\'s Mods folder as the Mod library is refused with a reason, and not saved', (tester) async {
    await pumpFolders(tester, pick: () => temp.saveMods.path);

    await tapWithIo(tester, changeLibrary());

    expect(find.text("That folder can't be the Mod library"), findsOneWidget);
    expect(find.textContaining("is ZZMI's Mods folder"), findsOneWidget);
    expect(temp.config.modsPath, temp.mods.path);
    expect(container.read(modsPathProvider), temp.mods.path);
  });

  testWidgets('a picked library is saved at once, with nothing to confirm', (tester) async {
    final newRoot = p.join(Directory.systemTemp.path, 'zzz_settings_pick_${DateTime.now().microsecondsSinceEpoch}');
    await pumpFolders(tester, pick: () => newRoot);
    await tester.runAsync(() async => Directory(newRoot).createSync(recursive: true));
    addTearDown(() => Directory(newRoot).deleteSync(recursive: true));

    await tapWithIo(tester, changeLibrary());

    expect(temp.config.modsPath, newRoot);
    expect(container.read(modsPathProvider), newRoot);
    expect(container.read(notificationsProvider), isEmpty, reason: 'a change on screen reports only its failure');
  });

  /// The ZZMI row's Change button, the first of the two.
  Finder changeZzmi() => find.widgetWithText(OutlinedButton, 'Change').first;

  testWidgets('picking the XXMI Launcher folder saves the ZZMI folder inside it', (tester) async {
    final launcher = p.join(Directory.systemTemp.path, 'zzz_settings_xxmi_${DateTime.now().microsecondsSinceEpoch}');
    await pumpFolders(tester, pick: () => launcher);
    await tester.runAsync(() async {
      File(p.join(launcher, 'ZZMI', 'd3dx.ini')).createSync(recursive: true);
    });
    addTearDown(() => Directory(launcher).deleteSync(recursive: true));

    await tapWithIo(tester, changeZzmi());

    expect(temp.config.zzmiPath, p.join(launcher, 'ZZMI'));
    expect(container.read(zzmiPathProvider), p.join(launcher, 'ZZMI'));
  });

  testWidgets('a folder that is not ZZMI is saved as picked, and the row says there is no d3dx.ini', (tester) async {
    final folder = p.join(Directory.systemTemp.path, 'zzz_settings_notzzmi_${DateTime.now().microsecondsSinceEpoch}');
    await pumpFolders(tester, pick: () => folder);
    await tester.runAsync(() async => Directory(folder).createSync(recursive: true));
    addTearDown(() => Directory(folder).deleteSync(recursive: true));

    await tapWithIo(tester, changeZzmi());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();

    expect(temp.config.zzmiPath, folder);
    expect(find.textContaining("doesn't look like ZZMI"), findsOneWidget);
    expect(find.text('d3dx.ini and Mods folder found'), findsNothing);
  });

  testWidgets('a ZZMI folder that would hold the Mod library is refused, and the old one stays', (tester) async {
    // The library inside the new ZZMI's Mods folder would be loaded by ZZMI, on or off.
    await pumpFolders(tester, pick: () => temp.mods.path);
    final zzmiBefore = temp.config.zzmiPath;
    await tester.runAsync(() async => File(p.join(temp.mods.path, 'd3dx.ini')).createSync());
    await tester.runAsync(() async => Directory(p.join(temp.mods.path, 'Mods')).createSync());

    await tapWithIo(tester, changeZzmi());

    expect(find.text("That folder can't be the Mod library"), findsOneWidget);
    expect(temp.config.zzmiPath, zzmiBefore);
  });

  testWidgets('mods whose links could not follow are counted in the title and named in the body', (tester) async {
    final newRoot = p.join(Directory.systemTemp.path, 'zzz_settings_moved_${DateTime.now().microsecondsSinceEpoch}');
    await pumpFolders(tester, pick: () => newRoot);
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
    addTearDown(() async {
      await Process.run('chmod', ['755', p.join(newRoot, 'Lucy')]);
      Directory(newRoot).deleteSync(recursive: true);
    });
    try {
      Directory(p.join(newRoot, 'Lucy')).listSync();
      markTestSkipped('chmod does not stop reads for this user');
      return;
    } on FileSystemException {
      // Unreadable, as the test needs.
    }

    await tapWithIo(tester, changeLibrary());

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
    final newRoot = p.join(Directory.systemTemp.path, 'zzz_settings_moved_${DateTime.now().microsecondsSinceEpoch}');
    await pumpFolders(tester, pick: () => newRoot, platform: WindowsPlatformService(calls: calls));
    final link = p.join(temp.saveMods.path, 'Ellen');
    await tester.runAsync(() async {
      temp.write('Ellen', 'Ellen.ini', '[TextureOverrideBody]\nps-t0 = R\n');
      Directory(p.join(newRoot, 'Ellen')).createSync(recursive: true);
      // Listed from the disk, and a link to the fake.
      Directory(link).createSync();
      calls.links[link] = (kind: 'junction', target: p.join(temp.mods.path, 'Ellen'));
    });
    addTearDown(() => Directory(newRoot).deleteSync(recursive: true));

    await tapWithIo(tester, changeLibrary());

    expect(find.text("Couldn't link to a network folder"), findsOneWidget);
    expect(
      find.text('Ellen: a mod on a network folder can only be turned on with Windows Developer Mode on.'),
      findsOneWidget,
    );
    expect(find.textContaining("couldn't be linked to the new library folder"), findsNothing);
    expect(calls.links[link]?.kind, 'junction');
  });
}
