import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/button_feedback.dart';
import '../../core/palette.dart';
import '../../l10n/app_localizations.dart';
// `AppNotification` and `NotificationKind` come through here: the queue re-exports its own model.
import '../../utils/notifications.dart';
import '../../utils/zzz_characters.dart';
import '../shell/keycap.dart';
import '../shell/status_bar.dart';
import 'character_avatar.dart';
import 'character_tile.dart';

/// Where notifications are drawn: a stack of cards in the bottom-right corner, above the status bar, newest at the
/// bottom.
///
/// **Mounted through `MaterialApp.builder`, above the `Navigator`**, so a card shows over a modal dialog, which is
/// where a large share of them are raised. The same placement means there is no `Overlay` above this layer, so
/// nothing in it may use a `Tooltip`.
class NotificationHost extends StatelessWidget {
  const NotificationHost({super.key, required this.child});

  final Widget child;

  /// From the window's right edge and from the top of the status bar.
  static const double margin = 14;

  /// From the window's bottom edge. The first-run screen has no status bar, and its stack sits this high too.
  static const double bottom = AppStatusBar.height + margin;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => Stack(
        children: [
          child,
          // Anchored to the corner and sized by its content, so it intercepts pointers only over the cards.
          Positioned(
            right: margin,
            bottom: bottom,
            child: NotificationOverlay(
              maxWidth: math.max(0, constraints.maxWidth - 2 * margin),
              maxHeight: math.max(0, constraints.maxHeight - bottom - margin),
            ),
          ),
        ],
      ),
    );
  }
}

/// The stack itself, apart from [NotificationHost] so a test can mount it alone.
///
/// Stateful for two facts it owns: whether the pointer is anywhere on the stack, which holds every clock on it,
/// folded cards included; and whether the user unfolded "+N more".
///
/// The stack is a column of slots, and a slot is one card or one deck: the cards that share a [NotificationDeck],
/// drawn as one. Three slots show, so downloads running at once never take every visible place.
class NotificationOverlay extends ConsumerStatefulWidget {
  const NotificationOverlay({super.key, this.maxWidth = double.infinity, this.maxHeight = double.infinity});

  static const double width = 380;

  final double maxWidth;
  final double maxHeight;

  @override
  ConsumerState<NotificationOverlay> createState() => _NotificationOverlayState();
}

class _NotificationOverlayState extends ConsumerState<NotificationOverlay> {
  bool _hovered = false;
  bool _unfolded = false;

  /// One key per card, so a card keeps its clock and its place in an animation as it moves between a slot of its
  /// own and a deck's.
  final Map<int, GlobalKey> _keys = {};

