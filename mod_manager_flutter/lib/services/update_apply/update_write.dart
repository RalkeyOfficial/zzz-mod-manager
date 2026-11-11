/// The half of an update that writes to a mod folder, with no window in sight.
///
/// [writeUpdate] takes what `prepareUpdate` found and writes it.
/// A base is written into each folder: the mod is turned off if it was on, the old folder is saved as a snapshot, everything but the sidecar is deleted, the new files are copied, a recorded patch is put back, the mod is turned on again, old snapshots are pruned, and the new origin is recorded.
/// A patch layer is placed over what the folder holds without clearing it: snapshot, placement, the files the last version recorded and this one does not place taken out, the mod turned on again, snapshots pruned, the origin recorded.
/// Then the library and the update marks follow what reached the disk.
///
/// The order is the safety argument and lives in `UpdateApplier`; this is the bookkeeping around it.
/// It reads the app's container and never a widget's `ref`, which throws once the widget is gone: a write that landed has to reach the library and the marks whether or not anyone is still watching, and a throw between the copy and the record would leave a folder holding the new files under a record naming the old version.
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;

import '../../models/character_info.dart';
import '../../models/gamebanana/gamebanana.dart';
import '../../models/installed_file.dart';
import '../../models/mod_download.dart';
import '../../models/mod_origin.dart';
import '../../models/origin_enums.dart';
import '../../utils/gamebanana_url.dart';
import '../../utils/state_providers.dart';
import '../mod_manager_service.dart';
import '../patch_record.dart';
import '../update_check.dart';
import '../writes_in_flight.dart';
import 'update_applier.dart';
import 'update_layout.dart';
import 'update_prepare.dart';
import 'update_target.dart';

/// What a write did, for the caller to say.
class UpdateReport {
  const UpdateReport({required this.applied, required this.outcome, this.removedMarks = const <String, UpdateCheck>{}});

  /// What the write did to each folder it attempted, in order.
  final List<AppliedUpdate> applied;

  /// What those add up to: whether the library changed, which marks were settled, and the one failure when there was one attempt and it failed.
  final GroupWriteOutcome outcome;

  /// The marks the write removed, by folder id, as they stood. A patch write removes none: the caller drops the folder's verdict.
  final Map<String, UpdateCheck> removedMarks;
}

/// Writes what [prepared] found.
///
/// A base ([PreparedFolders]) is written into [targets], the folders the caller chose, and nothing is chosen for it: the primary is one of the targets only when the caller passes it.
/// An empty [targets], or one holding a target that cannot proceed (a layout that cannot be reconciled, a folder the group refused), is an [ArgumentError] and nothing is written.
/// The base is written sequentially, and a failure does not stop the rest: each folder is its own mod with its own snapshot and copy, so one that fails leaves the others correctly updated.
/// A patch ([PreparedPatch]) is placed into the one folder and ignores [targets], so pass an empty list.
///
/// [onFolder] is told which folder is starting, of how many, and [onStep] which part of that folder's write is starting ([UpdateWriteStep]).
/// [onWritesDone] is called exactly once, in a `finally`, when the files are written and a caller's progress window can come down: for a base after the last folder is recorded, and for a patch right after its files are placed, before the snapshots are pruned and the record is written.
/// Either way it is called when the write threw too, and not when the arguments were rejected.
Future<UpdateReport> writeUpdate(
  ProviderContainer container,
  UpdatePrepared prepared, {
  required List<UpdateTarget> targets,
  void Function(ModInfo mod, int index, int total)? onFolder,
  void Function(ModInfo mod, UpdateWriteStep step)? onStep,
  void Function()? onWritesDone,
}) => switch (prepared) {
  final PreparedFolders folders => _writeFolders(
    container,
    folders,
    targets: targets,
    onFolder: onFolder,
    onStep: onStep,
    onWritesDone: onWritesDone,
  ),
  // The prune and the record are part of the write, so closing the app waits for them too.
  final PreparedPatch patch => WritesInFlight.shared.track(
      () => _writePatch(container, patch, onStep: onStep, onWritesDone: onWritesDone),
    ),
};

