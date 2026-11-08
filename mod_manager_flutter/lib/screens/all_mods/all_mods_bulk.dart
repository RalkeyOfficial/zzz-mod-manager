import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/palette.dart';
import '../../l10n/app_localizations.dart';
import '../../models/character_info.dart';
import '../../services/api_service.dart';
import '../../services/log/confirmations.dart';
import '../../services/log/logger.dart';
import '../../services/mod_manager_service.dart' show DeleteStatus;
import '../../services/platform_service.dart' show NetworkLinkRefused;
import '../../services/shader_fixes/shader_fixes_service.dart';
import '../../utils/byte_format.dart';
import '../../utils/categories.dart';
import '../../utils/notification_actions.dart';
import '../../utils/notifications.dart';
import '../../utils/state_providers.dart';
import '../components/character_tile.dart';
import '../components/network_link_notice.dart';
import '../components/shader_fixes_notices.dart';
import '../components/zenith_controls.dart';
import '../components/zenith_dialog.dart';
import '../dialogs/delete_mod_dialog.dart';

final Logger _log = Logger('mods');

/// What a bulk Enable turns on, and what it leaves off.
class BulkEnablePlan {
  const BulkEnablePlan({required this.enable, required this.leftOff});

  final List<ModInfo> enable;

  /// The mods left off because two or more of them belong to one character with One at a time on, by group id.
  /// Which one to keep is the user's choice, never the app's (`docs/library-screen.md` §10).
  final Map<String, List<ModInfo>> leftOff;
}

/// Plans turning [selected] on. A mod already on is left as it is.
BulkEnablePlan planBulkEnable(List<ModInfo> selected, Map<String, bool> oneAtATime, {required bool agentsDefault}) {
  final off = selected.where((m) => !m.isActive).toList();
  final byGroup = <String, List<ModInfo>>{};
  for (final mod in off) {
    (byGroup[libraryGroupOf(mod.characterId)] ??= []).add(mod);
  }
  final leftOff = {
    for (final entry in byGroup.entries)
      if (entry.value.length > 1 && isOneAtATime(oneAtATime, entry.key, agentsDefault: agentsDefault)) entry.key: entry.value,
  };
  return BulkEnablePlan(
    enable: [for (final mod in off) if (!leftOff.containsKey(libraryGroupOf(mod.characterId))) mod],
    leftOff: leftOff,
  );
}

/// Whether an update, an install into it or a restore is writing [mod]'s folder right now. A bulk action leaves such
/// a mod alone, acts on the rest, and names it ([reportSkippedWhileWriting]), so the user can do it again after.
bool isBeingWritten(ProviderContainer container, ModInfo mod) =>
    container.read(modWritesInProgressProvider).contains(mod.id);

/// Names the mods a bulk action skipped because their folders were being written.
void reportSkippedWhileWriting(AppLocalizations loc, NotificationCenter notify, List<ModInfo> skipped) {
  if (skipped.isEmpty) return;
  notify.warning(
    loc.plural('library.all.skipped_writing_title', skipped.length, params: {'count': '${skipped.length}'}),
    body: loc.t('library.all.skipped_writing_body', params: {'names': skipped.map((m) => m.name).join(', ')}),
    characterId: _soleCharacter(skipped),
  );
}

/// The portrait for a report about [mods]: the one mod's character, and none for several.
String? _soleCharacter(List<ModInfo> mods) => mods.length == 1 ? mods.single.characterId : null;

/// [mods]' names as a card's body says several subjects: "A", "A and B", or "A, B and 3 more".
String bulkSubjects(AppLocalizations loc, List<ModInfo> mods) => subjectList(loc, [for (final m in mods) m.name]);

/// The Working card a bulk action over [mods] shows while it runs, titled by the counted [key]. Null when there is
/// nothing to act on.
NotificationHandle? _working(AppLocalizations loc, NotificationCenter notify, String key, List<ModInfo> mods) =>
    mods.isEmpty
        ? null
        : notify.working(
            loc.plural(key, mods.length, params: {'count': '${mods.length}'}),
            body: bulkSubjects(loc, mods),
            characterId: _soleCharacter(mods),
            progress: 0,
          );

