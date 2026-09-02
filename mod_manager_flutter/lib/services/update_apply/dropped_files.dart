/// **What the version being replaced put in the folder that the new one no
/// longer ships**, decided before anything is written.
///
/// An overwrite only ever *adds* and *replaces*. A file the last version shipped
/// under a name the new one does not use is therefore left exactly where it was,
/// and it keeps working: the loader reads every `.ini` in the folder and every
/// asset those reference, so a renamed `.ini` doubles the mod's hotkeys and a
/// shader the author dropped goes on being applied. `stale_ini.dart` catches the
/// `.ini` half by inference — is this file describing the content we just
/// wrote? — and cannot see anything else.
///
/// This does not infer. Each download records the files it laid down
/// ([InstalledFile]), so the answer is a set difference: recorded last time,
/// not shipped this time. What that buys over the inference is the case the
/// inference has no signal for at all — an asset no `.ini` in the folder
/// mentions any more.
///
/// Pure, the shape `retention.dart` and `patch_removal.dart` use: the part worth
/// testing is which file gets which treatment, and that needs no folder.
library;

import '../../models/installed_file.dart';
import '../ini_resources.dart';

/// One recorded file's fate, once the new version has landed.
class DroppedFiles {
  const DroppedFiles({
    this.remove = const <String>[],
    this.restore = const <String>[],
    this.gone = const <String>[],
    this.claimed = const <String>[],
    this.stillNeeded = const <String>[],
    this.unrecoverable = const <String>[],
  });

  static const DroppedFiles nothing = DroppedFiles();

  /// This download put them here, nothing else claims them, and the new version
  /// has no file by that name. They go.
  ///
  /// On-disk spelling — these paths delete files, and a lower-cased one deletes
  /// nothing on Linux.
  final List<String> remove;

  /// Written over something, and that something is on hand: the file underneath
  /// comes back instead of the path being emptied.
  ///
  /// Only a layer that kept what it displaced has any of these — see
  /// [planDroppedFiles]'s `keepsDisplaced`.
  final List<String> restore;

  /// Recorded, and no longer in the folder.
  ///
  /// **Skipped, never acted on.** The record says what the app wrote, so the
  /// user having deleted one since is an edit rather than damage — the same rule
  /// `ingest.patch_files` and `planPatchRemoval` already read by.
  final List<String> gone;

  /// A download **above** this one in the folder records the same path, so the
  /// file sitting there now is its, not the old version's.
  ///
  /// The ordinary mixed folder: a patch replaced one of the mod's files, and the
  /// mod's next version stops shipping it. Deleting it would take the patch's
  /// file, which is the destruction the whole overwrite mechanism exists to
  /// avoid.
  final List<String> claimed;

  /// **The new version's own `.ini` points at this path and the archive does
  /// not carry the file**, so the file already there is what will satisfy it.
  ///
  /// Real, and not rare: an author who replaced only one component ships a
  /// fraction of what their own `.ini` references (`stale_ini.dart` measured 8
  /// of 36 on one mod). Removing this file would take a working mod and break
  /// it on the update that was supposed to improve it — the one outcome worse
  /// than a leftover, so the leftover wins.
  final List<String> stillNeeded;

  /// Written over something the app failed to keep a copy of, so there is
  /// nothing to put back and the file stays.
  ///
  /// Deleting it would leave a hole where the file underneath used to be;
  /// leaving it keeps a file no download claims any more, which is the
  /// recoverable half of a bad choice.
  final List<String> unrecoverable;

  bool get isEmpty =>
      remove.isEmpty &&
      restore.isEmpty &&
      gone.isEmpty &&
      claimed.isEmpty &&
      stillNeeded.isEmpty &&
      unrecoverable.isEmpty;

  /// Whether performing this would change the folder at all.
  bool get touchesFiles => remove.isNotEmpty || restore.isNotEmpty;

  /// How many files the folder loses, which is what the user is told.
  int get changedCount => remove.length + restore.length;
}

