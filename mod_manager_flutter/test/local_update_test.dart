import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/installed_file.dart';
import 'package:mod_manager_flutter/models/mod_download.dart';
import 'package:mod_manager_flutter/models/mod_ingest.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/mod_origin_seed.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/services/update_apply/local_update.dart';
import 'package:mod_manager_flutter/services/update_apply/mod_activation_port.dart';
import 'package:mod_manager_flutter/services/backup/snapshot_service.dart';
import 'package:mod_manager_flutter/services/update_apply/update_applier.dart';
import 'package:mod_manager_flutter/services/update_apply/update_layout.dart';
import 'package:path/path.dart' as p;

import 'support/origin_shorthand.dart';
import 'support/temp_library.dart';

/// **Update it**: a dropped folder written into a mod the library has (`docs/importing-mods.md` §5).
///
/// The write is the update's, so what is pinned here is what is specific to it: the files that remain, the snapshot
/// that came first, and above all the record afterwards, which keeps the identity and clears the file.
void main() {
  late TempLibrary temp;
  late UpdateApplier applier;
  final installed = DateTime.utc(2026, 1, 5);
  final now = DateTime.utc(2026, 11, 8);

  setUp(() async {
    temp = await TempLibrary.create();
    applier = UpdateApplier(snapshots: temp.snapshots, activation: ModManagerActivationPort(temp.service));
  });

  Directory dropped(String name, Map<String, String> files) {
    final folder = Directory(p.join(temp.root.path, 'drop', name))..createSync(recursive: true);
    for (final entry in files.entries) {
      final file = File(p.join(folder.path, entry.key.replaceAll('/', p.separator)));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(entry.value);
    }
    return folder;
  }

  ModInfo modInfo(String name, ModOrigin? origin) =>
      ModInfo(id: name, name: name, characterId: 'ellen', isActive: false, origin: origin);

  /// A mod installed from a GameBanana file, with everything the record can say about it.
  ModOrigin tracked({List<ModDownload> patches = const []}) => ModOrigin(
    source: 'gamebanana',
    provenance: OriginProvenance.downloaded,
    installedAt: installed,
    ingest: ModIngest(
      mode: IngestMode.separate,
      folders: const ['Ellen v1'],
      siblingGroup: 'abc123',
      patchFiles: [for (final patch in patches) ...patch.files.map((f) => f.path)],
    ),
    downloads: [
      ModDownload(
        modId: 700,
        modIdConfidence: OriginConfidence.exact,
        name: 'Winter Maid',
        fileId: 11,
        version: '1.0',
        versionLabel: 'Main file',
        versionConfidence: OriginConfidence.exact,
        archiveMd5: 'oldmd5',
        baselineRemoteDate: DateTime.utc(2025, 12),
        updatesDismissedUntil: DateTime.utc(2026, 2),
        files: const [InstalledFile(path: 'ellen.ini'), InstalledFile(path: 'old_only.dds')],
      ),
      ...patches,
    ],
  );

  Future<ModInfo> installedMod(ModOrigin? origin) async {
    temp.write('Ellen Maid', 'ellen.ini', 'old ini');
    temp.write('Ellen Maid', 'old_only.dds', 'old texture');
    if (origin != null) await temp.writeOrigin('Ellen Maid', origin);
    return modInfo('Ellen Maid', origin);
  }

  Future<LocalUpdateResult> update(ModInfo mod, Directory source, {ModOriginSeed? seed}) => applyLocalUpdate(
    applier: applier,
    amend: temp.service.updateModOrigin,
    mod: mod,
    modsPath: temp.mods.path,
    folders: {source.path: ''},
    seed: seed ?? ModOriginSeed.importedFolder,
    now: now,
  );

  test('takes a snapshot first, then leaves the dropped folder and nothing of the old one, sidecar kept', () async {
    final mod = await installedMod(tracked());
    final source = dropped('Ellen Maid', {'ellen.ini': 'new ini', 'Textures/Body.dds': 'new body'});

    final result = await update(mod, source);

    expect(result.success, isTrue);
    expect(temp.snapshotsOf('Ellen Maid'), hasLength(1), reason: 'the snapshot is what a failed or unwanted update is undone from');
    expect(temp.read('Ellen Maid', 'ellen.ini'), 'new ini');
    expect(temp.read('Ellen Maid', 'Textures/Body.dds'), 'new body');
    expect(temp.has('Ellen Maid', 'old_only.dds'), isFalse, reason: 'nothing of the old version is kept, and nothing is inferred');
    expect(temp.originOf('Ellen Maid'), isNotNull, reason: 'the sidecar is the one thing the wipe leaves');
    expect(source.existsSync(), isTrue, reason: 'the dropped folder itself is not moved');
  });

  test('keeps which mod it is and what the user decided, and clears which file', () async {
    final mod = await installedMod(tracked());
    final source = dropped('Ellen Maid', {'ellen.ini': 'new ini'});

    await update(mod, source);

    final origin = temp.originOf('Ellen Maid')!;
    final base = origin.base!;
    expect(base.modId, 700);
    expect(base.modIdConfidence, OriginConfidence.exact);
    expect(base.name, 'Winter Maid');
    expect(origin.source, 'gamebanana');
    expect(origin.tracking, OriginTracking.auto);
    expect(base.updatesDismissedUntil, DateTime.utc(2026, 2));

    expect(base.fileId, isNull, reason: 'the bytes are no longer that file\'s');
    expect(base.version, isNull);
    expect(base.versionLabel, isNull);
    expect(base.versionConfidence, OriginConfidence.unknown);
    expect(base.baselineRemoteDate, isNull);
    expect(base.archiveMd5, isNull, reason: 'a dropped folder has no archive');
    expect(base.files.map((f) => f.path), ['ellen.ini']);

    expect(origin.provenance, OriginProvenance.importedFolder);
    expect(origin.installedAt, now);
    expect(origin.installedAtIsProxy, isFalse);
  });

  test('a dropped archive banks its md5, so a published file can be matched by it later', () async {
    final mod = await installedMod(tracked());
    final source = dropped('Ellen Maid', {'ellen.ini': 'new ini'});

    await update(mod, source, seed: ModOriginSeed.importedArchive(archiveMd5: 'newmd5'));

    final origin = temp.originOf('Ellen Maid')!;
    expect(origin.archiveMd5, 'newmd5');
    expect(origin.provenance, OriginProvenance.importedArchive);
    expect(origin.fileId, isNull, reason: 'a hash is a matching key, never a claim about the file');
  });

  test('the layout is rewritten from the drop, and the folder leaves its sibling group', () async {
    final mod = await installedMod(tracked());
    final source = dropped('new_outfit', {'ellen.ini': 'new ini'});

    await update(mod, source);

    final ingest = temp.originOf('Ellen Maid')!.ingest!;
    expect(ingest.mode, IngestMode.separate);
    expect(ingest.folders, ['new_outfit']);
    expect(ingest.siblingGroup, isNull, reason: 'a group update would write that archive\'s folder over what was dropped');
  });

  test('a mod the app knows nothing about comes out as one imported now', () async {
    final mod = await installedMod(null);
    final source = dropped('Ellen Maid', {'ellen.ini': 'new ini'});

    final result = await update(mod, source);

    expect(result.success, isTrue);
    final origin = temp.originOf('Ellen Maid')!;
    expect(origin.base!.modId, isNull);
    expect(origin.provenance, OriginProvenance.importedFolder);
    expect(origin.installedAt, now);
  });

  test('a mod marked Local stays Local', () async {
    final mod = await installedMod(tracked().copyWith(tracking: OriginTracking.off));
    final source = dropped('Ellen Maid', {'ellen.ini': 'new ini'});

    await update(mod, source);

    expect(temp.originOf('Ellen Maid')!.tracking, OriginTracking.off);
  });

  test('a recorded patch goes back on the new layout, and its layer stays', () async {
    final patch = ModDownload(
      role: DownloadRole.patch,
      modId: 701,
      modIdConfidence: OriginConfidence.exact,
      fileId: 21,
      versionConfidence: OriginConfidence.exact,
      files: const [InstalledFile(path: 'Fix.dds', role: InstalledFileRole.added)],
    );
    final origin = tracked(patches: [patch]);
    final mod = await installedMod(origin);
    temp.write('Ellen Maid', 'Fix.dds', 'patch bytes');
    final source = dropped('Ellen Maid', {'ellen.ini': 'new ini'});

    final result = await update(mod, source);

    expect(result.success, isTrue);
    expect(temp.read('Ellen Maid', 'Fix.dds'), 'patch bytes', reason: 'a recorded patch is the one thing that comes back');
    final after = temp.originOf('Ellen Maid')!;
    expect(after.patches.single.modId, 701);
    expect(after.patches.single.fileId, 21, reason: 'the patch is still that file');
    expect(after.base!.fileId, isNull);
  });

  test('a patch whose files are not recorded goes with the old version', () async {
    final unrecorded = ModDownload(role: DownloadRole.patch, modId: 701, modIdConfidence: OriginConfidence.exact, fileId: 21);
    final mod = await installedMod(tracked(patches: [unrecorded]));
    temp.write('Ellen Maid', 'Fix.dds', 'patch bytes');
    final source = dropped('Ellen Maid', {'ellen.ini': 'new ini'});

    await update(mod, source);

    expect(temp.has('Ellen Maid', 'Fix.dds'), isFalse);
    expect(temp.snapshotsOf('Ellen Maid'), hasLength(1), reason: 'the saved copy still has it');
  });

  test('no snapshot means no write, and nothing is recorded', () async {
    final mod = await installedMod(tracked());
    final source = dropped('Ellen Maid', {'ellen.ini': 'new ini'});
    final refusing = UpdateApplier(snapshots: _NoSnapshots(rootPath: temp.snapshots.rootPath), activation: ModManagerActivationPort(temp.service));

    final result = await applyLocalUpdate(
      applier: refusing,
      amend: temp.service.updateModOrigin,
      mod: mod,
      modsPath: temp.mods.path,
      folders: {source.path: ''},
      seed: ModOriginSeed.importedFolder,
    );

    expect(result.success, isFalse);
    expect(result.record, isNull);
    expect(temp.read('Ellen Maid', 'ellen.ini'), 'old ini');
    expect(temp.originOf('Ellen Maid')!.base!.fileId, 11);
  });

  test('several folders combined into the mod each go into a subfolder named after them', () async {
    final mod = await installedMod(tracked());
    final body = dropped('Body', {'body.ini': 'b'});
    final hair = dropped('Hair', {'hair.ini': 'h'});

    final result = await applyLocalUpdate(
      applier: applier,
      amend: temp.service.updateModOrigin,
      mod: mod,
      modsPath: temp.mods.path,
      folders: {body.path: 'Body', hair.path: 'Hair'},
      seed: ModOriginSeed.importedFolder,
      now: now,
    );

    expect(result.success, isTrue);
    expect(temp.read('Ellen Maid', 'Body/body.ini'), 'b');
    expect(temp.read('Ellen Maid', 'Hair/hair.ini'), 'h');
    final ingest = temp.originOf('Ellen Maid')!.ingest!;
    expect(ingest.mode, IngestMode.combined);
    expect(ingest.folders, ['Body', 'Hair']);
  });

  test('two dropped folders with the same name, from different places, both keep their files', () async {
    final mod = await installedMod(tracked());
    final first = dropped('Body', {'a.ini': 'from the first'});
    final second = Directory(p.join(temp.root.path, 'elsewhere', 'Body'))..createSync(recursive: true);
    File(p.join(second.path, 'b.ini')).writeAsStringSync('from the second');

    final result = await applyLocalUpdate(
      applier: applier,
      amend: temp.service.updateModOrigin,
      mod: mod,
      modsPath: temp.mods.path,
      folders: {first.path: 'Body', second.path: 'Body'},
      seed: ModOriginSeed.importedFolder,
      now: now,
    );

    expect(result.success, isTrue);
    expect(temp.read('Ellen Maid', 'Body/a.ini'), 'from the first');
    expect(temp.read('Ellen Maid', 'Body (2)/b.ini'), 'from the second');
    expect(temp.originOf('Ellen Maid')!.ingest!.folders, ['Body', 'Body (2)']);
  });

  group('originAfterLocalUpdate', () {
    test('never invents an identity for a layer that had none', () {
      final after = originAfterLocalUpdate(
        null,
        seed: ModOriginSeed.importedFolder,
        layout: _rootLayout,
        files: const [],
        now: now,
      );

      expect(after.base!.hasIdentity, isFalse);
      expect(after.base!.versionConfidence, OriginConfidence.unknown);
    });
  });
}

const _rootLayout = UpdateLayout(mappings: [UpdateFolderMapping(source: 'drop', targetSubPath: '')]);

/// Stands in for a full disk or a read-only app-data directory.
class _NoSnapshots extends SnapshotService {
  _NoSnapshots({required super.rootPath});

  @override
  Future<ModSnapshot?> capture({
    required String modName,
    required String modUid,
    required Directory modFolder,
    required SnapshotReason reason,
    String? version,
    String? versionLabel,
    DateTime? now,
  }) async => null;
}