/// Ends a bulk action's Working [card]: as the error naming [failed], under the counted [titleKey], or dismissed
/// when nothing failed. Raised after the action's other notices, so the result is the newest card. [actions] builds
/// the result's buttons from its title and body.
void _endBulk(
  AppLocalizations loc,
  NotificationCenter notify,
  NotificationHandle? card, {
  required String titleKey,
  required List<ModInfo> failed,
  List<NotificationAction> Function(String title, String body)? actions,
}) {
  if (failed.isEmpty) {
    card?.dismiss();
    return;
  }
  final title = loc.plural(titleKey, failed.length, params: {'count': '${failed.length}'});
  final body = failed.map((m) => m.name).join(', ');
  final buttons = actions?.call(title, body) ?? const <NotificationAction>[];
  if (card == null) {
    notify.error(title, body: body, characterId: _soleCharacter(failed), actions: buttons);
  } else {
    card.update(
      kind: NotificationKind.error,
      title: title,
      body: body,
      characterId: _soleCharacter(failed),
      actions: buttons,
    );
  }
}

/// Turns [selected] on, each through `ApiService.enableMod` as the switch does, so a character's other mods go off
/// under One at a time. Reports only what didn't happen: the table shows what did.
///
/// Reads the app's [container] rather than a widget's `ref`, so leaving the page mid-run still rescans.
Future<void> bulkEnable(BuildContext context, ProviderContainer container, List<ModInfo> selected) async {
  final loc = context.loc;
  final notify = context.notify;
  final plan = planBulkEnable(
    selected,
    container.read(oneAtATimeProvider),
    agentsDefault: container.read(oneAtATimeDefaultProvider),
  );
  _log.info('bulk enable', fields: {
    'mods': plan.enable.length,
    'left_off': plan.leftOff.values.fold<int>(0, (sum, mods) => sum + mods.length),
    'left_off_characters': plan.leftOff.length,
  });

  // Kept up to date between enables, so the second mod of a category sees the first as on.
  var library = container.read(modsProvider);
  final failed = <ModInfo>[];
  final refused = <(ModInfo, ShaderPlacementRefused)>[];
  final onNetwork = <ModInfo>[];
  final writing = <ModInfo>[];
  final card = _working(loc, notify, 'library.all.enabling', plan.enable);
  var ended = false;
  try {
    for (final (i, mod) in plan.enable.indexed) {
      try {
        if (isBeingWritten(container, mod)) {
          writing.add(mod);
          continue;
        }
        final switchOff = modsToSwitchOff(
          library,
          mod,
          container.read(oneAtATimeProvider),
          beingWritten: container.read(modWritesInProgressProvider),
          agentsDefault: container.read(oneAtATimeDefaultProvider),
        );
        bool done;
        try {
          // A mod being written is turned off at once all the same, and its write leaves it off.
          done = await ApiService.enableMod(
            mod.id,
            switchOff: switchOff,
            whileWritten: (other) => turnOffDuringWrite(container, other),
          );
        } on ShaderPlacementRefused catch (refusal) {
          // Reported with its reason, as the switch reports it: which shader files are taken, and by whom.
          refused.add((mod, refusal));
          continue;
        } on NetworkLinkRefused {
          onNetwork.add(mod);
          continue;
        } catch (e, stack) {
          _log.warning('bulk enable failed', error: e, stack: stack, fields: {'mod': mod.id});
          done = false;
        }
        if (!done) {
          failed.add(mod);
          continue;
        }
        library = [
          for (final m in library)
            if (m.id == mod.id)
              m.copyWith(isActive: true)
            else if (switchOff.contains(m.id))
              m.copyWith(isActive: false)
            else
              m,
        ];
      } finally {
        card?.update(progress: (i + 1) / plan.enable.length);
      }
    }
    await container.read(libraryProvider.notifier).rescan();

    // One notice for every mod the missing shader folder kept off, since the reason is the same for each; a mod
    // whose shader files are taken gets its own, naming the files and who holds them.
    final noFolder = [for (final (mod, refusal) in refused) if (refusal.noShaderFolder) mod];
    if (noFolder.length > 1) {
      notify.error(
        loc.t('mods.shader_fixes.no_folder_title'),
        body: loc.t('mods.shader_fixes.no_folder_body_many', params: {'mods': noFolder.map((m) => m.name).join(', ')}),
        actions: [openSettingsAction(loc, container)],
      );
    }
    for (final (mod, refusal) in refused) {
      if (refusal.noShaderFolder && noFolder.length > 1) continue;
      reportShaderRefusal(loc, notify, refusal, characterId: mod.characterId, container: container);
    }
    // One notice for all of them, since the reason is the same for each.
    if (onNetwork.isNotEmpty) reportNetworkLinkRefused(loc, notify, onNetwork.map((m) => m.name));
    if (plan.leftOff.isNotEmpty) {
      notify.warning(
        loc.t('library.all.enable_left_off_title'),
        body: loc.t('library.all.enable_left_off_body', params: {
          'names': plan.leftOff.keys.map((id) => libraryGroupName(id, loc)).join(', '),
        }),
      );
    }
    reportSkippedWhileWriting(loc, notify, writing);
    _endBulk(loc, notify, card, titleKey: 'library.all.enable_failed_title', failed: failed);
    ended = true;
  } finally {
    if (!ended) card?.dismiss();
  }
}

