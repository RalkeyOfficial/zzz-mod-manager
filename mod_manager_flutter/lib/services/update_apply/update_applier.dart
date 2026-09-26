import 'dart:io';

import 'package:path/path.dart' as path;

import '../../core/constants.dart';
import '../../models/installed_file.dart';
import '../../models/keybind_info.dart';
import '../../models/mod_ingest.dart';
import '../../utils/directory_copy.dart';
import '../backup/snapshot_service.dart';
import '../folder_contents.dart';
import '../log/logger.dart';
import '../mod_uid.dart';
import '../patch_removal.dart';
import '../patch_store.dart';
import '../ini_parser_service.dart';
import '../ini_resources.dart';
import '../patch_detection.dart';
import '../patch_placement.dart';
import 'dropped_files.dart';
import 'keybind_changes.dart';
import 'update_layout.dart';

/// Writing a newer download over an installed mod.
///
/// **Extract to temp, sanity-check, snapshot, wipe the folder, write the new version.**
/// Everything in the folder except the sidecar is deleted before the copy, so what is left afterwards is the new version and nothing of the old one:
/// no renamed `.ini` loading beside its successor, no shader the author dropped still applied, and nothing decided about which files were whose.
/// A patch recorded on top is the one thing put back, from the snapshot, onto the new base's layout.
/// The folder itself is never moved or replaced, so its name, its active link and its `config.json` keys survive by construction,
/// and a half-finished extraction never reaches the install.
/// Deactivation is for open file handles only: the game's loader keeps them on Windows and the copy fails against them.
///
/// The decisions are all in pure units next door: [planUpdateLayout], [assessPatchShape], and for a patch layer's own update [planDroppedFiles].
/// This file does the I/O and the ordering.
/// One tag with a `phase` field, rather than a tag per phase: the five places this can fail are five stages of one operation,
/// and a reader wants them together.
final Logger _log = Logger('update.apply');

class UpdateApplier {
  UpdateApplier({
    required this.snapshots,
    required this.activation,
    this.store = const PatchStore(),
    ModUid? uids,
  }) : uids = uids ?? ModUid();

  final SnapshotService snapshots;
  final ModActivationPort activation;

  /// The mod folder's identity, which is what its snapshots are filed under.
  ///
  /// A field for the same reason [store] is: the one place that decides where a
  /// mod's history lives stays [ModUid] rather than being spelled out here. It
  /// reads and writes the folder's own sidecar and needs no config, so it is a
  /// default rather than an injected dependency.
  final ModUid uids;

  /// The mod's own files a patch wrote over, kept inside the mod folder.
  ///
  /// Not a seam for testing — it needs none, being pure filesystem work under a
  /// directory the caller already supplies — but a field so the one place that
  /// decides where displaced files live stays [PatchStore] rather than being
  /// spelled out here.
  final PatchStore store;

  final IniParserService _iniParser = IniParserService();

  /// Everything that can be known **before** anything is written.
  ///
  /// Deliberately a separate step: the user is shown a patch warning and a layout mismatch *before* consenting,
  /// and neither can be raised after the wipe has started.
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

