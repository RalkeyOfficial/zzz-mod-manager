import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../models/gamebanana/gb_mod.dart';
import '../../../services/gamebanana/content_filter.dart';
import 'gb_thumbnail.dart';

/// One mod in the results grid: cover, name, author, stats, category badge.
///
/// Stats shown are likes / views / posts and **not downloads**: listing
/// responses do not carry `_nDownloadCount` at all, so a download count on a
/// card could only ever render as a misleading "0". `GbMod` models that
/// honestly — its counters are nullable, where null means "not in this
/// response" — and this widget simply omits what it wasn't given.
class GbModCard extends StatefulWidget {
  const GbModCard({
    super.key,
    required this.mod,
    required this.treatment,
    required this.onOpen,
  });

  final GbMod mod;
  final ContentTreatment treatment;
  final VoidCallback onOpen;

  @override
  State<GbModCard> createState() => _GbModCardState();
}

class _GbModCardState extends State<GbModCard> {
  /// Reveal is per-card and deliberately **not** persisted: clicking through one
  /// blur is consent for that mod, not a settings change. The setting is in the
  /// toolbar for anyone who wants it permanently.
  bool _revealed = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final mod = widget.mod;
    final blurred =
        widget.treatment == ContentTreatment.blur && !_revealed;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: _hovered
                ? scheme.primary.withValues(alpha: 0.6)
                : scheme.outlineVariant.withValues(alpha: 0.4),
          ),
          boxShadow: _hovered
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.18),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ]
              : null,
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          // A blurred card opens on the first click too. Making the user reveal
          // before opening would gate the detail view — which has its own,
          // clearer warning — behind an extra click for no benefit.
          onTap: widget.onOpen,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Expanded, not AspectRatio(16/9). A width-derived cover height means
              // a narrower card gets *less* room for a text block that needs the
              // same amount, so the text overflows the bottom below ~179px — and
              // the same squeeze happens at any width once the OS text scale grows
              // the title. Letting the cover absorb the leftover space instead
              // makes vertical overflow impossible: the text always gets what it
              // needs and the cover simply gets shorter. Requires the tile to have
              // a bounded height, which is why the grid sets `mainAxisExtent`.
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    GbThumbnail(
                      image: mod.coverImage,
                      treatment: widget.treatment,
                      revealed: _revealed,
                    ),
                    if (blurred) _revealOverlay(context, loc),
                    if (mod.isObsolete)
                      Positioned(
                        top: 6,
                        left: 6,
                        child: _badge(
                          context,
                          loc.t('marketplace.badge_obsolete'),
                          scheme.tertiary,
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      mod.name ?? loc.t('marketplace.untitled_mod'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      mod.submitter?.name ?? '—',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(child: _stats(context, mod)),
                        if (mod.displayCategory?.name case final category?)
                          Flexible(
                            child: _badge(
                              context,
                              category,
                              scheme.primary,
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _revealOverlay(BuildContext context, AppLocalizations loc) {
    final scheme = Theme.of(context).colorScheme;
    return Positioned.fill(
      child: Material(
        color: Colors.black.withValues(alpha: 0.35),
        child: InkWell(
          onTap: () => setState(() => _revealed = true),
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.visibility_off_outlined,
                    color: scheme.onInverseSurface, size: 22),
                const SizedBox(height: 4),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    loc.t('marketplace.content_reveal'),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: scheme.onInverseSurface,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _stats(BuildContext context, GbMod mod) {
    final scheme = Theme.of(context).colorScheme;
    final style = TextStyle(fontSize: 11, color: scheme.onSurfaceVariant);
    // Each entry is omitted when the response didn't carry it, rather than
    // rendered as a zero.
    final entries = <(IconData, int)>[
      if (mod.likeCount case final n?) (Icons.favorite_outline, n),
      if (mod.viewCount case final n?) (Icons.visibility_outlined, n),
      if (mod.postCount case final n?) (Icons.mode_comment_outlined, n),
    ];
    if (entries.isEmpty) return const SizedBox.shrink();

    // FittedBox because this row's slot is not a fixed width and its content is
    // not a fixed length: cards reflow at a 300px max extent down to an 800px
    // minimum window, the app has its own zoom scale, and a count can reach
    // "1.2M". Scaling down keeps every digit readable, where clipping would hide
    // content and a plain Row overflows — which is what it did.
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: AlignmentDirectional.centerStart,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (index, (icon, count)) in entries.indexed) ...[
            // Between items only. A trailing gap after the last entry pushed the
            // row 8px wider than its content for no visual benefit.
            if (index > 0) const SizedBox(width: 8),
            Icon(icon, size: 12, color: scheme.onSurfaceVariant),
            const SizedBox(width: 2),
            Text(_compact(count), style: style),
          ],
        ],
      ),
    );
  }

  Widget _badge(BuildContext context, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.w600),
      ),
    );
  }

  /// `12.3k` / `1.2M`. Popular ZZZ mods run to six figures of views, which would
  /// otherwise wrap the stats row.
  static String _compact(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
    return '$n';
  }
}
