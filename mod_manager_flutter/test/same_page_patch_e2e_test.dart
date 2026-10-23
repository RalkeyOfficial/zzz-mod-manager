import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/l10n/app_localizations.dart';
import 'package:mod_manager_flutter/models/gamebanana/gamebanana.dart';
import 'package:mod_manager_flutter/models/installed_file.dart';
import 'package:mod_manager_flutter/models/mod_download.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/screens/dialogs/patch_install_flow.dart';
import 'package:mod_manager_flutter/screens/dialogs/patch_install_prompt.dart';
import 'package:mod_manager_flutter/services/backup/snapshot_service.dart';
import 'package:mod_manager_flutter/services/folder_contents.dart';
import 'package:mod_manager_flutter/services/origin_write.dart';
import 'package:mod_manager_flutter/services/patch_placement.dart';
import 'package:mod_manager_flutter/services/patch_record.dart';
import 'package:mod_manager_flutter/services/patch_removal.dart';
import 'package:mod_manager_flutter/services/patch_scan.dart';
import 'package:mod_manager_flutter/services/patch_store.dart';
import 'package:mod_manager_flutter/services/update_apply/update_applier.dart';
import 'package:mod_manager_flutter/services/update_apply/update_write_route.dart';
import 'package:mod_manager_flutter/services/update_check.dart';
import 'package:path/path.dart' as p;

class _NoActivation implements ModActivationPort {
  @override
  Future<bool> isActive(String modName) async => false;

  @override
  Future<bool> activate(String modName) async => true;

  @override
  Future<bool> deactivate(String modName) async => true;
}

