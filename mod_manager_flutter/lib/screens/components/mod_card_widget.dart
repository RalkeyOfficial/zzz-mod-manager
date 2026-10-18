import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../core/palette.dart';
import '../../core/type_scale.dart';
import '../../l10n/app_localizations.dart';
import '../../models/character_info.dart';
import '../../services/cover_thumbnail.dart';
import '../../services/installed_record.dart';
import '../../utils/state_providers.dart';
import '../../utils/zzz_characters.dart';
import 'character_tile.dart';
import 'mod_status_slot.dart';
import 'resolve/resolve_fragments.dart' show formatResolveDate;
import 'zenith_controls.dart';
import 'zenith_switch.dart';

/// One mod in a character's grid.
///
/// A press selects it, which opens the details panel; the switch along the bottom turns it on and off, and the star
/// favourites it. Its height is fixed by the grid ([extentFor]), so the cover takes whatever the text leaves.
class ModCardWidget extends ConsumerStatefulWidget {
  const ModCardWidget({
    super.key,
    required this.mod,
    this.selected = false,
    this.onSelect,
    this.onToggle,
    this.onFavoriteToggle,
    this.onMore,
    this.onResolveOrigin,
    this.onShowUpdate,
  });

  final ModInfo mod;

  /// The mod the details panel shows.
  final bool selected;

  final VoidCallback? onSelect;
  final VoidCallback? onToggle;
  final VoidCallback? onFavoriteToggle;

  /// Opens the context menu at a global position: the ⋯ button's, or the pointer's on a right-click.
  final void Function(Offset position)? onMore;

  /// Opens the resolve dialog. Null hides the status badge, which is what the faded copy left in the grid while
  /// the card is dragged wants — a badge you can't press is not a badge.
  final VoidCallback? onResolveOrigin;

  /// Opens the update dialog, reached only from the amber badge.
  final VoidCallback? onShowUpdate;

  /// The card's height in a grid column [width] wide: a 16:10 cover over the text and the footer.
  static double extentFor(double width) => width * 10 / 16 + 112;

  @override
  ConsumerState<ModCardWidget> createState() => _ModCardWidgetState();
}

class _ModCardWidgetState extends ConsumerState<ModCardWidget> {
  bool _hovered = false;
  bool _focused = false;

  /// The cover's thumbnail when one exists, else the cover, else nothing.
  ///
  /// Resolved when the cover changes rather than on every build: a hover
  /// rebuilds the card, and a `stat` per hover frame across a grid is the kind
  /// of disk I/O that shows up as jank.
  File? _cover;

  @override
  void initState() {
    super.initState();
    _resolveCover();
  }

