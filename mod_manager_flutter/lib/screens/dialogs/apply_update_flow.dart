import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;

import '../../core/constants.dart';
import '../../l10n/app_localizations.dart';
import '../../models/character_info.dart';
import '../../models/gamebanana/gamebanana.dart';
import '../../models/mod_ingest.dart';
import '../../models/mod_origin.dart';
import '../../models/origin_enums.dart';
import '../../services/api_service.dart';
import '../../services/archive_service.dart';
import '../../services/update_apply/mod_activation_port.dart';
import '../../services/update_apply/update_applier.dart';
import '../../services/update_apply/update_layout.dart';
import '../../utils/notifications.dart';
import '../../utils/state_providers.dart';
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
/// Returns true when the mod folder changed, so the caller rescans.
Future<bool> applyUpdateFlow(
  BuildContext context,
  WidgetRef ref, {
  required ModInfo mod,
  required int remoteModId,
  required GbFile file,
}) async {
  final loc = context.loc;
  final notify = context.notify;

  void fail(String message) => notify.error(message);

  final config = await ApiService.getConfig();
  final modsPath = config['mods_path'] ?? '';
  if (modsPath.isEmpty) {
    fail(loc.t('marketplace.install_missing_path'));
    return false;
  }
  final modFolder = Directory(path.join(modsPath, mod.id));
  if (!await modFolder.exists()) {
    fail(loc.t('mods.update_apply.mod_missing', params: {'mod': mod.name}));
    return false;
  }

  if (!context.mounted) return false;
  final download = await downloadFileWithProgress(context, ref, file);
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
      fail(
        '${extraction.error ?? loc.t('marketplace.install_unsupported')}\n'
        '${loc.t('marketplace.archive_kept', params: {'path': download.file.path})}',
      );
      return false;
    }
    archiveConsumed = true;

    final folders = extraction.extractedFolders ?? const <String>[];
    if (folders.isEmpty) {
      fail(loc.t('marketplace.install_empty'));
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
    );

    if (!context.mounted) return false;
    final choice = await showUpdateConfirmDialog(
      context,
      mod: mod,
      file: file,
      preview: preview,
    );
    if (choice == null) return false;

    final result = await applier.apply(
      modName: mod.id,
      modFolder: modFolder,
      preview: preview,
      deleteStaleInis: choice.removeStaleInis,
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
      fail(_failureMessage(loc, result, mod));
      // A failed *copy* still moved files. Anything else left the folder alone.
      return result.failure == UpdateApplyFailure.copy;
    }

    await _recordOrigin(
      mod: mod,
      remoteModId: remoteModId,
      file: file,
      archiveMd5: extraction.archiveMd5 ?? download.md5,
      layout: preview.layout,
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
      fail(loc.t('mods.update_apply.failed', params: {'message': '$e'}));
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
/// rather than here.
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
}) async {
  final now = DateTime.now();
  await ApiService.updateModOrigin(mod.id, (current) {
    final base = current ??
        const ModOrigin(provenance: OriginProvenance.downloaded);
    return base.updatedTo(
      source: AppConstants.gameBananaSourceName,
      modId: remoteModId,
      fileId: file.idRow,
      version: file.version,
      versionLabel: file.description,
      archiveMd5: archiveMd5,
      ingest: _ingestFor(layout, current?.ingest),
      installedAt: now,
    );
  });
}

/// The layout this update actually used, in the shape the next one replays.
///
/// A combined install keeps its **recorded** subfolder names rather than the
/// archive's: the subfolder is what the mod's own `.ini` paths were written
/// against, and adopting a differently-cased incoming name would create a second
/// directory beside the first on a case-sensitive filesystem.
ModIngest? _ingestFor(UpdateLayout layout, ModIngest? current) {
  if (layout.mappings.isEmpty) return current;
  if (current?.mode == IngestMode.combined) return current;
  return ModIngest(
    folders: [layout.mappings.single.source],
    siblingGroup: current?.siblingGroup,
  );
}

String _failureMessage(AppLocalizations loc, UpdateApplyResult result, ModInfo mod) =>
    switch (result.failure) {
      UpdateApplyFailure.snapshot =>
        loc.t('mods.update_apply.snapshot_failed', params: {'mod': mod.name}),
      UpdateApplyFailure.modMissing =>
        loc.t('mods.update_apply.mod_missing', params: {'mod': mod.name}),
      UpdateApplyFailure.copy => loc.t(
          'mods.update_apply.copy_failed',
          params: {'mod': mod.name, 'message': result.error ?? ''},
        ),
      _ => loc.t('mods.update_apply.layout_failed', params: {'mod': mod.name}),
    };

Future<void> _cleanupExtract(Directory? root) async {
  if (root == null) return;
  try {
    if (!root.path.contains('zzz_archive_extract_')) return;
    if (await root.exists()) await root.delete(recursive: true);
  } catch (e) {
    print('applyUpdateFlow: temp cleanup error ${root.path}: $e');
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
/// manage, and §0 measured a 1.24 GB tail. Revisit if anyone reports it.
Future<void> _deleteArchive(File archive) async {
  try {
    if (await archive.exists()) await archive.delete();
  } catch (e) {
    print('applyUpdateFlow: could not delete archive ${archive.path}: $e');
  }
}
