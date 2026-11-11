import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/services/backup/snapshot_service.dart';
import 'package:mod_manager_flutter/services/folder_contents.dart';
import 'package:mod_manager_flutter/services/patch_placement.dart';
import 'package:mod_manager_flutter/services/patch_removal.dart';
import 'package:mod_manager_flutter/services/update_apply/update_applier.dart';
import 'package:path/path.dart' as p;

/// What a snapshot does when it cannot be taken or kept: refused for space before a byte is copied, and a copy or a delete that stops part-way leaves nothing History could list.
void main() {
  late Directory tmp;
  late Directory mods;
  late String backups;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('zzz_snapshot_safeguards_');
    mods = Directory(p.join(tmp.path, 'mods'))..createSync();
    backups = p.join(tmp.path, 'backups');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Directory modFolder(String name, Map<String, String> files) {
    final dir = Directory(p.join(mods.path, name))..createSync();
    for (final entry in files.entries) {
      File(p.join(dir.path, entry.key)).writeAsStringSync(entry.value);
    }
    return dir;
  }

  Future<SnapshotAttempt> take(SnapshotService service, Directory folder) => service.take(
        modName: 'Ellen',
        modUid: 'ellen-uid',
        modFolder: folder,
        reason: SnapshotReason.beforeUpdate,
      );

  SnapshotService unchecked() => SnapshotService(rootPath: backups, freeSpace: (_) async => null);

  UpdateApplier refusingApplier() => UpdateApplier(
        snapshots: SnapshotService(rootPath: backups, freeSpace: (_) async => 1),
        activation: _Activation(),
      );

  /// Sets [entity]'s mode for the test, to make a file unreadable.
  /// Root reads and deletes anything, so a test that needs this skips under root.
  Future<void> lock(FileSystemEntity entity, String mode) async {
    await Process.run('chmod', [mode, entity.path]);
    addTearDown(() => Process.run('chmod', ['-R', 'u+rwx', entity.path]));
  }

  group('the space check', () {
    test('refuses a snapshot that does not fit, names both figures, and makes no directory', () async {
      final folder = modFolder('Ellen', {'ellen.ini': '0123456789'});
      final asked = <String>[];
      final service = SnapshotService(
        rootPath: backups,
        freeSpace: (path) async {
          asked.add(path);
          return 9;
        },
      );

      final attempt = await take(service, folder);

      expect(attempt.snapshot, isNull);
      expect(attempt.noRoom?.requiredBytes, 10);
      expect(attempt.noRoom?.availableBytes, 9);
      expect(Directory(backups).existsSync(), isFalse, reason: 'a refusal writes nothing');
      expect(asked, [tmp.path], reason: 'free space is asked of the nearest folder that exists');
    });

    test('takes a snapshot that fits exactly', () async {
      final folder = modFolder('Ellen', {'ellen.ini': '0123456789'});
      final attempt = await take(SnapshotService(rootPath: backups, freeSpace: (_) async => 10), folder);
      expect(attempt.snapshot, isNotNull);
      expect(attempt.noRoom, isNull);
      expect(attempt.snapshot!.sizeBytes, 10);
      expect(attempt.snapshot!.fileCount, 1);
    });

    test('takes a snapshot when the free space cannot be read', () async {
      final folder = modFolder('Ellen', {'ellen.ini': '0123456789'});
      expect((await take(unchecked(), folder)).snapshot, isNotNull);
    });

    test('an update refused for its snapshot writes nothing, and carries the figures', () async {
      final folder = modFolder('Ellen', {'ellen.ini': 'v1 v1 v1 v1'});
      final incoming = Directory(p.join(tmp.path, 'extract', 'Ellen'))..createSync(recursive: true);
      File(p.join(incoming.path, 'ellen.ini')).writeAsStringSync('v2');
      final applier = refusingApplier();
      final preview = await applier.preview(modFolder: folder, incomingFolders: [incoming.path]);

      final result = await applier.apply(modName: 'Ellen', modFolder: folder, preview: preview);

      expect(result.failure, UpdateApplyFailure.snapshot);
      expect(result.snapshotNoRoom?.availableBytes, 1);
      expect(result.snapshotNoRoom!.requiredBytes, greaterThan(1));
      expect(File(p.join(folder.path, 'ellen.ini')).readAsStringSync(), 'v1 v1 v1 v1', reason: 'no snapshot, no wipe');
    });

    test('a patch refused for its snapshot places nothing, and carries the figures', () async {
      final folder = modFolder('Ellen', {'ellen.ini': 'base', 'Body.dds': 'base body'});
      final source = Directory(p.join(tmp.path, 'extract', 'Patch'))..createSync(recursive: true);
      File(p.join(source.path, 'Body.dds')).writeAsStringSync('patched body');
      final incoming = await readFolderContents(source);
      final existing = await readFolderContents(folder);

      final result = await refusingApplier().applyPatchInto(
        modName: 'Ellen',
        modFolder: folder,
        source: source,
        incoming: incoming,
        existing: existing,
        placement: resolvePatchPlacement(incoming: incoming.files, target: existing.files),
      );

      expect(result.failure, UpdateApplyFailure.snapshot);
      expect(result.snapshotNoRoom?.availableBytes, 1);
      expect(File(p.join(folder.path, 'Body.dds')).readAsStringSync(), 'base body');
    });

    test('taking a patch out refused for its snapshot moves nothing, and carries the figures', () async {
      final folder = modFolder('Ellen', {'ellen.ini': 'base', 'patch.ini': 'patch'});

      final result = await refusingApplier().removePatch(
        modName: 'Ellen',
        modFolder: folder,
        patchModId: 605460,
        plan: const PatchRemovalPlan(delete: ['patch.ini']),
      );

      expect(result.failure, UpdateApplyFailure.snapshot);
      expect(result.snapshotNoRoom?.availableBytes, 1);
      expect(File(p.join(folder.path, 'patch.ini')).existsSync(), isTrue);
    });

    test('a restore refused for its safety snapshot writes nothing, and carries the figures', () async {
      final folder = modFolder('Ellen', {'ellen.ini': 'v2'});
      final saved = (await unchecked().take(
        modName: 'Ellen',
        modUid: 'ellen-uid',
        modFolder: modFolder('Old', {'ellen.ini': 'v1', 'extra.dds': 'x'}),
        reason: SnapshotReason.beforeUpdate,
      ))
          .snapshot!;

      final result = await refusingApplier().restore(modName: 'Ellen', modFolder: folder, snapshot: saved);

      expect(result.failure, UpdateApplyFailure.snapshot);
      expect(result.snapshotNoRoom, isNotNull);
      expect(File(p.join(folder.path, 'ellen.ini')).readAsStringSync(), 'v2');
      expect(File(p.join(folder.path, 'extra.dds')).existsSync(), isFalse);
    });
  });

  group('a capture that fails part-way', () {
    test('deletes the directory it made, so History lists nothing', () async {
      final folder = modFolder('Ellen', {'a.ini': 'readable', 'b.dds': 'unreadable'});
      await lock(File(p.join(folder.path, 'b.dds')), '000');
      final service = unchecked();

      final attempt = await take(service, folder);

      expect(attempt.snapshot, isNull);
      expect(attempt.noRoom, isNull, reason: 'a failure that is not about space carries no figures');
      expect(await service.list('ellen-uid'), isEmpty);
      expect(await service.listAll(), isEmpty);
      expect(await service.uidsWithSnapshots(), isEmpty, reason: 'no empty group is left behind either');
    }, skip: _cannotLock);

    test('leaves the snapshots taken before it as they were', () async {
      final folder = modFolder('Ellen', {'a.ini': 'readable'});
      final service = unchecked();
      final good = (await take(service, folder)).snapshot!;
      final locked = File(p.join(folder.path, 'b.dds'))..writeAsStringSync('unreadable');
      await lock(locked, '000');

      expect((await take(service, folder)).snapshot, isNull);

      final listed = await service.list('ellen-uid');
      expect(listed.map((s) => s.id), [good.id], reason: 'the last good snapshot is still the newest');
    }, skip: _cannotLock);
  });

  group('reading the store', () {
    test('a directory with no manifest is not a snapshot', () async {
      final service = unchecked();
      final taken = (await take(service, modFolder('Ellen', {'ellen.ini': 'v1'}))).snapshot!;
      File(p.join(taken.directory.path, 'manifest.json')).deleteSync();

      expect(await service.list('ellen-uid'), isEmpty);
    });

    test('a snapshot survives a manifest that cannot be read', () async {
      final service = unchecked();
      final taken = (await take(service, modFolder('Ellen', {'Body.dds': 'v1'}))).snapshot!;
      File(p.join(taken.directory.path, 'manifest.json')).writeAsStringSync('{ not json');

      final listed = await service.list('ellen-uid');
      expect(listed.length, 1);
      expect(listed.single.sizeBytes, greaterThan(0));
      expect(listed.single.modUid, 'ellen-uid',
          reason: 'the group it is in answers for which mod it is, so a manifest that cannot be read costs a display name and not the snapshot');
      expect(listed.single.modName, isEmpty);
    });

    test('a delete that stops part-way leaves nothing listed', () async {
      // The tree's delete fails before it removes anything, the worst case of a delete that stops part-way.
      // Whatever order the filesystem lists the directory in, only a manifest removed first keeps the copy from being listed.
      final service = SnapshotService(
        rootPath: backups,
        freeSpace: (_) async => null,
        deleteTree: (dir) async => throw FileSystemException('held open', dir.path),
      );
      final taken = (await take(service, modFolder('Ellen', {'ellen.ini': 'v1'}))).snapshot!;

      expect(await service.delete(taken), isFalse);

      expect(Directory(p.join(taken.directory.path, 'files')).existsSync(), isTrue, reason: 'the copy is still there');
      expect(await service.list('ellen-uid'), isEmpty);
    });
  });
}

/// Why the tests that lock a file cannot run here, or false when they can.
final Object _cannotLock = Platform.isWindows
    ? 'chmod has no Windows equivalent here'
    : (Process.runSync('id', ['-u']).stdout.toString().trim() == '0' ? 'root reads and deletes a locked file' : false);

class _Activation implements ModActivationPort {
  @override
  Future<bool> activate(String modName) async => true;

  @override
  Future<bool> deactivate(String modName) async => true;

  @override
  Future<bool> isActive(String modName) async => false;
}
