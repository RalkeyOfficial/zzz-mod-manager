import 'dart:io';

import 'package:path/path.dart' as path;

import '../../core/constants.dart';
import '../../models/keybind_info.dart';
import '../../models/mod_ingest.dart';
import '../../utils/directory_copy.dart';
import '../backup/snapshot_service.dart';
import '../folder_contents.dart';
import '../ini_parser_service.dart';
import '../patch_detection.dart';
import 'keybind_changes.dart';
import 'stale_ini.dart';
import 'update_layout.dart';

/// Writing a newer download over an installed mod.
///
/// **The mechanism is overwrite — extract to temp, sanity-check, then copy over
/// the live folder.** Never empty it, never move it, never delete it.
/// Everything else here follows from that one decision, so the reasoning comes
/// first.
///
/// A mod folder is often **mixed**: it holds files from two downloads, because a
/// patch mod was applied into it. Patches replace rather than add — a patch
/// `.ini` carries the same filename as the mod's own and takes its place, and a
/// patch asset likewise overwrites one of the mod's files — so a mixed folder
/// looks completely ordinary from outside: one `.ini`, every referenced file
/// present, nothing extra.
///
/// Replacing such a folder destroys the other download, and the common case is
/// worse than losing a fix. The ordering that produces it is routine: a page
/// looks like a normal mod, so it gets installed; the game shows nothing; the
/// user reads the page properly, finds it is a patch, and drags the base mod's
/// files in around it. The app now knows that folder as **the patch**. Replace
/// it and what is left is a lone `.ini` with nothing to apply to — the mod is
/// gone, not merely unfixed. Overwrite in the same situation copies the new
/// patch file over the old one and touches nothing else, which is exactly right.
///
/// Three properties fall out of it for free, each of which the rejected
/// swap-the-folder design needed machinery for:
///
/// - **The active link survives by construction.** Moving the folder would
///   dangle `saveModsPath/<name>`, which the next scan prunes — silently
///   switching the mod off. Nothing moves here, so nothing dangles.
/// - **The folder name never changes**, so `config.json`'s `active_mods`,
///   `favorite_mods` and `mod_character_tags` keys stay valid even though the
///   new archive's root folder is frequently named differently.
/// - **A half-finished extraction never touches the install**, because the
///   extraction happens into a temp directory and only the final copy reaches
///   the mod folder.
///
/// Deactivation is still performed, but for **open file handles only** — the
/// game's loader keeps them on Windows and the copy fails against them — never
/// for link integrity.
///
/// The decisions are all in pure units next door: [planUpdateLayout],
/// [assessPatchShape], [assessStaleInis]. This file does the I/O and the
/// ordering.
class UpdateApplier {
  UpdateApplier({required this.snapshots, required this.activation});

  final SnapshotService snapshots;
  final ModActivationPort activation;

  final IniParserService _iniParser = IniParserService();

  /// Everything that can be known **before** anything is written.
  ///
  /// Deliberately a separate step: the user is shown a patch warning, a
  /// stale-`.ini` question and a layout mismatch *before* consenting, and none
  /// of those can be raised after the copy has started.
  Future<UpdatePreview> preview({
    required Directory modFolder,
    required List<String> incomingFolders,
    ModIngest? ingest,
  }) async {
    final byName = {
      for (final folder in incomingFolders) path.basename(folder): folder,
    };
    final layout = planUpdateLayout(
      ingest: ingest,
      incomingFolders: byName.keys.toList(),
    );
    if (!layout.canProceed) {
      return UpdatePreview(layout: layout, sources: const {});
    }

    // What the download would lay down, expressed relative to the **mod folder
    // root** — so a combined install's subfolder prefixes are applied once,
    // here, and every rule downstream compares like with like.
    var incoming = FolderContents.empty;
    final sources = <UpdateFolderMapping, String>{};
    for (final mapping in layout.mappings) {
      final source = byName[mapping.source]!;
      sources[mapping] = source;
      final contents = await readFolderContents(Directory(source));
      incoming = incoming.merge(contents.underPrefix(mapping.targetSubPath));
    }

    final existing = await readFolderContents(modFolder);

    return UpdatePreview(
      layout: layout,
      sources: sources,
      incoming: incoming,
      existing: existing,
      // Does the *download* stand on its own? A patch-shaped one proves the
      // folder it is going into is mixed, which is the only signal available for
      // that with no recorded file list and no extra request.
      patch: assessPatchShape(
        references: incoming.references,
        files: incoming.files,
        directories: incoming.directories,
        hasIni: incoming.hasIni,
      ),
      staleInis: assessStaleInis(
        existingReferences: existing.references,
        existingInis: existing.iniPaths,
        existingFiles: existing.files,
        incomingInis: incoming.iniPaths,
        incomingFiles: incoming.files,
      ),
    );
  }

