import 'package:flutter/material.dart';

/// What a notification *means*, which is the only thing a call site has to
/// decide.
///
/// Deliberately not a colour and not an icon. Picked per call site — across ~60
/// of them — the same kind of event looks different depending on which screen
/// raised it, because whatever is nearest wins: `Colors.red` in one place and
/// `colorScheme.error` in the next. The severity is the input; the look is
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

/// A headline and its subject, for a producer that decides what to say
/// somewhere other than where it is said.
///
/// Deliberately *not* the shape of the `notify` methods: roughly half of all
/// bodies are bare data the call site already holds (`mod.name`, `e.toString()`)
/// and would gain nothing from being wrapped.
@immutable
class NotificationLines {
  const NotificationLines(this.title, this.body, {this.pinned = false});

  final String title;
  final String body;

  /// Stays until dismissed instead of timing out.
  ///
  /// For the warning the user must not read over. An install raises up to four
  /// cards at once and a warning clears itself in eight seconds, so the one
  /// that says *this mod will not work until you do something* competes with
  /// the one that says the install succeeded — and loses, because the success
  /// is the line they were waiting for.
  final bool pinned;

  @override
  bool operator ==(Object other) =>
      other is NotificationLines &&
      other.title == title &&
      other.body == body &&
      other.pinned == pinned;

  @override
  int get hashCode => Object.hash(title, body, pinned);
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
  AppNotification({
    required this.id,
    required this.severity,
    required this.title,
    required this.body,
    this.characterId,
    this.icon,
    this.duration,
  }) : assert(
          icon == null || characterId == null,
          'An explicit icon and a character both claim the leading slot. '
          'Pass one: the icon wins, and the portrait would be dropped silently.',
        );

  /// Unique and monotonic, so the newest is always last in the list.
  final int id;

  final NotificationSeverity severity;

  /// What happened, in a few words. "Mod installed", "Couldn't extract the
  /// archive".
  final String title;

  /// The one thing it happened to — the mod's name, the path, the reason it
  /// failed. Where a call site has no subject in hand, the single next step the
  /// user can take.
  ///
  /// Required, like [title]. An optional second level is a level nobody fills
  /// in: for the whole life of the earlier two-field version, not one call site
  /// passed a headline.
  final String body;

  /// Whose portrait leads the card, when the notification is about one mod.
  ///
  /// Also accepts a built-in category id; the overlay falls back to that
  /// category's own icon. Null, `unknown` or an unrecognised id fall back to
  /// the severity icon.
  final String? characterId;

  /// Overrides the icon [severity] would otherwise choose. Mutually exclusive
  /// with [characterId] — see the constructor's assert.
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

  /// Whether [other] is *the same thing being said again*, which is what makes
  /// re-raising it move down the stack instead of stacking a duplicate.
  ///
  /// Deliberately not full equality. [icon] and [characterId] are pictures of
  /// what a notification says, not part of what it says, and [duration] is how
  /// long it says it for — a second raise differing only in those is the same
  /// sentence, and the newer one's picture is the current one.
  ///
  /// It lives here rather than inline in `show` so that the next field added to
  /// this class has to answer the question rather than silently join the key or
  /// silently miss it.
  bool saysTheSameAs(AppNotification other) =>
      other.severity == severity &&
      other.title == title &&
      other.body == body;

  AppNotification copyWith({
    NotificationSeverity? severity,
    String? title,
    String? body,
    String? characterId,
    IconData? icon,
    Duration? duration,
    bool clearCharacterId = false,
    bool clearIcon = false,
    bool clearDuration = false,
  }) {
    return AppNotification(
      id: id,
      severity: severity ?? this.severity,
      title: title ?? this.title,
      body: body ?? this.body,
      // `copyWith` cannot express "back to nothing" with a nullable value, and
      // an update that turns a pinned notification into a self-dismissing one
      // has to be able to — as does one that drops a portrait or an icon.
      //
      // There is no `clearTitle`/`clearBody`: neither has a "back to nothing"
      // state, which is the point of both being required.
      characterId: clearCharacterId ? null : (characterId ?? this.characterId),
      icon: clearIcon ? null : (icon ?? this.icon),
      duration: clearDuration ? null : (duration ?? this.duration),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AppNotification &&
      other.id == id &&
      other.severity == severity &&
      other.title == title &&
      other.body == body &&
      other.characterId == characterId &&
      other.icon == icon &&
      other.duration == duration;

  @override
  int get hashCode =>
      Object.hash(id, severity, title, body, characterId, icon, duration);
}