Future<UpdateReport> _writeFolders(
  ProviderContainer container,
  PreparedFolders prepared, {
  required List<UpdateTarget> targets,
  required void Function(ModInfo mod, int index, int total)? onFolder,
  required void Function(ModInfo mod, UpdateWriteStep step)? onStep,
  required void Function()? onWritesDone,
}) async {
  if (targets.isEmpty) throw ArgumentError.value(targets, 'targets', 'a base is written into at least one folder');
  if (targets.any((target) => !target.canProceed)) {
    throw ArgumentError.value(targets, 'targets', 'a folder that cannot proceed is not written');
  }
  final request = prepared.request;

  final List<AppliedUpdate> applied;
  try {
    applied = await _writeAll(
      container: container,
      services: prepared.services,
      // Every member takes the same file off the same list, so a pick below the newest is the same passed-over release for each of them.
      dismissUntil: dismissalAfterTaking(request.file, request.published),
      targets: targets,
      modsPath: request.modsPath,
      remoteModId: request.remoteModId,
      file: request.file,
      archiveMd5: prepared.unpacked.archiveMd5,
      asCompanion: request.asCompanion,
      primary: prepared.primary,
      onFolder: onFolder,
      onStep: onStep,
    );
  } finally {
    onWritesDone?.call();
  }

  final outcome = summariseGroupWrite(applied, reinstall: request.reinstall);

  container.invalidate(modBackupsProvider);
  container.invalidate(libraryProvider);

  // Only what this write settled loses its mark: a folder the user unticked still has its update to take, one whose write failed needs its mark more than before, and a repair takes nothing (`summariseGroupWrite`).
  final notifier = container.read(modUpdateChecksProvider.notifier);
  final removed = {
    for (final id in outcome.settledMarks)
      if (notifier.state[id] case final mark?) id: mark,
  };
  notifier.state = {...notifier.state}..removeWhere((id, _) => outcome.settledMarks.contains(id));

  return UpdateReport(applied: applied, outcome: outcome, removedMarks: removed);
}

/// Writes the download into every folder in [targets], pruning snapshots after each folder rather than once at the end: several whole-folder snapshots can land together against the 5 GB budget, and each folder's own new snapshot is the one retention never prunes.
Future<List<AppliedUpdate>> _writeAll({
  /// Where each folder is marked as being written, so a press on its switch waits.
  required ProviderContainer container,
  required UpdateServices services,

  /// What the dismissal becomes on every record written (`dismissalAfterTaking`).
  required DateTime? dismissUntil,
  required List<UpdateTarget> targets,
  required String modsPath,
  required int remoteModId,
  required GbFile file,
  required String? archiveMd5,
  required bool asCompanion,
  required UpdateTarget primary,
  required void Function(ModInfo mod, int index, int total)? onFolder,
  required void Function(ModInfo mod, UpdateWriteStep step)? onStep,
}) async {
  final (:mods, :snapshots, :applier) = services;
  final applied = <AppliedUpdate>[];
  for (var i = 0; i < targets.length; i++) {
    final target = targets[i];
    onFolder?.call(target.mod, i + 1, targets.length);

    // The prune and the record are part of the folder's write, so closing the app waits for them too.
    await WritesInFlight.shared.track(() async {
      final result = await whileWritingMod(
        container,
        target.mod.id,
        () => applier.applyBaseThenPatch(
          modName: target.mod.id,
          modFolder: Directory(path.join(modsPath, target.mod.id)),
          preview: target.preview,
          patchFiles: target.patchFiles,
          patchModId: target.patchModId,
          previousVersion: target.mod.origin?.base?.version,
          previousVersionLabel: target.mod.origin?.base?.versionLabel,
          onStep: onStep == null ? null : (step) => onStep(target.mod, step),
        ),
      );
      applied.add(AppliedUpdate(mod: target.mod, result: result));
      // Whether the write landed or not, and before anything below can throw: a failed write may still have changed the folder, and a file written over one of the same size can keep its times on NTFS (`docs/library-screen.md` §12).
      mods.invalidateKeybinds(target.mod.id);

      // Before the success check: a snapshot exists once the write got past its snapshot step, and a failed copy sends the user to the rollback menu, which is drawn from this cached set.
      // Pruning runs whenever one was taken, since a copy that failed part-way still added a whole folder to the budget.
      if (result.snapshot != null) {
        container.invalidate(modBackupsProvider);
        await snapshots.prune();
      }
      if (!result.success) return;

      await _recordOrigin(
        mods: mods,
        mod: target.mod,
        remoteModId: remoteModId,
        dismissUntil: dismissUntil,
        file: file,
        archiveMd5: archiveMd5,
        layout: target.preview.layout,
        // Only ever the mod the user opened: a sibling's write is that folder's own bottom layer, since the group refuses any member whose stack says otherwise.
        asCompanion: asCompanion && target.mod.id == primary.mod.id,
        // Where the patch is now, since `applyBaseThenPatch` moves it onto the new base's layout.
        patchFiles: target.patchFiles.isEmpty ? null : result.patchFiles,
        files: result.writtenFiles,
        placedFrom: target.patchFiles.isEmpty ? null : result.placedFrom,
      );
    });
  }
  return applied;
}

