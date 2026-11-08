import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/button_working.dart';
import '../../core/palette.dart';
import '../../l10n/app_localizations.dart';
import '../../models/character_info.dart';
import '../../services/api_service.dart';
import '../../services/log/confirmations.dart';
import '../../services/mod_manager_service.dart';
import '../../services/platform_service.dart' show TrashResult;
import '../../utils/byte_format.dart';
import '../../utils/categories.dart';
import '../../utils/notification_actions.dart';
import '../../utils/notifications.dart';
import '../../utils/state_providers.dart';
import '../../utils/zzz_characters.dart';
import '../components/character_tile.dart' show libraryGroupName;
import '../components/mod_thumb.dart';
import '../components/zenith_controls.dart';
import '../components/zenith_dialog.dart';

/// What the user decided about the saved versions when they confirmed a delete.
class DeleteChoice {
  const DeleteChoice({required this.deleteSnapshots});

  final bool deleteSnapshots;
}

/// Asks, then moves the mod's folder to the system trash. [onDeleted] runs after it has gone, so the caller can
/// refresh its list.
///
/// [savedVersions] and [savedBytes] are the mod's snapshots, which the user has no other way to find out about; the
/// checkbox is there only when there are any. A trash that cannot take the folder leaves the mod as it was and raises
/// an error card; when the platform has no trash for it, the card offers "Delete for good…" (`docs/deleting-mods.md`).
Future<void> showDeleteModDialog(
  BuildContext context,
  ModInfo mod, {
  required VoidCallback onDeleted,
  int savedVersions = 0,
  int savedBytes = 0,
  WorkSpan work = noWorkSpan,
}) async {
  final choice = await showDialog<DeleteChoice>(
    context: context,
    builder: (_) => DeleteModDialog(mod: mod, savedVersions: savedVersions, savedBytes: savedBytes),
  );
  if (choice == null || !context.mounted) return;
  final loc = context.loc;
  final notify = context.notify;
  final navigator = Navigator.of(context, rootNavigator: true);
  final container = ProviderScope.containerOf(context, listen: false);
  // The most destructive thing in the app, and the one a user is most likely to ask about afterwards.
  logConfirmation('mod.delete', accepted: true, subject: mod.id);

  Future<void> report(DeleteOutcome outcome) async {
    switch (outcome.status) {
      case DeleteStatus.deleted:
        if (context.mounted) {
          onDeleted();
        } else {
          await container.read(libraryProvider.notifier).rescan();
        }
      case DeleteStatus.missing || DeleteStatus.failed:
        notify.error(loc.t('mods.snackbar.delete_failed_title'), body: mod.name, characterId: mod.characterId);
      case DeleteStatus.notTrashed:
        final title = loc.t('mods.delete.trash_failed_title');
        final body = loc.t('mods.delete.trash_failed_body', params: {'mod': mod.name});
        notify.error(
          title,
          body: body,
          characterId: mod.characterId,
          actions: [
            copyDetailsAction(loc, notify, title: title, body: body),
            if (outcome.trash == TrashResult.unavailable)
              NotificationAction(loc.t('mods.delete.for_good'), () async {
                if (!await askDeleteForGood(navigator.context, mod)) return;
                logConfirmation('mod.delete_for_good', accepted: true, subject: mod.id);
                await report(await ApiService.deleteMod(mod.id, deleteSnapshots: choice.deleteSnapshots, forGood: true));
              }),
          ],
        );
    }
  }

  try {
    // [work] shows the wait on the button that asked, after the question.
    await report(await work(() => ApiService.deleteMod(mod.id, deleteSnapshots: choice.deleteSnapshots)));
  } catch (e) {
    final title = loc.t('mods.errors.generic_title');
    notify.error(
      title,
      body: '$e',
      characterId: mod.characterId,
      actions: [copyDetailsAction(loc, notify, title: title, body: '$e')],
    );
  }
}

