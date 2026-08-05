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
  int _galleryIndex = 0;
  bool _revealed = false;
  bool _showArchived = false;

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
    final url = mod?.profileUrl ??
        'https://gamebanana.com/mods/${widget.modId}';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border(
          bottom:
              BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.4)),
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
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
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
          _notice(context, loc.t('marketplace.remote_missing'),
              Theme.of(context).colorScheme.error),
        if (mod.isObsolete)
          // Explicitly *not* the same thing as removed: the mod still exists and
          // still downloads, its author just flagged it superseded.
          _notice(context, loc.t('marketplace.obsolete_notice'),
              Theme.of(context).colorScheme.tertiary),
        if (treatment != ContentTreatment.show && !_revealed)
          _contentWarning(context, loc, mod),
        _gallery(context, mod, treatment),
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
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.w700),
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
      BuildContext context, AppLocalizations loc, GbMod mod) {
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
                  Text(reasons,
                      style: TextStyle(
                          fontSize: 11, color: scheme.onSurfaceVariant)),
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

  Widget _gallery(BuildContext context, GbMod mod, ContentTreatment treatment) {
    if (mod.images.isEmpty) return const SizedBox.shrink();
    final index = _galleryIndex.clamp(0, mod.images.length - 1);

    return Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: GbThumbnail(
              image: mod.images[index],
              treatment: treatment,
              revealed: _revealed,
              minWidth: 800,
              fit: BoxFit.contain,
            ),
          ),
        ),
        if (mod.images.length > 1) ...[
          const SizedBox(height: 8),
          SizedBox(
            height: 56,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
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
                      minWidth: 100,
                    ),
                  ),
                );
              },
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
            loc.t('marketplace.updated_on',
                params: {'date': _date(date)}),
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
            Icon(isNetwork ? Icons.wifi_off : Icons.error_outline,
                size: 40, color: scheme.error),
            const SizedBox(height: 12),
            Text(
              loc.t(isNetwork
                  ? 'marketplace.error_offline'
                  : 'marketplace.error_generic'),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () =>
                  ref.invalidate(modProfileProvider(widget.modId)),
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