Future<UpdateReport> _writePatch(
  ProviderContainer container,
  PreparedPatch prepared, {
  required void Function(ModInfo mod, UpdateWriteStep step)? onStep,
  required void Function()? onWritesDone,
}) async {
  final request = prepared.request;
  final mod = request.mod;
  final layer = _layerKey(request.remoteModId, asCompanion: request.asCompanion);

  final UpdateServices services;
  final UpdateApplyResult result;
  try {
    services = await updateServicesFor(container);
    result = await whileWritingMod(container, mod.id, () => services.applier.applyPatchInto(
      modName: mod.id,
      modFolder: request.modFolder,
      source: prepared.source,
      incoming: prepared.incoming,
      existing: prepared.existing,
      placement: prepared.placement,
      // Only a patch companion can be taken back out, so only it needs the mod's displaced files kept; a folder that is the patch has no such operation.
      patchModId: request.asCompanion ? request.remoteModId : null,
      // This layer's own last version, so what it no longer places is taken back out.
      recorded: mod.origin?.downloadOf(layer)?.files ?? const <InstalledFile>[],
      // A layer above this one has overwritten some of its files in turn, and those paths are not this layer's to touch.
      claimedAbove: _recordedAbove(mod.origin, layer),
      onStep: onStep == null ? null : (step) => onStep(mod, step),
    ));
  } finally {
    onWritesDone?.call();
  }
  final (:mods, :snapshots, applier: _) = services;
  // Before the success check, as after a base update: a failed write may still have changed the folder.
  mods.invalidateKeybinds(mod.id);

  if (result.snapshot != null) {
    container.invalidate(modBackupsProvider);
    // Whenever one was taken: a placement that failed part-way still added a whole folder to the budget (`docs/applying-updates.md` §5).
    await snapshots.prune();
  }

  final applied = [AppliedUpdate(mod: mod, result: result)];
  final outcome = GroupWriteOutcome(
    settledMarks: const <String>{},
    changed: result.success || result.failure == UpdateApplyFailure.copy,
    soleFailure: result.success ? null : applied.single,
  );
  if (!result.success) return UpdateReport(applied: applied, outcome: outcome);

  // One write for whichever layer this was, found by its key.
  // `ingest` is not refreshed from this archive's layout: the folder's shape belongs to its bottom layer and this archive's folder names describe a patch.
  await mods.updateModOrigin(mod.id, (current) {
    if (current == null) return null;
    final updated = withDownloadUpdatedTo(
      current,
      layer: layer,
      fileId: request.file.idRow,
      version: request.file.version,
      versionLabel: request.file.description,
      archiveMd5: prepared.unpacked.archiveMd5,
      // This version's files replace the last one's: the paths move whenever the two authors' layouts differ.
      files: result.writtenFiles,
      updatesDismissedUntil: dismissalAfterTaking(request.file, request.published),
    );
    if (updated == null) return null;
    // The folder's own facts only when what the folder is was written: a patch arriving on top does not re-date it.
    if (current.indexOf(layer) != 0) return updated;
    return updated.copyWith(
      source: gameBananaSource,
      provenance: OriginProvenance.downloaded,
      installedAt: DateTime.now(),
    );
  });

  // Pruning already ran with the snapshot, and the keys were dropped with the write, above.
  container.invalidate(modBackupsProvider);
  container.invalidate(libraryProvider);

  return UpdateReport(applied: applied, outcome: outcome);
}

