import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/core/constants.dart';
import 'package:mod_manager_flutter/services/patch_scan.dart';
import 'package:path/path.dart' as p;

/// The I/O side of patch detection.
///
/// The rule underneath it is covered exhaustively against fixture strings, so
/// what is left here is the plumbing the rule cannot see: the folder-name
/// resolution, the `hasIni` short-circuit, and the fact that both install paths
/// get the same answer for the same folder.
void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('zzz_patch_scan_test_');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  void write(String modName, String relative, String contents) {
    final file = File(p.join(tmp.path, modName, relative));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(contents);
  }

  String modIni(Map<String, String> resources) {
    final buffer = StringBuffer('[TextureOverrideBody]\n');
    var i = 0;
    for (final section in resources.keys) {
      buffer.writeln('ps-t${i++} = $section');
    }
    for (final entry in resources.entries) {
      buffer.writeln('\n[${entry.key}]\nfilename = ${entry.value}');
    }
    return buffer.toString();
  }

  /// One folder, one mod — the shape most installs are.
  group('a folder at a time', () {
    Future<PlannedPatchScan> scan(List<String> names) => scanPlannedMods([
          for (final name in names)
            PlannedMod(name: name, sources: {p.join(tmp.path, name): ''}),
        ]);

    test('it names the patches and nothing else', () async {
      write('Patch', 'fix.ini', modIni({'R': 'Body.dds'}));

      write('Complete', 'ellen.ini', modIni({'R': 'Body.dds'}));
      write('Complete', 'Body.dds', 'x');

      // The measured normal case: an .ini covering the whole character while
      // the author shipped only the component they replaced.
      write('Partial', 'wings.ini',
          modIni({'R1': 'Wings.dds', 'R2': 'Jets.dds', 'R3': 'Extra.dds'}));
      write('Partial', 'Wings.dds', 'x');

      final result = await scan(['Patch', 'Complete', 'Partial']);
      expect(result.iniPatches, {'Patch'});
      expect(result.incomplete, isEmpty);
    });

    test('a folder with no .ini is answered by the other rule', () async {
      // Exactly one of the three outcomes per mod: the `.ini` rule has no
      // references to read here, so it declines rather than guessing, and the
      // partition is what stops two things being said about one folder.
      write('NoIni', 'readme.txt', 'hello');

      final result = await scan(['NoIni']);
      expect(result.iniPatches, isEmpty);
      expect(result.assetPatches, isEmpty, reason: 'a readme loads nothing');
      expect(result.incomplete, {'NoIni'});
    });

    test('a folder that is not there is never called a patch', () async {
      expect((await scan(['Missing'])).patchShaped, isEmpty);
    });

    test('our own sidecar is never counted as the mod\'s content', () async {
      // Otherwise a sidecar image would make a patch look like it shipped
      // something.
      write('Patch', 'fix.ini', modIni({'R': 'Body.dds'}));
      write('Patch', '${AppConstants.modMetadataDirName}/images/01.png', 'x');
      expect((await scan(['Patch'])).iniPatches, {'Patch'});
    });

    test('names are resolved where the folder actually is', () async {
      write('Nested Name With Spaces', 'fix.ini', modIni({'R': 'Body.dds'}));
      expect((await scan(['Nested Name With Spaces'])).iniPatches,
          {'Nested Name With Spaces'});
    });
  });

  /// The same question asked **before** the copy, about folders that are still
  /// in a temp directory.
  ///
  /// Moving it there is what lets the install offer a destination instead of
  /// warning afterwards — but the subject of the question is a **mod**, not a
  /// folder, and the import selection is what decides where one ends and the
  /// next begins. Getting that wrong reports ordinary mods as patches.
  group('planned mods, before the import', () {
    PlannedMod separate(String name) => PlannedMod(
          name: name,
          sources: {p.join(tmp.path, name): ''},
        );

    PlannedMod combined(String name, List<String> folders) => PlannedMod(
          name: name,
          sources: {
            for (final folder in folders) p.join(tmp.path, folder): folder,
          },
        );

    Future<PlannedPatchScan> scan(List<PlannedMod> planned) =>
        scanPlannedMods(planned);

    test('a single folder answers exactly as it does after the copy', () async {
      write('Patch', 'fix.ini', modIni({'R': 'Body.dds'}));
      write('Complete', 'ellen.ini', modIni({'R': 'Body.dds'}));
      write('Complete', 'Body.dds', 'x');

      final result = await scan([separate('Patch'), separate('Complete')]);
      expect(result.iniPatches, {'Patch'});
      expect(result.incomplete, isEmpty);
    });

    test('a combined install is judged as one mod, not folder by folder',
        () async {
      // The regression that moving the scan would otherwise introduce. Judged
      // separately, `Wings` ships nothing it references and reads as a patch —
      // and the user would be asked where to apply an ordinary mod. The rule
      // is "the download brought no content at all", and the download here is
      // the mod the two folders become.
      write('Body', 'body.ini', modIni({'R': 'Body.dds'}));
      write('Body', 'Body.dds', 'x');
      write('Wings', 'wings.ini', modIni({'R': 'Wings.dds'}));

      expect(
        (await scan([separate('Body'), separate('Wings')])).iniPatches,
        {'Wings'},
        reason: 'installed separately they really are two mods, and one of '
            'them really did bring nothing',
      );
      expect(
        (await scan([combined('Ellen', ['Body', 'Wings'])])).iniPatches,
        isEmpty,
        reason: 'combined they are one mod, and it brought content',
      );
    });

    test('a genuinely patch-shaped combined install is still named', () async {
      // The union must not be able to launder a patch either: neither half
      // brings anything.
      write('Fixes', 'fix.ini', modIni({'R': 'Body.dds'}));
      write('More Fixes', 'more.ini', modIni({'R': 'Hair.dds'}));

      expect(
        (await scan([combined('Ellen Fixes', ['Fixes', 'More Fixes'])]))
            .iniPatches,
        {'Ellen Fixes'},
      );
    });

    test('the union is taken under the subfolder each folder lands in',
        () async {
      // References resolve relative to their own `.ini`, so after the combine
      // `Patch/patch.ini` asks for `Patch/Body.dds` — which is not what
      // `Extras/Body.dds` is. A raw union sees the basename, calls the
      // reference satisfied and loses the patch.
      write('Patch', 'patch.ini', modIni({'R': 'Body.dds'}));
      write('Extras', 'Body.dds', 'x');

      expect(
        (await scan([combined('Ellen', ['Patch', 'Extras'])])).iniPatches,
        {'Ellen'},
        reason: 'and this is the answer the post-import scan gives, because '
            'the copy puts them in exactly those subfolders',
      );
    });

    test('a source folder that vanished contributes nothing', () async {
      write('Patch', 'fix.ini', modIni({'R': 'Body.dds'}));
      expect(
        (await scan([combined('Ellen', ['Patch', 'Gone'])])).iniPatches,
        {'Ellen'},
      );
    });

    group('a download with no .ini', () {
      test('is a patch when it carries assets only an .ini could load',
          () async {
        // The measured real case: a 6.7 MB archive containing one `.dds`. The
        // `.ini` rule cannot see it — there are no references — so the signal
        // is the asset arriving with nothing to load it.
        write('Retexture', 'Body.dds', 'new bytes');

        final result = await scan([separate('Retexture')]);
        expect(result.assetPatches.keys, ['Retexture']);
        expect(
          result.incomplete,
          isEmpty,
          reason: 'calling it incomplete points at the wrong fix, and the two '
              'answers must not both be given about one mod',
        );
        expect(result.iniPatches, isEmpty);
      });

      test('does not need the mod it patches to be installed first', () async {
        // The reported bug. Downloading the patch before its base mod is an
        // ordinary way round, and the answer must not depend on which came
        // first — nothing outside the folder is consulted, so it cannot.
        write('Retexture', 'Body.dds', 'x');
        expect((await scan([separate('Retexture')])).assetPatches.keys,
            ['Retexture']);
      });

      test('is incomplete when it carries nothing an .ini would load',
          () async {
        // The case the "may be incomplete" warning is genuinely for: a
        // `previews` folder installed as a mod of its own.
        write('Previews', 'preview.png', 'x');
        write('Previews', '01.jpg', 'x');

        final result = await scan([separate('Previews')]);
        expect(result.assetPatches, isEmpty);
        expect(result.incomplete, {'Previews'});
      });

      test('is judged as one mod when the folders are combined', () async {
        // The same scoping rule as the `.ini` half. Combined, the `.ini` in one
        // folder covers the assets in the other and the mod is complete.
        write('Textures', 'Body.dds', 'x');
        write('Loader', 'ellen.ini', modIni({'R': 'Body.dds'}));

        final combinedScan =
            await scan([combined('Ellen', ['Loader', 'Textures'])]);
        expect(combinedScan.assetPatches, isEmpty);
        expect(combinedScan.incomplete, isEmpty);
        expect(
          (await scan([separate('Textures'), separate('Loader')]))
              .assetPatches
              .keys,
          ['Textures'],
          reason: 'installed on its own, Textures really is assets with no '
              '.ini to load them',
        );
      });
    });

    test('patchShaped is both rules and nothing else', () async {
      write('IniPatch', 'fix.ini', modIni({'R': 'Body.dds'}));
      write('AssetPatch', 'Hair.dds', 'x');
      write('Previews', 'shot.png', 'x');
      write('Fine', 'ellen.ini', modIni({'R': 'Body.dds'}));
      write('Fine', 'Body.dds', 'x');

      final result = await scan([
        separate('IniPatch'),
        separate('AssetPatch'),
        separate('Previews'),
        separate('Fine'),
      ]);
      expect(result.patchShaped, {'IniPatch', 'AssetPatch'});
      expect(result.incomplete, {'Previews'});
    });
  });
}
