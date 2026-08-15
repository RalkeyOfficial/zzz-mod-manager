import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
// `AppNotification` and `NotificationSeverity` come through here — the queue
// re-exports its own model, so nothing has to import both.
import '../../utils/notifications.dart';
import 'mod_status_slot.dart';

/// Where notifications are drawn: a stack of small cards in the bottom-right
/// corner, newest at the bottom, older ones pushed up.
///
/// **Mounted through `MaterialApp.builder`, above the `Navigator`.** That is the
/// one placement that works, and the reason is the thing the old snackbars got
/// wrong: a `ScaffoldMessenger` bar lives *inside* the `Scaffold`, so a modal
/// dialog's barrier covers it — and a large share of this app's messages are
/// raised from dialogs (rename, delete, keybinds, the update flow). Sitting
/// above the navigator, a notification is visible whatever is open.
///
/// It also fixes the shape of the thing. Material shows one snackbar at a time
/// and *queues* the rest, so an install that had three things to say said them
/// one after another across the bottom of the window, each covering the content
/// underneath for its turn. Here everything is on screen at once, in a corner,
/// and each can be closed.
class NotificationHost extends StatelessWidget {
  const NotificationHost({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        child,
        // Anchored to the corner and sized by its content, so it covers — and
        // intercepts pointers over — only the cards themselves. There is no
        // full-screen layer here to swallow clicks.
        const Positioned(
          right: 16,
          bottom: 16,
          child: NotificationOverlay(),
        ),
      ],
    );
  }
}

/// The stack itself. Separated from [NotificationHost] so it can be mounted
/// alone in a test, or dropped into another layout later.
///
/// Stateful for one reason: **the pointer being anywhere on the stack pauses
/// every countdown on it**, not just the one it is over. Reading is reading —
/// someone working through four messages is still reading the fourth while the
/// pointer rests on the first, and per-card pausing would let the others expire
/// underneath them, reflowing the stack out from under the pointer. So "is the
/// pointer here" is one fact, owned here, and handed down.
class NotificationOverlay extends ConsumerStatefulWidget {
  const NotificationOverlay({super.key});

  /// Wide enough for a sentence and a half at 13px, narrow enough that four of
  /// them stacked don't read as a second panel.
  static const double width = 360;

  @override
  ConsumerState<NotificationOverlay> createState() =>
      _NotificationOverlayState();
}

class _NotificationOverlayState extends ConsumerState<NotificationOverlay> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final notifications = ref.watch(notificationsProvider);
    if (notifications.isEmpty) return const SizedBox.shrink();

    // Bounded and scrollable rather than trusting the cap: the cap limits the
    // *count*, and one long message is enough to overflow a short window on its
    // own. Reversed, so the newest is the one that stays in view.
    final maxHeight = MediaQuery.sizeOf(context).height * 0.6;

    return MouseRegion(
      // One region around the whole column rather than one per card, which also
      // makes the 8px gaps between cards part of it: moving the pointer from
      // one notification to the next never crosses "outside", so nothing
      // restarts halfway through being read.
      onEnter: (_) => _setHovered(true),
      onExit: (_) => _setHovered(false),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: NotificationOverlay.width,
            maxHeight: maxHeight),
        child: SingleChildScrollView(
          reverse: true,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final notification in notifications)
                _NotificationCard(
                  // Keyed by id, which is what makes an in-place update keep the
                  // same card — same entrance animation, same place in the
                  // stack, same clock — instead of sliding a new one in.
                  key: ValueKey(notification.id),
                  notification: notification,
                  paused: _hovered,
                  onDismiss: () => ref
                      .read(notificationsProvider.notifier)
                      .dismiss(notification.id),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _setHovered(bool hovered) {
    if (_hovered == hovered) return;
    setState(() => _hovered = hovered);
  }
}

/// The colour that carries a notification's meaning.
///
/// One function, so the palette cannot drift between the icon, the accent bar
/// and anything added later. Two of the four are literals rather than scheme
/// slots because Material has no "success" or "warning" role — and the two
/// chosen are already this app's: the amber it marks "needs attention" with
/// everywhere else, and the green its active-mod count uses.
Color notificationColor(ColorScheme scheme, NotificationSeverity severity) {
  return switch (severity) {
    NotificationSeverity.success => const Color(0xFF10B981),
    NotificationSeverity.info => scheme.primary,
    NotificationSeverity.warning => ModStatusSlot.amber,
    NotificationSeverity.error => scheme.error,
  };
}

/// The icon a severity gets when the call site doesn't name one.
IconData notificationIcon(NotificationSeverity severity) {
  return switch (severity) {
    NotificationSeverity.success => Icons.check_circle_outline_rounded,
    NotificationSeverity.info => Icons.info_outline_rounded,
    NotificationSeverity.warning => Icons.warning_amber_rounded,
    NotificationSeverity.error => Icons.error_outline_rounded,
  };
}

/// One card, and the only thing in this subsystem that owns a clock.
///
/// The auto-dismiss timer is here rather than in `NotificationCenter` because it
/// has to stop while the notifications are being read — otherwise a long error
/// disappears mid-sentence, which is the complaint this whole rework exists to
/// answer. The centre stays a pure list of state; time is a property of the
/// thing on screen.
///
/// Whether it is being read is **not** this card's own business, though: see
/// [paused].
class _NotificationCard extends StatefulWidget {
  const _NotificationCard({
    super.key,
    required this.notification,
    required this.paused,
    required this.onDismiss,
  });

