/// The writes that take a mod folder back, with no `BuildContext`: a snapshot restored, and a patch taken out.
/// History's Restore and Take out run them behind their questions and cards, and an update run's Undo runs them on its own (`docs/library-screen.md` §15, `docs/update-runs.md` §8).
/// Each saves the folder as a snapshot before it changes anything.
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;

import '../models/character_info.dart';
import '../models/mod_download.dart';
import '../utils/state_providers.dart';
import 'backup/snapshot_service.dart';
import 'folder_contents.dart';
import 'mod_manager_service.dart';
import 'patch_record.dart';
import 'patch_removal.dart';
import 'patch_store.dart';
import 'update_apply/mod_activation_port.dart';
import 'update_apply/update_applier.dart';
import 'writes_in_flight.dart';

Future<T> _unwatched<T>(Future<T> Function() task) => task();

/// The library folder, or null when none is set.
String? _libraryPath(ModManagerService mods) => switch (mods.modsPath) {
      final path? when path.isNotEmpty => path,
      _ => null,
    };

/// Puts [mod]'s folder back to [snapshot] while the mod is marked as being written, then reads the saved versions, the mod's keys and the library again.
/// With no library folder set nothing is written or read.
Future<UpdateApplyResult> writeSnapshotBack(
  ProviderContainer container, {
  required ModInfo mod,
  required ModSnapshot snapshot,
}) async {
  if (_libraryPath(await container.read(modManagerServiceProvider.future)) == null) {
    return UpdateApplyResult.failed(UpdateApplyFailure.modMissing);
  }
  final result = await restoreSnapshotFiles(container, mod: mod, snapshot: snapshot);
  // A failed restore may still have changed the folder, so it is read again either way.
  await container.read(libraryProvider.notifier).rescan();
  return result;
}

/// [writeSnapshotBack] without its rescan, for a caller that reads the library again itself:
/// the restore, the prune of the saved versions it added to, and the saved versions and the mod's keys read again.
Future<UpdateApplyResult> restoreSnapshotFiles(
  ProviderContainer container, {
  required ModInfo mod,
  required ModSnapshot snapshot,
}) async {
  final mods = await container.read(modManagerServiceProvider.future);
  final modsPath = _libraryPath(mods);
  if (modsPath == null) return UpdateApplyResult.failed(UpdateApplyFailure.modMissing);

  final snapshots = container.read(snapshotServiceProvider);
  final applier = UpdateApplier(
    snapshots: snapshots,
    activation: ModManagerActivationPort(mods, leaveOff: (m) => leftOffAfterWrite(container, m)),
  );
  // The prune is part of the write, so closing the app waits for it too.
  final result = await WritesInFlight.shared.track(() async {
    final result = await whileWritingMod(
      container,
      mod.id,
      () => applier.restore(modName: mod.id, modFolder: Directory(path.join(modsPath, mod.id)), snapshot: snapshot),
    );

    // A rollback takes a safety copy of its own before it writes, so the store's budget moved here as on any other write.
    // Whether the restore landed or not: the copy was taken first.
    if (result.snapshot != null) await snapshots.prune();
    return result;
  });
  container.invalidate(modBackupsProvider);
  // Read again whatever the stamp says: a restore puts back old times, which can match what was there before.
  mods.invalidateKeybinds(mod.id);
  return result;
}

/// What taking [patch] out of [mod]'s folder would do, worked out against the folder as it stands, before anything is asked or written.
class PatchRemoval {
  const PatchRemoval._({
    required this.mods,
    required this.mod,
    required this.patch,
    required this.modFolder,
    required this.plan,
  });

  final ModManagerService mods;
  final ModInfo mod;
  final ModDownload patch;
  final Directory modFolder;
  final PatchRemovalPlan plan;

  /// Whether the removal moves or leaves any file; when not, only the record goes.
  bool get touchesFolder => plan.touchesFiles || plan.leavesPatchBehind;
}

