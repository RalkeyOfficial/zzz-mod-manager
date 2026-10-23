import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/core/button_feedback.dart';
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

    testWidgets('a tile card and a portrait card start their text at the same edge', (tester) async {
      await pumpOverlay(tester);
      center().error('About Ellen', body: 'x', characterId: 'ellen');
      center().error('About nobody', body: 'y');
      await tester.pumpAndSettle();

      expect(tester.getTopLeft(find.text('About Ellen')).dx, tester.getTopLeft(find.text('About nobody')).dx);
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

    testWidgets('paints its bar the full 3px tall, along the bottom edge', (tester) async {
      await pumpOverlay(tester);
      center().working('Downloading', body: 'x', progress: 0.64);
      await pumpIn(tester);

      final fill = find.descendant(
          of: find.byKey(const ValueKey('notification-progress')), matching: find.byType(ColoredBox));
      final rect = tester.getRect(fill);
      expect(rect.height, 3, reason: 'a fill with no height draws nothing');
      // Inside the card's 1px border, so 378px of track and 64% of it filled.
      expect(rect.width, closeTo(378 * 0.64, 0.01));
      expect(rect.bottom, tester.getRect(card('Downloading')).bottom - 1);
      expect(tester.widget<ColoredBox>(fill).color, palette.accent);
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

  group('a deck', () {
    final deck = NotificationDeck('downloads', more: (count) => '$count more downloading');
    NotificationHandle download(String mod, {String? characterId}) =>
        center().working('Installing $mod', body: 'Downloading', characterId: characterId, progress: 0.5, deck: deck);
    Finder ghost(int i) => find.byKey(ValueKey('notification-ghost-$i'));

    /// The pointer resting on [finder], removed when the test ends.
    Future<TestGesture> hover(WidgetTester tester, Finder finder) async {
      final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await pointer.addPointer(location: tester.getCenter(finder));
      addTearDown(pointer.removePointer);
      await pumpIn(tester);
      return pointer;
    }

    testWidgets('draws its oldest card in front, with two edges peeking above it as the board does', (tester) async {
      await pumpOverlay(tester);
      center().error('Above the deck', body: 'x');
      download('Victorian Ballgown', characterId: 'ellen');
      download('Crimson Kimono');
      download('Shark Hoodie Recolor');
      await pumpIn(tester);

      expect(find.text('Installing Victorian Ballgown'), findsOneWidget);
      expect(find.text('Installing Crimson Kimono'), findsNothing, reason: 'behind the front card');
      final front = tester.getRect(card('Installing Victorian Ballgown'));
      expect(front.width, 380);

      // The nearer edge: 360 wide, 7px above the front card, on `raised`.
      final near = tester.getRect(ghost(1));
      expect(near.size, const Size(360, 20));
      expect(near.top, front.top - 7);
      expect(near.center.dx, front.center.dx);
      // The farther one: 340 wide, 14px above, on `rowHover`.
      final far = tester.getRect(ghost(2));
      expect(far.size, const Size(340, 20));
      expect(far.top, front.top - 14);
      expect(far.center.dx, front.center.dx);

      BoxDecoration ghostDecoration(int i) => tester
          .widget<DecoratedBox>(find.descendant(of: ghost(i), matching: find.byType(DecoratedBox)))
          .decoration as BoxDecoration;
      expect(ghostDecoration(1).color, palette.raised);
      expect(ghostDecoration(2).color, palette.rowHover);
      for (final i in [1, 2]) {
        final border = ghostDecoration(i).border! as Border;
        expect([border.top.color, border.left.color, border.right.color], List.filled(3, palette.line));
        expect(border.bottom, BorderSide.none);
        expect(ghostDecoration(i).borderRadius, const BorderRadius.vertical(top: Radius.circular(12)));
      }
      // The nearer edge is drawn over the farther one, and the front card over both.
      final stack = find.ancestor(of: ghost(1), matching: find.byType(Stack)).first;
      final layers = tester.widget<Stack>(stack).children;
      expect(layers.map((w) => w.key),
          [const ValueKey('notification-ghost-2'), const ValueKey('notification-ghost-1'), const ValueKey('notification-face')]);

      // The deck's room for its edges: 14px on top of the stack's 8px gap.
      expect(front.top - tester.getRect(card('Above the deck')).bottom, 22);

      final line = tester.widget<Text>(find.text('2 more downloading'));
      final theme = Theme.of(tester.element(find.text('2 more downloading')));
      expect(line.style!.color, palette.text3);
      expect(line.style!.fontSize, theme.textTheme.bodySmall!.fontSize);
      expect(tester.getTopLeft(find.text('2 more downloading')).dx,
          tester.getTopLeft(find.text('Installing Victorian Ballgown')).dx);
      expect(tester.getTopLeft(find.text('2 more downloading')).dy,
          greaterThan(tester.getBottomLeft(find.text('Downloading')).dy));
      // The front card is the download's own card: its portrait and its own bar.
      expect(portraitAsset(tester), 'assets/characters/ellen.png');
      expect(find.byKey(const ValueKey('notification-progress')), findsOneWidget);
      center().clear();
      await pumpIn(tester);
    });

    testWidgets('of two shows one edge, and one of one is a plain card', (tester) async {
      await pumpOverlay(tester);
      center().error('Above the deck', body: 'x');
      download('A');
      await pumpIn(tester);
      expect(ghost(1), findsNothing);
      expect(find.byKey(const ValueKey('notification-deck-line')), findsNothing);
      expect(tester.getRect(card('Installing A')).top - tester.getRect(card('Above the deck')).bottom, 8);

      download('B');
      await pumpIn(tester);
      expect(ghost(1), findsOneWidget);
      expect(ghost(2), findsNothing);
      expect(find.text('1 more downloading'), findsOneWidget);
      expect(tester.getRect(card('Installing A')).top - tester.getRect(card('Above the deck')).bottom, 15);
      center().clear();
      await pumpIn(tester);
    });

    testWidgets('takes one slot of the three', (tester) async {
      await pumpOverlay(tester);
      center().error('error 1', body: 'x');
      center().error('error 2', body: 'x');
      for (final mod in ['A', 'B', 'C', 'D', 'E']) {
        download(mod);
      }
      await pumpIn(tester);

      expect(find.textContaining(RegExp(r'^\+\d+ more$')), findsNothing, reason: 'the deck is one slot');
      expect(find.text('4 more downloading'), findsOneWidget);
      expect(find.text('error 1'), findsOneWidget);
      expect(find.text('error 2'), findsOneWidget);
      expect(ghost(2), findsOneWidget, reason: 'never more than two edges');
      expect(ghost(3), findsNothing);

      center().error('error 3', body: 'x');
      await pumpIn(tester);
      expect(find.text('+1 more'), findsOneWidget);
      expect(find.text('error 1'), findsNothing);
      center().clear();
      await pumpIn(tester);
    });

    testWidgets('spreads into its full cards under the pointer, and folds back once it leaves the stack',
        (tester) async {
      await pumpOverlay(tester);
      center().error('Above the deck', body: 'x');
      download('A');
      download('B');
      download('C');
      await pumpIn(tester);
      final rest = tester.getRect(card('Installing A'));

      final pointer = await hover(tester, find.text('Installing A'));
      expect(find.text('Installing B'), findsOneWidget);
      expect(find.text('Installing C'), findsOneWidget);
      expect(ghost(1), findsNothing, reason: 'the edges tuck away once the cards are out');
      // Upwards from the front card, which stays under the pointer, the farthest at the top, 8px apart.
      expect(tester.getRect(card('Installing A')), rest);
      final b = tester.getRect(card('Installing B'));
      final c = tester.getRect(card('Installing C'));
      expect(rest.top - b.bottom, 8);
      expect(b.top - c.bottom, 8);
      expect(b.width, 380);
      expect(find.descendant(of: card('Installing B'), matching: find.byKey(const ValueKey('notification-deck-line'))),
          findsNothing, reason: 'the deck line is the front card\'s');

      // Over the card above, still on the stack: it stays spread, so nothing slides out from under the pointer.
      final above = tester.getRect(card('Above the deck'));
      await pointer.moveTo(above.center);
      await pumpIn(tester);
      expect(find.text('Installing C'), findsOneWidget);
      expect(tester.getRect(card('Above the deck')), above);

      await pointer.moveTo(const Offset(10, 10));
      await pumpIn(tester);
      expect(find.text('Installing B'), findsNothing);
      expect(find.text('Installing C'), findsNothing);
      expect(ghost(2), findsOneWidget);
      expect(tester.getRect(card('Installing A')), rest);
      center().clear();
      await pumpIn(tester);
    });

    testWidgets('Hide on its front card hides the deck, and every result still arrives', (tester) async {
      await pumpOverlay(tester);
      final a = download('A');
      final b = download('B');
      await pumpIn(tester);

      await tester.tap(find.byIcon(Icons.close_rounded));
      await pumpIn(tester);
      expect(container.read(notificationsProvider), isEmpty);

      a.update(kind: NotificationKind.done, title: 'Mod installed', body: 'A');
      b.update(kind: NotificationKind.error, title: "Couldn't download the mod", body: 'B');
      await pumpIn(tester);
      expect(find.text('Mod installed'), findsOneWidget);
      expect(find.text("Couldn't download the mod"), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
    });

    testWidgets('spread, a card\'s own close button hides that card alone', (tester) async {
      await pumpOverlay(tester);
      download('A');
      final b = download('B');
      download('C');
      await pumpIn(tester);
      await hover(tester, find.text('Installing A'));

      await tester.tap(find.descendant(of: card('Installing B'), matching: find.byIcon(Icons.close_rounded)));
      await pumpIn(tester);
      expect(container.read(notificationsProvider).map((n) => n.title), ['Installing A', 'Installing C']);
      expect(b.isVisible, isFalse);
      center().clear();
      await pumpIn(tester);
    });

    testWidgets('deals a result on top, which leaves on its own clock; a failure leaves as its own card',
        (tester) async {
      await pumpOverlay(tester);
      download('A');
      final b = download('B');
      final c = download('C');
      await pumpIn(tester);

      b.update(kind: NotificationKind.done, title: 'Mod installed', body: 'B');
      await pumpIn(tester);
      expect(find.text('Mod installed'), findsOneWidget);
      expect(find.text('Installing A'), findsNothing, reason: 'the result is in front of the deck');
      expect(find.text('2 more downloading'), findsOneWidget);
      expect(ghost(2), findsOneWidget);

      c.update(kind: NotificationKind.error, title: "Couldn't download the mod", body: 'C');
      await pumpIn(tester);
      final failure = tester.getRect(card("Couldn't download the mod"));
      expect(failure.top, greaterThan(tester.getRect(card('Mod installed')).bottom),
          reason: 'below the deck, at the newest place');
      expect(find.text('1 more downloading'), findsOneWidget);
      expect(ghost(2), findsNothing);

      await tester.pump(kNotificationDurations[NotificationKind.done]!);
      await pumpIn(tester);
      expect(find.text('Mod installed'), findsNothing);
      expect(find.text('Installing A'), findsOneWidget, reason: 'the next card comes up');
      expect(find.byKey(const ValueKey('notification-deck-line')), findsNothing);
      expect(find.text("Couldn't download the mod"), findsOneWidget);
      center().clear();
      await pumpIn(tester);
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

    testWidgets('keyboard focus draws a 2px accent ring, and a pointer\'s focus does not', (tester) async {
      await pumpOverlay(tester);
      center().error('Failed', body: 'x', actions: [NotificationAction('Open folder', () {})]);
      await tester.pumpAndSettle();
      addTearDown(() => FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic);

      final button = find.widgetWithText(TextButton, 'Open folder');
      expect(tester.renderObject(button), isNot(paints..drrect()));

      FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTouch;
      Focus.of(tester.element(find.text('Open folder'))).requestFocus();
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.renderObject(button), isNot(paints..drrect()), reason: "a pointer's focus draws none");

      // The app's ring: 2px of the accent from 2px to 4px out of the button's 7px corners. The button's border
      // eases in over 200 ms.
      FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTraditional;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final edge = RRect.fromRectAndRadius(Offset.zero & tester.getSize(button), const Radius.circular(7));
      expect(
        tester.renderObject(button),
        paints..drrect(outer: edge.inflate(4), inner: edge.inflate(2), color: palette.accent),
      );
    });

    testWidgets('a press draws its text colour at 16%, over the fill it has under the pointer', (tester) async {
      await pumpOverlay(tester);
      center().error('Failed', body: 'x', actions: [NotificationAction('Open folder', () {})]);
      await tester.pumpAndSettle();
      final button = find.widgetWithText(TextButton, 'Open folder');
      final layer = tester.renderObject(
        find.descendant(
          of: find.descendant(of: button, matching: find.byType(ButtonFeedback)),
          matching: find.byType(CustomPaint),
        ).first,
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: tester.getCenter(button));
      await tester.pumpAndSettle();
      expect(layer, isNot(paints..path()), reason: 'the hover is the fill alone');
      await mouse.down(tester.getCenter(button));
      await tester.pumpAndSettle();
      expect(layer, paints..path(color: palette.link.withValues(alpha: palette.link.a * 0.16)));
      await mouse.up();
      await mouse.removePointer();
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

    testWidgets('closing the last card under the pointer does not hold the next one', (tester) async {
      await pumpOverlay(tester);
      center().error('the last one', body: 'x');
      await tester.pumpAndSettle();

      final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await pointer.addPointer(location: tester.getCenter(find.byIcon(Icons.close_rounded)));
      addTearDown(pointer.removePointer);
      await tester.pump();
      await tester.tap(find.byIcon(Icons.close_rounded), kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      expect(find.text('the last one'), findsNothing);

      // Raised away from where the pointer rests, so nothing is hovering it.
      await pointer.moveTo(const Offset(10, 10));
      await tester.pump();
      center().done('later', body: 'y');
      await tester.pumpAndSettle();
      await tester.pump(kNotificationDurations[NotificationKind.done]!);
      await tester.pumpAndSettle();
      expect(find.text('later'), findsNothing);
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
