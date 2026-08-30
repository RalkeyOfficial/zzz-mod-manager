import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../../models/gamebanana/gamebanana.dart';
import '../../../services/gamebanana/content_filter.dart';
import '../../../services/installed_mods_index.dart';
import '../../../utils/html_to_markdown.dart';
import '../../../utils/markdown_description.dart';
import '../../../utils/markdown_style.dart';
import '../../../utils/marketplace_providers.dart';
import '../../../utils/state_providers.dart';
import 'gb_category_panel.dart' show selectCategory;
import 'gb_file_list.dart';
import 'gb_state_view.dart';
import 'gb_thumbnail.dart';

/// The mod detail screen: gallery, description, author/category/stats, and the
/// file list that actually starts a download.
class GbDetailView extends ConsumerStatefulWidget {
  const GbDetailView({
    super.key,
    required this.modId,
    required this.onBack,
    required this.onDownload,
    required this.onOpenInBrowser,
  });

  final int modId;
  final VoidCallback onBack;

  /// The mod is passed alongside the file because the origin block records
  /// remote *identity*, which is a property of the mod, not of the file.
  final void Function(GbMod mod, GbFile file) onDownload;

  final void Function(String url) onOpenInBrowser;

  @override
  ConsumerState<GbDetailView> createState() => _GbDetailViewState();
}

class _GbDetailViewState extends ConsumerState<GbDetailView> {
  /// Width the gallery strip requests, and therefore the width the hero uses as its
  /// stand-in. One constant so the two cannot drift apart — if they did, the
  /// placeholder would silently become an extra download instead of a cache hit.
  static const int _stripImageWidth = 100;

  /// Vertical space reserved below the thumbnails for the horizontal scrollbar.
  static const double _stripScrollbarLane = 12;

  /// Owned here rather than created in `build`: a `Scrollbar` and its `ListView`
  /// must share one controller, and a fresh one per build would detach the thumb.
  final ScrollController _stripScroll = ScrollController();

  int _galleryIndex = 0;
  bool _revealed = false;
  bool _showArchived = false;

