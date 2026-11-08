import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../../models/character_info.dart';
import '../../models/mod_download.dart';
import '../../models/mod_origin.dart';
import '../../models/origin_enums.dart';
import '../../services/patch_removal.dart';
import '../../utils/categories.dart';
import '../components/character_tile.dart' show libraryGroupName;
import '../components/folder_downloads_summary.dart' show layerLine, sharedPageFile;
import '../components/zenith_menu.dart';
import 'reinstall_flow.dart' show canReinstall;

/// What each entry of a mod's right-click menu does. The caller builds it once; the menu only decides which entries
/// to show.
class ModMenuActions {
  const ModMenuActions({
    required this.toggle,
    required this.toggleFavorite,
    required this.edit,
    required this.openFolder,
    required this.checkForUpdate,
    required this.reinstall,
    required this.updateTracking,
    required this.removePatch,
    required this.delete,
    this.makePatch,
  });

  final VoidCallback toggle;
  final VoidCallback toggleFavorite;
  final VoidCallback edit;
  final VoidCallback openFolder;
  final VoidCallback checkForUpdate;
  final VoidCallback reinstall;
  final VoidCallback updateTracking;
  final void Function(ModDownload patch) removePatch;
  final VoidCallback delete;

  /// Turns the mod into a patch of another. Null hides the entry.
  final VoidCallback? makePatch;
}

/// The right-click menu for a mod, opened at [position] or under its ⋯ button.
///
/// Space, F, E and Del act on the mod while the menu is open, whichever row is hot (`docs/library-screen.md` §5).
void showModContextMenu(
  BuildContext context,
  ModInfo mod,
  Offset position,
  ModMenuActions actions, {
  /// Names for the patches in this folder, by mod id, used only when there is more than one to tell apart.
  /// Nothing is fetched to fill this: the entry falls back to the id.
  Map<int, String> patchNames = const <int, String>{},
}) {
  final loc = context.loc;
  final origin = mod.origin;
  final patches = removablePatches(origin);
  final character = libraryGroupName(libraryGroupOf(mod.characterId), loc);
  final subtitle = switch (origin) {
    ModOrigin(tracking: OriginTracking.off) => loc.t('mods.menu.sub_local', params: {'character': character}),
    ModOrigin(hasIdentity: true) => loc.t('mods.menu.sub_tracked', params: {'character': character}),
    _ => loc.t('mods.menu.sub_untracked', params: {'character': character}),
  };
  showZenithMenu(
    context,
    title: mod.name,
    subtitle: subtitle,
    position: position,
    items: [
      ZenithMenuEntry(
        label: loc.t(mod.isActive ? 'mods.menu.turn_off' : 'mods.menu.turn_on'),
        icon: mod.isActive ? Icons.close_rounded : Icons.check_rounded,
        shortcut: 'Space',
        accelerator: LogicalKeyboardKey.space,
        onSelected: actions.toggle,
      ),
      ZenithMenuEntry(
        label: loc.t(mod.isFavorite ? 'mods.context_menu.favorite_remove' : 'mods.context_menu.favorite_add'),
        icon: mod.isFavorite ? Icons.star_rounded : Icons.star_border_rounded,
        shortcut: 'F',
        accelerator: LogicalKeyboardKey.keyF,
        onSelected: actions.toggleFavorite,
      ),
      const ZenithMenuSeparator(),
      ZenithMenuEntry(
        label: loc.t('mods.menu.edit_info'),
        icon: Icons.edit_outlined,
        shortcut: 'E',
        accelerator: LogicalKeyboardKey.keyE,
        onSelected: actions.edit,
      ),
      ZenithMenuEntry(
        label: loc.t('mods.context_menu.open_folder'),
        icon: Icons.folder_open_outlined,
        onSelected: actions.openFolder,
      ),
      const ZenithMenuSeparator(),
      // A folder with no remote identity has nothing to check against; Update tracking is the entry that fixes that.
      if (origin?.hasIdentity ?? false)
        ZenithMenuEntry(
          label: loc.t('mods.menu.check_updates'),
          icon: Icons.refresh_rounded,
          onSelected: actions.checkForUpdate,
        ),
      // Only for a folder that records the file it came from, which is what a reinstall fetches again.
      if (canReinstall(mod))
        ZenithMenuEntry(
          label: loc.t('mods.menu.reinstall'),
          icon: Icons.download_rounded,
          onSelected: actions.reinstall,
        ),
      ZenithMenuEntry(
        label: loc.t('mods.context_menu.resolve_origin'),
        icon: Icons.link_rounded,
        onSelected: actions.updateTracking,
      ),
      if (actions.makePatch case final makePatch?)
        ZenithMenuEntry(label: loc.t('mods.menu.make_patch'), icon: Icons.layers_outlined, onSelected: makePatch),
      // Only a patch this folder can take back out, which is one the app installed and recorded the files of; one
      // entry per patch, named when there are several.
      for (final patch in patches)
        ZenithMenuEntry(
          label: patches.length > 1
              ? loc.t(
                  'mods.context_menu.remove_patch_named',
                  params: {
                    // "<page> · <file>" for a patch from its base's own page.
                    'patch': layerLine(patchNames[patch.modId] ?? '#${patch.modId}', sharedPageFile(origin, patch)),
                  },
                )
              : loc.t('mods.context_menu.remove_patch'),
          icon: Icons.layers_clear_outlined,
          onSelected: () => actions.removePatch(patch),
        ),
      const ZenithMenuSeparator(),
      ZenithMenuEntry(
        label: loc.t('mods.menu.delete'),
        icon: Icons.delete_outline_rounded,
        shortcut: 'Del',
        accelerator: LogicalKeyboardKey.delete,
        danger: true,
        onSelected: actions.delete,
      ),
    ],
  );
}
