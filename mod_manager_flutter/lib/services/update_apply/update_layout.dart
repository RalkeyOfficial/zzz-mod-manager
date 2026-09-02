/// Where each folder of a freshly-extracted archive goes inside an **existing**
/// mod folder.
///
/// An update is not a re-run of the import path, and the difference is a rule
/// rather than an optimisation: **never re-ask the import questions.** The
/// install already asked "which of these folders, and separately or combined?"
/// and the answer was recorded in the origin block's `ingest`. Asking again for
/// every update turns a one-click action into a quiz whose right answer the app
/// already knows, and a user who answers differently the second time silently
/// restructures their own mod.
///
/// So this replays the recorded answer, and where it cannot, it **stops and
/// asks** rather than guessing. Those are the only two outcomes; there is no
/// third where it picks something plausible.
///
/// ## The unrecorded case is the common one, not the exception
///
/// `ingest` is written at install by this build and by nothing else. Every mod
/// that predates it — which on a real library is all of them, since the offline
/// backfill recovers identity and deliberately not layout — has none. That path
/// is therefore the one that matters most, and it is answered by the only
/// unambiguous shape: **exactly one top-level folder in the archive maps to the
/// mod folder itself.** Anything else is ambiguous with nothing to disambiguate
/// it, and says so.
///
/// ## A renamed upstream folder is expected, not a mismatch
///
/// The new archive's root folder is frequently named differently — `Ellen` one
/// release, `Ellen v2` the next. That is routine and must not stop an update,
/// which is why a `separate` install with one recorded folder accepts a single
/// incoming folder under any name. The mod folder keeps its own name regardless:
/// `config.json` keys active state, favourites and character tags by it.
///
/// Pure — the caller extracts the archive and lists its top-level folders.
library;

import '../../models/mod_ingest.dart';
import '../../models/origin_enums.dart';

/// Why an update cannot proceed without asking.
enum UpdateLayoutProblem {
  /// The archive expanded to no folders at all.
  nothingToInstall,

  /// Nothing was recorded about how this mod was installed, and the archive
  /// offers more than one folder — so which of them is *this* mod is a question
  /// only the user can answer.
  layoutUnknown,

  /// Something *was* recorded and the archive no longer matches it. The
  /// stronger of the two: the mod was installed as a specific arrangement of
  /// folders and the author has since changed it.
  layoutChanged,
}

/// One extracted folder and where it is written inside the mod folder.
class UpdateFolderMapping {
  const UpdateFolderMapping({required this.source, required this.targetSubPath});

  /// The top-level folder's name as it appears in the extracted archive.
  final String source;

  /// Empty for the mod folder root; otherwise the subfolder a combined install
  /// placed it in, which is the same `basename` the install used.
  final String targetSubPath;

  bool get isRoot => targetSubPath.isEmpty;

  @override
  bool operator ==(Object other) =>
      other is UpdateFolderMapping &&
      other.source == source &&
      other.targetSubPath == targetSubPath;

  @override
  int get hashCode => Object.hash(source, targetSubPath);

  @override
  String toString() =>
      '$source → ${targetSubPath.isEmpty ? '<mod root>' : targetSubPath}';
}

/// The answer: either a set of mappings, or a reason to stop.
class UpdateLayout {
  const UpdateLayout({
    this.mappings = const <UpdateFolderMapping>[],
    this.problem,
    this.unused = const <String>[],
    this.replayedIngest = false,
  });

  final List<UpdateFolderMapping> mappings;

  /// Null when the update may proceed.
  final UpdateLayoutProblem? problem;

  /// Top-level folders in the archive that are **not** part of this mod — the
  /// `previews/` folder beside the mod, or a sibling mod from the same archive
  /// that lives in its own folder in the library.
  ///
  /// Named rather than dropped: an archive that produced three mods is updated
  /// one mod at a time, and a user watching two thirds of a download go unused
  /// deserves to be told why.
  final List<String> unused;

  /// Whether a recorded `ingest` decided this, as opposed to the single-folder
  /// fallback. Drives the wording only — both are equally valid outcomes.
  final bool replayedIngest;

  bool get canProceed => problem == null && mappings.isNotEmpty;
}

/// Maps [incomingFolders] (top-level folder names from the extracted archive)
/// onto the existing mod folder, replaying [ingest] where there is one.
UpdateLayout planUpdateLayout({
  required ModIngest? ingest,
  required List<String> incomingFolders,
}) {
  if (incomingFolders.isEmpty) {
    return const UpdateLayout(problem: UpdateLayoutProblem.nothingToInstall);
  }

  final recorded = ingest?.folders ?? const <String>[];

  // Nothing recorded — the whole pre-`ingest` library. One folder is the only
  // shape that answers itself.
  if (recorded.isEmpty) {
    if (incomingFolders.length == 1) {
      return UpdateLayout(
        mappings: [
          UpdateFolderMapping(source: incomingFolders.single, targetSubPath: ''),
        ],
      );
    }
    return UpdateLayout(
      problem: UpdateLayoutProblem.layoutUnknown,
      unused: [...incomingFolders]..sort(),
    );
  }

  if (ingest!.mode == IngestMode.combined) {
    return _replayCombined(recorded, incomingFolders);
  }
  return _replaySeparate(recorded, incomingFolders);
}

