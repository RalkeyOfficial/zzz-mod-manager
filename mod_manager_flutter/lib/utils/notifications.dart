/// The app's notification queue — what is currently being told to the user.
///
/// Kept out of `state_providers.dart` for the same reason the marketplace's
/// browsing session is: that file is the registry of state the *app* is in
/// (library, theme, locale, tab), while this is one subsystem with its own
/// vocabulary. The pointer over there says where to find it.
///
/// ## Why this exists at all
///
/// `ScaffoldMessenger` shows **one snackbar at a time and queues the rest**, so
/// a burst — an install that reports auto-tags, then missing `.ini` files, then
/// a patch — arrives as three bars in sequence, each covering the bottom of the
/// window for its turn. This is a *stack* instead: everything raised is visible
/// at once, in the corner, and any of it can be dismissed by hand.
///
/// ## Raising one
///
/// Every notification is two levels: **what happened**, and **what it happened
/// to**. Both are required, which is what stops a card being a lone headline
/// over blank space.
///
/// ```dart
/// context.notify.success(
///   loc.t('marketplace.install_success_title_single'),
///   body: mod.name,
///   characterId: mod.characterId,   // leads the card with their portrait
/// );
/// ```
///
/// Where a call site has no subject in hand, the body is the single next step
/// the user can take — never a restatement of the title:
///
/// ```dart
/// context.notify.error(
///   loc.t('marketplace.install_missing_path_title'),
///   body: loc.t('marketplace.install_missing_path_body'),
/// );
/// ```
///
/// Capture it in a local before an `await` and it keeps working afterwards with
/// no `mounted` check — it is a plain object, not a `BuildContext` lookup:
///
/// ```dart
/// final notify = context.notify;
/// await doTheWork();
/// notify.success('…', body: '…');   // no context used after the await
/// ```
///
/// ## Notifications that wait for something rather than for a clock
///
/// Pass `duration: null` (or use [NotificationCenter.pinned]) and the
/// notification stays until something dismisses it. `show` hands back a
/// [NotificationHandle] for exactly that:
///
/// ```dart
/// final saving = context.notify.pinned('Saving tag…', body: mod.name);
/// await save();
/// saving.update(title: 'Tag saved', severity: NotificationSeverity.success);
/// // …or saving.dismiss();
/// ```
///
/// Note what that update does *not* say: the body is the stable subject, so it
/// carries over untouched. Raising builds a whole statement and needs both
/// levels; updating changes one level of a statement that already exists, which
/// is why every parameter of [NotificationHandle.update] is optional.
///
/// The user can still close a pinned notification by hand — nothing this app
/// puts on screen may be un-dismissable.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/app_notification.dart';
import '../services/log/log_level.dart';
import '../services/log/logger.dart';

export '../models/app_notification.dart';

final Logger _log = Logger('ui.notify');

/// A notification's severity as a log level.
///
/// `success` and `info` are both [LogLevel.info]: the distinction between them
/// is about tone on screen — a green tick versus a blue dot — and means nothing
/// to somebody reading a file afterwards. `warning` and `error` map straight
/// across, which is why the two vocabularies were kept spelled the same.
LogLevel _levelFor(NotificationSeverity severity) => switch (severity) {
      NotificationSeverity.error => LogLevel.error,
      NotificationSeverity.warning => LogLevel.warning,
      NotificationSeverity.success => LogLevel.info,
      NotificationSeverity.info => LogLevel.info,
    };

/// How long each severity stays when the caller doesn't say.
///
/// They differ because reading time differs: "Activated" is confirmation of
/// something the user just did and is already looking at, while an error is
/// text they have to read and possibly act on. Hovering a notification pauses
/// its timer, so these are floors on the *unattended* case rather than a race.
const Map<NotificationSeverity, Duration> kNotificationDurations = {
  NotificationSeverity.success: Duration(seconds: 4),
  NotificationSeverity.info: Duration(seconds: 5),
  NotificationSeverity.warning: Duration(seconds: 8),
  NotificationSeverity.error: Duration(seconds: 10),
};

/// How many are shown at once before the oldest is pushed off.
///
/// A cap rather than a scroll region: past four the stack stops being a corner
/// of the window and becomes a wall, which is the failure the old single bar had
/// in its own way. The oldest goes first — a burst is nearly always one action
/// reporting several things, and the last line is the one that concludes it.
const int kMaxVisibleNotifications = 4;

