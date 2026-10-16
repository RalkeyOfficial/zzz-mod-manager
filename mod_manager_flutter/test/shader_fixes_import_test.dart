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
  /// Each holds its own name, unless [contents] gives it other text.
  File zip(String name, List<String> entries, {Map<String, String> contents = const {}}) {
    final archive = Archive();
    final shipped = DateTime(2025, 3, 4, 5, 6, 8).millisecondsSinceEpoch ~/ 1000;
    for (final entry in entries) {
      final bytes = (contents[entry] ?? entry).codeUnits;
      archive.addFile(ArchiveFile(entry, bytes.length, bytes)..lastModTime = shipped);
    }
    return File(p.join(temp.path, name))..writeAsBytesSync(ZipEncoder().encode(archive)!);
  }

  Future<ArchiveExtractionResult> extractResult(File archive) async {
    final result = await ArchiveService.extractArchive(
      archiveFile: archive,
      destinationDir: Directory(p.join(temp.path, 'out'))..createSync(),
      freeSpace: (_) async => null,
    );
    expect(result.success, isTrue, reason: result.error);
    return result;
  }

  Future<List<String>> extract(File archive) async => (await extractResult(archive)).extractedFolders!;

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

  test('several mods beside ShaderFixes/: each mod gets its own copy, keeping its time', () async {
    final dirs = await extract(zip('attack colors.zip', [
      'Mods/Ellen Colors/ellen.ini',
      'Mods/Miyabi Colors/miyabi.ini',
      'ShaderFixes/9f848fa8163029bd-ps_replace.txt',
    ]));

    expect(dirs.map(p.basename).toList()..sort(), ['Ellen Colors', 'Miyabi Colors']);
    for (final mod in dirs) {
      expect(filesUnder(mod), contains('ShaderFixes/9f848fa8163029bd-ps_replace.txt'));
      expect(File(p.join(mod, 'ShaderFixes/9f848fa8163029bd-ps_replace.txt')).lastModifiedSync().year, 2025);
    }
  });

  test('several mods where some have their own ShaderFixes/: only the others get a copy', () async {
    final dirs = await extract(zip('attack colors.zip', [
      'Mods/Ellen Colors/ellen.ini',
      'Mods/Ellen Colors/ShaderFixes/1111111111111111-ps_replace.txt',
      'Mods/Miyabi Colors/miyabi.ini',
      'Mods/Yanagi Colors/yanagi.ini',
      'ShaderFixes/9f848fa8163029bd-ps_replace.txt',
    ]));

    expect(dirs.map(p.basename).toList()..sort(), ['Ellen Colors', 'Miyabi Colors', 'Yanagi Colors']);
    final ellen = dirs.firstWhere((d) => d.endsWith('Ellen Colors'));
    expect(filesUnder(ellen), ['ShaderFixes/1111111111111111-ps_replace.txt', 'ellen.ini']);
    for (final mod in dirs.where((d) => d != ellen)) {
      expect(filesUnder(mod), contains('ShaderFixes/9f848fa8163029bd-ps_replace.txt'));
    }
  });

  test('several mods that all have their own ShaderFixes/: the shared one becomes a mod of its own', () async {
    final dirs = await extract(zip('attack colors.zip', [
      'Mods/Ellen Colors/ellen.ini',
      'Mods/Ellen Colors/ShaderFixes/1111111111111111-ps_replace.txt',
      'Mods/Miyabi Colors/miyabi.ini',
      'Mods/Miyabi Colors/ShaderFixes/2222222222222222-ps_replace.txt',
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

  /// A folder named with "shader" that directly holds shader files and that no
  /// `.ini` loads from is a `ShaderFixes/` under another name (`docs/shader-fixes.md` §2).
  group('a shader folder under another name', () {
    test('inside a mod: its files move to ShaderFixes/, keeping their times', () async {
      final result = await extractResult(zip('ellen.zip', [
        'Ellen Mod/ellen.ini',
        'Ellen Mod/Shader Fix/0a1b2c3d4e5f6071-ps_replace.txt',
        'Ellen Mod/Shader Fix/0a1b2c3d4e5f6071-ps_replace.bin',
      ]));

      final mod = result.extractedFolders!.single;
      expect(filesUnder(mod), [
        'ShaderFixes/0a1b2c3d4e5f6071-ps_replace.bin',
        'ShaderFixes/0a1b2c3d4e5f6071-ps_replace.txt',
        'ellen.ini',
      ]);
      expect(Directory(p.join(mod, 'Shader Fix')).existsSync(), isFalse);
      final txt = File(p.join(mod, 'ShaderFixes/0a1b2c3d4e5f6071-ps_replace.txt')).lastModifiedSync();
      final bin = File(p.join(mod, 'ShaderFixes/0a1b2c3d4e5f6071-ps_replace.bin')).lastModifiedSync();
      expect(bin, txt);
      expect(txt.year, 2025);
      expect(result.shaderSources, {mod: 'Shader Fix'});
    });

    test('another file stays under the folder\'s own name, and a subfolder moves along', () async {
      final dirs = await extract(zip('ellen.zip', [
        'Ellen Mod/ellen.ini',
        'Ellen Mod/Shader Fix/0123456789abcdef-vs.txt',
        'Ellen Mod/Shader Fix/readme.txt',
        'Ellen Mod/Shader Fix/includes/common.hlsl',
      ]));

      expect(filesUnder(dirs.single), [
        'Shader Fix/readme.txt',
        'ShaderFixes/0123456789abcdef-vs.txt',
        'ShaderFixes/includes/common.hlsl',
        'ellen.ini',
      ]);
    });

    test('an .ini at the root beside it: wrapped into one mod, which takes the files', () async {
      final dirs = await extract(zip('shadow fix.zip', [
        'shadow fix.ini',
        'shaders/85be73aeb8e0d1d4-vs_replace.txt',
      ]));

      expect(dirs.map(p.basename), ['shadow fix']);
      expect(filesUnder(dirs.single), ['ShaderFixes/85be73aeb8e0d1d4-vs_replace.txt', 'shadow fix.ini']);
    });

    test('at the root beside one mod: moved into it, its readme kept under the folder\'s name', () async {
      final result = await extractResult(zip('ellen.zip', [
        'Ellen Mod/ellen.ini',
        'Shaders for ZZMI/9f848fa8163029bd-ps_replace.txt',
        'Shaders for ZZMI/readme.txt',
      ]));

      final mod = result.extractedFolders!.single;
      expect(p.basename(mod), 'Ellen Mod');
      expect(filesUnder(mod), [
        'ShaderFixes/9f848fa8163029bd-ps_replace.txt',
        'Shaders for ZZMI/readme.txt',
        'ellen.ini',
      ]);
      expect(result.shaderSources, {mod: 'Shaders for ZZMI'});
    });

    test('at the root beside several mods: each gets its own copy, keeping its time', () async {
      final result = await extractResult(zip('attack colors.zip', [
        'Ellen Colors/ellen.ini',
        'Miyabi Colors/miyabi.ini',
        'Shader Files/9f848fa8163029bd-ps_replace.txt',
      ]));

      final dirs = result.extractedFolders!;
      expect(dirs.map(p.basename).toList()..sort(), ['Ellen Colors', 'Miyabi Colors']);
      for (final mod in dirs) {
        expect(filesUnder(mod), contains('ShaderFixes/9f848fa8163029bd-ps_replace.txt'));
        expect(Directory(p.join(mod, 'Shader Files')).existsSync(), isFalse);
        expect(File(p.join(mod, 'ShaderFixes/9f848fa8163029bd-ps_replace.txt')).lastModifiedSync().year, 2025);
      }
      expect(result.shaderSources.values.toSet(), {'Shader Files'});
      expect(result.shaderSources.keys.toSet(), dirs.toSet());
    });

    test('at the root where every mod has its own ShaderFixes/: becomes a mod of its own', () async {
      final dirs = await extract(zip('attack colors.zip', [
        'Ellen Colors/ellen.ini',
        'Ellen Colors/ShaderFixes/1111111111111111-ps_replace.txt',
        'Miyabi Colors/miyabi.ini',
        'Miyabi Colors/ShaderFixes/2222222222222222-ps_replace.txt',
        'Extra Shaders/9f848fa8163029bd-ps_replace.txt',
      ]));

      expect(dirs.map(p.basename).toList()..sort(),
          ['Ellen Colors', 'Miyabi Colors', 'attack colors ShaderFixes']);
      final shaderMod = dirs.firstWhere((d) => d.endsWith('attack colors ShaderFixes'));
      expect(filesUnder(shaderMod), ['ShaderFixes/9f848fa8163029bd-ps_replace.txt']);
    });

    test('at the root beside a ShaderFixes/: the root ShaderFixes/ is used and the other stays as it is', () async {
      final dirs = await extract(zip('pack.zip', [
        'Mods/Ellen Colors/ellen.ini',
        'ShaderFixes/9f848fa8163029bd-ps_replace.txt',
        'More Shaders/1111111111111111-ps_replace.txt',
      ]));

      expect(dirs.map(p.basename).toList()..sort(), ['Ellen Colors', 'More Shaders']);
      final ellen = dirs.firstWhere((d) => d.endsWith('Ellen Colors'));
      expect(filesUnder(ellen), ['ShaderFixes/9f848fa8163029bd-ps_replace.txt', 'ellen.ini']);
      final more = dirs.firstWhere((d) => d.endsWith('More Shaders'));
      expect(filesUnder(more), ['1111111111111111-ps_replace.txt']);
    });

    test('alone at the root, named like the archive: one mod under that name, unnumbered', () async {
      final result = await extractResult(zip('Shader Fix.zip', [
        'README.md',
        'Shader Fix/0123456789abcdef-ps_replace.txt',
      ]));

      final mod = result.extractedFolders!.single;
      expect(p.basename(mod), 'Shader Fix');
      expect(filesUnder(mod), ['ShaderFixes/0123456789abcdef-ps_replace.txt']);
      expect(result.shaderSources, {mod: 'Shader Fix'});
    });

    test('beside an .ini directly in Mods/, named like the archive: the mod takes that name, unnumbered', () async {
      final dirs = await extract(zip('Shaders.zip', [
        'Mods/x.ini',
        'Shaders/9f848fa8163029bd-ps_replace.txt',
      ]));

      expect(dirs.map(p.basename), ['Shaders']);
      expect(filesUnder(dirs.single), ['ShaderFixes/9f848fa8163029bd-ps_replace.txt', 'x.ini']);
    });

    test('no mod can take it, and it is named like the mod it becomes: that name, unnumbered', () async {
      final dirs = await extract(zip('pack.zip', [
        'Ellen/ellen.ini',
        'Ellen/ShaderFixes/1111111111111111-ps_replace.txt',
        'pack ShaderFixes/2222222222222222-ps_replace.txt',
      ]));

      expect(dirs.map(p.basename).toList()..sort(), ['Ellen', 'pack ShaderFixes']);
      final shaderMod = dirs.firstWhere((d) => d.endsWith('pack ShaderFixes'));
      expect(filesUnder(shaderMod), ['ShaderFixes/2222222222222222-ps_replace.txt']);
    });

    test('two at the root: the first by name is used, and the second takes no copy', () async {
      final result = await extractResult(zip('pack.zip', [
        'Ellen/ellen.ini',
        'Miyabi/miyabi.ini',
        'Shaders A/1111111111111111-ps_replace.txt',
        'Shaders B/2222222222222222-ps_replace.txt',
      ]));

      final dirs = result.extractedFolders!;
      expect(dirs.map(p.basename).toList()..sort(), ['Ellen', 'Miyabi', 'Shaders B']);
      for (final mod in dirs.where((d) => !d.endsWith('Shaders B'))) {
        expect(filesUnder(mod), contains('ShaderFixes/1111111111111111-ps_replace.txt'));
      }
      final second = dirs.firstWhere((d) => d.endsWith('Shaders B'));
      expect(filesUnder(second), ['2222222222222222-ps_replace.txt']);
      expect(result.shaderSources.keys.map(p.basename).toSet(), {'Ellen', 'Miyabi'});
      expect(result.shaderSources.values.toSet(), {'Shaders A'});
    });

    test('two inside one mod: the first by name moves, the second stays as it is', () async {
      final dirs = await extract(zip('ellen.zip', [
        'Ellen/ellen.ini',
        'Ellen/Shader A/1111111111111111-ps_replace.txt',
        'Ellen/Shader B/2222222222222222-ps_replace.txt',
      ]));

      expect(filesUnder(dirs.single), [
        'Shader B/2222222222222222-ps_replace.txt',
        'ShaderFixes/1111111111111111-ps_replace.txt',
        'ellen.ini',
      ]);
    });

    test('at the root beside a mod with a shader folder of its own: becomes a mod of its own', () async {
      final result = await extractResult(zip('pack.zip', [
        'Ellen/ellen.ini',
        'Ellen/Shader A/1111111111111111-ps_replace.txt',
        'Shaders/2222222222222222-ps_replace.txt',
      ]));

      final dirs = result.extractedFolders!;
      expect(dirs.map(p.basename).toList()..sort(), ['Ellen', 'pack ShaderFixes']);
      final ellen = dirs.firstWhere((d) => d.endsWith('Ellen'));
      expect(filesUnder(ellen), ['ShaderFixes/1111111111111111-ps_replace.txt', 'ellen.ini']);
      final shaderMod = dirs.firstWhere((d) => d.endsWith('pack ShaderFixes'));
      expect(filesUnder(shaderMod), ['ShaderFixes/2222222222222222-ps_replace.txt']);
      expect(result.shaderSources, {ellen: 'Shader A', shaderMod: 'Shaders'});
    });

    test('at the root beside a mod holding a folder of the same name in another case: numbered, and named as in the archive', () async {
      final result = await extractResult(zip('ellen.zip', [
        'Ellen/ellen.ini',
        'Ellen/shaders/tex.dds',
        'Shaders/9f848fa8163029bd-ps_replace.txt',
      ], contents: {
        'Ellen/ellen.ini': '[TextureOverrideBody]\nps-t0 = ResourceBody\n\n'
            '[ResourceBody]\nfilename = shaders\\tex.dds\n',
      }));

      final mod = result.extractedFolders!.single;
      expect(filesUnder(mod), ['ShaderFixes/9f848fa8163029bd-ps_replace.txt', 'ellen.ini', 'shaders/tex.dds']);
      expect(result.shaderSources, {mod: 'Shaders'});
    });

    test('at the root, another mod\'s reference to its own Shaders/ does not hold it back', () async {
      final result = await extractResult(zip('ellen.zip', [
        'Ellen/ellen.ini',
        'Ellen/Shaders/tex.dds',
        'Shaders/9f848fa8163029bd-ps_replace.txt',
      ], contents: {
        'Ellen/ellen.ini': '[TextureOverrideBody]\nps-t0 = ResourceBody\n\n'
            '[ResourceBody]\nfilename = Shaders\\tex.dds\n',
      }));

      final mod = result.extractedFolders!.single;
      expect(filesUnder(mod), ['ShaderFixes/9f848fa8163029bd-ps_replace.txt', 'Shaders/tex.dds', 'ellen.ini']);
      expect(result.shaderSources, {mod: 'Shaders'});
    });

    test('Move Agents in Menu: the shader files join the mod, readmes and both variants stay', () async {
      const shaders = [
        '013d1715c5c946c8-vs_replace.txt',
        '11fa6706eaaa94f4-vs_replace.txt',
        '17b8feb05b02673e-vs_replace.txt',
        '25a44be262c3c5bd-vs_replace.txt',
        '4604983e6c833d56-vs_replace.txt',
        '5bf19ea4c3f9f721-vs_replace.txt',
        'b54ee89bce8af29a-vs_replace.txt',
        'd9a34ffd2c321a02-vs_replace.txt',
        'f82c94f20c21c957-vs_replace.txt',
      ];
      const variants = [
        'PICK ONE AND PUT IT IN MODS/CharacterMoverMod_ADVANCED-MODE/character-mover_ADVANCED-MODE.ini',
        'PICK ONE AND PUT IT IN MODS/CharacterMoverMod_BASIC-MODE/character-mover_BASIC-MODE.ini',
      ];
      final result = await extractResult(zip('CharacterMoverMod.zip', [
        'CharacterMoverMod/How to Change Key Bindings.txt',
        'CharacterMoverMod/List of Files in ShaderFixes.txt',
        for (final variant in variants) 'CharacterMoverMod/$variant',
        for (final shader in shaders) 'CharacterMoverMod/PUT THESE IN SHADERFIXES/$shader',
        'CharacterMoverMod/README.txt',
      ]));

      final mod = result.extractedFolders!.single;
      expect(p.basename(mod), 'CharacterMoverMod');
      expect(filesUnder(mod), [
        'How to Change Key Bindings.txt',
        'List of Files in ShaderFixes.txt',
        ...variants,
        'README.txt',
        for (final shader in shaders) 'ShaderFixes/$shader',
      ]);
      expect(result.shaderSources, {mod: 'PUT THESE IN SHADERFIXES'});
    });

    test('Move Agents in Menu without its outer folder: the shader files join the variants\' folder', () async {
      final dirs = await extract(zip('CharacterMoverMod.zip', [
        'PICK ONE AND PUT IT IN MODS/CharacterMoverMod_BASIC-MODE/character-mover_BASIC-MODE.ini',
        'PUT THESE IN SHADERFIXES/013d1715c5c946c8-vs_replace.txt',
        'README.txt',
      ]));

      expect(dirs.map(p.basename), ['PICK ONE AND PUT IT IN MODS']);
      expect(filesUnder(dirs.single), [
        'CharacterMoverMod_BASIC-MODE/character-mover_BASIC-MODE.ini',
        'ShaderFixes/013d1715c5c946c8-vs_replace.txt',
      ]);
    });

    group('stays an ordinary folder', () {
      test('when an .ini loads a file from it', () async {
        const ini = 'mod.ini';
        final dirs = await extract(zip('loader.zip', [
          'Loader/$ini',
          'Loader/Shader Stuff/0123456789abcdef-ps_replace.txt',
        ], contents: {
          'Loader/$ini': '[TextureOverrideBody]\nps-t0 = ResourceBody\n\n'
              '[ResourceBody]\nfilename = Shader Stuff\\0123456789abcdef-ps_replace.txt\n',
        }));

        expect(filesUnder(dirs.single), ['Shader Stuff/0123456789abcdef-ps_replace.txt', ini]);
      });

      test('when an .ini loads a file from it, spelling the folder in another case', () async {
        const ini = 'mod.ini';
        final dirs = await extract(zip('loader.zip', [
          'Loader/$ini',
          'Loader/Shader Stuff/0123456789abcdef-ps_replace.txt',
        ], contents: {
          'Loader/$ini': '[TextureOverrideBody]\nps-t0 = ResourceBody\n\n'
              '[ResourceBody]\nfilename = SHADER STUFF\\0123456789ABCDEF-ps_replace.txt\n',
        }));

        expect(filesUnder(dirs.single), ['Shader Stuff/0123456789abcdef-ps_replace.txt', ini]);
      });

      test('at the root, when a mod\'s .ini loads a file from it', () async {
        final dirs = await extract(zip('ellen.zip', [
          'Ellen/ellen.ini',
          'Shaders/tex.dds',
          'Shaders/9f848fa8163029bd-ps_replace.txt',
        ], contents: {
          'Ellen/ellen.ini': '[TextureOverrideBody]\nps-t0 = ResourceBody\n\n'
              '[ResourceBody]\nfilename = ..\\Shaders\\tex.dds\n',
        }));

        expect(dirs.map(p.basename).toList()..sort(), ['Ellen', 'Shaders']);
        final ellen = dirs.firstWhere((d) => d.endsWith('Ellen'));
        expect(filesUnder(ellen), ['ellen.ini']);
      });

      test('when it holds an .ini of its own, at the root or inside a mod', () async {
        final dirs = await extract(zip('toon.zip', [
          'Ellen/ellen.ini',
          'Ellen/Inner Shader/inner.ini',
          'Ellen/Inner Shader/1111111111111111-ps_replace.txt',
          'Toon Shader/toon.ini',
          'Toon Shader/0123456789abcdef-ps_replace.txt',
        ]));

        expect(dirs.map(p.basename).toList()..sort(), ['Ellen', 'Toon Shader']);
        final ellen = dirs.firstWhere((d) => d.endsWith('Ellen'));
        expect(filesUnder(ellen), [
          'Inner Shader/1111111111111111-ps_replace.txt',
          'Inner Shader/inner.ini',
          'ellen.ini',
        ]);
        final toon = dirs.firstWhere((d) => d.endsWith('Toon Shader'));
        expect(filesUnder(toon), ['0123456789abcdef-ps_replace.txt', 'toon.ini']);
      });

      test('when its name has no "shader" in it', () async {
        final dirs = await extract(zip('loading.zip', [
          'Loading/loading.ini',
          'Loading/ps/a9d9418078d93839-ps_replace.txt',
        ]));

        expect(filesUnder(dirs.single), ['loading.ini', 'ps/a9d9418078d93839-ps_replace.txt']);
      });

      test('when it holds no shader replacement file', () async {
        final dirs = await extract(zip('reshade.zip', [
          'Preset/preset.ini',
          'Preset/Shaders/Bloom.fx',
          'Preset/Shaders/0123456789abcdef-ps_replace.txt.bak',
        ]));

        expect(filesUnder(dirs.single), [
          'Shaders/0123456789abcdef-ps_replace.txt.bak',
          'Shaders/Bloom.fx',
          'preset.ini',
        ]);
      });

      test('when the mod already has a ShaderFixes/', () async {
        final result = await extractResult(zip('vivian.zip', [
          'Vivian Summer/da.ini',
          'Vivian Summer/ShaderFixes/23329d3473571697-ps_replace.txt',
          'Vivian Summer/More Shaders/1111111111111111-ps_replace.txt',
        ]));

        expect(filesUnder(result.extractedFolders!.single), [
          'More Shaders/1111111111111111-ps_replace.txt',
          'ShaderFixes/23329d3473571697-ps_replace.txt',
          'da.ini',
        ]);
        expect(result.shaderSources, isEmpty);
      });
    });
  });
}
