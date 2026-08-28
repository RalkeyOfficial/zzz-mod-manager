import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/utils/notifications.dart';

/// The notification queue — the list half, with no widgets and no clock.
///
/// The clock deliberately lives in the card (see `notification_overlay.dart`),
/// which is what lets everything here be asserted as a plain list operation.
void main() {
  late ProviderContainer container;
  NotificationCenter center() =>
      container.read(notificationsProvider.notifier);
  List<AppNotification> state() => container.read(notificationsProvider);

  setUp(() {
    container = ProviderContainer();
  });

  tearDown(() => container.dispose());

  test('starts empty', () {
    expect(state(), isEmpty);
  });

  test('newest goes last, which is what puts it at the bottom of the stack',
      () {
    center().info('first', body: 'a');
    center().info('second', body: 'b');
    expect(state().map((n) => n.title), ['first', 'second']);
  });

  test('each severity gets its own default duration', () {
    center().success('a', body: 'x');
    center().error('b', body: 'y');
    expect(state().first.duration,
        kNotificationDurations[NotificationSeverity.success]);
    expect(state().last.duration,
        kNotificationDurations[NotificationSeverity.error]);
  });

  test('an explicit duration wins over the default', () {
    center().info('a', body: 'x', duration: const Duration(seconds: 30));
    expect(state().single.duration, const Duration(seconds: 30));
  });

  test('an icon and a character both claim the leading slot, so both is a bug',
      () {
    // Caught in development rather than resolved silently — the icon would win
    // and the portrait would vanish with nothing to explain it.
    expect(
      () => center().success('Saved',
          body: 'Ellen Swimsuit',
          characterId: 'ellen',
          icon: Icons.save_alt_rounded),
      throwsAssertionError,
    );
  });

  group('the cap', () {
    test('keeps the newest and drops the oldest', () {
      // A burst is nearly always one action reporting several things, and the
      // last line is the one that concludes it.
      for (var i = 1; i <= kMaxVisibleNotifications + 2; i++) {
        center().info('message $i', body: 'body $i');
      }
      expect(state(), hasLength(kMaxVisibleNotifications));
      expect(state().first.title, 'message 3');
      expect(state().last.title, 'message ${kMaxVisibleNotifications + 2}');
    });
  });

  group('re-raising the same message', () {
    test('moves it to the bottom instead of stacking a copy', () {
      // Eight files failing the same way would otherwise fill the cap with one
      // repeated sentence.
      center().success('Saved', body: 'Ellen Swimsuit');
      center().info('something else', body: 'x');
      center().success('Saved', body: 'Ellen Swimsuit');

      expect(state().map((n) => n.title), ['something else', 'Saved']);
    });

    test('gets a new id, so its card re-enters and its clock restarts', () {
      final first = center().success('Saved', body: 'Ellen Swimsuit');
      final second = center().success('Saved', body: 'Ellen Swimsuit');
      expect(second.id, isNot(first.id));
      expect(first.isVisible, isFalse);
      expect(second.isVisible, isTrue);
    });

    test('is scoped to the same severity, title and body', () {
      center().success('Done', body: 'x');
      center().error('Done', body: 'x');
      center().success('Done', body: 'a different subject');
      expect(state(), hasLength(3));
    });

    test('a differing portrait alone does not stack a second copy', () {
      // The picture is not part of what a notification *says*. Two identical
      // sentences about different characters — re-filing one mod twice in quick
      // succession — collapse, and the survivor carries the current face rather
      // than the stale one.
      center().warning('Tag not saved', body: 'the folder may be read-only',
          characterId: 'ellen');
      center().warning('Tag not saved', body: 'the folder may be read-only',
          characterId: 'nicole');

      expect(state(), hasLength(1));
      expect(state().single.characterId, 'nicole');
    });
  });

  group('pinned', () {
    test('has no duration, so nothing on screen will time it out', () {
      final handle = center().pinned('Scanning…', body: 'your library');
      expect(state().single.duration, isNull);
      expect(state().single.isPinned, isTrue);
      expect(handle.isVisible, isTrue);
    });

    test('an update can give it an ending, and the body stays put', () {
      // The shape the whole feature exists for: the body is the stable subject
      // and the title is the changing verb, so finishing the work rewrites one
      // level and leaves the other alone.
      final handle = center().pinned('Saving tag…', body: 'Ellen Swimsuit');
      handle.update(
        title: 'Tag saved',
        severity: NotificationSeverity.success,
      );

      final updated = state().single;
      expect(updated.title, 'Tag saved');
      expect(updated.body, 'Ellen Swimsuit');
      expect(updated.severity, NotificationSeverity.success);
      expect(updated.duration,
          kNotificationDurations[NotificationSeverity.success],
          reason: 'a severity change re-clocks it to that severity default');
    });

    test('`pin` on an update takes the clock back off', () {
      final handle = center().success('done', body: 'x');
      handle.update(title: 'actually still working', pin: true);
      expect(state().single.duration, isNull);
    });

    test('an update keeps the id, so the card is not replaced', () {
      final handle = center().pinned('Working…', body: 'x');
      final id = state().single.id;
      handle.update(title: 'Still working…');
      expect(state().single.id, id);
    });
  });

  group('dismissing', () {
    test('removes exactly one', () {
      center().info('a', body: '1');
      final b = center().info('b', body: '2');
      center().info('c', body: '3');
      b.dismiss();
      expect(state().map((n) => n.title), ['a', 'c']);
    });

    test('a handle to something already gone is inert, never a throw', () {
      // The user can close any notification by hand at any moment, so every
      // caller holding a handle is holding one that may have expired.
      final handle = center().pinned('Working…', body: 'x');
      center().clear();

      expect(handle.isVisible, isFalse);
      expect(() => handle.update(title: 'done'), returnsNormally);
      expect(() => handle.dismiss(), returnsNormally);
      expect(state(), isEmpty);
    });

    test('clear empties the stack', () {
      center().info('a', body: '1');
      center().info('b', body: '2');
      center().clear();
      expect(state(), isEmpty);
    });
  });

  group('the accessors', () {
    testWidgets('context.notify and ref.notify are the same queue',
        (tester) async {
      // Two entry points, deliberately — a dialog helper has only a context,
      // a ConsumerState has a ref — but they must not be two queues.
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

      captured.notify.info('from a context', body: 'x');
      capturedRef.notify.info('from a ref', body: 'y');

      expect(state().map((n) => n.title), ['from a context', 'from a ref']);
    });
  });
}