  /// Carries out an update the user has consented to.
  ///
  /// Order is the design: deactivate (handles), snapshot (the only way back),
  /// copy, resolve leftovers, reactivate. A failure at any step past the
  /// snapshot leaves a folder the user can roll back, which is the whole reason
  /// the snapshot is unconditional.
  Future<UpdateApplyResult> apply({
    required String modName,
    required Directory modFolder,
    required UpdatePreview preview,
    required bool deleteStaleInis,
    String? previousVersion,
    String? previousVersionLabel,
  }) async {
    if (!preview.layout.canProceed) {
      return UpdateApplyResult.failed(UpdateApplyFailure.layout);
    }
    if (!await modFolder.exists()) {
      return UpdateApplyResult.failed(UpdateApplyFailure.modMissing);
    }

    final wasActive = await activation.isActive(modName);
    if (wasActive) await activation.deactivate(modName);

    final snapshot = await snapshots.capture(
      modName: modName,
      modFolder: modFolder,
      reason: SnapshotReason.beforeUpdate,
      version: previousVersion,
      versionLabel: previousVersionLabel,
    );
    if (snapshot == null) {
      // No snapshot, no write. There is no other way back from an overwrite, so
      // proceeding here would trade a recoverable failure for an unrecoverable
      // one.
      if (wasActive) await activation.activate(modName);
      return UpdateApplyResult.failed(UpdateApplyFailure.snapshot);
    }

    // Read *before* the copy: after it, the folder's keybinds are the new
    // version's. This is the whole of what survived the rejected "re-apply the
    // user's .ini edits" idea — a read-only record of what the keys were, with
    // no matching, no conflict logic and no write path.
    final keybindsBefore = await _keybindsIn(
      Directory(path.join(snapshot.directory.path, 'files')),
      modName,
    );

    var written = 0;
    try {
      for (final mapping in preview.layout.mappings) {
        final source = preview.sources[mapping]!;
        final target = mapping.isRoot
            ? modFolder
            : Directory(path.join(modFolder.path, mapping.targetSubPath));
        written += await copyDirectory(
          Directory(source),
          target,
          skipRelative: _isSidecar,
        );
      }
    } catch (e) {
      print('UpdateApplier: copy failed for $modName: $e');
      if (wasActive) await activation.activate(modName);
      return UpdateApplyResult.failed(
        UpdateApplyFailure.copy,
        snapshot: snapshot,
        error: '$e',
      );
    }

    final deleted = await _removeStale(
      enabled: deleteStaleInis,
      modFolder: modFolder,
      stale: preview.staleInis.stale,
      spelling: preview.existing,
    );

    if (wasActive) await activation.activate(modName);

    return UpdateApplyResult(
      snapshot: snapshot,
      filesWritten: written,
      removedInis: deleted,
      // A **diff**, computed after the copy. Reporting every keybind the mod
      // used to have is unreadable and appears whether anything moved or not;
      // reporting only what differs makes the section self-explanatory, and
      // makes it vanish in the common case where the author changed nothing.
      keybindChanges: keybindChanges(
        before: keybindsBefore,
        after: await _keybindsIn(modFolder, modName),
      ),
      reactivated: wasActive,
    );
  }

