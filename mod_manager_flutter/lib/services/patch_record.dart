/// **Writing down what a folder holds**, which is the only half of patch
/// detection that outlives the install.
///
/// A patch folder is legible exactly once: before the user drags the base mod's
/// files in around it. Afterwards every reference resolves and the folder is
/// indistinguishable from an ordinary one-download mod, so recognising a patch
/// and not recording it has the same result as never looking — no mark on the
/// card, no row offering to name what it patches, and an update check that goes
/// on asking the patch's own page and calling the answer "up to date".
///
/// Both import paths write through here, and both ask **before** their copy so
/// they can offer a destination rather than warn afterwards. What the write says
/// is the same either way; `patch_install_flow.dart` is where it is called from.
///
/// Each of these is a **stack operation** — insert at the bottom, add on top,
/// amend one layer — and every one of them re-derives `ingest.patch_files`
/// afterwards, so the flat compatibility list cannot drift from the layers it
/// summarises.
library;

import '../models/installed_file.dart';
import '../models/mod_download.dart';
import '../models/mod_ingest.dart';
import '../models/mod_origin.dart';
import '../models/origin_enums.dart';
import 'folder_downloads.dart';
import 'ini_resources.dart';

/// The patch's **own** remote identity, for the writes that have one: a patch installed from the Marketplace, and an update's patch-shaped file placed into a mod.
///
/// A Marketplace download knows exactly which mod page and file it is, and that is what gets recorded against the mod it is written into.
/// A folder dragged off a disk has no page at all, so its layer records only the files it wrote and cannot be checked for updates.
/// The write is the same operation either way; only the bookkeeping differs.
class PatchIdentity {
  const PatchIdentity({
    required this.modId,
    this.name,
    this.fileId,
    this.version,
    this.versionLabel,
    this.archiveMd5,
  });

  final int modId;

  /// The patch's mod page title, for the layer's `name`.
  final String? name;
  final int? fileId;
  final String? version;
  final String? versionLabel;
  final String? archiveMd5;

  /// **At `exact` on both axes**, which this is the one route to for a layer the user did not identify by hand:
  /// every other one is somebody telling us about bytes they moved in themselves.
  ///
  /// No `role`: it is taken from the position the layer lands in, and the write that places it is what knows that.
  ModDownload get layer => ModDownload(
        modId: modId,
        modIdConfidence: OriginConfidence.exact,
        name: name,
        fileId: fileId,
        version: version,
        versionLabel: versionLabel,
        versionConfidence: OriginConfidence.exact,
        archiveMd5: archiveMd5,
      );
}

/// [current] recorded as **a patch whose base is missing**, with [base] named as
/// the mod it applies to when the user has said which that is.
///
/// Null in, null out: this is an **amendment**, not the write that creates an
/// origin block. Both import paths seed one for every folder they create, so a
/// null here means that seed write itself failed — and inventing a block would
/// replace a reported failure with a sidecar claiming a provenance nobody
/// observed.
///
/// The flag is set whether or not a base is named. Being told what a folder
/// patches does not make it one download.
///
/// **Naming the base inserts it underneath**, which is the whole reason the
/// stack is ordered: what was the only layer becomes the patch above it, with no
/// role field to rewrite because the role follows the position.
ModOrigin? withPatchShape(ModOrigin? current, {ModDownload? base}) {
  if (current == null) return null;
  final shaped = current.copyWith(
    ingest: (current.ingest ?? const ModIngest()).copyWith(patchShaped: true),
  );
  if (base == null) return withRebuiltPatchFiles(shaped);

  // **Inserted once, never twice.** This runs again on every re-import of the
  // same folder, so a stack that already has something underneath gets its
  // bottom layer *replaced* rather than a second base pushed under it: a folder
  // patches one mod, so two would be a contradiction rather than more
  // information.
  if (shaped.downloads.length > 1) {
    return withRebuiltPatchFiles(shaped.withBase((_) => base));
  }
  return withRebuiltPatchFiles(shaped.withBaseInserted(base));
}

