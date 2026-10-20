import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/screens/components/notification_overlay.dart';
import 'package:mod_manager_flutter/screens/components/zenith_switch.dart';
import 'package:mod_manager_flutter/services/api_service.dart';
import 'package:mod_manager_flutter/services/platform_service.dart';
import 'package:mod_manager_flutter/services/platform_service_windows.dart';
import 'package:mod_manager_flutter/utils/notifications.dart';
import 'package:path/path.dart' as p;

import 'support/all_mods_harness.dart';
import 'support/fake_windows_link_calls.dart';
import 'support/localized_harness.dart';
import 'support/mods_screen_harness.dart';
import 'support/temp_library.dart';

/// **A mod on a network folder, on Windows without Developer Mode, stays off and the user is told why.** The app's
/// fallback, a junction, leads only to a local folder, so the link is refused rather than made dead, and every place
/// that turns a mod on says that Developer Mode is what it takes (`docs/app-architecture.md`).
void main() {
  const title = "Couldn't link to a network folder";
  String body(String mods) => '$mods: a mod on a network folder can only be turned on with Windows Developer Mode on.';

  late FakeWindowsLinkCalls calls;
  late TempLibrary temp;

  setUp(() async {
    // No Developer Mode, and the whole temp library reads as a mapped network drive.
    calls = FakeWindowsLinkCalls()
      ..symlinks = false
      ..onNetwork = ((_) => true);
    temp = await TempLibrary.create(prefix: 'zzz_network_link_', platform: WindowsPlatformService(calls: calls));
  });

  void installMod(String name, {Map<String, String> shaders = const {}}) {
    temp.createMod(name);
    temp.write(name, '$name.ini', '[TextureOverrideBody]\nps-t0 = R\n');
    shaders.forEach((file, contents) => temp.write(name, p.join('ShaderFixes', file), contents));
  }

  ModInfo mod(String name, {String characterId = 'ellen'}) =>
      ModInfo(id: name, name: name, characterId: characterId, isActive: false);

  test('turning a mod on throws the refusal, with no link made and its shader files taken back out', () async {
    File(p.join(temp.root.path, 'd3dx.ini')).writeAsStringSync('[Rendering]\noverride_directory = ShaderFixes\n');
    installMod('Ellen', shaders: {'1f6ab42231416fdb-vs_replace.txt': 'bytes'});

    await expectLater(ApiService.enableMod('Ellen'), throwsA(isA<NetworkLinkRefused>()));

    expect(calls.links, isEmpty);
    expect(File(p.join(temp.root.path, 'ShaderFixes', '1f6ab42231416fdb-vs_replace.txt')).existsSync(), isFalse);
    expect(await temp.service.isModActive('Ellen'), isFalse);
  });

  test('a library change names a mod whose link was refused, and leaves its link as it was', () async {
    final oldRoot = temp.mods.path;
    final newRoot = p.join(temp.root.path, 'moved');
    // Only the new library is on the network, so the old link can be put back.
    calls.onNetwork = (path) => path.contains('moved');
    installMod('Ellen');
    Directory(p.join(newRoot, 'Ellen')).createSync(recursive: true);
    // Listed from the disk, and a link to the fake.
    final link = p.join(temp.saveMods.path, 'Ellen');
    Directory(link).createSync();
    calls.links[link] = (kind: 'junction', target: p.join(oldRoot, 'Ellen'));
    await temp.config.setPaths(newRoot, temp.root.path);

    final networkRefused = <String>{};
    expect(await temp.service.relinkLibrary(oldRoot, newRoot, networkRefused: networkRefused), ['Ellen']);

    expect(networkRefused, {'Ellen'});
    expect(calls.links[link]?.kind, 'junction');
  });

  testWidgets("the card's switch says why the mod stayed off", (tester) async {
    installMod('Winter Maid');
    await pumpModsScreen(tester, temp, [mod('Winter Maid')]);

    await tapWithIo(tester, find.descendant(of: cardOf('Winter Maid'), matching: find.byType(ZenithSwitch)));

    final overlay = find.byType(NotificationOverlay);
    expect(find.descendant(of: overlay, matching: find.text(title)), findsOneWidget);
    expect(find.descendant(of: overlay, matching: find.text(body('Winter Maid'))), findsOneWidget);
    expect(find.text('Mod not turned on'), findsNothing);
  });

  testWidgets('bulk Enable says it once for every mod it kept off', (tester) async {
    installMod('Ellen School');
    installMod('Miyabi Kimono');
    final container = await pumpAllModsTable(
      tester,
      [mod('Ellen School'), mod('Miyabi Kimono', characterId: 'miyabi')],
      overrides: temp.overrides,
    );
    await tick(tester, ['Ellen School', 'Miyabi Kimono']);

    await pressBulk(tester, container, barButton('Enable'));

    expect(
      [for (final n in container.read(notificationsProvider)) (n.title, n.body)],
      [(title, body('Ellen School, Miyabi Kimono'))],
    );
  });
}
