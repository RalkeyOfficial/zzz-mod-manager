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

