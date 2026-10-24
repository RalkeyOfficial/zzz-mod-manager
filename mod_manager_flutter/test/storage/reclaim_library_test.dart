import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/core/constants.dart';
import 'package:mod_manager_flutter/services/storage/reclaim_plan.dart';
import 'package:mod_manager_flutter/services/storage/storage_providers.dart';
import 'package:mod_manager_flutter/services/storage/storage_roots.dart';
import 'package:mod_manager_flutter/utils/path_helper.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';
import 'package:path/path.dart' as path;

import '../support/temp_library.dart';

/// The Storage reclaim over a real library, as the app wires it: the scan answers an empty list, not an error, for a library it cannot find or list, and an empty list must never read as "no mod has a saved version".
void main() {
  final runsAsRoot = Platform.isLinux && Process.runSync('id', ['-u']).stdout.toString().trim() == '0';
  const ellenUid = 'a1b2c3d4e5f60718293a4b5c6d7e8f90';
  const deadUid = '00000000000000000000000000000dead';
  const awayUid = '000000000000000000000000000000aaa';

  late TempLibrary library;

  setUp(() async {
    library = await TempLibrary.create(prefix: 'reclaim_library_test_');
    // A library scan sweeps `<appData>/mod_images`, so the scans here must not reach the developer's own.
    PathHelper.useAppDataForTests(path.join(library.root.path, 'appdata'));
    addTearDown(PathHelper.resetForTests);
  });

  /// A mod folder carrying [uid] in its sidecar, as one an update has snapshotted does.
  void modWithUid(String name, String uid) {
    final folder = library.createMod(name);
    File(path.join(folder.path, AppConstants.modMetadataDirName, AppConstants.modMetadataFileName))
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode({'uid': uid}));
  }

  /// A saved-versions group under [uid].
  File backup(String uid) => File(path.join(library.snapshots.rootPath, uid, '20260101-000000-000', 'files', 'body.ini'))
    ..createSync(recursive: true)
    ..writeAsBytesSync(List<int>.filled(100, 0));

  StorageRoots roots() => StorageRoots(
        appData: Directory(path.join(library.root.path, 'appdata'))..createSync(recursive: true),
        downloads: Directory(path.join(library.root.path, 'appdata', 'downloads')),
        logs: Directory(path.join(library.root.path, 'appdata', 'logs')),
        legacyImages: Directory(path.join(library.root.path, 'appdata', 'mod_images')),
        backups: Directory(library.snapshots.rootPath),
        temp: Directory(path.join(library.root.path, 'temp'))..createSync(recursive: true),
        modsLibrary: library.mods,
      );

  ProviderContainer containerWith({String zzmi = 'zzmi'}) {
    final container = ProviderContainer(overrides: [
      ...library.overrides,
      storageRootsProvider.overrideWithValue(roots()),
      zzmiPathProvider.overrideWith((_) => zzmi),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  Future<ReclaimSkipReason?> clearVersions(ProviderContainer container) async {
    final outcome = (await container.read(reclaimControllerProvider.notifier).run({ReclaimTarget.unclaimedSnapshots}))!;
    return outcome.refused.map((result) => result.refusal).firstOrNull;
  }

  group('a library whose answer cannot be believed keeps every saved version', () {
    test('the folder went missing', () async {
      modWithUid('Ellen', ellenUid);
      final kept = [backup(ellenUid), backup(deadUid)];
      final container = containerWith();
      await container.read(libraryProvider.future);
      library.mods.deleteSync(recursive: true);
      await container.read(libraryProvider.notifier).rescan();
      expect(container.read(libraryProvider).requireValue, isEmpty, reason: 'the scan answers an empty list, not an error');

      final refusal = await clearVersions(container);

      expect(kept.map((file) => file.existsSync()), everyElement(isTrue));
      expect(refusal, ReclaimSkipReason.libraryUnreadable);
    });

    test('the folder is there but cannot be listed', () async {
      modWithUid('Ellen', ellenUid);
      final kept = [backup(ellenUid), backup(deadUid)];
      final container = containerWith();
      await container.read(libraryProvider.future);
      Process.runSync('chmod', ['000', library.mods.path]);
      addTearDown(() => Process.runSync('chmod', ['755', library.mods.path]));
      await container.read(libraryProvider.notifier).rescan();
      expect(container.read(libraryProvider).requireValue, isEmpty, reason: 'the scan swallows the listing error');
      expect(library.mods.existsSync(), isTrue, reason: 'so "exists" alone cannot tell it from a readable library');

      final refusal = await clearVersions(container);

      expect(kept.map((file) => file.existsSync()), everyElement(isTrue));
      expect(refusal, ReclaimSkipReason.libraryUnreadable);
    }, testOn: 'linux', skip: runsAsRoot ? 'root lists any folder' : false);

    test('the folder is a link to nowhere', () async {
      final kept = [backup(ellenUid), backup(deadUid)];
      final container = containerWith();
      library.mods.deleteSync(recursive: true);
      Link(library.mods.path).createSync(path.join(library.root.path, 'nowhere'));

      final refusal = await clearVersions(container);

      expect(kept.map((file) => file.existsSync()), everyElement(isTrue));
      expect(refusal, ReclaimSkipReason.libraryUnreadable);
    }, skip: Platform.isWindows);

    test('no ZZMI folder is set, though the library folder is there', () async {
      final kept = [backup(deadUid)];
      final container = containerWith(zzmi: '');
      await container.read(libraryProvider.future);

      final refusal = await clearVersions(container);

      expect(kept.map((file) => file.existsSync()), everyElement(isTrue));
      expect(refusal, ReclaimSkipReason.libraryUnreadable);
    });

    test('a mod is linked to a folder that is gone', () async {
      modWithUid('Ellen', ellenUid);
      final kept = [backup(ellenUid), backup(deadUid), backup(awayUid)];
      Link(path.join(library.mods.path, 'Away')).createSync(path.join(library.root.path, 'unmounted', 'Away'));
      final container = containerWith();

      final refusal = await clearVersions(container);

      expect(kept.map((file) => file.existsSync()), everyElement(isTrue), reason: 'the link may come back to life');
      expect(refusal, ReclaimSkipReason.libraryHasDeadLink);
    }, skip: Platform.isWindows);
  });

  group('a readable library', () {
    test('lets the group of a mod it does not hold go, and keeps the one it holds', () async {
      modWithUid('Ellen', ellenUid);
      final claimed = backup(ellenUid);
      final orphan = backup(deadUid);
      final container = containerWith();
      await container.read(libraryProvider.future);

      final refusal = await clearVersions(container);

      expect(orphan.existsSync(), isFalse);
      expect(claimed.existsSync(), isTrue);
      expect(refusal, isNull);
    });

    test('is walked afresh, so a cached empty list from when its drive was away claims nothing wrongly', () async {
      modWithUid('Ellen', ellenUid);
      final claimed = backup(ellenUid);
      final orphan = backup(deadUid);
      final container = containerWith();
      await container.read(libraryProvider.future);
      library.mods.deleteSync(recursive: true);
      await container.read(libraryProvider.notifier).rescan();
      expect(container.read(libraryProvider).requireValue, isEmpty);
      // The drive is back by the time the button is pressed, and nothing has rescanned since.
      library.mods.createSync();
      modWithUid('Ellen', ellenUid);

      final refusal = await clearVersions(container);

      expect(claimed.existsSync(), isTrue, reason: 'the cached empty list would have called it unclaimed');
      expect(orphan.existsSync(), isFalse);
      expect(refusal, isNull);
    });
  });
}
