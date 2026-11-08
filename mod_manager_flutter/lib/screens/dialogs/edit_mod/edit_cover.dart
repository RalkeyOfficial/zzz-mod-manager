import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../core/palette.dart';
import '../../../core/type_scale.dart';
import '../../../l10n/app_localizations.dart';
import '../../../models/character_info.dart';
import '../../../models/edit_image.dart';
import '../../../models/origin_enums.dart';
import '../../../services/gamebanana/file_selection.dart';
import '../../../services/installed_record.dart';
import '../../../utils/state_providers.dart';
import '../../../utils/zzz_characters.dart';
import '../../components/character_tile.dart' show elementToneOf;
import '../../components/resolve/resolve_fragments.dart' show formatResolveDate;
import '../../components/zenith_controls.dart';
import '../../shell/keycap.dart' show placeholderSentence;

/// The file extensions a dropped file may have to be taken as a picture.
const Set<String> _imageExtensions = {'.png', '.jpg', '.jpeg', '.webp', '.gif', '.bmp'};

/// The image files among [paths], for a drop.
List<EditImage> droppedImages(Iterable<String> paths) => [
  for (final path in paths)
    if (_imageExtensions.contains(p.extension(path).toLowerCase())) EditImage.picked(path),
];

/// The Cover part of Edit info: the cover at 4:3, a grid of every picture with the cover outlined, and a cell that
/// opens the file picker. Pictures can also be dropped on it ([onDrop]).
class EditCover extends StatelessWidget {
  const EditCover({
    super.key,
    required this.modName,
    required this.characterId,
    required this.images,
    required this.onPick,
    required this.onSetCover,
    required this.onRemove,
    required this.onDrop,
    required this.focusNode,
  });

  /// Taken when the pointer goes down anywhere on the cover, so Ctrl+V there pastes a picture rather than text into
  /// the field that had the focus.
  final FocusNode focusNode;

