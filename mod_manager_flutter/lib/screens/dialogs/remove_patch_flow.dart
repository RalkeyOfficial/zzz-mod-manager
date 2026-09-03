import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;

import '../../l10n/app_localizations.dart';
import '../../models/character_info.dart';
import '../../models/mod_download.dart';
import '../../services/api_service.dart';
import '../../services/folder_contents.dart';
import '../../services/log/confirmations.dart';
import '../../services/patch_record.dart';
import '../../services/patch_removal.dart';
import '../../services/patch_store.dart';
import '../../services/update_apply/mod_activation_port.dart';
import '../../services/update_apply/update_applier.dart';
import '../../utils/notifications.dart';
import '../../utils/state_providers.dart';

/// **Taking a patch out of a mod folder**, from the question to the write.
///
/// The order is the design and it is the same one every other write in this app
/// runs: work out what would happen against the folder as it stands, say it,
/// ask, snapshot, then change anything.
///
/// **The plan is computed before the confirmation, not after.** The counts on
/// screen are the actual plan — not an estimate read off the record — so a
/// recorded file the user deleted themselves is already excluded from what they
/// are agreeing to.
///
/// Returns true when the folder changed, so the caller rescans: the card's
/// status slot is drawn from `ModInfo.origin`, which only a scan refreshes.
Future<bool> removePatchFlow(
  BuildContext context,
  WidgetRef ref, {
  required ModInfo mod,
  required ModDownload patch,
  required String patchName,
}) async {
  final loc = context.loc;
  final notify = context.notify;
  // Guaranteed by `removablePatches`, which is the only way in: a layer with no
  // page has no store keyed by one and no update to check.
  final patchModId = patch.modId!;

  final mods = await ApiService.getModManagerService();
  final modsPath = mods.modsPath;
  if (modsPath == null) return false;
  final modFolder = Directory(path.join(modsPath, mod.id));

  final onDisk = await readFolderContents(modFolder);
  const store = PatchStore();
  final stored = <String>{
    for (final file in patch.files)
      if (await store.holds(
        modFolder: modFolder,
        patchModId: patchModId,
        relativePath: file.path,
      ))
        file.path,
  };

  final plan = planPatchRemoval(
    origin: mod.origin,
    patchModId: patchModId,
    onDisk: onDisk,
    storedOriginals: stored,
  );

  if (!context.mounted) return false;

  // Nothing to do, and saying so beats a confirmation that would change
  // nothing. The record still goes, because the folder demonstrably does not
  // hold this patch any more.
  if (!plan.touchesFiles && !plan.leavesPatchBehind) {
    final removed = await _forget(mod, patch);
    if (!context.mounted) return removed;
    notify.info(
      loc.t('mods.remove_patch.already_gone_title'),
      body: patchName,
      characterId: mod.characterId,
    );
    return removed;
  }

  final accepted = await showRemovePatchConfirmation(
    context,
    modName: mod.name,
    patchName: patchName,
    plan: plan,
  );
  logConfirmation(
    'patch.remove',
    accepted: accepted,
    subject: mod.name,
    fields: {'patch': patchModId, 'files': plan.delete.length},
  );
  if (!accepted || !context.mounted) return false;

  final snapshots = ref.read(snapshotServiceProvider);
  final applier = UpdateApplier(
    snapshots: snapshots,
    activation: ModManagerActivationPort(mods),
  );
  final result = await applier.removePatch(
    modName: mod.id,
    modFolder: modFolder,
    patchModId: patchModId,
    plan: plan,
  );

  // **Before the success check**, the same as the update path: a snapshot exists
  // the moment the capture succeeded, and the failure branch is where a user
  // needs "Restore a previous version…" to be in the menu.
  //
  // Retention runs on the same condition and for the same reason: the snapshot
  // comes before anything is moved, so a removal that failed part-way still
  // added a whole folder to the budget — see §5 of
  // `docs/applying-updates.md`.
  if (result.snapshot != null) {
    ref.invalidate(modBackupsProvider);
    await snapshots.prune();
  }

  if (!result.success) {
    if (!context.mounted) return false;
    notify.error(
      loc.t('mods.remove_patch.failed_title'),
      body: switch (result.failure!) {
        UpdateApplyFailure.snapshot =>
          loc.t('mods.remove_patch.failed_snapshot'),
        UpdateApplyFailure.modMissing =>
          loc.t('mods.remove_patch.failed_missing'),
        _ => mod.name,
      },
      characterId: mod.characterId,
    );
    return false;
  }

  // **The record goes even when some files could not be moved.** What it claims
  // is that this folder holds that patch, and after this it does not — the
  // leftovers are named on screen rather than kept as a claim that would go on
  // offering to update a patch that has been taken out.
  await _forget(mod, patch);

  // Pruning already ran with the snapshot, above.
  ref.invalidate(modBackupsProvider);
  ref.invalidate(installedModsIndexProvider);

  if (!context.mounted) return true;
  if (result.failed.isEmpty) {
    notify.success(
      loc.t('mods.remove_patch.done_title'),
      body: patchName,
      characterId: mod.characterId,
    );
  } else {
    notify.warning(
      loc.t('mods.remove_patch.partial_title'),
      body: _counted(
          loc, 'mods.remove_patch.partial_body', result.failed.length),
      characterId: mod.characterId,
    );
  }
  return true;
}

