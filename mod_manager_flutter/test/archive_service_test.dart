import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:mod_manager_flutter/services/archive_hash.dart';
import 'package:mod_manager_flutter/services/archive_service.dart';

import 'support/system_temp.dart';

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

/// Path to a 7-Zip binary, or null when none is installed.
final String? _sevenZip = () {
  for (final candidate in ['7z', '7za', '7zr']) {
    try {
      final which = Process.runSync('which', [candidate]);
      if (which.exitCode == 0) {
        final found = which.stdout.toString().trim();
        if (found.isNotEmpty) return found;
      }
    } catch (_) {
      // `which` missing (Windows); the test skips.
    }
  }
  return null;
}();

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

    test('D2: the invented folder can be named by the caller', () async {
      // **The mod's name comes from the archive's filename here**, and the file
      // on disk is not always called what the download asked for: a leftover
      // archive of the same name pushes the new one to `mod (2).rar`, and the
      // user's mod would be called `pulchra_reworked (2)`. The caller knows the
      // name that was asked for, so it says.
      final zip = _makeZip(path.join(tmp.path, 'Flat (2).zip'), {
        'mod.ini': '[m]',
        'hash.buf': 'b',
      });
      final dest = Directory(path.join(tmp.path, 'out_named'))
        ..createSync(recursive: true);

      final result = await ArchiveService.extractArchive(
        archiveFile: zip,
        destinationDir: dest,
        nameHint: 'Flat.zip',
      );

      expect(result.success, isTrue, reason: result.error);
      expect(path.basename(result.extractedFolders!.single), 'Flat');
    });

    test('D3: with no hint the file name is still what it is called', () async {
      // A folder dragged or an archive the user picked themselves: nobody
      // renamed it, so its own name is the right one.
      final zip = _makeZip(path.join(tmp.path, 'Untouched.zip'), {
        'mod.ini': '[m]',
      });

      final folders = await extractFolders(zip);
      expect(path.basename(folders.single), 'Untouched');
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

  group('deleting an unpack', () {
    test('takes the whole extraction directory, for mods that came out a level down as well', () async {
      final zip = _makeZip(path.join(tmp.path, 'jiggleforge.zip'), {
        'INSTALL-en.txt': 'read me',
        'Mods/JiggleForgeShaderFix/JiggleForge.ini': '[Constants]',
        'ShaderFixes/1f6ab42231416fdb-vs_replace.txt': 'shader',
      });
      final result = await ArchiveService.extractArchive(archiveFile: zip, freeSpace: (_) async => null);
      expect(result.success, isTrue, reason: result.error);
      final folder = result.extractedFolders!.single;
      final root = Directory(folder).parent.parent;
      expect(path.basename(root.path), startsWith('zzz_archive_extract_'), reason: 'the ZZMI-root layout under test');

      await ArchiveService.deleteExtraction(result.extractedFolders!);

      expect(root.existsSync(), isFalse);
    });

    test('leaves a folder no unpack created alone', () async {
      final folder = Directory(path.join(tmp.path, 'library', 'Ellen'))..createSync(recursive: true);

      await ArchiveService.deleteExtraction([folder.path]);

      expect(folder.existsSync(), isTrue);
    });
  });

  group('archive fingerprint', () {
    // The archive is deleted after a successful install and a zip cannot be
    // reproduced byte-for-byte from its extracted files, so this hash is the
    // only residue that survives. If it isn't taken here, it is gone.
    test('a successful extraction reports the archive md5', () async {
      final zip = _makeZip(path.join(tmp.path, 'Mod.zip'), {
        'Mod/mod.ini': '[Key]',
      });
      final dest = Directory(path.join(tmp.path, 'out'))..createSync();

      final result = await ArchiveService.extractArchive(
        archiveFile: zip,
        destinationDir: dest,
      );

      expect(result.success, isTrue);
      expect(result.archiveMd5, isNotNull);
      expect(result.archiveMd5, await md5OfFile(zip));
    });

    test('knownMd5 is returned verbatim and never verified', () async {
      // Documents the contract as much as it tests it: the download path has
      // already hashed the bytes in-stream, and re-reading a 1.24 GB file to
      // "check" that would defeat the entire point of passing it.
      final zip = _makeZip(path.join(tmp.path, 'Mod.zip'), {
        'Mod/mod.ini': '[Key]',
      });
      final dest = Directory(path.join(tmp.path, 'out'))..createSync();
      const wrongButWellFormed = '00000000000000000000000000000000';

      final result = await ArchiveService.extractArchive(
        archiveFile: zip,
        destinationDir: dest,
        knownMd5: wrongButWellFormed,
      );

      expect(result.archiveMd5, wrongButWellFormed);
      expect(result.archiveMd5, isNot(await md5OfFile(zip)));
    });

    test('a failed extraction carries no md5', () async {
      final notAnArchive = File(path.join(tmp.path, 'mod.tar.gz'))
        ..writeAsStringSync('nope');
      final dest = Directory(path.join(tmp.path, 'out'))..createSync();

      final result = await ArchiveService.extractArchive(
        archiveFile: notAnArchive,
        destinationDir: dest,
      );

      expect(result.success, isFalse);
      expect(result.archiveMd5, isNull);
    });

    test('works for 7z too, where bytes never enter Dart', () async {
      // The reason the hash is taken in extractArchive rather than in the zip
      // decoder: 7z/rar are extracted by shelling out, so a hash computed
      // inside _extractZip would silently cover only zips.
      final source = Directory(path.join(tmp.path, 'src', 'Mod'))
        ..createSync(recursive: true);
      File(path.join(source.path, 'mod.ini')).writeAsStringSync('[Key]');

      final archivePath = path.join(tmp.path, 'Mod.7z');
      final made = Process.runSync(
        _sevenZip!,
        ['a', archivePath, path.join(tmp.path, 'src', 'Mod')],
      );
      expect(made.exitCode, 0, reason: made.stderr.toString());

      final dest = Directory(path.join(tmp.path, 'out'))..createSync();
      final result = await ArchiveService.extractArchive(
        archiveFile: File(archivePath),
        destinationDir: dest,
      );

      expect(result.success, isTrue, reason: result.error);
      expect(result.archiveMd5, await md5OfFile(File(archivePath)));
    }, skip: _sevenZip == null ? '7z not installed' : null);
  });

  group('the space preflight', () {
    /// The unpacked size of a zip whose contents are known, so a test can ask
    /// for exactly one byte less than it needs.
    Map<String, String> entries() => {
          'Mod/mod.ini': 'x' * 1000,
          'Mod/body.dds': 'y' * 4000,
        };

    test('an archive is sized without unpacking it', () async {
      final zip = _makeZip(path.join(tmp.path, 'Mod.zip'), entries());

      // The central directory carries every entry's uncompressed size, so this
      // is a seek rather than a read — which is what makes it affordable in
      // front of a 1.24 GB archive.
      expect(await ArchiveService.unpackedSize(zip), 5000);
    });

    test('an unpack that does not fit is refused, and writes nothing',
        () async {
      final zip = _makeZip(path.join(tmp.path, 'Mod.zip'), entries());
      final dest = Directory(path.join(tmp.path, 'out'))..createSync();

      final result = await ArchiveService.extractArchive(
        archiveFile: File(zip.path),
        destinationDir: dest,
        freeSpace: (_) async => 4999,
      );

      expect(result.success, isFalse);
      expect(result.failure, ExtractFailure.insufficientSpace);
      expect(result.requiredBytes, 5000);
      expect(result.availableBytes, 4999);
      expect(dest.listSync(), isEmpty,
          reason: 'a refusal must not leave half an unpack behind');
      expect(zip.existsSync(), isTrue,
          reason: 'the archive is the way out, so it stays');
    });

    test('an unpack that fits exactly is allowed', () async {
      // The boundary in the direction that matters: refusing an install that
      // would have worked leaves the user with no way to install it at all.
      final zip = _makeZip(path.join(tmp.path, 'Mod.zip'), entries());
      final dest = Directory(path.join(tmp.path, 'out'))..createSync();

      final result = await ArchiveService.extractArchive(
        archiveFile: File(zip.path),
        destinationDir: dest,
        freeSpace: (_) async => 5000,
      );

      expect(result.success, isTrue, reason: result.error);
    });

    test('an unknown free space unpacks anyway', () async {
      final zip = _makeZip(path.join(tmp.path, 'Mod.zip'), entries());
      final dest = Directory(path.join(tmp.path, 'out'))..createSync();

      final result = await ArchiveService.extractArchive(
        archiveFile: File(zip.path),
        destinationDir: dest,
        freeSpace: (_) async => null,
      );

      expect(result.success, isTrue, reason: result.error);
    });

    test('the volume asked about is the one being written to', () async {
      // Not the archive's own directory: a download sits in `<appData>` and is
      // unpacked into a temp dir, which on most Linux desktops is a tmpfs — a
      // different volume with a different, much smaller, amount of room.
      final zip = _makeZip(path.join(tmp.path, 'Mod.zip'), entries());
      final dest = Directory(path.join(tmp.path, 'out'))..createSync();

      final asked = <String>[];
      await ArchiveService.extractArchive(
        archiveFile: File(zip.path),
        destinationDir: dest,
        freeSpace: (p) async {
          asked.add(p);
          return 1 << 30;
        },
      );

      expect(asked, [dest.path]);
    });

    test('a 7z is sized by the tool that will unpack it', () async {
      final source = Directory(path.join(tmp.path, 'src', 'Mod'))
        ..createSync(recursive: true);
      File(path.join(source.path, 'mod.ini')).writeAsStringSync('x' * 1000);
      File(path.join(source.path, 'body.dds')).writeAsStringSync('y' * 4000);

      final archivePath = path.join(tmp.path, 'Mod.7z');
      final made = Process.runSync(
        _sevenZip!,
        ['a', archivePath, path.join(tmp.path, 'src', 'Mod')],
      );
      expect(made.exitCode, 0, reason: made.stderr.toString());

      // The listing's own numbers, not the archive's size on disk: this one
      // compresses 5 KB of repeated bytes down to a few hundred.
      expect(await ArchiveService.unpackedSize(File(archivePath)), 5000);
    }, skip: _sevenZip == null ? '7z not installed' : null);

    test('a 7z that does not fit is refused too', () async {
      final source = Directory(path.join(tmp.path, 'src', 'Mod'))
        ..createSync(recursive: true);
      File(path.join(source.path, 'mod.ini')).writeAsStringSync('x' * 5000);

      final archivePath = path.join(tmp.path, 'Mod.7z');
      Process.runSync(
        _sevenZip!,
        ['a', archivePath, path.join(tmp.path, 'src', 'Mod')],
      );

      final dest = Directory(path.join(tmp.path, 'out'))..createSync();
      final result = await ArchiveService.extractArchive(
        archiveFile: File(archivePath),
        destinationDir: dest,
        freeSpace: (_) async => 100,
      );

      expect(result.failure, ExtractFailure.insufficientSpace);
      expect(result.requiredBytes, 5000);
      expect(dest.listSync(), isEmpty);
    }, skip: _sevenZip == null ? '7z not installed' : null);

    test('a 7z of many files is sized in full, not to the first few hundred',
        () async {
      // `7z l -slt` prints a block per entry, so a mod with a few hundred files
      // — a texture pack, a character overhaul, a UI bundle — runs past any cap
      // meant for a diagnostic banner. A cut listing still parses and still
      // exits 0: it just sums to less than the archive holds, and says an
      // install fits when it does not.
      final source = Directory(path.join(tmp.path, 'src', 'Mod'))
        ..createSync(recursive: true);
      for (var i = 0; i < 600; i++) {
        File(path.join(source.path, 'tex$i.dds')).writeAsStringSync('z' * 1024);
      }

      final archivePath = path.join(tmp.path, 'Many.7z');
      final made = Process.runSync(
        _sevenZip!,
        ['a', archivePath, path.join(tmp.path, 'src', 'Mod')],
      );
      expect(made.exitCode, 0, reason: made.stderr.toString());

      expect(await ArchiveService.unpackedSize(File(archivePath)), 600 * 1024);
    }, skip: _sevenZip == null ? '7z not installed' : null);

    test('an unsupported format is not sized, and not refused', () async {
      // Nothing here can unpack a `.tar.gz`, so the extraction reports the
      // format — a space refusal in front of that would name the wrong problem.
      final notAnArchive = File(path.join(tmp.path, 'mod.tar.gz'))
        ..writeAsStringSync('not really');

      expect(await ArchiveService.unpackedSize(notAnArchive), isNull);

      final result = await ArchiveService.extractArchive(
        archiveFile: notAnArchive,
        destinationDir: Directory(path.join(tmp.path, 'out'))..createSync(),
        freeSpace: (_) async => 0,
      );

      expect(result.failure, ExtractFailure.other);
    });
  });

  group('the folder an unpack makes', () {
    // The system temp folder is pointed into this test's own, so a folder left behind can be seen apart from other
    // tests' work.
    late Directory systemTemp;
    setUp(() {
      systemTemp = Directory(path.join(tmp.path, 'system_temp'))..createSync();
      IOOverrides.global = SystemTempIn(systemTemp);
    });
    tearDown(() => IOOverrides.global = null);

    List<String> leftOver() => [
          for (final entry in systemTemp.listSync())
            if (path.basename(entry.path).startsWith('zzz_archive_extract_')) path.basename(entry.path),
        ];

    /// Unpacks [archive] into a folder of the unpack's own making, and returns the result with that folder, which
    /// the free-space question names and which is checked to exist while the unpack runs.
    Future<(ArchiveExtractionResult, String)> unpack(File archive, {int? Function()? free}) async {
      String? into;
      final result = await ArchiveService.extractArchive(
        archiveFile: archive,
        freeSpace: (asked) async {
          into = asked;
          expect(Directory(asked).existsSync(), isTrue, reason: 'the unpack made its folder');
          return free == null ? null : free();
        },
      );
      expect(into, isNotNull, reason: 'the size was read, so the folder was made before the failure under test');
      return (result, into!);
    }

    test('is deleted when the unpack is refused for space', () async {
      final zip = _makeZip(path.join(tmp.path, 'Mod.zip'), {'Mod/mod.ini': 'x' * 5000});

      final (result, into) = await unpack(zip, free: () => 10);

      expect(result.failure, ExtractFailure.insufficientSpace);
      expect(Directory(into).existsSync(), isFalse);
      expect(leftOver(), isEmpty);
    });

    test('is deleted when the unpack fails for a reason other than a password', () async {
      // Stored rather than deflated, so a flipped byte in the entry's data fails its checksum at the unpack while
      // the central directory still lists it.
      final bytes = 'x' * 5000;
      final archive = Archive()..addFile(ArchiveFile('Mod/mod.ini', bytes.length, bytes.codeUnits)..compress = false);
      final encoded = ZipEncoder().encode(archive)!;
      encoded[100] ^= 0xff;
      final zip = File(path.join(tmp.path, 'Broken.zip'))..writeAsBytesSync(encoded);

      final (result, into) = await unpack(zip);

      expect(result.success, isFalse);
      expect(result.failure, ExtractFailure.other);
      expect(Directory(into).existsSync(), isFalse);
      expect(leftOver(), isEmpty);
    });

    test('is deleted when the archive holds no mod folder', () async {
      // An empty `Mods/` in the ZZMI layout: nothing in it to import.
      final zip = _makeZip(path.join(tmp.path, 'Empty.zip'), {'Mods/readme.txt': 'nothing here'});

      final (result, into) = await unpack(zip);

      expect(result.error, 'The archive contains no mod folders');
      expect(Directory(into).existsSync(), isFalse);
      expect(leftOver(), isEmpty);
    });

    test('is deleted when the unpack throws', () async {
      final zip = _makeZip(path.join(tmp.path, 'Mod.zip'), {'Mod/mod.ini': 'x' * 5000});

      final (result, into) = await unpack(zip, free: () => throw const FileSystemException('df failed'));

      expect(result.success, isFalse);
      expect(result.error, startsWith('Extraction failed'));
      expect(Directory(into).existsSync(), isFalse);
      expect(leftOver(), isEmpty);
    });

    test('is handed to the caller on success, the whole of it for mods a level down', () async {
      final zip = _makeZip(path.join(tmp.path, 'Layout.zip'), {'Mods/Ellen/Ellen.ini': '[Constants]'});

      final (result, into) = await unpack(zip);

      expect(result.success, isTrue, reason: result.error);
      expect(result.extractionRoot, into);
      expect(path.dirname(path.dirname(result.extractedFolders!.single)), into,
          reason: 'the root, not the parent of the first folder');
      expect(Directory(into).existsSync(), isTrue, reason: 'the caller deletes it once done with the folders');
    });

    test('a destination the caller passed is left to the caller on a failure', () async {
      final zip = _makeZip(path.join(tmp.path, 'Mod.zip'), {'Mod/mod.ini': 'x' * 5000});
      final dest = Directory(path.join(tmp.path, 'out'))..createSync();

      final result = await ArchiveService.extractArchive(
        archiveFile: zip,
        destinationDir: dest,
        freeSpace: (_) async => 10,
      );

      expect(result.failure, ExtractFailure.insufficientSpace);
      expect(dest.existsSync(), isTrue);
    });
  });

  group('a listing taken before the unpack', () {
    // Each test lists one archive, then swaps a bigger one in under the same name: an unpack that reads the listing
    // it was handed sizes the small one and fits, and one that lists again sizes the big one and is refused.
    test('is what the unpack sizes a zip by, rather than listing it again', () async {
      final zip = _makeZip(path.join(tmp.path, 'Mod.zip'), {'Mod/mod.ini': 'x' * 1000});
      final listing = await ArchiveService.listArchive(zip);
      expect(listing.needsPassword, isFalse);
      _makeZip(zip.path, {'Mod/mod.ini': 'x' * 9000});

      Future<ArchiveExtractionResult> unpack({ArchiveListing? listing}) => ArchiveService.extractArchive(
            archiveFile: zip,
            destinationDir: Directory(path.join(tmp.path, 'out_${DateTime.now().microsecondsSinceEpoch}'))
              ..createSync(),
            freeSpace: (_) async => 5000,
            listing: listing,
          );

      expect((await unpack(listing: listing)).success, isTrue, reason: 'sized from the listing it was handed');
      expect((await unpack()).failure, ExtractFailure.insufficientSpace, reason: 'the swap is what a new listing sees');
    });

    test('is what the unpack sizes a 7z by too', () async {
      File make(String name, int size) {
        final source = Directory(path.join(tmp.path, name, 'Mod'))..createSync(recursive: true);
        File(path.join(source.path, 'mod.ini')).writeAsStringSync('x' * size);
        final archivePath = path.join(tmp.path, '$name.7z');
        final made = Process.runSync(_sevenZip!, ['a', archivePath, source.path]);
        expect(made.exitCode, 0, reason: made.stderr.toString());
        return File(archivePath);
      }

      final archive = make('small', 1000);
      final listing = await ArchiveService.listArchive(archive);
      make('big', 9000).renameSync(archive.path);

      final result = await ArchiveService.extractArchive(
        archiveFile: archive,
        destinationDir: Directory(path.join(tmp.path, 'out'))..createSync(),
        freeSpace: (_) async => 5000,
        listing: listing,
      );

      expect(result.success, isTrue, reason: result.error);
    }, skip: _sevenZip == null ? '7z not installed' : null);

    test("is ignored when it is another archive's", () async {
      final other = _makeZip(path.join(tmp.path, 'Other.zip'), {'Mod/mod.ini': 'x'});
      final zip = _makeZip(path.join(tmp.path, 'Mod.zip'), {'Mod/mod.ini': 'x' * 9000});

      final result = await ArchiveService.extractArchive(
        archiveFile: zip,
        destinationDir: Directory(path.join(tmp.path, 'out'))..createSync(),
        freeSpace: (_) async => 5000,
        listing: await ArchiveService.listArchive(other),
      );

      expect(result.failure, ExtractFailure.insufficientSpace);
    });
  });
}