  @override
  void didUpdateWidget(ModCardWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.mod.imagePath != widget.mod.imagePath) _resolveCover();
  }

  void _resolveCover() {
    final imagePath = widget.mod.imagePath;
    _cover = imagePath == null ? null : coverFileFor(imagePath);
  }

  @override
  Widget build(BuildContext context) {
    final mod = widget.mod;
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final loc = context.loc;
    final selectedBorder = Color.lerp(palette.outline, palette.accent, 0.6)!;

    final ringed = widget.selected || _focused;

    // A button to the keyboard and to a screen reader as well as the pointer: Tab reaches it, Enter or Space
    // selects it, and the switch, star and ⋯ inside it are reached after it.
    // No label of its own: the name inside is the label, and a second would be read twice.
    return Semantics(
      container: true,
      button: true,
      selected: widget.selected,
      child: FocusableActionDetector(
        enabled: widget.onSelect != null,
        onShowHoverHighlight: (hovered) => setState(() => _hovered = hovered),
        onShowFocusHighlight: (focused) => setState(() => _focused = focused),
        actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => widget.onSelect?.call())},
        child: GestureDetector(
        onTap: widget.onSelect,
        onSecondaryTapDown: widget.onMore == null ? null : (d) => widget.onMore!(d.globalPosition),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: palette.card,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: ringed ? selectedBorder : (_hovered ? palette.edge : palette.outline),
            ),
            boxShadow: ringed ? [BoxShadow(color: selectedBorder, spreadRadius: 1)] : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _buildCover(context)),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 2,
                  children: [
                    Text(
                      mod.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.titleSmall?.copyWith(color: palette.text),
                    ),
                    _subline(loc),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(border: Border(top: BorderSide(color: palette.divider))),
                child: Row(
                  children: [
                    ZenithSwitch(
                      value: mod.isActive,
                      semanticLabel: loc.t('library.card.toggle', params: {'name': mod.name}),
                      onChanged: widget.onToggle == null ? null : (_) => widget.onToggle!(),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        loc.t(mod.isActive ? 'library.card.active' : 'library.card.off'),
                        style: text.bodySmall?.copyWith(color: palette.text2),
                      ),
                    ),
                    if (widget.onMore != null)
                      Builder(
                        builder: (button) => IconButton(
                          style: smallButtonStyle(context, iconOnly: true),
                          tooltip: loc.t('library.card.more'),
                          icon: const Icon(Icons.more_horiz_rounded),
                          onPressed: () {
                            final box = button.findRenderObject() as RenderBox;
                            widget.onMore!(box.localToGlobal(box.size.bottomLeft(Offset.zero)));
                          },
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        ),
      ),
    );
  }

  /// Who made it and which file, when this session's check has the page in hand and the file on record is
  /// confirmed; the date it was added otherwise. The date half is set in mono, as the design sets it.
  Widget _subline(AppLocalizations loc) {
    final mod = widget.mod;
    final palette = ZenithPalette.of(context);
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(color: palette.text3);
    final (:page, :file) = installedRecord(mod, ref.watch(modUpdateRecordsProvider));
    final author = page?.submitter?.name;
    // A file only worked out is not stated as the file.
    final confirmed = mod.origin?.base?.versionConfidence.isConfirmed ?? false;
    final uploaded = confirmed ? file?.dateAdded : null;
    final added = mod.origin?.installedAt;
    final when = uploaded != null
        ? loc.t('library.card.file_from', params: {'date': formatResolveDate(uploaded)})
        : added != null
        ? loc.t('library.card.added', params: {'date': formatResolveDate(added)})
        : null;
    return Text.rich(
      TextSpan(
        children: [
          if (author != null) TextSpan(text: when == null ? author : '$author · '),
          if (when != null) TextSpan(text: when, style: ZenithType.of(context).mono.copyWith(color: palette.text3)),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: style,
    );
  }

  Widget _buildCover(BuildContext context) {
    final mod = widget.mod;
    final palette = ZenithPalette.of(context);
    final loc = context.loc;
    final ground = palette.groundFor(elementToneOf(mod.characterId));
    final empty = DottedGround(
      ground: ground,
      child: Center(
        child: OutlinedInitials(
          nameInitials(mod.name),
          style: ZenithType.of(context).watermark,
          color: ground.stroke,
        ),
      ),
    );

    return Stack(
      fit: StackFit.expand,
      children: [
        if (_cover != null)
          Image.file(
            _cover!,
            fit: BoxFit.cover,
            // Decode to the card's size rather than the file's. Without this a
            // 2560px screenshot is held as 14 MB of pixels to fill a 320px
            // card, and a handful of them evict the whole shared ImageCache —
            // including the marketplace's previews. See
            // AppConstants.modCardDecodeWidth for the measurements.
            cacheWidth: AppConstants.modCardDecodeWidth,
            key: ValueKey('${mod.id}_${mod.imagePath}'),
            // The file was there when the card mounted and is checked again
            // only when the path changes, so one deleted underneath an open tab
            // lands here rather than as the framework's error widget.
            errorBuilder: (_, __, ___) => empty,
          )
        else
          empty,
        Positioned(
          left: 10,
          top: 10,
          right: 48,
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              if (mod.isActive) ZenithBadge(label: loc.t('library.card.active'), tone: palette.badgeOn),
              if (widget.onResolveOrigin != null)
                ModStatusSlot(mod: mod, onTap: widget.onResolveOrigin!, onShowUpdate: widget.onShowUpdate),
            ],
          ),
        ),
        if (widget.onFavoriteToggle != null)
          Positioned(right: 8, top: 8, child: _FavoriteButton(on: mod.isFavorite, onTap: widget.onFavoriteToggle!)),
      ],
    );
  }
}

/// The star over a card's cover, on a scrim so it reads over any artwork.
class _FavoriteButton extends StatelessWidget {
  const _FavoriteButton({required this.on, required this.onTap});

  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    return Semantics(
      button: true,
      toggled: on,
      label: context.loc.t('library.card.favorite'),
      child: Material(
        color: palette.artworkScrim,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: SizedBox.square(
            dimension: 30,
            child: Icon(
              on ? Icons.star_rounded : Icons.star_outline_rounded,
              color: on ? palette.accent : palette.onArtwork,
            ),
          ),
        ),
      ),
    );
  }
}