/// The notification stack, oldest first.
///
/// List order **is** stack order: the overlay renders it top to bottom against
/// the bottom-right corner, so a new notification appears at the bottom and
/// pushes the others up.
final notificationsProvider =
    NotifierProvider<NotificationCenter, List<AppNotification>>(
  NotificationCenter.new,
);

/// A raised notification, for as long as the caller wants to keep talking about
/// it.
///
/// Returned by every `show`/`success`/`error`/… call. Holding one is optional —
/// most call sites raise a message and forget it — but it is the whole mechanism
/// behind a notification that ends on a *condition* instead of a timer.
///
/// Safe to keep and to call after the notification is gone: [update] and
/// [dismiss] on something no longer in the stack do nothing rather than throw,
/// because the user may have closed it by hand at any moment.
class NotificationHandle {
  const NotificationHandle(this._center, this.id);

  final NotificationCenter _center;

  /// Identifies this notification for as long as it is on screen.
  final int id;

  /// Whether it is still showing.
  bool get isVisible => _center.visible.any((n) => n.id == id);

  /// Rewrites it in place, keeping its position in the stack and its card.
  ///
  /// Every parameter is optional and unspecified means unchanged — unlike
  /// raising one, which requires both levels. The two are different operations:
  /// raising builds a whole statement, updating changes one level of a
  /// statement that already exists. Pass `duration` to give a pinned
  /// notification an ending — that is the usual shape: raise it pinned while
  /// the work runs, then update it to a result that dismisses itself.
  void update({
    NotificationSeverity? severity,
    String? title,
    String? body,
    String? characterId,
    IconData? icon,
    Duration? duration,
    bool clearCharacterId = false,
    bool clearIcon = false,
    bool pin = false,
  }) {
    _center.update(
      id,
      severity: severity,
      title: title,
      body: body,
      characterId: characterId,
      icon: icon,
      duration: duration,
      clearCharacterId: clearCharacterId,
      clearIcon: clearIcon,
      pin: pin,
    );
  }

  /// Removes it now.
  void dismiss() => _center.dismiss(id);
}

/// Owns the stack. Everything it does is a list operation — no timers.
///
/// **The auto-dismiss clock lives in the card**, not here, and that is
/// deliberate: the timer has to pause while the pointer is over a notification
/// (otherwise a long error vanishes mid-sentence), and "is the pointer over it"
/// is a fact only the widget has. Keeping the timers out also keeps this class
/// synchronous and trivially testable — a test asserts about a list, never about
/// elapsed time.
class NotificationCenter extends Notifier<List<AppNotification>> {
  @override
  List<AppNotification> build() => const [];

  int _nextId = 1;

  /// What is on screen right now, oldest first.
  ///
  /// Exists so [NotificationHandle] can ask without touching `state`, which
  /// Riverpod marks protected for anything that is not the notifier itself.
  List<AppNotification> get visible => state;

  /// Raises a notification and returns its handle.
  ///
  /// [duration] defaults to [kNotificationDurations] for the severity. Pass
  /// `duration: null` **with** `pinned: true` to keep it until it is dismissed —
  /// the extra flag exists because a bare null is indistinguishable from "not
  /// specified" in Dart, and silently defaulting a caller's intended pin to a
  /// 4-second timer is the kind of bug nobody finds.
  NotificationHandle show(
    String title, {
    required String body,
    NotificationSeverity severity = NotificationSeverity.info,
    String? characterId,
    IconData? icon,
    Duration? duration,
    bool pinned = false,
  }) {
    final notification = AppNotification(
      id: _nextId++,
      severity: severity,
      title: title,
      body: body,
      characterId: characterId,
      icon: icon,
      duration: pinned ? null : (duration ?? kNotificationDurations[severity]!),
    );

    // **Every notification the app raises passes through here**, so one call
    // covers all of them and no call site has to remember one. This is what
    // puts "what the user was actually told, and when" in the log beside the
    // failure that caused it.
    //
    // The text is already localized, so a Ukrainian UI writes Ukrainian here —
    // correct, because the point is to record what was on screen.
    _log.at(_levelFor(severity), 'notified', fields: {
      'severity': severity.name,
      'title': title,
      'body': body,
      if (pinned) 'pinned': true,
    });

    // Re-raising something already on screen moves it to the bottom and
    // restarts its clock rather than stacking a second copy: a folder scan that
    // fails the same way for eight files would otherwise fill the cap with one
    // repeated sentence and push everything else off. The survivor is the new
    // object, so it carries the current portrait.
    final next = [
      for (final n in state)
        if (!n.saysTheSameAs(notification)) n,
      notification,
    ];
    state = _capped(next);
    return NotificationHandle(this, notification.id);
  }

