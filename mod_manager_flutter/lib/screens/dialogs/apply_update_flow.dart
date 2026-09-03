import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;

import '../../l10n/app_localizations.dart';
import '../../models/character_info.dart';
import '../../models/gamebanana/gamebanana.dart';
import '../../models/installed_file.dart';
import '../../models/mod_origin.dart';
import '../../models/origin_enums.dart';
import '../../services/api_service.dart';
import '../../services/archive_service.dart';
import '../../services/backup/snapshot_service.dart';
import '../../services/folder_contents.dart';
import '../../services/log/confirmations.dart';
import '../../services/log/logger.dart';
import '../../services/patch_placement.dart';
import '../../services/patch_record.dart';
import '../../services/update_apply/mod_activation_port.dart';
import '../../services/update_apply/sibling_group.dart';
import '../../services/update_apply/update_applier.dart';
import '../../services/update_apply/update_layout.dart';
import '../../services/update_apply/update_target.dart';
import '../../utils/gamebanana_url.dart';
import '../../utils/notifications.dart';
import '../../utils/state_providers.dart';
import '../components/extract_failure_message.dart';
import 'download_with_progress.dart';
import 'update_confirm_dialog.dart';
import 'update_progress_dialog.dart';
import 'update_result_dialog.dart';

/// Downloading a newer file and writing it over an installed mod, end to end.
///
/// The orchestration lives at the widget layer because it is a *conversation* —
/// download, then show what is about to happen, then write only if the user
/// agrees. The decisions it is built on are all in
/// `services/update_apply/`, which knows nothing about dialogs.
///
/// The order is the safety argument, and each step exists to make the next one
/// refusable:
///
/// 1. **Download to `<appData>/downloads`.** Cancellable; nothing local has
///    changed yet.
/// 2. **Extract to a temp directory and sanity-check it.** A failed or
///    half-finished extraction never touches the installed mod, which is the
///    crash-safety property the rejected swap-the-folder design needed a swap
///    for.
/// 3. **Preview.** Patch shape, orphaned `.ini` files, and whether the archive's
///    layout still matches how this mod was installed — every question that can
///    only be asked before the copy.
/// 4. **Ask.** Including the one thing the user must be told rather than
///    discover: keybinds they rebound inside the folder will be reverted by a
///    shipped `.ini`, and the snapshot is the way back.
/// 5. **Apply**, then record what the folder now is.
///
/// **It writes one of the folder's two halves.** A mixed folder holds a base mod
/// and a patch over it, and the rule is the same whichever of them is the
/// folder's own recorded identity: *base first, then patch*. So a write that
/// replaces the **base** takes the patch out, writes the base, and places the
/// patch back on top ([patchFiles]); a write that replaces the **patch** is a
/// placement onto the base's layout and goes through
/// `UpdateApplier.applyPatchInto` instead of this.
///
/// Returns true when the mod folder changed, so the caller rescans.
Future<bool> applyUpdateFlow(
  BuildContext context,
  WidgetRef ref, {
  required ModInfo mod,
  required int remoteModId,
  required GbFile file,

  /// The folder's recorded patch files (`ingest.patch_files`), when this write
  /// replaces the **base** of a folder that also holds a patch. They are set
  /// aside, the base is written, and they are placed back onto its layout.
  ///
  /// Empty means nothing is known to be the patch — either an ordinary
  /// single-download mod, or a mixed folder from before the record existed. The
  /// second is an ordinary overwrite of whatever is in there, and the **caller**
  /// is the one that has to have said so.
  Iterable<String> patchFiles = const <String>[],

  /// Whose store of displaced originals to rebuild as that patch goes back —
  /// see `UpdateWriteRoute.patchModId`. Null leaves any store alone.
  int? patchModId,

  /// True when [remoteModId] is a **companion** of this folder — the mod its
  /// patch applies to — rather than the folder's own identity. Decides which
  /// record the installed file is written against; writing a companion's file
  /// id onto the primary would claim this folder is that other mod.
  bool asCompanion = false,

  /// Whether to ask before writing. False only where the user has just answered
  /// the same question in a modal, which is the one case where confirming again
  /// is asking twice rather than asking.
  bool confirm = true,

  /// This folder holds a patch that **cannot be put back**, because nothing
  /// records which files are its. Stated on the confirmation, where it is the
  /// one loss not already paid for by a rule.
  bool flattensPatch = false,

  /// **Every file the check found newer than what this mod holds**, so a
  /// sibling's own recorded file can be placed against [file].
  ///
  /// Without it the group can only ask "is it on this exact file?", which reads
  /// a member that has since been updated *past* this one as needing it — and
  /// writes it back a version. See `sibling_group.dart`. Empty is safe and
  /// degrades to that older question, so the callers with no check in hand
  /// (a repair, a patch install) lose nothing they had.
  List<GbFile> published = const <GbFile>[],

  /// Whether this is a **repair** — the version already installed, written over
  /// the folder again ([reinstallFlow]).
  ///
  /// Wording only: the operation is identical, and the two screens have to say
  /// which one the user asked for. "Update Ellen?" in front of a reinstall
  /// reads as an offer of something newer.
  bool reinstall = false,
}) async {
  final loc = context.loc;
  final notify = context.notify;

  // `mod` is captured before every await, so its character is safe to read on
  // any path below — including the catch blocks.
  void fail(String title, String body) =>
      notify.error(title, body: body, characterId: mod.characterId);

  final config = await ApiService.getConfig();
  final modsPath = config['mods_path'] ?? '';
  if (modsPath.isEmpty) {
    fail(
      loc.t('marketplace.install_missing_path_title'),
      loc.t('marketplace.install_missing_path_body'),
    );
    return false;
  }
  final modFolder = Directory(path.join(modsPath, mod.id));
  if (!await modFolder.exists()) {
    fail(
      loc.t('mods.update_apply.mod_missing_title'),
      loc.t('mods.update_apply.mod_missing', params: {'mod': mod.name}),
    );
    return false;
  }

  if (!context.mounted) return false;
  final download = await downloadFileWithProgress(
    context,
    ref,
    file,
    characterId: mod.characterId,
    subject: mod.name,
  );
  if (download == null) return false;

  var archiveConsumed = false;
  Directory? extractRoot;
  try {
    final extraction = await ArchiveService.extractArchive(
      archiveFile: download.file,
      knownMd5: download.md5,
    );
    if (!extraction.success) {
      // The archive is kept on purpose: the user can still extract it by hand,
      // and saying where it is turns a dead end into a workaround.
      final lines = extractFailureMessage(
        loc,
        archivePath: download.file.path,
        reason: extraction.failure ?? ExtractFailure.other,
      );
      fail(lines.title, lines.body);
      return false;
    }
    archiveConsumed = true;

    final folders = extraction.extractedFolders ?? const <String>[];
    if (folders.isEmpty) {
      fail(
        loc.t('marketplace.install_empty_title'),
        loc.t('marketplace.install_empty_body'),
      );
      return false;
    }
    extractRoot = Directory(folders.first).parent;

    final mods = await ApiService.getModManagerService();
    // Read once, before anything is written: retention is a disk operation and
    // has to run even if the widget that owns `ref` has gone by then.
    final snapshots = ref.read(snapshotServiceProvider);
    final applier = UpdateApplier(
      snapshots: snapshots,
      activation: ModManagerActivationPort(mods),
    );

    final preview = await applier.preview(
      modFolder: modFolder,
      incomingFolders: folders,
      ingest: mod.origin?.ingest,
      // The patch belongs to neither side of the base's update: it is going back
      // on top afterwards. Left in, its own `.ini` is assessed as a leftover the
      // base renamed and offered for deletion, which deletes the patch.
      excluding: patchFiles,
      // **The bottom layer's record**, because that is the layer this writes.
      // What it names is removed where the new version has no file by that name,
      // which is how a renamed `.ini` or a dropped shader stops being loaded
      // instead of lingering. Empty for a mod installed before the record
      // existed — see `dropped_files.dart`.
      recorded: mod.origin?.base?.files ?? const <InstalledFile>[],
    );

    final primary = UpdateTarget(
      mod: mod,
      preview: preview,
      patchFiles: patchFiles.toList(),
      patchModId: patchModId,
      flattensPatch: flattensPatch,
    );

    // **The archive's other mods, previewed against the same extraction.**
    // Refused outright for a repair (the user asked about one folder) and for a
    // companion write (a patch layer is not a folder this archive produced).
    final group = confirm && !reinstall && !asCompanion
        ? await _previewSiblings(
            applier: applier,
            mod: mod,
            modsPath: modsPath,
            remoteModId: remoteModId,
            file: file,
            published: published,
            folders: folders,
          )
        : const _SiblingPreviews();

    if (!context.mounted) return false;
    final choice = confirm
        ? await showUpdateConfirmDialog(
            context,
            mod: mod,
            file: file,
            preview: preview,
            flattensPatch: flattensPatch,
            reinstall: reinstall,
            siblings: group.targets,
            // Carries the primary's own refusal when the group contested its
            // folder — the dialog reads the row's state off this list, so there
            // is no second field to forget.
            refused: group.refused,
            otherFolders: group.otherFolders,
          )
        : const UpdateConfirmChoice(removeStaleInis: true);
    if (confirm) {
      // **What the consent covered, keyed on what was accepted rather than on
      // how many.** Unticking the mod the dialog was opened on is coherent, and
      // a log naming only that mod would describe a folder nothing wrote.
      final accepted = choice?.accepted ?? const <String>{};
      final also = accepted.where((id) => id != mod.id).toList();
      logConfirmation('update.apply',
          accepted: choice != null,
          subject: mod.id,
          fields: {
            'from': mod.origin?.base?.version,
            'to': file.version ?? file.description,
            'file_id': file.idRow,
            'flattens_patch': flattensPatch,
            if (reinstall) 'reinstall': true,
            if (choice != null) 'remove_stale_inis': choice.removeStaleInis,
            if (also.isNotEmpty) 'also': also,
            if (accepted.isNotEmpty && !accepted.contains(mod.id))
              'subject_skipped': true,
          });
    }
    if (choice == null) return false;

    // Empty when the confirmation was skipped, which is the one path that has
    // no group: `installNamedBase` answered this question in its own prompt.
    final chosen = choice.accepted.isEmpty
        ? [primary]
        : [
            for (final target in [primary, ...group.targets])
              if (choice.accepted.contains(target.mod.id)) target,
          ];
    if (chosen.isEmpty) return false;

    // **The modal is optional and the write is not.** The user has consented,
    // so the copy happens whether or not there is still a context to draw
    // progress on — a dead context costs the progress bar and nothing else.
    final progress = _GroupProgress(chosen.length);
    if (chosen.length > 1 && context.mounted) progress.attach(context);

    final applied = await _writeAll(
      progress: progress,
      applier: applier,
      snapshots: snapshots,
      // **The one thing the loop needs `ref` for**, handed in as a callback so
      // the write itself holds none: `WidgetRef` throws once its widget is
      // disposed, and a throw between the copy and `_recordOrigin` would leave
      // a folder holding new files under a record naming the old version.
      onSnapshotTaken: () {
        if (!context.mounted) return;
        ref.invalidate(modBackupsProvider);
      },
      targets: chosen,
      modsPath: modsPath,
      remoteModId: remoteModId,
      file: file,
      archiveMd5: extraction.archiveMd5 ?? download.md5,
      deleteStaleInis: choice.removeStaleInis,
      asCompanion: asCompanion,
      primary: primary,
    );

    final outcome = summariseGroupWrite(applied, reinstall: reinstall);

    if (context.mounted) {
      ref.invalidate(modBackupsProvider);
      ref.invalidate(installedModsIndexProvider);

      // **Only what this write settled may lose its mark**, which is neither
      // "all the targets" nor "all but the one the dialog was opened on". A
      // folder the user unticked still has its update to take, one whose write
      // failed needs its mark more than before, and a repair takes nothing —
      // see `summariseGroupWrite`.
      final notifier = ref.read(modUpdateChecksProvider.notifier);
      notifier.state = {...notifier.state}
        ..removeWhere((id, _) => outcome.settledMarks.contains(id));
    }

    // **One folder reports its failure as a notification, several report it in
    // the dialog.** With one mod the split is not the information and the
    // dialog would only repeat what the notification says; with several, which
    // ones landed *is* the report, and three notifications would bury it.
    if (outcome.soleFailure case final only?) {
      if (!context.mounted) return only.result.snapshot != null;
      // **The folder that was written, not the one the dialog was opened on.**
      // With the primary unticked the sole attempt is a sibling, and naming the
      // wrong mod sends the user to restore something never touched.
      final lines = _failureMessage(loc, only.result, only.mod);
      notify.error(lines.title,
          body: lines.body, characterId: only.mod.characterId);
      // A failed *copy* still moved files. Anything else left the folder alone.
      return only.result.failure == UpdateApplyFailure.copy;
    }

    final changed = outcome.changed;

    if (!context.mounted) return changed;
    await showUpdateResultDialog(
      context,
      mod: applied.first.mod,
      file: file,
      result: applied.first.result,
      reinstall: reinstall,
      others: applied.skip(1).toList(),
    );
    return changed;
  } catch (e) {
    if (context.mounted) {
      fail(loc.t('mods.update_apply.failed_title'), '$e');
    }
    return false;
  } finally {
    await _cleanupExtract(extractRoot);
    if (archiveConsumed) await _deleteArchive(download.file);
  }
}

