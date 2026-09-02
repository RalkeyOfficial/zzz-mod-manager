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
import '../patch_removal.dart';
import '../patch_store.dart';
import '../ini_parser_service.dart';
import '../ini_resources.dart';
import '../patch_detection.dart';
import '../patch_placement.dart';
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
/// One tag with a `phase` field, rather than a tag per phase: the five places
/// this can fail are five stages of one operation, and a reader wants them
/// together.
final Logger _log = Logger('update.apply');

class UpdateApplier {
  UpdateApplier({
    required this.snapshots,
    required this.activation,
    this.store = const PatchStore(),
  });

  final SnapshotService snapshots;
  final ModActivationPort activation;

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
  /// Deliberately a separate step: the user is shown a patch warning, a
  /// stale-`.ini` question and a layout mismatch *before* consenting, and none
  /// of those can be raised after the copy has started.
  Future<UpdatePreview> preview({
    required Directory modFolder,
    required List<String> incomingFolders,
    ModIngest? ingest,

    /// Files in [modFolder] to judge this update **as if they were not there** —
    /// the other download in a mixed folder.
    ///
    /// Without it the patch's own `.ini` is assessed as a leftover of the base's
    /// update and offered for deletion, which reads as "the update renamed this"
    /// and deletes the patch if accepted. See [applyBaseThenPatch], which puts
    /// those files back on top once the base has landed.
    Iterable<String> excluding = const <String>[],
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

    final existing = (await readFolderContents(modFolder)).without(excluding);

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
  }) =>
      _write(
        modName: modName,
        modFolder: modFolder,
        preview: preview,
        deleteStaleInis: deleteStaleInis,
        previousVersion: previousVersion,
        previousVersionLabel: previousVersionLabel,
        patchFiles: const <String>[],
      );

