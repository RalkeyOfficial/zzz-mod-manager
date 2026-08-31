import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/l10n/app_localizations.dart';
import 'package:mod_manager_flutter/models/mod_companion.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/services/archive_service.dart';
import 'package:mod_manager_flutter/services/mod_metadata_repository.dart';
import 'package:mod_manager_flutter/services/mod_metadata_service.dart';
import 'package:mod_manager_flutter/screens/dialogs/patch_install_flow.dart';
import 'package:mod_manager_flutter/services/backup/snapshot_service.dart';
import 'package:mod_manager_flutter/services/origin_status.dart';
import 'package:mod_manager_flutter/services/patch_scan.dart';
import 'package:mod_manager_flutter/services/update_apply/update_applier.dart';
import 'package:mod_manager_flutter/utils/directory_copy.dart';
import 'package:path/path.dart' as p;

/// The **whole install path** for an asset-only patch, over a real archive.
///
/// Every other test here works on sets of strings. This one starts with an
/// actual `.rar` on disk and finishes by reading a sidecar back out of a mod
/// folder, because the parts most likely to be quietly wrong are the joins: the
/// extractor wrapping a rootless archive, the copy, and whether the flag
/// survives to disk in a form the status slot reads.
///
/// Skipped unless `ZZZ_PATCH_E2E` points at a directory holding:
///
/// ```
///   <dir>/patch.rar     an asset patch — assets only, no .ini
///   <dir>/base/         the extracted mod it patches, as a mod folder
/// ```
///
/// ```
/// ZZZ_PATCH_E2E=/path/to/pair flutter test \
///   test/asset_patch_install_e2e_test.dart
/// ```
///
/// The archives are hundreds of megabytes between them and are nobody's
/// business to check in, which is why this cannot be a normal test. It exists
/// so "the install path handles this" can be re-derived rather than trusted.
/// Nothing here is activated, so nothing has to be linked or unlinked.
class _NoActivation implements ModActivationPort {
  @override
  Future<bool> isActive(String modName) async => false;

  @override
  Future<bool> activate(String modName) async => true;

  @override
  Future<bool> deactivate(String modName) async => true;
}

class _FakeTagStore implements ModCharacterTagStore {
  final Map<String, String> tags = {};

  @override
  Map<String, String> get modCharacterTags => Map.of(tags);

  @override
  Future<bool> setModCharacterTag(String modId, String characterId) async {
    tags[modId] = characterId;
    return true;
  }

  @override
  Future<bool> removeModCharacterTag(String modId) async {
    tags.remove(modId);
    return true;
  }
}

void main() {
  final pair = Platform.environment['ZZZ_PATCH_E2E'];

  test('a real asset patch is detected, recorded and rendered', () async {
    final source = Directory(pair!);
    final archive = File(p.join(source.path, 'patch.rar'));
    final base = Directory(p.join(source.path, 'base'));
    expect(await archive.exists(), isTrue, reason: '${archive.path} missing');
    expect(await base.exists(), isTrue, reason: '${base.path} missing');

    final tmp = await Directory.systemTemp.createTemp('zzz_patch_e2e_');
    addTearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });
    final modsPath = p.join(tmp.path, 'mods');
    await Directory(modsPath).create(recursive: true);

    // ---- the library already holds the mod being patched -------------------
    final baseName = p.basename(base.path) == 'base'
        ? 'The Base Mod'
        : p.basename(base.path);
    await copyDirectory(base, Directory(p.join(modsPath, baseName)));

    // ---- 1. real extraction ------------------------------------------------
    final extraction =
        await ArchiveService.extractArchive(archiveFile: archive);
    expect(extraction.success, isTrue,
        reason: 'needs 7-Zip on PATH for a .rar');
    final folders = extraction.extractedFolders ?? const <String>[];

    // A rootless archive is *wrapped* in a folder named after the archive.
    // Inferred from reading the extractor until now; this is where it is
    // actually watched, because branch B's rule depends on telling a wrapper
    // from a folder the archive really had.
    expect(folders.length, 1,
        reason: 'a loose pile of files becomes exactly one folder');
    expect(p.basename(folders.single), p.basenameWithoutExtension(archive.path),
        reason: 'the wrapper takes the archive name, not the file name');

    // ---- 2. real import ----------------------------------------------------
    final modName = p.basename(folders.single);
    await copyDirectory(
      Directory(folders.single),
      Directory(p.join(modsPath, modName)),
    );

    // ---- 3. both rules, and the write, exactly as the import calls them ----
    final repository = ModMetadataRepository(
      _FakeTagStore(),
      modsPath: () => modsPath,
      legacyImagesPath: () => p.join(tmp.path, 'legacy'),
    );
    await repository.recordOrigin(
      modName,
      const ModOrigin(
        provenance: OriginProvenance.downloaded,
        source: 'gamebanana',
        modId: 900460,
        modIdConfidence: OriginConfidence.exact,
        fileId: 1900174,
        versionConfidence: OriginConfidence.exact,
      ),
    );

    final scan = await scanPlannedMods([
      PlannedMod(name: modName, sources: {p.join(modsPath, modName): ''}),
    ]);
    final loc = AppLocalizations(const Locale('en'));
    await loc.load();
    await applyPatchInstall(
      loc,
      decision: PatchInstallDecision(scan: scan),
      importedMods: [modName],
      modsPath: modsPath,
      applier: UpdateApplier(
        snapshots: SnapshotService(rootPath: p.join(tmp.path, 'backups')),
        activation: _NoActivation(),
      ),
      amend: repository.updateOrigin,
    );

    expect(scan.iniPatches, isEmpty,
        reason: 'the .ini rule cannot see it, and must not pretend to');
    expect(scan.incomplete, isEmpty,
        reason: 'this is the branch the asset rule exists to rescue');
    expect(scan.assetPatches.keys, [modName]);
    expect(scan.assetPatches[modName]!.assets, greaterThan(0),
        reason: 'the real archive is one .dds, which is exactly a file that '
            'does nothing without an .ini to load it');

    // ---- 4. the flag reaches disk ------------------------------------------
    // Read back off the filesystem, not from the object we just wrote — the
    // question is whether it survives the round trip a scan makes.
    final sidecar =
        await ModMetadataService().read(p.join(modsPath, modName));
    expect(sidecar, isNotNull);
    expect(sidecar!.origin!.ingest!.patchShaped, isTrue);

    // ---- 5. and the card asks the user to finish it ------------------------
    final origin = sidecar.origin!;
    expect(origin.needsCompanion, isTrue);
    expect(modOriginStatus(origin), ModOriginStatus.secondIdentityUnknown,
        reason: 'the amber mark, and its own sentence');
    expect(modNeedsAttention(origin), isTrue,
        reason: 'and it is counted, because naming the base clears it');

    // ---- 6. naming the base retires the state ------------------------------
    // The last link in the chain: the state is not a dead end.
    expect(
      modOriginStatus(origin.copyWith(companions: [
        const ModCompanion(
          role: CompanionRole.base,
          modId: 900282,
          modIdConfidence: OriginConfidence.user,
        ),
      ])),
      ModOriginStatus.none,
    );
  }, skip: pair == null);
}
