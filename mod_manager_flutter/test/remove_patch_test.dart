import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/installed_file.dart';
import 'package:mod_manager_flutter/models/mod_download.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/services/backup/snapshot_service.dart';
import 'package:mod_manager_flutter/services/folder_contents.dart';
import 'package:mod_manager_flutter/services/patch_removal.dart';
import 'package:mod_manager_flutter/services/patch_store.dart';
import 'package:mod_manager_flutter/services/update_apply/update_applier.dart';
import 'package:path/path.dart' as p;

/// **Taking a patch back out of a folder**, end to end over a real directory.
///
/// `patch_removal_test.dart` covers which files get which treatment; this is the
/// write. The properties worth pinning are the ones a user would find out about
/// the hard way: the mod's own files come back, the patch's own go, and the
/// snapshot exists before any of it happens.
class _FakeActivation implements ModActivationPort {
  final Set<String> active = {};
  final List<String> log = [];

  @override
  Future<bool> isActive(String modName) async => active.contains(modName);

  @override
  Future<bool> activate(String modName) async {
    log.add('activate:$modName');
    return active.add(modName);
  }

  @override
  Future<bool> deactivate(String modName) async {
    log.add('deactivate:$modName');
    return active.remove(modName);
  }
}

/// Stands in for a full disk or a read-only app-data directory.
class _RefusingSnapshots extends SnapshotService {
  _RefusingSnapshots({required super.rootPath});

  @override
  Future<ModSnapshot?> capture({
    required String modName,
    required String modUid,
    required Directory modFolder,
    required SnapshotReason reason,
    String? version,
    String? versionLabel,
    DateTime? now,
  }) async =>
      null;
}