  @override
  Widget build(BuildContext context) {
    final notifications = ref.watch(notificationsProvider);
    if (notifications.isEmpty) {
      // The region goes with the last card, and a region taken out of the tree never hears its `onExit`. A card
      // raised under a pointer that is still there enters the new region and holds again.
      _hovered = false;
      _keys.clear();
      return const SizedBox.shrink();
    }

    final loc = context.loc;
    final width = math.min(NotificationOverlay.width, widget.maxWidth);
    final slots = _slotsOf(notifications);
    final overflow = slots.length - kVisibleNotifications;
    // It folds by itself once nothing is left to fold.
    if (overflow <= 0) _unfolded = false;
    final folded = _unfolded ? 0 : math.max(0, overflow);
    final center = ref.read(notificationsProvider.notifier);
    _keys.removeWhere((id, _) => !notifications.any((n) => n.id == id));

    Widget cardOf(
      AppNotification n, {
      required bool folded,
      bool behind = false,
      bool dealt = false,
      int ghosts = 0,
      String? line,
      bool closesDeck = false,
    }) =>
        KeyedSubtree(
          key: _keys.putIfAbsent(n.id, GlobalKey.new),
          child: _NotificationCard(
            notification: n,
            width: width,
            paused: _hovered,
            folded: folded,
            behind: behind,
            dealt: dealt,
            ghosts: ghosts,
            line: line,
            onClosed: closesDeck
                ? (seen) => _leave(seen, (_) => _hideDeck(center, seen.deck!.key))
                : (seen) => _leave(seen, center.close),
            onExpired: (seen) => _leave(seen, center.dismiss),
          ),
        );

    return Semantics(
      container: true,
      label: loc.t('notifications.region'),
      child: MouseRegion(
        // One region around the pill and every card, so the gaps between cards are inside it: moving from one card
        // to the next never leaves, and nothing restarts halfway through being read.
        onEnter: (_) => _setHovered(true),
        onExit: (_) => _setHovered(false),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: width, maxHeight: widget.maxHeight),
          child: SingleChildScrollView(
            // Reversed, so the newest stays in view when the column is taller than the window.
            reverse: true,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (overflow > 0)
                  _MorePill(
                    label: _unfolded
                        ? loc.t('notifications.fewer')
                        : loc.plural('notifications.more', folded, params: {'count': '$folded'}),
                    onPressed: () => setState(() => _unfolded = !_unfolded),
                  ),
                for (var i = 0; i < slots.length; i++)
                  // A folded card is still built, offstage, so it keeps owning its clock: a Done runs out unseen and
                  // the count drops, while an Error waits.
                  KeyedSubtree(
                    key: ValueKey(slots[i].key),
                    child: Offstage(
                      offstage: i < folded,
                      child: TickerMode(
                        enabled: i >= folded,
                        child: slots[i].deck == null
                            ? cardOf(slots[i].cards.single, folded: i < folded)
                            : _Deck(
                                cards: slots[i].cards,
                                stackHovered: _hovered,
                                folded: i < folded,
                                card: cardOf,
                              ),
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

  void _setHovered(bool hovered) {
    if (_hovered == hovered) return;
    setState(() => _hovered = hovered);
  }

  /// Takes a card off once its exit ends, unless news reached it in the same frame, before the card could see it.
  bool _leave(AppNotification seen, void Function(int id) go) {
    final now = ref.read(notificationsProvider).where((n) => n.id == seen.id).firstOrNull;
    if (now != null && _isNews(seen, now)) return false;
    go(seen.id);
    return true;
  }

  /// Hide on a deck's front card at rest: every Working card in the deck, each kept aside for its result.
  void _hideDeck(NotificationCenter center, String deck) {
    for (final n in ref.read(notificationsProvider)) {
      if (n.deck?.key == deck && n.kind == NotificationKind.working) center.close(n.id);
    }
  }
}

/// One place in the stack: a card of its own, or every card of one deck, front first.
typedef _Slot = ({String key, NotificationDeck? deck, List<AppNotification> cards});

/// The stack's slots, oldest first. A deck sits where its newest card is, so a download starting or one finishing
/// brings it down to the newest place as a card of its own would come.
///
/// A deck is dealt with its results in front, the newest first, since a result is the news; then its Working cards,
/// the oldest first.
List<_Slot> _slotsOf(List<AppNotification> all) {
  final newest = <String, int>{};
  for (var i = 0; i < all.length; i++) {
    final deck = all[i].deck;
    if (deck != null) newest[deck.key] = i;
  }
  final slots = <_Slot>[];
  for (var i = 0; i < all.length; i++) {
    final deck = all[i].deck;
    if (deck == null) {
      slots.add((key: 'card:${all[i].id}', deck: null, cards: [all[i]]));
    } else if (newest[deck.key] == i) {
      final dealt = all.where((n) => n.deck == deck);
      slots.add((
        key: 'deck:${deck.key}',
        deck: deck,
        cards: [
          ...dealt.where((n) => n.kind != NotificationKind.working).toList().reversed,
          ...dealt.where((n) => n.kind == NotificationKind.working),
        ],
      ));
    }
  }
  return slots;
}

/// Builds one card of the stack, keyed so it keeps its state wherever it is drawn.
typedef _CardBuilder = Widget Function(
  AppNotification n, {
  required bool folded,
  bool behind,
  bool dealt,
  int ghosts,
  String? line,
  bool closesDeck,
});

/// The cards of one deck in one slot: the front card in full, "2 more downloading" under its body, and up to two
/// edges of the cards behind it peeking above it.
///
/// Hovering it spreads it into its full cards, the stack growing upwards from the front card, and it stays spread
/// until the pointer leaves the stack: folding back as soon as the pointer left the deck would slide the cards above
/// it out from under the pointer. Spread, each card's close button is its own; at rest, Hide on a Working front
/// hides the deck.
class _Deck extends StatefulWidget {
  const _Deck({required this.cards, required this.stackHovered, required this.folded, required this.card});

  /// Front first.
  final List<AppNotification> cards;

  /// Whether the pointer is anywhere on the stack.
  final bool stackHovered;

  /// The slot is folded under "+N more".
  final bool folded;

  final _CardBuilder card;

  @override
  State<_Deck> createState() => _DeckState();
}

class _DeckState extends State<_Deck> with SingleTickerProviderStateMixin {
  late final AnimationController _spread = AnimationController(vsync: this, duration: const Duration(milliseconds: 200));
  late final CurvedAnimation _curve = CurvedAnimation(parent: _spread, curve: Curves.easeOutCubic);

  /// The pointer came onto the deck and has not left the stack since.
  bool _entered = false;

  @override
  void didUpdateWidget(_Deck oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_entered && !widget.stackHovered) {
      _entered = false;
      _spreadOut(false);
    }
  }

  @override
  void dispose() {
    _curve.dispose();
    _spread.dispose();
    super.dispose();
  }

  void _spreadOut(bool out) {
    if (MediaQuery.disableAnimationsOf(context)) {
      _spread.value = out ? 1 : 0;
    } else if (out) {
      _spread.forward();
    } else {
      // Not `animateTo(0)`, which ends as completed rather than dismissed and would leave the cards onstage.
      _spread.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    final front = widget.cards.first;
    final behind = widget.cards.skip(1).toList();
    final working = widget.cards.where((n) => n.kind == NotificationKind.working).length;
    final more = front.kind == NotificationKind.working ? working - 1 : working;
    return MouseRegion(
      onEnter: (_) {
        if (_entered) return;
        setState(() => _entered = true);
        _spreadOut(true);
      },
      child: AnimatedBuilder(
        animation: _spread,
        builder: (context, _) {
          final open = !_spread.isDismissed;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              // The farthest from the front at the top.
              for (final n in behind.reversed)
                Offstage(
                  key: ValueKey('behind:${n.id}'),
                  offstage: !open,
                  child: TickerMode(
                    enabled: open,
                    child: SizeTransition(
                      sizeFactor: _curve,
                      // Out from behind the front card: its bottom edge shows first.
                      alignment: Alignment.bottomCenter,
                      child: FadeTransition(
                        opacity: _curve,
                        child: widget.card(n, folded: widget.folded || !open, behind: true, dealt: true),
                      ),
                    ),
                  ),
                ),
              widget.card(
                front,
                folded: widget.folded,
                dealt: behind.isNotEmpty,
                ghosts: _entered ? 0 : math.min(2, behind.length),
                line: more > 0 ? front.deck!.more(more) : null,
                closesDeck: !open && behind.isNotEmpty && front.kind == NotificationKind.working,
              ),
            ],
          );
        },
      ),
    );
  }
}

/// The edge of a card behind a deck's front card: 20px tall with no bottom border, the rest hidden under the front.
class _Ghost extends StatelessWidget {
  const _Ghost({required this.color});

  final Color color;

  /// How far each edge peeks out above the one in front of it.
  static const double step = 7;

  /// How much narrower each edge is than the one in front of it.
  static const double narrower = 20;

  static const double height = 20;

  @override
  Widget build(BuildContext context) {
    final side = BorderSide(color: ZenithPalette.of(context).line);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
        border: Border(top: side, left: side, right: side),
      ),
    );
  }
}

/// Whether [now] says something [before] did not, which keeps a card that was on its way out. A Working card's own
/// progress is not news.
bool _isNews(AppNotification before, AppNotification now) {
  final progressOnly = before.kind == NotificationKind.working && now.kind == NotificationKind.working;
  return before.kind != now.kind ||
      before.count != now.count ||
      (!progressOnly && (before.title != now.title || before.body != now.body));
}

/// Takes a card off the stack once its exit ends, returning false when news arrived and it stays.
typedef _Leave = bool Function(AppNotification seen);

/// How one kind looks: its icon tile, the badge it puts on a portrait, and their glyphs.
typedef NotificationLook = ({TonePair tile, TonePair? badge, IconData icon, IconData? badgeIcon, bool spins});

/// The look of each [NotificationKind], in one place so the tile, the badge and anything added later cannot drift.
NotificationLook notificationLook(ZenithPalette p, NotificationKind kind) => switch (kind) {
      NotificationKind.working => (
          tile: TonePair(p.hover, p.textProse),
          badge: TonePair(p.line, p.text),
          icon: Icons.sync_rounded,
          badgeIcon: null,
          spins: true,
        ),
      NotificationKind.done => (
          tile: p.notificationDoneTile,
          badge: TonePair(p.accent, p.onAccent),
          icon: Icons.check_rounded,
          badgeIcon: Icons.check_rounded,
          spins: false,
        ),
      NotificationKind.note => (
          tile: TonePair(p.hover, p.textProse),
          badge: null,
          icon: Icons.info_outline_rounded,
          badgeIcon: null,
          spins: false,
        ),
      NotificationKind.update => (
          tile: p.badgeUpdate,
          badge: TonePair(p.amber, p.onAccent),
          icon: Icons.arrow_circle_up_outlined,
          badgeIcon: Icons.arrow_upward_rounded,
          spins: false,
        ),
      NotificationKind.needsYou => (
          tile: p.badgeInfo,
          badge: TonePair(p.blue, p.onAccent),
          icon: Icons.download_rounded,
          badgeIcon: Icons.arrow_downward_rounded,
          spins: false,
        ),
      NotificationKind.warning => (
          tile: p.badgeUpdate,
          badge: TonePair(p.amber, p.onAccent),
          icon: Icons.warning_amber_rounded,
          badgeIcon: Icons.priority_high_rounded,
          spins: false,
        ),
      NotificationKind.error => (
          tile: p.badgeMissing,
          badge: TonePair(p.red, p.onRed),
          icon: Icons.highlight_off_rounded,
          badgeIcon: Icons.close_rounded,
          spins: false,
        ),
    };

/// The card's ground: [ZenithPalette.notificationError] for an error, [ZenithPalette.notification] otherwise.
TonePair notificationGround(ZenithPalette p, NotificationKind kind) =>
    kind == NotificationKind.error ? p.notificationError : p.notification;

/// "+N more" above the stack, or "Show fewer" while it is unfolded.
class _MorePill extends StatelessWidget {
  const _MorePill({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    final ground = palette.notification;
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 26),
        fixedSize: const Size.fromHeight(26),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        backgroundColor: ground.background,
        foregroundColor: palette.text2,
        overlayColor: Colors.transparent,
        textStyle: Theme.of(context).textTheme.bodySmall,
      ).copyWith(
        side: focusRingOr(palette, null),
        shape: pressShape(StadiumBorder(side: BorderSide(color: ground.border!))),
      ),
      clipBehavior: Clip.none,
      child: Text(label),
    );
  }
}

