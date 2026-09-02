import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../../models/character_info.dart';
import '../../services/api_service.dart';
import '../../services/log/confirmations.dart';
import '../../utils/notifications.dart';

/// Confirms and permanently deletes a mod (its folder and all state). The
/// action is irreversible, so it requires an explicit confirmation. [onDeleted]
/// runs after a successful delete so the caller can refresh its list.
///
/// [savedVersions] is how many snapshots go with it, which the delete does and
/// which the user has no other way to find out. Stated only when there are any:
/// a sentence about saved versions in front of a mod that has none is noise,
/// and an alarming kind.
Future<void> showDeleteModDialog(
  BuildContext context,
  ModInfo mod, {
  required VoidCallback onDeleted,
  int savedVersions = 0,
}) {
  final loc = context.loc;
  final notify = context.notify;
  return showDialog(
    context: context,
    builder: (dialogContext) {
      Future<void> confirm() async {
        Navigator.pop(dialogContext);
        // The most destructive thing in the app, and the one a user is most
        // likely to ask about afterwards.
        logConfirmation('mod.delete', accepted: true, subject: mod.id);
        try {
          final ok = await ApiService.deleteMod(mod.id);
          if (!context.mounted) return;
          if (ok) {
            onDeleted();
          } else {
            notify.error(
              loc.t('mods.snackbar.delete_failed_title'),
              body: mod.name,
              characterId: mod.characterId,
            );
          }
        } catch (e) {
          if (!context.mounted) return;
          notify.error(
            loc.t('mods.errors.generic_title'),
            body: e.toString(),
            characterId: mod.characterId,
          );
        }
      }

      return AlertDialog(
        title: Row(
          children: [
            const Icon(
              Icons.warning_amber_rounded,
              size: 24,
              color: Colors.red,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                loc.t('mods.dialog.delete_title'),
                style: const TextStyle(fontSize: 18),
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: 380,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                loc.t('mods.dialog.delete_message', params: {'mod': mod.name}),
              ),
              if (savedVersions > 0) ...[
                const SizedBox(height: 10),
                Text(
                  loc.plural(
                    'mods.dialog.delete_saved',
                    savedVersions,
                    params: {'count': '$savedVersions'},
                  ),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(loc.t('mods.dialog.cancel')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: confirm,
            child: Text(loc.t('mods.dialog.delete_confirm')),
          ),
        ],
      );
    },
  );
}