/// Downloading a newer file of the **patch** in a mixed folder and placing it
/// over the base that is in there with it.
///
/// The other half of [applyUpdateFlow], and a separate function because the copy
/// is a different one: **layout belongs to the base, and the patch is placed.**
/// The two downloads are by different authors and nothing makes their layouts
/// agree, so replaying the folder's recorded layout for a patch archive writes
/// its files *beside* the ones they should replace — where the `.ini` still loads
/// the base's, nothing errors, and the update appears to have done nothing.
///
/// Everything else is the same and shared: the cancellable download, the
/// snapshot, and the record written against whichever identity this was.
Future<bool> applyPatchUpdateFlow(
  BuildContext context,
  WidgetRef ref, {
  required ModInfo mod,
  required int remoteModId,
  required GbFile file,
  bool asCompanion = false,
}) async {
  final loc = context.loc;
  final notify = context.notify;
  void fail(String title, String body) =>
      notify.error(title, body: body, characterId: mod.characterId);

  final config = await ApiService.getConfig();
  final modsPath = config['mods_path'] ?? '';
  final modFolder = Directory(path.join(modsPath, mod.id));
  if (modsPath.isEmpty || !await modFolder.exists()) {
    fail(
      loc.t('mods.update_apply.mod_missing_title'),
      loc.t('mods.update_apply.mod_missing', params: {'mod': mod.name}),
    );
    return false;
  }

  if (!context.mounted) return false;
  final download = await downloadFileWithProgress(
    context,
    ref,
    file,
    characterId: mod.characterId,
    subject: mod.name,
  );
  if (download == null) return false;

  var archiveConsumed = false;
  Directory? extractRoot;
  try {
    final extraction = await ArchiveService.extractArchive(
      archiveFile: download.file,
      knownMd5: download.md5,
    );
    if (!extraction.success) {
      final lines = extractFailureMessage(
        loc,
        archivePath: download.file.path,
        reason: extraction.failure ?? ExtractFailure.other,
      );
      fail(lines.title, lines.body);
      return false;
    }
    archiveConsumed = true;

    final folders = extraction.extractedFolders ?? const <String>[];
    if (folders.isEmpty) {
      fail(
        loc.t('marketplace.install_empty_title'),
        loc.t('marketplace.install_empty_body'),
      );
      return false;
    }
    extractRoot = Directory(folders.first).parent;

    // One folder's contents, never the folder itself — an extraction wrapper
    // invented for a rootless archive must not end up nested inside the target.
    final source = Directory(folders.first);
    final incoming = await readFolderContents(source);
    final existing = await readFolderContents(modFolder);
    final placement = resolvePatchPlacement(
      incoming: incoming.files,
      target: existing.files,
    );

    final mods = await ApiService.getModManagerService();
    final snapshots = ref.read(snapshotServiceProvider);
    final applier = UpdateApplier(
      snapshots: snapshots,
      activation: ModManagerActivationPort(mods),
    );
    final result = await applier.applyPatchInto(
      modName: mod.id,
      modFolder: modFolder,
      source: source,
      incoming: incoming,
      existing: existing,
      placement: placement,
      // **Only where a removal flow can reach it.** A `patch` companion is the
      // one shape that can be taken back out, so it is the one that needs the
      // mod's displaced files kept. A folder that *is* the patch has no such
      // operation — stripping it leaves a block naming a mod the folder does
      // not hold — so nothing is stored under it.
      patchModId: asCompanion ? remoteModId : null,
      // **This layer's own last version**, so what it no longer places is taken
      // back out: the mod's file returns where this patch had written over one,
      // and the patch's own additions go.
      recorded: mod.origin?.downloadOf(remoteModId)?.files ??
          const <InstalledFile>[],
      // A folder can hold two patches, and the one above this has overwritten
      // some of its files in turn — those paths are not this layer's to touch.
      claimedAbove: _recordedAbove(mod.origin, remoteModId),
    );
    if (result.snapshot != null) {
      ref.invalidate(modBackupsProvider);
      // **Whenever one was taken, not only on a write that landed.** The
      // snapshot comes before the copy, so a placement that failed part-way
      // still added a whole folder to the budget — see §5 of
      // `docs/applying-updates.md`.
      await snapshots.prune();
    }

    if (!result.success) {
      if (!context.mounted) return result.snapshot != null;
      final lines = _failureMessage(loc, result, mod);
      fail(lines.title, lines.body);
      return result.failure == UpdateApplyFailure.copy;
    }

    // **One write for whichever layer this was**, which is what the stack
    // bought: the two shapes a mixed folder comes in used to need two branches
    // here, and they were doing the same thing to a different record.
    //
    // `ingest` is deliberately *not* refreshed from this archive's layout: the
    // folder's shape belongs to its bottom layer, and this archive's folder
    // names describe a patch. `patch_files` is re-derived from the layers by
    // `withDownloadUpdatedTo`, so it follows the files recorded just below.
    await ApiService.updateModOrigin(mod.id, (current) {
      if (current == null) return null;
      final updated = withDownloadUpdatedTo(
        current,
        modId: remoteModId,
        fileId: file.idRow,
        version: file.version,
        versionLabel: file.description,
        archiveMd5: extraction.archiveMd5 ?? download.md5,
        // This version's files, replacing the last one's — the paths move
        // whenever the two authors' layouts differ.
        files: result.writtenFiles,
      );
      if (updated == null) return null;
      // The **folder's** facts only when what the folder *is* was written. A
      // patch arriving on top does not re-date the folder or re-describe how it
      // got here.
      if (current.base?.modId != remoteModId) return updated;
      return updated.copyWith(
        source: gameBananaSource,
        provenance: OriginProvenance.downloaded,
        installedAt: DateTime.now(),
      );
    });

    // Pruning already ran with the snapshot, above.
    ref.invalidate(modBackupsProvider);
    ref.invalidate(installedModsIndexProvider);

    if (!context.mounted) return true;
    await showUpdateResultDialog(context, mod: mod, file: file, result: result);
    return true;
  } catch (e) {
    if (context.mounted) {
      fail(loc.t('mods.update_apply.failed_title'), '$e');
    }
    return false;
  } finally {
    await _cleanupExtract(extractRoot);
    if (archiveConsumed) await _deleteArchive(download.file);
  }
}

