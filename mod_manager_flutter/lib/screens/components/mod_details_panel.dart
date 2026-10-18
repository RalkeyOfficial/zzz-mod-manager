import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/palette.dart';
import '../../core/type_scale.dart';
import '../../l10n/app_localizations.dart';
import '../../models/character_info.dart';
import '../../models/gamebanana/gb_mod.dart';
import '../../models/keybind_info.dart';
import '../../models/mod_download.dart';
import '../../models/origin_enums.dart';
import '../../services/api_service.dart';
import '../../services/cover_thumbnail.dart';
import '../../services/gamebanana/file_selection.dart';
import '../../services/installed_record.dart';
import '../../services/platform_service_factory.dart';
import '../../services/update_check.dart';
import '../../utils/byte_format.dart';
import '../../utils/gamebanana_url.dart';
import '../../utils/home_relative.dart';
import '../../utils/markdown_description.dart';
import '../../utils/markdown_style.dart';
import '../../utils/notifications.dart';
import '../../utils/state_providers.dart';
import '../../utils/url_utils.dart';
import '../../utils/zzz_characters.dart';
import '../shell/keycap.dart';
import 'character_tile.dart';
import 'folder_downloads_summary.dart' show downloadName;
import 'resolve/resolve_fragments.dart' show formatResolveDate;
import 'shader_part_summary.dart';
import 'zenith_controls.dart';
import 'zenith_switch.dart';

/// Saves a mod's note. Production is `ApiService.setModNote`; tests inject one so typing never reaches the
/// developer's own `config.json`.
typedef NoteWriter = Future<bool> Function(String modId, String note);

