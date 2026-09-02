import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../../models/character_info.dart';
import '../../models/mod_download.dart';
import '../../services/patch_removal.dart';

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
  required VoidCallback onResolveOrigin,
  required VoidCallback onCheckForUpdate,
  required VoidCallback onReinstall,
  required VoidCallback onRestoreBackup,
  required VoidCallback onDelete,
  required void Function(ModDownload patch) onRemovePatch,
  /// Whether this mod has a pre-update snapshot to roll back to.
  ///
  /// Passed in rather than looked up here: the answer is one directory listing
  /// of `<appData>/backups` for the whole library, and doing it per right-click
  /// would be a filesystem call inside a menu builder. A permanently-present
  /// entry that usually opens an empty dialog was the alternative.
  bool hasBackups = false,

  /// Names for the patches in this folder, by mod id, used only when there is
  /// more than one to tell apart.
  ///
  /// **Nothing is fetched to fill this.** A companion records an id and never a
  /// title, and a menu builder is the last place to spend a request; the caller
  /// passes what the session already has and the entry falls back to the id.
  Map<int, String> patchNames = const <int, String>{},
}) {
  final loc = context.loc;
  final patches = removablePatches(mod.origin);
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
      // Offered only for a mod that can actually be looked up. A tracked mod
      // whose page is gone still qualifies — the check is what says so — but a
      // folder with no remote identity has nothing to check against, and the
      // entry below it is the one that fixes that.
      if (mod.origin?.hasIdentity ?? false)
        PopupMenuItem(
          child: Row(
            children: [
              const Icon(Icons.arrow_circle_up, size: 18),
              const SizedBox(width: 8),
              Text(loc.t('mods.context_menu.check_update')),
            ],
          ),
          onTap: () => Future.delayed(Duration.zero, onCheckForUpdate),
        ),
      // **Only for a folder that records the exact file it came from**, which
      // is what a repair fetches again. A mod known only by its page has no
      // version to put back — offering "reinstall" and then having to ask which
      // file would be an update in everything but name.
      if (mod.origin?.base?.fileId != null)
        PopupMenuItem(
          child: Row(
            children: [
              const Icon(Icons.restart_alt, size: 18),
              const SizedBox(width: 8),
              Text(loc.t('mods.context_menu.reinstall')),
            ],
          ),
          onTap: () => Future.delayed(Duration.zero, onReinstall),
        ),
      // Only where there is something to restore. A rollback is the recourse
      // for every loss the update path deliberately accepts, so it has to be
      // reachable from inside the app — but a mod that has never been updated
      // has nothing to offer.
      if (hasBackups)
        PopupMenuItem(
          child: Row(
            children: [
              const Icon(Icons.history, size: 18),
              const SizedBox(width: 8),
              Text(loc.t('mods.context_menu.restore_backup')),
            ],
          ),
          onTap: () => Future.delayed(Duration.zero, onRestoreBackup),
        ),
      // **Only for a patch this folder can actually take back out**, which
      // means one the app installed and recorded the files of. A patch merged in
      // by hand is recorded and checked for updates and still cannot be removed,
      // because nothing says which of the folder's files are its — so the entry
      // is absent rather than present and refusing.
      //
      // One entry per patch, named, for the folder that holds two: a single
      // "Remove patch…" would have to ask which, and the menu is the better
      // place to ask than a dialog opened from it.
      for (final patch in patches)
        PopupMenuItem(
          child: Row(
            children: [
              const Icon(Icons.layers_clear, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  patches.length > 1
                      ? loc.t('mods.context_menu.remove_patch_named', params: {
                          'patch': patchNames[patch.modId] ?? '#${patch.modId}',
                        })
                      : loc.t('mods.context_menu.remove_patch'),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          onTap: () =>
              Future.delayed(Duration.zero, () => onRemovePatch(patch)),
        ),
      // The second way into the resolve dialog. The status slot on the card is
      // the first, but it is absent for a mod whose origin is fully known — and
      // rebinding one that was resolved wrongly has to stay possible.
      PopupMenuItem(
        child: Row(
          children: [
            const Icon(Icons.sync_alt, size: 18),
            const SizedBox(width: 8),
            Text(loc.t('mods.context_menu.resolve_origin')),
          ],
        ),
        onTap: () => Future.delayed(Duration.zero, onResolveOrigin),
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