  /// Puts a snapshot back over the mod folder.
  ///
  /// It **snapshots first**, so a rollback is itself undoable — a user who rolls
  /// back the wrong mod, or discovers the old version was the broken one, is one
  /// click from where they were. The leftovers are resolved with the same
  /// stale-`.ini` rule the update uses, in the opposite direction: an `.ini` the
  /// newer version added, whose every resource the snapshot also carries, is the
  /// renamed successor of a restored file and would fight it.
  Future<UpdateApplyResult> restore({
    required String modName,
    required Directory modFolder,
    required ModSnapshot snapshot,
    bool deleteStaleInis = true,
  }) async {
    final wasActive = await activation.isActive(modName);
    if (wasActive) await activation.deactivate(modName);

    final safety = await snapshots.capture(
      modName: modName,
      modFolder: modFolder,
      reason: SnapshotReason.beforeRestore,
    );
    if (safety == null) {
      if (wasActive) await activation.activate(modName);
      return UpdateApplyResult.failed(UpdateApplyFailure.snapshot);
    }

    final restoring = await readFolderContents(
      Directory(path.join(snapshot.directory.path, 'files')),
    );
    final current = await readFolderContents(modFolder);
    final stale = assessStaleInis(
      existingReferences: current.references,
      existingInis: current.iniPaths,
      existingFiles: current.files,
      incomingInis: restoring.iniPaths,
      incomingFiles: restoring.files,
    );

    if (!await snapshots.restoreInto(snapshot, modFolder)) {
      if (wasActive) await activation.activate(modName);
      return UpdateApplyResult.failed(
        UpdateApplyFailure.copy,
        snapshot: safety,
      );
    }

    final deleted = await _removeStale(
      enabled: deleteStaleInis,
      modFolder: modFolder,
      stale: stale.stale,
      spelling: current,
    );

    if (wasActive) await activation.activate(modName);

    return UpdateApplyResult(
      snapshot: safety,
      filesWritten: restoring.files.length,
      removedInis: deleted,
      keybindChanges: const [],
      reactivated: wasActive,
    );
  }

  /// Deletes the orphaned `.ini` files the user agreed to, **by their real
  /// name**.
  ///
  /// One copy for both directions, and it exists because getting this wrong is
  /// silent. `StaleIni.path` is normalised — lower-cased, because 3DMigoto is
  /// case-insensitive and the comparison has to be — and handing that to `File`
  /// opens nothing on Linux when the author shipped `Ellen.ini`. `exists()`
  /// answered false, the loop reported nothing removed, no error was raised,
  /// and the folder kept the two live `.ini` files this whole rule exists to
  /// prevent. [spelling] is the walk that produced those paths, so it is the
  /// one thing that knows how they are really written.
  ///
  /// The **reported** names are the real ones too: a summary naming a file the
  /// user does not have is its own small lie.
  Future<List<String>> _removeStale({
    required bool enabled,
    required Directory modFolder,
    required List<StaleIni> stale,
    required FolderContents spelling,
  }) async {
    if (!enabled) return const [];
    final deleted = <String>[];
    for (final entry in stale) {
      final onDisk = spelling.onDisk(entry.path);
      final file = File(
        path.joinAll([modFolder.path, ...onDisk.split('/')]),
      );
      try {
        if (await file.exists()) {
          await file.delete();
          deleted.add(onDisk);
        }
      } catch (e) {
        print('UpdateApplier: could not remove $onDisk: $e');
      }
    }
    return deleted;
  }

  Future<List<KeybindInfo>> _keybindsIn(Directory dir, String modName) async {
    try {
      final parsed = await _iniParser.parseCharacterDirectory(modName, dir.path);
      return parsed?.keybinds ?? const [];
    } catch (_) {
      return const [];
    }
  }
}