/// The column beside a character's mods that shows the selected one: its pictures and text, whether it is on, its
/// in-game keys, where it came from, where it lives, and the user's note on it.
///
/// It reads what the app already has and **never fetches**: a mod selected in passing should not spend a request
/// the user did not ask for. The file name, upload date and author appear once this session's update check has the
/// mod page in hand.
class ModDetailsPanel extends ConsumerWidget {
  const ModDetailsPanel({
    super.key,
    required this.mod,
    required this.onClose,
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
  final VoidCallback onToggle;
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
    final keys = [
      for (final k in mod.keybinds ?? const <KeybindInfo>[])
        if (k.displayKeyValue case final value? when value.isNotEmpty) (k.displayName, value),
    ];

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
                  Text.rich(
                    TextSpan(
                      // The placeholder rather than a prefix, so each language puts the name where its word order
                      // wants it.
                      children: [
                        for (final (i, part) in loc.t('library.details.by').split('{author}').indexed) ...[
                          if (i > 0)
                            WidgetSpan(
                              alignment: PlaceholderAlignment.baseline,
                              baseline: TextBaseline.alphabetic,
                              child: _Link(author, onTap: () => openModLink(context, mod)),
                            ),
                          if (part.isNotEmpty) TextSpan(text: part),
                        ],
                      ],
                    ),
                    style: text.bodyMedium?.copyWith(color: palette.text2),
                  ),
                ],
                if (mod.description?.trim().isNotEmpty ?? false) ...[
                  const SizedBox(height: 10),
                  _Description(key: ValueKey('description_${mod.id}'), text: mod.description!),
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
                _ActiveBox(mod: mod, onToggle: onToggle),
                if (keys.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  _Keys(keys: keys),
                ],
                ShaderPartSummary(folderName: mod.name),
                if ((mod.origin?.downloads.length ?? 0) > 1) ...[
                  const SizedBox(height: 18),
                  _MadeOf(mod: mod),
                ],
                const SizedBox(height: 18),
                _Facts(mod: mod, onResolveOrigin: onResolveOrigin),
                const SizedBox(height: 12),
                _PathButton(mod: mod),
                const SizedBox(height: 18),
                _NoteField(key: ValueKey('note_${mod.id}'), modId: mod.id, writer: noteWriter),
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
                    // Only where there is a mod page to ask; the dialog would say "not tracked" and nothing else.
                    // Nor for a mod marked Local, which is never checked.
                    onPressed: (mod.origin?.hasIdentity ?? false) && mod.origin?.tracking != OriginTracking.off
                        ? onCheckForUpdate
                        : null,
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

class _Link extends StatelessWidget {
  const _Link(this.label, {required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ZenithLink(
    label,
    onTap: onTap,
    style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: ZenithPalette.of(context).link),
  );
}

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
              onTap: () => _showLightbox(context, images[index]),
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

/// Opens an image large over a dark backdrop. A tap anywhere closes it.
void _showLightbox(BuildContext context, String imagePath) {
  final palette = ZenithPalette.of(context);
  showGeneralDialog(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: palette.overlay,
    transitionDuration: const Duration(milliseconds: 150),
    pageBuilder: (context, _, __) => GestureDetector(
      onTap: () => Navigator.of(context).pop(),
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Center(
          child: InteractiveViewer(
            maxScale: 5,
            child: Image.file(
              File(imagePath),
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => Icon(Icons.broken_image_outlined, size: 64, color: palette.text3),
            ),
          ),
        ),
      ),
    ),
  );
}

/// The description, three lines' worth until the user asks for the rest.
class _Description extends StatefulWidget {
  const _Description({super.key, required this.text});

  final String text;

  @override
  State<_Description> createState() => _DescriptionState();
}

class _DescriptionState extends State<_Description> {
  /// Around the More and Less word, on each side.
  static const double _morePadding = 6;

  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    // Three lines of the paragraph style the markdown is drawn in, plus the padding above the first.
    final sheet = buildMarkdownStyleSheet(context);
    final p = sheet.p;
    // Scaled as the text is, so a larger desktop text size still folds after the third line.
    final fontSize = MediaQuery.textScalerOf(context).scale(p?.fontSize ?? 13);
    final collapsed = fontSize * (p?.height ?? 1.45) * 3 + (sheet.pPadding?.top ?? 0);
    final markdown = buildDescriptionMarkdown(
      context,
      widget.text,
      onLaunchUrl: (href) => launchExternalUrl(context, href),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        // Long enough to need folding: a rough measure, since the markdown lays itself out.
        final long = widget.text.length > constraints.maxWidth / 6 * 3 || widget.text.contains('\n');
        if (!long) return markdown;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AnimatedSize(
              duration: const Duration(milliseconds: 160),
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: _expanded ? double.infinity : collapsed),
                // The markdown lays out at its full height inside a scroll view that can't be scrolled, and the clip
                // shows three lines of it. Squeezed into the box itself, its column overflows instead.
                child: ClipRect(
                  child: SingleChildScrollView(physics: const NeverScrollableScrollPhysics(), child: markdown),
                ),
              ),
            ),
            // A snug hover box, as wide around the word as it is tall, pulled left by its padding so the word lines
            // up with the description above it.
            Transform.translate(
              offset: const Offset(-_morePadding, 0),
              child: TextButton(
                style: smallButtonStyle(context).copyWith(
                  minimumSize: const WidgetStatePropertyAll(Size.zero),
                  padding: const WidgetStatePropertyAll(
                    EdgeInsets.symmetric(horizontal: _morePadding, vertical: 3),
                  ),
                  shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(6))),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: () => setState(() => _expanded = !_expanded),
                child: Text(loc.t(_expanded ? 'library.details.less' : 'library.details.more')),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ActiveBox extends StatelessWidget {
  const _ActiveBox({required this.mod, required this.onToggle});

  final ModInfo mod;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final on = mod.isActive;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: on ? Color.lerp(palette.card, palette.accent, 0.09) : palette.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: on ? Color.lerp(palette.outline, palette.accent, 0.3)! : palette.outline),
      ),
      child: Row(
        spacing: 12,
        children: [
          ZenithSwitch(
            value: on,
            semanticLabel: loc.t('library.card.toggle', params: {'name': mod.name}),
            onChanged: (_) => onToggle(),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  loc.t(on ? 'library.details.active_title' : 'library.details.off_title'),
                  style: text.bodyMedium?.copyWith(color: palette.text, fontWeight: FontWeight.w600),
                ),
                Text(
                  loc.t(on ? 'library.details.active_body' : 'library.details.off_body'),
                  style: text.bodySmall?.copyWith(color: palette.text2),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The keys a mod's `.ini` binds, each as keycaps. Tokens such as `no_shift` say which modifier must **not** be
/// held, so they are left out of the caps.
class _Keys extends StatelessWidget {
  const _Keys({required this.keys});

  final List<(String, String)> keys;

  static List<String> _caps(String value) => [
    for (final token in value.split(RegExp(r'\s+')))
      if (token.isNotEmpty && !token.toLowerCase().startsWith('no_'))
        token.length == 1 ? token.toUpperCase() : '${token[0].toUpperCase()}${token.substring(1)}',
  ];

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        _Heading(loc.t('library.details.keys'), aside: loc.t('library.details.keys_source')),
        Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: palette.outline),
          ),
          child: Column(
            children: [
              for (var i = 0; i < keys.length; i++)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                  decoration: BoxDecoration(
                    border: i == keys.length - 1 ? null : Border(bottom: BorderSide(color: palette.divider)),
                  ),
                  child: Row(
                    spacing: 12,
                    children: [
                      Expanded(
                        child: Text(
                          keys[i].$1,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodyMedium?.copyWith(color: palette.text),
                        ),
                      ),
                      Wrap(spacing: 4, children: [for (final cap in _caps(keys[i].$2)) Keycap(cap)]),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A section's label in caps, and a quieter remark on the right.
class _Heading extends StatelessWidget {
  const _Heading(this.label, {required this.aside});

  final String label;
  final String aside;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Expanded(
          child: Text(label.toUpperCase(), style: ZenithType.of(context).caps.copyWith(color: palette.text3)),
        ),
        Text(aside, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: palette.text3)),
      ],
    );
  }
}

/// The downloads a folder is made of, in stack order: the base first, each patch above what it is written over
/// (`docs/origin-tracking.md` §10). Shown only for a folder with more than one.
///
/// Like the facts below it, a row's file, author and upload date come from a page this session holds, fetched by a
/// check, an install or a dialog, and are absent without one; the file and its date also need the file on record to
/// be confirmed.
class _MadeOf extends ConsumerWidget {
  const _MadeOf({required this.mod});

  final ModInfo mod;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final downloads = mod.origin?.downloads ?? const <ModDownload>[];
    final records = ref.watch(knownModPagesProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        _Heading(
          loc.plural('library.details.made_of', downloads.length, params: {'count': '${downloads.length}'}),
          aside: loc.t('library.details.made_of_order'),
        ),
        Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: palette.outline),
          ),
          child: Column(
            children: [
              for (final (i, download) in downloads.indexed)
                _DownloadRow(
                  download: download,
                  folderName: mod.name,
                  records: records,
                  last: i == downloads.length - 1,
                ),
            ],
          ),
        ),
        // Opens the mod's GameBanana page, so it is offered only when there is one.
        if (modPageUrl(mod) != null)
          Align(
            alignment: Alignment.centerLeft,
            child: _SmallLink(loc.t('library.details.manage_history'), onTap: () => openModLink(context, mod)),
          ),
      ],
    );
  }
}