  /// Writes a new **base** into a folder that also holds a patch, in the order
  /// that makes the patch survive it: **base first, then the patch back on top.**
  ///
  /// The same operation as [apply] — deactivate, snapshot, copy, reactivate — with
  /// two steps around the copy, and it is the same method underneath so the two
  /// can never come to disagree about the order.
  ///
  /// **Why the patch has to move rather than be left alone.** The base decides
  /// where files live. A patch shipping `Body.dds` at its root, written into a mod
  /// that keeps `Textures/Body.dds`, leaves both — and the `.ini` loads the
  /// base's. Nothing is missing, nothing errors, the folder looks complete and the
  /// patch does nothing. So the patch's files are taken out, the base is written,
  /// and they are placed back by basename (`patch_placement.dart`).
  ///
  /// **The snapshot is the aside.** It is a full copy of the folder taken before
  /// anything is written, so the patch's bytes are read back from there rather
  /// than copied to a second temporary place that could itself be lost.
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
    required bool deleteStaleInis,
    required Iterable<String> patchFiles,
    int? patchModId,
    String? previousVersion,
    String? previousVersionLabel,
  }) =>
      _write(
        modName: modName,
        modFolder: modFolder,
        preview: preview,
        deleteStaleInis: deleteStaleInis,
        previousVersion: previousVersion,
        previousVersionLabel: previousVersionLabel,
        patchFiles: patchFiles,
        patchModId: patchModId,
      );

  Future<UpdateApplyResult> _write({
    required String modName,
    required Directory modFolder,
    required UpdatePreview preview,
    required bool deleteStaleInis,
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
    // cannot be settled has to stop this *now*: past the deletion below there is
    // a folder with the patch taken out and nowhere to put it back.
    final recorded = patchFiles.toList();
    final placement = recorded.isEmpty
        ? PatchPlacement.nothing
        : _placementFor(preview: preview, patchFiles: recorded);
    if (placement.needsChoice) {
      return UpdateApplyResult.failed(UpdateApplyFailure.layout);
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

    // Taken out before the base is written, which is what makes that write an
    // ordinary update: the folder then holds only the old base, and every rule
    // downstream compares like with like. The bytes are in the snapshot.
    final aside = await _takePatchAside(modFolder, recorded);

    final written = <InstalledFile>[];
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

    // **Before the patch goes back**, deliberately. The stale list names `.ini`
    // files the *base* renamed, and the patch's own `.ini` was taken out above —
    // so nothing here can reach it. Run the other way round, a patch that had
    // replaced the base's `.ini` would be placed back and then deleted as the
    // predecessor of the file that replaced it.
    final deleted = await _removeStale(
      enabled: deleteStaleInis,
      modFolder: modFolder,
      stale: preview.staleInis.stale,
      spelling: preview.existing,
    );

    final placed = await _putPatchBack(
      modFolder: modFolder,
      snapshot: snapshot,
      aside: aside,
      placement: placement,
      patchModId: patchModId,
    );
    if (wasActive) await activation.activate(modName);

    return UpdateApplyResult(
      snapshot: snapshot,
      filesWritten: written.length + placed.length,
      writtenFiles: written,
      removedInis: deleted,
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
      reactivated: wasActive,
    );
  }

  /// Where the recorded patch files will land **once the base has been written**.
  ///
  /// Computed against the folder the copy is about to produce — what is there now
  /// minus the patch, plus what the base lays down — rather than against the
  /// folder as it stands. That is what lets an unsettleable placement stop the
  /// operation before anything is deleted.
  PatchPlacement _placementFor({
    required UpdatePreview preview,
    required List<String> patchFiles,
  }) {
    final patch = {for (final file in patchFiles) normalizeIniPath(file)};
    return resolvePatchPlacement(
      incoming: patch,
      target: {
        for (final file in preview.existing.files)
          if (!patch.contains(file)) file,
        ...preview.incoming.files,
      },
    );
  }

  /// Removes the recorded patch files from the folder, reporting what was there.
  ///
  /// Safe because the snapshot above is a full copy: these bytes are read back
  /// from it. A recorded file that is no longer there is **named, not restored** —
  /// the record says what the app wrote, and the user having deleted one since is
  /// an edit rather than damage.
  Future<_PatchAside> _takePatchAside(
    Directory modFolder,
    List<String> patchFiles,
  ) async {
    if (patchFiles.isEmpty) return const _PatchAside();

    final before = await readFolderContents(modFolder);
    final taken = <String, String>{};
    final missing = <String>[];
    for (final recorded in patchFiles) {
      final key = normalizeIniPath(recorded);
      if (!before.files.contains(key)) {
        missing.add(recorded);
        continue;
      }
      // The spelling on disk, not the spelling in the record — they agree today
      // and a mismatch would silently delete nothing and leave a second copy.
      final onDisk = before.onDisk(key);
      taken[key] = onDisk;
      try {
        await File(path.join(modFolder.path, onDisk)).delete();
      } catch (e) {
        _log.warning('could not set a patch file aside',
            error: e, fields: {'file': onDisk, 'phase': 'aside'});
      }
    }
    return _PatchAside(taken: taken, missing: missing);
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
        final copied =
            await File(path.join(source.path, entry.value)).copy(
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
  Future<UpdateApplyResult> applyPatchInto({
    required String modName,
    required Directory modFolder,
    required Directory source,
    required FolderContents incoming,
    required FolderContents existing,
    required PatchPlacement placement,
    int? patchModId,
  }) async {
    if (placement.needsChoice) {
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
        final to = existing.actualPaths[entry.value] ?? entry.value;
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
        final copied = await File(path.join(source.path, from)).copy(
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

    if (wasActive) await activation.activate(modName);

    return UpdateApplyResult(
      snapshot: snapshot,
      filesWritten: placed.length,
      // Where the patch now is, for the caller to record — the paths are the
      // *target's*, not the ones the archive shipped, and that is the point.
      patchFiles: [for (final file in placed) file.path],
      writtenFiles: placed,
      // Nothing is removed on this path. The stale-`.ini` rule looks for an
      // `.ini` whose every resource the incoming download also carries — the
      // renamed predecessor of an update — and a patch by definition carries
      // less than the mod it patches, so the rule has nothing true to say here.
      removedInis: const <String>[],
      keybindChanges: keybindChanges(
        before: keybindsBefore,
        after: await _keybindsIn(modFolder, modName),
      ),
      reactivated: wasActive,
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

    final snapshot = await snapshots.capture(
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

    if (wasActive) await activation.activate(modName);

    return PatchRemovalResult(
      snapshot: snapshot,
      restored: restored,
      deleted: deleted,
      failed: failed,
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
        _log.warning('could not remove a stale file',
            error: e, fields: {'file': onDisk, 'phase': 'remove'});
      }
    }
    return deleted;
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
    required this.removedInis,
    required this.keybindChanges,
    required this.reactivated,
    this.failure,
    this.error,
    this.writtenFiles = const <InstalledFile>[],
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