/// One card, and the only thing in this subsystem that owns a clock.
///
/// The clock is here rather than in `NotificationCenter` because it stops while the stack is being read, and only
/// the widget knows that.
class _NotificationCard extends StatefulWidget {
  const _NotificationCard({
    required this.notification,
    required this.width,
    required this.paused,
    required this.folded,
    required this.onClosed,
    required this.onExpired,
    this.behind = false,
    this.dealt = false,
    this.ghosts = 0,
    this.line,
  });

  final AppNotification notification;
  final double width;

  /// True while the pointer is anywhere on the stack. Leaving restarts the full duration rather than resuming: who
  /// just moved the pointer away has not necessarily finished reading.
  final bool paused;

  /// Offstage under "+N more", or behind a deck's front card at rest. Its tickers are stopped, so it leaves without
  /// its exit animation.
  final bool folded;

  /// In a deck, behind its front card.
  final bool behind;

  /// In a deck of more than one card.
  final bool dealt;

  /// How many edges of the cards behind it peek above it, at most two: it is a deck's front card at rest.
  final int ghosts;

  /// A deck's front card's last line, "2 more downloading".
  final String? line;

  /// The user closed it.
  final _Leave onClosed;

  /// Its clock ran out.
  final _Leave onExpired;

  @override
  State<_NotificationCard> createState() => _NotificationCardState();
}

