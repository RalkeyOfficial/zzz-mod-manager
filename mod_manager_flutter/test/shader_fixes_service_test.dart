import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/services/shader_fixes/shader_fixes_service.dart';
import 'package:mod_manager_flutter/services/update_apply/mod_activation_port.dart';
import 'package:path/path.dart' as p;

import 'support/temp_library.dart';

/// **A mod's `ShaderFixes/` goes into ZZMI's shader folder while the mod is on.**
///
/// Through the real activation path, against a temp library whose links folder
/// sits in a ZZMI root with a `d3dx.ini`, so the assertions are about the bytes
/// in the folder ZZMI reads.
void main() {
  late TempLibrary temp;
  late Directory shaders;

  const hashA = '1f6ab42231416fdb-vs_replace.txt';
  const hashB = '26214fb5eedfcbdd-ps_replace.txt';

  setUp(() async {
    temp = await TempLibrary.create(prefix: 'zzz_shader_fixes_');
    File(p.join(temp.root.path, 'd3dx.ini'))
        .writeAsStringSync('[Rendering]\noverride_directory = ShaderFixes\n');
    shaders = Directory(p.join(temp.root.path, 'ShaderFixes'))..createSync();
    // ZZMI's own placeholder, which no mod placed.
    File(p.join(shaders.path, 'Sucrose.png')).writeAsStringSync('png');
  });

  File shader(String relative) => File(p.join(shaders.path, relative));

  void installShaderMod(String name, Map<String, String> shaderFiles) {
    temp.createMod(name);
    temp.write(name, '$name.ini', '[ShaderOverrideX]\nhash = 1f6ab42231416fdb\n');
    shaderFiles.forEach((relative, contents) {
      temp.write(name, 'ShaderFixes/$relative', contents);
    });
  }

  test('enabling copies every shader file in, keeping its time', () async {
    installShaderMod('Jiggle', {
      hashA: 'shader a',
      'JiggleForgeRuntime/motion.hlsl': 'include',
    });
    final source = File(p.join(temp.modFolder('Jiggle').path, 'ShaderFixes', hashA));
    final shipped = DateTime(2025, 1, 2, 3, 4, 5);
    source.setLastModifiedSync(shipped);

    expect(await temp.service.activateMod('Jiggle'), isTrue);

    expect(shader(hashA).readAsStringSync(), 'shader a');
    expect(shader('JiggleForgeRuntime/motion.hlsl').existsSync(), isTrue);
    expect(shader(hashA).lastModifiedSync(), shipped);
    expect(Link(p.join(temp.saveMods.path, 'Jiggle')).existsSync(), isTrue);
  });

  test("disabling removes the mod's files, the cache ZZMI wrote, and emptied folders — nothing else",
      () async {
    installShaderMod('Jiggle', {hashA: 'shader a', 'JiggleForgeRuntime/motion.hlsl': 'x'});
    await temp.service.activateMod('Jiggle');
    shader('1f6ab42231416fdb-vs_replace.bin').writeAsStringSync('compiled by ZZMI');
    shader('0000000000000000-ps_replace.txt').writeAsStringSync('a hunting dump');

    expect(await temp.service.deactivateMod('Jiggle'), isTrue);

    expect(shader(hashA).existsSync(), isFalse);
    expect(shader('1f6ab42231416fdb-vs_replace.bin').existsSync(), isFalse);
    expect(Directory(p.join(shaders.path, 'JiggleForgeRuntime')).existsSync(), isFalse);
    expect(shader('Sucrose.png').existsSync(), isTrue);
    expect(shader('0000000000000000-ps_replace.txt').existsSync(), isTrue);
    expect(shaders.existsSync(), isTrue);
  });

  test('a file edited after it was placed survives a disable', () async {
    installShaderMod('Jiggle', {hashA: 'shader a'});
    await temp.service.activateMod('Jiggle');
    shader(hashA).writeAsStringSync('tweaked by the user');

    await temp.service.deactivateMod('Jiggle');

    expect(shader(hashA).readAsStringSync(), 'tweaked by the user');
  });

  test('a filename another mod placed refuses the enable, names it, and copies nothing', () async {
    installShaderMod('No Outlines', {hashA: 'from no outlines'});
    installShaderMod('Censor Remover', {hashB: 'b', hashA: 'from censor remover'});
    await temp.service.activateMod('No Outlines');

    await expectLater(
      temp.service.activateMod('Censor Remover'),
      throwsA(isA<ShaderPlacementRefused>()
          .having((r) => r.conflicts.single.path, 'path', hashA)
          .having((r) => r.conflicts.single.owner, 'owner', 'No Outlines')),
    );

    expect(shader(hashA).readAsStringSync(), 'from no outlines');
    expect(shader(hashB).existsSync(), isFalse);
    expect(Link(p.join(temp.saveMods.path, 'Censor Remover')).existsSync(), isFalse);
    expect(temp.config.activeMods, isNot(contains('Censor Remover')));
  });

  test('a file copied in by hand refuses the enable with no owner', () async {
    shader(hashA).writeAsStringSync('hand-copied');
    installShaderMod('Jiggle', {hashA: 'shader a'});

    await expectLater(
      temp.service.activateMod('Jiggle'),
      throwsA(isA<ShaderPlacementRefused>()
          .having((r) => r.conflicts.single.owner, 'owner', isNull)),
    );
    expect(shader(hashA).readAsStringSync(), 'hand-copied');
  });

  test('with no d3dx.ini beside the links folder, only a mod with shader files is refused', () async {
    File(p.join(temp.root.path, 'd3dx.ini')).deleteSync();
    installShaderMod('Jiggle', {hashA: 'shader a'});
    temp.createMod('Ellen School');
    temp.write('Ellen School', 'Ellen.ini', '[TextureOverrideBody]\n');

    await expectLater(
      temp.service.activateMod('Jiggle'),
      throwsA(isA<ShaderPlacementRefused>().having((r) => r.noShaderFolder, 'noShaderFolder', isTrue)),
    );
    expect(await temp.service.activateMod('Ellen School'), isTrue);
  });

  test('re-enabling after the folder changed places the new version and drops the old file', () async {
    installShaderMod('Jiggle', {hashA: 'v1', hashB: 'v1 only'});
    await temp.service.activateMod('Jiggle');
    await temp.service.deactivateMod('Jiggle');
    File(p.join(temp.modFolder('Jiggle').path, 'ShaderFixes', hashB)).deleteSync();
    temp.write('Jiggle', 'ShaderFixes/$hashA', 'v2');

    await temp.service.activateMod('Jiggle');

    expect(shader(hashA).readAsStringSync(), 'v2');
    expect(shader(hashB).existsSync(), isFalse);
  });

  test("deleting an enabled mod takes its shader files with it", () async {
    installShaderMod('Jiggle', {hashA: 'shader a'});
    await temp.service.activateMod('Jiggle');

    expect(await temp.service.deleteMod('Jiggle'), isTrue);

    expect(shader(hashA).existsSync(), isFalse);
  });

  test('renaming an enabled mod keeps ownership, so a disable still cleans up', () async {
    installShaderMod('Jiggle', {hashA: 'shader a'});
    await temp.service.activateMod('Jiggle');

    expect(await temp.service.renameMod('Jiggle', 'JiggleForge'), isTrue);
    await temp.service.deactivateMod('JiggleForge');

    expect(shader(hashA).existsSync(), isFalse);
  });

  test('a target differing only in case is found on disk and refused, naming its owner', () async {
    installShaderMod('Jiggle', {'JiggleForgeRuntime/motion.hlsl': 'jiggle'});
    installShaderMod('Other', {'jiggleforgeruntime/motion.hlsl': 'other'});
    await temp.service.activateMod('Jiggle');

    await expectLater(
      temp.service.activateMod('Other'),
      throwsA(isA<ShaderPlacementRefused>()
          .having((r) => r.conflicts.single.owner, 'owner', 'Jiggle')),
    );
    expect(Directory(p.join(shaders.path, 'jiggleforgeruntime')).existsSync(), isFalse);

    await temp.service.deactivateMod('Jiggle');
    expect(shader('JiggleForgeRuntime/motion.hlsl').existsSync(), isFalse);
  });

  test('a link that cannot be made takes the placed files back out, with no restart notice', () async {
    installShaderMod('Jiggle', {hashA: 'shader a'});
    // A real folder where the link would go, which the platform refuses to replace.
    Directory(p.join(temp.saveMods.path, 'Jiggle')).createSync();
    final announced = <String>[];
    final subscription = ShaderFixesService.changes.listen(announced.add);
    addTearDown(subscription.cancel);

    expect(await temp.service.activateMod('Jiggle'), isFalse);
    await Future<void>.delayed(Duration.zero);

    expect(shader(hashA).existsSync(), isFalse);
    expect(announced, isEmpty);
  });

  test('the dry run refuses what an enable would, and copies nothing either way', () async {
    installShaderMod('No Outlines', {hashA: 'from no outlines'});
    installShaderMod('Censor Remover', {hashA: 'from censor remover', hashB: 'b'});
    installShaderMod('Jiggle', {'JiggleForgeRuntime/motion.hlsl': 'x'});
    await temp.service.activateMod('No Outlines');

    await expectLater(
      temp.service.checkActivation('Censor Remover'),
      throwsA(isA<ShaderPlacementRefused>()),
    );
    await temp.service.checkActivation('Jiggle');

    expect(shader(hashB).existsSync(), isFalse);
    expect(shader('JiggleForgeRuntime/motion.hlsl').existsSync(), isFalse);
  });

  test("after the links folder moves to another ZZMI, a same-named file there is not the mod's own", () async {
    installShaderMod('Jiggle', {hashA: 'shader a'});
    await temp.service.activateMod('Jiggle');

    final second = Directory(p.join(temp.root.path, 'second'))..createSync();
    File(p.join(second.path, 'd3dx.ini')).writeAsStringSync('[Rendering]\n');
    final secondShaders = Directory(p.join(second.path, 'ShaderFixes'))..createSync();
    File(p.join(secondShaders.path, hashA)).writeAsStringSync('already here');
    final secondMods = Directory(p.join(second.path, 'Mods'))..createSync();
    await temp.config.setPaths(temp.mods.path, secondMods.path);

    await expectLater(
      temp.service.activateMod('Jiggle'),
      throwsA(isA<ShaderPlacementRefused>()
          .having((r) => r.conflicts.single.owner, 'owner', isNull)),
    );
    expect(File(p.join(secondShaders.path, hashA)).readAsStringSync(), 'already here');

    // Deleting the mod still cleans the folder its files went into.
    await temp.service.deleteMod('Jiggle');
    expect(shader(hashA).existsSync(), isFalse);
    expect(File(p.join(secondShaders.path, hashA)).existsSync(), isTrue);
  });

  test('an update that cannot switch the mod back on reports the refusal', () async {
    installShaderMod('No Outlines', {hashA: 'from no outlines'});
    installShaderMod('Censor Remover', {hashA: 'from censor remover'});
    await temp.service.activateMod('No Outlines');
    final reported = <ShaderPlacementRefused>[];
    final subscription = ShaderFixesService.unattendedRefusals.listen(reported.add);
    addTearDown(subscription.cancel);

    final activated = await ModManagerActivationPort(temp.service).activate('Censor Remover');
    await Future<void>.delayed(Duration.zero);

    expect(activated, isFalse);
    expect(reported.single.mod, 'Censor Remover');
  });
}