/// What the folder is left holding from [recorded] once [incoming] is written.
///
/// [recorded] is the file list of **the download being replaced** — the same
/// layer the new archive is going into, never the folder as a whole. [incoming]
/// is every path the new version lays down, and [onDisk] the folder as it stands
/// now; both normalised, because the loader is case-insensitive and a record
/// written on Windows may not agree with the folder's spelling.
///
/// [claimedByOthers] is every path recorded by a download that sits **over**
/// this one. A mixed folder's layers overwrite each other by design, so a path
/// in two records belongs to the upper one and this must not touch it. Only
/// upward: a layer *under* this one records the same path precisely because
/// this download wrote over it, and treating that as a claim would make every
/// displacement untouchable.
///
/// [incomingReferences] is every path the new version's own `.ini` files point
/// at. A recorded file it still names and the archive does not carry is kept:
/// the mod is about to ask the loader for it.
///
/// [storedOriginals] is what a store actually holds an original for, asked of
/// the store rather than read off the record: a `replaced` entry says the write
/// displaced something and **not** that keeping it succeeded.
///
/// [keepsDisplaced] says whether this download is one that keeps what it writes
/// over. A patch layer does; the bottom layer has nothing underneath it to
/// keep, so for it a `replaced` entry means *the previous version of itself* —
/// which is exactly what an update is replacing, and deleting it is the whole
/// point. Getting this backwards is the one dangerous mistake available here,
/// which is why it is a named parameter rather than inferred from an empty
/// store: an empty store is also what a failed keep leaves.
///
/// A layer with no store and a `replaced` entry does not arise: a patch is
/// written into an empty folder as `added` throughout, and the roles only
/// become `replaced` when a base is put underneath it — which is the operation
/// that builds the store.
///
/// Returns [DroppedFiles.nothing] for a download with no file record: a folder
/// installed before the record existed has no way to tell its files from
/// anything else's, and guessing would delete the mod.
DroppedFiles planDroppedFiles({
  required List<InstalledFile> recorded,
  required Set<String> incoming,
  required Set<String> onDisk,
  Iterable<String> claimedByOthers = const <String>[],
  Set<String> incomingReferences = const <String>{},
  Set<String> storedOriginals = const <String>{},
  bool keepsDisplaced = false,
}) {
  if (recorded.isEmpty) return DroppedFiles.nothing;

  final claimed = <String>[];
  final remove = <String>[];
  final restore = <String>[];
  final gone = <String>[];
  final stillNeeded = <String>[];
  final unrecoverable = <String>[];
  final others = {for (final path in claimedByOthers) normalizeIniPath(path)};

  for (final file in recorded) {
    final key = normalizeIniPath(file.path);
    // The ordinary overwrite. The new version has this file, so the copy
    // replaces it and there is nothing to decide.
    if (incoming.contains(key)) continue;

    // **Before the on-disk test**, because a claimed path is a file that is
    // there and is somebody else's — reporting it as "gone" would be true of
    // the old version's copy and misleading about the folder.
    if (others.contains(key)) {
      claimed.add(file.path);
      continue;
    }
    if (!onDisk.contains(key)) {
      gone.add(file.path);
      continue;
    }
    // The new version names the path and did not bring the file, so what is
    // there is what it gets. Ahead of the store, because a mod that loads is
    // worth more than a tidy one.
    if (incomingReferences.contains(key)) {
      stillNeeded.add(file.path);
      continue;
    }
    if (storedOriginals.contains(file.path)) {
      restore.add(file.path);
      continue;
    }
    if (keepsDisplaced && file.role == InstalledFileRole.replaced) {
      unrecoverable.add(file.path);
      continue;
    }
    remove.add(file.path);
  }

  return DroppedFiles(
    remove: remove,
    restore: restore,
    gone: gone,
    claimed: claimed,
    stillNeeded: stillNeeded,
    unrecoverable: unrecoverable,
  );
}