/// The archive's other mods, previewed and split into offered and refused.
class _SiblingPreviews {
  const _SiblingPreviews({
    this.targets = const <UpdateTarget>[],
    this.refused = const <SiblingRefused>[],
    this.otherFolders = const <String>[],
  });

  final List<UpdateTarget> targets;

  /// Includes the **primary** when the group contested its folder. That is the
  /// only channel the confirmation has for it, deliberately: a second field
  /// carrying the same fact is a field a caller can forget, and forgetting it
  /// writes a folder the group refused.
  final List<SiblingRefused> refused;

  final List<String> otherFolders;
}

/// Finds the mods this archive also installed, and previews the write into each.
///
/// **The library is read here, when the question is asked**, rather than off a
/// provider: the Mods tab owns `charactersProvider` and is disposed while the
/// marketplace is open, so a cached list is as old as the last visit — and a mod
/// installed since would be missing from a group it belongs to. See
/// `test/modal_freshness_test.dart`.
///
/// **Nothing is read at all for a mod with no group**, which is every mod in a
/// backfilled library: the check is one field already in hand.
Future<_SiblingPreviews> _previewSiblings({
  required UpdateApplier applier,
  required ModInfo mod,
  required String modsPath,
  required int remoteModId,
  required GbFile file,
  required List<GbFile> published,
  required List<String> folders,
}) async {
  if (mod.origin?.ingest?.siblingGroup == null) return const _SiblingPreviews();

  final List<ModInfo> library;
  try {
    library = await ApiService.getMods();
  } catch (e) {
    // The group is an addition to a write that works without it, so a failed
    // scan costs the user the offer and nothing else.
    Logger('update').warning('could not read the library for a sibling group',
        error: e, fields: {'mod': mod.id});
    return const _SiblingPreviews();
  }

  final plan = planSiblingUpdates(
    primary: mod,
    library: library,
    subjectModId: remoteModId,
    target: file,
    published: published,
    incomingFolders: [for (final folder in folders) path.basename(folder)],
  );

  final targets = <UpdateTarget>[];
  for (final sibling in plan.targets) {
    final folder = Directory(path.join(modsPath, sibling.mod.id));
    // Gone between the scan and here, or renamed by the user mid-flow. Silently
    // dropped rather than refused with a reason: there is no folder left to name
    // one about.
    if (!await folder.exists()) continue;
    targets.add(UpdateTarget(
      mod: sibling.mod,
      preview: await applier.preview(
        modFolder: folder,
        incomingFolders: folders,
        ingest: sibling.mod.origin?.ingest,
        excluding: sibling.route.patchFiles,
        recorded: sibling.mod.origin?.base?.files ?? const <InstalledFile>[],
      ),
      patchFiles: sibling.route.patchFiles,
      patchModId: sibling.route.patchModId,
      flattensPatch: sibling.route.flattensPatch,
      caution: sibling.caution,
    ));
  }

  return _SiblingPreviews(
    targets: targets,
    refused: [
      // The primary first when it is the refused one, since it is the mod the
      // user was asking about.
      if (plan.primaryRefused case final reason?)
        SiblingRefused(mod: mod, reason: reason),
      ...plan.refused,
    ],
    otherFolders: plan.otherFolders,
  );
}

