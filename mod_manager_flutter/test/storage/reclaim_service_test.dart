import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/core/constants.dart';
import 'package:mod_manager_flutter/services/log/log_rotation.dart';
import 'package:mod_manager_flutter/services/storage/reclaim_plan.dart';
import 'package:mod_manager_flutter/services/storage/reclaim_service.dart';
import 'package:mod_manager_flutter/services/storage/storage_roots.dart';
import 'package:path/path.dart' as path;

/// Every store, as a test of the sweep itself asks for them all.
final Set<ReclaimTarget> everything = ReclaimTarget.values.toSet();

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
    Set<String>? uids = const <String>{},
  }) =>
      ReclaimService(
        roots,
        downloadsBusy: () => downloadsBusy,
        installBusy: () => installBusy,
        modNames: () async => mods,
        claimedSnapshotUids: () async => uids,
      );

  bool exists(String relative) => File(path.join(root.path, relative)).existsSync();

  /// A library folder that is there, as one the scan can read.
  String existingLibrary() {
    final library = Directory(path.join(root.path, 'mods'))..createSync(recursive: true);
    return library.path;
  }

  group('downloads', () {
    test('a leftover archive goes and its bytes are reported', () async {
      write('appdata/downloads/mod.rar', 500);

      final outcome = await serviceOver(rootsIn()).run(everything);

      expect(exists('appdata/downloads/mod.rar'), isFalse);
      expect(outcome.freedBytes, 500);
      expect(outcome.removedCount, 1);
    });

    test('a running transfer stops the sweep touching the folder', () async {
      write('appdata/downloads/mod.rar', 500);

      final outcome =
          await serviceOver(rootsIn(), downloadsBusy: true).run(everything);

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

      await serviceOver(rootsIn()).run(everything);

      expect(exists('appdata/downloads/mod.rar.part'), isTrue,
          reason: 'a week has not passed, so this is still resumable');
    });

    test('an orphaned part with no record is wreckage and goes', () async {
      write('appdata/downloads/mod.rar.part', 200);

      await serviceOver(rootsIn()).run(everything);

      expect(exists('appdata/downloads/mod.rar.part'), isFalse);
    });

    test('a pair abandoned for over a week goes', () async {
      write('appdata/downloads/old.rar.part', 200, age: const Duration(days: 9));
      write('appdata/downloads/old.rar.part.json', 40,
          age: const Duration(days: 9));

      await serviceOver(rootsIn()).run(everything);

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

      await serviceOver(rootsIn()).run(everything);

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

      await serviceOver(rootsIn()).run(everything);

      expect(dir.existsSync(), isTrue);
    }, testOn: 'linux || mac-os');

    test('someone else\'s temp folder is never touched', () async {
      write('temp/someone_elses_work/file.bin', 400,
          age: const Duration(days: 30));

      await serviceOver(rootsIn()).run(everything);

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

      await serviceOver(rootsIn(library: library), mods: {'Ellen'}).run(everything);

      expect(exists('appdata/mod_images/Deleted.png'), isFalse);
    });

    test('the only copy of a live mod\'s cover is kept', () async {
      write('appdata/mod_images/Ellen.png', 300);
      final library = libraryWith(['Ellen']);

      await serviceOver(rootsIn(library: library), mods: {'Ellen'}).run(everything);

      expect(exists('appdata/mod_images/Ellen.png'), isTrue,
          reason: 'a mod with no sidecar still reads its cover from here');
    });

    test('an image whose mod has migrated is dead weight and goes', () async {
      write('appdata/mod_images/Ellen.png', 300);
      final library = libraryWith(['Ellen'], withSidecar: ['Ellen']);

      await serviceOver(rootsIn(library: library), mods: {'Ellen'}).run(everything);

      expect(exists('appdata/mod_images/Ellen.png'), isFalse);
    });

    test('an unreadable library sweeps none of them', () async {
      // Handed no library, every image looks unreachable — and taking the lot
      // destroys the user's only copy of every cover.
      write('appdata/mod_images/Ellen.png', 300);
      write('appdata/mod_images/Nicole.png', 300);

      final outcome =
          await serviceOver(rootsIn(), mods: null).run(everything);

      expect(exists('appdata/mod_images/Ellen.png'), isTrue);
      expect(exists('appdata/mod_images/Nicole.png'), isTrue);
      expect(
        outcome.refused.map((r) => r.refusal),
        contains(ReclaimSkipReason.libraryUnreadable),
      );
    });

    test('a mod linked to a folder that is gone keeps the images and saved versions, under its own reason', () async {
      // The link is not in the scan, so its mod's image and versions read as nobody's.
      write('appdata/mod_images/Away.png', 300);
      write('appdata/backups/away/20260101-000000-000/files/body.ini', 8000);
      final library = libraryWith(['Ellen']);
      Link(path.join(library, 'Away')).createSync(path.join(root.path, 'unmounted', 'Away'));

      final outcome = await serviceOver(rootsIn(library: library), mods: {'Ellen'}, uids: <String>{})
          .run({ReclaimTarget.legacyImages, ReclaimTarget.unclaimedSnapshots});

      expect(exists('appdata/mod_images/Away.png'), isTrue);
      expect(exists('appdata/backups/away/20260101-000000-000/files/body.ini'), isTrue);
      expect(outcome.refused.map((r) => r.refusal), everyElement(ReclaimSkipReason.libraryHasDeadLink));
      expect(outcome.refused, hasLength(2));
    }, skip: Platform.isWindows);

    test('a library folder that is missing sweeps none of them, whatever the scan answered', () async {
      write('appdata/mod_images/Ellen.png', 300);
      final missing = path.join(root.path, 'unmounted', 'mods');

      final outcome = await serviceOver(rootsIn(library: missing), mods: <String>{}).run({ReclaimTarget.legacyImages});

      expect(exists('appdata/mod_images/Ellen.png'), isTrue);
      expect(outcome.refused.map((r) => r.refusal), [ReclaimSkipReason.libraryUnreadable]);
    });
  });

  group('logs', () {
    test('every log goes when none is running', () async {
      for (var i = 0; i < 10; i++) {
        write('appdata/logs/${logFileName(DateTime(2026, 1, i + 1))}', 10);
      }

      await serviceOver(rootsIn()).run(everything);

      final left = Directory(path.join(root.path, 'appdata', 'logs'))
          .listSync()
          .length;
      expect(left, 0);
    });

    test('only this run\'s log stays, however few there are', () async {
      final current = logFileName(DateTime(2026, 1, 3));
      for (var i = 0; i < 3; i++) {
        write('appdata/logs/${logFileName(DateTime(2026, 1, i + 1))}', 10);
      }

      await serviceOver(rootsIn(currentLog: path.join(root.path, 'appdata', 'logs', current))).run({ReclaimTarget.oldLogs});

      expect(Directory(path.join(root.path, 'appdata', 'logs')).listSync().map((e) => path.basename(e.path)), [current]);
    });

    test('this run\'s own log survives', () async {
      final current = logFileName(DateTime(2026, 1, 1));
      for (var i = 0; i < 10; i++) {
        write('appdata/logs/${logFileName(DateTime(2026, 1, i + 1))}', 10);
      }

      await serviceOver(
        rootsIn(currentLog: path.join(root.path, 'appdata', 'logs', current)),
      ).run(everything);

      expect(exists('appdata/logs/$current'), isTrue);
    });

    test('a file the user left there is never deleted', () async {
      for (var i = 0; i < 10; i++) {
        write('appdata/logs/${logFileName(DateTime(2026, 1, i + 1))}', 10);
      }
      write('appdata/logs/notes.txt', 50);

      await serviceOver(rootsIn()).run(everything);

      expect(exists('appdata/logs/notes.txt'), isTrue);
    });
  });

  group('saved versions', () {
    test('a group no mod claims goes, with its bytes reported', () async {
      write('appdata/backups/dead/20260101-000000-000/files/body.ini', 8000);

      final outcome = await serviceOver(rootsIn(library: existingLibrary()), uids: {'cafe'}).run(everything);

      expect(Directory(path.join(root.path, 'appdata', 'backups', 'dead')).existsSync(), isFalse);
      expect(outcome.freedBytes, 8000);
    });

    test('a group a mod in the library claims is kept', () async {
      write('appdata/backups/cafe/20260101-000000-000/files/body.ini', 8000);

      final outcome = await serviceOver(rootsIn(library: existingLibrary()), uids: {'cafe'}).run(everything);

      expect(exists('appdata/backups/cafe/20260101-000000-000/files/body.ini'), isTrue);
      expect(outcome.freedBytes, 0);
    });

    test('an unreadable library sweeps none of them', () async {
      write('appdata/backups/cafe/20260101-000000-000/files/body.ini', 8000);
      write('appdata/backups/dead/20260101-000000-000/files/body.ini', 8000);

      final outcome = await serviceOver(rootsIn(library: existingLibrary()), uids: null).run(everything);

      expect(exists('appdata/backups/cafe/20260101-000000-000/files/body.ini'), isTrue);
      expect(exists('appdata/backups/dead/20260101-000000-000/files/body.ini'), isTrue);
      expect(
        outcome.refused.map((r) => r.refusal),
        contains(ReclaimSkipReason.libraryUnreadable),
      );
    });

    // The scan answers an empty list, not an error, for a library folder it cannot find, so an empty claimed set is not evidence that no mod has a group.
    test('a library folder that is missing keeps every group, whatever the scan answered', () async {
      write('appdata/backups/cafe/20260101-000000-000/files/body.ini', 8000);
      write('appdata/backups/dead/20260101-000000-000/files/body.ini', 8000);
      final missing = path.join(root.path, 'unmounted', 'mods');

      final outcome = await serviceOver(rootsIn(library: missing), uids: <String>{}).run({ReclaimTarget.unclaimedSnapshots});

      expect(exists('appdata/backups/cafe/20260101-000000-000/files/body.ini'), isTrue);
      expect(exists('appdata/backups/dead/20260101-000000-000/files/body.ini'), isTrue);
      expect(outcome.freedBytes, 0);
      expect(outcome.refused.map((r) => r.refusal), [ReclaimSkipReason.libraryUnreadable]);
    });

    test('no library folder set keeps every group, whatever the scan answered', () async {
      write('appdata/backups/dead/20260101-000000-000/files/body.ini', 8000);

      final outcome = await serviceOver(rootsIn(), uids: <String>{}).run({ReclaimTarget.unclaimedSnapshots});

      expect(exists('appdata/backups/dead/20260101-000000-000/files/body.ini'), isTrue);
      expect(outcome.refused.map((r) => r.refusal), [ReclaimSkipReason.libraryUnreadable]);
    });

    test('a library that is there and holds nothing leaves every group unclaimed', () async {
      write('appdata/backups/dead/20260101-000000-000/files/body.ini', 8000);

      await serviceOver(rootsIn(library: existingLibrary()), uids: <String>{}).run({ReclaimTarget.unclaimedSnapshots});

      expect(exists('appdata/backups/dead/20260101-000000-000/files/body.ini'), isFalse);
    });

    test('the library is not asked at all while its folder is missing', () async {
      var asked = false;
      final service = ReclaimService(
        rootsIn(library: path.join(root.path, 'unmounted')),
        downloadsBusy: () => false,
        installBusy: () => false,
        modNames: () async {
          asked = true;
          return <String>{};
        },
        claimedSnapshotUids: () async {
          asked = true;
          return <String>{};
        },
      );

      await service.run({ReclaimTarget.legacyImages, ReclaimTarget.unclaimedSnapshots});

      expect(asked, isFalse);
    });
  });

  group('scope', () {
    /// One of everything the sweep can take, each of them old enough to go.
    void arrange() {
      write('appdata/downloads/mod.rar', 100);
      write('appdata/downloads/orphan.rar.part', 100);
      write('appdata/mod_images/Gone.png', 100);
      write('temp/zzz_archive_extract_old/body.ini', 100, age: const Duration(hours: 5));
      write('appdata/backups/dead/20260101-000000-000/files/body.ini', 100);
      for (var i = 0; i < 10; i++) {
        write('appdata/logs/${logFileName(DateTime(2026, 1, i + 1))}', 10);
      }
    }

    bool everyDownloadGone() =>
        !exists('appdata/downloads/mod.rar') && !exists('appdata/downloads/orphan.rar.part');

    test('Downloads takes the archives and the partials, and nothing else', () async {
      arrange();

      final outcome = await serviceOver(rootsIn()).run({ReclaimTarget.completedArchives, ReclaimTarget.abandonedPartials});

      expect(everyDownloadGone(), isTrue);
      expect(exists('appdata/mod_images/Gone.png'), isTrue);
      expect(exists('temp/zzz_archive_extract_old/body.ini'), isTrue);
      expect(exists('appdata/backups/dead/20260101-000000-000/files/body.ini'), isTrue);
      expect(Directory(path.join(root.path, 'appdata', 'logs')).listSync().length, 10);
      expect(outcome.targets.map((r) => r.target).toSet(), {
        ReclaimTarget.completedArchives,
        ReclaimTarget.abandonedPartials,
      });
    });

    test('Leftovers takes the legacy images and the old extractions, and nothing else', () async {
      arrange();

      await serviceOver(rootsIn(library: root.path), mods: {'Ellen'})
          .run({ReclaimTarget.legacyImages, ReclaimTarget.tempExtracts});

      expect(exists('appdata/mod_images/Gone.png'), isFalse);
      expect(exists('temp/zzz_archive_extract_old/body.ini'), isFalse);
      expect(everyDownloadGone(), isFalse);
      expect(exists('appdata/backups/dead/20260101-000000-000/files/body.ini'), isTrue);
      expect(Directory(path.join(root.path, 'appdata', 'logs')).listSync().length, 10);
    });

    test('Logs takes the old log files, and nothing else', () async {
      arrange();

      await serviceOver(rootsIn()).run({ReclaimTarget.oldLogs});

      expect(Directory(path.join(root.path, 'appdata', 'logs')).listSync().length, 0);
      expect(everyDownloadGone(), isFalse);
      expect(exists('appdata/mod_images/Gone.png'), isTrue);
      expect(exists('appdata/backups/dead/20260101-000000-000/files/body.ini'), isTrue);
    });

    test('Saved versions takes the unclaimed groups, and nothing else', () async {
      arrange();

      await serviceOver(rootsIn(library: existingLibrary())).run({ReclaimTarget.unclaimedSnapshots});

      expect(exists('appdata/backups/dead/20260101-000000-000/files/body.ini'), isFalse);
      expect(everyDownloadGone(), isFalse);
      expect(exists('appdata/mod_images/Gone.png'), isTrue);
      expect(Directory(path.join(root.path, 'appdata', 'logs')).listSync().length, 10);
    });

    test('a store out of scope is not read, so an unreadable library refuses nothing there', () async {
      arrange();

      final outcome = await serviceOver(rootsIn(), mods: null, uids: null)
          .run({ReclaimTarget.completedArchives, ReclaimTarget.abandonedPartials});

      expect(everyDownloadGone(), isTrue);
      expect(outcome.refused, isEmpty);
    });

    test('a closed gate still refuses a target that is asked for alone', () async {
      arrange();

      final outcome = await serviceOver(rootsIn(), downloadsBusy: true)
          .run({ReclaimTarget.completedArchives, ReclaimTarget.abandonedPartials});

      expect(everyDownloadGone(), isFalse);
      expect(outcome.refused.map((r) => r.refusal), everyElement(ReclaimSkipReason.downloadsActive));
    });

    test('a download waiting for an answer keeps the extractions, even old ones', () async {
      arrange();
      final service = ReclaimService(
        rootsIn(),
        downloadsBusy: () => false,
        installBusy: () => false,
        downloadWaiting: () => true,
        modNames: () async => <String>{},
        claimedSnapshotUids: () async => <String>{},
      );

      final outcome = await service.run({ReclaimTarget.tempExtracts});

      expect(exists('temp/zzz_archive_extract_old/body.ini'), isTrue);
      expect(outcome.refused.map((r) => r.refusal), [ReclaimSkipReason.downloadWaiting]);
    });

    test('an extraction under an hour old is left alone', () async {
      write('temp/zzz_archive_extract_new/body.ini', 100);

      await serviceOver(rootsIn()).run({ReclaimTarget.tempExtracts});

      expect(exists('temp/zzz_archive_extract_new/body.ini'), isTrue);
    });

    test('an unreadable library refuses the Leftovers images but not the extractions', () async {
      arrange();

      final outcome = await serviceOver(rootsIn(), mods: null)
          .run({ReclaimTarget.legacyImages, ReclaimTarget.tempExtracts});

      expect(exists('appdata/mod_images/Gone.png'), isTrue);
      expect(exists('temp/zzz_archive_extract_old/body.ini'), isFalse);
      expect(outcome.refused.map((r) => r.refusal), [ReclaimSkipReason.libraryUnreadable]);
    });

    test('this run\'s log survives a Logs clear', () async {
      final current = logFileName(DateTime(2026, 1, 1));
      arrange();

      await serviceOver(rootsIn(currentLog: path.join(root.path, 'appdata', 'logs', current)))
          .run({ReclaimTarget.oldLogs});

      expect(exists('appdata/logs/$current'), isTrue);
    });
  });

  group('what it must never touch', () {
    test('the library is not in its vocabulary', () async {
      final library = Directory(path.join(root.path, 'mods'))
        ..createSync(recursive: true);
      write('mods/Ellen/body.ini', 4000);
      write('appdata/backups/abc/20260101-000000-000/files/body.ini', 8000);
      write('appdata/downloads/mod.rar', 100);

      final outcome = await serviceOver(
        rootsIn(library: library.path),
        mods: {'Ellen'},
        uids: {'abc'},
      ).run(everything);

      expect(exists('mods/Ellen/body.ini'), isTrue);
      expect(
        exists('appdata/backups/abc/20260101-000000-000/files/body.ini'),
        isTrue,
      );
      expect(outcome.freedBytes, 100, reason: 'only the archive was reclaimed');
    });

    test('nothing to do reports nothing rather than failing', () async {
      final outcome = await serviceOver(rootsIn()).run(everything);

      expect(outcome.isEmpty, isTrue);
      expect(outcome.freedBytes, 0);
    });
  });
}
