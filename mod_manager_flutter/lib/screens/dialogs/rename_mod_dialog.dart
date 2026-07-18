import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../l10n/app_localizations.dart';
import '../../models/character_info.dart';
import '../../services/api_service.dart';
import '../../utils/state_providers.dart';

/// Renames a mod (its on-disk folder). Live-validates the new name and
/// delegates to [ApiService.renameMod], which also migrates the active link
/// and the mod's active/favorite/category state. [onRenamed] runs after a
/// successful rename with the new folder name so the caller can update its list.
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
    for (final c in ref.read(charactersProvider))
      for (final m in c.skins) m.id.toLowerCase(),
  }..remove(mod.id.toLowerCase());
  final messenger = ScaffoldMessenger.of(context);

  return showDialog(
    context: context,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (dialogContext, setLocal) {
          final name = controller.text.trim();
          String? error;
          if (name.isNotEmpty && name != mod.name) {
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
            Navigator.pop(dialogContext);
            try {
              final ok = await ApiService.renameMod(mod.id, name);
              if (!context.mounted) return;
              if (ok) {
                messenger.showSnackBar(
                  SnackBar(
                    content: Text(loc.t('mods.snackbar.renamed')),
                    duration: const Duration(seconds: 1),
                  ),
                );
                onRenamed(name);
              } else {
                messenger.showSnackBar(
                  SnackBar(
                    content: Text(loc.t('mods.dialog.rename_exists')),
                    backgroundColor: Colors.red,
                  ),
                );
              }
            } catch (e) {
              if (!context.mounted) return;
              messenger.showSnackBar(
                SnackBar(
                  content: Text(
                    loc.t(
                      'mods.errors.generic',
                      params: {'message': e.toString()},
                    ),
                  ),
                  backgroundColor: Colors.red,
                ),
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
                    style: const TextStyle(fontSize: 18),
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
    },
  );
}