  final AppNotification notification;

  /// True while the pointer is anywhere on the stack — over *any* card, or in
  /// a gap between two. Held one level up so hovering one notification holds
  /// all of them: the pointer resting on the first while the fourth is being
  /// read must not let the fourth expire.
  ///
  /// Leaving does not resume where it left off, it **restarts** the full
  /// duration. Someone who has just moved the pointer away has not necessarily
  /// finished, and half a second of grace is worse than none.
  final bool paused;

  final VoidCallback onDismiss;

  @override
  State<_NotificationCard> createState() => _NotificationCardState();
}

class _NotificationCardState extends State<_NotificationCard>
    with SingleTickerProviderStateMixin {
  /// In and out. The exit is quicker than the entrance — an arrival wants to be
  /// noticed, a departure wants to be out of the way.
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    reverseDuration: const Duration(milliseconds: 140),
  );

  /// Built once and disposed, not rebuilt in `build`: a `CurvedAnimation`
  /// attaches to its parent, so one per frame is a listener leak that only
  /// shows up as a slow bleed.
  late final CurvedAnimation _curve = CurvedAnimation(
    parent: _anim,
    curve: Curves.easeOutCubic,
  );

  Timer? _timer;

  /// Set the moment the exit starts, so a hover, a second click on the close
  /// button, or a timer that had already fired cannot start it twice.
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _anim.forward();
    _restartTimer();
  }

  @override
  void didUpdateWidget(_NotificationCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Hovering stops the clock; leaving starts a fresh one.
    if (oldWidget.paused != widget.paused) {
      if (widget.paused) {
        _timer?.cancel();
      } else {
        _restartTimer();
      }
      return;
    }
    // An update in place re-clocks the card. This is the whole point of a
    // pinned notification: it sits there with no timer while the work runs, and
    // the update that reports the result is what gives it an ending.
    if (oldWidget.notification.duration != widget.notification.duration ||
        oldWidget.notification.message != widget.notification.message) {
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
    // `paused` is checked here too, not only on the transition: a notification
    // raised *while* the pointer is already on the stack must arrive stopped,
    // or a burst would tick away under a reader who never moved.
    if (duration == null || _closing || widget.paused) return;
    _timer = Timer(duration, _close);
  }

  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    _timer?.cancel();
    await _anim.reverse();
    // The card can be disposed mid-exit — the stack was cleared, or the tab
    // holding the overlay went away — in which case there is nothing left to
    // remove.
    if (mounted) widget.onDismiss();
  }

  @override
  Widget build(BuildContext context) {
    return SizeTransition(
      // Collapsing rather than vanishing is what makes the cards above slide
      // down into the gap instead of jumping.
      sizeFactor: _curve,
      child: FadeTransition(
        opacity: _curve,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0.12, 0),
            end: Offset.zero,
          ).animate(_curve),
          // The gap belongs to the card above it, so the stack's single
          // `MouseRegion` covers the spaces between cards as well as the cards.
          child: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: _card(context),
          ),
        ),
      ),
    );
  }

  Widget _card(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final notification = widget.notification;
    final accent = notificationColor(scheme, notification.severity);
    final title = notification.title;

    return Material(
      color: Colors.transparent,
      child: Container(
        width: NotificationOverlay.width,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: accent.withValues(alpha: 0.35)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.22),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        // Clipped so the accent bar can run the full height of the card and
        // still follow its rounded corners.
        clipBehavior: Clip.antiAlias,
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // The severity, readable before a single word is: a solid stripe
              // is legible at a glance and at any text scale, where a tinted
              // background would have to be so pale it stops being a colour.
              Container(width: 4, color: accent),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        notification.icon ??
                            notificationIcon(notification.severity),
                        size: 18,
                        color: accent,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (title != null)
                              Text(
                                title,
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            if (title != null) const SizedBox(height: 2),
                            Text(
                              notification.message,
                              // Long enough for the install summary, which is
                              // several lines by design; past that the message
                              // belongs in a dialog rather than here.
                              maxLines: 8,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: title == null
                                    ? scheme.onSurface
                                    : scheme.onSurfaceVariant,
                                height: 1.35,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 4),
                      _CloseButton(onPressed: _close),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The close affordance, on every notification including the pinned ones.
///
/// Its own widget only so the hit target can be generous while the glyph stays
/// small enough not to compete with the message.
///
/// **A semantic label rather than a `Tooltip`**, and that is forced rather than
/// chosen: a tooltip needs an `Overlay` ancestor, and this layer is mounted as a
/// *sibling* of the `Navigator` — which is exactly what puts it above dialogs.
/// A tooltip here throws "No Overlay widget found" the first time a notification
/// is drawn. Nothing is lost that a ✕ doesn't already say, and the label keeps
/// the control named for screen readers.
class _CloseButton extends StatelessWidget {
  const _CloseButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 28,
      height: 28,
      child: IconButton(
        onPressed: onPressed,
        padding: EdgeInsets.zero,
        iconSize: 16,
        visualDensity: VisualDensity.compact,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        icon: Icon(
          Icons.close_rounded,
          semanticLabel: context.loc.t('notifications.dismiss'),
        ),
      ),
    );
  }
}