/// The second question, asked after the trash had no room for the mod: delete it from the disk, for good.
Future<bool> askDeleteForGood(BuildContext context, ModInfo mod) async =>
    await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final loc = dialogContext.loc;
        final palette = ZenithPalette.of(dialogContext);
        return ZenithDialog.compact(
          alert: true,
          width: 480,
          title: loc.t('mods.delete.for_good_title', params: {'mod': mod.name}),
          body: Text(
            loc.t('mods.delete.for_good_body'),
            style: Theme.of(dialogContext).textTheme.bodyMedium?.copyWith(color: palette.textProse, height: 1.6),
          ),
          actions: [
            TextButton(
              autofocus: true,
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(loc.t('mods.dialog.cancel')),
            ),
            FilledButton.icon(
              style: dangerButtonStyle(dialogContext),
              onPressed: () => Navigator.pop(dialogContext, true),
              icon: const Icon(Icons.delete_outline_rounded),
              label: Text(loc.t('mods.delete.for_good_confirm')),
            ),
          ],
        );
      },
    ) ??
    false;

/// The question before a delete: which mod, what happens to it, and whether its saved versions go too. Cancel has the
/// initial focus, so Enter on a dialog that has just opened never deletes.
class DeleteModDialog extends ConsumerStatefulWidget {
  const DeleteModDialog({super.key, required this.mod, this.savedVersions = 0, this.savedBytes = 0});

  final ModInfo mod;
  final int savedVersions;
  final int savedBytes;

  @override
  ConsumerState<DeleteModDialog> createState() => _DeleteModDialogState();
}

class _DeleteModDialogState extends ConsumerState<DeleteModDialog> {
  bool _deleteSnapshots = true;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final mod = widget.mod;
    final group = libraryGroupOf(mod.characterId);
    final character = libraryGroupName(group, loc);
    final size = ref.watch(modSizeProvider(mod.id)).valueOrNull?.bytes;
    final isAgent = characterById(group) != null;
    final body = [
      loc.t('mods.delete.body'),
      if (mod.isActive)
        isAgent
            ? loc.t('mods.delete.active_agent', params: {'character': character})
            : loc.t('mods.delete.active_other'),
    ].join(' ');
    return ZenithDialog.compact(
      alert: true,
      width: 480,
      leading: _CoverThumb(mod: mod),
      title: loc.t('mods.delete.title', params: {'mod': mod.name}),
      subtitle: size == null ? character : '$character · ${formatBytes(size)}',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 18,
        children: [
          Text(body, style: text.bodyMedium?.copyWith(color: palette.textProse, height: 1.6)),
          if (widget.savedVersions > 0)
            DeleteSnapshotsBox(
              label: loc.plural(
                'mods.delete.snapshots',
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
          label: Text(loc.t('mods.dialog.delete_confirm')),
        ),
      ],
    );
  }
}

/// The 64x44 cover the canvas puts before a dialog's title, or the character's dotted ground.
class _CoverThumb extends StatelessWidget {
  const _CoverThumb({required this.mod});

  final ModInfo mod;

  @override
  Widget build(BuildContext context) => Container(
    foregroundDecoration: BoxDecoration(
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: ZenithPalette.of(context).outline),
    ),
    child: ClipRRect(borderRadius: BorderRadius.circular(8), child: ModThumb(mod: mod, width: 64, height: 44)),
  );
}

/// "Also delete its N snapshots (size)", ticked by default. Shared by the single and the bulk delete.
class DeleteSnapshotsBox extends StatelessWidget {
  const DeleteSnapshotsBox({
    super.key,
    required this.label,
    required this.bytes,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final int bytes;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    final style = Theme.of(context).textTheme.bodyMedium;
    return MergeSemantics(
      child: InkWell(
        canRequestFocus: false,
        hoverColor: Colors.transparent,
        onTap: () => onChanged(!value),
        child: Row(
          spacing: 10,
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: Checkbox(value: value, onChanged: (next) => onChanged(next ?? false)),
            ),
            Expanded(
              child: Text.rich(
                TextSpan(
                  text: label,
                  style: style?.copyWith(color: palette.text),
                  children: [
                    TextSpan(
                      text: ' (${formatBytes(bytes)})',
                      style: style?.copyWith(color: palette.text3),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