/// One recorded folder that became the mod folder itself.
UpdateLayout _replaySeparate(
  List<String> recorded,
  List<String> incomingFolders,
) {
  // A `separate` install records exactly one folder per mod. More than one
  // means the sidecar was hand-edited or written by a build that meant
  // something else by it; either way it is not a shape this can replay.
  if (recorded.length != 1) {
    return UpdateLayout(
      problem: UpdateLayoutProblem.layoutChanged,
      unused: [...incomingFolders]..sort(),
      replayedIngest: true,
    );
  }

  final match = _matchFolder(recorded.single, incomingFolders);
  if (match != null) {
    return UpdateLayout(
      mappings: [UpdateFolderMapping(source: match, targetSubPath: '')],
      unused: [
        for (final folder in incomingFolders)
          if (folder != match) folder,
      ]..sort(),
      replayedIngest: true,
    );
  }

  // Renamed upstream. Routine, and unambiguous while there is only one folder
  // to pick.
  if (incomingFolders.length == 1) {
    return UpdateLayout(
      mappings: [
        UpdateFolderMapping(source: incomingFolders.single, targetSubPath: ''),
      ],
      replayedIngest: true,
    );
  }

  return UpdateLayout(
    problem: UpdateLayoutProblem.layoutChanged,
    unused: [...incomingFolders]..sort(),
    replayedIngest: true,
  );
}

/// Several recorded folders that became subfolders of one mod.
///
/// Every recorded folder must still be present. A rename cannot be absorbed
/// here the way it can for a single folder: with three subfolders and three
/// differently-named incoming ones there is no way to tell which became which,
/// and guessing writes a mod's textures over its buffers.
UpdateLayout _replayCombined(
  List<String> recorded,
  List<String> incomingFolders,
) {
  final mappings = <UpdateFolderMapping>[];
  final matched = <String>{};

  for (final folder in recorded) {
    final match = _matchFolder(folder, incomingFolders);
    if (match == null) {
      return UpdateLayout(
        problem: UpdateLayoutProblem.layoutChanged,
        unused: [...incomingFolders]..sort(),
        replayedIngest: true,
      );
    }
    matched.add(match);
    // The subfolder keeps the name the *install* gave it, not the one the new
    // archive uses: the mod's internal layout is what its `.ini` paths were
    // written against, and it is also what `importCombinedMod` created.
    mappings.add(UpdateFolderMapping(source: match, targetSubPath: folder));
  }

  return UpdateLayout(
    mappings: mappings,
    unused: [
      for (final folder in incomingFolders)
        if (!matched.contains(folder)) folder,
    ]..sort(),
    replayedIngest: true,
  );
}

/// The `ingest` record to write after an update, in the shape the *next* one
/// replays.
///
/// A combined install keeps its **recorded** subfolder names rather than the
/// archive's: the subfolder is what the mod's own `.ini` paths were written
/// against, and adopting a differently-cased incoming name would create a second
/// directory beside the first on a case-sensitive filesystem.
///
/// **Everything the update did not observe is carried across.** This is an
/// amendment, and the two facts it must not drop cannot be recovered afterwards:
/// `patch_shaped` is knowable only at install, and `patch_files` is the only
/// thing that makes a mixed folder rebuildable. Rebuilt from scratch here, an
/// ordinary update silently turned a folder the app knew held two downloads into
/// one it thinks holds one.
///
/// [patchFiles] replaces the recorded list when the update moved the patch —
/// which `applyBaseThenPatch` does by design, so a record still naming the old
/// paths would send the next rebuild looking in the wrong place.
///
/// The **file manifest is not here**: it belongs to the layer that wrote it
/// (`ModDownload.files`), and only `patch_files` — the derived flat list an
/// older build can still read — lives on `ingest`.
ModIngest? ingestAfterUpdate(
  UpdateLayout layout,
  ModIngest? current, {
  List<String>? patchFiles,
}) {
  final carried = patchFiles == null
      ? current
      : (current ?? const ModIngest()).copyWith(patchFiles: patchFiles);
  if (layout.mappings.isEmpty) return carried;
  if (carried?.mode == IngestMode.combined) return carried;
  return (carried ?? const ModIngest()).copyWith(
    mode: IngestMode.separate,
    folders: [layout.mappings.single.source],
  );
}

/// Case-insensitive, because an archive repacked on another machine routinely
/// changes only the case of a folder name.
String? _matchFolder(String wanted, List<String> candidates) {
  final key = wanted.toLowerCase();
  for (final candidate in candidates) {
    if (candidate.toLowerCase() == key) return candidate;
  }
  return null;
}
