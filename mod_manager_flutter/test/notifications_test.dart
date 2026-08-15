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
    center().info('first');
    center().info('second');
    expect(state().map((n) => n.message), ['first', 'second']);
  });

  test('each severity gets its own default duration', () {
    center().success('a');
    center().error('b');
    expect(state().first.duration,
        kNotificationDurations[NotificationSeverity.success]);
    expect(state().last.duration,
        kNotificationDurations[NotificationSeverity.error]);
  });

  test('an explicit duration wins over the default', () {
    center().info('a', duration: const Duration(seconds: 30));
    expect(state().single.duration, const Duration(seconds: 30));
  });

  group('the cap', () {
    test('keeps the newest and drops the oldest', () {
      // A burst is nearly always one action reporting several things, and the
      // last line is the one that concludes it.
      for (var i = 1; i <= kMaxVisibleNotifications + 2; i++) {
        center().info('message $i');
      }
      expect(state(), hasLength(kMaxVisibleNotifications));
      expect(state().first.message, 'message 3');
      expect(state().last.message, 'message ${kMaxVisibleNotifications + 2}');
    });
  });

  group('re-raising the same message', () {
    test('moves it to the bottom instead of stacking a copy', () {
      // Toggling a mod twice, or eight files failing the same way, would
      // otherwise fill the cap with one repeated sentence.
      center().success('Activated');
      center().info('something else');
      center().success('Activated');

      expect(state().map((n) => n.message), ['something else', 'Activated']);
    });

    test('gets a new id, so its card re-enters and its clock restarts', () {
      final first = center().success('Activated');
      final second = center().success('Activated');
      expect(second.id, isNot(first.id));
      expect(first.isVisible, isFalse);
      expect(second.isVisible, isTrue);
    });

    test('is scoped to the same severity and title', () {
      center().success('Done');
      center().error('Done');
      center().success('Done', title: 'Import');
      expect(state(), hasLength(3));
    });
  });

  group('pinned', () {
    test('has no duration, so nothing on screen will time it out', () {
      final handle = center().pinned('Scanning…');
      expect(state().single.duration, isNull);
      expect(state().single.isPinned, isTrue);
      expect(handle.isVisible, isTrue);
    });

    test('an update can give it an ending', () {
      // The shape the whole feature exists for: raise it pinned while the work
      // runs, then let the result dismiss itself.
      final handle = center().pinned('Scanning…');
      handle.update(
        message: 'Library scanned',
        severity: NotificationSeverity.success,
      );

      final updated = state().single;
      expect(updated.message, 'Library scanned');
      expect(updated.severity, NotificationSeverity.success);
      expect(updated.duration,
          kNotificationDurations[NotificationSeverity.success],
          reason: 'a severity change re-clocks it to that severity default');
    });

    test('`pin` on an update takes the clock back off', () {
      final handle = center().success('done');
      handle.update(message: 'actually still working', pin: true);
      expect(state().single.duration, isNull);
    });

    test('an update keeps the id, so the card is not replaced', () {
      final handle = center().pinned('Working…');
      final id = state().single.id;
      handle.update(message: 'Still working…');
      expect(state().single.id, id);
    });
  });

  group('dismissing', () {
    test('removes exactly one', () {
      center().info('a');
      final b = center().info('b');
      center().info('c');
      b.dismiss();
      expect(state().map((n) => n.message), ['a', 'c']);
    });

    test('a handle to something already gone is inert, never a throw', () {
      // The user can close any notification by hand at any moment, so every
      // caller holding a handle is holding one that may have expired.
      final handle = center().pinned('Working…');
      center().clear();

      expect(handle.isVisible, isFalse);
      expect(() => handle.update(message: 'done'), returnsNormally);
      expect(() => handle.dismiss(), returnsNormally);
      expect(state(), isEmpty);
    });

    test('clear empties the stack', () {
      center().info('a');
      center().info('b');
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

      captured.notify.info('from a context');
      capturedRef.notify.info('from a ref');

      expect(state().map((n) => n.message),
          ['from a context', 'from a ref']);
    });
  });
}