/// [current] recorded as **also holding a patch** that was written into it.
///
/// The other direction from [withPatchShape]: here the folder already holds the
/// mod and the patch goes on top, so no `patch_shaped` flag is involved — that
/// flag says the bottom of the stack is missing, which is the opposite claim.
///
/// A block is created when there is none, unlike [withPatchShape]. The target is
/// an existing library mod, and most of a library that predates origin tracking
/// has no block at all — refusing to record the patch on those would make the
/// feature quietly unavailable for exactly the folders most likely to be
/// hand-assembled.
///
/// **A patch with no mod id is still recorded.** The install knows exactly which files it laid down even when it cannot say which mod they are,
/// and that is enough to set the layer aside on a base update.
/// What it cannot do is be checked for updates or be taken back out: both need a page, the second because the store of displaced files is keyed by it.
ModOrigin withAppliedPatch(ModOrigin? current, ModDownload patch) {
  final base =
      current ?? const ModOrigin(provenance: OriginProvenance.importedFolder);
  return withRebuiltPatchFiles(base.withLayerOnTop(patch));
}

/// [current] with the layer [layer] names recorded as the file the app has just
/// downloaded and written into the folder.
///
/// By key, so a page that is both the folder's base and a patch on it has only
/// the layer that was written stamped.
///
/// A separate write from the one that records the folder's own identity, and for
/// one reason: **a layer's place in the stack does not change because we learned
/// something about it.** Stamping this file id onto the wrong layer would claim
/// one download is another.
///
/// A folder with no such layer is returned unchanged: this amends, and inventing
/// the entry would record a download nobody named.
ModOrigin? withDownloadUpdatedTo(
  ModOrigin? current, {
  required DownloadKey layer,
  required int fileId,
  String? version,
  String? versionLabel,
  String? archiveMd5,
  List<InstalledFile>? files,
  DateTime? updatesDismissedUntil,
}) {
  if (current == null) return null;
  return withRebuiltPatchFiles(current.withDownload(
    layer,
    (download) => download.updatedTo(
      modId: layer.modId,
      fileId: fileId,
      version: version,
      versionLabel: versionLabel,
      archiveMd5: archiveMd5,
      files: files,
      updatesDismissedUntil: updatesDismissedUntil,
    ),
  ));
}

/// [origin] with the files an update put back recorded on the patches, by the recorded path each came from.
///
/// **A patch takes only its own files**: one that records none is left as it is, and one whose files were all missing
/// records none. With a single patch, though, every placed file is its, which also gives a record that predates the
/// per-layer registries its first one. Called only for a write that had recorded patch files to put back.
ModOrigin withPlacedPatches(ModOrigin origin, Map<String, InstalledFile> placedFrom) {
  final patches = origin.patches;
  if (patches.isEmpty) return origin;
  return origin.copyWith(
    downloads: [
      origin.downloads.first,
      for (final patch in patches)
        if (patches.length == 1)
          patch.copyWith(files: placedFrom.values.toList())
        else if (patch.files.isEmpty)
          patch
        else
          patch.copyWith(files: [for (final file in patch.files) ?placedFrom[normalizeIniPath(file.path)]]),
    ],
  );
}

/// [origin] with `ingest.patch_files` recomputed from the stack.
///
/// Every write that changes what a folder holds goes through here, so the flat
/// list and the layers cannot drift — a `patch_files` naming a patch that has
/// been removed would have the next base update set aside files nothing owns.
///
/// **A folder with no per-layer registries is left exactly as it is.**
/// Everything installed before they existed has a hand-written `patch_files` and
/// no `files` to derive one from, so rebuilding would replace the only record it
/// has with an empty list — and that record is what makes it rebuildable.
ModOrigin withRebuiltPatchFiles(ModOrigin origin) {
  final derived = derivedPatchFiles(origin);
  if (derived.isEmpty) return origin;
  return origin.copyWith(
    ingest: (origin.ingest ?? const ModIngest()).copyWith(patchFiles: derived),
  );
}