/// The progress modal for a group write, and nothing at all for a single one.
///
/// Separated from the write so the write never depends on a live context: the
/// user has already consented by the time this exists, and a context that died
/// in between must cost the progress bar rather than the copy.
class _GroupProgress {
  _GroupProgress(this.total);

  final int total;
  final ValueNotifier<GroupWriteProgress> _value =
      ValueNotifier(const GroupWriteProgress(modName: '', index: 1, total: 1));
  NavigatorState? _navigator;

  /// Puts the modal up. Called only where the context is known to be mounted,
  /// and only for more than one folder: a single write takes a second and has
  /// nothing to report, where several take that long each and a blank screen
  /// reads as the app having forgotten the request.
  void attach(BuildContext context) {
    _navigator = Navigator.of(context, rootNavigator: true);
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => UpdateProgressDialog(progress: _value),
    ));
  }

  void step(String modName, int index) {
    _value.value =
        GroupWriteProgress(modName: modName, index: index, total: total);
  }

  void close() {
    _navigator?.pop();
    _navigator = null;
    _value.dispose();
  }
}

/// Writes the download into every folder the user left ticked.
///
/// **Sequential, and a failure does not stop the rest.** Each folder is its own
/// mod with its own snapshot and its own copy, so one that fails leaves the
/// others correctly updated — and stopping would waste the download the whole
/// feature exists to share. Every outcome comes back so the result dialog can
/// say which folders landed.
///
/// **It holds no `WidgetRef`**, which is what makes the write independent of the
/// widget that started it. `WidgetRef` throws once its widget is disposed, and a
/// throw between the copy and the record would leave a folder holding the new
/// version's files under a sidecar still naming the old one — the record an
/// update replays from, so that folder would silently drop to "layout unknown"
/// and its next dropped-file pass would compare against the wrong manifest.
///
/// **Retention runs per folder rather than once at the end.** Three members of a
/// large archive add three whole-folder snapshots against a 5 GB budget and the
/// tail of an archive is 1.24 GB, so pruning between them keeps the budget
/// honest during the run instead of reporting an overage after it. Each folder's
/// own new snapshot is the one retention never prunes, so this cannot delete
/// what it just took.
Future<List<AppliedUpdate>> _writeAll({
  required _GroupProgress progress,
  required UpdateApplier applier,
  required SnapshotService snapshots,

  /// Called after a folder's snapshot exists, so the rollback menu can be
  /// re-read. A callback rather than a `ref` for the reason above.
  required void Function() onSnapshotTaken,
  required List<UpdateTarget> targets,
  required String modsPath,
  required int remoteModId,
  required GbFile file,
  required String? archiveMd5,
  required bool deleteStaleInis,
  required bool asCompanion,
  required UpdateTarget primary,
}) async {
  final applied = <AppliedUpdate>[];
  try {
    for (var i = 0; i < targets.length; i++) {
      final target = targets[i];
      progress.step(target.mod.name, i + 1);

      final result = await applier.applyBaseThenPatch(
        modName: target.mod.id,
        modFolder: Directory(path.join(modsPath, target.mod.id)),
        preview: target.preview,
        deleteStaleInis: deleteStaleInis,
        patchFiles: target.patchFiles,
        patchModId: target.patchModId,
        previousVersion: target.mod.origin?.base?.version,
        previousVersionLabel: target.mod.origin?.base?.versionLabel,
      );
      applied.add(AppliedUpdate(mod: target.mod, result: result));

      // **Before the success check, deliberately.** A snapshot exists the
      // moment `apply` got past its snapshot step, and the *failure* path is
      // where it matters most: a copy that broke halfway leaves the folder
      // half-old and half-new, and the error message sends the user straight to
      // "Restore a previous version…". That entry is drawn from this provider's
      // cached set, so a mod being updated for the first time was not in it —
      // the one moment the rollback is needed was the one moment it was missing
      // from the menu.
      if (result.snapshot != null) {
        onSnapshotTaken();
        // **Whenever one was taken, not only on a write that landed.** The
        // snapshot comes before the copy, so a copy that failed part-way still
        // added a whole folder to the budget — and a retry against a nearly
        // full disk is exactly when retention is load-bearing.
        await snapshots.prune();
      }
      if (!result.success) continue;

      await _recordOrigin(
        mod: target.mod,
        remoteModId: remoteModId,
        file: file,
        archiveMd5: archiveMd5,
        layout: target.preview.layout,
        // **Only ever the mod the user opened.** A sibling's write is that
        // folder's own bottom layer by definition — the group refuses any
        // member whose stack says otherwise.
        asCompanion: asCompanion && target.mod.id == primary.mod.id,
        // Where the patch is *now*. `applyBaseThenPatch` moves it onto the new
        // base's layout by design, so recording the paths it started from would
        // send the next rebuild looking in the wrong place.
        patchFiles: target.patchFiles.isEmpty ? null : result.patchFiles,
        // **Only when this write was the folder's own download.** With
        // `asCompanion` the files that moved belong to the *other* one, and
        // stamping them onto `ingest` would credit the folder's own record with
        // a patch's file list.
        files: result.writtenFiles,
        placedPatchFiles: result.placedPatchFiles,
      );
    }
  } finally {
    progress.close();
  }
  return applied;
}