/// Drops the layer and rebuilds the flat patch-file list from what is left.
///
/// Both in one write: a `patch_files` still naming a patch that has gone would
/// have the next base update set aside files nothing owns.
Future<bool> _forget(ModInfo mod, ModDownload patch) =>
    ApiService.updateModOrigin(
      mod.id,
      (current) => current == null
          ? null
          : withRebuiltPatchFiles(current.withoutDownload(patch.modId!)),
    );

/// What will happen, as counts.
///
/// **Counts, not a file list.** A patch is routinely a dozen textures and a
/// dialog listing them is unreadable; what a user needs before agreeing is how
/// many files leave, how many of their mod's come back, and whether anything is
/// left behind. The names are in the log if it ever matters.
///
/// Public so it can be mounted on its own: [removePatchFlow] reaches `ApiService`,
/// which lazily builds a `ConfigService` against the developer's **real**
/// `<appData>/config.json`, so a test that ran the flow to see this screen would
/// rewrite their library paths. It needs no seam of its own — it takes a decided
/// plan and returns an answer.
Future<bool> showRemovePatchConfirmation(
  BuildContext context, {
  required String modName,
  required String patchName,
  required PatchRemovalPlan plan,
}) async {
  final loc = context.loc;
  final answer = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(loc.t('mods.remove_patch.title')),
      content: SizedBox(
        width: 460,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(loc.t('mods.remove_patch.body',
                params: {'patch': patchName, 'mod': modName})),
            const SizedBox(height: 12),
            if (plan.delete.isNotEmpty)
              _line(
                context,
                Icons.remove_circle_outline,
                _counted(loc, 'mods.remove_patch.deletes', plan.delete.length),
              ),
            if (plan.restore.isNotEmpty)
              _line(
                context,
                Icons.settings_backup_restore,
                _counted(
                    loc, 'mods.remove_patch.restores', plan.restore.length),
              ),
            // **The one loss on this screen**, so it is stated before the
            // answer rather than reported after it.
            if (plan.unrecoverable.isNotEmpty)
              _line(
                context,
                Icons.warning_amber_rounded,
                _counted(
                  loc,
                  'mods.remove_patch.unrecoverable',
                  plan.unrecoverable.length,
                ),
                emphasis: true,
              ),
            if (plan.gone.isNotEmpty)
              _line(
                context,
                Icons.help_outline,
                _counted(loc, 'mods.remove_patch.gone', plan.gone.length),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(loc.t('mods.remove_patch.cancel')),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(loc.t('mods.remove_patch.confirm')),
        ),
      ],
    ),
  );
  return answer ?? false;
}

/// [loc.plural] chooses the form; the count still has to be handed to it.
///
/// Every one of these strings names its number, in both locales — a Ukrainian
/// `_single` is reached at 1, 21 and 31, so a form that left the count out would
/// read "one file" over twenty-one of them.
String _counted(AppLocalizations loc, String key, int count) =>
    loc.plural(key, count, params: {'count': '$count'});

Widget _line(
  BuildContext context,
  IconData icon,
  String text, {
  bool emphasis = false,
}) {
  final scheme = Theme.of(context).colorScheme;
  final colour = emphasis ? scheme.error : scheme.onSurfaceVariant;
  return Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: colour),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: colour),
          ),
        ),
      ],
    ),
  );
}