/// Turns [selected] off. Reports only a failure.
Future<void> bulkDisable(BuildContext context, ProviderContainer container, List<ModInfo> selected) async {
  final loc = context.loc;
  final notify = context.notify;
  final on = selected.where((m) => m.isActive).toList();
  _log.info('bulk disable', fields: {'mods': on.length});
  final failed = <ModInfo>[];
  final writing = <ModInfo>[];
  final card = _working(loc, notify, 'library.all.disabling', on);
  var ended = false;
  try {
    for (final (i, mod) in on.indexed) {
      if (isBeingWritten(container, mod)) {
        writing.add(mod);
      } else {
        bool done;
        try {
          done = await ApiService.disableMod(mod.id);
        } catch (e, stack) {
          _log.warning('bulk disable failed', error: e, stack: stack, fields: {'mod': mod.id});
          done = false;
        }
        if (!done) failed.add(mod);
      }
      card?.update(progress: (i + 1) / on.length);
    }
    await container.read(libraryProvider.notifier).rescan();
    reportSkippedWhileWriting(loc, notify, writing);
    _endBulk(loc, notify, card, titleKey: 'library.all.disable_failed_title', failed: failed);
    ended = true;
  } finally {
    if (!ended) card?.dismiss();
  }
}

/// Asks, then moves [selected] to the system trash, with their saved versions when the user says so, each as the
/// single delete does it. Returns whether it went ahead.
///
/// A mod the trash could not take stays as it was and is named once in one notification. Delete for good is only
/// offered for a single mod (`docs/deleting-mods.md` §6).
Future<bool> bulkDelete(BuildContext context, ProviderContainer container, List<ModInfo> selected) async {
  if (selected.isEmpty) return false;
  final loc = context.loc;
  final notify = context.notify;
  final snapshots = container.read(snapshotServiceProvider);
  var saved = 0;
  var savedBytes = 0;
  for (final mod in selected) {
    final versions = await snapshots.list(mod.uid);
    saved += versions.length;
    savedBytes += versions.fold<int>(0, (sum, snapshot) => sum + snapshot.sizeBytes);
  }
  if (!context.mounted) return false;
  final sizes = container.read(librarySizesProvider).valueOrNull;
  // No total until every ticked mod is measured: a mod left out would make "N in all" too small.
  final total = sizes == null || selected.any((m) => !sizes.containsKey(m.id))
      ? null
      : selected.fold<int>(0, (sum, m) => sum + sizes[m.id]!);

  final choice = await showDialog<DeleteChoice>(
    context: context,
    builder: (_) => _BulkDeleteDialog(mods: selected, savedVersions: saved, savedBytes: savedBytes, totalBytes: total),
  );
  if (choice == null) return false;

  final failed = <ModInfo>[];
  final notTrashed = <ModInfo>[];
  final writing = <ModInfo>[];
  final card = _working(loc, notify, 'library.all.deleting', selected);
  var ended = false;
  try {
    for (final (i, mod) in selected.indexed) {
      if (isBeingWritten(container, mod)) {
        writing.add(mod);
      } else {
        logConfirmation('mod.delete', accepted: true, subject: mod.id);
        try {
          final outcome = await ApiService.deleteMod(mod.id, deleteSnapshots: choice.deleteSnapshots);
          switch (outcome.status) {
            case DeleteStatus.deleted:
              break;
            case DeleteStatus.notTrashed:
              notTrashed.add(mod);
            case DeleteStatus.missing || DeleteStatus.failed:
              failed.add(mod);
          }
        } catch (e, stack) {
          _log.warning('bulk delete failed', error: e, stack: stack, fields: {'mod': mod.id});
          failed.add(mod);
        }
      }
      card?.update(progress: (i + 1) / selected.length);
    }
    final deleted = {
      for (final mod in selected)
        if (!failed.contains(mod) && !notTrashed.contains(mod) && !writing.contains(mod)) mod.id,
    };
    final selectedMod = container.read(selectedModIdProvider.notifier);
    if (deleted.contains(selectedMod.state)) selectedMod.state = null;
    final selection = container.read(allModsSelectionProvider.notifier);
    selection.state = selection.state.difference(deleted);
    container.invalidate(modBackupsProvider);
    await container.read(libraryProvider.notifier).rescan();

    reportSkippedWhileWriting(loc, notify, writing);
    // One result for every refusal: the card names the mods the trash refused as the trash's own error, and any other
    // failure under the plain "couldn't delete" title.
    _endBulk(
      loc,
      notify,
      card,
      titleKey: failed.isEmpty ? 'mods.delete.trash_failed_many_title' : 'library.all.delete_failed_title',
      failed: [for (final mod in selected) if (failed.contains(mod) || notTrashed.contains(mod)) mod],
      actions: (title, body) => [
        if (notTrashed.isNotEmpty) copyDetailsAction(loc, notify, title: title, body: body),
      ],
    );
    ended = true;
  } finally {
    if (!ended) card?.dismiss();
  }
  return true;
}