  final String modName;
  final String characterId;
  final List<EditImage> images;
  final VoidCallback onPick;
  final ValueChanged<EditImage> onSetCover;
  final ValueChanged<EditImage> onRemove;
  final ValueChanged<List<EditImage>> onDrop;

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: focusNode,
      skipTraversal: true,
      child: Semantics(
        explicitChildNodes: true,
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (_) => focusNode.requestFocus(),
          child: DropTarget(
            onDragDone: (details) => onDrop(droppedImages([for (final file in details.files) file.path])),
            child: _body(context),
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final palette = ZenithPalette.of(context);
    final loc = context.loc;
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 6,
      children: [
        Text(
          loc.t('mods.edit.cover'),
          style: text.labelMedium?.copyWith(fontWeight: FontWeight.w600, color: palette.textProse),
        ),
        AspectRatio(
          aspectRatio: 4 / 3,
          child: DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: palette.outline),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: images.isEmpty ? _empty(context) : _EditImageView(images.first, cacheWidth: 480),
            ),
          ),
        ),
        LayoutBuilder(
          builder: (context, constraints) {
            const gap = 6.0;
            final cell = (constraints.maxWidth - gap * 3) / 4;
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (final (i, image) in images.indexed)
                  SizedBox(
                    width: cell,
                    height: cell,
                    child: _Thumb(
                      image: image,
                      number: i + 1,
                      isCover: i == 0,
                      onSetCover: () => onSetCover(image),
                      onRemove: () => onRemove(image),
                    ),
                  ),
                SizedBox(
                  width: cell,
                  height: cell,
                  child: Semantics(
                    button: true,
                    label: loc.t('mods.edit.cover_add'),
                    excludeSemantics: true,
                    onTap: onPick,
                    child: Tooltip(
                      message: loc.t('mods.edit.cover_add'),
                      child: DashedBox(
                        color: palette.edge,
                        radius: 6,
                        width: 1,
                        child: Material(
                          color: Colors.transparent,
                          borderRadius: BorderRadius.circular(6),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(6),
                            onTap: onPick,
                            child: Center(child: Icon(Icons.add_rounded, color: palette.text2)),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
        Text(loc.t('mods.edit.cover_hint'), style: text.bodySmall?.copyWith(color: palette.text3)),
      ],
    );
  }

  Widget _empty(BuildContext context) {
    final palette = ZenithPalette.of(context);
    final ground = palette.groundFor(elementToneOf(characterId));
    return DottedGround(
      ground: ground,
      child: Center(
        child: OutlinedInitials(nameInitials(modName), style: ZenithType.of(context).watermark, color: ground.stroke),
      ),
    );
  }
}

/// A staged picture: a file in the mod folder, a file picked, or pasted bytes.
class _EditImageView extends StatelessWidget {
  const _EditImageView(this.image, {required this.cacheWidth});

  final EditImage image;
  final int cacheWidth;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    Widget broken(BuildContext _, Object _, StackTrace? _) => ColoredBox(
      color: palette.chip,
      child: Center(child: Icon(Icons.broken_image_outlined, color: palette.text3)),
    );
    final bytes = image.pastedBytes;
    if (bytes != null) {
      return Image.memory(bytes, fit: BoxFit.cover, cacheWidth: cacheWidth, errorBuilder: broken);
    }
    return Image.file(
      File(image.existingPath ?? image.pickedPath!),
      fit: BoxFit.cover,
      cacheWidth: cacheWidth,
      errorBuilder: broken,
    );
  }
}

/// One square of the grid. The cover is outlined in the accent; the others are dimmed and make themselves the cover
/// when pressed. A × shows on hover and while focus is inside, and takes the picture out.
class _Thumb extends StatefulWidget {
  const _Thumb({
    required this.image,
    required this.number,
    required this.isCover,
    required this.onSetCover,
    required this.onRemove,
  });

  final EditImage image;
  final int number;
  final bool isCover;
  final VoidCallback onSetCover;
  final VoidCallback onRemove;

  @override
  State<_Thumb> createState() => _ThumbState();
}

class _ThumbState extends State<_Thumb> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    final loc = context.loc;
    final params = {'n': '${widget.number}'};
    final showRemove = _hovered || _focused;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (focused) => setState(() => _focused = focused),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Semantics(
              button: true,
              selected: widget.isCover,
              label: loc.t('mods.edit.cover_use', params: params),
              excludeSemantics: true,
              onTap: widget.isCover ? null : widget.onSetCover,
              child: Opacity(
                opacity: widget.isCover ? 1 : 0.55,
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: widget.isCover ? null : widget.onSetCover,
                    child: DecoratedBox(
                      position: DecorationPosition.foreground,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(6),
                        border: widget.isCover ? Border.all(color: palette.accent, width: 2) : null,
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: _EditImageView(widget.image, cacheWidth: 128),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (showRemove)
              Positioned(
                top: 3,
                right: 3,
                child: Semantics(
                  button: true,
                  label: loc.t('mods.edit.cover_remove', params: params),
                  excludeSemantics: true,
                  onTap: widget.onRemove,
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: Material(
                      color: palette.ground.withValues(alpha: 0.8),
                      borderRadius: BorderRadius.circular(4),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(4),
                        onTap: widget.onRemove,
                        child: Icon(Icons.close_rounded, size: 12, color: palette.text),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Tracking: where the mod is checked for updates, read from what the mod and the session hold. Its link opens the
/// tracking screen.
class EditTrackingBox extends ConsumerWidget {
  const EditTrackingBox({super.key, required this.mod, required this.onUpdateTracking});

  final ModInfo mod;
  final VoidCallback onUpdateTracking;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = ZenithPalette.of(context);
    final loc = context.loc;
    final text = Theme.of(context).textTheme;
    final type = ZenithType.of(context);
    final origin = mod.origin;
    final (:page, :file) = installedRecord(mod, ref.watch(knownModPagesProvider));
    final named = (origin?.base?.versionConfidence.namesFile ?? false) && file != null;
    final small = text.bodySmall?.copyWith(color: palette.text3);

    final String title;
    final List<InlineSpan> body;
    if (origin?.tracking == OriginTracking.off) {
      title = loc.t('mods.edit.tracking_local_title');
      body = [TextSpan(text: loc.t('mods.edit.tracking_local_body'))];
    } else if (origin?.hasIdentity ?? false) {
      title = loc.t('mods.edit.tracking_name');
      final date = named ? file.dateAdded : null;
      body = named && date != null
          ? placeholderSentence(loc.t('mods.edit.tracking_file'), {
              'file': TextSpan(
                text: fileDisplayName(file),
                style: type.mono.copyWith(color: palette.text3),
              ),
              'date': TextSpan(text: formatResolveDate(date)),
            })
          : [TextSpan(text: loc.t('mods.edit.tracking_plain'))];
    } else {
      title = loc.t('mods.edit.tracking_none_title');
      body = [TextSpan(text: loc.t('mods.edit.tracking_none_body'))];
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 6,
      children: [
        Text(
          loc.t('mods.edit.tracking'),
          style: text.labelMedium?.copyWith(fontWeight: FontWeight.w600, color: palette.textProse),
        ),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: palette.card,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: palette.outline),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 4,
            children: [
              Text(
                title,
                style: text.labelLarge?.copyWith(fontWeight: FontWeight.w600, color: palette.text),
              ),
              Text.rich(TextSpan(children: body), style: small),
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: ZenithLink(
                  loc.t('mods.context_menu.resolve_origin'),
                  onTap: onUpdateTracking,
                  style: text.bodySmall?.copyWith(color: palette.link),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
