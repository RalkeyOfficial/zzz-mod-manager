import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;

import '../../core/button_working.dart';
import '../../l10n/app_localizations.dart';
import '../../models/character_info.dart';
import '../../services/backup/snapshot_service.dart';
import '../../services/log/logger.dart';
import '../../services/update_apply/mod_activation_port.dart';
import '../../services/update_apply/update_applier.dart';
import '../../utils/notification_actions.dart';
import '../../utils/notifications.dart';
import '../../utils/state_providers.dart';

final Logger _log = Logger('snapshot');

/// Asks, then puts [mod]'s folder back to [snapshot] (`docs/applying-updates.md` §5, "Rollback"). The restore takes
/// a snapshot of the folder as it is first, so the restore itself can be undone: the Done card's Undo puts that one
/// back.
///
/// The outcome is reported either way, success included: the folder's files are not something the user sees change.
/// Returns true when the folder changed. The library is rescanned here, not by the caller: from the History tab
/// nothing holds the user on the page while the folder is copied, and the result has to land even after they leave.
///
/// [work] shows the copy on the button that asked, after the question.
Future<bool> restoreSnapshotFlow(
  BuildContext context, {
  required ModInfo mod,
  required ModSnapshot snapshot,
  WorkSpan work = noWorkSpan,
}) async {
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
    notify.error(
      loc.t('marketplace.install_missing_path_title'),
      body: loc.t('marketplace.install_missing_path_body'),
      actions: [openSettingsAction(loc, container)],
    );
    return false;
  }

  final card = notify.working(loc.t('mods.backups.restoring_title'), body: mod.name, characterId: mod.characterId);
  var ended = false;
  try {
    final result = await work(() => writeSnapshotBack(container, mod: mod, snapshot: snapshot));
    final safety = result.snapshot;
    if (result.success) {
      card.update(
        kind: NotificationKind.done,
        title: loc.t('mods.backups.restored_title'),
        actions: [
          if (safety != null)
            undoAction(
              loc,
              () => unawaited(undoSnapshotWrite(container, loc, notify,
                  mod: mod, snapshot: safety, wording: _restoreUndoWording(loc, mod))),
            ),
        ],
      );
    } else {
      card.update(kind: NotificationKind.error, title: loc.t('mods.backups.restore_failed_title'));
    }
    ended = true;
    return result.success;
  } finally {
    if (!ended) card.dismiss();
  }
}

/// The write half of a restore, with no `BuildContext`, so a card's Undo can run it too: puts [mod]'s folder back to
/// [snapshot] while the mod is marked as being written, then reads the saved versions, the mod's keys and the library
/// again.
Future<UpdateApplyResult> writeSnapshotBack(
  ProviderContainer container, {
  required ModInfo mod,
  required ModSnapshot snapshot,
}) async {
  final mods = await container.read(modManagerServiceProvider.future);
  final modsPath = mods.modsPath;
  if (modsPath == null || modsPath.isEmpty) return UpdateApplyResult.failed(UpdateApplyFailure.modMissing);

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
  return result;
}

/// What an Undo's cards say. Undoing a restore and putting a patch back differ only in their words.
class UndoWording {
  const UndoWording({
    required this.working,
    required this.done,
    required this.failed,
    required this.gone,
    required this.missing,
    required this.body,
  });

  /// The Working card's title.
  final String working;

  /// The Done card's title.
  final String done;

  /// The Error card's title.
  final String failed;

  /// The Error card's body when the snapshot is no longer kept.
  final String gone;

  /// The Error card's body when the mod's folder is no longer there.
  final String missing;

  /// What every card is about.
  final String body;
}

UndoWording _restoreUndoWording(AppLocalizations loc, ModInfo mod) => UndoWording(
      working: loc.t('mods.backups.undoing_title'),
      done: loc.t('mods.backups.undone_title'),
      failed: loc.t('mods.backups.undo_failed_title'),
      gone: loc.t('mods.backups.undo_gone'),
      missing: loc.t('mods.backups.undo_missing'),
      body: mod.name,
    );

/// A card's Undo for a write that took [snapshot] of [mod]'s folder first: puts that snapshot back, as a restore
/// does, so the undo can itself be restored from the list of previous versions.
///
/// A Working card shows while it runs and ends as [wording]'s Done, with no Undo of its own, or its Error. A folder
/// another write holds is waited for, as a switch press waits: a card's button can't be held the way the History
/// tab's are.
Future<void> undoSnapshotWrite(
  ProviderContainer container,
  AppLocalizations loc,
  NotificationCenter notify, {
  required ModInfo mod,
  required ModSnapshot snapshot,
  required UndoWording wording,
}) async {
  final card = notify.working(wording.working, body: wording.body, characterId: mod.characterId);
  void fail([String? body]) => card.update(kind: NotificationKind.error, title: wording.failed, body: body);
  try {
    await _untilFree(container, mod.id);
    // Marked from here rather than from the write, so a press on History between the checks and the write is held
    // too. The write marks it again, and the marks are counted.
    final outcome = await whileWritingMod<({bool ok, String? body})>(container, mod.id, () async {
      // Pruned to make room, or deleted from the list of previous versions. Restoring from it would still take a
      // safety copy and then fail.
      if (!await Directory(path.join(snapshot.directory.path, 'files')).exists()) return (ok: false, body: wording.gone);
      // Renamed or deleted since. Restoring would make a folder of the old name.
      final modsPath = (await container.read(modManagerServiceProvider.future)).modsPath;
      if (modsPath == null || !await Directory(path.join(modsPath, mod.id)).exists()) {
        return (ok: false, body: wording.missing);
      }
      final result = await writeSnapshotBack(container, mod: mod, snapshot: snapshot);
      return (ok: result.success, body: null);
    });
    if (outcome.ok) {
      card.update(kind: NotificationKind.done, title: wording.done);
    } else {
      fail(outcome.body);
    }
  } catch (e, stack) {
    _log.warning('could not undo a write', error: e, stack: stack, fields: {'mod': mod.id, 'snapshot': snapshot.id});
    fail();
  }
}

/// Waits until no write holds [modId]'s folder.
Future<void> _untilFree(ProviderContainer container, String modId) async {
  while (container.read(modWritesInProgressProvider).contains(modId)) {
    final free = Completer<void>();
    final watching = container.listen(modWritesInProgressProvider, (_, writing) {
      if (!writing.contains(modId) && !free.isCompleted) free.complete();
    });
    await free.future;
    watching.close();
  }
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
