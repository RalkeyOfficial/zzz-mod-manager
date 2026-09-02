/// **Taking a patch back out of a folder**, decided before anything is touched.
///
/// Pure, and separate from the write for the reason `retention.dart` is: the
/// part worth testing is which files get which treatment, and that needs no
/// filesystem and no mod folder. The applier performs the plan.
///
/// Four outcomes, and the split between the first two is the whole point — a
/// patch adds some files and displaces others, and only the first kind is the
/// patch's to delete.
library;

import '../models/installed_file.dart';
import '../models/mod_download.dart';
import '../models/mod_origin.dart';
import 'folder_contents.dart';
import 'ini_resources.dart';

/// What removing one patch will do, file by file.
class PatchRemovalPlan {
  const PatchRemovalPlan({
    this.delete = const <String>[],
    this.restore = const <String>[],
    this.gone = const <String>[],
    this.unrecoverable = const <String>[],
  });

  static const PatchRemovalPlan nothing = PatchRemovalPlan();

  /// The patch brought these and nothing was underneath, so they go.
  ///
  /// On-disk spelling — these paths delete files, and a lower-cased one deletes
  /// nothing on Linux.
  final List<String> delete;

  /// The patch wrote over the mod's own version of these, and the original is on
  /// hand to put back.
  final List<String> restore;

  /// Recorded, and no longer in the folder.
  ///
  /// **Skipped, never restored.** The record says what the app wrote, so the
  /// user having deleted one since is an edit rather than damage — the same rule
  /// `ingest.patch_files` already reads by. Named so the removal can say it did
  /// less than the record implies.
  final List<String> gone;

  /// The patch wrote over the mod's own version and **the original is not
  /// stored**, so the file stays where it is.
  ///
  /// A folder patched before the store existed, or one whose store could not be
  /// written at install. Deleting these would take the mod's file with the
  /// patch and leave a hole; leaving them keeps a patched file in a folder that
  /// no longer claims to be patched, which is the recoverable half of a bad
  /// choice — and the one the user is told about.
  final List<String> unrecoverable;

  bool get isEmpty =>
      delete.isEmpty &&
      restore.isEmpty &&
      gone.isEmpty &&
      unrecoverable.isEmpty;

  /// Whether performing this would change the folder at all.
  bool get touchesFiles => delete.isNotEmpty || restore.isNotEmpty;

  /// Whether the folder is left holding files the patch put there.
  bool get leavesPatchBehind => unrecoverable.isNotEmpty;
}

/// What removing the patch identified by [patchModId] from [origin] would do.
///
/// [onDisk] is the folder as it stands, so a recorded file that is gone is
/// reported rather than acted on. [storedOriginals] is the set of recorded paths
/// the store actually holds an original for — asked of the store rather than
/// read off the record, because a `replaced` entry says the write displaced
/// something and **not** that keeping it succeeded.
///
/// Returns [PatchRemovalPlan.nothing] for a patch this folder does not record,
/// or one with no file registry: a folder merged by hand has no way to tell the
/// patch's files from the mod's, and guessing would delete the mod.
PatchRemovalPlan planPatchRemoval({
  required ModOrigin? origin,
  required int patchModId,
  required FolderContents onDisk,
  required Set<String> storedOriginals,
}) {
  final patch = _patchIn(origin, patchModId);
  if (patch == null || patch.files.isEmpty) return PatchRemovalPlan.nothing;

  final delete = <String>[];
  final restore = <String>[];
  final gone = <String>[];
  final unrecoverable = <String>[];

  for (final file in patch.files) {
    // Compared normalised, because the loader is case-insensitive and the
    // folder may spell a path differently than the record does; acted on with
    // the spelling that is really there.
    if (!onDisk.files.contains(normalizeIniPath(file.path))) {
      gone.add(file.path);
      continue;
    }
    switch (file.role) {
      case InstalledFileRole.added:
        delete.add(file.path);
      case InstalledFileRole.replaced:
        if (storedOriginals.contains(file.path)) {
          restore.add(file.path);
        } else {
          unrecoverable.add(file.path);
        }
    }
  }

  return PatchRemovalPlan(
    delete: delete,
    restore: restore,
    gone: gone,
    unrecoverable: unrecoverable,
  );
}

/// The layer naming [patchModId], if it is one this folder can take out.
///
/// **Never the bottom layer.** Removing what the folder *is* would leave a patch
/// with nothing to patch — the broken state `ingest.patch_shaped` exists to warn
/// about — so it is refused here rather than merely unexpressible. What a user
/// wants for the bottom layer is deleting the mod, which already exists.
ModDownload? _patchIn(ModOrigin? origin, int patchModId) {
  for (final patch in origin?.patches ?? const <ModDownload>[]) {
    if (patch.modId == patchModId) return patch;
  }
  return null;
}

/// Every patch in this folder that can actually be taken out.
///
/// What the menu entry is shown for. A layer with no file registry is excluded:
/// it is recorded, it may be checked for updates, and it cannot be removed,
/// because nothing says which of the folder's files are its.
///
/// **Topmost first**, which is the order they have to come out in: a layer with
/// another one over it has had some of its own files overwritten in turn, so
/// pulling it out from underneath would put the mod's originals back *over* the
/// patch still sitting on top.
List<ModDownload> removablePatches(ModOrigin? origin) => [
      for (final patch in (origin?.patches ?? const <ModDownload>[]).reversed)
        if (patch.hasFileRecord && patch.hasIdentity) patch,
    ];