/// The layer a write of [modId] is about: a patch for a companion, else the base. A page can be both in one folder, so the id alone does not say which.
DownloadKey _layerKey(int modId, {required bool asCompanion}) =>
    asCompanion ? DownloadKey.patch(modId) : DownloadKey.base(modId);

/// Every path recorded by a layer sitting over [layer] in this folder, which a write to [layer] must not remove.
/// Upward only: a layer under it records the same path because this one wrote over it, and reading that as a claim would make every displacement untouchable.
List<String> _recordedAbove(ModOrigin? origin, DownloadKey layer) {
  if (origin == null) return const <String>[];
  final index = origin.indexOf(layer);
  if (index < 0) return const <String>[];
  return [
    for (final layer in origin.downloads.skip(index + 1))
      for (final file in layer.files) file.path,
  ];
}

/// Writes what the folder now is.
///
/// Both confidences reach `exact`, since the user picked this row of the mod's file list and the app wrote exactly that file id; the clearing rules live in [ModOrigin.updatedTo] and [ModDownload.updatedTo].
/// It is written against the identity that was written, because stamping a companion's file id onto the primary would claim the folder is that other mod.
/// `ingest` is refreshed from what happened, so a mod with no layout on record has one for its next update.
/// [files] is what this write laid down, the base, and [placedFrom] is where each patch ended up on top of it.
Future<void> _recordOrigin({
  required ModManagerService mods,
  required ModInfo mod,
  required int remoteModId,
  required GbFile file,
  required String? archiveMd5,
  required UpdateLayout layout,
  required bool asCompanion,
  required List<String>? patchFiles,
  required DateTime? dismissUntil,
  List<InstalledFile>? files,
  Map<String, InstalledFile>? placedFrom,
}) async {
  final now = DateTime.now();
  await mods.updateModOrigin(mod.id, (current) {
    var block = current ??
        const ModOrigin(provenance: OriginProvenance.downloaded);

    // The layer that was written, whether it is the bottom of the stack or one above it.
    ModDownload record(ModDownload download) => download.updatedTo(
          modId: remoteModId,
          fileId: file.idRow,
          version: file.version,
          versionLabel: file.description,
          archiveMd5: archiveMd5,
          files: files,
          updatesDismissedUntil: dismissUntil,
        );
    // This write is always the bottom layer's (`applyBaseThenPatch`), whatever [asCompanion] says about the wording.
    final layer = DownloadKey.base(remoteModId);
    final written = block.downloadOf(layer);
    block = written == null
        // Not on record at all: the layer it wrote is what the folder now is.
        ? block.withBase(record)
        : block.withDownload(layer, record);

    // The layers above moved onto the new base's layout, so their records are rewritten in the same write.
    if (placedFrom != null) block = withPlacedPatches(block, placedFrom);

    block = block.copyWith(
      source: gameBananaSource,
      ingest: ingestAfterUpdate(layout, block.ingest, patchFiles: patchFiles),
    );

    // Only when what the folder is was written: a patch arriving on top does not re-date it.
    if (block.indexOf(layer) != 0) return withRebuiltPatchFiles(block);
    return withRebuiltPatchFiles(block.copyWith(
      provenance: OriginProvenance.downloaded,
      installedAt: now,
      // Observed, so the proxy flag goes: a flag saying the date was derived from file timestamps would make anything comparing dates distrust one it can rely on.
      installedAtIsProxy: false,
    ));
  });
}
