import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../../models/gamebanana/gb_top_sub.dart';
import '../../../services/gamebanana/content_filter.dart';
import '../../../utils/marketplace_providers.dart';
import '../../../utils/state_providers.dart';

/// The "best of" carousel: one large card at a time, stepped through with arrows,
/// covering GameBanana's top three submissions for each of seven time windows
/// (today, this week, this month, 3/6 months, this year, all time).
///
/// Backed by `Game/<id>/TopSubs`, a dedicated endpoint that returns exactly this —
/// 3 × 7 entries each tagged with its `_sPeriod`. It is **not** synthesised from the
/// browse listing, which could not produce it: `Mod/Index` has no date-window filter
/// and its like counts are lifetime totals, so "best of this week" is not derivable
/// from anything else the API offers.
///
/// Shown only on the unfiltered "All" view. Once the user picks a category or
/// searches, a fixed game-wide list is no longer about what they are looking at, and
/// it costs vertical space the grid wants.
class GbTopSubsCarousel extends ConsumerStatefulWidget {
  const GbTopSubsCarousel({
    super.key,
    required this.onOpenMod,
    this.autoAdvanceInterval = defaultAutoAdvanceInterval,
  });

  final void Function(int modId) onOpenMod;

  /// How long each card is shown before advancing, or **null to never advance**.
  ///
  /// Injectable for two reasons. Tests need it off, because an auto-advancing
  /// widget makes `pumpAndSettle` walk the carousel forward while it settles — so
  /// any test asserting "the first card is showing" would be racing the timer. And
  /// it is the knob to turn if the dwell time feels wrong.
  final Duration? autoAdvanceInterval;

  static const Duration defaultAutoAdvanceInterval = Duration(seconds: 6);

  @override
  ConsumerState<GbTopSubsCarousel> createState() => _GbTopSubsCarouselState();
}

class _GbTopSubsCarouselState extends ConsumerState<GbTopSubsCarousel> {
  static const double _height = 250;
  static const Duration _slideDuration = Duration(milliseconds: 260);

  final PageController _controller = PageController();
  int _index = 0;

  /// Keyed by mod id, not page index: the visible set shrinks and shifts when the
  /// content filter changes, and a revealed mod should stay revealed rather than
  /// handing its consent to whatever slid into that slot.
  final Set<int> _revealed = <int>{};

  Timer? _autoAdvance;

  /// How many cards are currently on screen, so the timer can wrap without
  /// reaching back into `build`'s locals.
  int _count = 0;

