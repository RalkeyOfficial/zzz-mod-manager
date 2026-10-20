import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/palette.dart';
import '../../core/type_scale.dart';
import '../../l10n/app_localizations.dart';
import '../../models/character_info.dart';
import '../../models/origin_enums.dart';
import '../../services/cover_thumbnail.dart';
import '../../services/installed_record.dart';
import '../../services/platform_service_factory.dart';
import '../../utils/home_relative.dart';
import '../../utils/notifications.dart';
import '../../utils/state_providers.dart';
import '../../utils/url_utils.dart';
import '../../utils/zzz_characters.dart';
import 'character_tile.dart';
import 'mod_detail_parts.dart';
import 'shader_part_summary.dart';
import 'zenith_controls.dart';

export 'mod_detail_parts.dart' show NoteWriter;

/// The column beside a character's mods that shows the selected one: its pictures and text, whether it is on, its
/// in-game keys, where it came from, where it lives, and the user's note on it.
///
/// It reads what the app already has and **never fetches**: a mod selected in passing should not spend a request
/// the user did not ask for. The file name, upload date and author appear once this session holds the mod page,
/// from a check, an install or the mod's own page in the Library.
class ModDetailsPanel extends ConsumerWidget {
  const ModDetailsPanel({
    super.key,
    required this.mod,
    required this.onClose,
    required this.onOpenPage,
    required this.onToggle,
    required this.onFavoriteToggle,
    required this.onEdit,
    required this.onOpenFolder,
    required this.onCheckForUpdate,
    required this.onResolveOrigin,
    required this.onDelete,
    this.noteWriter,
    this.width = ModDetailsPanel.defaultWidth,
  });

  static const double defaultWidth = 340;

  /// [defaultWidth], or the page's width when the window is narrower than that.
  final double width;

  final ModInfo mod;
  final VoidCallback onClose;

  /// Opens the mod's page in the Library on [ModPageTab].
  final ValueChanged<ModPageTab> onOpenPage;

  /// Null while the switch can't be pressed.
  final VoidCallback? onToggle;
  final VoidCallback onFavoriteToggle;
  final VoidCallback onEdit;
  final VoidCallback onOpenFolder;
  final VoidCallback onCheckForUpdate;
  final VoidCallback onResolveOrigin;
  final VoidCallback onDelete;
  final NoteWriter? noteWriter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final (:page, file: _) = installedRecord(mod, ref.watch(knownModPagesProvider));
    final author = page?.submitter?.name;
    final keys = modKeyRows(mod);

