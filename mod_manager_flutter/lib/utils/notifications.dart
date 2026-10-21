/// The app's notification queue: what is currently being told to the user.
///
/// Kept out of `state_providers.dart` for the same reason the marketplace's browsing session is: that file is the
/// registry of state the *app* is in (library, theme, locale, tab), while this is one subsystem with its own
/// vocabulary. The pointer over there says where to find it.
///
/// ## Raising one
///
/// Every notification is two levels, **what happened** and **what it happened to**, and a kind. Both levels are
/// required, which stops a card being a lone headline over blank space. The kind is the only other thing a call
/// site decides: colour, icon and how long it stays come from it.
///
/// ```dart
/// context.notify.done(
///   loc.t('marketplace.install_success_title_single'),
///   body: mod.name,
///   characterId: mod.characterId,   // leads the card with their portrait
/// );
/// ```
///
/// Capture it in a local before an `await` and it keeps working afterwards with no `mounted` check; it is a plain
/// object, not a `BuildContext` lookup:
///
/// ```dart
/// final notify = context.notify;
/// await doTheWork();
/// notify.done('…', body: '…');
/// ```
///
/// ## Work in progress
///
/// A Working card has no clock and a bar. Its handle turns it into its result in place:
///
/// ```dart
/// final saving = context.notify.working('Saving tag…', body: mod.name);
/// await save();
/// saving.update(kind: NotificationKind.error, title: 'Couldn\'t save the tag');
/// // …or saving.dismiss();
/// ```
///
/// The body is the stable subject, so it carries over. Raising builds a whole statement and needs both levels;
/// updating changes part of a statement that already exists, which is why every parameter of
/// [NotificationHandle.update] is optional.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../models/app_notification.dart';
import '../services/log/log_level.dart';
import '../services/log/logger.dart';

export '../models/app_notification.dart';

final Logger _log = Logger('ui.notify');

/// A kind as a log level. Only the two that say something went wrong differ from info.
LogLevel _levelFor(NotificationKind kind) => switch (kind) {
      NotificationKind.error => LogLevel.error,
      NotificationKind.warning => LogLevel.warning,
      _ => LogLevel.info,
    };

/// The subjects of a card about several, "A", "A and B", "A, B and 3 more": the body of a counted card and of a
/// Working card over several mods.
String subjectList(AppLocalizations loc, List<String> names) {
  if (names.length < 2) return names.join();
  if (names.length == 2) {
    return loc.t('notifications.subjects_two', params: {'first': names[0], 'second': names[1]});
  }
  final more = names.length - 2;
  return loc.plural('notifications.subjects_more', more,
      params: {'first': names[0], 'second': names[1], 'count': '$more'});
}

/// The notification stack, oldest first. List order is stack order: the newest is drawn at the bottom.
final notificationsProvider = NotifierProvider<NotificationCenter, List<AppNotification>>(NotificationCenter.new);

/// A raised notification, for as long as the caller wants to keep talking about it.
///
/// Safe to keep and to call after the card is gone: [update] and [dismiss] on something no longer in the stack do
/// nothing, because the user may close it at any moment.
class NotificationHandle {
  const NotificationHandle(this._center, this.id);

  final NotificationCenter _center;

  /// Identifies this notification for as long as it is on screen.
  final int id;

  /// Whether it is still in the stack.
  bool get isVisible => _center.visible.any((n) => n.id == id);

  /// Rewrites it. Every parameter is optional and unspecified means unchanged.
  ///
  /// Changing [kind] turns the card into its result: the bar goes, the clock is the new kind's, and the card moves
  /// to the newest place, so a result raised after its warnings still ends the burst. A result other than Done
  /// leaves the card's deck.
  void update({
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
    bool clearCharacterId = false,
    bool clearIcon = false,
    bool clearProgress = false,
  }) {
    _center.update(
      id,
      kind: kind,
      title: title,
      body: body,
      characterId: characterId,
      icon: icon,
      progress: progress,
      actions: actions,
      keycap: keycap,
      stays: stays,
      repeat: repeat,
      clearCharacterId: clearCharacterId,
      clearIcon: clearIcon,
      clearProgress: clearProgress,
    );
  }

  /// Removes it now, the owner ending it.
  void dismiss() => _center.dismiss(id);
}

/// Owns the stack. Everything it does is a list operation, with no timers.
///
/// **The clock lives in the card**, not here: it has to stop while the pointer is over the stack, and that is a
/// fact only the widget has. It also keeps this class synchronous, so a test asserts about a list, never about
/// elapsed time.
class NotificationCenter extends Notifier<List<AppNotification>> {
  @override
  List<AppNotification> build() => const [];

  int _nextId = 1;

  /// Working cards the user hid, by id, kept so their result can still be shown.
  final Map<int, AppNotification> _hidden = {};

  /// What is in the stack right now, oldest first, folded cards included.
  List<AppNotification> get visible => state;

