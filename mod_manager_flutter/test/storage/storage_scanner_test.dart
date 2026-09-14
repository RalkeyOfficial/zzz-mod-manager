import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/core/constants.dart';
import 'package:mod_manager_flutter/services/storage/storage_roots.dart';
import 'package:mod_manager_flutter/services/storage/storage_scanner.dart';
import 'package:mod_manager_flutter/services/storage/storage_usage.dart';
import 'package:path/path.dart' as path;

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('storage_scanner_test_');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Directory dir(String relative) =>
      Directory(path.join(root.path, relative))..createSync(recursive: true);

  void write(String relative, int bytes) {
    final file = File(path.join(root.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(List<int>.filled(bytes, 0));
  }

  StorageRoots rootsWith({String? library}) => StorageRoots(
        appData: dir('appdata'),
        downloads: Directory(path.join(root.path, 'appdata', 'downloads')),
        logs: Directory(path.join(root.path, 'appdata', 'logs')),
        legacyImages: Directory(path.join(root.path, 'appdata', 'mod_images')),
        backups: Directory(path.join(root.path, 'appdata', 'backups')),
        temp: dir('temp'),
        modsLibrary: library == null ? null : Directory(library),
      );

  group('the library, split at the sidecar', () {
    test('mods and covers are disjoint and sum to the folder', () async {
      final library = dir('mods').path;
      write('mods/Ellen/body.ini', 400);
      write('mods/Ellen/${AppConstants.modMetadataDirName}/metadata.json', 30);
      write('mods/Ellen/${AppConstants.modMetadataDirName}/images/00.png', 70);
      write('mods/Nicole/body.ini', 200);

      final scanner = StorageScanner(rootsWith(library: library));
      final mods = await scanner.mods();
      final sidecars = await scanner.sidecars();

      expect(mods.bytes, 600, reason: 'the mods own files only');
      expect(sidecars.bytes, 100, reason: 'the sidecars only');
      expect(mods.bytes + sidecars.bytes, 700,
          reason: 'the slices must sum to the library, never past it');
    });

    test('both halves come from one walk', () async {
      final library = dir('mods').path;
      write('mods/Ellen/body.ini', 400);

      final scanner = StorageScanner(rootsWith(library: library));
      await scanner.mods();
      // Deleting between the two calls proves the second did not re-walk.
      Directory(path.join(library, 'Ellen')).deleteSync(recursive: true);

      expect((await scanner.sidecars()).read, StorageRead.ok);
      expect((await scanner.mods()).bytes, 400);
    });

    test('a mod with no sidecar contributes no cover bytes', () async {
      final library = dir('mods').path;
      write('mods/Ellen/body.ini', 400);

      final scanner = StorageScanner(rootsWith(library: library));

      expect((await scanner.sidecars()).bytes, 0);
      expect((await scanner.sidecars()).items, isEmpty);
    });

    test('folders the library scan skips are skipped here too', () async {
      final library = dir('mods').path;
      write('mods/Ellen/body.ini', 400);
      write('mods/.hidden/junk.bin', 5000);
      write('mods/__staging/junk.bin', 5000);

      final scanner = StorageScanner(rootsWith(library: library));

      expect((await scanner.mods()).bytes, 400,
          reason: 'counting them would describe a library the app disbelieves');
    });

    test('an unreadable sidecar makes the covers a floor, not the mods',
        () async {
      // The whole-folder walk covers the sidecar too, so a failure in there
      // lands in both counts. Attributing it to Mods marks a figure that is
      // exact as approximate, and leaves the category that really did
      // under-read claiming a clean total — the opposite of the guarantee.
      final library = dir('mods').path;
      write('mods/Ellen/body.ini', 400);
      write('mods/Ellen/${AppConstants.modMetadataDirName}/metadata.json', 30);
      final locked = dir(
          'mods/Ellen/${AppConstants.modMetadataDirName}/images');
      write('mods/Ellen/${AppConstants.modMetadataDirName}/images/00.png', 900);
      Process.runSync('chmod', ['000', locked.path]);
      addTearDown(() => Process.runSync('chmod', ['755', locked.path]));

      final scanner = StorageScanner(rootsWith(library: library));
      final mods = await scanner.mods();
      final sidecars = await scanner.sidecars();

      expect(mods.read, StorageRead.ok);
      expect(mods.bytes, 400, reason: 'the mod\'s own files were all readable');
      expect(sidecars.read, StorageRead.partial);
      expect(sidecars.bytes, 30, reason: 'a floor: the images are missing');
    }, testOn: 'linux');

    test('an unreadable mod file makes the mods a floor, not the covers',
        () async {
      final library = dir('mods').path;
      write('mods/Ellen/body.ini', 400);
      write('mods/Ellen/${AppConstants.modMetadataDirName}/metadata.json', 30);
      final locked = dir('mods/Ellen/textures');
      write('mods/Ellen/textures/big.dds', 5000);
      Process.runSync('chmod', ['000', locked.path]);
      addTearDown(() => Process.runSync('chmod', ['755', locked.path]));

      final scanner = StorageScanner(rootsWith(library: library));

      expect((await scanner.mods()).read, StorageRead.partial);
      expect((await scanner.sidecars()).read, StorageRead.ok);
    }, testOn: 'linux');

    test('no library configured is not a zero-byte library', () async {
      final scanner = StorageScanner(rootsWith());

      final mods = await scanner.mods();

      expect(mods.read, StorageRead.notConfigured);
      expect(mods.hasMeasurement, isFalse,
          reason: '"not set" must not draw a slice or read as "you have none"');
    });

    test('a configured library that is gone reads as absent', () async {
      final scanner =
          StorageScanner(rootsWith(library: path.join(root.path, 'missing')));

      final mods = await scanner.mods();

      expect(mods.read, StorageRead.absent);
      expect(mods.rootPath, endsWith('missing'));
    });

    test('a linked mod folder says so instead of reporting nothing', () async {
      final library = dir('mods').path;
      final elsewhere = dir('elsewhere');
      File(path.join(elsewhere.path, 'big.bin'))
          .writeAsBytesSync(List<int>.filled(8000, 0));
      write('mods/Ellen/body.ini', 400);
      Link(path.join(library, 'Linked')).createSync(elsewhere.path);

      final scanner = StorageScanner(rootsWith(library: library));
      final mods = await scanner.mods();

      expect(mods.bytes, 400, reason: 'a link holds no bytes of its own');
      final linked = mods.items.firstWhere((i) => i.id == 'Linked');
      expect(linked.kind, StorageItemKind.linked);
    }, testOn: 'linux || mac-os');
  });

  group('the flat stores', () {
    test('downloads tell an archive from a partial', () async {
      dir('appdata/downloads');
      write('appdata/downloads/mod.rar', 500);
      write('appdata/downloads/other.rar.part', 120);
      write('appdata/downloads/other.rar.part.json', 40);

      final category = await StorageScanner(rootsWith()).downloads();

      expect(category.bytes, 660);
      expect(
        category.items.firstWhere((i) => i.id == 'mod.rar').kind,
        StorageItemKind.archive,
      );
      expect(
        category.items.firstWhere((i) => i.id == 'other.rar.part').kind,
        StorageItemKind.partialDownload,
      );
    });

    test('a downloads folder that was never created is empty, not absent',
        () async {
      final category = await StorageScanner(rootsWith()).downloads();

      expect(category.read, StorageRead.ok,
          reason: 'nothing downloaded yet is not a fault to report');
      expect(category.bytes, 0);
    });
  });

  group('leftovers', () {
    test('legacy images and abandoned extractions are counted together',
        () async {
      write('appdata/mod_images/Ellen.png', 300);
      write('temp/${archiveExtractPrefix}abc/inner/file.bin', 700);
      write('temp/unrelated/file.bin', 9999);

      final category = await StorageScanner(rootsWith()).leftovers();

      expect(category.bytes, 1000,
          reason: 'only our own prefix, never the rest of temp');
      expect(category.items.map((i) => i.id),
          containsAll(<String>['Ellen.png', '${archiveExtractPrefix}abc']));
    });

    test('nothing left over is zero', () async {
      final category = await StorageScanner(rootsWith()).leftovers();

      expect(category.bytes, 0);
      expect(category.read, StorageRead.ok);
    });
  });
}