/// **A patch whose file comes from its base's own page**, through every write a folder meets, over a real directory.
///
/// Page P publishes main file A and a lone `.ini` fix B. A is installed, B is put into it, B is ignored and then
/// updated, A is updated with B put back on top, and B is taken out. The sidecar is held as JSON and read back after
/// every write, so the stack's read rule is in the loop as it is on disk. Each write is the one the app makes; the
/// two update writes are the flows' own steps without their windows (`docs/origin-tracking.md` §10).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const page = 700;
  const fileA = 1;
  const fileB = 2;
  const fileB2 = 3;
  const fileA2 = 4;
  const base = DownloadKey.base(page);
  const patch = DownloadKey.patch(page);

  final a = GbFile(idRow: fileA, file: 'main.zip', description: 'Main file', dateAdded: DateTime.utc(2026, 1));
  final b = GbFile(idRow: fileB, file: 'fix.zip', description: 'Hair fix', dateAdded: DateTime.utc(2026, 2));
  final b2 = GbFile(idRow: fileB2, file: 'fix2.zip', description: 'Hair fix', dateAdded: DateTime.utc(2026, 3));

  late AppLocalizations loc;
  late Directory tmp;
  late String modsPath;
  late Directory folder;
  late UpdateApplier applier;
  // The sidecar, as the JSON a read starts from.
  Map<String, dynamic>? sidecar;

  setUpAll(() async {
    loc = AppLocalizations(const Locale('en'));
    await loc.load();
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('zzz_same_page_');
    modsPath = p.join(tmp.path, 'mods');
    folder = Directory(p.join(modsPath, 'Ellen'))..createSync(recursive: true);
    applier = UpdateApplier(
      snapshots: SnapshotService(rootPath: p.join(tmp.path, 'backups')),
      activation: _NoActivation(),
    );
    sidecar = null;
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  void write(String root, String relative, String contents) {
    final file = File(p.join(root, relative.replaceAll('/', p.separator)));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(contents);
  }

  String? read(String relative) {
    final file = File(p.join(folder.path, relative.replaceAll('/', p.separator)));
    return file.existsSync() ? file.readAsStringSync() : null;
  }

  Directory unpacked(String name, Map<String, String> files) {
    final root = p.join(tmp.path, 'extract', name);
    for (final entry in files.entries) {
      write(root, entry.key, entry.value);
    }
    return Directory(root);
  }

  ModOrigin? origin() => ModOrigin.fromJson(sidecar);

  Future<OriginWriteResult> amend(String modName, ModOrigin? Function(ModOrigin? current) update) async {
    sidecar = update(origin())?.toJson();
    return OriginWriteResult.written;
  }

  test('a patch from its base\'s own page lives through every write as a patch from another page', () async {
    // ---- install A ----------------------------------------------------------------------------------------------
    write(folder.path, 'ellen.ini', 'A ini');
    write(folder.path, 'Textures/Body.dds', 'A body');
    sidecar = ModOrigin(
      source: 'gamebanana',
      provenance: OriginProvenance.downloaded,
      downloads: const [
        ModDownload(
          modId: page,
          modIdConfidence: OriginConfidence.exact,
          fileId: fileA,
          versionLabel: 'Main file',
          versionConfidence: OriginConfidence.exact,
          files: [InstalledFile(path: 'ellen.ini'), InstalledFile(path: 'Textures/Body.dds')],
        ),
      ],
    ).toJson();

    // ---- put B in, through the install's own write --------------------------------------------------------------
    final fix = unpacked('Ellen Fix', {'ellen.ini': 'B fix'});
    final decision = await resolvePatchDestinations(
      scan: const PlannedPatchScan(iniPatches: {'Ellen Fix'}),
      destinations: {'Ellen Fix': const InstallIntoMod(modId: 'Ellen', modName: 'Ellen')},
      folders: [fix.path],
      modsPath: modsPath,
    );
    await applyPatchInstall(
      loc,
      decision: decision,
      importedMods: const [],
      modsPath: modsPath,
      applier: applier,
      amend: amend,
      patch: const PatchIdentity(modId: page, fileId: fileB, versionLabel: 'Hair fix'),
    );

    expect(origin()!.downloads.map((d) => (d.modId, d.fileId)), [(page, fileA), (page, fileB)],
        reason: 'the base is kept and the fix sits on top of it');
    expect(read('ellen.ini'), 'B fix');
    expect(removablePatches(origin()).single.fileId, fileB, reason: 'History lists it with Take out');

    // ---- a check reads both layers -------------------------------------------------------------------------------
    final clean = checkForUpdate(origin: origin(), remote: GbMod(idRow: page, files: [a, b]));
    expect(clean.layers.map((l) => l.key), [base, patch]);
    expect(clean.outcome, UpdateOutcome.upToDate, reason: "the base is not flagged by the fix it holds");

    // ---- ignore B's update -------------------------------------------------------------------------------------------
    final found = checkForUpdate(origin: origin(), remote: GbMod(idRow: page, files: [a, b, b2]));
    expect(found.subject, patch);
    await amend('Ellen', (current) => current!.withDismissal(subject: found.subject!, until: found.dismissableUpTo));
    expect(origin()!.patches.single.updatesDismissedUntil, b2.dateAdded);
    expect(origin()!.base!.updatesDismissedUntil, isNull, reason: "only B's entry is dated");

    // ---- update B to B2, as the patch update flow writes it ----------------------------------------------------
    expect(updateWriteRoute(origin: origin(), subject: patch).kind, UpdateWriteKind.patch);
    final fix2 = unpacked('Ellen Fix 2', {'ellen.ini': 'B2 fix'});
    final incoming = await readFolderContents(fix2);
    final existing = await readFolderContents(folder);
    final placed = await applier.applyPatchInto(
      modName: 'Ellen',
      modFolder: folder,
      source: fix2,
      incoming: incoming,
      existing: existing,
      placement: resolvePatchPlacement(incoming: incoming.files, target: existing.files),
      patchModId: page,
      recorded: origin()!.downloadOf(patch)!.files,
    );
    expect(placed.success, isTrue);
    await amend(
      'Ellen',
      (current) => withDownloadUpdatedTo(current,
          layer: patch, fileId: fileB2, versionLabel: 'Hair fix', files: placed.writtenFiles),
    );
    expect(origin()!.downloads.map((d) => d.fileId), [fileA, fileB2], reason: 'only B is replaced');
    expect(origin()!.base!.files.map((f) => f.path), ['ellen.ini', 'Textures/Body.dds']);
    expect(read('ellen.ini'), 'B2 fix');

    // ---- update A to A2, as the base update flow writes it -----------------------------------------------------
    final route = updateWriteRoute(origin: origin(), subject: base);
    expect(route.kind, UpdateWriteKind.base);
    expect(route.patchModId, page);
    final main2 = unpacked('Ellen 2', {'ellen.ini': 'A2 ini', 'Textures/Body.dds': 'A2 body'});
    final preview = await applier.preview(modFolder: folder, incomingFolders: [main2.path], ingest: origin()!.ingest);
    final rewritten = await applier.applyBaseThenPatch(
      modName: 'Ellen',
      modFolder: folder,
      preview: preview,
      patchFiles: route.patchFiles,
      patchModId: route.patchModId,
    );
    expect(rewritten.success, isTrue);
    await amend('Ellen', (current) {
      final updated = withDownloadUpdatedTo(current, layer: base, fileId: fileA2, files: rewritten.writtenFiles)!;
      return withRebuiltPatchFiles(updated.copyWith(downloads: [
        updated.base!,
        for (final layer in updated.patches) layer.copyWith(files: rewritten.placedPatchFiles),
      ]));
    });
    expect(read('ellen.ini'), 'B2 fix', reason: 'B2 is put back on top');
    expect(read('Textures/Body.dds'), 'A2 body');
    expect(origin()!.downloads.map((d) => (d.modId, d.fileId)), [(page, fileA2), (page, fileB2)],
        reason: 'both records stay');

    // ---- take B out --------------------------------------------------------------------------------------------
    final onDisk = await readFolderContents(folder);
    const store = PatchStore();
    final stored = <String>{
      for (final file in origin()!.patches.single.files)
        if (await store.holds(modFolder: folder, patchModId: page, relativePath: file.path)) file.path,
    };
    final removed = await applier.removePatch(
      modName: 'Ellen',
      modFolder: folder,
      patchModId: page,
      plan: planPatchRemoval(origin: origin(), patchModId: page, onDisk: onDisk, storedOriginals: stored),
    );
    expect(removed.success, isTrue);
    await amend('Ellen', (current) => withRebuiltPatchFiles(current!.withoutDownload(patch)));

    expect(origin()!.downloads.map((d) => (d.modId, d.fileId)), [(page, fileA2)]);
    expect(read('ellen.ini'), 'A2 ini', reason: "A2's own file comes back");
  });
}