  /// Raises a notification and returns its handle.
  NotificationHandle show(
    NotificationKind kind,
    String title, {
    required String body,
    String? characterId,
    IconData? icon,
    double? progress,
    List<NotificationAction> actions = const [],
    String? keycap,
    bool stays = false,
    NotificationRepeat? repeat,
    NotificationDeck? deck,
  }) {
    if (repeat != null) {
      final index = state.indexWhere((n) => n.kind == kind && n.repeat?.key == repeat.key);
      if (index >= 0) return _merge(state[index], title, body, repeat);
    }

    final raised = AppNotification(
      id: _nextId++,
      kind: kind,
      title: title,
      body: body,
      characterId: characterId,
      icon: icon,
      progress: progress,
      actions: actions,
      keycap: keycap,
      stays: stays,
      deck: deck,
    );
    final notification = repeat == null ? raised : _counted(raised, repeat, repeat.subjects);
    _logRaise(notification);

    // Re-raising something already on screen moves it to the newest place and restarts its clock rather than
    // stacking a second copy: a scan that fails the same way for eight files would otherwise fill the stack with
    // one sentence. The survivor is the new object, so it carries the current portrait.
    state = _kept([
      for (final n in state)
        if (!n.saysTheSameAs(notification)) n,
      notification,
    ]);
    return NotificationHandle(this, notification.id);
  }

  /// [card] counting [subjects]. Past one, it takes the repeat's counted title and body, and its portrait and
  /// actions go, since both were about one mod.
  static AppNotification _counted(AppNotification card, NotificationRepeat repeat, List<String> subjects) {
    final count = subjects.isEmpty ? 1 : subjects.length;
    if (count == 1) return card.copyWith(repeat: repeat, subjects: subjects, count: 1);
    return AppNotification(
      id: card.id,
      kind: card.kind,
      title: repeat.title?.call(count) ?? card.title,
      body: repeat.body?.call(count) ?? card.body,
      icon: card.icon,
      progress: card.progress,
      keycap: card.keycap,
      stays: card.stays,
      repeat: repeat,
      count: count,
      subjects: subjects,
      deck: card.deck,
    );
  }

  /// Counts a repeat on [card]: same id, its subjects added, moved to the newest place.
  NotificationHandle _merge(AppNotification card, String title, String body, NotificationRepeat repeat) {
    final merged = _counted(card.copyWith(title: title, body: body), repeat, [...card.subjects, ...repeat.subjects]);
    _logRaise(merged);
    state = [
      for (final n in state)
        if (n.id != card.id) n,
      merged,
    ];
    return NotificationHandle(this, card.id);
  }

  /// Every notification the app raises passes through here, so the log holds what the user was told and when,
  /// beside whatever caused it. The text is already localized: the point is to record what was on screen.
  void _logRaise(AppNotification n) {
    final keycap = n.keycap;
    _log.at(_levelFor(n.kind), 'notified', fields: {
      'kind': n.kind.name,
      'title': n.title,
      'body': keycap == null ? n.body : n.body.replaceAll('{key}', keycap),
      if (n.repeat != null) 'key': n.repeat!.key,
      if (n.repeat != null) 'count': n.count,
      if (n.stays) 'stays': true,
    });
  }

  /// Trims the stack to [kKeptNotifications], dropping the oldest card with a clock rather than simply the oldest.
  ///
  /// A card with no clock is waiting for something: an owner holding its handle, or a reader who has not seen an
  /// error yet. Dropping it throws away the only report of that. It still goes once nothing else can, so the
  /// backstop holds whatever the stack is made of.
  static List<AppNotification> _kept(List<AppNotification> all) {
    if (all.length <= kKeptNotifications) return all;
    final kept = List<AppNotification>.of(all);
    while (kept.length > kKeptNotifications) {
      final oldestTimed = kept.indexWhere((n) => n.hasClock);
      kept.removeAt(oldestTimed >= 0 ? oldestTimed : 0);
    }
    return kept;
  }

  /// [deck] deals it into one slot with the other Working cards of that deck, such as the downloads running at once.
  NotificationHandle working(String title,
          {required String body,
          String? characterId,
          IconData? icon,
          double? progress,
          List<NotificationAction> actions = const [],
          NotificationDeck? deck}) =>
      show(NotificationKind.working, title,
          body: body, characterId: characterId, icon: icon, progress: progress, actions: actions, deck: deck);

  NotificationHandle done(String title,
          {required String body,
          String? characterId,
          IconData? icon,
          List<NotificationAction> actions = const [],
          String? keycap,
          NotificationRepeat? repeat}) =>
      show(NotificationKind.done, title,
          body: body, characterId: characterId, icon: icon, actions: actions, keycap: keycap, repeat: repeat);

  NotificationHandle note(String title,
          {required String body,
          String? characterId,
          IconData? icon,
          List<NotificationAction> actions = const [],
          String? keycap,
          NotificationRepeat? repeat}) =>
      show(NotificationKind.note, title,
          body: body, characterId: characterId, icon: icon, actions: actions, keycap: keycap, repeat: repeat);