  @override
  void dispose() {
    _stripScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final profile = ref.watch(modProfileProvider(widget.modId));

    return Column(
      children: [
        _header(context, loc, profile.valueOrNull, failed: profile.hasError),
        Expanded(
          child: profile.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => GbFailureState(
              error: error,
              onRetry: () => ref.invalidate(modProfileProvider(widget.modId)),
            ),
            data: (mod) => _body(context, loc, mod),
          ),
        ),
      ],
    );
  }

  Widget _header(
    BuildContext context,
    AppLocalizations loc,
    GbMod? mod, {
    required bool failed,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final url =
        mod?.profileUrl ?? 'https://gamebanana.com/mods/${widget.modId}';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border(
          bottom: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.4),
          ),
        ),
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: widget.onBack,
            icon: const Icon(Icons.arrow_back),
            tooltip: loc.t('marketplace.back'),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              // *Loading…* only while it genuinely is. On a failure there is no
              // name to show and never will be, so the header falls back to the
              // id — the same shape a file row uses for a record it cannot name
              // (`gb_file_list.dart`). Left as "Loading…" it sat as a title over
              // a message saying the load had failed.
              mod?.name ??
                  (failed ? '#${widget.modId}' : loc.t('marketplace.loading')),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          // The escape hatch for everything this screen deliberately doesn't
          // render — comments, threads, credits, the author's other pages.
          TextButton.icon(
            onPressed: () => widget.onOpenInBrowser(url),
            icon: const Icon(Icons.open_in_new, size: 16),
            label: Text(loc.t('marketplace.open_in_browser')),
          ),
        ],
      ),
    );
  }

  Widget _body(BuildContext context, AppLocalizations loc, GbMod mod) {
    final filter = ref.watch(contentFilterProvider);
    final treatment = contentTreatment(mod.effectiveVisibility, filter);
    final installed = ref.watch(installedModsIndexProvider).valueOrNull ??
        InstalledModsIndex.empty;
    final installedAs = installed.installsOfMod(mod.idRow);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Mod-level, so it is true even when *which* file is unknown — which is
        // the normal state for a library that predates this (nothing local
        // survives to identify a file). The file list below adds the per-row
        // answer when there is one.
        if (installedAs.isNotEmpty)
          _notice(
            context,
            loc.t('marketplace.installed_as',
                params: {'mods': installedAs.join(', ')}),
            // `primary`, matching the card's badge. One colour per meaning across
            // the marketplace, so "you already have this" doesn't change hue
            // depending on which screen you are looking at.
            Theme.of(context).colorScheme.primary,
          ),
        if (mod.isRemoteMissing)
          _notice(
            context,
            loc.t('marketplace.remote_missing'),
            Theme.of(context).colorScheme.error,
          ),
        if (mod.isObsolete)
          // Explicitly *not* the same thing as removed: the mod still exists and
          // still downloads, its author just flagged it superseded.
          _notice(
            context,
            loc.t('marketplace.obsolete_notice'),
            Theme.of(context).colorScheme.tertiary,
          ),
        if (treatment != ContentTreatment.show && !_revealed)
          _contentWarning(context, loc, mod),
        _gallery(context, loc, mod, treatment),
        const SizedBox(height: 16),
        _meta(context, loc, mod),
        if (mod.tags.isNotEmpty) ...[
          const SizedBox(height: 12),
          _tags(context, mod),
        ],
        const SizedBox(height: 16),
        GbFileList(
          files: mod.files,
          archivedFiles: mod.archivedFiles,
          showArchived: _showArchived,
          onToggleArchived: () =>
              setState(() => _showArchived = !_showArchived),
          onDownload: (file) => widget.onDownload(mod, file),
          // Deliberately keyed on the file, not the mod: a mod being in the
          // library says nothing about which of its files you hold. Archived
          // rows go through the same lookup, which is where a banked hash pays
          // off most — an old install matches a superseded file more often than
          // the current one.
          matchInstalled: (file) => installed.matchFile(
            fileId: file.idRow,
            md5: file.md5Checksum,
          ),
        ),
        const SizedBox(height: 20),
        if (mod.text case final html? when html.trim().isNotEmpty)
          // Prose is capped at a readable measure and centred, rather than
          // running the full width of a maximised window. It also matches the
          // shape the description was written for — GameBanana lays one out in
          // a ~522px column, so line breaks and inline images land where the
          // author saw them. The heading is inside the cap so it stays aligned
          // with the text it labels.
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: MarkdownScale.readingWidth,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    loc.t('marketplace.description'),
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  // `_sText` is HTML while every description this app renders
                  // is markdown, so it is converted rather than dumped into
                  // the markdown widget — which would show literal tags.
                  buildDescriptionMarkdown(
                    context,
                    htmlToMarkdown(html),
                    onLaunchUrl: widget.onOpenInBrowser,
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _contentWarning(
    BuildContext context,
    AppLocalizations loc,
    GbMod mod,
  ) {
    final scheme = Theme.of(context).colorScheme;
    // Unlike a card, the detail response carries `_aContentRatings`, so this can
    // name the reasons instead of just flagging.
    final reasons = mod.contentRatings.values.join(', ');

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.tertiary.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, color: scheme.tertiary, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  loc.t('marketplace.content_warning'),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                if (reasons.isNotEmpty)
                  Text(
                    reasons,
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          TextButton(
            onPressed: () => setState(() => _revealed = true),
            child: Text(loc.t('marketplace.content_reveal')),
          ),
        ],
      ),
    );
  }

  Widget _gallery(
    BuildContext context,
    AppLocalizations loc,
    GbMod mod,
    ContentTreatment treatment,
  ) {
    if (mod.images.isEmpty) return const SizedBox.shrink();
    final index = _galleryIndex.clamp(0, mod.images.length - 1);

    return Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: Stack(
              fit: StackFit.expand,
              children: [
                GbThumbnail(
                  image: mod.images[index],
                  treatment: treatment,
                  revealed: _revealed,
                  minWidth: 800,
                  fit: BoxFit.contain,
                  // Deliberately the same width the strip below requests, so this
                  // is a cache hit rather than a second download: the small copy
                  // fills the frame the instant you switch, and the 800px version
                  // paints over it. Without it, changing preview image left the
                  // area blank for the length of a download.
                  placeholderMinWidth: _stripImageWidth,
                ),
                if (mod.images.length > 1) ...[
                  // Clamped with a disabled state at each end, matching the "best
                  // of" carousel — one navigation idiom for the whole screen.
                  _GalleryArrow(
                    alignment: Alignment.centerLeft,
                    icon: Icons.chevron_left,
                    tooltip: loc.t('marketplace.previous'),
                    onPressed: index > 0
                        ? () => setState(() => _galleryIndex = index - 1)
                        : null,
                  ),
                  _GalleryArrow(
                    alignment: Alignment.centerRight,
                    icon: Icons.chevron_right,
                    tooltip: loc.t('marketplace.next'),
                    onPressed: index < mod.images.length - 1
                        ? () => setState(() => _galleryIndex = index + 1)
                        : null,
                  ),
                ],
              ],
            ),
          ),
        ),
        if (mod.images.length > 1) ...[
          const SizedBox(height: 8),
          SizedBox(
            // Taller than the thumbnails so the scrollbar has its own lane instead
            // of sitting on top of them.
            height: 52 + 4 + _stripScrollbarLane,
            child: ScrollConfiguration(
              // Flutter's desktop scroll behaviour deliberately leaves the mouse out
              // of `dragDevices`, which is why this strip could only be moved with
              // shift+scroll. Adding it back makes click-and-drag work.
              //
              // Scoped to this strip rather than the screen: the page around it is a
              // vertical `ListView` containing selectable description text, and
              // mouse-dragging *that* would fight text selection.
              behavior: ScrollConfiguration.of(context).copyWith(
                dragDevices: const {
                  PointerDeviceKind.touch,
                  PointerDeviceKind.mouse,
                  PointerDeviceKind.trackpad,
                  PointerDeviceKind.stylus,
                },
                // Suppressed so it doesn't fight the explicit Scrollbar below, which
                // owns the same controller.
                scrollbars: false,
              ),
              child: Scrollbar(
                controller: _stripScroll,
                // Always visible: a strip that scrolls with no indication that it
                // scrolls is the problem being fixed, so hover-to-discover is not
                // good enough.
                thumbVisibility: true,
                child: ListView.separated(
                  controller: _stripScroll,
                  scrollDirection: Axis.horizontal,
                  // Keeps the thumbnails clear of the scrollbar lane.
                  padding: const EdgeInsets.only(bottom: _stripScrollbarLane),
                  itemCount: mod.images.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 6),
                  itemBuilder: (context, i) {
                    final selected = i == index;
                    return InkWell(
                      onTap: () => setState(() => _galleryIndex = i),
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: selected
                                ? Theme.of(context).colorScheme.primary
                                : Colors.transparent,
                            width: 2,
                          ),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: GbThumbnail(
                          image: mod.images[i],
                          treatment: treatment,
                          revealed: _revealed,
                          width: 92,
                          height: 52,
                          minWidth: _stripImageWidth,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _meta(BuildContext context, AppLocalizations loc, GbMod mod) {
    final scheme = Theme.of(context).colorScheme;
    final style = TextStyle(fontSize: 12, color: scheme.onSurfaceVariant);

    return Wrap(
      spacing: 16,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (mod.submitter?.name case final author?)
          _pair(Icons.person_outline, author, style),
        if (mod.displayCategory case final category?
            when category.name != null)
          _categoryPair(context, mod, category, style),
        // The mod-level version, clearly the mod's own and not a file's.
        if (mod.version case final version? when version.isNotEmpty)
          _pair(Icons.sell_outlined, version, style),
        // Both dates, each from its own field. `_tsDateUpdated` is **null on a
        // mod that has never been updated**, so the old `dateUpdated ??
        // dateAdded` fallback labelled a first release as an update — the one
        // reading of these two fields that states something untrue. Released
        // first because it is the one every mod has.
        if (mod.dateAdded case final date?)
          _pair(
            Icons.event_outlined,
            loc.t('marketplace.released_on', params: {'date': _date(date)}),
            style,
          ),
        if (mod.dateUpdated case final date?)
          _pair(
            Icons.schedule,
            loc.t('marketplace.updated_on', params: {'date': _date(date)}),
            style,
          ),
        if (mod.likeCount case final n?)
          _pair(Icons.favorite_outline, '$n', style),
        if (mod.viewCount case final n?)
          _pair(Icons.visibility_outlined, '$n', style),
        if (mod.downloadCount case final n?)
          _pair(Icons.download_outlined, '$n', style),
      ],
    );
  }

  /// The category, as a link to everything else filed under it.
  ///
  /// For a ZZZ mod this is usually the *character* ("Ellen Joe"), which is the
  /// one piece of metadata a reader is most likely to want more of — and the
  /// browse filter already takes exactly this id.
  ///
  /// **Plain text when there is no id.** A listing's `_aRootCategory` carries
  /// no `_idRow` and [GbCategoryRef.idRow] recovers it from `_sProfileUrl`, so
  /// a record with neither would otherwise offer a link that filters by
  /// nothing. Better to look inert than to look broken.
  Widget _categoryPair(
    BuildContext context,
    GbMod mod,
    GbCategoryRef category,
    TextStyle style,
  ) {
    final id = category.idRow;
    if (id == null) {
      return _pair(Icons.folder_outlined, category.name!, style);
    }

    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () {
        // The panel highlights a child only while its parent is open, so
        // expanding the root is what makes the selection visible when the grid
        // comes back rather than looking like nothing happened.
        if (mod.rootCategory?.idRow case final rootId?) {
          ref.read(expandedCategoryProvider.notifier).state = rootId;
        }
        selectCategory(ref, id);
        widget.onBack();
      },
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
        child: _pair(
          Icons.folder_outlined,
          category.name!,
          style.copyWith(
            color: scheme.primary,
            decoration: TextDecoration.underline,
            decorationColor: scheme.primary.withValues(alpha: 0.4),
          ),
        ),
      ),
    );
  }

  /// The author's own tags, verbatim.
  ///
  /// Shown in the **same `"Title: Value"` form the library stores**, because an
  /// install copies these strings straight onto the mod — so a tag reads
  /// identically whether you are browsing the page or looking at the folder it
  /// became. Splitting them for display here would make the two disagree.
  ///
  /// Absent rather than empty on a mod with none: 4 of 20 captured records carry
  /// any, so a permanent empty row would be the common case.
  Widget _tags(BuildContext context, GbMod mod) {
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final tag in mod.tags)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: 0.4),
              ),
            ),
            child: Text(
              tag,
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
          ),
      ],
    );
  }

  Widget _pair(IconData icon, String label, TextStyle style) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: style.color),
        const SizedBox(width: 4),
        Text(label, style: style),
      ],
    );
  }

  Widget _notice(BuildContext context, String message, Color color) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, color: color, size: 18),
          const SizedBox(width: 10),
          Expanded(child: Text(message, style: const TextStyle(fontSize: 12))),
        ],
      ),
    );
  }

  static String _date(DateTime date) {
    final d = date.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }
}

/// A circular overlay arrow for stepping through the gallery.
///
/// Its own widget rather than an inline `IconButton` so the disabled look — the one
/// thing that tells the user they are at an end — is defined once for both sides.
/// Deliberately the same treatment as the "best of" carousel's arrows: literal black
/// and white, because these sit over arbitrary artwork rather than a themed surface.
class _GalleryArrow extends StatelessWidget {
  const _GalleryArrow({
    required this.alignment,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final Alignment alignment;
  final IconData icon;
  final String tooltip;

  /// Null disables the arrow, which is how the ends of the list are communicated.
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Align(
      alignment: alignment,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Material(
          color: Color(enabled ? 0xB3000000 : 0x4D000000),
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: IconButton(
            onPressed: onPressed,
            tooltip: enabled ? tooltip : null,
            iconSize: 22,
            icon: Icon(icon, color: Color(enabled ? 0xFFFFFFFF : 0x66FFFFFF)),
          ),
        ),
      ),
    );
  }
}