  /// Trims the stack to [kMaxVisibleNotifications], dropping the oldest
  /// **dismissable** notification rather than simply the oldest.
  ///
  /// A pinned one ends on a condition rather than a clock, and whoever raised it
  /// is holding a handle to [update] when that condition arrives — but an update
  /// to one that is gone is a deliberate no-op. So evicting a pinned card does
  /// not merely hide a sentence, it silently throws away the only report of the
  /// work it was tracking.
  ///
  /// Pinned ones still go once there is nothing else to drop. The cap is what
  /// keeps the corner from becoming a wall, and that has to hold whatever the
  /// stack happens to be made of.
  static List<AppNotification> _capped(List<AppNotification> all) {
    if (all.length <= kMaxVisibleNotifications) return all;
    final kept = List<AppNotification>.of(all);
    while (kept.length > kMaxVisibleNotifications) {
      final oldestDismissable = kept.indexWhere((n) => !n.isPinned);
      kept.removeAt(oldestDismissable >= 0 ? oldestDismissable : 0);
    }
    return kept;
  }

  NotificationHandle success(String title,
          {required String body,
          String? characterId,
          IconData? icon,
          Duration? duration}) =>
      show(title,
          body: body,
          severity: NotificationSeverity.success,
          characterId: characterId,
          icon: icon,
          duration: duration);

  NotificationHandle info(String title,
          {required String body,
          String? characterId,
          IconData? icon,
          Duration? duration}) =>
      show(title,
          body: body,
          severity: NotificationSeverity.info,
          characterId: characterId,
          icon: icon,
          duration: duration);

  NotificationHandle warning(String title,
          {required String body,
          String? characterId,
          IconData? icon,
          Duration? duration}) =>
      show(title,
          body: body,
          severity: NotificationSeverity.warning,
          characterId: characterId,
          icon: icon,
          duration: duration);

  NotificationHandle error(String title,
          {required String body,
          String? characterId,
          IconData? icon,
          Duration? duration}) =>
      show(title,
          body: body,
          severity: NotificationSeverity.error,
          characterId: characterId,
          icon: icon,
          duration: duration);

  /// A notification with no clock, for work whose end is an event rather than a
  /// moment. Dismiss it — or [NotificationHandle.update] it into a result — when
  /// that event happens.
  NotificationHandle pinned(
    String title, {
    required String body,
    NotificationSeverity severity = NotificationSeverity.info,
    String? characterId,
    IconData? icon,
  }) =>
      show(title,
          body: body,
          severity: severity,
          characterId: characterId,
          icon: icon,
          pinned: true);

  /// Rewrites one in place. A no-op if it is already gone.
  void update(
    int id, {
    NotificationSeverity? severity,
    String? title,
    String? body,
    String? characterId,
    IconData? icon,
    Duration? duration,
    bool clearCharacterId = false,
    bool clearIcon = false,
    bool pin = false,
  }) {
    if (!state.any((n) => n.id == id)) return;
    state = [
      for (final n in state)
        if (n.id == id)
          n.copyWith(
            severity: severity,
            title: title,
            body: body,
            characterId: characterId,
            icon: icon,
            // A severity change with no explicit duration re-clocks it to the
            // new severity's default: an update turning "working…" into an
            // error must not inherit the four seconds a success would have got.
            duration: duration ??
                (severity != null && !pin
                    ? kNotificationDurations[severity]
                    : null),
            clearCharacterId: clearCharacterId,
            clearIcon: clearIcon,
            clearDuration: pin,
          )
        else
          n,
    ];
  }

  void dismiss(int id) =>
      state = state.where((n) => n.id != id).toList(growable: false);

  void clear() => state = const [];
}

/// `context.notify.success(…)` — the one way call sites raise a notification.
///
/// Resolved through the `ProviderScope` rather than an inherited widget of its
/// own, with `listen: false`, so it is legal anywhere a context is: `initState`,
/// a dialog's builder, a plain top-level function that was handed a context.
/// Reading the notifier never rebuilds the caller.
extension NotifyContext on BuildContext {
  NotificationCenter get notify =>
      ProviderScope.containerOf(this, listen: false)
          .read(notificationsProvider.notifier);
}

/// The same object, for the widgets that already have a `ref` and no reason to
/// go through a context.
extension NotifyRef on WidgetRef {
  NotificationCenter get notify => read(notificationsProvider.notifier);
}
