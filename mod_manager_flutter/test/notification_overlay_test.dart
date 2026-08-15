import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/screens/components/notification_overlay.dart';
import 'package:mod_manager_flutter/utils/notifications.dart';

import 'support/localized_harness.dart';

/// The corner of the window notifications actually live in.
///
/// The queue itself is `notifications_test.dart`; everything here is what only
/// the widget can answer — that a card appears at all, that the newest is the
/// bottom one, that the close button works, and that the auto-dismiss clock
/// runs *here* and stops while the pointer is over the card.
void main() {
  late ProviderContainer container;
  NotificationCenter center() =>
      container.read(notificationsProvider.notifier);

  setUp(() => container = ProviderContainer());
  tearDown(() => container.dispose());

  /// The overlay, mounted the way `main.dart` mounts it — above the app's own
  /// content rather than inside it.
  Future<void> pumpOverlay(
    WidgetTester tester, {
    Size surfaceSize = const Size(1200, 800),
  }) async {
    await pumpLocalized(
      tester,
      const Center(child: Text('app content')),
      container: container,
      surfaceSize: surfaceSize,
    );
    expectBuilt(NotificationHost);
  }

  testWidgets('nothing is drawn while the queue is empty', (tester) async {
    await pumpOverlay(tester);
    expect(find.byType(NotificationOverlay), findsOneWidget);
    expect(find.byIcon(Icons.close_rounded), findsNothing);
  });

  testWidgets('a message and its title both render', (tester) async {
    await pumpOverlay(tester);
    center().success('Auto-tags: Ellen Swim → ellen', title: 'Imported 1 mod');
    await tester.pumpAndSettle();

    expect(find.text('Imported 1 mod'), findsOneWidget);
    expect(find.text('Auto-tags: Ellen Swim → ellen'), findsOneWidget);
    // The old install flow said these two things as two bars, the second
    // replacing the first. One card, both facts.
    expect(find.byIcon(Icons.close_rounded), findsOneWidget);
  });

  testWidgets('each severity brings its own icon', (tester) async {
    await pumpOverlay(tester);
    center().success('a');
    center().warning('b');
    center().error('c');
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.check_circle_outline_rounded), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    expect(find.byIcon(Icons.error_outline_rounded), findsOneWidget);
  });

  testWidgets('an explicit icon overrides the severity default',
      (tester) async {
    await pumpOverlay(tester);
    center().success('Saved', icon: Icons.save_alt_rounded);
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.save_alt_rounded), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_outline_rounded), findsNothing);
  });

  testWidgets('they stack upwards — the newest is the lowest', (tester) async {
    await pumpOverlay(tester);
    center().info('older');
    center().info('newer');
    await tester.pumpAndSettle();

    expect(
      tester.getCenter(find.text('newer')).dy,
      greaterThan(tester.getCenter(find.text('older')).dy),
    );
  });

  testWidgets('they sit in the bottom-right corner', (tester) async {
    await pumpOverlay(tester);
    center().info('corner');
    await tester.pumpAndSettle();

    final card = tester.getRect(find.text('corner'));
    expect(card.right, greaterThan(1200 * 0.6));
    expect(card.bottom, greaterThan(800 * 0.8));
  });

  testWidgets('the close button dismisses that one and only that one',
      (tester) async {
    await pumpOverlay(tester);
    center().pinned('first');
    center().pinned('second');
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.close_rounded).first);
    await tester.pumpAndSettle();

    expect(find.text('first'), findsNothing);
    expect(find.text('second'), findsOneWidget);
    expect(container.read(notificationsProvider).single.message, 'second');
  });

  group('the clock', () {
    testWidgets('dismisses a notification once its duration is up',
        (tester) async {
      await pumpOverlay(tester);
      center().info('temporary', duration: const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.text('temporary'), findsOneWidget);

      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();

      expect(find.text('temporary'), findsNothing);
      expect(container.read(notificationsProvider), isEmpty);
    });

    testWidgets('a pinned notification stays until something dismisses it',
        (tester) async {
      // The point of pinning: it ends on a condition, not on a clock.
      await pumpOverlay(tester);
      final handle = center().pinned('Scanning the library…');
      await tester.pumpAndSettle();

      await tester.pump(const Duration(minutes: 5));
      await tester.pumpAndSettle();
      expect(find.text('Scanning the library…'), findsOneWidget);

      handle.update(
        message: 'Library scanned',
        severity: NotificationSeverity.success,
      );
      await tester.pumpAndSettle();
      expect(find.text('Library scanned'), findsOneWidget);

      // …and the update it was given *does* have a clock.
      await tester.pump(kNotificationDurations[NotificationSeverity.success]!);
      await tester.pumpAndSettle();
      expect(find.text('Library scanned'), findsNothing);
    });

    testWidgets('hovering pauses it, and leaving starts it again',
        (tester) async {
      // The complaint the whole rework answers: a message that vanishes while
      // it is being read.
      await pumpOverlay(tester);
      center().error('a long error worth reading',
          duration: const Duration(seconds: 4));
      await tester.pumpAndSettle();

      final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await pointer.addPointer(
        location: tester.getCenter(find.text('a long error worth reading')),
      );
      addTearDown(pointer.removePointer);
      await tester.pump();

      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
      expect(find.text('a long error worth reading'), findsOneWidget,
          reason: 'the pointer is still on it');

      await pointer.moveTo(const Offset(10, 10));
      await tester.pump();
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(find.text('a long error worth reading'), findsNothing);
    });

    testWidgets('hovering one notification holds every one of them',
        (tester) async {
      // Reading is reading. Someone resting the pointer on the first card is
      // still working down the stack, and letting the others expire underneath
      // them would also reflow the stack out from under the pointer.
      await pumpOverlay(tester);
      center().info('read me first', duration: const Duration(seconds: 4));
      center().info('read me second', duration: const Duration(seconds: 4));
      await tester.pumpAndSettle();

      final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await pointer.addPointer(
        location: tester.getCenter(find.text('read me first')),
      );
      addTearDown(pointer.removePointer);
      await tester.pump();

      await tester.pump(const Duration(seconds: 20));
      await tester.pumpAndSettle();
      expect(find.text('read me first'), findsOneWidget);
      expect(find.text('read me second'), findsOneWidget,
          reason: 'the pointer is on the other card, not this one');

      await pointer.moveTo(const Offset(10, 10));
      await tester.pump();
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(container.read(notificationsProvider), isEmpty);
    });

    testWidgets('one raised while the pointer is on the stack arrives held',
        (tester) async {
      // Otherwise a burst that lands during a read ticks away under a reader
      // who never moved.
      await pumpOverlay(tester);
      center().pinned('something to hover');
      await tester.pumpAndSettle();

      final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await pointer.addPointer(
        location: tester.getCenter(find.text('something to hover')),
      );
      addTearDown(pointer.removePointer);
      await tester.pump();

      center().info('arrived late', duration: const Duration(seconds: 4));
      await tester.pumpAndSettle();

      await tester.pump(const Duration(seconds: 20));
      await tester.pumpAndSettle();
      expect(find.text('arrived late'), findsOneWidget);

      await pointer.moveTo(const Offset(10, 10));
      await tester.pump();
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(find.text('arrived late'), findsNothing);
      expect(find.text('something to hover'), findsOneWidget,
          reason: 'pinned, so leaving gives it no clock either');
    });

    testWidgets('leaving restarts the full duration rather than resuming',
        (tester) async {
      await pumpOverlay(tester);
      center().info('nearly expired', duration: const Duration(seconds: 4));
      await tester.pumpAndSettle();

      // Three of its four seconds gone before the pointer arrives.
      await tester.pump(const Duration(seconds: 3));

      final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await pointer.addPointer(
        location: tester.getCenter(find.text('nearly expired')),
      );
      addTearDown(pointer.removePointer);
      await tester.pump();
      await pointer.moveTo(const Offset(10, 10));
      await tester.pump();

      // The second it had left is not what it gets back.
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.text('nearly expired'), findsOneWidget);

      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.text('nearly expired'), findsNothing);
    });
  });

  testWidgets('the stack stays inside a short window', (tester) async {
    // 800x600 is the app's minimum window size, and four cards of a paragraph
    // each is more than it has to give — so the column scrolls rather than
    // overflowing into a debug stripe.
    await pumpOverlay(tester, surfaceSize: const Size(800, 600));
    for (var i = 0; i < kMaxVisibleNotifications; i++) {
      center().pinned(
        'A notification with a genuinely long message, of the kind an import '
        'summary produces when it has several things to say about several '
        'mods at once — number $i.',
      );
    }
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(SingleChildScrollView), findsWidgets);
  });
}
