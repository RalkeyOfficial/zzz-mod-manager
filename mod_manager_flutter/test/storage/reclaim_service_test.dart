import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/core/constants.dart';
import 'package:mod_manager_flutter/services/log/log_rotation.dart';
import 'package:mod_manager_flutter/services/storage/reclaim_plan.dart';
import 'package:mod_manager_flutter/services/storage/reclaim_service.dart';
import 'package:mod_manager_flutter/services/storage/storage_roots.dart';
import 'package:path/path.dart' as path;

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('reclaim_service_test_');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  File write(String relative, int bytes, {Duration? age}) {
    final file = File(path.join(root.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(List<int>.filled(bytes, 0));
    if (age != null) {
      file.setLastModifiedSync(DateTime.now().subtract(age));
    }
    return file;
  }

  /// Roots entirely inside a temp directory. Not a nicety — the real ones point
  /// at the developer's own downloads and `/tmp`, and this service deletes.
  StorageRoots rootsIn({String? library, String? currentLog}) => StorageRoots(
        appData: Directory(path.join(root.path, 'appdata'))
          ..createSync(recursive: true),
        downloads: Directory(path.join(root.path, 'appdata', 'downloads')),
        logs: Directory(path.join(root.path, 'appdata', 'logs')),
        legacyImages: Directory(path.join(root.path, 'appdata', 'mod_images')),
        backups: Directory(path.join(root.path, 'appdata', 'backups')),
        temp: Directory(path.join(root.path, 'temp'))
          ..createSync(recursive: true),
        modsLibrary: library == null ? null : Directory(library),
        currentLogFile: currentLog,
      );

  ReclaimService serviceOver(
    StorageRoots roots, {
    bool downloadsBusy = false,
    bool installBusy = false,
    Set<String>? mods = const <String>{},
  }) =>
      ReclaimService(
        roots,
        downloadsBusy: () => downloadsBusy,
        installBusy: () => installBusy,
        modNames: () async => mods,
      );

  bool exists(String relative) => File(path.join(root.path, relative)).existsSync();

  group('downloads', () {
    test('a leftover archive goes and its bytes are reported', () async {
      write('appdata/downloads/mod.rar', 500);

      final outcome = await serviceOver(rootsIn()).run();

      expect(exists('appdata/downloads/mod.rar'), isFalse);
      expect(outcome.freedBytes, 500);
      expect(outcome.removedCount, 1);
    });

    test('a running transfer stops the sweep touching the folder', () async {
      write('appdata/downloads/mod.rar', 500);

      final outcome =
          await serviceOver(rootsIn(), downloadsBusy: true).run();

      expect(exists('appdata/downloads/mod.rar'), isTrue);
      expect(outcome.freedBytes, 0);
      expect(
        outcome.refused.map((r) => r.refusal),
        contains(ReclaimSkipReason.downloadsActive),
      );
    });

    test('a resumable partial is left alone even with an idle queue', () async {
      write('appdata/downloads/mod.rar.part', 200, age: const Duration(hours: 2));
      write('appdata/downloads/mod.rar.part.json', 40,
          age: const Duration(hours: 2));

      await serviceOver(rootsIn()).run();

      expect(exists('appdata/downloads/mod.rar.part'), isTrue,
          reason: 'a week has not passed, so this is still resumable');
    });

    test('an orphaned part with no record is wreckage and goes', () async {
      write('appdata/downloads/mod.rar.part', 200);

      await serviceOver(rootsIn()).run();

      expect(exists('appdata/downloads/mod.rar.part'), isFalse);
    });

    test('a pair abandoned for over a week goes', () async {
      write('appdata/downloads/old.rar.part', 200, age: const Duration(days: 9));
      write('appdata/downloads/old.rar.part.json', 40,
          age: const Duration(days: 9));

      await serviceOver(rootsIn()).run();

      expect(exists('appdata/downloads/old.rar.part'), isFalse);
      expect(exists('appdata/downloads/old.rar.part.json'), isFalse);
    });
  });

  group('extraction leftovers', () {
    test('an abandoned extraction goes', () async {
      // Flat, because every entry counts: a freshly-created subdirectory is
      // itself a recent write, which is exactly the conservatism the rule wants
      // and would make this fixture look like a live extraction.
      write('temp/zzz_archive_extract_old/file.bin', 700,
          age: const Duration(hours: 6));

      await serviceOver(rootsIn()).run();

      expect(
        Directory(path.join(root.path, 'temp', 'zzz_archive_extract_old'))
            .existsSync(),
        isFalse,
      );
    });

    test('a directory whose inner file is new survives', () async {
      // The directory's own mtime stops changing once its top-level entries
      // exist, so a deep extraction still writing underneath looks idle from
      // the outside. Reading the inside is what stops this deleting a live one.
      final dir = Directory(
          path.join(root.path, 'temp', 'zzz_archive_extract_live'))
        ..createSync(recursive: true);
      write('temp/zzz_archive_extract_live/inner/fresh.bin', 10);
      // Aged from the outside only: Dart cannot set a directory's mtime, and
      // the point of the test is that the outside is the misleading signal.
      Process.runSync('touch', ['-d', '2 days ago', dir.path]);

      await serviceOver(rootsIn()).run();

      expect(dir.existsSync(), isTrue);
    }, testOn: 'linux || mac-os');

    test('someone else\'s temp folder is never touched', () async {
      write('temp/someone_elses_work/file.bin', 400,
          age: const Duration(days: 30));

      await serviceOver(rootsIn()).run();

      expect(exists('temp/someone_elses_work/file.bin'), isTrue);
    });
  });

  group('legacy images', () {
    String libraryWith(List<String> mods, {List<String> withSidecar = const []}) {
      final library = Directory(path.join(root.path, 'mods'))
        ..createSync(recursive: true);
      for (final mod in mods) {
        Directory(path.join(library.path, mod)).createSync(recursive: true);
        if (withSidecar.contains(mod)) {
          File(path.join(library.path, mod, AppConstants.modMetadataDirName,
              AppConstants.modMetadataFileName))
            ..parent.createSync(recursive: true)
            ..writeAsStringSync('{}');
        }
      }
      return library.path;
    }

    test('an image whose mod is gone goes', () async {
      write('appdata/mod_images/Deleted.png', 300);
      final library = libraryWith(['Ellen']);

      await serviceOver(rootsIn(library: library), mods: {'Ellen'}).run();

      expect(exists('appdata/mod_images/Deleted.png'), isFalse);
    });

    test('the only copy of a live mod\'s cover is kept', () async {
      write('appdata/mod_images/Ellen.png', 300);
      final library = libraryWith(['Ellen']);

      await serviceOver(rootsIn(library: library), mods: {'Ellen'}).run();

      expect(exists('appdata/mod_images/Ellen.png'), isTrue,
          reason: 'a mod with no sidecar still reads its cover from here');
    });

    test('an image whose mod has migrated is dead weight and goes', () async {
      write('appdata/mod_images/Ellen.png', 300);
      final library = libraryWith(['Ellen'], withSidecar: ['Ellen']);

      await serviceOver(rootsIn(library: library), mods: {'Ellen'}).run();

      expect(exists('appdata/mod_images/Ellen.png'), isFalse);
    });

    test('an unreadable library sweeps none of them', () async {
      // Handed no library, every image looks unreachable — and taking the lot
      // destroys the user's only copy of every cover.
      write('appdata/mod_images/Ellen.png', 300);
      write('appdata/mod_images/Nicole.png', 300);

      final outcome =
          await serviceOver(rootsIn(), mods: null).run();

      expect(exists('appdata/mod_images/Ellen.png'), isTrue);
      expect(exists('appdata/mod_images/Nicole.png'), isTrue);
      expect(
        outcome.refused.map((r) => r.refusal),
        contains(ReclaimSkipReason.libraryUnreadable),
      );
    });
  });

  group('logs', () {
    test('the oldest go and the newest seven stay', () async {
      for (var i = 0; i < 10; i++) {
        write('appdata/logs/${logFileName(DateTime(2026, 1, i + 1))}', 10);
      }

      await serviceOver(rootsIn()).run();

      final left = Directory(path.join(root.path, 'appdata', 'logs'))
          .listSync()
          .length;
      expect(left, 7);
    });

    test('this run\'s own log survives', () async {
      final current = logFileName(DateTime(2026, 1, 1));
      for (var i = 0; i < 10; i++) {
        write('appdata/logs/${logFileName(DateTime(2026, 1, i + 1))}', 10);
      }

      await serviceOver(
        rootsIn(currentLog: path.join(root.path, 'appdata', 'logs', current)),
      ).run();

      expect(exists('appdata/logs/$current'), isTrue);
    });

    test('a file the user left there is never deleted', () async {
      for (var i = 0; i < 10; i++) {
        write('appdata/logs/${logFileName(DateTime(2026, 1, i + 1))}', 10);
      }
      write('appdata/logs/notes.txt', 50);

      await serviceOver(rootsIn()).run();

      expect(exists('appdata/logs/notes.txt'), isTrue);
    });
  });

  group('what it must never touch', () {
    test('the library and the backups are not in its vocabulary', () async {
      final library = Directory(path.join(root.path, 'mods'))
        ..createSync(recursive: true);
      write('mods/Ellen/body.ini', 4000);
      write('appdata/backups/abc/20260101-000000-000/files/body.ini', 8000);
      write('appdata/downloads/mod.rar', 100);

      final outcome =
          await serviceOver(rootsIn(library: library.path), mods: {'Ellen'})
              .run();

      expect(exists('mods/Ellen/body.ini'), isTrue);
      expect(
        exists('appdata/backups/abc/20260101-000000-000/files/body.ini'),
        isTrue,
      );
      expect(outcome.freedBytes, 100, reason: 'only the archive was reclaimed');
    });

    test('nothing to do reports nothing rather than failing', () async {
      final outcome = await serviceOver(rootsIn()).run();

      expect(outcome.isEmpty, isTrue);
      expect(outcome.freedBytes, 0);
    });
  });
}
