import 'package:flutter/material.dart';

/// What a notification *means*, which is the only thing a call site has to
/// decide.
///
/// Deliberately not a colour and not an icon. Both used to be picked at each of
/// the ~60 call sites, by hand, from whatever was nearest — `Colors.red` in one
/// place and `colorScheme.error` in the next, `Colors.orange` for a warning here
/// and nothing at all there — so the same kind of event looked different
/// depending on which screen raised it. The severity is the input; the look is
/// derived from it in exactly one place (`notification_overlay.dart`).
enum NotificationSeverity {
  /// Something the user asked for finished. The default for "done".
  success,

  /// Neutral progress or a statement of fact. Nothing went wrong.
  info,

  /// It worked, but not completely, or it needs attention before it will.
  warning,

  /// It did not work.
  error,
}

/// One message on the notification stack.
///
/// Immutable and value-identified by [id]: the overlay keys its cards on it, so
/// updating a notification in place (see `NotificationHandle.update`) keeps the
/// same card — and therefore the same entrance animation, position in the stack
/// and hover state — instead of replacing it with a new one that slides in from
/// scratch.
@immutable
class AppNotification {
  const AppNotification({
    required this.id,
    required this.severity,
    required this.message,
    this.title,
    this.icon,
    this.duration,
  });

  /// Unique and monotonic, so the newest is always last in the list.
  final int id;

  final NotificationSeverity severity;

  /// The body. Always present — a notification with no message says nothing.
  final String message;

  /// An optional headline above [message].
  ///
  /// Optional rather than defaulted per severity, because most messages here
  /// are already a whole sentence and a generic "Success" above one is noise.
  /// It earns its place where a call site genuinely has two levels — "Imported
  /// Ellen Swimsuit" over "Auto-tags: … · 2 mods have no .ini" — which used to
  /// be sent as two separate bars, one of which pushed the other off screen.
  final String? title;

  /// Overrides the icon [severity] would otherwise choose.
  final IconData? icon;

  /// How long it stays before dismissing itself, or **null to stay until it is
  /// dismissed** — by the user's close button, or by whoever raised it.
  ///
  /// Null is what makes a notification usable for something still happening: a
  /// caller holds the handle, and calls `update` or `dismiss` when the work it
  /// describes is done. See `NotificationCenter.show`.
  final Duration? duration;

  /// Whether this one waits for something rather than for a clock.
  bool get isPinned => duration == null;

  AppNotification copyWith({
    NotificationSeverity? severity,
    String? message,
    String? title,
    IconData? icon,
    Duration? duration,
    bool clearTitle = false,
    bool clearIcon = false,
    bool clearDuration = false,
  }) {
    return AppNotification(
      id: id,
      severity: severity ?? this.severity,
      message: message ?? this.message,
      // `copyWith` cannot express "back to nothing" with a nullable value, and
      // an update that turns a pinned notification into a self-dismissing one
      // has to be able to — as does one that drops a title.
      title: clearTitle ? null : (title ?? this.title),
      icon: clearIcon ? null : (icon ?? this.icon),
      duration: clearDuration ? null : (duration ?? this.duration),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AppNotification &&
      other.id == id &&
      other.severity == severity &&
      other.message == message &&
      other.title == title &&
      other.icon == icon &&
      other.duration == duration;

  @override
  int get hashCode => Object.hash(id, severity, message, title, icon, duration);
}