    return UpdatePreview(
      layout: layout,
      sources: sources,
      incoming: incoming,
      // Does the *download* stand on its own? A patch-shaped one proves the
      // folder it is going into is mixed, which is the only signal available for
      // that with no recorded file list and no extra request.
      patch: assessPatchShape(
        references: incoming.references,
        files: incoming.files,
        directories: incoming.directories,
        hasIni: incoming.hasIni,
      ),
    );
  }

  /// Carries out an update the user has consented to.
  ///
  /// Order is the design: deactivate (handles), snapshot (the only way back), wipe, copy, reactivate.
  /// A failure at any step past the snapshot leaves a folder the user can roll back, which is the whole reason the snapshot is unconditional.
  Future<UpdateApplyResult> apply({
    required String modName,
    required Directory modFolder,
    required UpdatePreview preview,
    String? previousVersion,
    String? previousVersionLabel,
  }) =>
      _write(
        modName: modName,
        modFolder: modFolder,
        preview: preview,
        previousVersion: previousVersion,
        previousVersionLabel: previousVersionLabel,
        patchFiles: const <String>[],
      );

  /// Writes a new **base** into a folder that also holds a patch, in the order
  /// that makes the patch survive it: **base first, then the patch back on top.**
  ///
  /// The same operation as [apply] — deactivate, snapshot, wipe, copy, reactivate
  /// — with one step after the copy, and it is the same method underneath so the
  /// two can never come to disagree about the order.
  ///
  /// **Why the patch goes back by placement rather than by path.** The base
  /// decides where files live. A patch shipping `Body.dds` at its root, put
  /// back into a mod that keeps `Textures/Body.dds`, leaves both — and the
  /// `.ini` loads the base's. Nothing is missing, nothing errors, the folder
  /// looks complete and the patch does nothing. So the patch's files are placed
  /// back by basename (`patch_placement.dart`).
  ///
  /// **The snapshot is the aside.** The wipe takes the patch's files with
  /// everything else, and they are read back from the full copy taken before
  /// anything was touched rather than from a second temporary place that could
  /// itself be lost.
  ///
  /// [patchFiles] is the folder's recorded patch paths (`ingest.patch_files`), in
  /// on-disk spelling. Empty means nothing is known to be the patch, and this
  /// degrades to exactly [apply] — the caller is the one that has to have told the
  /// user that.
  /// [patchModId] is whose store of displaced originals to rebuild as the patch
  /// goes back — see [UpdateWriteRoute.patchModId]. Null leaves any store alone.
  Future<UpdateApplyResult> applyBaseThenPatch({
    required String modName,
    required Directory modFolder,
    required UpdatePreview preview,
    required Iterable<String> patchFiles,
    int? patchModId,
    String? previousVersion,
    String? previousVersionLabel,
  }) =>
      _write(
        modName: modName,
        modFolder: modFolder,
        preview: preview,
        previousVersion: previousVersion,
        previousVersionLabel: previousVersionLabel,
        patchFiles: patchFiles,
        patchModId: patchModId,
      );

  Future<UpdateApplyResult> _write({
    required String modName,
    required Directory modFolder,
    required UpdatePreview preview,
    required Iterable<String> patchFiles,
    int? patchModId,
    String? previousVersion,
    String? previousVersionLabel,
  }) async {
    if (!preview.layout.canProceed) {
      return UpdateApplyResult.failed(UpdateApplyFailure.layout);
    }
    if (!await modFolder.exists()) {
      return UpdateApplyResult.failed(UpdateApplyFailure.modMissing);
    }

    // **Resolved before the folder is touched at all**, because a placement that
    // cannot be settled has to stop this *now*: past the wipe below there is a
    // folder with the patch gone and nowhere to put it back. Judged against what
    // the copy lays down and nothing else, since that is all the folder will
    // hold by then.
    final recorded = patchFiles.toList();
    final placement = recorded.isEmpty
        ? PatchPlacement.nothing
        : resolvePatchPlacement(
            incoming: {for (final file in recorded) normalizeIniPath(file)},
            target: preview.incoming.files,
          );
    if (placement.needsChoice) {
      return UpdateApplyResult.failed(UpdateApplyFailure.layout);
    }

    final wasActive = await activation.isActive(modName);
    if (wasActive) await activation.deactivate(modName);

    final snapshot = await _snapshot(
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

    // Read once before the wipe: it is what names the patch's files as they are
    // spelled on disk, and what the old files are counted against afterwards.
    final before = await readFolderContents(modFolder);
    final aside = _findPatch(before, recorded);

    final written = <InstalledFile>[];
    try {
      await _wipe(modFolder);
      _log.info('cleared the folder for the new version',
          fields: {'mod': modName, 'files': before.files.length});
    } catch (e) {
      _log.error('update failed',
          error: e, fields: {'mod': modName, 'phase': 'wipe'});
      if (wasActive) await activation.activate(modName);
      return UpdateApplyResult.failed(
        UpdateApplyFailure.copy,
        snapshot: snapshot,
        error: '$e',
      );
    }
    try {
      for (final mapping in preview.layout.mappings) {
        final source = preview.sources[mapping]!;
        final target = mapping.isRoot
            ? modFolder
            : Directory(path.join(modFolder.path, mapping.targetSubPath));
        written.addAll(installedFilesUnderPrefix(
          await copyDirectory(
            Directory(source),
            target,
            skipRelative: _isSidecar,
          ),
          // Lifted to the mod root here rather than at the far end: a combined
          // install's mappings each land in their own subfolder, and a record
          // relative to one of those names a file the folder does not have.
          mapping.isRoot ? '' : mapping.targetSubPath,
        ));
      }
    } catch (e) {
      _log.error('update failed',
          error: e, fields: {'mod': modName, 'phase': 'copy'});
      if (wasActive) await activation.activate(modName);
      return UpdateApplyResult.failed(
        UpdateApplyFailure.copy,
        snapshot: snapshot,
        error: '$e',
      );
    }

    final placed = await _putPatchBack(
      modFolder: modFolder,
      snapshot: snapshot,
      aside: aside,
      placement: placement,
      patchModId: patchModId,
    );
    final reactivated = wasActive && await activation.activate(modName);

    // What the wipe took that nothing wrote again: a report, not a decision.
    // The patch's files count as kept under the path they *left*, since where
    // they came back is the new layout's business, not the old version's.
    final kept = {
      for (final file in written) normalizeIniPath(file.path),
      ...aside.taken.keys,
    };
    final droppedFiles = [
      for (final file in before.files)
        if (!kept.contains(file)) before.onDisk(file),
    ];

    return UpdateApplyResult(
      snapshot: snapshot,
      filesWritten: written.length + placed.length,
      writtenFiles: written,
      droppedFiles: droppedFiles,
      patchFiles: [for (final file in placed) file.path],
      placedPatchFiles: placed,
      missingPatchFiles: aside.missing,
      // A **diff**, computed after the copy. Reporting every keybind the mod
      // used to have is unreadable and appears whether anything moved or not;
      // reporting only what differs makes the section self-explanatory, and
      // makes it vanish in the common case where the author changed nothing.
      keybindChanges: keybindChanges(
        before: keybindsBefore,
        after: await _keybindsIn(modFolder, modName),
      ),
      reactivated: reactivated,
    );
  }

  /// Which of the recorded patch files the folder holds, spelled as they are on
  /// disk, which is where to read them back from inside the snapshot.
  ///
  /// A recorded file that is no longer there is **named, not restored** — the
  /// record says what the app wrote, and the user having deleted one since is
  /// an edit rather than damage.
  _PatchAside _findPatch(FolderContents before, List<String> patchFiles) {
    if (patchFiles.isEmpty) return const _PatchAside();
    final taken = <String, String>{};
    final missing = <String>[];
    for (final recorded in patchFiles) {
      final key = normalizeIniPath(recorded);
      if (before.files.contains(key)) {
        taken[key] = before.onDisk(key);
      } else {
        missing.add(recorded);
      }
    }
    return _PatchAside(taken: taken, missing: missing);
  }

  /// Deletes everything in the folder except the sidecar.
  ///
  /// **Nothing is decided here**, which is the point: the old version, a file
  /// the user merged in by hand and a patch the record names all go, and the
  /// snapshot taken just before is what holds them. The folder itself stays, so
  /// its name, its active link and its `config.json` keys are never in question.
  Future<void> _wipe(Directory modFolder) async {
    final entries = await modFolder.list(followLinks: false).toList();
    for (final entity in entries) {
      if (_isSidecar(path.basename(entity.path))) continue;
      await entity.delete(recursive: true);
    }
  }

  /// Copies the patch back out of the snapshot, onto the base's layout.
  ///
  /// Returns where each file now is, sized and marked, for the caller to record
  /// — the paths are frequently not the ones it started from.
  ///
  /// **The store of displaced originals is rebuilt as this runs**, and it has to
  /// be: it held the *old* base's files, and taking the patch out later must
  /// give back the version of the mod that is in the folder now. So the old
  /// store is dropped and each newly-displaced file is kept before the patch
  /// goes over it. With no [patchModId] there is no store, and nothing here
  /// changes that.
  Future<List<InstalledFile>> _putPatchBack({
    required Directory modFolder,
    required ModSnapshot snapshot,
    required _PatchAside aside,
    required PatchPlacement placement,
    int? patchModId,
  }) async {
    if (aside.taken.isEmpty) return const <InstalledFile>[];

    if (patchModId != null) {
      await store.discard(modFolder: modFolder, patchModId: patchModId);
    }

    final source = Directory(path.join(snapshot.directory.path, 'files'));
    final after = await readFolderContents(modFolder);
    final placed = <InstalledFile>[];
    for (final entry in aside.taken.entries) {
      final target = placement.mapping[entry.key] ?? entry.key;
      // A file the base does not have keeps its own path, and keeps the spelling
      // it arrived with — `onDisk` would answer the lower-cased comparison key
      // for a path the walk has never seen.
      final onDisk =
          target == entry.key ? entry.value : after.onDisk(target);
      try {
        final destination = File(path.join(modFolder.path, onDisk));
        // Asked before the copy, and it answers a real question here: the new
        // base may not ship the file this patch replaced in the old one.
        final occupied = await destination.exists();
        if (occupied && patchModId != null) {
          await store.keep(
            modFolder: modFolder,
            patchModId: patchModId,
            relativePath: onDisk,
          );
        }
        await destination.parent.create(recursive: true);
        final copied = await copyKeepingTime(
          File(path.join(source.path, entry.value)),
          destination.path,
        );
        placed.add(InstalledFile(
          path: onDisk,
          bytes: await _fileSize(copied),
          role:
              occupied ? InstalledFileRole.replaced : InstalledFileRole.added,
        ));
      } catch (e) {
        _log.error('could not put a patch file back',
            error: e, fields: {'file': onDisk, 'phase': 'place'});
      }
    }
    return placed;
  }

  /// Writes a **patch** into a mod folder that already works.
  ///
  /// The same operation as [apply] and deliberately the same order — deactivate,
  /// snapshot, copy, reactivate — because it carries the same risk: it writes
  /// over a live folder and the snapshot is the only way back. What differs is
  /// only the copy. An update replaces whole folders by layout; a patch replaces
  /// **individual files, each where the target already keeps that name**
  /// (`patch_placement.dart`), because the two downloads are by different
  /// authors and nothing makes their layouts agree.
  ///
  /// [placement] must be settled — a caller passing one that still
  /// [PatchPlacement.needsChoice] gets nothing written, since the alternative is
  /// guessing which of two variant subfolders the user runs.
  ///
  /// The **wrapper problem solves itself here**: what is copied is the contents
  /// of [source], never [source] itself, so an extraction folder invented for a
  /// rootless archive cannot end up nested inside the target — which would leave
  /// a second live `.ini` whose paths resolve beside itself.
  /// [patchModId] is the patch's own mod page, when it has one. Given, the mod's
  /// displaced files are kept under it so the patch can be taken back out later.
  /// **Null for a patch dragged off a disk**: there is no id to key a store by,
  /// nothing to check for updates, and nothing that could put it back — the
  /// write still happens and the snapshot is still the way back.
  /// [recorded] is what this same patch laid down last time, when this is an
  /// **update** to it rather than a first install. What it names and the new
  /// version does not place is taken back out: the mod's own file returns where
  /// this patch had written over one, and the patch's own additions go.
  /// [claimedAbove] is any path a layer sitting over this one records, which is
  /// not this one's to touch.
  Future<UpdateApplyResult> applyPatchInto({
    required String modName,
    required Directory modFolder,
    required Directory source,
    required FolderContents incoming,
    required FolderContents existing,
    required PatchPlacement placement,
    int? patchModId,
    List<InstalledFile> recorded = const <InstalledFile>[],
    Iterable<String> claimedAbove = const <String>[],
  }) async {
    if (placement.needsChoice) {
      return UpdateApplyResult.failed(UpdateApplyFailure.layout);
    }
    if (!await modFolder.exists()) {
      return UpdateApplyResult.failed(UpdateApplyFailure.modMissing);
    }

    final wasActive = await activation.isActive(modName);
    if (wasActive) await activation.deactivate(modName);

    final snapshot = await _snapshot(
      modName: modName,
      modFolder: modFolder,
      reason: SnapshotReason.beforeUpdate,
    );
    if (snapshot == null) {
      // No snapshot, no write — the same trade [apply] refuses to make.
      if (wasActive) await activation.activate(modName);
      return UpdateApplyResult.failed(UpdateApplyFailure.snapshot);
    }

    final keybindsBefore = await _keybindsIn(
      Directory(path.join(snapshot.directory.path, 'files')),
      modName,
    );

    final placed = <InstalledFile>[];
    try {
      for (final entry in placement.mapping.entries) {
        // Real on-disk spelling on both sides. The placement is computed over
        // normalised paths so that a case-insensitive loader's `Body.dds` and
        // `body.dds` are one file; the copy needs what is actually there.
        final from = incoming.actualPaths[entry.key] ?? entry.key;
        // **A file that replaces nothing keeps the name its author gave it.**
        // The folder has no spelling to offer for a path it does not hold, and
        // the normalised key is lower-cased — so falling back to it would write
        // `glow.dds` where the archive shipped `Glow.dds`, and record that as
        // the on-disk name every removal afterwards works from.
        final to = existing.actualPaths[entry.value] ??
            (entry.value == entry.key ? from : entry.value);
        if (_isSidecar(entry.key)) continue;

        final target = File(path.join(modFolder.path, to));
        // **Asked before the copy**, or every path reports itself occupied by
        // the file just written.
        final occupied = await target.exists();
        // Best-effort, and deliberately not gating the role below. A store that
        // could not be written loses the cheap way back, not the write: the
        // snapshot is still the recovery, and the removal asks the store what it
        // actually holds rather than trusting the record to have succeeded.
        if (occupied && patchModId != null) {
          await store.keep(
            modFolder: modFolder,
            patchModId: patchModId,
            relativePath: to,
          );
        }
        await target.parent.create(recursive: true);
        final copied = await copyKeepingTime(
          File(path.join(source.path, from)),
          target.path,
        );
        placed.add(InstalledFile(
          path: to,
          bytes: await _fileSize(copied),
          // **A fact about the write, never about the store.** `added` is what
          // licenses a delete, so it is claimed only where the path was empty —
          // a displaced file we failed to keep stays `replaced` and is reported
          // as unrecoverable instead of being deleted as if it were ours.
          role: occupied ? InstalledFileRole.replaced : InstalledFileRole.added,
        ));
      }
    } catch (e) {
      _log.error('patch write failed',
          error: e, fields: {'mod': modName, 'phase': 'copy'});
      if (wasActive) await activation.activate(modName);
      return UpdateApplyResult.failed(
        UpdateApplyFailure.copy,
        snapshot: snapshot,
        error: '$e',
      );
    }

    // **Worked out from the record and the placement, not from the folder**,
    // and after the copy for the same reason the base path does it there: a
    // write that failed part-way leaves the old version's files where they are.
    final dropped = planDroppedFiles(
      recorded: recorded,
      incoming: placement.mapping.values.toSet(),
      onDisk: existing.files,
      claimedByOthers: claimedAbove,
      // Lifted onto the folder's layout, because the patch's `.ini` names paths
      // in the *patch author's* layout and the placement is what reconciles the
      // two. Compared unmapped, this would ask about files the folder does not
      // have.
      incomingReferences: {
        for (final reference in incoming.references.paths)
          placement.mapping[reference] ?? reference,
      },
      storedOriginals:
          await _storedOriginals(modFolder, patchModId, recorded),
      keepsDisplaced: patchModId != null,
    );
    final restored = await _restoreUnderneath(
      modFolder: modFolder,
      patchModId: patchModId,
      paths: dropped.restore,
    );
    final droppedFiles = await _removeDropped(
      modFolder: modFolder,
      dropped: dropped,
      spelling: existing,
    );

    final reactivated = wasActive && await activation.activate(modName);

    return UpdateApplyResult(
      snapshot: snapshot,
      filesWritten: placed.length,
      droppedFiles: droppedFiles,
      restoredFiles: restored,
      // Where the patch now is, for the caller to record — the paths are the
      // *target's*, not the ones the archive shipped, and that is the point.
      patchFiles: [for (final file in placed) file.path],
      writtenFiles: placed,
      keybindChanges: keybindChanges(
        before: keybindsBefore,
        after: await _keybindsIn(modFolder, modName),
      ),
      reactivated: reactivated,
    );
  }

  /// **Takes a patch back out**, putting the mod's own files back under it.
  ///
  /// The same order as every other write in this file — deactivate, snapshot,
  /// change, reactivate — and for the same reason: it writes over a folder the
  /// user is using, so **no snapshot means no write**. The patch store is the
  /// cheap, permanent route back; the snapshot is what covers this operation
  /// itself going wrong halfway.
  ///
  /// [plan] is decided before this is called (`planPatchRemoval`), against the
  /// folder as it stands, so a recorded file that is gone never reaches here.
  ///
  /// **Restores run before deletes.** Both orders leave the same folder when
  /// every step works; this one is better when they do not, because a restore
  /// that fails leaves the patch's file in place — recoverable — while a delete
  /// that runs first and a restore that then fails leaves a hole.
  ///
  /// The store is dropped only once the folder no longer needs it, and the
  /// registry it belongs to is the **caller's** to rewrite: this owns the files,
  /// not the sidecar.
  Future<PatchRemovalResult> removePatch({
    required String modName,
    required Directory modFolder,
    required int patchModId,
    required PatchRemovalPlan plan,
  }) async {
    if (!await modFolder.exists()) {
      return const PatchRemovalResult(failure: UpdateApplyFailure.modMissing);
    }

    final wasActive = await activation.isActive(modName);
    if (wasActive) await activation.deactivate(modName);

    final snapshot = await _snapshot(
      modName: modName,
      modFolder: modFolder,
      reason: SnapshotReason.beforePatchRemoval,
    );
    if (snapshot == null) {
      if (wasActive) await activation.activate(modName);
      return const PatchRemovalResult(failure: UpdateApplyFailure.snapshot);
    }

    final restored = <String>[];
    final deleted = <String>[];
    final failed = <String>[];

    for (final relative in plan.restore) {
      final ok = await store.restore(
        modFolder: modFolder,
        patchModId: patchModId,
        relativePath: relative,
      );
      (ok ? restored : failed).add(relative);
    }

    for (final relative in plan.delete) {
      try {
        final file =
            File(path.joinAll([modFolder.path, ...relative.split('/')]));
        if (await file.exists()) await file.delete();
        deleted.add(relative);
      } catch (e) {
        _log.warning('could not remove a patch file',
            error: e, fields: {'file': relative, 'phase': 'remove'});
        failed.add(relative);
      }
    }

    // **Only when there is nothing left that needs it.** A file we could not put
    // back still has its original in here, and dropping the store would turn a
    // retryable failure into a permanent one.
    if (failed.isEmpty) {
      await store.discard(modFolder: modFolder, patchModId: patchModId);
    }

    final reactivated = wasActive && await activation.activate(modName);

    return PatchRemovalResult(
      snapshot: snapshot,
      restored: restored,
      deleted: deleted,
      failed: failed,
      reactivated: reactivated,
    );
  }

  /// Puts a snapshot back over the mod folder.
  ///
  /// It **snapshots first**, so a rollback is itself undoable — a user who rolls
  /// back the wrong mod, or discovers the old version was the broken one, is one
  /// click from where they were. Files the folder holds and the snapshot does not are removed after the copy,
  /// so what is left is the saved version and nothing of the newer one.
  /// The sidecar comes back with the copy, so the record matches the restored files.
  Future<UpdateApplyResult> restore({
    required String modName,
    required Directory modFolder,
    required ModSnapshot snapshot,
  }) async {
    final wasActive = await activation.isActive(modName);
    if (wasActive) await activation.deactivate(modName);

    final safety = await _snapshot(
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

    if (!await snapshots.restoreInto(snapshot, modFolder)) {
      if (wasActive) await activation.activate(modName);
      return UpdateApplyResult.failed(
        UpdateApplyFailure.copy,
        snapshot: safety,
      );
    }

    final droppedFiles = await _removeDropped(
      modFolder: modFolder,
      dropped: DroppedFiles(remove: [
        for (final file in current.files)
          if (!restoring.files.contains(file)) current.onDisk(file),
      ]),
      spelling: current,
    );

    final reactivated = wasActive && await activation.activate(modName);

    return UpdateApplyResult(
      snapshot: safety,
      filesWritten: restoring.files.length,
      droppedFiles: droppedFiles,
      keybindChanges: const [],
      reactivated: reactivated,
    );
  }

  /// Takes a snapshot, filed under the folder's **own identity** rather than
  /// its name — so a rename, in the app or in a file manager, leaves every
  /// rollback point reachable.
  ///
  /// **No identity, no snapshot, and therefore no write.** The uid is assigned
  /// here if the folder has never needed one, so the only way this returns null
  /// is a sidecar that cannot be written — a folder the copy about to follow
  /// would fail on anyway. The alternative is putting a snapshot somewhere
  /// nothing can ever find again, which is not a way back at all.
  Future<ModSnapshot?> _snapshot({
    required String modName,
    required Directory modFolder,
    required SnapshotReason reason,
    String? version,
    String? versionLabel,
  }) async {
    final uid = await uids.ensure(modFolder);
    if (uid == null) return null;
    return snapshots.capture(
      modName: modName,
      modUid: uid,
      modFolder: modFolder,
      reason: reason,
      version: version,
      versionLabel: versionLabel,
    );
  }

  /// Which of [recorded]'s paths the store really holds an original for.
  ///
  /// **Asked of the store rather than read off the record.** A `replaced` entry
  /// says the write displaced something and not that keeping it succeeded, and
  /// the difference decides between putting a file back and leaving one alone.
  Future<Set<String>> _storedOriginals(
    Directory modFolder,
    int? patchModId,
    List<InstalledFile> recorded,
  ) async {
    if (patchModId == null || recorded.isEmpty) return const <String>{};
    return {
      for (final file in recorded)
        if (await store.holds(
          modFolder: modFolder,
          patchModId: patchModId,
          relativePath: file.path,
        ))
          file.path,
    };
  }

  /// Puts the mod's own files back where a patch version that no longer wants
  /// them had written over them.
  ///
  /// **The stored copy is deliberately left in place.** The path is one this
  /// patch has stopped touching, so nothing needs it now; and if a later
  /// version reaches for it again, `PatchStore.keep` finds an original already
  /// on hand and keeps that one — which is the mod's, not the patch's.
  Future<List<String>> _restoreUnderneath({
    required Directory modFolder,
    required int? patchModId,
    required List<String> paths,
  }) async {
    if (patchModId == null || paths.isEmpty) return const <String>[];
    final restored = <String>[];
    for (final relative in paths) {
      final ok = await store.restore(
        modFolder: modFolder,
        patchModId: patchModId,
        relativePath: relative,
      );
      if (ok) {
        restored.add(relative);
      } else {
        _log.warning('could not put back what a patch had replaced',
            fields: {'file': relative, 'phase': 'restore'});
      }
    }
    return restored;
  }

  /// Deletes the files the new version no longer ships, and the directories
  /// that held nothing else.
  ///
  /// **Not offered as a choice.** A file the new version has no name for is exactly what "update this mod" means to remove,
  /// and the snapshot taken above is the way back.
  ///
  /// A path that cannot be deleted is logged and skipped: it is the old
  /// version's file, so leaving it is the state the app was already in before
  /// this existed, and failing the update over it would be worse.
  Future<List<String>> _removeDropped({
    required Directory modFolder,
    required DroppedFiles dropped,
    required FolderContents spelling,
  }) async {
    if (dropped.remove.isEmpty) return const <String>[];
    final removed = <String>[];
    final parents = <String>{};
    for (final relative in dropped.remove) {
      // The walk's spelling when it has one, and **the record's own otherwise**
      // — never `onDisk`'s fallback, which hands back the lower-cased
      // comparison key and would delete nothing on Linux while reporting a
      // file the user does not have.
      final onDisk =
          spelling.actualPaths[normalizeIniPath(relative)] ?? relative;
      final segments = onDisk.split('/');
      try {
        final file = File(path.joinAll([modFolder.path, ...segments]));
        if (!await file.exists()) continue;
        await file.delete();
        removed.add(onDisk);
        if (segments.length > 1) {
          parents.add(segments.sublist(0, segments.length - 1).join('/'));
        }
      } catch (e) {
        _log.warning('could not remove a file the new version dropped',
            error: e, fields: {'file': onDisk, 'phase': 'remove'});
      }
    }
    await _pruneEmptyParents(modFolder, parents);
    return removed;
  }

  /// Removes a directory a removal has just emptied, and its parents up to — but
  /// never including — the mod folder.
  ///
  /// The visible half of the removal: a version that dropped its whole
  /// `ShaderFixes/` otherwise leaves the folder behind, and a user looking at
  /// the mod cannot tell it is empty. **Only directories a removed file was in**,
  /// and only while they are empty, so nothing the user put there is at risk and
  /// an empty directory the app never touched is left alone.
  Future<void> _pruneEmptyParents(
    Directory modFolder,
    Set<String> parents,
  ) async {
    for (final parent in parents) {
      var segments = parent.split('/');
      while (segments.isNotEmpty) {
        final dir = Directory(path.joinAll([modFolder.path, ...segments]));
        try {
          if (!await dir.exists()) break;
          if (!await dir.list(followLinks: false).isEmpty) break;
          await dir.delete();
        } catch (e) {
          _log.debug('could not remove an emptied directory',
              fields: {'dir': segments.join('/'), 'reason': '$e'});
          break;
        }
        segments = segments.sublist(0, segments.length - 1);
      }
    }
  }

  /// Zero rather than throwing: a size that could not be read is a weaker
  /// record of a file that copied successfully, and failing the write over it
  /// would trade a working install for a missing one.
  Future<int> _fileSize(File file) async {
    try {
      return await file.length();
    } catch (_) {
      return 0;
    }
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
    this.patch = PatchAssessment.none,
  });

  final UpdateLayout layout;

  /// Each mapping's absolute source directory in the extracted archive.
  final Map<UpdateFolderMapping, String> sources;

  /// What the download would lay down, mod-folder-relative.
  final FolderContents incoming;

  final PatchAssessment patch;

  bool get canProceed => layout.canProceed;

  /// The download expects files it does not carry, so the folder it is going
  /// into holds more than one download and only part of it is being replaced.
  bool get incomingIsPatch => patch.looksLikePatch;
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

/// The patch's files, out of the folder and safe in the snapshot.
///
/// [taken] maps the comparison key to the spelling it had on disk, which is both
/// where to read it back from inside the snapshot and what to call it if the base
/// turns out not to have that file at all.
class _PatchAside {
  const _PatchAside({
    this.taken = const <String, String>{},
    this.missing = const <String>[],
  });

  final Map<String, String> taken;
  final List<String> missing;
}

class UpdateApplyResult {
  const UpdateApplyResult({
    required this.snapshot,
    required this.filesWritten,
    required this.keybindChanges,
    required this.reactivated,
    this.failure,
    this.error,
    this.writtenFiles = const <InstalledFile>[],
    this.droppedFiles = const <String>[],
    this.restoredFiles = const <String>[],
    this.placedPatchFiles = const <InstalledFile>[],
    this.patchFiles = const <String>[],
    this.missingPatchFiles = const <String>[],
  });

  factory UpdateApplyResult.failed(
    UpdateApplyFailure failure, {
    ModSnapshot? snapshot,
    String? error,
  }) =>
      UpdateApplyResult(
        snapshot: snapshot,
        filesWritten: 0,
        keybindChanges: const [],
        reactivated: false,
        failure: failure,
        error: error,
      );

  /// The snapshot taken before writing. Present even on a [UpdateApplyFailure.copy]
  /// — that is exactly when it matters.
  final ModSnapshot? snapshot;

  final int filesWritten;

  /// **What this write laid down**, mod-folder-relative and sized.
  ///
  /// The download's own files only. On [UpdateApplier.applyBaseThenPatch] that
  /// is the *base*, and the patch put back over it is [patchFiles] — two
  /// downloads, two records, which is the whole reason a folder holding both can
  /// be rebuilt at all.
  ///
  /// Empty from a build that could not report it, which is not the same as an
  /// empty folder: a caller carries the previous record forward rather than
  /// replacing it with nothing.
  final List<InstalledFile> writtenFiles;

  /// What was in the folder before and is not there now: the last version's
  /// files the new one no longer ships, and anything else the wipe took.
  ///
  /// On-disk spelling. A report of what happened, never an input to it.
  final List<String> droppedFiles;

  /// **The mod's own files, back where a patch had written over them** — paths
  /// the patch's new version has stopped touching.
  ///
  /// Only ever from a layer that keeps what it displaces. The bottom layer has
  /// nothing underneath it, so an update to it never puts anything back.
  final List<String> restoredFiles;

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

  /// Where the patch's files ended up, after [UpdateApplier.applyBaseThenPatch]
  /// placed them onto the new base's layout.
  ///
  /// **The caller records this**, because the paths are frequently not the ones
  /// it passed in — that relocation is the whole point of the operation — and a
  /// record still naming the old ones sends the next rebuild looking in the
  /// wrong place. On-disk spelling, which is what opens a file.
  final List<String> patchFiles;

  /// The same files as [patchFiles], sized and marked, for the registry that
  /// belongs to the **patch** rather than to the folder's own download.
  ///
  /// Two shapes of one answer, deliberately: the flat list is what an
  /// already-released build can still read out of `ingest.patch_files`, and this
  /// is what a removal acts on.
  final List<InstalledFile> placedPatchFiles;

  /// Recorded patch files that were not in the folder any more.
  ///
  /// Skipped rather than restored from the snapshot: the record says what the app
  /// wrote, and the user deleting one of those files afterwards is an edit, not
  /// corruption. Named so the caller can say what it could not put back.
  final List<String> missingPatchFiles;

  bool get success => failure == null;
}

/// What taking a patch out actually did.
///
/// Separate from [UpdateApplyResult] rather than another set of optional fields
/// on it: nothing here is a version, a file id or a keybind diff, and a result
/// type whose meaningful half depends on which method returned it is the kind
/// that gets read wrong.
class PatchRemovalResult {
  const PatchRemovalResult({
    this.snapshot,
    this.restored = const <String>[],
    this.deleted = const <String>[],
    this.failed = const <String>[],
    this.reactivated = false,
    this.failure,
  });

  /// Taken before anything changed. Present even on a partial failure — that is
  /// exactly when it matters.
  final ModSnapshot? snapshot;

  /// The mod's own files, back where they were.
  final List<String> restored;

  /// The patch's own files, gone.
  final List<String> deleted;

  /// Files this could not restore or could not delete. **The store is kept when
  /// this is non-empty**, so the operation can be tried again.
  final List<String> failed;

  final bool reactivated;

  /// Set when nothing was done at all. A per-file problem lands in [failed]
  /// instead: the folder did change, and the caller must not report otherwise.
  final UpdateApplyFailure? failure;

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
