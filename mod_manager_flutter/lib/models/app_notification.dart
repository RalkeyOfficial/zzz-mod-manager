import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// What a notification *is*, which is the only thing a call site decides about how it looks.
///
/// Deliberately not a colour, an icon or a duration. Picked per call site, across some 150 of them, the same kind
/// of event would look different depending on which screen raised it. The kind is the input; the look comes from it
/// in one place (`notificationLook` in `notification_overlay.dart`) and the clock from [kNotificationDurations].
enum NotificationKind {
  /// Work still running, with a bar. Stays until its owner ends it or turns it into its result.
  working,

  /// Something the user asked for finished.
  done,

  /// A plain fact with nothing at risk.
  note,

  /// Newer files were found.
  update,

  /// Something waits on a decision from the user. Stays until closed.
  needsYou,

  /// It worked, but not completely, or something needs attention.
  warning,

  /// It did not work. Stays until closed.
  error,
}

/// How long each kind stays. A kind that is not here stays until it is closed or its owner ends it.
///
/// Hovering the stack holds every clock, so these are floors on the unattended case rather than a race.
const Map<NotificationKind, Duration> kNotificationDurations = {
  NotificationKind.done: Duration(seconds: 5),
  NotificationKind.note: Duration(seconds: 5),
  NotificationKind.update: Duration(seconds: 8),
  NotificationKind.warning: Duration(seconds: 8),
};

/// How many cards show before the older ones fold into "+N more".
const int kVisibleNotifications = 3;

/// The backstop on the whole stack, folded cards included: past it, the oldest card with a clock goes.
const int kKeptNotifications = 20;

/// Marks the cards that share one slot of the stack as a deck, such as the downloads running at once.
///
/// Only Working cards and the Done cards they turn into are dealt into a deck; a card turned into any other kind
/// leaves it as its own card. Two decks are the same deck when their [key]s match.
@immutable
class NotificationDeck {
  const NotificationDeck(this.key, {required this.more});

  final String key;

  /// The front card's last line, "2 more downloading", for the [count] Working cards behind it.
  final String Function(int count) more;

  @override
  bool operator ==(Object other) => other is NotificationDeck && other.key == key;

  @override
  int get hashCode => key.hashCode;
}

/// A button on a card. Pressing it runs [onPressed] and then closes the card, unless [closes] is false.
///
/// The card is drawn above the `Navigator`, so [onPressed] reaches the app through what it captured where the card
/// was raised (a `ProviderContainer`), never through a `BuildContext` of this layer.
@immutable
class NotificationAction {
  const NotificationAction(this.label, this.onPressed, {this.closes = true});

  final String label;
  final VoidCallback onPressed;
  final bool closes;
}

/// Marks a notification that is counted on one card when it comes again, such as "3 mods installed".
///
/// A raise whose [key] matches a card of the same kind takes that card's place, with its [subjects] added to the
/// card's and the count raised by as many. Counting more than one subject, the card's title is [title] and its body
/// is [body] with the subject list drawn under it, or the subject list alone when [body] is null.
@immutable
class NotificationRepeat {
  const NotificationRepeat(this.key, {required this.subjects, this.title, this.body});

  final String key;

  /// What this raise counts, usually one: a mod's name. An install of three folders counts three.
  final List<String> subjects;

  /// The counted title, such as "3 mods installed".
  final String Function(int count)? title;

  /// The counted body, for a card whose body says more than its subject: what to do, what was kept. Null when the
  /// body is the subject itself, which the subject list then replaces.
  final String Function(int count)? body;
}

/// A headline and its subject, for a producer that decides what to say somewhere other than where it is said.
///
/// Deliberately *not* the shape of the `notify` methods: roughly half of all bodies are bare data the call site
/// already holds (`mod.name`, `e.toString()`) and would gain nothing from being wrapped.
@immutable
class NotificationLines {
  const NotificationLines(
    this.title,
    this.body, {
    this.kind = NotificationKind.warning,
    this.stays = false,
    this.characterId,
    this.repeat,
    this.actions = const [],
  });

  final String title;
  final String body;
  final NotificationKind kind;

  /// The card's buttons, such as Open folder on a failure that left an archive behind.
  final List<NotificationAction> actions;

  /// A warning that stays until it is closed. See [AppNotification.stays].
  final bool stays;

  /// Whose portrait leads the card, when the line is about a mod other than the one its producer was handed.
  final String? characterId;

  final NotificationRepeat? repeat;

  @override
  bool operator ==(Object other) =>
      other is NotificationLines &&
      other.title == title &&
      other.body == body &&
      other.kind == kind &&
      other.stays == stays &&
      other.characterId == characterId &&
      other.repeat?.key == repeat?.key &&
      listEquals(other.repeat?.subjects, repeat?.subjects) &&
      // By label: two closures are never equal, and what a line offers is what the user reads.
      listEquals([for (final a in other.actions) a.label], [for (final a in actions) a.label]);

  @override
  int get hashCode => Object.hash(title, body, kind, stays, characterId, repeat?.key,
      Object.hashAll(repeat?.subjects ?? const []), Object.hashAll([for (final a in actions) a.label]));
}

