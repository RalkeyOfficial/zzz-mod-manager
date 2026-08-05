import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../models/gamebanana/gb_mod.dart';
import '../../../services/gamebanana/content_filter.dart';
import '../../../utils/relative_time.dart';
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
                    const SizedBox(height: 5),
                    _Dates(mod: mod),
                    const SizedBox(height: 6),
                    // Two equal halves with their contents pushed to the outer
                    // edges: stats left, category badge hard right.
                    //
                    // The badge half is `Expanded` + `Align`, not a bare
                    // `Flexible`. A loose `Flexible` sizes itself to the badge, so
                    // the leftover space in that half fell to its *right* and the
                    // badge sat against the middle of the card rather than its
                    // right edge. `Expanded` claims the half, `Align` puts the
                    // badge at the end of it, and the badge still shrinks (its
                    // label is one ellipsised line) when a category name is long.
                    Row(
                      children: [
                        Expanded(child: _stats(context, mod)),
                        if (mod.displayCategory?.name case final category?)
                          Expanded(
                            child: Align(
                              alignment: Alignment.centerRight,
                              child: _badge(
                                context,
                                category,
                                scheme.primary,
                              ),
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
    // Fixed white, **not** a theme colour. This sits on an always-dark scrim over
    // an arbitrary image, so it is not the theme's surface — `onInverseSurface`
    // resolved to dark grey and vanished against the typical dark cover. The
    // scrim + shadow give it contrast over a light image too, which is the case a
    // plain white label would fail.
    const label = Color(0xFFFFFFFF);
    const shadows = [Shadow(color: Color(0xCC000000), blurRadius: 4)];

    return Positioned.fill(
      child: Material(
        color: Colors.black.withValues(alpha: 0.55),
        child: InkWell(
          onTap: () => setState(() => _revealed = true),
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.visibility_off_outlined,
                  color: label,
                  size: 22,
                  shadows: shadows,
                ),
                const SizedBox(height: 4),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    loc.t('marketplace.content_reveal'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: label,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      shadows: shadows,
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

/// "First released N ago · last updated N ago", the pair GameBanana shows.
///
/// Both dates rather than one because they routinely disagree by a lot — the
/// captured listing has mods added in 2024 and updated last week — and which one
/// matters depends on the question. "Is this maintained?" is the update date;
/// "is this an old classic or brand new?" is the release date.
class _Dates extends StatelessWidget {
  const _Dates({required this.mod});

  final GbMod mod;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final scheme = Theme.of(context).colorScheme;
    final style = TextStyle(fontSize: 10, color: scheme.onSurfaceVariant);

    final added = mod.dateAdded;
    // `_tsDateUpdated` is the *content* update, and it is null on a mod that has
    // never been updated (a zero timestamp means "never", not 1970). Treating a
    // non-later value as absent also covers a mod whose update date merely echoes
    // its release date, which would otherwise render the same figure twice.
    final updated = mod.dateUpdated;
    final hasUpdate =
        updated != null && added != null && updated.isAfter(added);

    if (added == null && !hasUpdate) return const SizedBox.shrink();

    // `DateTime.now()` is read here rather than injected: this is a label that is
    // rebuilt whenever the card is, and the arithmetic it feeds is unit-tested
    // separately with an injected clock (`relative_time_test.dart`).
    final now = DateTime.now().toUtc();

    return Row(
      children: [
        if (added != null)
          Flexible(
            child: _entry(
              context,
              icon: Icons.schedule,
              label: _ago(loc, added, now),
              tooltip: loc.t('marketplace.first_released',
                  params: {'date': _absolute(added)}),
              style: style,
            ),
          ),
        if (added != null && hasUpdate) const SizedBox(width: 10),
        if (hasUpdate)
          Flexible(
            child: _entry(
              context,
              icon: Icons.autorenew,
              label: _ago(loc, updated, now),
              tooltip: loc.t('marketplace.last_updated',
                  params: {'date': _absolute(updated)}),
              style: style,
            ),
          ),
      ],
    );
  }

  Widget _entry(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String tooltip,
    required TextStyle style,
  }) {
    // The tooltip carries the absolute date, so "2y" is never the only thing the
    // user can find out.
    return Tooltip(
      message: tooltip,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: style.color),
          const SizedBox(width: 3),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
        ],
      ),
    );
  }

  static String _ago(AppLocalizations loc, DateTime instant, DateTime now) {
    final age = relativeAge(instant, now: now);
    return loc.t('time.${age.unit.l10nKey}', params: {'n': '${age.count}'});
  }

  static String _absolute(DateTime date) {
    final d = date.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }
}