/// Reads [mod]'s folder and the patch's kept originals and plans the removal of [patch], whose layer has a page.
/// Null when no library folder is set.
Future<PatchRemoval?> preparePatchRemoval(
  ProviderContainer container, {
  required ModInfo mod,
  required ModDownload patch,
}) async {
  final patchModId = patch.modId!;
  final mods = await container.read(modManagerServiceProvider.future);
  final modsPath = mods.modsPath;
  if (modsPath == null) return null;
  final modFolder = Directory(path.join(modsPath, mod.id));

  final onDisk = await readFolderContents(modFolder);
  const store = PatchStore();
  final stored = <String>{
    for (final file in patch.files)
      if (await store.holds(
        modFolder: modFolder,
        patchModId: patchModId,
        relativePath: file.path,
      ))
        file.path,
  };

  return PatchRemoval._(
    mods: mods,
    mod: mod,
    patch: patch,
    modFolder: modFolder,
    plan: planPatchRemoval(
      origin: mod.origin,
      patchModId: patchModId,
      onDisk: onDisk,
      storedOriginals: stored,
    ),
  );
}

/// Drops the patch's record from a folder that no longer holds it, and the folder's verdict with it. True when the record went.
Future<bool> forgetPatchRecord(ProviderContainer container, PatchRemoval removal) async {
  final removed = await whileWritingMod(container, removal.mod.id, () => _forget(removal.mods, removal.mod, removal.patch));
  if (removed) forgetUpdateCheck(container, removal.mod.id);
  return removed;
}

/// The write half of taking a patch out: the folder is snapshotted, the patch's files go and the mod's own come back,
/// the snapshots are pruned, and on success the record and the folder's verdict go.
/// The library and the saved versions are read again either way. [work] shows the write on the button that asked.
Future<PatchRemovalResult> writePatchRemoval(
  ProviderContainer container,
  PatchRemoval removal, {
  Future<T> Function<T>(Future<T> Function() task) work = _unwatched,
}) async {
  final PatchRemoval(:mods, :mod, :patch, :modFolder, :plan) = removal;
  final snapshots = container.read(snapshotServiceProvider);
  final applier = UpdateApplier(
    snapshots: snapshots,
    activation: ModManagerActivationPort(mods, leaveOff: (m) => leftOffAfterWrite(container, m)),
  );
  // The prune and the record are part of the write, so closing the app waits for them too.
  final result = await WritesInFlight.shared.track(() async {
    final result = await work(
      () => whileWritingMod(
        container,
        mod.id,
        () => applier.removePatch(
          modName: mod.id,
          modFolder: modFolder,
          patchModId: patch.modId!,
          plan: plan,
        ),
      ),
    );

    // **Before the success check**, the same as the update path: a snapshot exists the moment the capture succeeded, and the failure branch is where a user needs "Restore a previous version…" to be in the menu.
    //
    // Retention runs on the same condition and for the same reason: the snapshot comes before anything is moved, so a removal that failed part-way still added a whole folder to the budget — see §5 of `docs/applying-updates.md`.
    if (result.snapshot != null) {
      container.invalidate(modBackupsProvider);
      await snapshots.prune();
    }
    // Read again whatever the `.ini` stamp says, and before the success check: a removal that failed part-way may still have moved files.
    mods.invalidateKeybinds(mod.id);

    // **The record goes even when some files could not be moved.** What it claims is that this folder holds that patch, and after this it does not — the leftovers are named on screen rather than kept as a claim that would go on offering to update a patch that has been taken out.
    if (result.success) await whileWritingMod(container, mod.id, () => _forget(mods, mod, patch));
    return result;
  });

  // The folder's verdict can name the patch's layer, which is gone.
  if (result.success) forgetUpdateCheck(container, mod.id);
  // Pruning already ran with the snapshot, and the keys were dropped, above.
  container.invalidate(modBackupsProvider);
  container.invalidate(libraryProvider);
  return result;
}

/// Drops the layer and rebuilds the flat patch-file list from what is left.
///
/// Both in one write: a `patch_files` still naming a patch that has gone would have the next base update set aside files nothing owns.
Future<bool> _forget(
  ModManagerService mods,
  ModInfo mod,
  ModDownload patch,
) async {
  final result = await mods.updateModOrigin(
    mod.id,
    (current) => current == null
        ? null
        // The patch of that page, never its base: one page can be both.
        : withRebuiltPatchFiles(current.withoutDownload(DownloadKey.patch(patch.modId!))),
  );
  return result.ok;
}