/// Every path recorded by a layer sitting **over** [modId] in this folder.
///
/// What a write to [modId] must not remove: the layers above it overwrote some
/// of its files by design, so the file at such a path is theirs. Upward only —
/// a layer *under* it records the same path precisely because this one wrote
/// over it, and reading that as a claim would make every displacement
/// untouchable.
List<String> _recordedAbove(ModOrigin? origin, int modId) {
  if (origin == null) return const <String>[];
  final index = origin.indexOf(modId);
  if (index < 0) return const <String>[];
  return [
    for (final layer in origin.downloads.skip(index + 1))
      for (final file in layer.files) file.path,
  ];
}

/// Writes what the folder now is.
///
/// Both confidences reach `exact` here on the same grounds a marketplace
/// install does — the user picked this row of this mod's file list and we wrote
/// exactly that file id — and the clearing rules live in [ModOrigin.updatedTo]
/// and [ModDownload.updatedTo] rather than here.
///
/// **Against the identity that was actually written.** A folder can hold two
/// downloads, and stamping a companion's file id onto the primary would claim the
/// folder is that other mod.
///
/// The `ingest` record is refreshed from what actually happened, which is a real
/// gain for the pre-`ingest` library: a mod that had no layout on record now has
/// one, so its *next* update replays instead of stopping to ask.
///
/// **Two downloads moved and each gets its own record**, which is the whole
/// reason a mixed folder can be rebuilt. [files] is what this write laid down —
/// the base — and [placedPatchFiles] is where the patch ended up on top of it.
/// Which of the two records is the folder's own depends on [asCompanion], and
/// nothing else about the write does.
Future<void> _recordOrigin({
  required ModInfo mod,
  required int remoteModId,
  required GbFile file,
  required String? archiveMd5,
  required UpdateLayout layout,
  required bool asCompanion,
  required List<String>? patchFiles,
  List<InstalledFile>? files,
  List<InstalledFile>? placedPatchFiles,
}) async {
  final now = DateTime.now();
  await ApiService.updateModOrigin(mod.id, (current) {
    var block = current ??
        const ModOrigin(provenance: OriginProvenance.downloaded);

    // **The layer that was written**, whether it is the bottom of the stack or
    // one above it. `updatedTo` owns the clearing rules; the stack is what makes
    // the two cases one line instead of two branches.
    final written = block.downloadOf(remoteModId);
    block = written == null
        // Not on record at all — a mod the app updated without ever having a
        // block for it, which is most of a library that predates origin
        // tracking. The layer it wrote is what the folder now is.
        ? block.withBase((download) => download.updatedTo(
              modId: remoteModId,
              fileId: file.idRow,
              version: file.version,
              versionLabel: file.description,
              archiveMd5: archiveMd5,
              files: files,
            ))
        : block.withDownload(
            remoteModId,
            (download) => download.updatedTo(
              modId: remoteModId,
              fileId: file.idRow,
              version: file.version,
              versionLabel: file.description,
              archiveMd5: archiveMd5,
              files: files,
            ),
          );

    // The layers above moved onto the new base's layout, so their records are
    // rewritten too. One write, not two: they are layers of one stack.
    if (placedPatchFiles != null && placedPatchFiles.isNotEmpty) {
      block = block.copyWith(downloads: [
        block.downloads.first,
        for (final patch in block.patches)
          patch.copyWith(files: placedPatchFiles),
      ]);
    }

    block = block.copyWith(
      source: gameBananaSource,
      ingest: ingestAfterUpdate(layout, block.ingest, patchFiles: patchFiles),
    );

    // **Only when what the folder *is* was written.** A patch arriving on top
    // does not re-date the folder or re-describe how it got here.
    if (block.base?.modId != remoteModId) return withRebuiltPatchFiles(block);
    return withRebuiltPatchFiles(block.copyWith(
      provenance: OriginProvenance.downloaded,
      installedAt: now,
      // **Observed, so the proxy flag goes.** We watched this happen; leaving a
      // flag that says the date was derived from file timestamps would have
      // anything comparing dates distrust one it can rely on.
      installedAtIsProxy: false,
    ));
  });
}

