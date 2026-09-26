import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/temp_library.dart';

/// **A link whose mod folder is missing is never removed by a scan.**
///
/// The folder may be on a drive that is not mounted, or restored from a backup
/// later, and the mod is active again the moment it is back. Removing the link
/// would silently lose the fact that the mod was enabled.
void main() {
  late TempLibrary temp;

  setUp(() async {
    temp = await TempLibrary.create(prefix: 'zzz_dead_links_');
  });

  void installMod(String name) {
    temp.createMod(name);
    temp.write(name, '$name.ini', '[TextureOverrideBody]\nps-t0 = R\n');
  }

  test('a link to a folder that is gone survives a scan', () async {
    installMod('Ellen School');
    expect(await temp.service.activateMod('Ellen School'), isTrue);
    temp.deleteMod('Ellen School');

    await temp.service.getModsInfo();

    final link = Link(p.join(temp.saveMods.path, 'Ellen School'));
    expect(link.existsSync(), isTrue);
    expect(temp.config.activeMods, contains('Ellen School'));
  });

  test('every link survives a scan while the mods folder is missing', () async {
    installMod('Ellen School');
    installMod('Miyabi Kimono');
    await temp.service.activateMod('Ellen School');
    await temp.service.activateMod('Miyabi Kimono');

    // An unmounted drive: the library folder is simply not there.
    final unmounted = '${temp.mods.path}_unmounted';
    temp.mods.renameSync(unmounted);

    expect(await temp.service.getModsInfo(), isEmpty);

    for (final name in ['Ellen School', 'Miyabi Kimono']) {
      expect(Link(p.join(temp.saveMods.path, name)).existsSync(), isTrue,
          reason: '$name lost its link');
    }
    expect(temp.config.activeMods,
        containsAll(['Ellen School', 'Miyabi Kimono']));

    // Once the drive is back, both mods read as active again.
    Directory(unmounted).renameSync(temp.mods.path);
    final mods = await temp.service.getModsInfo();
    expect(mods.where((m) => m.isActive).map((m) => m.name),
        containsAll(['Ellen School', 'Miyabi Kimono']));
  });
}
