/// **Update it**: writing a folder the user dropped into a mod they already have (`docs/importing-mods.md` §5).
///
/// The write is the update's, unchanged: snapshot, wipe everything but the sidecar, copy the dropped folder in, put a
/// recorded patch back ([UpdateApplier.applyBaseThenPatch]). What this file adds is the record afterwards, which keeps
/// what says *which mod* the folder is and clears what said *which file*, since the bytes are no longer that file's.
library;

import 'dart:io';

import 'package:path/path.dart' as path;

import '../../models/character_info.dart';
import '../../models/installed_file.dart';
import '../../models/mod_download.dart';
import '../../models/mod_ingest.dart';
import '../../models/mod_origin.dart';
import '../../models/mod_origin_seed.dart';
import '../../models/origin_enums.dart';
import '../log/logger.dart';
import '../origin_write.dart';
import '../patch_record.dart';
import 'update_applier.dart';
import 'update_layout.dart';

final Logger _log = Logger('update.apply');

/// What an Update it came to.
class LocalUpdateResult {
  const LocalUpdateResult({required this.write, this.record});

  /// The write itself, with its snapshot.
  final UpdateApplyResult write;

  /// How the origin block's rewrite ended. Null when the write did not land, since nothing is recorded then.
  final OriginWriteResult? record;

  bool get success => write.success;
}

/// Writes [folders] into the library's [mod] and records what it is afterwards.
///
/// [folders] maps each dropped source folder to the subfolder of the mod it goes into, empty for the mod itself.
/// [seed] says what the bytes came from: an archive, with its md5, or a folder. The caller marks the mod as being
/// written around this whole call (`whileWritingMod`), so the folder reads as busy until the record is down too.
Future<LocalUpdateResult> applyLocalUpdate({
  required UpdateApplier applier,
  required OriginWriter amend,
  required ModInfo mod,
  required String modsPath,
  required Map<String, String> folders,
  required ModOriginSeed seed,
  DateTime? now,
}) async {
  final preview = await applier.previewDropped(folders);
  final origin = mod.origin;
  final patchFiles = origin?.ingest?.patchFiles ?? const <String>[];
  final result = await applier.applyBaseThenPatch(
    modName: mod.id,
    modFolder: Directory(path.join(modsPath, mod.id)),
    preview: preview,
    patchFiles: patchFiles,
    patchModId: origin == null || origin.patches.isEmpty ? null : origin.patches.last.modId,
    previousVersion: origin?.base?.version,
    previousVersionLabel: origin?.base?.versionLabel,
  );
  if (!result.success) {
    _log.warning('a dropped folder could not be written into a mod', fields: {'mod': mod.id, 'failure': result.failure?.name});
    return LocalUpdateResult(write: result);
  }

  final stamp = now ?? DateTime.now();
  final record = await amend(
    mod.id,
    (current) => originAfterLocalUpdate(
      current,
      seed: seed,
      layout: preview.layout,
      files: result.writtenFiles,
      placedFrom: patchFiles.isEmpty ? null : result.placedFrom,
      patchFiles: patchFiles.isEmpty ? null : result.patchFiles,
      now: stamp,
    ),
  );
  _log.info('updated a mod from a dropped folder', fields: {'mod': mod.id, 'files': result.filesWritten});
  return LocalUpdateResult(write: result, record: record);
}

/// The origin block of a mod whose folder was just rewritten from a dropped one.
///
/// **Kept, because the write says nothing against it:** the layers of the stack with their mod ids, confidences and
/// names, `tracking`, a dismissal, and each patch's record. **Cleared, because it described the old bytes:** the base
/// layer's file id, version, label and baseline, its version back to unknown, and the old archive's md5, replaced by
/// the dropped archive's when there was one. The mod then reads "Which file?" and is answered like any other, and the
/// app never decides from a name which published file a dropped folder is. **Rewritten:** provenance, the install
/// date, the base layer's file list and the layout. The folder leaves its sibling group, since a group update would
/// write the archive that installed it over what was just dropped.
ModOrigin originAfterLocalUpdate(
  ModOrigin? current, {
  required ModOriginSeed seed,
  required UpdateLayout layout,
  required List<InstalledFile> files,
  required DateTime now,
  Map<String, InstalledFile>? placedFrom,
  List<String>? patchFiles,
}) {
  var block = current ?? ModOrigin(provenance: seed.provenance);
  block = block.withBase(
    (base) => ModDownload(
      role: DownloadRole.base,
      modId: base.modId,
      modIdConfidence: base.modIdConfidence,
      name: base.name,
      archiveMd5: seed.archiveMd5,
      updatesDismissedUntil: base.updatesDismissedUntil,
      files: files,
    ),
  );
  if (placedFrom != null) block = withPlacedPatches(block, placedFrom);

  final combined = layout.mappings.any((mapping) => !mapping.isRoot);
  final previous = block.ingest;
  block = block.copyWith(
    provenance: seed.provenance,
    installedAt: now.toUtc(),
    installedAtIsProxy: false,
    ingest: ModIngest(
      mode: combined ? IngestMode.combined : IngestMode.separate,
      folders: combined
          ? [for (final mapping in layout.mappings) mapping.targetSubPath]
          : [layout.mappings.single.source],
      patchShaped: previous?.patchShaped ?? false,
      patchFiles: patchFiles ?? previous?.patchFiles ?? const <String>[],
    ),
  );
  return withRebuiltPatchFiles(block);
}