void main() {
  const patchId = 605460;
  const store = PatchStore();

  late Directory tmp;
  late Directory folder;
  late SnapshotService snapshots;
  late _FakeActivation activation;
  late UpdateApplier applier;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('zzz_remove_patch_');
    folder = Directory(p.join(tmp.path, 'mods', 'Ellen Swimsuit'))
      ..createSync(recursive: true);
    snapshots = SnapshotService(rootPath: p.join(tmp.path, 'backups'));
    activation = _FakeActivation();
    applier = UpdateApplier(snapshots: snapshots, activation: activation);
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  void write(String relative, String contents) {
    final file =
        File(p.join(folder.path, relative.replaceAll('/', p.separator)));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(contents);
  }

  String? read(String relative) {
    final file =
        File(p.join(folder.path, relative.replaceAll('/', p.separator)));
    return file.existsSync() ? file.readAsStringSync() : null;
  }

  /// A folder holding the mod plus a patch the app installed into it: the
  /// patch replaced `Textures/Body.dds` and added `patch.ini`.
  Future<ModOrigin> patched() async {
    write('ellen.ini', 'the mod');
    write('Textures/Body.dds', 'the mod\'s body');
    await store.keep(
      modFolder: folder,
      patchModId: patchId,
      relativePath: 'Textures/Body.dds',
    );
    write('Textures/Body.dds', 'the patch\'s body');
    write('patch.ini', 'the patch');

    return ModOrigin(
      source: 'gamebanana',
      provenance: OriginProvenance.downloaded,
      downloads: const [
        ModDownload(
          modId: 585282,
          modIdConfidence: OriginConfidence.exact,
        ),
        ModDownload(
          role: DownloadRole.patch,
          modId: patchId,
          modIdConfidence: OriginConfidence.exact,
          versionConfidence: OriginConfidence.exact,
          files: [
            InstalledFile(
              path: 'Textures/Body.dds',
              role: InstalledFileRole.replaced,
            ),
            InstalledFile(path: 'patch.ini', role: InstalledFileRole.added),
          ],
        ),
      ],
    );
  }

  Future<PatchRemovalResult> remove(ModOrigin origin) async {
    final onDisk = await readFolderContents(folder);
    final stored = <String>{
      for (final file in origin.patches.single.files)
        if (await store.holds(
          modFolder: folder,
          patchModId: patchId,
          relativePath: file.path,
        ))
          file.path,
    };
    return applier.removePatch(
      modName: 'Ellen Swimsuit',
      modFolder: folder,
      patchModId: patchId,
      plan: planPatchRemoval(
        origin: origin,
        patchModId: patchId,
        onDisk: onDisk,
        storedOriginals: stored,
      ),
    );
  }

  test('the mod comes back and the patch goes', () async {
    final origin = await patched();

    final result = await remove(origin);

    expect(result.success, isTrue);
    expect(read('Textures/Body.dds'), 'the mod\'s body');
    expect(read('patch.ini'), isNull);
    expect(read('ellen.ini'), 'the mod',
        reason: 'a file neither download claimed is untouched');
    expect(result.restored, ['Textures/Body.dds']);
    expect(result.deleted, ['patch.ini']);
    expect(result.failed, isEmpty);
  });

  test('the store is gone once nothing needs it', () async {
    await remove(await patched());

    expect(await PatchStore.idsIn(folder), isEmpty);
  });

  test('a snapshot is taken before anything changes', () async {
    final origin = await patched();

    final result = await remove(origin);

    expect(result.snapshot, isNotNull);
    // Its own reason, so a rollback list does not call this an update.
    expect(result.snapshot!.reason, SnapshotReason.beforePatchRemoval);
    final saved = File(p.join(
      result.snapshot!.directory.path,
      'files',
      'Textures',
      'Body.dds',
    ));
    expect(saved.readAsStringSync(), 'the patch\'s body',
        reason: 'the folder as it was, patch and all');
  });

  test('no snapshot means no write at all', () async {
    // The same trade every write in this file refuses to make: proceeding would
    // swap a recoverable failure for an unrecoverable one.
    applier = UpdateApplier(
      snapshots: _RefusingSnapshots(rootPath: p.join(tmp.path, 'backups')),
      activation: activation,
    );
    final origin = await patched();

    final result = await remove(origin);

    expect(result.success, isFalse);
    expect(result.failure, UpdateApplyFailure.snapshot);
    expect(read('patch.ini'), 'the patch', reason: 'nothing was removed');
    expect(read('Textures/Body.dds'), 'the patch\'s body');
    expect(await PatchStore.idsIn(folder), {patchId},
        reason: 'and the way back is still there');
  });

  test('an active mod is switched off for the write and back on after',
      () async {
    // For open file handles, the same as every other write here: the game's
    // loader holds them on Windows and the copy fails against them.
    activation.active.add('Ellen Swimsuit');
    final origin = await patched();

    final result = await remove(origin);

    expect(activation.log,
        ['deactivate:Ellen Swimsuit', 'activate:Ellen Swimsuit']);
    expect(result.reactivated, isTrue);
    expect(activation.active, contains('Ellen Swimsuit'));
  });

  test('a mod that was off stays off', () async {
    final result = await remove(await patched());

    expect(activation.log, isEmpty);
    expect(result.reactivated, isFalse);
  });

  test('a displaced file with no original is left alone, not deleted',
      () async {
    // Deleting it would take the mod's file with the patch and leave a hole.
    write('Textures/Body.dds', 'the patch\'s body');
    final origin = ModOrigin(
      source: 'gamebanana',
      provenance: OriginProvenance.downloaded,
      downloads: const [
        ModDownload(modId: 585282),
        ModDownload(
          role: DownloadRole.patch,
          modId: patchId,
          files: [
            InstalledFile(
              path: 'Textures/Body.dds',
              role: InstalledFileRole.replaced,
            ),
          ],
        ),
      ],
    );

    final result = await remove(origin);

    expect(result.success, isTrue);
    expect(read('Textures/Body.dds'), 'the patch\'s body');
    expect(result.restored, isEmpty);
    expect(result.deleted, isEmpty);
  });

  test('a gone mod folder changes nothing and says so', () async {
    final origin = await patched();
    await folder.delete(recursive: true);

    final result = await remove(origin);

    expect(result.success, isFalse);
    expect(result.failure, UpdateApplyFailure.modMissing);
    expect(result.snapshot, isNull);
  });

  test('two patches are removed one at a time', () async {
    // Per-companion registries and per-patch stores exist for exactly this:
    // taking one out must leave the other working.
    write('Textures/Body.dds', 'the mod\'s body');
    await store.keep(
      modFolder: folder,
      patchModId: patchId,
      relativePath: 'Textures/Body.dds',
    );
    write('Textures/Body.dds', 'patch A');
    write('b_patch.ini', 'patch B');

    final origin = ModOrigin(
      source: 'gamebanana',
      provenance: OriginProvenance.downloaded,
      downloads: const [
        ModDownload(modId: 585282),
        ModDownload(
          role: DownloadRole.patch,
          modId: patchId,
          files: [
            InstalledFile(
              path: 'Textures/Body.dds',
              role: InstalledFileRole.replaced,
            ),
          ],
        ),
        ModDownload(
          role: DownloadRole.patch,
          modId: 611203,
          files: [
            InstalledFile(path: 'b_patch.ini', role: InstalledFileRole.added),
          ],
        ),
      ],
    );

    final onDisk = await readFolderContents(folder);
    await applier.removePatch(
      modName: 'Ellen Swimsuit',
      modFolder: folder,
      patchModId: patchId,
      plan: planPatchRemoval(
        origin: origin,
        patchModId: patchId,
        onDisk: onDisk,
        storedOriginals: const {'Textures/Body.dds'},
      ),
    );

    expect(read('Textures/Body.dds'), 'the mod\'s body');
    expect(read('b_patch.ini'), 'patch B', reason: 'the other patch survives');
  });
}
