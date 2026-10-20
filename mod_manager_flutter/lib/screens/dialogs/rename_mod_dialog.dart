import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../l10n/app_localizations.dart';
import '../../models/character_info.dart';
import '../../services/api_service.dart';
import '../../services/mod_manager_service.dart' show RenameFolderFailed, RenameLinkFailed, RenameRefused;
import '../../utils/notifications.dart';
import '../../utils/state_providers.dart';

/// Renames a mod (its on-disk folder). Live-validates the new name and
/// delegates to [ApiService.renameMod], which also migrates the active link
/// and the mod's active/favorite/category state. [onRenamed] runs with the new folder name whenever the folder has it,
/// so the caller can update its list.
///
/// Refused while the mod's folder is being written ([modWritesInProgressProvider]), such as by an update or a restore.
Future<void> showRenameModDialog(
  BuildContext context,
  WidgetRef ref,
  ModInfo mod, {
  required void Function(String newName) onRenamed,
}) {
  final loc = context.loc;
  final controller = TextEditingController(text: mod.name);
  // Existing mod names (lowercased) for a live collision check; the service
  // re-checks authoritatively.
  final existingLower = <String>{
    for (final m in ref.read(modsProvider)) m.id.toLowerCase(),
  }..remove(mod.id.toLowerCase());
  final notify = context.notify;

  return showDialog(
    context: context,
    builder: (dialogContext) => Consumer(builder: (dialogContext, dialogRef, _) {
      final writing = dialogRef.watch(modWritesInProgressProvider).contains(mod.id);
      return StatefulBuilder(
        builder: (dialogContext, setLocal) {
          final name = controller.text.trim();
          String? error;
          if (writing) {
            error = loc.t('mods.dialog.rename_busy', params: {'name': mod.name});
          } else if (name.isNotEmpty && name != mod.name) {
            if (RegExp(r'[\\/<>:"|?*]').hasMatch(name) ||
                name.startsWith('.') ||
                name.startsWith('__')) {
              error = loc.t('mods.dialog.rename_invalid');
            } else if (existingLower.contains(name.toLowerCase())) {
              error = loc.t('mods.dialog.rename_exists');
            }
          }
          final canRename =
              name.isNotEmpty && name != mod.name && error == null;

          Future<void> submit() async {
            // A write may have started since the dialog was last built.
            if (dialogRef.read(modWritesInProgressProvider).contains(mod.id)) return;
            Navigator.pop(dialogContext);
            try {
              final ok = await ApiService.renameMod(mod.id, name);
              if (!context.mounted) return;
              if (ok) {
                onRenamed(name);
              } else {
                notify.error(
                  loc.t('mods.dialog.rename_failed_title'),
                  body: loc.t('mods.dialog.rename_exists'),
                  characterId: mod.characterId,
                );
              }
            } on RenameRefused catch (refusal) {
              if (!context.mounted) return;
              notify.error(
                loc.t('mods.dialog.rename_failed_title'),
                body: loc.t('mods.dialog.rename_link_taken', params: {'name': refusal.name}),
                characterId: mod.characterId,
              );
            } on RenameFolderFailed {
              if (!context.mounted) return;
              notify.error(
                loc.t('mods.dialog.rename_failed_title'),
                body: loc.t('mods.dialog.rename_folder_failed', params: {'name': mod.name}),
                characterId: mod.characterId,
              );
            } on RenameLinkFailed catch (failure) {
              if (!context.mounted) return;
              if (failure.renamed) {
                // The folder has its new name, so the tick and the selection follow it; the mod is off, so the page
                // reads the disk again.
                onRenamed(failure.name);
                unawaited(ref.read(libraryProvider.notifier).rescan());
                notify.warning(
                  loc.t('mods.dialog.rename_left_off_title'),
                  body: loc.t('mods.dialog.rename_left_off_body', params: {'name': failure.name}),
                  characterId: mod.characterId,
                  // The mod won't load until the user turns it back on.
                  stays: true,
                );
              } else {
                notify.error(
                  loc.t('mods.dialog.rename_failed_title'),
                  body: loc.t('mods.dialog.rename_link_failed', params: {'name': mod.name}),
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
                const Icon(Icons.drive_file_rename_outline, size: 24),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    loc.t('mods.dialog.rename_title'),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
              ],
            ),
            content: SizedBox(
              width: 380,
              child: TextField(
                controller: controller,
                autofocus: true,
                onChanged: (_) => setLocal(() {}),
                onSubmitted: canRename ? (_) => submit() : null,
                decoration: InputDecoration(
                  labelText: loc.t('mods.dialog.rename_label'),
                  errorText: error,
                  errorMaxLines: 3,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: Text(loc.t('mods.dialog.cancel')),
              ),
              FilledButton(
                onPressed: canRename ? submit : null,
                child: Text(loc.t('mods.dialog.rename_confirm')),
              ),
            ],
          );
        },
      );
    }),
  );
}