class _DownloadRow extends StatelessWidget {
  const _DownloadRow({required this.download, required this.folderName, required this.records, required this.last});

  final ModDownload download;
  final String folderName;
  final Map<int, GbMod> records;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final (:page, file: recorded) = downloadRecord(download, records);
    final file = download.versionConfidence.isConfirmed ? recorded : null;
    final isBase = download.role == DownloadRole.base;
    final modId = download.modId;

    final name = downloadName(loc, download, folderName: folderName, fetched: page?.name);
    final byline = [
      ?page?.submitter?.name,
      if (file?.dateAdded case final date?)
        loc.t('library.details.uploaded_on', params: {'date': formatResolveDate(date)}),
    ].join(' · ');

    final nameStyle = text.bodyMedium?.copyWith(color: palette.text, fontWeight: FontWeight.w600);
    // Every row with a page links to it: an id is not something a person can act on.
    final title = modId == null
        ? Text(name, style: nameStyle)
        : Tooltip(
            message: loc.t('mods.folder.open_page'),
            child: ZenithLink(
              name,
              onTap: () => launchExternalUrl(context, gameBananaModUrl(modId)),
              style: nameStyle,
            ),
          );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        border: last ? null : Border(bottom: BorderSide(color: palette.divider)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 10,
        children: [
          ZenithBadge(
            label: loc.t(isBase ? 'library.details.role_base' : 'library.details.role_patch'),
            tone: palette.badgeNeutral,
            minWidth: 46,
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 1,
              children: [
                title,
                if (file != null)
                  Text(
                    fileDisplayName(file),
                    style: ZenithType.of(context).monoSmall.copyWith(color: palette.text2, height: 1.4),
                  ),
                if (byline.isNotEmpty) Text(byline, style: text.labelSmall?.copyWith(color: palette.text3)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// File, variant, upload date, tracking, when it was added, and its size.
class _Facts extends ConsumerWidget {
  const _Facts({required this.mod, required this.onResolveOrigin});

  final ModInfo mod;
  final VoidCallback onResolveOrigin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final style = Theme.of(context).textTheme.bodySmall;
    final origin = mod.origin;
    final base = origin?.base;
    final (page: _, file: recorded) = installedRecord(mod, ref.watch(knownModPagesProvider));
    // A file only worked out is not stated as the file, here as on the card: not its name, its date or its variant.
    final confirmed = base?.versionConfidence.isConfirmed ?? false;
    final file = confirmed ? recorded : null;
    final check = ref.watch(modUpdateChecksProvider.select((checks) => checks[mod.id]));
    final size = ref.watch(modSizeProvider(mod.id)).valueOrNull;

    // The base mod's own verdict, not the folder's: in a folder with a patch on top, the folder's verdict can be the
    // patch's, and the line it goes on describes the base mod's file.
    final baseCheck = check == null
        ? null
        : check.layers.isNotEmpty
        ? check.layers.first.check
        : (check.subjectModId == base?.modId ? check : null);

    String? uploaded;
    if (file?.dateAdded case final date?) {
      final verdict = switch (baseCheck?.outcome) {
        UpdateOutcome.upToDate => loc.t('library.details.nothing_newer'),
        UpdateOutcome.updateAvailable => loc.t('library.details.newer_out'),
        _ => null,
      };
      uploaded = [formatResolveDate(date), ?verdict].join(' · ');
    }

    final Widget tracking;
    if (origin?.tracking == OriginTracking.off) {
      tracking = _linked(context, loc.t('library.details.tracking_local'), null, loc.t('library.details.tracking_change'));
    } else if (origin?.hasIdentity ?? false) {
      tracking = _linked(
        context,
        loc.t('library.details.tracking_gamebanana'),
        () => openModLink(context, mod),
        loc.t('library.details.tracking_change'),
      );
    } else {
      tracking = _linked(context, loc.t('library.details.tracking_none'), null, loc.t('library.details.tracking_set_up'));
    }

    final installedAt = origin?.installedAt;
    final rows = <(String, Widget)>[
      if (file != null) (loc.t('library.details.file'), _value(context, fileDisplayName(file), mono: true)),
      if (base?.versionLabel case final label? when confirmed && label.isNotEmpty)
        (loc.t('library.details.variant'), _value(context, label)),
      if (uploaded != null) (loc.t('library.details.uploaded'), _value(context, uploaded)),
      (loc.t('library.details.tracking'), tracking),
      if (installedAt != null)
        (
          loc.t('library.details.added'),
          _value(
            context,
            origin!.installedAtIsProxy
                ? loc.t('library.details.added_about', params: {'date': formatResolveDate(installedAt)})
                : formatResolveDate(installedAt),
          ),
        ),
      if (size != null && size.bytes > 0) (loc.t('library.details.size'), _value(context, formatBytes(size.bytes))),
    ];
    return Column(
      spacing: 8,
      children: [
        for (final (label, value) in rows)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 16,
            children: [
              Text(label, style: style?.copyWith(color: palette.text3)),
              Expanded(child: Align(alignment: Alignment.centerRight, child: value)),
            ],
          ),
      ],
    );
  }

  Widget _value(BuildContext context, String value, {bool mono = false}) {
    final palette = ZenithPalette.of(context);
    final style = mono
        ? ZenithType.of(context).mono.copyWith(color: palette.text)
        : Theme.of(context).textTheme.bodySmall?.copyWith(color: palette.text);
    return Text(value, textAlign: TextAlign.right, style: style);
  }

  /// "GameBanana · change": the first half opens the page when there is one, the second the resolve dialog.
  Widget _linked(BuildContext context, String label, VoidCallback? open, String change) {
    final palette = ZenithPalette.of(context);
    final style = Theme.of(context).textTheme.bodySmall;
    return Wrap(
      alignment: WrapAlignment.end,
      children: [
        if (open != null) _SmallLink(label, onTap: open) else Text(label, style: style?.copyWith(color: palette.textProse)),
        Text(' · ', style: style?.copyWith(color: palette.text3)),
        _SmallLink(change, onTap: onResolveOrigin),
      ],
    );
  }
}

class _SmallLink extends StatelessWidget {
  const _SmallLink(this.label, {required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ZenithLink(
    label,
    onTap: onTap,
    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: ZenithPalette.of(context).link),
  );
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
            if (context.mounted) context.notify.success(loc.t('library.details.path_copied_title'), body: folder);
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

/// The user's note on the mod, saved as they type (`docs/library-screen.md` §11).
///
/// Keyed by the mod, so selecting another mod disposes this one, and a note still waiting to be saved is saved on
/// the way out.
class _NoteField extends ConsumerStatefulWidget {
  const _NoteField({super.key, required this.modId, this.writer});

  final String modId;
  final NoteWriter? writer;

  @override
  ConsumerState<_NoteField> createState() => _NoteFieldState();
}

class _NoteFieldState extends ConsumerState<_NoteField> {
  static const Duration _pause = Duration(milliseconds: 600);

  late final TextEditingController _controller;
  Timer? _debounce;
  late String _saved;

  /// Held from the start, so a save on the way out can still publish and still report: by then `ref` and
  /// `context` may no longer be used.
  late final StateController<Map<String, String>> _notes;
  late NotificationCenter _notify;
  late String _failedTitle;

  @override
  void initState() {
    super.initState();
    _notes = ref.read(modNotesProvider.notifier);
    _saved = _notes.state[widget.modId] ?? '';
    _controller = TextEditingController(text: _saved);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _notify = context.notify;
    _failedTitle = context.loc.t('library.details.note_failed_title');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _save(duringDispose: true);
    _controller.dispose();
    super.dispose();
  }

  /// [duringDispose] publishes in a microtask: a dispose runs inside a build, where Riverpod refuses a provider
  /// write. The microtask is queued before the write starts, so it still lands first.
  void _save({bool duringDispose = false}) {
    final note = _controller.text;
    if (note == _saved) return;
    _saved = note;
    // Published before it is written, so a field rebuilt for this mod while the write is in flight shows what was
    // typed rather than the note before it.
    final notesController = _notes;
    final modId = widget.modId;
    void publish() {
      final notes = {...notesController.state};
      if (note.trim().isEmpty) {
        notes.remove(modId);
      } else {
        notes[modId] = note;
      }
      notesController.state = notes;
    }

    if (duringDispose) {
      scheduleMicrotask(publish);
    } else {
      publish();
    }
    final notify = _notify;
    final title = _failedTitle;
    unawaited(
      (widget.writer ?? ApiService.setModNote)(widget.modId, note).then((saved) {
        if (!saved) notify.error(title, body: widget.modId);
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 6,
      children: [
        Text(
          loc.t('library.details.note').toUpperCase(),
          style: ZenithType.of(context).caps.copyWith(color: palette.text3),
        ),
        TextField(
          controller: _controller,
          minLines: 2,
          maxLines: 6,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: palette.text),
          decoration: InputDecoration(hintText: loc.t('library.details.note_hint')),
          onChanged: (_) {
            _debounce?.cancel();
            _debounce = Timer(_pause, _save);
          },
          // Saves, and lets go of the caret as a field does when you click elsewhere.
          onTapOutside: (_) {
            _save();
            FocusManager.instance.primaryFocus?.unfocus();
          },
        ),
      ],
    );
  }
}
