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
}
