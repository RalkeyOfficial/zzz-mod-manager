import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_theme.dart';
import '../../../core/palette.dart';
import '../../../core/type_scale.dart';
import '../../../l10n/app_localizations.dart';
import '../../../models/gamebanana/gb_file.dart';
import '../../../models/gamebanana/gb_mod.dart';
import '../../../models/gamebanana/gb_top_sub.dart';
import '../../../services/gamebanana/content_filter.dart';
import '../../../services/gamebanana/file_selection.dart';
import '../../../services/installed_mods_index.dart';
import '../../../utils/marketplace_providers.dart';
import '../../../utils/state_providers.dart';
import '../zenith_controls.dart';
import 'gb_mod_card.dart';

/// The "best of" carousel: one large slide at a time, stepped through with arrows,
/// covering GameBanana's top three submissions for each of seven time windows
/// (today, this week, this month, 3/6 months, this year, all time).
///
/// Backed by `Game/<id>/TopSubs`, a dedicated endpoint that returns exactly this —
/// 3 × 7 entries each tagged with its `_sPeriod`. It is **not** synthesised from the
/// browse listing, which could not produce it: `Mod/Index` has no date-window filter
/// and its like counts are lifetime totals, so "best of this week" is not derivable
/// from anything else the API offers.
///
/// An entry carries no character and no download count; one `Mod/Multi` for the entries fills both in, and until it
/// answers the slide shows the root category and leaves downloads out.
class GbTopSubsCarousel extends ConsumerStatefulWidget {
  const GbTopSubsCarousel({
    super.key,
    required this.onOpenMod,
    this.onInstallFile,
    this.autoAdvanceInterval = defaultAutoAdvanceInterval,
  });

  final void Function(int modId) onOpenMod;

  /// Queues one file of a mod as an install, as a grid card's Install does. Null opens the mod page instead.
  final void Function(int modId, GbFile file)? onInstallFile;

  /// How long each slide is shown before advancing, or **null to never advance**.
  ///
  /// Injectable for two reasons. Tests need it off, because an auto-advancing
  /// widget makes `pumpAndSettle` walk the carousel forward while it settles — so
  /// any test asserting "the first slide is showing" would be racing the timer. And
  /// it is the knob to turn if the dwell time feels wrong.
  final Duration? autoAdvanceInterval;

  static const Duration defaultAutoAdvanceInterval = Duration(seconds: 6);

  /// The slide's height.
  static const double height = 280;

  @override
  ConsumerState<GbTopSubsCarousel> createState() => _GbTopSubsCarouselState();
}

class _GbTopSubsCarouselState extends ConsumerState<GbTopSubsCarousel> {
  static const Duration _slideDuration = Duration(milliseconds: 260);

  final PageController _controller = PageController();
  int _index = 0;

  /// Keyed by mod id, not page index: the visible set shrinks and shifts when the
  /// content filter changes, and a revealed mod should stay revealed rather than
  /// handing its consent to whatever slid into that slot.
  final Set<int> _revealed = <int>{};

  Timer? _autoAdvance;

  /// How many slides are currently on screen, so the timer can wrap without
  /// reaching back into `build`'s locals.
  int _count = 0;

  /// True while the pointer is over the carousel.
  bool _hovered = false;

  /// True while the mod detail view is open over the grid.
  bool _detailOpen = false;

  /// Nothing rotates while anything is holding it. Two holds, one rule.
  bool get _paused => _hovered || _detailOpen;

  /// The ink theme the overlays are drawn in, built once per accent rather than on every slide change.
  ThemeData? _dark;
  AccentChoice? _darkAccent;

