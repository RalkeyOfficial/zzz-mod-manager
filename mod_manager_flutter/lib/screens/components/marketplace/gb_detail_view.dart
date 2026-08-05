import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../../models/gamebanana/gamebanana.dart';
import '../../../services/gamebanana/content_filter.dart';
import '../../../utils/html_to_markdown.dart';
import '../../../utils/markdown_description.dart';
import '../../../utils/marketplace_providers.dart';
import '../../../utils/state_providers.dart';
import 'gb_file_list.dart';
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
        _header(context, loc, profile.valueOrNull),
        Expanded(
          child: profile.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => _error(context, loc, error),
            data: (mod) => _body(context, loc, mod),
          ),
        ),
      ],
    );
  }

  Widget _header(BuildContext context, AppLocalizations loc, GbMod? mod) {
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
              mod?.name ?? loc.t('marketplace.loading'),
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

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
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
        const SizedBox(height: 16),
        GbFileList(
          files: mod.files,
          archivedFiles: mod.archivedFiles,
          showArchived: _showArchived,
          onToggleArchived: () =>
              setState(() => _showArchived = !_showArchived),
          onDownload: (file) => widget.onDownload(mod, file),
        ),
        const SizedBox(height: 20),
        if (mod.text case final html? when html.trim().isNotEmpty) ...[
          Text(
            loc.t('marketplace.description'),
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          // `_sText` is HTML while every description this app renders is
          // markdown, so it is converted rather than dumped into the markdown
          // widget — which would show literal tags.
          buildDescriptionMarkdown(
            context,
            htmlToMarkdown(html),
            onLaunchUrl: widget.onOpenInBrowser,
          ),
        ],
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
        if (mod.displayCategory?.name case final category?)
          _pair(Icons.folder_outlined, category, style),
        // The mod-level version, clearly the mod's own and not a file's.
        if (mod.version case final version? when version.isNotEmpty)
          _pair(Icons.sell_outlined, version, style),
        if (mod.dateUpdated ?? mod.dateAdded case final date?)
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

  Widget _error(BuildContext context, AppLocalizations loc, Object error) {
    final scheme = Theme.of(context).colorScheme;
    final isNetwork = error is GbNetworkException;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isNetwork ? Icons.wifi_off : Icons.error_outline,
              size: 40,
              color: scheme.error,
            ),
            const SizedBox(height: 12),
            Text(
              loc.t(
                isNetwork
                    ? 'marketplace.error_offline'
                    : 'marketplace.error_generic',
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => ref.invalidate(modProfileProvider(widget.modId)),
              icon: const Icon(Icons.refresh, size: 16),
              label: Text(loc.t('marketplace.retry')),
            ),
          ],
        ),
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