class _NotificationCardState extends State<_NotificationCard> with SingleTickerProviderStateMixin {
  /// The exit is quicker than the entrance: an arrival wants to be noticed, a departure to be out of the way.
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    reverseDuration: const Duration(milliseconds: 140),
  );

  late final CurvedAnimation _curve = CurvedAnimation(parent: _anim, curve: Curves.easeOutCubic);

  Timer? _timer;

  /// What runs once the exit ends, while one is under way. Set when the exit starts, so a second press or a clock
  /// that already fired cannot start it twice.
  _Leave? _leaving;

  @override
  void initState() {
    super.initState();
    // Dealt in behind a deck's front card, it has no entrance to show.
    if (widget.folded) {
      _anim.value = 1;
    } else {
      _anim.forward();
    }
    _restartTimer();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) _anim.value = 1;
  }

  @override
  void didUpdateWidget(_NotificationCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final before = oldWidget.notification;
    final now = widget.notification;
    final leaving = _leaving;
    if (leaving != null) {
      // News arriving during the exit keeps the card, since it is meant to be read: a merge, or the result of a
      // Working card being hidden.
      if (_isNews(before, now)) {
        _leaving = null;
        _anim.forward();
      } else if (widget.folded && !oldWidget.folded) {
        // Folded mid-exit, its tickers stop and the exit would never finish. After the frame, since the stack
        // can't change while it is being built.
        _leaving = null;
        WidgetsBinding.instance.addPostFrameCallback((_) => leaving(now));
        return;
      }
    }
    // Up from under a deck as its new front card, or out of one as a card of its own: it enters as a new card would.
    final cameUp = oldWidget.behind && oldWidget.folded && !widget.behind && !widget.folded;
    final leftDeck = oldWidget.dealt && now.deck == null;
    if ((cameUp || leftDeck) && _leaving == null && !MediaQuery.disableAnimationsOf(context)) {
      _anim.forward(from: 0);
    }
    if (oldWidget.paused != widget.paused ||
        before.duration != now.duration ||
        before.title != now.title ||
        before.body != now.body ||
        before.kind != now.kind ||
        before.count != now.count) {
      _restartTimer();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _curve.dispose();
    _anim.dispose();
    super.dispose();
  }

  void _restartTimer() {
    _timer?.cancel();
    final duration = widget.notification.duration;
    // A card raised while the pointer is already on the stack arrives held.
    if (duration == null || _leaving != null || widget.paused) return;
    _timer = Timer(duration, () => _leave(widget.onExpired));
  }

  Future<void> _leave(_Leave then) async {
    if (_leaving != null) return;
    _leaving = then;
    _timer?.cancel();
    final seen = widget.notification;
    // A folded card's tickers are stopped, so its exit would never finish. An exit called off by news never
    // finishes either, and leaves the callback to a later exit.
    if (!widget.folded && !MediaQuery.disableAnimationsOf(context)) await _anim.reverse();
    if (!mounted || !identical(_leaving, then)) return;
    _leaving = null;
    if (!then(seen)) {
      _anim.forward();
      _restartTimer();
    }
  }

  void _press(NotificationAction action) {
    action.onPressed();
    if (action.closes) _leave(widget.onClosed);
  }

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.disableAnimationsOf(context);
    // Each edge a shade further back than the one in front of it.
    final ghostColors = [ZenithPalette.of(context).raised, ZenithPalette.of(context).rowHover];
    final card = TweenAnimationBuilder<double>(
      // Eased rather than jumped, so a card dealt in behind slides its edge out and a spread deck tucks them away.
      tween: Tween(end: widget.ghosts.toDouble()),
      duration: still ? Duration.zero : const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      child: KeyedSubtree(key: const ValueKey('notification-face'), child: _card(context)),
      builder: (context, peek, face) => Padding(
        // The gap belongs to the card below it, so the stack's one `MouseRegion` covers the gaps too. A deck's edges
        // peek out into room of their own above it.
        padding: EdgeInsets.only(top: 8 + _Ghost.step * peek),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // The farthest first, so each edge is drawn under the one in front of it.
            for (var i = 2; i >= 1; i--)
              if (peek > i - 1)
                Positioned(
                  key: ValueKey('notification-ghost-$i'),
                  top: -_Ghost.step * math.min(peek, i.toDouble()),
                  left: _Ghost.narrower * i / 2,
                  right: _Ghost.narrower * i / 2,
                  height: _Ghost.height,
                  child: _Ghost(color: ghostColors[i - 1]),
                ),
            face!,
          ],
        ),
      ),
    );
    return SizeTransition(
      // Collapsing rather than vanishing makes the cards above slide down into the gap.
      sizeFactor: _curve,
      child: FadeTransition(
        opacity: _curve,
        child: still
            ? card
            : SlideTransition(
                position: Tween<Offset>(begin: const Offset(0.12, 0), end: Offset.zero).animate(_curve),
                child: card,
              ),
      ),
    );
  }

  Widget _card(BuildContext context) {
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final loc = context.loc;
    final n = widget.notification;
    final ground = notificationGround(palette, n.kind);
    final working = n.kind == NotificationKind.working;

    final bodyStyle = text.bodySmall?.copyWith(color: palette.text2);
    final Widget body;
    if (n.count > 1 && n.subjects.length > 1) {
      final subjects = Text(subjectList(loc, n.subjects), style: bodyStyle, maxLines: 3, overflow: TextOverflow.ellipsis);
      // A body that says more than its subject keeps saying it, with the subjects under it.
      body = n.repeat?.body == null
          ? subjects
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(n.body, style: bodyStyle, maxLines: 8, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                subjects,
              ],
            );
    } else if (n.keycap != null) {
      body = Text.rich(TextSpan(children: keycapSentence(context, n.body, n.keycap!)), style: bodyStyle);
    } else {
      // Long enough for the few bodies that carry a reason as well as a subject; past that it belongs in a dialog.
      body = Text(n.body, style: bodyStyle, maxLines: 8, overflow: TextOverflow.ellipsis);
    }

    return Semantics(
      container: true,
      liveRegion: true,
      child: Material(
        type: MaterialType.transparency,
        child: Container(
          key: const ValueKey('notification-card'),
          width: widget.width,
          decoration: BoxDecoration(
            color: ground.background,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: ground.border!),
            boxShadow: [BoxShadow(color: palette.notificationShadow, blurRadius: 40, offset: const Offset(0, 14))],
          ),
          // Clipped so the bar along the bottom follows the rounded corners.
          clipBehavior: Clip.antiAlias,
          child: Stack(
            children: [
              Padding(
                // An action's hit area reaches 8px left of its label and 6px into the bottom padding, and a hit
                // outside a parent's bounds never lands, so the column and the padding give that room up instead.
                padding: EdgeInsets.fromLTRB(12, 12, 10, n.actions.isEmpty ? 12 : 12 - _ActionButton.overhang),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _NotificationLeading(notification: n, ground: ground.background),
                    const SizedBox(width: 12 - _ActionButton.inset),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(left: _ActionButton.inset),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(n.title,
                                      style:
                                          text.bodyMedium?.copyWith(fontWeight: FontWeight.w600, color: palette.text)),
                                  const SizedBox(height: 2),
                                  body,
                                  if (widget.line case final line?) ...[
                                    const SizedBox(height: 2),
                                    Text(line,
                                        key: const ValueKey('notification-deck-line'),
                                        style: text.bodySmall?.copyWith(color: palette.text3)),
                                  ],
                                ],
                              ),
                            ),
                            if (n.actions.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: Wrap(
                                  spacing: 2,
                                  children: [
                                    for (var i = 0; i < n.actions.length; i++)
                                      _ActionButton(
                                        action: n.actions[i],
                                        color: i == 0 && n.kind != NotificationKind.note ? palette.link : palette.text,
                                        hover: n.kind == NotificationKind.error
                                            ? palette.notificationErrorHover
                                            : palette.line,
                                        onPressed: () => _press(n.actions[i]),
                                      ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    _CloseButton(
                      label: loc.t(working ? 'notifications.hide' : 'notifications.close'),
                      onPressed: () => _leave(widget.onClosed),
                    ),
                  ],
                ),
              ),
              if (working)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  height: 3,
                  child: _ProgressBar(progress: n.progress),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The card's leading slot: the portrait with the kind as a badge on its corner when the card is about one
/// character's mod, else the kind's icon on its tile.
///
/// A mod filed under a category, Unknown or Unassigned has no portrait and gets the plain icon, as does a card that
/// counts several mods.
class _NotificationLeading extends StatelessWidget {
  const _NotificationLeading({required this.notification, required this.ground});

  final AppNotification notification;

  /// The card's ground, for the ring that cuts the badge out of the portrait.
  final Color ground;

  static const double _portrait = 32;
  static const double _tile = 28;
  static const double _badge = 18;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    final n = notification;
    final look = notificationLook(palette, n.kind);
    final characterId = n.characterId;
    final hasPortrait =
        n.icon == null && n.count == 1 && characterId != null && CharacterAvatar.assetPathFor(characterId) != null;

    if (hasPortrait) {
      final badge = look.badge;
      return Semantics(
        image: true,
        label: context.loc.t(
          'notifications.character_portrait',
          params: {'name': getCharacterDisplayName(characterId)},
        ),
        child: SizedBox(
          width: _portrait,
          height: _portrait + 1,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                top: 1,
                left: 0,
                child: CharacterTile(groupId: characterId, size: _portrait, radius: 9),
              ),
              if (badge != null)
                Positioned(
                  right: -5,
                  bottom: -5,
                  // 18px across with its 2px ring in the card's ground, so a 14px fill.
                  child: Container(
                    width: _badge,
                    height: _badge,
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(color: ground, shape: BoxShape.circle),
                    child: Container(
                      key: const ValueKey('notification-badge'),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(color: badge.background, shape: BoxShape.circle),
                      child: look.spins
                          ? _Spinner(size: 10, color: badge.foreground)
                          : Icon(look.badgeIcon, size: 10, color: badge.foreground),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    }

    // As wide as a portrait, so the text starts at the same edge on every card in a mixed stack.
    return SizedBox(
      width: _portrait,
      child: Align(
        alignment: Alignment.topCenter,
        child: Container(
          key: const ValueKey('notification-tile'),
          width: _tile,
          height: _tile,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: look.tile.background, borderRadius: BorderRadius.circular(8)),
          child: look.spins && n.icon == null
              ? _Spinner(size: 16, color: look.tile.foreground)
              : Icon(n.icon ?? look.icon, size: 16, color: look.tile.foreground),
        ),
      ),
    );
  }
}

/// A 270° arc turning once every 0.9s, standing still under reduced motion.
class _Spinner extends StatefulWidget {
  const _Spinner({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  State<_Spinner> createState() => _SpinnerState();
}

class _SpinnerState extends State<_Spinner> with SingleTickerProviderStateMixin {
  late final AnimationController _turn =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 900));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _turn.stop();
    } else if (!_turn.isAnimating) {
      _turn.repeat();
    }
  }

  @override
  void dispose() {
    _turn.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RotationTransition(
      key: const ValueKey('notification-spinner'),
      turns: _turn,
      child: CustomPaint(size: Size.square(widget.size), painter: _ArcPainter(widget.color)),
    );
  }
}

class _ArcPainter extends CustomPainter {
  const _ArcPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // The canvas draws it in a 24-unit box: radius 8.5, from the top clockwise to the left.
    final unit = size.width / 24;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 2.6 * unit;
    final rect = Rect.fromCircle(center: size.center(Offset.zero), radius: 8.5 * unit);
    canvas.drawArc(rect, -math.pi / 2, 1.5 * math.pi, false, paint);
  }

  @override
  bool shouldRepaint(_ArcPainter oldDelegate) => oldDelegate.color != color;
}

/// A Working card's bar along its bottom edge: the share done, or a sweep for work of unknown size.
class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.progress});

  final double? progress;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    final still = MediaQuery.disableAnimationsOf(context);
    final progress = this.progress;
    return ColoredBox(
      color: palette.line,
      child: progress == null
          ? _Sweep(color: palette.accent)
          : AnimatedFractionallySizedBox(
              key: const ValueKey('notification-progress'),
              duration: still ? Duration.zero : const Duration(milliseconds: 200),
              alignment: Alignment.centerLeft,
              widthFactor: progress,
              child: ColoredBox(color: palette.accent),
            ),
    );
  }
}