  /// The Update kind: newer files were found. Named apart from [update], which rewrites a card.
  NotificationHandle updateAvailable(String title,
          {required String body,
          String? characterId,
          IconData? icon,
          List<NotificationAction> actions = const [],
          String? keycap,
          NotificationRepeat? repeat}) =>
      show(NotificationKind.update, title,
          body: body, characterId: characterId, icon: icon, actions: actions, keycap: keycap, repeat: repeat);

  NotificationHandle needsYou(String title,
          {required String body,
          String? characterId,
          IconData? icon,
          List<NotificationAction> actions = const [],
          String? keycap,
          NotificationRepeat? repeat}) =>
      show(NotificationKind.needsYou, title,
          body: body, characterId: characterId, icon: icon, actions: actions, keycap: keycap, repeat: repeat);

  /// [stays] keeps it until it is closed: for a mod that will not work until the user acts.
  NotificationHandle warning(String title,
          {required String body,
          String? characterId,
          IconData? icon,
          List<NotificationAction> actions = const [],
          String? keycap,
          bool stays = false,
          NotificationRepeat? repeat}) =>
      show(NotificationKind.warning, title,
          body: body,
          characterId: characterId,
          icon: icon,
          actions: actions,
          keycap: keycap,
          stays: stays,
          repeat: repeat);

  NotificationHandle error(String title,
          {required String body,
          String? characterId,
          IconData? icon,
          List<NotificationAction> actions = const [],
          String? keycap,
          NotificationRepeat? repeat}) =>
      show(NotificationKind.error, title,
          body: body, characterId: characterId, icon: icon, actions: actions, keycap: keycap, repeat: repeat);

  /// Rewrites one. A no-op if it is gone; see [NotificationHandle.update].
  ///
  /// A Working card the user hid takes progress updates silently, and comes back as a card when an update turns it
  /// into its result: hiding the progress never hides the outcome.
  void update(
    int id, {
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
    bool clearCharacterId = false,
    bool clearIcon = false,
    bool clearProgress = false,
  }) {
    final hidden = _hidden[id];
    final index = state.indexWhere((n) => n.id == id);
    final current = index >= 0 ? state[index] : hidden;
    if (current == null) return;

    final resolved = kind != null && kind != current.kind;
    final nextKind = kind ?? current.kind;
    var next = current.copyWith(
      kind: kind,
      title: title,
      body: body,
      characterId: characterId,
      icon: icon,
      progress: nextKind == NotificationKind.working ? progress : null,
      actions: actions,
      keycap: keycap,
      stays: nextKind == NotificationKind.warning ? (stays ?? current.stays) : false,
      clearCharacterId: clearCharacterId,
      clearIcon: clearIcon,
      clearProgress: clearProgress || nextKind != NotificationKind.working,
      // A failure or a question is read on its own, so it leaves the deck as a card of its own.
      clearDeck: nextKind != NotificationKind.working && nextKind != NotificationKind.done,
    );

    if (repeat != null) {
      // A result that repeats a card already in the stack is counted on that card, as a raise would be.
      final other = state.where((n) => n.id != id && n.kind == nextKind && n.repeat?.key == repeat.key).firstOrNull;
      if (other != null) {
        _hidden.remove(id);
        state = [
          for (final n in state)
            if (n.id != id) n,
        ];
        _merge(other, next.title, next.body, repeat);
        return;
      }
      next = _counted(next, repeat, repeat.subjects);
    }
    if (resolved) _logRaise(next);

    if (hidden != null) {
      if (nextKind == NotificationKind.working) {
        _hidden[id] = next;
        return;
      }
      _hidden.remove(id);
      state = _kept([...state, next]);
      return;
    }

    state = resolved
        ? [
            for (final n in state)
              if (n.id != id) n,
            next,
          ]
        : [
            for (final n in state) n.id == id ? next : n,
          ];
  }

  /// The user's close button. A Working card is kept aside so its result can still arrive; see [update].
  void close(int id) {
    final index = state.indexWhere((n) => n.id == id);
    if (index < 0) return;
    final card = state[index];
    if (card.kind == NotificationKind.working) _hidden[id] = card;
    state = [
      for (final n in state)
        if (n.id != id) n,
    ];
  }

  /// The owner ending it, shown or hidden.
  void dismiss(int id) {
    _hidden.remove(id);
    if (!state.any((n) => n.id == id)) return;
    state = [
      for (final n in state)
        if (n.id != id) n,
    ];
  }

  void clear() {
    _hidden.clear();
    state = const [];
  }
}

/// `context.notify.done(…)`, the one way call sites raise a notification.
///
/// Resolved through the `ProviderScope` with `listen: false`, so it is legal anywhere a context is: `initState`, a
/// dialog's builder, a top-level function handed a context. Reading the notifier never rebuilds the caller.
extension NotifyContext on BuildContext {
  NotificationCenter get notify =>
      ProviderScope.containerOf(this, listen: false).read(notificationsProvider.notifier);
}

/// The same object, for widgets that already have a `ref`.
extension NotifyRef on WidgetRef {
  NotificationCenter get notify => read(notificationsProvider.notifier);
}