/// `.zzz-mod-manager/` is **ours, and the archive's copy of it is a stranger's.**
///
/// The sidecar holds the description, the user's imported gallery, the tags and
/// the origin block that decides which mod page this mod is checked against. A
/// download can legitimately carry one the moment anybody shares a folder they
/// managed with this app, so an unfiltered copy silently swaps a user's metadata
/// for someone else's. The *install* path handles the same hazard differently —
/// it keeps a stranger's description and images on purpose and replaces only
/// their origin block — but there is nothing here we want from the archive, so
/// this excludes rather than merges.
bool _isSidecar(String relativePath) {
  final dir = AppConstants.modMetadataDirName.toLowerCase();
  final normalized = relativePath.toLowerCase();
  return normalized == dir || normalized.startsWith('$dir/');
}

/// Everything the update flow can tell the user before it writes anything.
class UpdatePreview {
  const UpdatePreview({
    required this.layout,
    required this.sources,
    this.incoming = FolderContents.empty,
    this.existing = FolderContents.empty,
    this.patch = PatchAssessment.none,
    this.staleInis = StaleIniAssessment.none,
  });

  final UpdateLayout layout;

  /// Each mapping's absolute source directory in the extracted archive.
  final Map<UpdateFolderMapping, String> sources;

  /// What the download would lay down, mod-folder-relative.
  final FolderContents incoming;

  /// The mod folder as it is now.
  final FolderContents existing;

  final PatchAssessment patch;
  final StaleIniAssessment staleInis;

  bool get canProceed => layout.canProceed;

  /// The download expects files it does not carry, so the folder it is going
  /// into holds more than one download and only part of it is being replaced.
  bool get incomingIsPatch => patch.looksLikePatch;

  /// A normalised path as it is really spelled in the mod folder.
  ///
  /// Anything shown to a user or handed to `File` goes through here. The
  /// normalised form is for comparing only — `ellen.ini` names no file the user
  /// has when the author shipped `Ellen.ini`.
  String onDisk(String normalised) => existing.onDisk(normalised);
}

enum UpdateApplyFailure {
  /// The archive's layout could not be reconciled with the install.
  layout,

  /// The mod folder is gone.
  modMissing,

  /// The snapshot could not be taken, so nothing was written.
  snapshot,

  /// The copy itself failed part-way. The snapshot is the recovery.
  copy,
}

class UpdateApplyResult {
  const UpdateApplyResult({
    required this.snapshot,
    required this.filesWritten,
    required this.removedInis,
    required this.keybindChanges,
    required this.reactivated,
    this.failure,
    this.error,
  });

  factory UpdateApplyResult.failed(
    UpdateApplyFailure failure, {
    ModSnapshot? snapshot,
    String? error,
  }) =>
      UpdateApplyResult(
        snapshot: snapshot,
        filesWritten: 0,
        removedInis: const [],
        keybindChanges: const [],
        reactivated: false,
        failure: failure,
        error: error,
      );

  /// The snapshot taken before writing. Present even on a [UpdateApplyFailure.copy]
  /// — that is exactly when it matters.
  final ModSnapshot? snapshot;

  final int filesWritten;
  final List<String> removedInis;

  /// The keys this update moved or removed — **empty when it moved none**.
  ///
  /// Read-only and reported once. A shipped `.ini` that reverts a rebound key is
  /// accepted loss: re-applying it was considered and rejected, because there is
  /// no pristine baseline to diff the author's changes against and a wrong guess
  /// writes a broken `.ini` into the folder. Naming what moved costs two parses
  /// and no write path at all. See `keybind_changes.dart`.
  final List<KeybindChange> keybindChanges;

  final bool reactivated;
  final UpdateApplyFailure? failure;
  final String? error;

  bool get success => failure == null;
}

/// The activation half of `ModManagerService`, narrowed to what an update needs.
///
/// A seam rather than a direct call, for the reason every other dialog-facing
/// seam in this app exists: `ApiService` lazily builds a `ConfigService` against
/// the developer's **real** `<appData>/config.json`, so a test that exercised
/// this applier would rewrite their library paths and active-mod list.
abstract class ModActivationPort {
  Future<bool> isActive(String modName);
  Future<bool> activate(String modName);
  Future<bool> deactivate(String modName);
}