  /// True while the pointer is over the carousel.
  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    _restartAutoAdvance();
  }

  @override
  void didUpdateWidget(GbTopSubsCarousel old) {
    super.didUpdateWidget(old);
    if (old.autoAdvanceInterval != widget.autoAdvanceInterval) {
      _restartAutoAdvance();
    }
  }

  @override
  void dispose() {
    // Before the controller: a tick that landed after disposal would call
    // animateToPage on a dead controller.
    _autoAdvance?.cancel();
    _controller.dispose();
    super.dispose();
  }

  /// (Re)starts the dwell timer from zero.
  ///
  /// Called after **every** page change, whoever caused it — arrow, drag or the
  /// timer itself — so a card the user just navigated to gets a full interval
  /// rather than the remainder of the previous one.
  void _restartAutoAdvance() {
    _autoAdvance?.cancel();
    final interval = widget.autoAdvanceInterval;
    if (interval == null || _hovered) return;
    _autoAdvance = Timer.periodic(interval, (_) => _advanceAutomatically());
  }

  void _advanceAutomatically() {
    // `hasClients` is not defensive habit: when the content filter hides every
    // entry this widget collapses to a `SizedBox`, the PageView goes away, and the
    // controller is left attached to nothing while the timer keeps ticking.
    if (!mounted || !_controller.hasClients || _count < 2) return;

    // Wraps, unlike the arrows. The arrows clamp because a disabled arrow tells the
    // user where the list ends; an auto-advance that clamped would simply stop
    // forever at the last card, which is not "auto" at all.
    final next = (_index + 1) % _count;
    _controller.animateToPage(
      next,
      duration: _slideDuration,
      curve: Curves.easeOutCubic,
    );
  }

  void _setHovered(bool hovered) {
    if (_hovered == hovered) return;
    _hovered = hovered;
    // Paused rather than merely skipped on tick: the point is that the card under
    // the cursor stays put for as long as the user is reading it.
    if (hovered) {
      _autoAdvance?.cancel();
    } else {
      _restartAutoAdvance();
    }
  }

  void _step(int delta, int count) {
    // Clamped rather than wrapping, and the arrows disable at the ends. Wrapping
    // would need an unbounded page count to avoid a jump, and a disabled arrow says
    // "you are at the end" more clearly than silently looping to the start.
    final target = (_index + delta).clamp(0, count - 1);
    if (target == _index) return;
    _controller.animateToPage(
      target,
      duration: _slideDuration,
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final subs = ref.watch(topSubsProvider);
    final filter = ref.watch(contentFilterProvider);

    // Absent rather than empty on loading or error. This is a decorative strip
    // above the real content: a spinner or an error box here would report a problem
    // the user cannot act on and did not ask about, while the grid below already
    // surfaces any outage.
    final all = subs.valueOrNull;
    if (all == null || all.isEmpty) return const SizedBox.shrink();

    // Flattened in period order, so stepping right walks today -> … -> all time.
    // Filtered first: with adult content hidden almost nothing survives (20 of 21
    // captured entries are `warn`/`hide`), and an empty carousel frame would look
    // broken where showing nothing at all does not.
    final visible = [
      for (final group in groupTopSubs(all))
        for (final sub in group.mods)
          if (contentTreatment(sub.effectiveVisibility, filter)
              case final treatment when treatment != ContentTreatment.omit)
            (sub: sub, period: group.period, treatment: treatment),
    ];
    if (visible.isEmpty) return const SizedBox.shrink();

    final count = visible.length;
    // Kept on the state so the timer can wrap without reaching into these locals.
    _count = count;
    // The visible set can shrink under us when the filter changes, leaving the
    // controller past the end.
    final index = _index.clamp(0, count - 1);

    return MouseRegion(
      // Hovering pauses the rotation. Anyone with the pointer over the carousel is
      // reading or about to click, and sliding the target out from under them is the
      // single most annoying thing an auto-advancing carousel can do.
      onEnter: (_) => _setHovered(true),
      onExit: (_) => _setHovered(false),
      child: SizedBox(
        height: _height,
        child: Stack(
          children: [
            PageView.builder(
              controller: _controller,
              itemCount: count,
              onPageChanged: (i) {
                setState(() => _index = i);
                // Whatever moved the page — arrow, drag, or the timer — the dwell
                // starts over, so a card the user chose isn't shown for a sliver of
                // an interval before sliding away.
                _restartAutoAdvance();
              },
              itemBuilder: (context, i) {
                final entry = visible[i];
                return _Card(
                  sub: entry.sub,
                  period: entry.period,
                  treatment: entry.treatment,
                  revealed: _revealed.contains(entry.sub.idRow),
                  onReveal: () =>
                      setState(() => _revealed.add(entry.sub.idRow)),
                  onOpen: () => widget.onOpenMod(entry.sub.idRow),
                );
              },
            ),
            _Arrow(
              alignment: Alignment.centerLeft,
              icon: Icons.chevron_left,
              tooltip: context.loc.t('marketplace.carousel_prev'),
              onPressed: index > 0 ? () => _step(-1, count) : null,
            ),
            _Arrow(
              alignment: Alignment.centerRight,
              icon: Icons.chevron_right,
              tooltip: context.loc.t('marketplace.carousel_next'),
              onPressed: index < count - 1 ? () => _step(1, count) : null,
            ),
            Positioned(
              right: 14,
              bottom: 12,
              // Also decoration — it must not swallow clicks meant for the card.
              child: IgnorePointer(
                child: _Counter(index: index + 1, total: count),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One full-bleed card: the cover image fills it, everything else sits on top.
class _Card extends StatelessWidget {
  const _Card({
    required this.sub,
    required this.period,
    required this.treatment,
    required this.revealed,
    required this.onReveal,
    required this.onOpen,
  });

  final GbTopSub sub;
  final GbTopSubPeriod period;
  final ContentTreatment treatment;
  final bool revealed;
  final VoidCallback onReveal;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final blurred = treatment == ContentTreatment.blur && !revealed;

    return Stack(
      fit: StackFit.expand,
      children: [
        _image(context, blurred),
        // A scrim under the text rather than over the whole image: the title has to
        // stay readable on a bright cover without dimming the artwork that is the
        // point of a full-bleed card.
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.center,
              colors: [Color(0xD9000000), Color(0x00000000)],
            ),
          ),
        ),
        // Tap layer beneath the arrows and the reveal overlay, so those win.
        Positioned.fill(
          child: Material(
            color: Colors.transparent,
            child: InkWell(onTap: onOpen),
          ),
        ),
        // IgnorePointer on both: they are decoration layered *above* the tap layer,
        // and a `Text` does absorb a hit — without this, clicking the title (the
        // most obvious thing to click) did nothing at all.
        Positioned(
          left: 14,
          top: 12,
          child: IgnorePointer(
            child: _PeriodBadge(
              label: loc.t('marketplace.period_${period.l10nKey}'),
            ),
          ),
        ),
        Positioned(
          left: 16,
          right: 90,
          bottom: 14,
          child: IgnorePointer(child: _Caption(sub: sub)),
        ),
        if (blurred) Positioned.fill(child: _RevealOverlay(onReveal: onReveal)),
      ],
    );
  }

  Widget _image(BuildContext context, bool blurred) {
    final scheme = Theme.of(context).colorScheme;
    // Prefer the large image here — this card is far wider than the 220px
    // thumbnail the strip tiles used.
    final url = sub.imageUrl ?? sub.thumbnailUrl;

    Widget placeholder() => ColoredBox(
      color: scheme.surfaceContainerHighest,
      child: Center(
        child: Icon(
          Icons.image_not_supported_outlined,
          size: 32,
          color: scheme.onSurface.withValues(alpha: 0.3),
        ),
      ),
    );

    if (url == null || url.isEmpty) return placeholder();

    Widget image = Image.network(
      url,
      fit: BoxFit.cover,
      errorBuilder: (context, _, __) => placeholder(),
    );
    if (blurred) {
      image = ImageFiltered(
        imageFilter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: image,
      );
    }
    return image;
  }
}

/// The period label, in a black box at the top-left.
///
/// Deliberately literal black rather than a theme colour: it sits on arbitrary
/// artwork, not on a themed surface, so it must be legible in both themes and over
/// any image.
class _PeriodBadge extends StatelessWidget {
  const _PeriodBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xE6000000),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0x33FFFFFF)),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Color(0xFFFFFFFF),
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}

class _Caption extends StatelessWidget {
  const _Caption({required this.sub});

  final GbTopSub sub;

  static const _shadows = [Shadow(color: Color(0xCC000000), blurRadius: 6)];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          sub.name ?? context.loc.t('marketplace.untitled_mod'),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Color(0xFFFFFFFF),
            fontSize: 19,
            fontWeight: FontWeight.w700,
            height: 1.15,
            shadows: _shadows,
          ),
        ),
        const SizedBox(height: 5),
        Row(
          children: [
            if (sub.submitter?.name case final author?) ...[
              Flexible(
                child: Text(
                  author,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xE6FFFFFF),
                    fontSize: 12,
                    shadows: _shadows,
                  ),
                ),
              ),
              const SizedBox(width: 12),
            ],
            if (sub.likeCount case final likes?) ...[
              const Icon(
                Icons.favorite_outline,
                size: 12,
                color: Color(0xE6FFFFFF),
                shadows: _shadows,
              ),
              const SizedBox(width: 4),
              Text(
                _compact(likes),
                style: const TextStyle(
                  color: Color(0xE6FFFFFF),
                  fontSize: 12,
                  shadows: _shadows,
                ),
              ),
            ],
            if (sub.rootCategory?.name case final category?) ...[
              const SizedBox(width: 12),
              Flexible(
                child: Text(
                  category,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xB3FFFFFF),
                    fontSize: 12,
                    shadows: _shadows,
                  ),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }

  static String _compact(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
    return '$n';
  }
}

