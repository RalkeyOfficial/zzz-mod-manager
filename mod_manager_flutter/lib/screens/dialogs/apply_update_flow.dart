import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;

import '../../l10n/app_localizations.dart';
import '../../models/character_info.dart';
import '../../models/gamebanana/gamebanana.dart';
import '../../models/mod_ingest.dart';
import '../../models/mod_origin.dart';
import '../../models/origin_enums.dart';
import '../../services/api_service.dart';
import '../../services/archive_service.dart';
import '../../services/folder_contents.dart';
import '../../services/log/logger.dart';
import '../../services/patch_placement.dart';
import '../../services/patch_record.dart';
import '../../services/update_apply/mod_activation_port.dart';
import '../../services/update_apply/update_applier.dart';
import '../../services/update_apply/update_layout.dart';
import '../../utils/gamebanana_url.dart';
import '../../utils/notifications.dart';
import '../../utils/state_providers.dart';
import '../components/extract_failure_message.dart';
import 'download_with_progress.dart';
import 'update_confirm_dialog.dart';
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
    final applier = UpdateApplier(
      snapshots: ref.read(snapshotServiceProvider),
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
    );

    if (!context.mounted) return false;
    final choice = confirm
        ? await showUpdateConfirmDialog(
            context,
            mod: mod,
            file: file,
            preview: preview,
            flattensPatch: flattensPatch,
          )
        : const UpdateConfirmChoice(removeStaleInis: true);
    if (choice == null) return false;

    final result = await applier.applyBaseThenPatch(
      modName: mod.id,
      modFolder: modFolder,
      preview: preview,
      deleteStaleInis: choice.removeStaleInis,
      patchFiles: patchFiles,
      previousVersion: mod.origin?.version,
      previousVersionLabel: mod.origin?.versionLabel,
    );

    // **Before the success check, deliberately.** A snapshot exists the moment
    // `apply` got past its snapshot step, and the *failure* path is where it
    // matters most: a copy that broke halfway leaves the folder half-old and
    // half-new, and the error message sends the user straight to "Restore a
    // previous version…". That entry is drawn from this provider's cached set,
    // so a mod being updated for the first time was not in it — the one moment
    // the rollback is needed was the one moment it was missing from the menu.
    // Invalidating here rather than in each branch is what stops that returning.
    if (result.snapshot != null) ref.invalidate(modBackupsProvider);

    if (!result.success) {
      if (!context.mounted) return result.snapshot != null;
      final lines = _failureMessage(loc, result, mod);
      fail(lines.title, lines.body);
      // A failed *copy* still moved files. Anything else left the folder alone.
      return result.failure == UpdateApplyFailure.copy;
    }

    await _recordOrigin(
      mod: mod,
      remoteModId: remoteModId,
      file: file,
      archiveMd5: extraction.archiveMd5 ?? download.md5,
      layout: preview.layout,
      asCompanion: asCompanion,
      // Where the patch is *now*. `applyBaseThenPatch` moves it onto the new
      // base's layout by design, so recording the paths it started from would
      // send the next rebuild looking in the wrong place.
      patchFiles: patchFiles.isEmpty ? null : result.patchFiles,
    );

    // Bounded retention runs here rather than on a timer: it is the one moment
    // a new snapshot has just been added, and it is already an operation the
    // user is waiting on. Pruning can delete, so the backup list is re-read
    // after it as well as before.
    await ref.read(snapshotServiceProvider).prune();
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
    final applier = UpdateApplier(
      snapshots: ref.read(snapshotServiceProvider),
      activation: ModManagerActivationPort(mods),
    );
    final result = await applier.applyPatchInto(
      modName: mod.id,
      modFolder: modFolder,
      source: source,
      incoming: incoming,
      existing: existing,
      placement: placement,
    );
    if (result.snapshot != null) ref.invalidate(modBackupsProvider);

    if (!result.success) {
      if (!context.mounted) return result.snapshot != null;
      final lines = _failureMessage(loc, result, mod);
      fail(lines.title, lines.body);
      return result.failure == UpdateApplyFailure.copy;
    }

    await ApiService.updateModOrigin(mod.id, (current) {
      // Where the patch is now, whichever record names it.
      final ingest = (current?.ingest ?? const ModIngest())
          .copyWith(patchFiles: result.patchFiles);
      if (asCompanion) {
        return withCompanionUpdatedTo(
          current?.copyWith(ingest: ingest),
          modId: remoteModId,
          fileId: file.idRow,
          version: file.version,
          versionLabel: file.description,
          archiveMd5: extraction.archiveMd5 ?? download.md5,
        );
      }
      final base =
          current ?? const ModOrigin(provenance: OriginProvenance.downloaded);
      return base.updatedTo(
        source: gameBananaSource,
        modId: remoteModId,
        fileId: file.idRow,
        version: file.version,
        versionLabel: file.description,
        archiveMd5: extraction.archiveMd5 ?? download.md5,
        // **Not refreshed from this download's layout.** The folder's shape is
        // the base's, and this archive's folder names describe the patch.
        ingest: ingest,
        installedAt: DateTime.now(),
      );
    });

    await ref.read(snapshotServiceProvider).prune();
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

/// Writes what the folder now is.
///
/// Both confidences reach `exact` here on the same grounds a marketplace
/// install does — the user picked this row of this mod's file list and we wrote
/// exactly that file id — and the clearing rules live in [ModOrigin.updatedTo]
/// and [withCompanionUpdatedTo] rather than here.
///
/// **Against the identity that was actually written.** A folder can hold two
/// downloads, and stamping a companion's file id onto the primary would claim the
/// folder is that other mod.
///
/// The `ingest` record is refreshed from what actually happened, which is a real
/// gain for the pre-`ingest` library: a mod that had no layout on record now has
/// one, so its *next* update replays instead of stopping to ask.
Future<void> _recordOrigin({
  required ModInfo mod,
  required int remoteModId,
  required GbFile file,
  required String? archiveMd5,
  required UpdateLayout layout,
  required bool asCompanion,
  required List<String>? patchFiles,
}) async {
  final now = DateTime.now();
  await ApiService.updateModOrigin(mod.id, (current) {
    final ingest =
        ingestAfterUpdate(layout, current?.ingest, patchFiles: patchFiles);
    if (asCompanion) {
      // The folder's own identity is untouched: it still is what it was, and
      // what changed is the *other* download in it.
      return withCompanionUpdatedTo(
        current?.copyWith(ingest: ingest),
        modId: remoteModId,
        fileId: file.idRow,
        version: file.version,
        versionLabel: file.description,
        archiveMd5: archiveMd5,
      );
    }
    final base = current ??
        const ModOrigin(provenance: OriginProvenance.downloaded);
    return base.updatedTo(
      source: gameBananaSource,
      modId: remoteModId,
      fileId: file.idRow,
      version: file.version,
      versionLabel: file.description,
      archiveMd5: archiveMd5,
      ingest: ingest,
      installedAt: now,
    );
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
