import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/screens/components/character_avatar.dart';
import 'package:mod_manager_flutter/screens/components/notification_overlay.dart';
import 'package:mod_manager_flutter/utils/notifications.dart';

import 'support/localized_harness.dart';

/// The corner of the window notifications actually live in.
///
/// The queue itself is `notifications_test.dart`; everything here is what only
/// the widget can answer — that a card appears at all, that the newest is the
/// bottom one, that the close button works, that the auto-dismiss clock runs
/// *here* and stops while the pointer is over the card, and what the leading
/// slot renders.
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

  /// The bundled file a rendered portrait actually points at, or null when the
  /// slot rendered an icon instead.
  ///
  /// **Asserted through the `AssetImage`, never through pixels.** `Image.asset`
  /// resolves asynchronously and `pumpAndSettle` does not wait for real async
  /// I/O — the same trap `localized_harness.dart` documents for localizations.
  /// This assertion is synchronous, so it cannot pass vacuously.
  String? portraitAsset(WidgetTester tester) {
    final images = tester.widgetList<Image>(find.byType(Image));
    if (images.isEmpty) return null;
    return (images.first.image as AssetImage).assetName;
  }

  testWidgets('nothing is drawn while the queue is empty', (tester) async {
    await pumpOverlay(tester);
    expect(find.byType(NotificationOverlay), findsOneWidget);
    expect(find.byIcon(Icons.close_rounded), findsNothing);
  });

  testWidgets('both levels render', (tester) async {
    await pumpOverlay(tester);
    center().success('Mod installed', body: 'Ellen Swimsuit');
    await tester.pumpAndSettle();

    expect(find.text('Mod installed'), findsOneWidget);
    expect(find.text('Ellen Swimsuit'), findsOneWidget);
    expect(find.byIcon(Icons.close_rounded), findsOneWidget);
  });

  testWidgets('each severity brings its own icon', (tester) async {
    await pumpOverlay(tester);
    center().success('a', body: '1');
    center().warning('b', body: '2');
    center().error('c', body: '3');
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.check_circle_outline_rounded), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    expect(find.byIcon(Icons.error_outline_rounded), findsOneWidget);
  });

  testWidgets('an explicit icon overrides the severity default',
      (tester) async {
    await pumpOverlay(tester);
    center().success('Saved', body: 'x', icon: Icons.save_alt_rounded);
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.save_alt_rounded), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_outline_rounded), findsNothing);
  });

  group('the leading slot', () {
    testWidgets('a known character shows their portrait instead of the icon',
        (tester) async {
      await pumpOverlay(tester);
      center().success('Mod installed',
          body: 'Ellen Swimsuit', characterId: 'ellen');
      await tester.pumpAndSettle();

      expect(portraitAsset(tester), 'assets/characters/ellen.png');
      // The portrait *replaced* the severity glyph — that is the feature, not a
      // decoration added beside it.
      expect(find.byIcon(Icons.check_circle_outline_rounded), findsNothing);
      // A failed asset load throws into the error handler rather than the test.
      expect(tester.takeException(), isNull);
    });

    testWidgets("the roster's asset override survives", (tester) async {
      // The one thing a hand-built path silently loses, and the reason
      // `assetPathFor` exists at all.
      await pumpOverlay(tester);
      center().info('Mod enabled', body: 'Starlight Knight', characterId: 'billy');
      await tester.pumpAndSettle();

      expect(portraitAsset(tester), 'assets/characters/billy_herinkton.png');
    });

    for (final id in <String?>[null, '', 'unknown']) {
      testWidgets('an unassigned character (${id ?? 'null'}) falls back to the '
          'severity icon', (tester) async {
        await pumpOverlay(tester);
        center().info('Something happened', body: 'x', characterId: id);
        await tester.pumpAndSettle();

        expect(find.byIcon(Icons.info_outline_rounded), findsOneWidget);
        expect(find.byType(Image), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('a built-in category shows that category, not a portrait',
        (tester) async {
      // `getCharacterAssetName` falls back to the id, so without the roster
      // pre-check this would ask the bundle for `cat_ui.png` and hit
      // `errorBuilder` on every notification about a category-filed mod.
      await pumpOverlay(tester);
      center().info('Mod enabled', body: 'Dark HUD', characterId: 'cat_ui');
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.web_asset), findsOneWidget);
      expect(find.byType(Image), findsNothing);
      expect(find.byIcon(Icons.info_outline_rounded), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the ring carries the severity, and only on the portrait',
        (tester) async {
      await pumpOverlay(tester);
      center().error('Update failed', body: 'Ellen Swimsuit',
          characterId: 'ellen');
      await tester.pumpAndSettle();

      final avatar = tester.widget<CharacterAvatar>(
        find.byType(CharacterAvatar),
      );
      final scheme = Theme.of(tester.element(find.byType(CharacterAvatar)))
          .colorScheme;
      expect(avatar.ring?.color,
          notificationColor(scheme, NotificationSeverity.error));

      // The icon variant gets no ring — the tinted disc and the glyph already
      // carry the accent.
      center().clear();
      center().error('Update failed', body: 'no character here');
      await tester.pumpAndSettle();
      expect(find.byType(CharacterAvatar), findsNothing);
    });

    testWidgets('the slot is the same width whichever variant renders',
        (tester) async {
      // The regression guard for the fixed 40px footprint. Without it, a future
      // "the icon looks lonely, let's shrink the slot" reintroduces a ragged
      // left edge down the stack with no test failure.
      await pumpOverlay(tester);
      center().info('With a portrait', body: 'x', characterId: 'ellen');
      center().info('Without one', body: 'y');
      await tester.pumpAndSettle();

      expect(
        tester.getRect(find.text('With a portrait')).left,
        tester.getRect(find.text('Without one')).left,
      );
    });

    testWidgets('a portrait does not make the card taller', (tester) async {
      // Pins the arithmetic the 40px slot was chosen for: two lines of card
      // text come to 41px, so the avatar never drives the card's height.
      await pumpOverlay(tester);
      center().info('A headline', body: 'a subject');
      await tester.pumpAndSettle();
      final withoutPortrait =
          tester.getRect(find.byType(NotificationOverlay)).height;

      center().clear();
      await tester.pumpAndSettle();
      center().info('A headline', body: 'a subject', characterId: 'ellen');
      await tester.pumpAndSettle();

      expect(
        tester.getRect(find.byType(NotificationOverlay)).height,
        withoutPortrait,
      );
    });
  });

  testWidgets('they stack upwards — the newest is the lowest', (tester) async {
    await pumpOverlay(tester);
    center().info('older', body: '1');
    center().info('newer', body: '2');
    await tester.pumpAndSettle();

    expect(
      tester.getCenter(find.text('newer')).dy,
      greaterThan(tester.getCenter(find.text('older')).dy),
    );
  });

  testWidgets('they sit in the bottom-right corner', (tester) async {
    await pumpOverlay(tester);
    center().info('corner', body: 'x');
    await tester.pumpAndSettle();

    final card = tester.getRect(find.text('corner'));
    expect(card.right, greaterThan(1200 * 0.6));
    expect(card.bottom, greaterThan(800 * 0.8));
  });

  testWidgets('the close button dismisses that one and only that one',
      (tester) async {
    await pumpOverlay(tester);
    center().pinned('first', body: '1');
    center().pinned('second', body: '2');
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.close_rounded).first);
    await tester.pumpAndSettle();

    expect(find.text('first'), findsNothing);
    expect(find.text('second'), findsOneWidget);
    expect(container.read(notificationsProvider).single.title, 'second');
  });

  group('the clock', () {
    testWidgets('dismisses a notification once its duration is up',
        (tester) async {
      await pumpOverlay(tester);
      center().info('temporary',
          body: 'x', duration: const Duration(seconds: 3));
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
      final handle =
          center().pinned('Scanning the library…', body: 'your mods');
      await tester.pumpAndSettle();

      await tester.pump(const Duration(minutes: 5));
      await tester.pumpAndSettle();
      expect(find.text('Scanning the library…'), findsOneWidget);

      handle.update(
        title: 'Library scanned',
        severity: NotificationSeverity.success,
      );
      await tester.pumpAndSettle();
      expect(find.text('Library scanned'), findsOneWidget);
      expect(find.text('your mods'), findsOneWidget,
          reason: 'the body is the stable subject and carries over');

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
          body: 'x', duration: const Duration(seconds: 4));
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
      center().info('read me first',
          body: '1', duration: const Duration(seconds: 4));
      center().info('read me second',
          body: '2', duration: const Duration(seconds: 4));
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
      center().pinned('something to hover', body: 'x');
      await tester.pumpAndSettle();

      final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await pointer.addPointer(
        location: tester.getCenter(find.text('something to hover')),
      );
      addTearDown(pointer.removePointer);
      await tester.pump();

      center().info('arrived late',
          body: 'y', duration: const Duration(seconds: 4));
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
      center().info('nearly expired',
          body: 'x', duration: const Duration(seconds: 4));
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
    // overflowing into a debug stripe. The 40px leading slot narrows the text
    // column, so this wraps harder than it looks.
    await pumpOverlay(tester, surfaceSize: const Size(800, 600));
    for (var i = 0; i < kMaxVisibleNotifications; i++) {
      center().pinned(
        'A headline for notification number $i',
        body: 'A genuinely long body, of the kind an install produces when it '
            'has something to say about several mods at once — number $i.',
        characterId: 'ellen',
      );
    }
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(SingleChildScrollView), findsWidgets);
  });
}
