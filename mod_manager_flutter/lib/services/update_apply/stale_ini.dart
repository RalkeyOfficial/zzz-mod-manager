/// Which `.ini` files an overwrite leaves behind that will now fight the ones
/// it just wrote.
///
/// The loader reads **every** `.ini` in a mod folder. So when an update renames
/// its own `.ini` — `ellen.ini` becomes `ellen_v2.ini` — the overwrite writes
/// the new one and the old one simply stays, and the two are live at once:
/// duplicate hotkeys, two sets of overrides on the same hashes, and a user who
/// reports that "the update broke my mod".
///
/// Unused *non*-`.ini` leftovers are not a problem worth solving: the loader
/// only touches what an `.ini` references, so an orphaned texture is wasted
/// space and nothing else.
///
/// ## The rule, and the correction it embodies
///
/// The obvious rule — *any `.ini` we did not just write is a leftover* — is
/// wrong here, and wrong in the one direction this whole update path exists to
/// avoid. A mod folder frequently holds two downloads: a patch applied into it,
/// or two mods a user merged by hand. Under that rule, updating one of them
/// offers to delete the other one's `.ini`, which is the same destruction the
/// overwrite mechanism was chosen to prevent. (`services/update_apply` refuses
/// to clear `.ini` files wholesale for exactly this reason; a prompt that
/// defaults to delete is the same act with a dialog in front of it.)
///
/// So the test is not "did we write this file" but **"does this file describe
/// the content we just wrote"**:
///
/// > A leftover `.ini` is stale when every resource it names **and the folder
/// > actually has** is a file the incoming download ships.
///
/// An upstream rename satisfies that by construction — the renamed `.ini` is a
/// full replacement for the old one, so it references the same resources. A
/// hand-merged second mod does not: it names *its own* files, which the incoming
/// download knows nothing about. A patch `.ini` shares the mod's filename and is
/// therefore overwritten rather than orphaned, so it never reaches here at all.
///
/// **"And the folder actually has" is load-bearing, not a guard.** A ZZZ
/// character is several components and the extraction tools emit an `.ini`
/// covering all of them, so an author who replaced only the wings ships a
/// fraction of what their own `.ini` references — measured at 8 of 36 on one
/// real mod. Comparing against the *whole* reference list would find those 28
/// never-present files missing from the incoming download too, conclude "not
/// stale", and quietly stop offering to remove the file it was written for.
/// Restricting to references the folder satisfies today asks the question that
/// was always meant: *is this `.ini` describing the content we just wrote?*
///
/// An `.ini` naming nothing checkable is **kept without asking**. "We could not
/// tell" is not "it is safe to delete", and the cost of keeping one is a
/// duplicate the user can still remove by hand, against the cost of deleting one
/// which is somebody's merged mod.
///
/// Pure — the caller supplies both sides.
library;

import '../ini_resources.dart';

/// One `.ini` the overwrite would orphan, and why.
class StaleIni {
  const StaleIni({required this.path, required this.sharedResources});

  /// Mod-folder-relative, in [normalizeIniPath] spelling.
  ///
  /// **Comparison only.** It is lower-cased, so handing it to `File` or showing
  /// it to a user names something that may not exist — see
  /// `FolderContents.actualPaths` for the real spelling.
  final String path;

  /// How many of its references the incoming download supplies — the references
  /// it names **that the folder actually holds**, which is the restriction the
  /// note above establishes as the rule rather than a guard. Carried so the
  /// prompt can say *how* it decided rather than only that it did.
  final int sharedResources;
}

/// The leftovers worth offering to delete, and the ones deliberately left alone.
class StaleIniAssessment {
  const StaleIniAssessment({
    this.stale = const <StaleIni>[],
    this.keptUndecidable = const <String>[],
  });

  static const StaleIniAssessment none = StaleIniAssessment();

  /// Safe to delete: each describes exactly the content just written.
  final List<StaleIni> stale;

  /// Orphaned `.ini` files that reference something the incoming download does
  /// **not** ship, or reference nothing checkable at all. Not offered for
  /// deletion — they are the merged-second-mod case, or unreadable.
  ///
  /// Surfaced rather than silent: a folder that gains an `.ini` nobody can
  /// account for is worth one sentence, and it is the signal that the folder is
  /// mixed.
  final List<String> keptUndecidable;

  bool get isEmpty => stale.isEmpty && keptUndecidable.isEmpty;
}

/// Decides which of the folder's existing `.ini` files the write orphans.
///
/// [existingReferences] and [existingFiles] describe the folder **as it is
/// now**; [incomingInis] / [incomingFiles] are every path the write is about to
/// lay down. All of them are relative to the mod folder root, so a combined
/// install's subfolder prefixes are already applied.
StaleIniAssessment assessStaleInis({
  required IniReferences existingReferences,
  required Set<String> existingInis,
  required Set<String> existingFiles,
  required Set<String> incomingInis,
  required Set<String> incomingFiles,
}) {
  final stale = <StaleIni>[];
  final kept = <String>[];

  for (final rawPath in existingInis) {
    final iniPath = normalizeIniPath(rawPath);
    // Overwritten by the incoming write — it is the *same* file, not a leftover.
    if (incomingInis.contains(iniPath)) continue;

    // Only the references this `.ini` can actually resolve today. See the note
    // at the top: a template `.ini` names several components' worth of files
    // that the mod never shipped, and those say nothing about what it describes.
    final references = existingReferences
        .pathsFrom(iniPath)
        .where(existingFiles.contains)
        .toSet();
    if (references.isEmpty) {
      kept.add(iniPath);
      continue;
    }
    if (references.every(incomingFiles.contains)) {
      stale.add(StaleIni(path: iniPath, sharedResources: references.length));
    } else {
      kept.add(iniPath);
    }
  }

  stale.sort((a, b) => a.path.compareTo(b.path));
  kept.sort();
  return StaleIniAssessment(stale: stale, keptUndecidable: kept);
}