  @override
  void initState() {
    super.initState();
    // `read`, not `watch`: `initState` cannot watch, and this is only the
    // starting value — `build` listens for every change after it.
    _detailOpen = ref.read(marketplaceRoutesProvider).isNotEmpty;
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

  /// (Re)starts the dwell timer from zero, or leaves it stopped while paused.
  ///
  /// Called after **every** page change, whoever caused it — arrow, dot, drag or the
  /// timer itself — so a slide the user just navigated to gets a full interval
  /// rather than the remainder of the previous one. Also the one way a hold is
  /// applied or lifted, which is why it cancels before it checks: releasing one
  /// hold while another is still on must not start the timer.
  void _restartAutoAdvance() {
    _autoAdvance?.cancel();
    final interval = widget.autoAdvanceInterval;
    if (interval == null || _paused) return;
    _autoAdvance = Timer.periodic(interval, (_) => _step(1));
  }

  void _setHovered(bool hovered) {
    if (_hovered == hovered) return;
    _hovered = hovered;
    // Paused rather than merely skipped on tick: the slide under the cursor stays
    // put for as long as the user is reading it. Leaving restarts the full interval.
    _restartAutoAdvance();
  }

  void _setDetailOpen(bool open) {
    if (_detailOpen == open) return;
    _detailOpen = open;
    _restartAutoAdvance();
  }

  /// Moves [delta] slides, wrapping at both ends — the arrows and the timer alike.
  void _step(int delta) {
    // `hasClients` is not defensive habit: when the content filter hides every
    // entry this widget collapses to a `SizedBox`, the PageView goes away, and the
    // controller is left attached to nothing while the timer keeps ticking.
    if (!mounted || !_controller.hasClients || _count < 2) return;
    _goTo((_index + delta) % _count);
  }

  void _goTo(int target) {
    if (target == _index || !_controller.hasClients) return;
    _controller.animateToPage(target, duration: _slideDuration, curve: Curves.easeOutCubic);
  }

  @override
  Widget build(BuildContext context) {
    // The browse view stays mounted under the pages opened over it, so without this
    // the rotation carries on behind a full-screen overlay. Above the early returns
    // because `ref.listen` has to run on every build.
    ref.listen(marketplaceRoutesProvider, (_, next) {
      _setDetailOpen(next.isNotEmpty);
    });

    final subs = ref.watch(topSubsProvider);
    final filter = ref.watch(contentFilterProvider);
    // While the library snapshot loads, `empty` means "nothing is known to be
    // installed" — Install rather than an In library that might be wrong. Same
    // reading as the grid beneath, so the two cannot disagree about a mod that
    // appears in both.
    final installed = ref.watch(installedModsIndexProvider).valueOrNull ?? InstalledModsIndex.empty;

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
          if (contentTreatment(sub.effectiveVisibility, filter) case final treatment
              when treatment != ContentTreatment.omit)
            (sub: sub, period: group.period, treatment: treatment),
    ];
    if (visible.isEmpty) return const SizedBox.shrink();

    final enrichment =
        ref.watch(modEnrichmentProvider(ModIdList([for (final sub in all) sub.idRow]))).valueOrNull ?? const {};

    final count = visible.length;
    // Kept on the state so the timer can wrap without reaching into these locals.
    _count = count;
    // The visible set can shrink under us when the filter changes, leaving the
    // controller past the end.
    final index = _index.clamp(0, count - 1);
    final current = visible[index];
    // The dots are the current period's entries, so they say where in "best of this week" the slide is.
    final periodSlides = [
      for (var i = 0; i < count; i++)
        if (visible[i].period == current.period) i,
    ];

    // The slide's overlays are always drawn on dark, over artwork, whatever the app's theme, so they take the ink
    // theme: its ground, its text and its buttons.
    final accent = ref.watch(accentProvider);
    if (_dark == null || _darkAccent != accent) {
      _dark = buildAppTheme(brightness: Brightness.dark, accent: accent);
      _darkAccent = accent;
    }
    final dark = _dark!;
    final palette = ZenithPalette.of(context);
    // The info box stops short of the position pill beside it, whatever the pill's dots and count make its width.
    final boxRight = math.max(
      _arrowClearance,
      _Position.bottomRight + _Position.widthFor(context, dots: periodSlides.length, total: count) + 12,
    );

    return MouseRegion(
      // Hovering pauses the rotation. Anyone with the pointer over the carousel is
      // reading or about to click, and sliding the target out from under them is the
      // single most annoying thing an auto-advancing carousel can do.
      onEnter: (_) => _setHovered(true),
      onExit: (_) => _setHovered(false),
      child: Container(
        height: GbTopSubsCarousel.height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: palette.outline),
        ),
        clipBehavior: Clip.antiAlias,
        child: Theme(
          data: dark,
          child: Stack(
            children: [
              PageView.builder(
                controller: _controller,
                itemCount: count,
                onPageChanged: (i) {
                  setState(() => _index = i);
                  // Whatever moved the page, the dwell starts over, so a slide the user
                  // chose isn't shown for a sliver of an interval before sliding away.
                  _restartAutoAdvance();
                },
                itemBuilder: (context, i) {
                  final entry = visible[i];
                  final id = entry.sub.idRow;
                  return _Slide(
                    sub: entry.sub,
                    period: entry.period,
                    treatment: entry.treatment,
                    enrichment: enrichment[id],
                    installedAs: installed.installsOfMod(id),
                    revealed: _revealed.contains(id),
                    boxRight: boxRight,
                    onReveal: () => setState(() => _revealed.add(id)),
                    onOpen: () => widget.onOpenMod(id),
                    onInstallFile: widget.onInstallFile == null ? null : (file) => widget.onInstallFile!(id, file),
                  );
                },
              ),
              if (count > 1) ...[
                Positioned(
                  left: 14,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: _Arrow(
                      icon: Icons.chevron_left_rounded,
                      tooltip: context.loc.t('marketplace.previous'),
                      onPressed: () => _step(-1),
                    ),
                  ),
                ),
                Positioned(
                  right: 14,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: _Arrow(
                      icon: Icons.chevron_right_rounded,
                      tooltip: context.loc.t('marketplace.next'),
                      onPressed: () => _step(1),
                    ),
                  ),
                ),
              ],
              Positioned(
                right: _Position.bottomRight,
                bottom: _Position.bottomRight,
                child: _Position(
                  slides: periodSlides,
                  labels: [
                    for (final slide in periodSlides)
                      visible[slide].sub.name ?? context.loc.t('marketplace.untitled_mod'),
                  ],
                  current: index,
                  total: count,
                  onDot: _goTo,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// From the slide's left edge to the info box: past the left arrow (14 + 36 + 14), which would otherwise cover the
/// title. The least the box keeps from the right edge too, for the right arrow.
const double _arrowClearance = 64;

/// One slide: the cover fills it, and the info box sits at the bottom-left.
class _Slide extends StatelessWidget {
  const _Slide({
    required this.sub,
    required this.period,
    required this.treatment,
    required this.enrichment,
    required this.installedAs,
    required this.revealed,
    required this.boxRight,
    required this.onReveal,
    required this.onOpen,
    required this.onInstallFile,
  });

  final GbTopSub sub;
  final GbTopSubPeriod period;
  final ContentTreatment treatment;

  /// The entry's `Mod/Multi` record: its character, download count and files. Null until it answers.
  final GbMod? enrichment;

  /// Mod folders in the local library that came from this remote mod, or empty.
  final List<String> installedAs;

  final bool revealed;

  /// From the slide's right edge to the info box, clear of the position pill.
  final double boxRight;

  final VoidCallback onReveal;
  final VoidCallback onOpen;
  final void Function(GbFile file)? onInstallFile;

  @override
  Widget build(BuildContext context) {
    final blurred = treatment == ContentTreatment.blur && !revealed;

    return Stack(
      fit: StackFit.expand,
      children: [
        // The ink ground under the cover, so a blur fades into dark at the edges rather than into the page.
        ColoredBox(color: ZenithPalette.of(context).ground),
        _image(context, blurred),
        // The slide opens its mod, under everything drawn over it.
        Positioned.fill(
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(onTap: onOpen, behavior: HitTestBehavior.opaque),
          ),
        ),
        if (blurred) Positioned.fill(child: _RevealOverlay(onReveal: onReveal)),
        // After the reveal overlay: which period this is the best of, the name and the buttons are not adult content.
        Positioned.fill(
          child: Column(
            children: [
              // The reveal label takes what the box leaves above it, so a box grown by a long name never covers it.
              Expanded(child: blurred ? const _RevealLabel() : const SizedBox.shrink()),
              Padding(
                padding: EdgeInsets.fromLTRB(_arrowClearance, 0, boxRight, 20),
                child: Align(
                  alignment: Alignment.bottomLeft,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 460),
                    child: _InfoBox(
                      sub: sub,
                      period: period,
                      enrichment: enrichment,
                      installedAs: installedAs,
                      onOpen: onOpen,
                      onInstall: () {
                        final file = selectDefaultFile(enrichment?.files).file;
                        if (file != null && onInstallFile != null) {
                          onInstallFile!(file);
                        } else {
                          onOpen();
                        }
                      },
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _image(BuildContext context, bool blurred) {
    final palette = ZenithPalette.of(context);
    // The large image: the slide is far wider than a grid card. `urlAtLeast` falls back to the original rather
    // than inventing a filename, which for a TopSubs entry *is* the 800px render.
    final url = sub.image?.urlAtLeast(800);

    Widget placeholder() => DottedGround(ground: palette.groundFor(ElementTone.neutral));

    if (url == null || url.isEmpty) return placeholder();

    Widget image = Image.network(url, fit: BoxFit.cover, errorBuilder: (context, _, _) => placeholder());
    if (blurred) {
      image = ImageFiltered(imageFilter: ImageFilter.blur(sigmaX: 24, sigmaY: 24), child: image);
    }
    return image;
  }
}

/// The box at the slide's bottom-left: the period and character badges, the name, the byline and stats, and the
/// buttons.
class _InfoBox extends ConsumerWidget {
  const _InfoBox({
    required this.sub,
    required this.period,
    required this.enrichment,
    required this.installedAs,
    required this.onOpen,
    required this.onInstall,
  });

  final GbTopSub sub;
  final GbTopSubPeriod period;
  final GbMod? enrichment;
  final List<String> installedAs;
  final VoidCallback onOpen;
  final VoidCallback onInstall;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    // TopSubs names only the root; the enrichment's category is the character for a skin.
    final category = enrichment?.category?.name ?? sub.rootCategory?.name;
    final small = smallButtonStyle(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      decoration: BoxDecoration(
        color: palette.ground.withValues(alpha: 0.86),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: palette.line),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 10,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              ZenithBadge(label: loc.t('marketplace.period_${period.l10nKey}'), tone: palette.badgeOn),
              if (category != null) ZenithBadge(label: category, tone: palette.badgeOverArt),
            ],
          ),
          Text(
            sub.name ?? loc.t('marketplace.untitled_mod'),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: text.headlineMedium!.copyWith(color: palette.text),
          ),
          Wrap(
            spacing: 14,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (sub.submitter?.name case final author?)
                Text(
                  loc.t('marketplace.by_author', params: {'author': author}),
                  style: text.bodySmall!.copyWith(color: palette.text2),
                ),
              if (sub.likeCount case final likes?)
                GbStat(icon: Icons.favorite_border_rounded, value: compactCount(likes)),
              if (enrichment?.downloadCount case final downloads?)
                GbStat(icon: Icons.download_rounded, value: compactCount(downloads)),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (installedAs.isEmpty)
                  FilledButton(style: small, onPressed: onInstall, child: Text(loc.t('marketplace.install')))
                else
                  OutlinedButton(
                    style: small,
                    onPressed: () => showMarketplaceModInLibrary(context, ref, installedAs),
                    child: Text(loc.t('marketplace.in_library')),
                  ),
                OutlinedButton(style: small, onPressed: onOpen, child: Text(loc.t('marketplace.view_mod'))),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The scrim over a flagged cover, which reveals it on a click, or on Enter or Space once Tab has reached it. Its
/// label is [_RevealLabel], laid out with the info box so the box never covers it.
class _RevealOverlay extends StatefulWidget {
  const _RevealOverlay({required this.onReveal});

  final VoidCallback onReveal;

  @override
  State<_RevealOverlay> createState() => _RevealOverlayState();
}

class _RevealOverlayState extends State<_RevealOverlay> {
  bool _focusShown = false;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    return Semantics(
      container: true,
      button: true,
      label: loc.t('marketplace.mature_content'),
      hint: loc.t('marketplace.content_reveal'),
      onTap: widget.onReveal,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowFocusHighlight: (shown) => setState(() => _focusShown = shown),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onReveal();
              return null;
            },
          ),
        },
        child: GestureDetector(
          onTap: widget.onReveal,
          behavior: HitTestBehavior.opaque,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: palette.artworkScrim,
              // The app's keyboard focus ring, drawn inside the slide's rounded clip.
              border: _focusShown ? Border.all(color: palette.accent, width: 2) : null,
            ),
          ),
        ),
      ),
    );
  }
}

/// The reveal's words over a flagged cover, centred in the space above the info box and scaled down when a tall box
/// leaves less than they need.
///
/// No reason text, unlike the detail view: `TopSubs` carries no `_aContentRatings`, so this endpoint can flag a
/// mod but never explain why.
class _RevealLabel extends StatelessWidget {
  const _RevealLabel();

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    // Presses fall through to the overlay under it, which also carries these words for a screen reader.
    return IgnorePointer(
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(_arrowClearance, 8, _arrowClearance, 6),
          child: Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                spacing: 4,
                children: [
                  Icon(Icons.visibility_off_outlined, size: 20, color: palette.text),
                  Text(
                    loc.t('marketplace.mature_content'),
                    style: text.bodyMedium!.copyWith(color: palette.text, fontWeight: FontWeight.w600),
                  ),
                  Text(
                    loc.t('marketplace.content_reveal'),
                    style: text.labelSmall!.copyWith(color: palette.text2, fontWeight: FontWeight.w400),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The pill at the bottom-right: a dot per entry of the current period, the current one wide in the accent, and
/// "n / total".
class _Position extends StatelessWidget {
  const _Position({
    required this.slides,
    required this.labels,
    required this.current,
    required this.total,
    required this.onDot,
  });

  /// The indexes of the current period's slides.
  final List<int> slides;

  /// The mod name of each of [slides], which its dot is called for a screen reader.
  final List<String> labels;

  final int current;
  final int total;
  final ValueChanged<int> onDot;

  /// From the slide's bottom and right edges to the pill.
  static const double bottomRight = 18;

  static const double _padding = 10;
  static const double _gap = 10;
  static const double _dotGap = 5;
  static const double _dot = 8;
  static const double _dotCurrent = 22;

  /// The pill's width with [dots] dots and the widest count [total] can show, so the box beside it can stop short.
  static double widthFor(BuildContext context, {required int dots, required int total}) {
    final count = TextPainter(
      text: TextSpan(text: _count(context, total, total), style: ZenithType.of(context).monoSmall),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final width = count.width;
    count.dispose();
    final dotsWidth = dots == 0 ? 0 : _dotCurrent + (dots - 1) * (_dot + _dotGap);
    return (_padding * 2 + dotsWidth + _gap + width).ceilToDouble();
  }

  static String _count(BuildContext context, int index, int total) =>
      context.loc.t('marketplace.carousel_position', params: {'index': '$index', 'total': '$total'});

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: _padding, vertical: 6),
      decoration: BoxDecoration(color: palette.ground.withValues(alpha: 0.75), borderRadius: BorderRadius.circular(99)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: _gap,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            spacing: _dotGap,
            children: [
              for (final (i, slide) in slides.indexed)
                _Dot(
                  key: ValueKey('carousel-dot-$slide'),
                  label: labels[i],
                  current: slide == current,
                  onPressed: () => onDot(slide),
                ),
            ],
          ),
          Text(
            _count(context, current + 1, total),
            style: ZenithType.of(context).monoSmall.copyWith(color: palette.text2),
          ),
        ],
      ),
    );
  }
}

/// One slide's dot in the pill: a button that goes to it, by a click or by Enter or Space once Tab has reached it.
class _Dot extends StatefulWidget {
  const _Dot({super.key, required this.label, required this.current, required this.onPressed});

  final String label;
  final bool current;
  final VoidCallback onPressed;

  @override
  State<_Dot> createState() => _DotState();
}

class _DotState extends State<_Dot> {
  bool _focusShown = false;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    return Semantics(
      container: true,
      button: true,
      selected: widget.current,
      label: widget.label,
      onTap: widget.onPressed,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowFocusHighlight: (shown) => setState(() => _focusShown = shown),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onPressed();
              return null;
            },
          ),
        },
        child: GestureDetector(
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: widget.current ? _Position._dotCurrent : _Position._dot,
            height: _Position._dot,
            decoration: BoxDecoration(
              color: widget.current ? palette.accent : palette.text.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(99),
            ),
            // The app's 2px focus ring, 2px out from the dot, drawn over the pill without moving the other dots.
            foregroundDecoration: _focusShown
                ? BoxDecoration(
                    borderRadius: BorderRadius.circular(99),
                    border: Border.all(color: palette.accent, width: 2, strokeAlign: 3),
                  )
                : null,
          ),
        ),
      ),
    );
  }
}

/// A 36px arrow at the slide's edge, on the translucent dark ground, filled as any button is under the pointer.
class _Arrow extends StatelessWidget {
  const _Arrow({required this.icon, required this.tooltip, required this.onPressed});

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    return Tooltip(
      message: tooltip,
      child: OutlinedButton(
        onPressed: onPressed,
        style: ButtonStyle(
          fixedSize: const WidgetStatePropertyAll(Size(36, 36)),
          padding: const WidgetStatePropertyAll(EdgeInsets.zero),
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.hovered) ? palette.hover : palette.ground.withValues(alpha: 0.75),
          ),
        ),
        child: Icon(icon),
      ),
    );
  }
}