    return Container(
      width: width,
      decoration: BoxDecoration(
        color: palette.panel,
        border: Border(left: BorderSide(color: palette.divider)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(18, 12, 14, 12),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: palette.divider))),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    loc.t('library.details.heading').toUpperCase(),
                    style: ZenithType.of(context).caps.copyWith(color: palette.text3),
                  ),
                ),
                IconButton(
                  style: smallButtonStyle(context, iconOnly: true),
                  tooltip: loc.t(mod.isFavorite ? 'mods.context_menu.favorite_remove' : 'mods.context_menu.favorite_add'),
                  isSelected: mod.isFavorite,
                  onPressed: onFavoriteToggle,
                  icon: const Icon(Icons.star_outline_rounded),
                  selectedIcon: const Icon(Icons.star_rounded),
                ),
                TextButton.icon(
                  style: smallButtonStyle(context),
                  onPressed: onEdit,
                  icon: const Icon(Icons.edit_outlined),
                  label: Text(loc.t('library.details.edit_info')),
                ),
                IconButton(
                  style: smallButtonStyle(context, iconOnly: true),
                  tooltip: loc.t('library.details.open_page'),
                  onPressed: () => onOpenPage(ModPageTab.overview),
                  icon: const Icon(Icons.open_in_full_rounded),
                ),
                IconButton(
                  style: smallButtonStyle(context, iconOnly: true),
                  tooltip: loc.t('library.details.close'),
                  onPressed: onClose,
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 20),
              children: [
                _Gallery(key: ValueKey('gallery_${mod.id}'), mod: mod),
                const SizedBox(height: 18),
                Text(mod.name, style: text.titleLarge?.copyWith(color: palette.text)),
                if (author != null) ...[
                  const SizedBox(height: 6),
                  authorLine(
                    context,
                    template: loc.t('library.details.by'),
                    author: author,
                    onTap: () => openModLink(context, mod),
                  ),
                ],
                if (mod.description?.trim().isNotEmpty ?? false) ...[
                  const SizedBox(height: 10),
                  ModDescription(key: ValueKey('description_${mod.id}'), text: mod.description!),
                ],
                if (mod.tags.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [for (final tag in mod.tags) ZenithBadge(label: tag, tone: palette.badgeNeutral)],
                  ),
                ],
                const SizedBox(height: 18),
                ModActiveBox(mod: mod, onToggle: onToggle),
                if (keys.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  ModKeysList(keys: keys),
                ],
                ShaderPartSummary(folderName: mod.name),
                if ((mod.origin?.downloads.length ?? 0) > 1) ...[
                  const SizedBox(height: 18),
                  ModMadeOf(mod: mod, onManageHistory: () => onOpenPage(ModPageTab.history)),
                ],
                const SizedBox(height: 18),
                ModFacts(mod: mod, onResolveOrigin: onResolveOrigin),
                const SizedBox(height: 12),
                _PathButton(mod: mod),
                const SizedBox(height: 18),
                ModNoteField(
                  key: ValueKey('note_${mod.id}'),
                  modId: mod.id,
                  characterId: mod.characterId,
                  writer: noteWriter,
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
            decoration: BoxDecoration(border: Border(top: BorderSide(color: palette.divider))),
            child: Row(
              spacing: 8,
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onOpenFolder,
                    icon: const Icon(Icons.folder_outlined),
                    label: Text(loc.t('library.details.open_folder')),
                  ),
                ),
                Tooltip(
                  message: loc.t('library.details.check_update'),
                  child: OutlinedButton(
                    style: const ButtonStyle(
                      fixedSize: WidgetStatePropertyAll(Size(36, 36)),
                      minimumSize: WidgetStatePropertyAll(Size(36, 36)),
                      padding: WidgetStatePropertyAll(EdgeInsets.zero),
                    ),
                    onPressed: canCheckForUpdate(mod) ? onCheckForUpdate : null,
                    child: const Icon(Icons.sync_rounded),
                  ),
                ),
                Tooltip(
                  message: loc.t('library.details.delete'),
                  child: OutlinedButton(
                    style: ButtonStyle(
                      fixedSize: const WidgetStatePropertyAll(Size(36, 36)),
                      minimumSize: const WidgetStatePropertyAll(Size(36, 36)),
                      padding: const WidgetStatePropertyAll(EdgeInsets.zero),
                      foregroundColor: WidgetStatePropertyAll(palette.redText),
                    ),
                    onPressed: onDelete,
                    child: const Icon(Icons.delete_outline_rounded),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Whether there is a mod page to ask: without one the update dialog would say "not tracked" and nothing else. Never
/// for a mod marked Local, which is not checked.
bool canCheckForUpdate(ModInfo mod) =>
    (mod.origin?.hasIdentity ?? false) && mod.origin?.tracking != OriginTracking.off;

/// The cover large, and the rest of the gallery as thumbnails under it. A mod with no pictures shows its
/// character's dotted ground.
class _Gallery extends StatefulWidget {
  const _Gallery({super.key, required this.mod});

  final ModInfo mod;

  @override
  State<_Gallery> createState() => _GalleryState();
}

class _GalleryState extends State<_Gallery> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    final images = widget.mod.images;
    final ground = palette.groundFor(elementToneOf(widget.mod.characterId));
    final index = _index.clamp(0, images.isEmpty ? 0 : images.length - 1);

    Widget frame(Widget child, {double radius = 10, bool current = false, double opacity = 1}) => Opacity(
      opacity: opacity,
      child: Container(
        clipBehavior: Clip.antiAlias,
        foregroundDecoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: current ? palette.accent : palette.outline, width: current ? 2 : 1),
        ),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(radius)),
        child: child,
      ),
    );

    if (images.isEmpty) {
      return AspectRatio(
        aspectRatio: 16 / 10,
        child: frame(
          DottedGround(
            ground: ground,
            child: Center(
              child: OutlinedInitials(
                nameInitials(widget.mod.name),
                style: ZenithType.of(context).watermark,
                color: ground.stroke,
              ),
            ),
          ),
        ),
      );
    }

    Widget picture(String path, {int? decodeWidth}) => Image.file(
      File(path),
      fit: BoxFit.cover,
      cacheWidth: decodeWidth,
      gaplessPlayback: true,
      errorBuilder: (_, __, ___) => DottedGround(ground: ground),
    );

    return Column(
      spacing: 6,
      children: [
        AspectRatio(
          aspectRatio: 16 / 10,
          child: MouseRegion(
            cursor: SystemMouseCursors.zoomIn,
            child: GestureDetector(
              onTap: () => showImageLightbox(context, images[index]),
              child: frame(picture(images[index], decodeWidth: 720)),
            ),
          ),
        ),
        if (images.length > 1)
          GridView.count(
            crossAxisCount: 4,
            mainAxisSpacing: 6,
            crossAxisSpacing: 6,
            childAspectRatio: 16 / 10,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              for (var i = 0; i < images.length; i++)
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: () => setState(() => _index = i),
                    child: frame(
                      picture((coverFileFor(images[i]) ?? File(images[i])).path, decodeWidth: 160),
                      radius: 6,
                      current: i == index,
                      opacity: i == index ? 1 : 0.6,
                    ),
                  ),
                ),
            ],
          ),
      ],
    );
  }
}

/// The mod's folder, shortened to `~` inside the home folder as the status bar shortens it. Pressing it copies the
/// full path.
class _PathButton extends ConsumerWidget {
  const _PathButton({required this.mod});

  final ModInfo mod;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final library = ref.watch(modsPathProvider);
    if (library.isEmpty) return const SizedBox.shrink();
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final folder = p.join(library, mod.id);
    return Tooltip(
      message: loc.t('library.details.copy_path'),
      child: Material(
        color: palette.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: palette.outline),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () async {
            await Clipboard.setData(ClipboardData(text: folder));
            // The clipboard can't be seen, so its success is worth saying.
            if (context.mounted) {
              context.notify.done(loc.t('library.details.path_copied_title'), body: folder, characterId: mod.characterId);
            }
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Text(
              homeRelative(folder, home: PlatformServiceFactory.getInstance().homeDirectoryPath),
              style: ZenithType.of(context).monoSmall.copyWith(color: palette.text2, height: 1.4),
            ),
          ),
        ),
      ),
    );
  }
}
