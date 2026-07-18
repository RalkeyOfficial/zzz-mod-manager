import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../../models/character_info.dart';

/// The right-click menu for a mod card. A thin dispatcher: each entry runs the
/// matching callback (deferred so the menu closes first). The caller wires the
/// callbacks to the actual actions/dialogs.
void showModContextMenu(
  BuildContext context,
  ModInfo mod,
  Offset position, {
  required VoidCallback onDetails,
  required VoidCallback onEdit,
  required VoidCallback onRename,
  required VoidCallback onOpenFolder,
  required VoidCallback onOpenLink,
  required VoidCallback onEditKeybinds,
  required VoidCallback onToggleFavorite,
  required VoidCallback onDelete,
}) {
  final loc = context.loc;
  showMenu(
    context: context,
    position: RelativeRect.fromLTRB(
      position.dx,
      position.dy,
      position.dx,
      position.dy,
    ),
    items: [
      PopupMenuItem(
        child: Row(
          children: [
            const Icon(Icons.info_outline, size: 18),
            const SizedBox(width: 8),
            Text(loc.t('mods.context_menu.details')),
          ],
        ),
        onTap: () => Future.delayed(Duration.zero, onDetails),
      ),
      PopupMenuItem(
        child: Row(
          children: [
            const Icon(Icons.edit, size: 18),
            const SizedBox(width: 8),
            Text(loc.t('mods.context_menu.edit')),
          ],
        ),
        onTap: () => Future.delayed(Duration.zero, onEdit),
      ),
      PopupMenuItem(
        child: Row(
          children: [
            const Icon(Icons.drive_file_rename_outline, size: 18),
            const SizedBox(width: 8),
            Text(loc.t('mods.context_menu.rename')),
          ],
        ),
        onTap: () => Future.delayed(Duration.zero, onRename),
      ),
      PopupMenuItem(
        child: Row(
          children: [
            const Icon(Icons.folder_open, size: 18),
            const SizedBox(width: 8),
            Text(loc.t('mods.context_menu.open_folder')),
          ],
        ),
        onTap: () => Future.delayed(Duration.zero, onOpenFolder),
      ),
      // Відкрити сторінку джерела, якщо вказано посилання
      if (mod.sourceUrl != null && mod.sourceUrl!.isNotEmpty)
        PopupMenuItem(
          child: Row(
            children: [
              const Icon(Icons.open_in_new, size: 18),
              const SizedBox(width: 8),
              Text(loc.t('mods.context_menu.open_link')),
            ],
          ),
          onTap: () => Future.delayed(Duration.zero, onOpenLink),
        ),
      // Показати keybinds якщо є
      if (mod.keybinds != null && mod.keybinds!.isNotEmpty)
        PopupMenuItem(
          child: Row(
            children: [
              const Icon(Icons.keyboard_outlined, size: 18),
              const SizedBox(width: 8),
              Text(
                loc.t(
                  'mods.context_menu.edit_keybinds',
                  params: {'count': '${mod.keybinds!.length}'},
                ),
              ),
            ],
          ),
          onTap: () => Future.delayed(Duration.zero, onEditKeybinds),
        ),
      PopupMenuItem(
        child: Row(
          children: [
            Icon(mod.isFavorite ? Icons.star : Icons.star_border, size: 18),
            const SizedBox(width: 8),
            Text(
              mod.isFavorite
                  ? loc.t('mods.context_menu.favorite_remove')
                  : loc.t('mods.context_menu.favorite_add'),
            ),
          ],
        ),
        onTap: () => Future.delayed(Duration.zero, onToggleFavorite),
      ),
      PopupMenuItem(
        child: Row(
          children: [
            const Icon(Icons.delete_outline, size: 18, color: Colors.red),
            const SizedBox(width: 8),
            Text(
              loc.t('mods.context_menu.delete'),
              style: const TextStyle(color: Colors.red),
            ),
          ],
        ),
        onTap: () => Future.delayed(Duration.zero, onDelete),
      ),
    ],
  );
}
