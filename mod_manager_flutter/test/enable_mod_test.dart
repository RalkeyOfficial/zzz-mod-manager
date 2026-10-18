import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/services/api_service.dart';
import 'package:mod_manager_flutter/services/shader_fixes/shader_fixes_service.dart';
import 'package:path/path.dart' as p;

import 'support/temp_library.dart';

/// `ApiService.enableMod`, the one path every enable from the library takes (`docs/library-screen.md` §10): the dry
/// run, then the mods to switch off, then the mod.
void main() {
  late TempLibrary temp;

  setUp(() async {
    temp = await TempLibrary.create(prefix: 'zzz_enable_mod_');
  });

  void installMod(String name) {
    temp.createMod(name);
    temp.write(name, '$name.ini', '[TextureOverrideBody]\nps-t0 = R\n');
  }

  bool linked(String name) => Link(p.join(temp.saveMods.path, name)).existsSync();

  test('turns the mods in switchOff off, then the mod on', () async {
    installMod('Ellen School');
    installMod('Ellen Maid');
    installMod('Ellen Beach');
    expect(await temp.service.activateMod('Ellen School'), isTrue);
    expect(await temp.service.activateMod('Ellen Beach'), isTrue);

    expect(await ApiService.enableMod('Ellen Maid', switchOff: ['Ellen School', 'Ellen Beach']), isTrue);

    expect(linked('Ellen Maid'), isTrue);
    expect(linked('Ellen School'), isFalse);
    expect(linked('Ellen Beach'), isFalse);
    expect(temp.config.activeMods, ['Ellen Maid']);
  });

  test('with nothing to switch off, the others stay on', () async {
    installMod('Ellen School');
    installMod('Ellen Maid');
    await temp.service.activateMod('Ellen School');

    expect(await ApiService.enableMod('Ellen Maid'), isTrue);

    expect(linked('Ellen Maid'), isTrue);
    expect(linked('Ellen School'), isTrue);
  });

  test('a mod that will not turn off stops the enable', () async {
    installMod('Ellen School');
    installMod('Ellen Maid');

    // Not on, so there is no link to remove: the disk is not what the caller read.
    expect(await ApiService.enableMod('Ellen Maid', switchOff: ['Ellen School']), isFalse);

    expect(linked('Ellen Maid'), isFalse);
  });

  test('a refused enable throws before anything is switched off', () async {
    installMod('Ellen School');
    // Shader files, and no d3dx.ini beside the links folder to say where they would go.
    temp.createMod('Jiggle');
    temp.write('Jiggle', 'Jiggle.ini', '[TextureOverrideBody]\n');
    temp.write('Jiggle', 'ShaderFixes/abc123-ps_replace.txt', 'shader');
    await temp.service.activateMod('Ellen School');

    await expectLater(
      ApiService.enableMod('Jiggle', switchOff: ['Ellen School']),
      throwsA(isA<ShaderPlacementRefused>()),
    );

    expect(linked('Ellen School'), isTrue, reason: 'the mod that was on stays on');
    expect(linked('Jiggle'), isFalse);
  });

  test('disableMod removes the link', () async {
    installMod('Ellen School');
    await temp.service.activateMod('Ellen School');

    expect(await ApiService.disableMod('Ellen School'), isTrue);

    expect(linked('Ellen School'), isFalse);
    expect(temp.config.activeMods, isEmpty);
  });
}
