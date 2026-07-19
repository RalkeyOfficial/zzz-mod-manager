import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:mod_manager_flutter/services/archive_service.dart';

/// Builds a `.zip` at [zipPath] from a map of archive-relative path -> contents.
/// A trailing `/` key denotes an (otherwise empty) directory entry.
File _makeZip(String zipPath, Map<String, String> entries) {
  final archive = Archive();
  entries.forEach((name, contents) {
    if (name.endsWith('/')) {
      archive.addFile(ArchiveFile('$name.keep', 0, <int>[]));
    } else {
      final bytes = contents.codeUnits;
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    }
  });
  final bytes = ZipEncoder().encode(archive)!;
  final file = File(zipPath)..writeAsBytesSync(bytes);
  return file;
}

/// Sorted top-level entry names inside [dir].
List<String> _names(String dir) =>
    Directory(dir).listSync().map((e) => path.basename(e.path)).toList()
      ..sort();

bool _hasFileNamed(String dir, String fileName) => Directory(dir)
    .listSync(recursive: true)
    .whereType<File>()
    .any((f) => path.basename(f.path) == fileName);

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('archive_test_');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<List<String>> extractFolders(File zip) async {
    final dest = Directory(path.join(tmp.path, 'out_${zip.hashCode}'))
      ..createSync(recursive: true);
    final result = await ArchiveService.extractArchive(
      archiveFile: zip,
      destinationDir: dest,
    );
    expect(result.success, isTrue, reason: result.error);
    return result.extractedFolders ?? const [];
  }

  group('_prepareDirectoriesForImport via extractArchive', () {
    test('A: root .ini + resource folders => one wrapped mod (bug case)',
        () async {
      final zip = _makeZip(path.join(tmp.path, 'CoolMod.zip'), {
        'res/tex.dds': 'x',
        'buffer/data.buf': 'y',
        'texture/a.dds': 'z',
        'CoolMod.ini': '[Constants]',
      });

      final folders = await extractFolders(zip);

      expect(folders.length, 1, reason: 'root .ini => single mod');
      expect(path.basename(folders.single), 'CoolMod');
      // The .ini and every resource folder survive inside the one mod.
      expect(_hasFileNamed(folders.single, 'CoolMod.ini'), isTrue);
      expect(_names(folders.single),
          containsAll(<String>['res', 'buffer', 'texture', 'CoolMod.ini']));
    });

    test('B: multiple folders each with own .ini, no root .ini => separate',
        () async {
      final zip = _makeZip(path.join(tmp.path, 'Pack.zip'), {
        'ModA/a.ini': '[A]',
        'ModA/res/x': '1',
        'ModB/b.ini': '[B]',
        'ModB/res/y': '2',
      });

      final folders = await extractFolders(zip);

      expect(folders.length, 2, reason: 'container of independent mods');
      expect(folders.map((f) => path.basename(f)).toList()..sort(),
          <String>['ModA', 'ModB']);
    });

    test('C: one mod folder + previews folder, no root .ini => both returned',
        () async {
      final zip = _makeZip(path.join(tmp.path, 'WithPreview.zip'), {
        'TheMod/mod.ini': '[m]',
        'previews/shot.png': 'img',
      });

      final folders = await extractFolders(zip);

      expect(folders.length, 2);
      // containsIniFile distinguishes the real mod from the aux folder — this is
      // what the selection dialog uses to pre-check.
      final byName = {for (final f in folders) path.basename(f): f};
      expect(await ArchiveService.containsIniFile(byName['TheMod']!), isTrue);
      expect(await ArchiveService.containsIniFile(byName['previews']!), isFalse);
    });

    test('D: flat archive of loose files (no folders) => one wrapped mod',
        () async {
      final zip = _makeZip(path.join(tmp.path, 'Flat.zip'), {
        'mod.ini': '[m]',
        'hash.buf': 'b',
      });

      final folders = await extractFolders(zip);

      expect(folders.length, 1);
      expect(path.basename(folders.single), 'Flat');
      expect(_hasFileNamed(folders.single, 'mod.ini'), isTrue);
    });

    test('E: archive-name collides with a root folder => siblings nest, no crash',
        () async {
      // Foo.zip contains a Foo/ folder AND a root Foo.ini.
      final zip = _makeZip(path.join(tmp.path, 'Foo.zip'), {
        'Foo/inner.txt': 'i',
        'Foo.ini': '[f]',
      });

      final folders = await extractFolders(zip);

      expect(folders.length, 1);
      expect(path.basename(folders.single), 'Foo');
      // The root .ini is preserved (moved into the existing Foo/ folder).
      expect(_hasFileNamed(folders.single, 'Foo.ini'), isTrue);
      expect(_hasFileNamed(folders.single, 'inner.txt'), isTrue);
    });
  });
}
