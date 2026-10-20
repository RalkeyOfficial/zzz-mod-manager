import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/core/palette.dart';
import 'package:mod_manager_flutter/screens/components/character_tile.dart';
import 'package:mod_manager_flutter/screens/components/notification_overlay.dart';
import 'package:mod_manager_flutter/screens/shell/keycap.dart';
import 'package:mod_manager_flutter/screens/shell/status_bar.dart';
import 'package:mod_manager_flutter/utils/notifications.dart';

import 'support/localized_harness.dart';

/// The corner of the window notifications live in.
///
/// The queue itself is `notifications_test.dart`; everything here is what only the widget can answer: how a card
/// looks for each kind, where the stack sits, the fold, the actions, and the clock that runs *here* and stops while
/// the pointer is over the stack.
///
/// A Working card's spinner and sweep repeat forever, so a test that shows one pumps fixed durations rather than
/// settling.
void main() {
  late ProviderContainer container;
  NotificationCenter center() => container.read(notificationsProvider.notifier);
  final palette = ZenithPalette.dark(AccentChoice.violet);

  setUp(() => container = ProviderContainer());
  tearDown(() => container.dispose());

  /// The overlay, mounted the way `main.dart` mounts it: above the app's own content rather than inside it.
  Future<void> pumpOverlay(
    WidgetTester tester, {
    Size surfaceSize = const Size(1200, 800),
    Brightness brightness = Brightness.dark,
  }) async {
    await pumpLocalized(tester, const Center(child: Text('app content')),
        container: container, surfaceSize: surfaceSize, brightness: brightness);
    expectBuilt(NotificationHost);
  }

  /// Lets a card in without settling, for a stack that holds a spinner or a sweep.
  Future<void> pumpIn(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// The bundled file a rendered portrait points at, or null when the slot rendered an icon. Asserted through the
  /// `AssetImage`, never through pixels, which resolve asynchronously.
  String? portraitAsset(WidgetTester tester) {
    final images = tester.widgetList<Image>(find.byType(Image));
    if (images.isEmpty) return null;
    return (images.first.image as AssetImage).assetName;
  }

  BoxDecoration decorationOf(WidgetTester tester, Finder finder) =>
      tester.widget<Container>(finder).decoration! as BoxDecoration;

  /// The colour the spinner's arc is painted in. Its painter is private, so it is read dynamically.
  Color arcColour(WidgetTester tester, Finder spinner) {
    final paint = tester.widget<CustomPaint>(find.descendant(of: spinner, matching: find.byType(CustomPaint)).first);
    return (paint.painter! as dynamic).color as Color;
  }

  Finder card(String title) => find.ancestor(of: find.text(title), matching: find.byKey(const ValueKey('notification-card')));

  testWidgets('nothing is drawn while the queue is empty', (tester) async {
    await pumpOverlay(tester);
    expect(find.byType(NotificationOverlay), findsOneWidget);
    expect(find.byIcon(Icons.close_rounded), findsNothing);
  });

  group('the card', () {
    testWidgets('is 380 wide on the notification ground, with both levels in their roles', (tester) async {
      await pumpOverlay(tester);
      center().done('Mod installed', body: 'Ellen Swimsuit');
      await tester.pumpAndSettle();

      expect(tester.getSize(card('Mod installed')).width, 380);
      final decoration = decorationOf(tester, card('Mod installed'));
      expect(decoration.color, palette.notification.background);
      expect(decoration.borderRadius, BorderRadius.circular(12));
      expect((decoration.border! as Border).top.color, palette.notification.border);

      final theme = Theme.of(tester.element(find.text('Mod installed')));
      final title = tester.widget<Text>(find.text('Mod installed')).style!;
      expect(title.fontSize, theme.textTheme.bodyMedium!.fontSize);
      expect(title.fontWeight, FontWeight.w600);
      expect(title.color, palette.text);
      final body = tester.widget<Text>(find.text('Ellen Swimsuit')).style!;
      expect(body.fontSize, theme.textTheme.bodySmall!.fontSize);
      expect(body.color, palette.text2);
      await tester.pump(const Duration(seconds: 6));
    });

    testWidgets('an error card has its own ground', (tester) async {
      await pumpOverlay(tester);
      center().error('Couldn\'t turn on', body: 'Lab Coat');
      await tester.pumpAndSettle();

      final decoration = decorationOf(tester, card('Couldn\'t turn on'));
      expect(decoration.color, palette.notificationError.background);
      expect((decoration.border! as Border).top.color, palette.notificationError.border);
    });

    // Pinned to the palette's tokens, so a wrong mapping in `notificationLook` fails here.
    final tiles = <NotificationKind, (Color, Color, IconData)>{
      NotificationKind.done: (palette.notificationDoneTile.background, palette.accent, Icons.check_rounded),
      NotificationKind.note: (palette.hover, palette.textProse, Icons.info_outline_rounded),
      NotificationKind.update: (palette.badgeUpdate.background, palette.badgeUpdate.foreground, Icons.arrow_circle_up_outlined),
      NotificationKind.needsYou: (palette.badgeInfo.background, palette.badgeInfo.foreground, Icons.download_rounded),
      NotificationKind.warning: (palette.badgeUpdate.background, palette.badgeUpdate.foreground, Icons.warning_amber_rounded),
      NotificationKind.error: (palette.badgeMissing.background, palette.badgeMissing.foreground, Icons.highlight_off_rounded),
    };
    for (final MapEntry(key: kind, value: (ground, ink, glyph)) in tiles.entries) {
      testWidgets('a ${kind.name} card draws its own tile and icon', (tester) async {
        await pumpOverlay(tester);
        center().show(kind, 'A ${kind.name}', body: 'x');
        await tester.pumpAndSettle();

        final tile = find.byKey(const ValueKey('notification-tile'));
        expect(decorationOf(tester, tile).color, ground);
        final icon = tester.widget<Icon>(find.descendant(of: tile, matching: find.byType(Icon)));
        expect(icon.icon, glyph);
        expect(icon.color, ink);
        center().clear();
        await tester.pumpAndSettle();
      });
    }

    testWidgets('a Working card draws its spinner on the hover tile', (tester) async {
      await pumpOverlay(tester);
      center().working('Installing', body: 'x');
      await pumpIn(tester);

      final tile = find.byKey(const ValueKey('notification-tile'));
      expect(decorationOf(tester, tile).color, palette.hover);
      final spinner = find.descendant(of: tile, matching: find.byKey(const ValueKey('notification-spinner')));
      expect(spinner, findsOneWidget);
      expect(arcColour(tester, spinner), palette.textProse);
      center().clear();
      await pumpIn(tester);
    });

    testWidgets('on paper, the cards take the paper tokens', (tester) async {
      final paper = ZenithPalette.light(AccentChoice.violet);
      await pumpOverlay(tester, brightness: Brightness.light);
      center().done('Mod installed', body: 'Ellen Swimsuit', characterId: 'ellen');
      center().error('Couldn\'t turn on', body: 'Lab Coat');
      await tester.pumpAndSettle();

      expect(decorationOf(tester, card('Mod installed')).color, paper.notification.background);
      expect(decorationOf(tester, card('Couldn\'t turn on')).color, paper.notificationError.background);
      expect(decorationOf(tester, card('Mod installed')).boxShadow!.single.color, paper.notificationShadow);
      expect(decorationOf(tester, find.byKey(const ValueKey('notification-badge'))).color, paper.accent);
      expect(decorationOf(tester, find.byKey(const ValueKey('notification-tile'))).color, paper.badgeMissing.background);
      expect(tester.widget<Text>(find.text('Mod installed')).style!.color, paper.text);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 6));
    });

    testWidgets('an explicit icon keeps the kind\'s colours', (tester) async {
      await pumpOverlay(tester);
      center().done('Saved', body: 'x', icon: Icons.save_alt_rounded);
      await tester.pumpAndSettle();

      final icon = tester.widget<Icon>(find.byIcon(Icons.save_alt_rounded));
      expect(icon.color, palette.notificationDoneTile.foreground);
      expect(find.byIcon(Icons.check_rounded), findsNothing);
      await tester.pump(const Duration(seconds: 6));
    });

    testWidgets('close is labelled Close, and Hide on a Working card', (tester) async {
      await pumpOverlay(tester);
      center().error('Failed', body: 'x');
      center().working('Installing', body: 'y');
      await pumpIn(tester);

      final labels = tester.widgetList<Icon>(find.byIcon(Icons.close_rounded)).map((i) => i.semanticLabel);
      expect(labels, ['Close', 'Hide']);
      center().clear();
      await pumpIn(tester);
    });
  });

  group('the leading slot', () {
    testWidgets('a character draws a 32px portrait tile with the kind as a badge', (tester) async {
      await pumpOverlay(tester);
      center().done('Mod installed', body: 'Ellen Swimsuit', characterId: 'ellen');
      await tester.pumpAndSettle();

      expect(portraitAsset(tester), 'assets/characters/ellen.png');
      expect(tester.widget<CharacterTile>(find.byType(CharacterTile)).size, 32);
      final badge = find.byKey(const ValueKey('notification-badge'));
      expect(decorationOf(tester, badge).color, palette.accent);
      expect(tester.widget<Icon>(find.descendant(of: badge, matching: find.byType(Icon))).icon, Icons.check_rounded);
      expect(find.byKey(const ValueKey('notification-tile')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 6));
    });

    final badges = <NotificationKind, (Color, Color, IconData)>{
      NotificationKind.error: (palette.red, palette.onRed, Icons.close_rounded),
      NotificationKind.update: (palette.amber, palette.onAccent, Icons.arrow_upward_rounded),
      NotificationKind.warning: (palette.amber, palette.onAccent, Icons.priority_high_rounded),
      NotificationKind.needsYou: (palette.blue, palette.onAccent, Icons.arrow_downward_rounded),
    };
    for (final MapEntry(key: kind, value: (fill, ink, glyph)) in badges.entries) {
      testWidgets('a ${kind.name} portrait carries its badge', (tester) async {
        await pumpOverlay(tester);
        center().show(kind, 'About Ellen', body: 'x', characterId: 'ellen');
        await tester.pumpAndSettle();

        final badge = find.byKey(const ValueKey('notification-badge'));
        expect(decorationOf(tester, badge).color, fill);
        final icon = tester.widget<Icon>(find.descendant(of: badge, matching: find.byType(Icon)));
        expect(icon.icon, glyph);
        expect(icon.color, ink);
        expect(icon.size, 10);
        // 18px across with its ring: a 14px fill.
        expect(tester.getSize(badge), const Size.square(14));
        center().clear();
        await tester.pumpAndSettle();
      });
    }

    testWidgets('a Working portrait carries the spinner as its badge', (tester) async {
      await pumpOverlay(tester);
      center().working('Installing', body: 'Ellen Swimsuit', characterId: 'ellen');
      await pumpIn(tester);

      final badge = find.byKey(const ValueKey('notification-badge'));
      final spinner = find.descendant(of: badge, matching: find.byKey(const ValueKey('notification-spinner')));
      expect(spinner, findsOneWidget);
      expect(decorationOf(tester, badge).color, palette.line);
      expect(arcColour(tester, spinner), palette.text);
      center().clear();
      await pumpIn(tester);
    });

    testWidgets('a Note portrait has no badge', (tester) async {
      await pumpOverlay(tester);
      center().note('Ellen Swimsuit is on', body: 'x', characterId: 'ellen');
      await tester.pumpAndSettle();

      expect(portraitAsset(tester), 'assets/characters/ellen.png');
      expect(find.byKey(const ValueKey('notification-badge')), findsNothing);
      await tester.pump(const Duration(seconds: 6));
    });

    testWidgets("the roster's asset override survives", (tester) async {
      await pumpOverlay(tester);
      center().note('Mod enabled', body: 'Starlight Knight', characterId: 'billy');
      await tester.pumpAndSettle();

      expect(portraitAsset(tester), 'assets/characters/billy_herinkton.png');
      await tester.pump(const Duration(seconds: 6));
    });

    for (final id in <String?>[null, '', 'unknown', 'cat_ui', 'not-a-character']) {
      testWidgets('${id ?? 'no character'} draws the kind\'s plain icon', (tester) async {
        await pumpOverlay(tester);
        center().error('Something happened', body: 'x', characterId: id);
        await tester.pumpAndSettle();

        expect(find.byKey(const ValueKey('notification-tile')), findsOneWidget);
        expect(find.byIcon(Icons.highlight_off_rounded), findsOneWidget);
        expect(find.byType(Image), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('a card counting several mods draws the plain icon', (tester) async {
      await pumpOverlay(tester);
      const repeat = NotificationRepeat('install-done', subjects: ['A']);
      center().done('Mod installed', body: 'A', characterId: 'ellen', repeat: repeat);
      center().done('Mod installed', body: 'B', characterId: 'ellen',
          repeat: const NotificationRepeat('install-done', subjects: ['B']));
      await tester.pumpAndSettle();

      expect(find.byType(Image), findsNothing);
      expect(find.byKey(const ValueKey('notification-tile')), findsOneWidget);
      expect(find.text('A and B'), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
    });
  });

  group('a Working card', () {
    testWidgets('draws its bar at the share of the work done', (tester) async {
      await pumpOverlay(tester);
      final handle = center().working('Downloading', body: 'x', progress: 0.25);
      await pumpIn(tester);

      final bar = find.byKey(const ValueKey('notification-progress'));
      expect(tester.widget<AnimatedFractionallySizedBox>(bar).widthFactor, 0.25);
      handle.update(progress: 0.75);
      await pumpIn(tester);
      expect(tester.widget<AnimatedFractionallySizedBox>(bar).widthFactor, 0.75);
      expect(find.byKey(const ValueKey('notification-sweep')), findsNothing);
      center().clear();
      await pumpIn(tester);
    });

    testWidgets('of unknown size draws the sweep', (tester) async {
      await pumpOverlay(tester);
      center().working('Downloading', body: 'x');
      await pumpIn(tester);

      expect(find.byKey(const ValueKey('notification-sweep')), findsOneWidget);
      expect(find.byKey(const ValueKey('notification-progress')), findsNothing);
      center().clear();
      await pumpIn(tester);
    });

    testWidgets('holds still under reduced motion', (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      await pumpOverlay(tester);
      center().working('Installing', body: 'x');
      // Nothing repeats, so the stack settles.
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('notification-sweep')), findsOneWidget);
      expect(find.byKey(const ValueKey('notification-spinner')), findsOneWidget);
    });
  });

  group('actions', () {
    testWidgets('the first is primary on every kind but a Note', (tester) async {
      await pumpOverlay(tester);
      void noop() {}
      center().updateAvailable('3 newer files', body: 'x',
          actions: [NotificationAction('Review', noop), NotificationAction('Later', noop)]);
      await tester.pumpAndSettle();

      Color? colourOf(String label) => DefaultTextStyle.of(tester.element(find.text(label))).style.color;
      expect(colourOf('Review'), palette.link);
      expect(colourOf('Later'), palette.text);
      await tester.pump(const Duration(seconds: 9));
    });

    testWidgets('pressing one runs it and closes the card; closes: false keeps it', (tester) async {
      await pumpOverlay(tester);
      var pressed = 0;
      center().error('Failed', body: 'x', actions: [
        NotificationAction('Retry', () => pressed++, closes: false),
        NotificationAction('Open folder', () => pressed++),
      ]);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(pressed, 1);
      expect(find.text('Failed'), findsOneWidget);

      await tester.tap(find.text('Open folder'));
      await tester.pumpAndSettle();
      expect(pressed, 2);
      expect(container.read(notificationsProvider), isEmpty);
    });

    testWidgets('the F10 Note draws its keycap, and its Undo is plain', (tester) async {
      await pumpOverlay(tester);
      var undone = false;
      center().note(
        'Ellen Swimsuit is on',
        body: 'Press {key} in game to load it.',
        keycap: 'F10',
        characterId: 'ellen',
        actions: [NotificationAction('Undo', () => undone = true)],
      );
      await tester.pumpAndSettle();

      expect(find.widgetWithText(Keycap, 'F10'), findsOneWidget);
      expect(DefaultTextStyle.of(tester.element(find.text('Undo'))).style.color, palette.text);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(undone, isTrue);
      expect(container.read(notificationsProvider), isEmpty);
    });

    testWidgets('Needs you draws its blue tile, tray icon and a primary action', (tester) async {
      await pumpOverlay(tester);
      center().needsYou('A download needs a decision', body: 'Victorian Ballgown',
          actions: [NotificationAction('Open Downloads', () {})]);
      await tester.pumpAndSettle();

      final tile = find.byKey(const ValueKey('notification-tile'));
      expect(decorationOf(tester, tile).color, palette.badgeInfo.background);
      expect(find.byIcon(Icons.download_rounded), findsOneWidget);
      expect(DefaultTextStyle.of(tester.element(find.text('Open Downloads'))).style.color, palette.link);
    });
  });

  group('the stack', () {
    testWidgets('stacks upwards, the newest lowest', (tester) async {
      await pumpOverlay(tester);
      center().error('older', body: '1');
      center().error('newer', body: '2');
      await tester.pumpAndSettle();

      expect(tester.getCenter(find.text('newer')).dy, greaterThan(tester.getCenter(find.text('older')).dy));
    });

    testWidgets('sits 14px from the right edge and 14px above the status bar', (tester) async {
      await pumpOverlay(tester);
      center().error('corner', body: 'x');
      await tester.pumpAndSettle();

      final rect = tester.getRect(card('corner'));
      expect(rect.right, 1200 - 14);
      expect(rect.bottom, 800 - (AppStatusBar.height + 14));
    });

    testWidgets('a fourth card folds the oldest under "+1 more", which unfolds and folds', (tester) async {
      await pumpOverlay(tester);
      for (var i = 1; i <= 4; i++) {
        center().error('error $i', body: 'x');
      }
      await tester.pumpAndSettle();

      expect(find.text('error 1'), findsNothing);
      expect(find.text('error 4'), findsOneWidget);
      expect(find.text('+1 more'), findsOneWidget);

      await tester.tap(find.text('+1 more'));
      await tester.pumpAndSettle();
      expect(find.text('error 1'), findsOneWidget);
      expect(find.text('Show fewer'), findsOneWidget);

      await tester.tap(find.text('Show fewer'));
      await tester.pumpAndSettle();
      expect(find.text('error 1'), findsNothing);
    });

    testWidgets('a folded card with a clock runs out unseen, and the pill goes with it', (tester) async {
      await pumpOverlay(tester);
      center().done('folded done', body: 'x');
      for (var i = 1; i <= 3; i++) {
        center().error('error $i', body: 'x');
      }
      await tester.pumpAndSettle();
      expect(find.text('+1 more'), findsOneWidget);

      await tester.pump(kNotificationDurations[NotificationKind.done]!);
      await tester.pumpAndSettle();
      expect(container.read(notificationsProvider).map((n) => n.title), ['error 1', 'error 2', 'error 3']);
      expect(find.text('+1 more'), findsNothing);
    });

    testWidgets('hovering holds folded clocks too', (tester) async {
      await pumpOverlay(tester);
      center().done('folded done', body: 'x');
      for (var i = 1; i <= 3; i++) {
        center().error('error $i', body: 'x');
      }
      await tester.pumpAndSettle();

      final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await pointer.addPointer(location: tester.getCenter(find.text('error 3')));
      addTearDown(pointer.removePointer);
      await tester.pump();

      await tester.pump(const Duration(seconds: 20));
      await tester.pumpAndSettle();
      expect(container.read(notificationsProvider), hasLength(4));

      await pointer.moveTo(const Offset(10, 10));
      await tester.pump();
      await tester.pump(kNotificationDurations[NotificationKind.done]!);
      await tester.pumpAndSettle();
      expect(container.read(notificationsProvider), hasLength(3));
    });

    testWidgets('stays inside a short window', (tester) async {
      await pumpOverlay(tester, surfaceSize: const Size(800, 600));
      for (var i = 0; i < 6; i++) {
        center().error(
          'A headline for notification number $i',
          body: 'A genuinely long body, of the kind an install produces when it '
              'has something to say about several mods at once — number $i.',
          characterId: 'ellen',
        );
      }
      await tester.pumpAndSettle();
      await tester.tap(find.text('+3 more'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      // The column is taller than the window, so it scrolls inside the stack's bounds with the newest in view.
      final scroll = find.descendant(of: find.byType(NotificationOverlay), matching: find.byType(Scrollable));
      expect(tester.state<ScrollableState>(scroll).position.maxScrollExtent, greaterThan(0));
      expect(tester.getRect(find.byType(NotificationOverlay)).top, greaterThanOrEqualTo(0));
      final newest = tester.getRect(card('A headline for notification number 5'));
      expect(newest.bottom, lessThanOrEqualTo(600 - (AppStatusBar.height + 14)));
      expect(newest.top, greaterThanOrEqualTo(0));
    });
  });

  testWidgets('an action is 30px tall, 6px under the body, its label in line with the title', (tester) async {
    await pumpOverlay(tester);
    center().error('Failed', body: 'Lab Coat', actions: [NotificationAction('Retry', () {})]);
    await tester.pumpAndSettle();

    final title = tester.getRect(find.text('Failed'));
    final body = tester.getRect(find.text('Lab Coat'));
    final label = tester.getRect(find.text('Retry'));
    final button = tester.getRect(find.ancestor(of: find.text('Retry'), matching: find.byType(TextButton)));
    expect(button.top - body.bottom, 6);
    expect(button.height, 30);
    expect(label.left, title.left);
    expect(label.left - button.left, 8);
    expect(label.center.dy, closeTo(button.center.dy, 0.5));
    // 6px of the card's 12px bottom padding, and its 1px border.
    expect(tester.getRect(card('Failed')).bottom - button.bottom, 7);

    final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await pointer.addPointer(location: Offset(button.left + 2, button.center.dy));
    addTearDown(pointer.removePointer);
    await tester.pumpAndSettle();
    final fill = tester.widget<Material>(find.descendant(of: find.byType(TextButton), matching: find.byType(Material)));
    expect(fill.color, palette.notificationErrorHover);
  });

  testWidgets('an action on a card that is not an error is filled with line under the pointer', (tester) async {
    await pumpOverlay(tester);
    center().warning('Low on space', body: 'x', actions: [NotificationAction('Storage', () {}, closes: false)]);
    await tester.pumpAndSettle();

    final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await pointer.addPointer(location: tester.getCenter(find.text('Storage')));
    addTearDown(pointer.removePointer);
    await tester.pumpAndSettle();
    final fill = tester.widget<Material>(find.descendant(of: find.byType(TextButton), matching: find.byType(Material)));
    expect(fill.color, palette.line);
  });

  testWidgets('a press beside or under the label, inside the button, runs the action', (tester) async {
    await pumpOverlay(tester);
    var pressed = 0;
    center().warning('Low on space', body: 'x', actions: [NotificationAction('Storage', () => pressed++, closes: false)]);
    await tester.pumpAndSettle();

    final label = tester.getRect(find.text('Storage'));
    await tester.tapAt(Offset(label.left - 6, label.center.dy));
    await tester.pumpAndSettle();
    expect(pressed, 1);

    await tester.tapAt(Offset(label.center.dx, label.bottom + 5));
    await tester.pumpAndSettle();
    expect(pressed, 2);
  });

  testWidgets('a counted card keeps its instruction, with the subjects under it', (tester) async {
    await pumpOverlay(tester);
    NotificationRepeat asset(String name) => NotificationRepeat('asset-patch',
        subjects: [name], body: (n) => '$n folders need the mod they patch in the same folder.');
    center().warning('These files need another mod', body: 'A needs its mod.', stays: true, repeat: asset('A'));
    center().warning('These files need another mod', body: 'B needs its mod.', stays: true, repeat: asset('B'));
    await tester.pumpAndSettle();

    expect(find.text('2 folders need the mod they patch in the same folder.'), findsOneWidget);
    expect(find.text('A and B'), findsOneWidget);
    expect(container.read(notificationsProvider).single.stays, isTrue);
  });

  group('news during an exit', () {
    testWidgets('a result arriving just after Hide keeps the card', (tester) async {
      await pumpOverlay(tester);
      final working = center().working('Installing', body: 'Ellen Swimsuit');
      await pumpIn(tester);

      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pump(const Duration(milliseconds: 50));
      working.update(kind: NotificationKind.done, title: 'Mod installed');
      await tester.pump(const Duration(milliseconds: 300));

      expect(container.read(notificationsProvider).single.title, 'Mod installed');
      expect(find.text('Mod installed'), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
    });

    testWidgets('a repeat arriving while a card runs out keeps it, counted', (tester) async {
      await pumpOverlay(tester);
      center().done('Mod installed', body: 'A', repeat: const NotificationRepeat('install-done', subjects: ['A']));
      await tester.pumpAndSettle();

      await tester.pump(kNotificationDurations[NotificationKind.done]!);
      await tester.pump(const Duration(milliseconds: 50));
      center().done('Mod installed', body: 'B', repeat: const NotificationRepeat('install-done', subjects: ['B']));
      await tester.pump(const Duration(milliseconds: 300));

      expect(container.read(notificationsProvider).single.count, 2);
      expect(find.text('A and B'), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
    });

    testWidgets('a card folded while it leaves is removed at once', (tester) async {
      await pumpOverlay(tester);
      center().done('leaving', body: 'x');
      await tester.pumpAndSettle();

      await tester.pump(kNotificationDurations[NotificationKind.done]!);
      await tester.pump(const Duration(milliseconds: 50));
      for (var i = 1; i <= 3; i++) {
        center().error('error $i', body: 'x');
      }
      await tester.pump();

      expect(container.read(notificationsProvider).map((n) => n.title), ['error 1', 'error 2', 'error 3']);
    });
  });

  group('the clock', () {
    testWidgets('closes a card once its kind\'s duration is up', (tester) async {
      await pumpOverlay(tester);
      center().done('temporary', body: 'x');
      await tester.pumpAndSettle();
      expect(find.text('temporary'), findsOneWidget);

      await tester.pump(kNotificationDurations[NotificationKind.done]!);
      await tester.pumpAndSettle();

      expect(find.text('temporary'), findsNothing);
      expect(container.read(notificationsProvider), isEmpty);
    });

    testWidgets('errors, Needs you and a staying warning are still there after a minute', (tester) async {
      await pumpOverlay(tester);
      center().error('an error', body: 'x');
      center().needsYou('a decision', body: 'x');
      center().warning('a staying warning', body: 'x', stays: true);
      await tester.pumpAndSettle();

      await tester.pump(const Duration(minutes: 1));
      await tester.pumpAndSettle();
      expect(container.read(notificationsProvider), hasLength(3));
    });

    testWidgets('a Working card turned into its result takes that result\'s clock', (tester) async {
      await pumpOverlay(tester);
      final handle = center().working('Scanning the library…', body: 'your mods');
      await pumpIn(tester);
      await tester.pump(const Duration(minutes: 5));
      expect(find.text('Scanning the library…'), findsOneWidget);

      handle.update(kind: NotificationKind.done, title: 'Library scanned');
      await tester.pumpAndSettle();
      expect(find.text('Library scanned'), findsOneWidget);
      expect(find.text('your mods'), findsOneWidget, reason: 'the body is the stable subject and carries over');

      await tester.pump(kNotificationDurations[NotificationKind.done]!);
      await tester.pumpAndSettle();
      expect(find.text('Library scanned'), findsNothing);
    });

    testWidgets('the close button closes that one and only that one', (tester) async {
      await pumpOverlay(tester);
      center().error('first', body: '1');
      center().error('second', body: '2');
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.close_rounded).first);
      await tester.pumpAndSettle();

      expect(find.text('first'), findsNothing);
      expect(container.read(notificationsProvider).single.title, 'second');
    });

    testWidgets('one raised while the pointer is on the stack arrives held', (tester) async {
      await pumpOverlay(tester);
      center().error('something to hover', body: 'x');
      await tester.pumpAndSettle();

      final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await pointer.addPointer(location: tester.getCenter(find.text('something to hover')));
      addTearDown(pointer.removePointer);
      await tester.pump();

      center().done('arrived late', body: 'y');
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 20));
      await tester.pumpAndSettle();
      expect(find.text('arrived late'), findsOneWidget);

      await pointer.moveTo(const Offset(10, 10));
      await tester.pump();
      await tester.pump(kNotificationDurations[NotificationKind.done]!);
      await tester.pumpAndSettle();
      expect(find.text('arrived late'), findsNothing);
      expect(find.text('something to hover'), findsOneWidget);
    });

    testWidgets('leaving restarts the full duration rather than resuming', (tester) async {
      await pumpOverlay(tester);
      center().done('nearly expired', body: 'x');
      await tester.pumpAndSettle();

      // Four of its five seconds gone before the pointer arrives.
      await tester.pump(const Duration(seconds: 4));

      final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await pointer.addPointer(location: tester.getCenter(find.text('nearly expired')));
      addTearDown(pointer.removePointer);
      await tester.pump();
      await pointer.moveTo(const Offset(10, 10));
      await tester.pump();

      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.text('nearly expired'), findsOneWidget);

      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.text('nearly expired'), findsNothing);
    });
  });
}