/// The confirmation for deleting several mods: how many, which, how much, and whether their saved versions go too.
class _BulkDeleteDialog extends StatefulWidget {
  const _BulkDeleteDialog({
    required this.mods,
    required this.savedVersions,
    required this.savedBytes,
    required this.totalBytes,
  });

  final List<ModInfo> mods;
  final int savedVersions;
  final int savedBytes;
  final int? totalBytes;

  /// Names listed before the rest are counted.
  static const _listed = 6;

  @override
  State<_BulkDeleteDialog> createState() => _BulkDeleteDialogState();
}

class _BulkDeleteDialogState extends State<_BulkDeleteDialog> {
  bool _deleteSnapshots = true;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final mods = widget.mods;
    final totalBytes = widget.totalBytes;
    final count = mods.length;
    final active = mods.where((m) => m.isActive).length;
    final rest = count - _BulkDeleteDialog._listed;

    return ZenithDialog.compact(
      alert: true,
      width: 480,
      title: loc.plural('library.all.delete_title', count, params: {'count': '$count'}),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 12,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 2,
            children: [
              for (final mod in mods.take(_BulkDeleteDialog._listed))
                Text(mod.name, style: text.bodyMedium?.copyWith(color: palette.text, fontWeight: FontWeight.w600)),
              if (rest > 0)
                Text(
                  loc.plural('library.all.delete_more', rest, params: {'count': '$rest'}),
                  style: text.bodySmall?.copyWith(color: palette.text3),
                ),
            ],
          ),
          Text(
            // "Its folder" or "their folders" is about one mod or several, not a plural form: Ukrainian's singular
            // form also covers 21 mods.
            loc.t(
              switch ((count == 1, totalBytes == null)) {
                (true, true) => 'library.all.delete_body_one',
                (true, false) => 'library.all.delete_body_one_size',
                (false, true) => 'library.all.delete_body',
                (false, false) => 'library.all.delete_body_size',
              },
              params: {if (totalBytes != null) 'size': formatBytes(totalBytes)},
            ),
            style: text.bodyMedium?.copyWith(color: palette.textProse, height: 1.6),
          ),
          // "It" for one mod and "them" for several, as the folder line above.
          if (active > 0)
            Text(
              count == 1
                  ? loc.t('library.all.delete_active_one')
                  : loc.plural('library.all.delete_active', active, params: {'count': '$active'}),
              style: text.bodyMedium?.copyWith(color: palette.textProse, height: 1.6),
            ),
          if (widget.savedVersions > 0)
            DeleteSnapshotsBox(
              label: loc.plural(
                count == 1 ? 'mods.delete.snapshots' : 'library.all.snapshots',
                widget.savedVersions,
                params: {'count': '${widget.savedVersions}'},
              ),
              bytes: widget.savedBytes,
              value: _deleteSnapshots,
              onChanged: (value) => setState(() => _deleteSnapshots = value),
            ),
        ],
      ),
      actions: [
        TextButton(autofocus: true, onPressed: () => Navigator.pop(context), child: Text(loc.t('mods.dialog.cancel'))),
        FilledButton.icon(
          style: dangerButtonStyle(context),
          onPressed: () => Navigator.pop(context, DeleteChoice(deleteSnapshots: _deleteSnapshots)),
          icon: const Icon(Icons.delete_outline_rounded),
          label: Text(loc.plural('library.all.delete_confirm', count, params: {'count': '$count'})),
        ),
      ],
    );
  }
}
