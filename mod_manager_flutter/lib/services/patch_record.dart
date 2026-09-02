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

/// How an import amends the origin block of a mod it has just created.
///
/// A seam rather than a direct call so this file stays testable against a real
/// sidecar without a `ModManagerService` and its singletons behind it.
typedef OriginAmender = Future<bool> Function(
  String modName,
  ModOrigin? Function(ModOrigin? current) update,
);

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
  // **Only ever added, never replaced from here.** An unanswered prompt is the
  // user not saying, which is not the same as them saying there is nothing
  // there — and this runs again on every re-import of the same folder. A folder
  // that already has something underneath is left alone: it is not a patch
  // missing its base any more.
  if (shaped.downloads.length > 1) return withRebuiltPatchFiles(shaped);
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
/// **A patch with no mod id is still recorded**, unlike under the old shape,
/// which required an identity and therefore wrote nothing at all for a patch
/// dragged off a disk. The install knows exactly which files it laid down even
/// when it cannot say which mod they are, and that is enough to set the layer
/// aside on a base update and to take it back out. What it cannot do is be
/// checked for updates, which follows from the null id on its own.
ModOrigin withAppliedPatch(ModOrigin? current, ModDownload patch) {
  final base =
      current ?? const ModOrigin(provenance: OriginProvenance.importedFolder);
  return withRebuiltPatchFiles(base.withLayerOnTop(patch));
}

/// [current] with the layer naming [modId] recorded as the file the app has just
/// downloaded and written into the folder.
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
  required int modId,
  required int fileId,
  String? version,
  String? versionLabel,
  String? archiveMd5,
  List<InstalledFile>? files,
}) {
  if (current == null) return null;
  return withRebuiltPatchFiles(current.withDownload(
    modId,
    (download) => download.updatedTo(
      modId: modId,
      fileId: fileId,
      version: version,
      versionLabel: versionLabel,
      archiveMd5: archiveMd5,
      files: files,
    ),
  ));
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
