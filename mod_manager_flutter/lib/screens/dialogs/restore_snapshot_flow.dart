import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;

import '../../l10n/app_localizations.dart';
import '../../models/character_info.dart';
import '../../services/backup/snapshot_service.dart';
import '../../services/update_apply/mod_activation_port.dart';
import '../../services/update_apply/update_applier.dart';
import '../../utils/notifications.dart';
import '../../utils/state_providers.dart';

/// Asks, then puts [mod]'s folder back to [snapshot] (`docs/applying-updates.md` §5, "Rollback"). The restore takes
/// a snapshot of the folder as it is first, so the restore itself can be undone.
///
/// The outcome is reported either way, success included: the folder's files are not something the user sees change.
/// Returns true when the folder changed. The library is rescanned here, not by the caller: from the History tab
/// nothing holds the user on the page while the folder is copied, and the result has to land even after they leave.
Future<bool> restoreSnapshotFlow(BuildContext context, {required ModInfo mod, required ModSnapshot snapshot}) async {
  final loc = context.loc;
  final notify = context.notify;
  // **The app's container, not the caller's `ref`**, which dies with the page.
  final container = ProviderScope.containerOf(context, listen: false);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(dialogContext.loc.t('mods.backups.confirm_title')),
      content: SizedBox(
        width: 440,
        child: Text(
          dialogContext.loc.t(
            'mods.backups.confirm_body',
            params: {'mod': mod.name, 'date': formatSnapshotTime(snapshot.takenAt)},
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(dialogContext.loc.t('mods.update_apply.cancel')),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(dialogContext.loc.t('mods.backups.restore')),
        ),
      ],
    ),
  );
  if (confirmed != true) return false;

  final mods = await container.read(modManagerServiceProvider.future);
  final modsPath = mods.modsPath;
  if (modsPath == null || modsPath.isEmpty) {
    // Not reachable from a configured app, but without this the restore runs against a relative `Directory(mod.id)`
    // and fails through the generic "couldn't restore" message, which says nothing the user can act on.
    notify.error(loc.t('marketplace.install_missing_path_title'), body: loc.t('marketplace.install_missing_path_body'));
    return false;
  }

  final snapshots = container.read(snapshotServiceProvider);
  final applier = UpdateApplier(
    snapshots: snapshots,
    activation: ModManagerActivationPort(mods, leaveOff: (m) => leftOffAfterWrite(container, m)),
  );
  final result = await whileWritingMod(
    container,
    mod.id,
    () => applier.restore(modName: mod.id, modFolder: Directory(path.join(modsPath, mod.id)), snapshot: snapshot),
  );

  // A rollback takes a safety copy of its own before it writes, so the store's budget moved here as on any other
  // write. Whether the restore landed or not: the copy was taken first.
  if (result.snapshot != null) await snapshots.prune();
  container.invalidate(modBackupsProvider);
  // Read again whatever the stamp says: a restore puts back old times, which can match what was there before.
  mods.invalidateKeybinds(mod.id);
  // A failed restore may still have changed the folder, so it is read again either way.
  await container.read(libraryProvider.notifier).rescan();

  notify.show(
    result.success ? NotificationKind.done : NotificationKind.error,
    loc.t(result.success ? 'mods.backups.restored_title' : 'mods.backups.restore_failed_title'),
    body: mod.name,
    characterId: mod.characterId,
  );
  return result.success;
}

/// A snapshot's time as the restore list and its confirmation show it, `2026-09-28 14:05` in local time.
String formatSnapshotTime(DateTime date) {
  final d = date.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}

/// Why [reason]'s snapshot was taken, as the restore list words it.
String snapshotReasonKey(SnapshotReason reason) => switch (reason) {
  SnapshotReason.beforeUpdate => 'mods.backups.reason_update',
  SnapshotReason.beforeRestore => 'mods.backups.reason_restore',
  SnapshotReason.beforePatchRemoval => 'mods.backups.reason_patch_removal',
};
