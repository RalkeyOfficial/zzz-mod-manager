import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/services/log/log_format.dart';
import 'package:mod_manager_flutter/services/log/log_level.dart';
import 'package:mod_manager_flutter/services/log/log_record.dart';
import 'package:mod_manager_flutter/services/log/log_sinks.dart';
import 'package:mod_manager_flutter/services/log/logger.dart';
import 'package:mod_manager_flutter/utils/notifications.dart';

/// The notification queue: the list half, with no widgets and no clock.
///
/// The clock lives in the card (see `notification_overlay.dart`), which is what lets everything here be asserted as
/// a plain list operation.
void main() {
  late ProviderContainer container;
  NotificationCenter center() => container.read(notificationsProvider.notifier);
  List<AppNotification> state() => container.read(notificationsProvider);

  setUp(() {
    container = ProviderContainer();
  });

  tearDown(() => container.dispose());

  test('starts empty', () {
    expect(state(), isEmpty);
  });

  test('newest goes last, which is what puts it at the bottom of the stack', () {
    center().note('first', body: 'a');
    center().note('second', body: 'b');
    expect(state().map((n) => n.title), ['first', 'second']);
  });

  group('each kind has its own clock', () {
    test('Done and Note 5s, Update and Warning 8s', () {
      center().done('a', body: 'x');
      center().note('b', body: 'x');
      center().updateAvailable('c', body: 'x');
      center().warning('d', body: 'x');
      expect(state().map((n) => n.duration), const [
        Duration(seconds: 5),
        Duration(seconds: 5),
        Duration(seconds: 8),
        Duration(seconds: 8),
      ]);
    });

    test('Working, Needs you and Error stay until closed', () {
      center().working('a', body: 'x');
      center().needsYou('b', body: 'x');
      center().error('c', body: 'x');
      expect(state().map((n) => n.hasClock), [false, false, false]);
    });

    test('a staying warning has no clock', () {
      center().warning('a', body: 'x', stays: true);
      expect(state().single.duration, isNull);
    });
  });

  group('what a card refuses', () {
    test('a third action', () {
      void noop() {}
      expect(
        () => center().done('a', body: 'x', actions: [
          NotificationAction('1', noop),
          NotificationAction('2', noop),
          NotificationAction('3', noop),
        ]),
        throwsAssertionError,
      );
    });

    test('progress on a kind that is not Working, or outside 0..1', () {
      expect(() => center().show(NotificationKind.done, 'a', body: 'x', progress: 0.5), throwsAssertionError);
      expect(() => center().working('a', body: 'x', progress: 1.5), throwsAssertionError);
    });

    test('staying on a kind that is not a warning', () {
      expect(() => center().show(NotificationKind.error, 'a', body: 'x', stays: true), throwsAssertionError);
    });

    test('an icon and a character both claiming the leading slot', () {
      expect(
        () => center().done('Saved', body: 'Ellen Swimsuit', characterId: 'ellen', icon: Icons.save_alt_rounded),
        throwsAssertionError,
      );
    });
  });

  group('the backstop', () {
    test('drops nothing below it', () {
      for (var i = 0; i < kKeptNotifications; i++) {
        center().done('message $i', body: 'x');
      }
      expect(state(), hasLength(kKeptNotifications));
    });

    test('past it, drops the oldest card with a clock, never one that waits', () {
      center().working('Downloading', body: 'Ellen Swimsuit');
      center().error('Failed', body: 'x');
      center().needsYou('Decide', body: 'x');
      for (var i = 0; i < kKeptNotifications; i++) {
        center().done('message $i', body: 'x');
      }
      expect(state(), hasLength(kKeptNotifications));
      expect(state().take(3).map((n) => n.kind),
          [NotificationKind.working, NotificationKind.error, NotificationKind.needsYou]);
      expect(state().any((n) => n.title == 'message 2'), isFalse);
      expect(state().any((n) => n.title == 'message 3'), isTrue);
    });

    test('still holds when nothing in it has a clock', () {
      for (var i = 0; i < kKeptNotifications + 2; i++) {
        center().error('error $i', body: 'x');
      }
      expect(state(), hasLength(kKeptNotifications));
      expect(state().first.title, 'error 2');
    });
  });

  group('the same sentence again', () {
    test('moves to the newest place with a new id rather than stacking', () {
      center().error('Couldn\'t save', body: 'Ellen');
      final first = state().single.id;
      center().note('Other', body: 'x');
      center().error('Couldn\'t save', body: 'Ellen');
      expect(state().map((n) => n.title), ['Other', 'Couldn\'t save']);
      expect(state().last.id, isNot(first));
    });

    test('a different kind with the same words is a different card', () {
      center().note('Saved', body: 'x');
      center().done('Saved', body: 'x');
      expect(state(), hasLength(2));
    });
  });

  group('repeats', () {
    NotificationRepeat installed(String subject) =>
        NotificationRepeat('install-done', subjects: [subject], title: (n) => '$n mods installed');

    test('count on one card: same id, the count and subjects grow, the counted title', () {
      final first = center().done('Mod installed', body: 'A', characterId: 'ellen', repeat: installed('A'));
      center().done('Mod installed', body: 'B', characterId: 'ellen', repeat: installed('B'));
      center().done('Mod installed', body: 'C', characterId: 'ellen', repeat: installed('C'));
      final card = state().single;
      expect(card.id, first.id);
      expect(card.count, 3);
      expect(card.subjects, ['A', 'B', 'C']);
      expect(card.title, '3 mods installed');
    });

    test('the portrait and the actions go once it counts several', () {
      void noop() {}
      center().done('Mod installed',
          body: 'A', characterId: 'ellen', actions: [NotificationAction('Open', noop)], repeat: installed('A'));
      center().done('Mod installed',
          body: 'B', characterId: 'ellen', actions: [NotificationAction('Open', noop)], repeat: installed('B'));
      expect(state().single.characterId, isNull);
      expect(state().single.actions, isEmpty);
    });

    test('a merge moves the card to the newest place', () {
      center().done('Mod installed', body: 'A', repeat: installed('A'));
      center().warning('Something', body: 'x');
      center().done('Mod installed', body: 'B', repeat: installed('B'));
      expect(state().map((n) => n.kind), [NotificationKind.warning, NotificationKind.done]);
    });

    test('a different kind with the same key does not merge', () {
      center().done('Mod installed', body: 'A', repeat: installed('A'));
      center().note('Mod installed', body: 'B', repeat: installed('B'));
      expect(state(), hasLength(2));
      expect(state().map((n) => n.count), [1, 1]);
    });

    test('counts subjects, not raises: three folders and one more read four', () {
      center().done('Mods installed',
          body: 'A, B, C',
          repeat: NotificationRepeat('install-done', subjects: const ['A', 'B', 'C'], title: (n) => '$n mods installed'));
      center().done('Mod installed', body: 'D', repeat: installed('D'));
      expect(state().single.count, 4);
      expect(state().single.subjects, ['A', 'B', 'C', 'D']);
      expect(state().single.title, '4 mods installed');
    });

    test('a counted card keeps its instruction, in its counted form', () {
      NotificationRepeat patched(String mod) =>
          NotificationRepeat('patch-applied', subjects: [mod], body: (n) => '$n mods have the patch. A copy was saved.');
      center().done('Patch applied', body: 'A has the patch. A copy was saved.', repeat: patched('A'));
      expect(state().single.body, 'A has the patch. A copy was saved.', reason: 'one subject keeps its own body');
      center().done('Patch applied', body: 'B has the patch. A copy was saved.', repeat: patched('B'));
      expect(state().single.body, '2 mods have the patch. A copy was saved.');
      expect(state().single.subjects, ['A', 'B']);
    });

    test('a Working card turned into a result folds into the matching repeat on screen', () {
      center().done('Mod installed', body: 'A', repeat: installed('A'));
      final working = center().working('Installing', body: 'B');
      working.update(kind: NotificationKind.done, title: 'Mod installed', repeat: installed('B'));
      expect(state().single.count, 2);
      expect(state().single.title, '2 mods installed');
      expect(working.isVisible, isFalse);
    });
  });

  group('a Working card', () {
    test('turned into its result keeps its id, drops the bar, takes the clock and moves to the newest place', () {
      final working = center().working('Installing', body: 'Ellen Swimsuit', progress: 0.4);
      center().warning('A warning', body: 'x');
      working.update(kind: NotificationKind.done, title: 'Mod installed');
      final card = state().last;
      expect(card.id, working.id);
      expect(card.kind, NotificationKind.done);
      expect(card.progress, isNull);
      expect(card.duration, kNotificationDurations[NotificationKind.done]);
      expect(card.body, 'Ellen Swimsuit');
    });

    test('a progress update keeps its place', () {
      final working = center().working('Installing', body: 'x', progress: 0.1);
      center().warning('A warning', body: 'x');
      working.update(progress: 0.6);
      expect(state().first.id, working.id);
      expect(state().first.progress, 0.6);
    });

    test('clearProgress turns the bar into the sweep', () {
      final working = center().working('Installing', body: 'x', progress: 0.1);
      working.update(clearProgress: true);
      expect(state().single.progress, isNull);
    });

    group('hidden by the user', () {
      test('takes progress silently', () {
        final working = center().working('Installing', body: 'x', progress: 0.1);
        center().close(working.id);
        working.update(progress: 0.8, title: 'Installing 80%');
        expect(state(), isEmpty);
        expect(working.isVisible, isFalse);
      });

      test('comes back as a card when it turns into its result', () {
        final working = center().working('Installing', body: 'Ellen', progress: 0.1);
        center().close(working.id);
        working.update(kind: NotificationKind.error, title: 'Couldn\'t install');
        expect(state().single.kind, NotificationKind.error);
        expect(state().single.title, 'Couldn\'t install');
        expect(state().single.body, 'Ellen');
      });

      test('is forgotten when its owner dismisses it', () {
        final working = center().working('Installing', body: 'x');
        center().close(working.id);
        working.dismiss();
        working.update(kind: NotificationKind.done, title: 'Done');
        expect(state(), isEmpty);
      });
    });

    test('closing any other kind forgets it', () {
      final error = center().error('Failed', body: 'x');
      center().close(error.id);
      error.update(kind: NotificationKind.done, title: 'Done');
      expect(state(), isEmpty);
    });

    test('raised twice with the same words is two cards, each with its own handle', () {
      // Two downloads of one mod both read like this, and each owner still has a result to report.
      final first = center().working('Installing Ellen Swimsuit', body: 'Waiting for a free slot');
      final second = center().working('Installing Ellen Swimsuit', body: 'Waiting for a free slot');
      expect(state().map((n) => n.id), [first.id, second.id]);
    });
  });

  group('a deck', () {
    final deck = NotificationDeck('downloads', more: (count) => '$count more downloading');
    NotificationRepeat installed(String subject) => NotificationRepeat('install-done',
        subjects: [subject], title: (count) => '$count mods installed');

    test('keeps a card turned into Done, so the result is dealt on top', () {
      final working = center().working('Installing', body: 'A', deck: deck);
      working.update(kind: NotificationKind.done, title: 'Mod installed');
      expect(state().single.deck, deck);
    });

    for (final kind in [NotificationKind.error, NotificationKind.warning, NotificationKind.note, NotificationKind.needsYou]) {
      test('lets go of a card turned into a ${kind.name}, which is then a card of its own', () {
        final working = center().working('Installing', body: 'A', deck: deck);
        working.update(kind: kind, title: 'It went wrong');
        expect(state().single.deck, isNull);
      });
    }

    test('keeps a Done result that is counted on its card', () {
      final a = center().working('Installing', body: 'A', deck: deck);
      final b = center().working('Installing', body: 'B', deck: deck);
      a.update(kind: NotificationKind.done, title: 'Mod installed', repeat: installed('A'));
      b.update(kind: NotificationKind.done, title: 'Mod installed', repeat: installed('B'));
      expect(state().single.count, 2);
      expect(state().single.deck, deck);
    });
  });

  group('handles', () {
    test('update rewrites in place, keeping the id', () {
      final handle = center().working('Saving tag…', body: 'Ellen Swimsuit');
      handle.update(title: 'Still saving…');
      expect(state().single.id, handle.id);
      expect(state().single.title, 'Still saving…');
    });

    test('a handle to a card that is gone is a no-op, not an error', () {
      final handle = center().working('Working…', body: 'x');
      handle.dismiss();
      expect(handle.isVisible, isFalse);
      expect(() => handle.update(title: 'done'), returnsNormally);
      expect(() => handle.dismiss(), returnsNormally);
      expect(state(), isEmpty);
    });

    test('clear empties the stack', () {
      center().note('a', body: '1');
      center().note('b', body: '2');
      center().clear();
      expect(state(), isEmpty);
    });
  });

  group('the log', () {
    late _Capture sink;
    setUp(() {
      sink = _Capture();
      Log.install(LogRouter(sinks: [sink]));
    });
    tearDown(() => Log.install(LogRouter()));

    test('every raise and every merge logs once, with its kind', () {
      center().error('Failed', body: 'Ellen');
      center().done('Mod installed', body: 'A', repeat: const NotificationRepeat('install-done', subjects: ['A']));
      center().done('Mod installed', body: 'B', repeat: const NotificationRepeat('install-done', subjects: ['B']));
      final notified = sink.records.where((r) => r.message == 'notified').toList();
      expect(notified, hasLength(3));
      expect(notified.first.level, LogLevel.error);
      expect(notified.first.fields['kind'], 'error');
      expect(notified.last.fields['key'], 'install-done');
      expect(notified.last.fields['count'], 2);
    });

    test('a keycap body logs with the key in place', () {
      center().note('Ellen Swimsuit is on', body: 'Press {key} in game to load it.', keycap: 'F10');
      expect(sink.records.single.fields['body'], 'Press F10 in game to load it.');
    });
  });

  group('the accessors', () {
    testWidgets('context.notify and ref.notify are the same queue', (tester) async {
      late BuildContext captured;
      late WidgetRef capturedRef;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: Consumer(
            builder: (context, ref, _) {
              captured = context;
              capturedRef = ref;
              return const SizedBox();
            },
          ),
        ),
      );

      captured.notify.note('from a context', body: 'x');
      capturedRef.notify.note('from a ref', body: 'y');

      expect(state().map((n) => n.title), ['from a context', 'from a ref']);
    });
  });
}

class _Capture extends LogSink {
  final List<LogRecord> records = [];

  @override
  LogFormat get format => LogFormat.file;

  @override
  LogLevel get threshold => LogLevel.debug;

  @override
  void write(LogRecord record, String line) => records.add(record);
}