/// Blur-and-reveal, matching the grid cards' rule.
///
/// No reason text here, unlike the detail view: `TopSubs` carries no
/// `_aContentRatings`, so this endpoint can flag a mod but never explain why.
class _RevealOverlay extends StatelessWidget {
  const _RevealOverlay({required this.onReveal});

  final VoidCallback onReveal;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;

    return Material(
      color: Colors.black.withValues(alpha: 0.55),
      child: InkWell(
        onTap: onReveal,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.visibility_off_outlined,
                color: Color(0xFFFFFFFF),
                size: 26,
                shadows: [Shadow(color: Color(0xCC000000), blurRadius: 4)],
              ),
              const SizedBox(height: 6),
              Text(
                loc.t('marketplace.content_reveal'),
                style: const TextStyle(
                  color: Color(0xFFFFFFFF),
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  shadows: [Shadow(color: Color(0xCC000000), blurRadius: 4)],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// `1 / 21` — with 21 entries a dot indicator would be unreadable, and the period
/// badge alone doesn't say how far through the list you are.
class _Counter extends StatelessWidget {
  const _Counter({required this.index, required this.total});

  final int index;
  final int total;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xB3000000),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        context.loc.t(
          'marketplace.carousel_position',
          params: {'index': '$index', 'total': '$total'},
        ),
        style: const TextStyle(
          color: Color(0xFFFFFFFF),
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _Arrow extends StatelessWidget {
  const _Arrow({
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
            iconSize: 26,
            icon: Icon(icon, color: Color(enabled ? 0xFFFFFFFF : 0x66FFFFFF)),
          ),
        ),
      ),
    );
  }
}