/// A segment 35% of the bar's width crossing it every 1.4s, standing still under reduced motion.
class _Sweep extends StatefulWidget {
  const _Sweep({required this.color});

  final Color color;

  @override
  State<_Sweep> createState() => _SweepState();
}

class _SweepState extends State<_Sweep> with SingleTickerProviderStateMixin {
  late final AnimationController _run =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _run.stop();
    } else if (!_run.isAnimating) {
      _run.repeat();
    }
  }

  @override
  void dispose() {
    _run.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.disableAnimationsOf(context);
    return LayoutBuilder(
      builder: (context, constraints) => AnimatedBuilder(
        animation: _run,
        builder: (context, _) {
          final width = constraints.maxWidth;
          final left = still ? 0.30 : -0.35 + 1.35 * _run.value;
          return Stack(
            key: const ValueKey('notification-sweep'),
            clipBehavior: Clip.hardEdge,
            children: [
              Positioned(
                left: left * width,
                top: 0,
                bottom: 0,
                width: 0.35 * width,
                child: ColoredBox(color: widget.color.withValues(alpha: 0.7)),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// A flat text button, 30px tall with its label 8px in from either side, filled under the pointer.
class _ActionButton extends StatelessWidget {
  const _ActionButton({required this.action, required this.color, required this.hover, required this.onPressed});

  final NotificationAction action;
  final Color color;
  final Color hover;
  final VoidCallback onPressed;

  /// From the button's edge to its label.
  static const double inset = 8;

  /// How far the button reaches below the column of text it sits in, into the card's bottom padding.
  static const double overhang = 6;

  static const double height = 30;

  @override
  Widget build(BuildContext context) {
    final label = Theme.of(context).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600);
    return TextButton(
      onPressed: onPressed,
      style: ButtonStyle(
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: inset)),
        minimumSize: const WidgetStatePropertyAll(Size(0, height)),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.standard,
        shape: pressShape(RoundedRectangleBorder(borderRadius: BorderRadius.circular(7))),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.hovered) ? hover : Colors.transparent,
        ),
        foregroundColor: WidgetStatePropertyAll(color),
        textStyle: WidgetStatePropertyAll(label),
        // The press; the hover is the fill above. The keyboard focus ring is the border, since this layer has no
        // Overlay for the theme's ring to be drawn in, and the button must not clip it.
        backgroundBuilder: buttonFeedback(hover: false),
        side: focusRingOr(ZenithPalette.of(context), null),
      ),
      clipBehavior: Clip.none,
      child: Text(action.label),
    );
  }
}

/// The close button, on every card. "Hide" on a Working card, whose result still arrives.
///
/// **A semantic label rather than a `Tooltip`**, which is forced: a tooltip needs an `Overlay` ancestor, and this
/// layer is a sibling of the `Navigator`.
class _CloseButton extends StatelessWidget {
  const _CloseButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    return SizedBox.square(
      dimension: 26,
      child: IconButton(
        onPressed: onPressed,
        padding: EdgeInsets.zero,
        iconSize: 14,
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size.square(26)),
          shape: pressShape(RoundedRectangleBorder(borderRadius: BorderRadius.circular(7))),
          overlayColor: const WidgetStatePropertyAll(Colors.transparent),
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.hovered) ? palette.line : Colors.transparent,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.hovered) ? palette.text : palette.text3,
          ),
          backgroundBuilder: buttonFeedback(hover: false),
          side: focusRingOr(palette, null),
        ),
        icon: Icon(Icons.close_rounded, semanticLabel: label),
      ),
    );
  }
}