/// One message on the notification stack.
///
/// Immutable and identified by [id]: the overlay keys its cards on it, so updating a notification in place keeps
/// the same card, with its entrance animation and hover state, instead of sliding a new one in.
@immutable
class AppNotification {
  const AppNotification({
    required this.id,
    required this.kind,
    required this.title,
    required this.body,
    this.characterId,
    this.icon,
    this.progress,
    this.actions = const [],
    this.keycap,
    this.stays = false,
    this.repeat,
    this.count = 1,
    this.subjects = const [],
    this.deck,
  })  : assert(actions.length <= 2, 'A card has room for two actions.'),
        assert(progress == null || kind == NotificationKind.working, 'Only a Working card has a bar.'),
        assert(deck == null || kind == NotificationKind.working || kind == NotificationKind.done,
            'Only Working cards and their Done results are dealt into a deck.'),
        assert(progress == null || (progress >= 0 && progress <= 1), 'Progress is a fraction, 0 to 1.'),
        assert(!stays || kind == NotificationKind.warning, 'Only a warning is told to stay; the rest have a kind for it.'),
        assert(
          icon == null || characterId == null,
          'An explicit icon and a character both claim the leading slot. '
          'Pass one: the icon wins, and the portrait would be dropped silently.',
        );

  /// Unique and monotonic.
  final int id;

  final NotificationKind kind;

  /// What happened, in a few words. "Mod installed", "Couldn't extract the archive".
  final String title;

  /// The one thing it happened to: the mod's name, the path, the reason it failed. Where a call site has no
  /// subject in hand, the single next step the user can take. Holds `{key}` where [keycap] is drawn.
  ///
  /// Required, like [title]. An optional second level is a level nobody fills in.
  final String body;

  /// Whose portrait leads the card, when the notification is about one mod. A category, `unknown` or an
  /// unrecognised id shows the kind's plain icon instead.
  final String? characterId;

  /// Overrides the icon the kind would choose, keeping the kind's colours. Exclusive with [characterId].
  final IconData? icon;

  /// A Working card's share of the work done, 0 to 1. Null draws a sweep for work of unknown size.
  final double? progress;

  /// At most two, the first the primary one except on a Note.
  final List<NotificationAction> actions;

  /// The key drawn where [body] says `{key}`, such as `F10`.
  final String? keycap;

  /// A warning that stays until it is closed, instead of leaving after the kind's eight seconds.
  ///
  /// For a warning about a mod that will not work until the user acts, or about something the next action will
  /// likely fail on until the user fixes it, such as the DNS before a launch. An install can raise several cards at
  /// once, and the one that says *this mod will not work until you do something* would otherwise leave beside the
  /// one that says the install succeeded, which is the line the user was waiting for.
  final bool stays;

  final NotificationRepeat? repeat;

  /// How many [subjects] this card counts, 1 without a [repeat]. Past 1 the card is drawn counted: the subject list,
  /// no portrait and no actions.
  final int count;

  /// The [repeat] subjects so far, oldest first.
  final List<String> subjects;

  /// The deck this card is dealt into, sharing one slot with the cards of the same deck.
  final NotificationDeck? deck;

  /// How long it stays before closing itself, or null to stay until it is closed or its owner ends it.
  Duration? get duration => stays ? null : kNotificationDurations[kind];

  bool get hasClock => duration != null;

  /// Whether [other] is *the same thing being said again*, which makes a re-raise move the card to the newest
  /// place instead of stacking a duplicate.
  ///
  /// Not full equality: the portrait and icon are pictures of what a card says, not part of what it says. Cards
  /// with a [repeat] are counted instead, so they never match here, and neither does a Working card, whose owner
  /// holds its handle: two downloads of one mod both read "Installing Ellen Swimsuit / Waiting for a free slot".
  bool saysTheSameAs(AppNotification other) =>
      repeat == null &&
      other.repeat == null &&
      kind != NotificationKind.working &&
      other.kind == kind &&
      other.title == title &&
      other.body == body;

  AppNotification copyWith({
    int? id,
    NotificationKind? kind,
    String? title,
    String? body,
    String? characterId,
    IconData? icon,
    double? progress,
    List<NotificationAction>? actions,
    String? keycap,
    bool? stays,
    NotificationRepeat? repeat,
    int? count,
    List<String>? subjects,
    NotificationDeck? deck,
    bool clearCharacterId = false,
    bool clearIcon = false,
    bool clearProgress = false,
    bool clearDeck = false,
  }) {
    return AppNotification(
      id: id ?? this.id,
      kind: kind ?? this.kind,
      title: title ?? this.title,
      body: body ?? this.body,
      characterId: clearCharacterId ? null : (characterId ?? this.characterId),
      icon: clearIcon ? null : (icon ?? this.icon),
      progress: clearProgress ? null : (progress ?? this.progress),
      actions: actions ?? this.actions,
      keycap: keycap ?? this.keycap,
      stays: stays ?? this.stays,
      repeat: repeat ?? this.repeat,
      count: count ?? this.count,
      subjects: subjects ?? this.subjects,
      deck: clearDeck ? null : (deck ?? this.deck),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AppNotification &&
      other.id == id &&
      other.kind == kind &&
      other.title == title &&
      other.body == body &&
      other.characterId == characterId &&
      other.icon == icon &&
      other.progress == progress &&
      listEquals(other.actions, actions) &&
      other.keycap == keycap &&
      other.stays == stays &&
      other.repeat == repeat &&
      other.count == count &&
      listEquals(other.subjects, subjects) &&
      other.deck == deck;

  @override
  int get hashCode => Object.hash(id, kind, title, body, characterId, icon, progress, Object.hashAll(actions), keycap,
      stays, repeat, count, Object.hashAll(subjects), deck);
}
