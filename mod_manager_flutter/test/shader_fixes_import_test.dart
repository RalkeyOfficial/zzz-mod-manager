import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/services/archive_service.dart';
import 'package:path/path.dart' as p;

/// **Archives that carry shader files land as mods with a `ShaderFixes/` inside.**
///
/// Every layout here is one a real GameBanana mod ships (`docs/shader-fixes.md`
/// §2), reduced to the entries that decide where things go.
void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('zzz_shader_import_');
    addTearDown(() => temp.deleteSync(recursive: true));
  });

  /// Entries are written in the order given, all stamped with one shipped time.
  File zip(String name, List<String> entries) {
    final archive = Archive();
    final shipped = DateTime(2025, 3, 4, 5, 6, 8).millisecondsSinceEpoch ~/ 1000;
    for (final entry in entries) {
      final bytes = entry.codeUnits;
      archive.addFile(ArchiveFile(entry, bytes.length, bytes)..lastModTime = shipped);
    }
    return File(p.join(temp.path, name))..writeAsBytesSync(ZipEncoder().encode(archive)!);
  }

  Future<List<String>> extract(File archive) async {
    final result = await ArchiveService.extractArchive(
      archiveFile: archive,
      destinationDir: Directory(p.join(temp.path, 'out'))..createSync(),
      freeSpace: (_) async => null,
    );
    expect(result.success, isTrue, reason: result.error);
    return result.extractedFolders!;
  }

  List<String> filesUnder(String dir) => [
        for (final f in Directory(dir).listSync(recursive: true).whereType<File>())
          p.relative(f.path, from: dir).replaceAll(r'\', '/'),
      ]..sort();

  test('Mods/ and ShaderFixes/ side by side, with Windows separators: one mod holding both', () async {
    final dirs = await extract(zip('jiggleforge-manual-v0123.zip', [
      r'INSTALL-en.txt',
      r'Mods\JiggleForgeShaderFix\JiggleForge.ini',
      r'Mods\JiggleForgeShaderFix\JiggleForge\runtime\motion_model.hlsl',
      r'ShaderFixes\1f6ab42231416fdb-vs_replace.txt',
      r'ShaderFixes\JiggleForgeRuntime\draw_state_consumer.hlsl',
    ]));

    expect(dirs.map(p.basename), ['JiggleForgeShaderFix']);
    expect(filesUnder(dirs.single), [
      'JiggleForge.ini',
      'JiggleForge/runtime/motion_model.hlsl',
      'ShaderFixes/1f6ab42231416fdb-vs_replace.txt',
      'ShaderFixes/JiggleForgeRuntime/draw_state_consumer.hlsl',
    ]);
  });

  test('an .ini at the root beside ShaderFixes/: wrapped into one mod', () async {
    final dirs = await extract(zip('shadow fix.zip', [
      'shadow fix.ini',
      'ShaderFixes/85be73aeb8e0d1d4-vs_replace.txt',
    ]));

    expect(dirs.map(p.basename), ['shadow fix']);
    expect(filesUnder(dirs.single), ['ShaderFixes/85be73aeb8e0d1d4-vs_replace.txt', 'shadow fix.ini']);
  });

  test('ShaderFixes/ already inside the mod folder: left where it is', () async {
    final dirs = await extract(zip('vivian.zip', [
      'Vivian Summer/da.ini',
      'Vivian Summer/ShaderFixes/23329d3473571697-ps_replace.txt',
    ]));

    expect(filesUnder(dirs.single), ['ShaderFixes/23329d3473571697-ps_replace.txt', 'da.ini']);
  });

  test('an .ini directly in Mods/: Mods/ is the mod, and takes the shader files', () async {
    final dirs = await extract(zip('no_outlines.zip', [
      'Mods/no-outlines.ini',
      'ShaderFixes/4e2a0a1d6c8f9b3e-ps_replace.txt',
    ]));

    expect(dirs.map(p.basename), ['no_outlines']);
    expect(filesUnder(dirs.single), ['ShaderFixes/4e2a0a1d6c8f9b3e-ps_replace.txt', 'no-outlines.ini']);
  });

  test('only ShaderFixes/ and a readme: one shader-only mod, sources and caches keeping one time', () async {
    final dirs = await extract(zip('censor_remover_v320.zip', [
      'README.md',
      'ShaderFixes/0a1b2c3d4e5f6071-ps_replace.txt',
      'ShaderFixes/0a1b2c3d4e5f6071-ps_replace.bin',
    ]));

    expect(dirs.map(p.basename), ['censor_remover_v320']);
    final shaders = p.join(dirs.single, 'ShaderFixes');
    final txt = File(p.join(shaders, '0a1b2c3d4e5f6071-ps_replace.txt')).lastModifiedSync();
    final bin = File(p.join(shaders, '0a1b2c3d4e5f6071-ps_replace.bin')).lastModifiedSync();
    expect(bin, txt);
    expect(txt.year, 2025);
  });

  test('several mods beside ShaderFixes/: the shader files become a mod of their own', () async {
    final dirs = await extract(zip('attack colors.zip', [
      'Mods/Ellen Colors/ellen.ini',
      'Mods/Miyabi Colors/miyabi.ini',
      'ShaderFixes/9f848fa8163029bd-ps_replace.txt',
    ]));

    expect(dirs.map(p.basename).toList()..sort(),
        ['Ellen Colors', 'Miyabi Colors', 'attack colors ShaderFixes']);
    final shaderMod = dirs.firstWhere((d) => d.endsWith('attack colors ShaderFixes'));
    expect(filesUnder(shaderMod), ['ShaderFixes/9f848fa8163029bd-ps_replace.txt']);
  });

  test('a hash-named shader beside its .ini, with no ShaderFixes/ folder, is an ordinary mod', () async {
    final dirs = await extract(zip('custom_loading_screen.zip', [
      'README.txt',
      'Mods/custom_loading_screen/custom_loading_screen.ini',
      'Mods/custom_loading_screen/ps/a9d9418078d93839-ps_replace.txt',
    ]));

    expect(dirs.map(p.basename), ['custom_loading_screen']);
    expect(Directory(p.join(dirs.single, 'ShaderFixes')).existsSync(), isFalse);
  });
}
