/// **Writing down that a folder holds a patch**, which is the only half of
/// patch detection that outlives the install.
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
library;

import '../models/mod_companion.dart';
import '../models/mod_ingest.dart';
import '../models/mod_origin.dart';
import '../models/origin_enums.dart';

/// How an import amends the origin block of a mod it has just created.
///
/// A seam rather than a direct call so this file stays testable against a real
/// sidecar without a `ModManagerService` and its singletons behind it.
typedef OriginAmender = Future<bool> Function(
  String modName,
  ModOrigin? Function(ModOrigin? current) update,
);

/// [current] recorded as holding a patch, with [base] named as the mod it
/// patches when the user has said which that is.
///
/// Null in, null out: this is an **amendment**, not the write that creates an
/// origin block. Both import paths seed one for every folder they create, so a
/// null here means that seed write itself failed — and inventing a block would
/// replace a reported failure with a sidecar claiming a provenance nobody
/// observed.
///
/// The flag is set whether or not a base is named. Being told what a folder
/// patches does not make it one download.
ModOrigin? withPatchShape(ModOrigin? current, {ModCompanion? base}) {
  if (current == null) return null;
  return current.copyWith(
    ingest: (current.ingest ?? const ModIngest()).copyWith(patchShaped: true),
    // **Only ever added, never cleared.** An unanswered prompt is the user not
    // saying, which is not the same as them saying there is nothing there — and
    // this runs again on every re-import of the same folder. One base at a
    // time, though: a folder patches one mod, so a second entry would be a
    // contradiction rather than more information.
    companions: base == null
        ? current.companions
        : [
            for (final companion in current.companions)
              if (companion.role != CompanionRole.base) companion,
            base,
          ],
  );
}

/// [current] with the companion naming [modId] recorded as the file the app has
/// just downloaded and written into the folder.
///
/// The mirror of [ModOrigin.updatedTo] for the **other** download, and a separate
/// write for one reason: the folder's own identity did not change. Stamping this
/// file id onto the primary would claim the folder is that other mod.
///
/// It clears the same three things, on the same grounds:
///
/// - **`baselineRemoteDate`** — "I don't know which file, I got it around then"
///   is a weaker answer, and left beside a known file it is a second comparison
///   that can only disagree.
/// - **`updatesDismissedUntil`** — they waved an update away and have now taken
///   it. Stored as a date at or after this file's, so keeping it silences the
///   *next* release too.
/// - **`remoteMissing`** — we just fetched the page and a file off it.
///
/// **Reaches `exact`**, which is otherwise closed to a companion: every other
/// route is the user telling us about bytes they moved in themselves, and these
/// are bytes we fetched. `role` survives — which half of the folder this is has
/// not changed.
///
/// A folder with no such companion is returned unchanged: this amends, and
/// inventing the entry would record a second identity nobody named.
ModOrigin? withCompanionUpdatedTo(
  ModOrigin? current, {
  required int modId,
  required int fileId,
  String? version,
  String? versionLabel,
  String? archiveMd5,
}) {
  if (current == null) return null;
  return current.copyWith(companions: [
    for (final companion in current.companions)
      if (companion.modId != modId)
        companion
      else
        ModCompanion(
          role: companion.role,
          modId: modId,
          modIdConfidence: OriginConfidence.exact,
          fileId: fileId,
          version: version,
          versionLabel: versionLabel,
          versionConfidence: OriginConfidence.exact,
          archiveMd5: archiveMd5,
        ),
  ]);
}

/// [current] recorded as **also holding a patch** that was written into it.
///
/// The reverse ordering from [withPatchShape]: here the folder's primary is the
/// mod itself and the patch is the second thing in it, so nothing about the
/// primary changes and no `patch_shaped` flag is involved — that flag says the
/// folder *is* a patch missing its base, which is the opposite claim.
///
/// A block is created when there is none, unlike [withPatchShape]. The target is
/// an existing library mod, and most of a library that predates origin tracking
/// has no block at all — refusing to record the patch on those would make the
/// feature quietly unavailable for exactly the folders most likely to be
/// hand-assembled.
///
/// Deduplicated by **mod id, not by role**: one folder can legitimately hold two
/// different patches, and re-applying the same one must not list it twice.
ModOrigin withAppliedPatch(ModOrigin? current, ModCompanion patch) {
  final base =
      current ?? const ModOrigin(provenance: OriginProvenance.importedFolder);
  return base.copyWith(companions: [
    for (final companion in base.companions)
      if (companion.modId != patch.modId) companion,
    patch,
  ]);
}