NotificationLines _failureMessage(
  AppLocalizations loc,
  UpdateApplyResult result,
  ModInfo mod,
) =>
    switch (result.failure) {
      UpdateApplyFailure.snapshot => NotificationLines(
          loc.t('mods.update_apply.snapshot_failed_title'),
          loc.t('mods.update_apply.snapshot_failed', params: {'mod': mod.name}),
        ),
      UpdateApplyFailure.modMissing => NotificationLines(
          loc.t('mods.update_apply.mod_missing_title'),
          loc.t('mods.update_apply.mod_missing', params: {'mod': mod.name}),
        ),
      UpdateApplyFailure.copy => NotificationLines(
          loc.t('mods.update_apply.copy_failed_title'),
          loc.t(
            'mods.update_apply.copy_failed',
            params: {'mod': mod.name, 'message': result.error ?? ''},
          ),
        ),
      _ => NotificationLines(
          loc.t('mods.update_apply.layout_failed_title'),
          loc.t('mods.update_apply.layout_failed', params: {'mod': mod.name}),
        ),
    };

Future<void> _cleanupExtract(Directory? root) async {
  if (root == null) return;
  try {
    if (!root.path.contains('zzz_archive_extract_')) return;
    if (await root.exists()) await root.delete(recursive: true);
  } catch (e) {
    Logger('fileops').debug('temp cleanup failed',
        fields: {'path': root.path, 'reason': '$e'});
  }
}

/// The file we just consumed and nothing else — never its directory. Archives
/// share `<appData>/downloads`, so deleting a parent here would take every other
/// archive and every in-flight partial with it.
///
/// **Cancelling at the confirmation still deletes it**, because `archiveConsumed`
/// is set once the extraction succeeds and the dialog comes after. Backing out
/// therefore costs a full re-download. Deliberate rather than overlooked: the
/// alternative is keeping every declined archive in a folder the user does not
/// manage, and mod archives reach 1.24 GB. Revisit if anyone reports it.
Future<void> _deleteArchive(File archive) async {
  try {
    if (await archive.exists()) await archive.delete();
  } catch (e) {
    Logger('fileops').warning('could not delete a consumed archive',
        error: e, fields: {'archive': archive.path});
  }
}
