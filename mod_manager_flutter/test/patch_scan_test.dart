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

  test('it names the patches and nothing else', () async {
    write('Patch', 'fix.ini', modIni({'R': 'Body.dds'}));

    write('Complete', 'ellen.ini', modIni({'R': 'Body.dds'}));
    write('Complete', 'Body.dds', 'x');

    // The measured normal case: an .ini covering the whole character while the
    // author shipped only the component they replaced.
    write('Partial', 'wings.ini',
        modIni({'R1': 'Wings.dds', 'R2': 'Jets.dds', 'R3': 'Extra.dds'}));
    write('Partial', 'Wings.dds', 'x');

    expect(
      await modsThatLookLikePatches(tmp.path, ['Patch', 'Complete', 'Partial']),
      ['Patch'],
    );
  });

  test('a folder with no .ini is skipped rather than judged', () async {
    // It has its own warning on both install paths, and reporting it twice
    // would say two different things about one folder.
    write('NoIni', 'readme.txt', 'hello');
    expect(await modsThatLookLikePatches(tmp.path, ['NoIni']), isEmpty);
  });

  test('a folder that is not there answers nothing', () async {
    expect(await modsThatLookLikePatches(tmp.path, ['Missing']), isEmpty);
  });

  test('our own sidecar is never counted as the mod\'s content', () async {
    // Otherwise a sidecar image would make a patch look like it shipped
    // something.
    write('Patch', 'fix.ini', modIni({'R': 'Body.dds'}));
    write('Patch', '${AppConstants.modMetadataDirName}/images/01.png', 'x');
    expect(await modsThatLookLikePatches(tmp.path, ['Patch']), ['Patch']);
  });

  test('names are resolved under the mods path, not the cwd', () async {
    write('Nested Name With Spaces', 'fix.ini', modIni({'R': 'Body.dds'}));
    expect(
      await modsThatLookLikePatches(tmp.path, ['Nested Name With Spaces']),
      ['Nested Name With Spaces'],
    );
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

    test('a single folder answers exactly as it does after the copy', () async {
      write('Patch', 'fix.ini', modIni({'R': 'Body.dds'}));
      write('Complete', 'ellen.ini', modIni({'R': 'Body.dds'}));
      write('Complete', 'Body.dds', 'x');

      expect(
        await plannedPatchShapedMods([separate('Patch'), separate('Complete')]),
        {'Patch'},
      );
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
        await plannedPatchShapedMods([separate('Body'), separate('Wings')]),
        {'Wings'},
        reason: 'installed separately they really are two mods, and one of '
            'them really did bring nothing',
      );
      expect(
        await plannedPatchShapedMods([combined('Ellen', ['Body', 'Wings'])]),
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
        await plannedPatchShapedMods([
          combined('Ellen Fixes', ['Fixes', 'More Fixes']),
        ]),
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
        await plannedPatchShapedMods([
          combined('Ellen', ['Patch', 'Extras']),
        ]),
        {'Ellen'},
        reason: 'and this is the answer the post-import scan gives, because '
            'the copy puts them in exactly those subfolders',
      );
    });

    test('a planned mod with no .ini at all is skipped rather than judged',
        () async {
      write('Previews', 'shot.png', 'x');
      expect(await plannedPatchShapedMods([separate('Previews')]), isEmpty);
    });

    test('a source folder that vanished contributes nothing', () async {
      write('Patch', 'fix.ini', modIni({'R': 'Body.dds'}));
      expect(
        await plannedPatchShapedMods([
          combined('Ellen', ['Patch', 'Gone']),
        ]),
        {'Ellen'},
      );
    });
  });
}
