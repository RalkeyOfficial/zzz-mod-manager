import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/core/app_theme.dart';
import 'package:mod_manager_flutter/core/button_feedback.dart';
import 'package:mod_manager_flutter/core/keyboard_focus.dart';
import 'package:mod_manager_flutter/core/palette.dart';

void _noop() {}

/// What a button draws on itself (the canvas's `ButtonStates` board) and the keyboard focus ring.
void main() {
  tearDown(() => FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic);

  Future<void> pumpButtons(
    WidgetTester tester, {
    Brightness brightness = Brightness.dark,
    AccentChoice accent = AccentChoice.violet,
    List<Widget>? children,
    bool follow = false,
  }) async {
    Widget body = Scaffold(
      body: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 16,
          children: children ??
              [
                FilledButton(onPressed: () {}, child: const Text('Primary')),
                OutlinedButton(onPressed: () {}, child: const Text('Default')),
                TextButton(onPressed: () {}, child: const Text('Ghost')),
                IconButton(onPressed: () {}, icon: const Icon(Icons.close)),
              ],
        ),
      ),
    );
    if (follow) body = KeyboardFocusHighlight(child: body);
    await tester.pumpWidget(MaterialApp(theme: buildAppTheme(brightness: brightness, accent: accent), home: body));
  }

  final kinds = [find.byType(FilledButton), find.byType(OutlinedButton), find.byType(TextButton), find.byType(IconButton)];

  /// The button's feedback layer, where the overlay is painted.
  RenderObject layer(WidgetTester tester, Finder button) => tester.renderObject(
        find.descendant(
          of: find.descendant(of: button, matching: find.byType(ButtonFeedback)),
          matching: find.byType(CustomPaint),
        ).first,
      );

  Color overlay(Color text, double opacity) => text.withValues(alpha: text.a * opacity);

  /// The one ring on screen is around [button]: where it sits, and 2px of [color] from 2px to 4px out of its edge.
  void expectRing(WidgetTester tester, Finder button, Color color, {double radius = 8, String? reason}) {
    final ring = find.byType(ButtonFocusRing);
    expect(ring, findsOneWidget, reason: reason);
    final painter = find.descendant(of: ring, matching: find.byType(CustomPaint));
    final edge = RRect.fromRectAndRadius(Offset.zero & tester.getSize(button), Radius.circular(radius));
    expect(
      tester.renderObject(painter),
      paints
        ..transform(
          matrix4: equals(
            Matrix4.translationValues(tester.getTopLeft(button).dx, tester.getTopLeft(button).dy, 0).storage,
          ),
        )
        ..drrect(outer: edge.inflate(4), inner: edge.inflate(2), color: color),
      reason: reason,
    );
  }

  void expectNoRing({String? reason}) => expect(find.byType(ButtonFocusRing), findsNothing, reason: reason);

  group('hover and press', () {
    for (final brightness in Brightness.values) {
      for (final accent in AccentChoice.values) {
        testWidgets('draw the text colour at 8% and 16% on every button, ${brightness.name} ${accent.name}',
            (tester) async {
          final p = ZenithPalette.forBrightness(brightness, accent);
          await pumpButtons(tester, brightness: brightness, accent: accent);
          // The overlay is the text colour at rest: onPrimary, text, and a ghost or icon button's text2, which stays
          // the overlay's colour while its text goes to text under the pointer.
          final texts = [p.onPrimary, p.text, p.text2, p.text2];
          // The primary button's fill as painted, the canvas's per accent (light: violet #6B45D9, ink for Paper,
          // lime's and teal's own bright accent).
          expect(tester.renderObject(kinds[0]), paints..path(color: p.primary));
          if (brightness == Brightness.light) {
            const fills = {
              AccentChoice.violet: Color(0xFF6B45D9),
              AccentChoice.paper: Color(0xFF15161C),
              AccentChoice.lime: Color(0xFFC8F031),
              AccentChoice.teal: Color(0xFF5FE1D9),
            };
            expect(p.primary, fills[accent]);
          }

          for (final (i, button) in kinds.indexed) {
            expect(layer(tester, button), isNot(paints..path()), reason: '$button at rest');

            final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
            await mouse.addPointer(location: tester.getCenter(button));
            await tester.pumpAndSettle();
            expect(layer(tester, button), paints..path(color: overlay(texts[i], 0.08)), reason: '$button hovered');

            await mouse.down(tester.getCenter(button));
            await tester.pumpAndSettle();
            expect(layer(tester, button), paints..path(color: overlay(texts[i], 0.16)), reason: '$button pressed');

            await mouse.up();
            await tester.pumpAndSettle();
            expect(layer(tester, button), paints..path(color: overlay(texts[i], 0.08)), reason: '$button released');

            await mouse.moveTo(Offset.zero);
            await tester.pumpAndSettle();
            expect(layer(tester, button), isNot(paints..path()), reason: '$button left');
            await mouse.removePointer();
          }
        });
      }
    }

    testWidgets('the press comes in over 60 ms and goes out over 150 ms', (tester) async {
      final p = ZenithPalette.dark(AccentChoice.violet);
      await pumpButtons(tester);
      final button = find.byType(FilledButton);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: tester.getCenter(button));
      await tester.pumpAndSettle();

      await mouse.down(tester.getCenter(button));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(layer(tester, button), paints..path(color: overlay(p.onPrimary, 0.16)));

      await mouse.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(layer(tester, button), isNot(paints..path(color: overlay(p.onPrimary, 0.08))), reason: 'still going');
      await tester.pump(const Duration(milliseconds: 50));
      expect(layer(tester, button), paints..path(color: overlay(p.onPrimary, 0.08)));
      await mouse.removePointer();
    });

    testWidgets('a press shows at once on a button in a scrolling list, before it counts as pressed', (tester) async {
      final p = ZenithPalette.dark(AccentChoice.violet);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(brightness: Brightness.dark, accent: AccentChoice.violet),
          home: Scaffold(
            body: ListView(children: [Center(child: OutlinedButton(onPressed: () {}, child: const Text('Row')))]),
          ),
        ),
      );
      final button = find.byType(OutlinedButton);
      final touch = await tester.startGesture(tester.getCenter(button));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(layer(tester, button), paints..path(color: overlay(p.text, 0.16)));
      await touch.up();
      await tester.pumpAndSettle();
    });

    testWidgets('a disabled button draws nothing', (tester) async {
      await pumpButtons(tester, children: [const FilledButton(onPressed: null, child: Text('Off'))]);
      final button = find.byType(FilledButton);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: tester.getCenter(button));
      await mouse.down(tester.getCenter(button));
      await tester.pumpAndSettle();
      expect(layer(tester, button), isNot(paints..path()));
      await mouse.up();
      await mouse.removePointer();
    });

    testWidgets("a style with its own overlay keeps it, so the two don't add up", (tester) async {
      await pumpButtons(
        tester,
        children: [
          FilledButton(
            style: FilledButton.styleFrom(foregroundColor: Colors.white),
            onPressed: () {},
            child: const Text('Own'),
          ),
        ],
      );
      final button = find.byType(FilledButton);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: tester.getCenter(button));
      await mouse.down(tester.getCenter(button));
      await tester.pumpAndSettle();
      expect(layer(tester, button), isNot(paints..path()));
      await mouse.up();
      await mouse.removePointer();
    });

    testWidgets('a button that fills under the pointer itself keeps only the press', (tester) async {
      final p = ZenithPalette.dark(AccentChoice.violet);
      await pumpButtons(
        tester,
        children: [
          TextButton(
            style: ButtonStyle(backgroundBuilder: buttonFeedback(hover: false)),
            onPressed: () {},
            child: const Text('Action'),
          ),
        ],
      );
      final button = find.byType(TextButton);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: tester.getCenter(button));
      await tester.pumpAndSettle();
      expect(layer(tester, button), isNot(paints..path()));
      await mouse.down(tester.getCenter(button));
      await tester.pumpAndSettle();
      expect(layer(tester, button), paints..path(color: overlay(p.text2, 0.16)));
      await mouse.up();
      await mouse.removePointer();
    });
  });

  group('the press scale', () {
    Future<Size> pumpOne(WidgetTester tester, Widget button, {bool still = false}) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(brightness: Brightness.dark, accent: AccentChoice.violet),
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: still),
            child: Scaffold(body: Center(child: button)),
          ),
        ),
      );
      return tester.getSize(find.byWidget(button));
    }

    /// The fill as the button paints it: a point 0.6px in from its left edge is outside it once it has shrunk.
    PaintPattern fill(Size size, {required bool shrunk}) {
      final center = size.center(Offset.zero);
      final edge = Offset(0.6, size.height / 2);
      return paints..path(includes: [center, if (!shrunk) edge], excludes: [if (shrunk) edge]);
    }

    double labelScale(WidgetTester tester, Finder button) => tester
        .widget<Transform>(
          find.descendant(
            of: find.descendant(of: button, matching: find.byType(ButtonFeedback)),
            matching: find.byType(Transform),
          ).first,
        )
        .transform
        .storage[0];

    testWidgets('shrinks the whole button to 97% in 60 ms and back out in 150 ms', (tester) async {
      const button = FilledButton(onPressed: _noop, child: Text('Install 1 file'));
      final size = await pumpOne(tester, button);
      final finder = find.byType(FilledButton);
      expect(tester.renderObject(finder), fill(size, shrunk: false));

      final touch = await tester.startGesture(tester.getCenter(finder));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      final shape = tester.widget<Material>(find.descendant(of: finder, matching: find.byType(Material))).shape;
      expect(shape, isA<PressedBorder>().having((s) => s.factor, 'factor', closeTo(0.97, 1e-9)));
      expect(tester.renderObject(finder), fill(size, shrunk: true), reason: 'the fill shrinks with it');
      expect(labelScale(tester, finder), closeTo(0.97, 1e-9), reason: 'and the label');
      expect(tester.getSize(finder), size, reason: 'its box, and so the layout, stays');

      await touch.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(labelScale(tester, finder), lessThan(1), reason: 'still on its way out');
      await tester.pump(const Duration(milliseconds: 50));
      expect(labelScale(tester, finder), 1);
      expect(tester.renderObject(finder), fill(size, shrunk: false));
    });

    testWidgets('shrinks the frame of a default button and a call site\'s own shape too', (tester) async {
      final button = OutlinedButton(
        style: ButtonStyle(shape: pressShape(RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)))),
        onPressed: _noop,
        child: const Text('Restore'),
      );
      final size = await pumpOne(tester, button);
      final finder = find.byType(OutlinedButton);
      final touch = await tester.startGesture(tester.getCenter(finder));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      final edge = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(7));
      // The 1px border, drawn 3% smaller about the centre.
      expect(
        tester.renderObject(finder),
        paints..drrect(outer: edge, inner: edge.deflate(1), color: ZenithPalette.dark(AccentChoice.violet).control),
      );
      final material = tester.widget<Material>(find.descendant(of: finder, matching: find.byType(Material)));
      expect((material.shape! as PressedBorder).factor, closeTo(0.97, 1e-9));
      await touch.up();
      await tester.pumpAndSettle();
    });

    testWidgets('is left out with reduced motion, and the press still shows', (tester) async {
      const button = FilledButton(onPressed: _noop, child: Text('Install 1 file'));
      final size = await pumpOne(tester, button, still: true);
      final finder = find.byType(FilledButton);
      final touch = await tester.startGesture(tester.getCenter(finder));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(tester.renderObject(finder), fill(size, shrunk: false));
      expect(labelScale(tester, finder), 1);
      final p = ZenithPalette.dark(AccentChoice.violet);
      expect(layer(tester, finder), paints..path(color: overlay(p.onPrimary, 0.16)));
      await touch.up();
      await tester.pumpAndSettle();
    });
  });

  group('the keyboard focus ring', () {
    for (final brightness in Brightness.values) {
      testWidgets('is 2px of the accent 2px out on every button, and a click draws none, ${brightness.name}',
          (tester) async {
        final p = ZenithPalette.forBrightness(brightness, AccentChoice.paper);
        await pumpButtons(tester, brightness: brightness, accent: AccentChoice.paper);

        for (final button in kinds) {
          await tester.tap(button, kind: PointerDeviceKind.mouse);
          await tester.pumpAndSettle();
        }
        expectNoRing(reason: 'a click draws no ring');

        for (final button in kinds) {
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pumpAndSettle();
          // Violet with the Paper accent, which only fills the primary button.
          expectRing(tester, button, p.accent, reason: '$button focused');
        }
        // The default button keeps its own border under the ring.
        expect(tester.renderObject(kinds[1]), paints..drrect(color: p.control));
      });
    }

    testWidgets('costs an unfocused button nothing: one ring, only for the focused one', (tester) async {
      await pumpButtons(tester);
      expect(find.byType(ButtonFocusRing), findsNothing);
      expect(find.byType(CompositedTransformTarget), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(find.byType(ButtonFocusRing), findsOneWidget);
    });

    testWidgets('follows the focused button when it grows', (tester) async {
      final p = ZenithPalette.dark(AccentChoice.violet);
      final label = ValueNotifier('Go');
      await pumpButtons(
        tester,
        children: [
          ValueListenableBuilder<String>(
            valueListenable: label,
            builder: (_, text, _) => OutlinedButton(onPressed: () {}, child: Text(text)),
          ),
        ],
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      label.value = 'A much longer label than before';
      await tester.pumpAndSettle();
      expectRing(tester, find.byType(OutlinedButton), p.accent);
    });

    testWidgets('is clipped to its scroll view, so it never draws over what the view scrolls under', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(brightness: Brightness.dark, accent: AccentChoice.violet),
          home: Scaffold(
            body: Column(
              children: [
                const SizedBox(height: 100, child: Text('Header')),
                Expanded(
                  child: ListView(
                    children: [
                      const SizedBox(height: 20),
                      Center(child: OutlinedButton(onPressed: () {}, child: const Text('Row'))),
                      const SizedBox(height: 2000),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTraditional;
      Focus.of(tester.element(find.text('Row'))).requestFocus();
      await tester.pumpAndSettle();
      final viewport = tester.getRect(find.byType(ListView));
      final ring = find.descendant(of: find.byType(ButtonFocusRing), matching: find.byType(CustomPaint));
      expect(tester.renderObject(ring), paints..clipRect(rect: viewport)..drrect());

      // Scrolled half under the header: the clip stays the view's, and the ring moves with the button.
      await tester.drag(find.byType(ListView), const Offset(0, -40));
      FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTraditional;
      await tester.pumpAndSettle();
      final top = tester.getTopLeft(find.byType(OutlinedButton));
      expect(top.dy, lessThan(viewport.top));
      expect(
        tester.renderObject(ring),
        paints
          ..clipRect(rect: viewport)
          ..transform(matrix4: equals(Matrix4.translationValues(top.dx, top.dy, 0).storage)),
      );
    });

    /// The ring's transform and the clip it is drawn under, as it paints now.
    PaintPattern ringAt(Offset at, {Rect? clip}) => paints
      ..clipRect(rect: clip)
      ..transform(matrix4: equals(Matrix4.translationValues(at.dx, at.dy, 0).storage));

    final screen = GlobalKey();

    /// The colour on screen as last painted, which is what shows whether the ring was repainted where the button went.
    Future<Color> pixel(WidgetTester tester, Offset at) async {
      final boundary = screen.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final rgba = await tester.runAsync(() async {
        final image = await boundary.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        final i = (at.dy.round() * image.width + at.dx.round()) * 4;
        return [for (var k = 0; k < 4; k++) data!.getUint8(i + k)];
      });
      return Color.fromARGB(rgba![3], rgba[0], rgba[1], rgba[2]);
    }

    /// A point on the ring's top edge, 3px above the button: the middle of the 2px stroke 2px out.
    Offset onRing(WidgetTester tester) {
      final button = tester.getRect(find.byType(OutlinedButton));
      return Offset(button.center.dx, button.top - 3);
    }

    testWidgets('follows a button in a sideways list when the list around it scrolls, clipped by both', (tester) async {
      FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTraditional;
      final accent = ZenithPalette.dark(AccentChoice.violet).accent;
      final outer = ScrollController();
      addTearDown(outer.dispose);
      await tester.pumpWidget(
        RepaintBoundary(
          key: screen,
          child: MaterialApp(
          theme: buildAppTheme(brightness: Brightness.dark, accent: AccentChoice.violet),
          home: Scaffold(
            body: ListView(
              controller: outer,
              children: [
                const SizedBox(height: 100),
                SizedBox(
                  height: 60,
                  child: ListView(
                    key: const ValueKey('inner'),
                    scrollDirection: Axis.horizontal,
                    children: [
                      const SizedBox(width: 100),
                      Center(child: OutlinedButton(onPressed: () {}, child: const Text('Install'))),
                    ],
                  ),
                ),
                const SizedBox(height: 2000),
              ],
            ),
          ),
          ),
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      final ring = find.descendant(of: find.byType(ButtonFocusRing), matching: find.byType(CustomPaint));
      Rect clip() => tester
          .getRect(find.byKey(const ValueKey('inner')))
          .intersect(tester.getRect(find.byType(ListView).first));
      expect(tester.renderObject(ring), ringAt(tester.getTopLeft(find.byType(OutlinedButton)), clip: clip()));
      final before = onRing(tester);
      expect(await pixel(tester, before), accent);

      outer.jumpTo(30);
      await tester.pump();
      await tester.pump();
      final after = onRing(tester);
      expect(after.dy, before.dy - 30);
      expect(await pixel(tester, after), accent, reason: 'repainted where the outer list moved the button');
      expect(await pixel(tester, before), isNot(accent), reason: 'and not left behind');
      expect(tester.renderObject(ring), ringAt(tester.getTopLeft(find.byType(OutlinedButton)), clip: clip()));
    });

    testWidgets('follows a button an ancestor animation moves', (tester) async {
      FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTraditional;
      final accent = ZenithPalette.dark(AccentChoice.violet).accent;
      final slide = ValueNotifier(Offset.zero);
      await tester.pumpWidget(
        RepaintBoundary(
          key: screen,
          child: MaterialApp(
            theme: buildAppTheme(brightness: Brightness.dark, accent: AccentChoice.violet),
            home: Scaffold(
              body: Center(
                child: ValueListenableBuilder<Offset>(
                  valueListenable: slide,
                  builder: (_, offset, child) => AnimatedSlide(
                    offset: offset,
                    duration: const Duration(milliseconds: 200),
                    child: child,
                  ),
                  child: OutlinedButton(onPressed: () {}, child: const Text('Install')),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      final before = onRing(tester);
      expect(await pixel(tester, before), accent);

      slide.value = const Offset(0, 2);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(await pixel(tester, onRing(tester)), accent, reason: 'follows half way');
      await tester.pumpAndSettle();
      expect(await pixel(tester, onRing(tester)), accent, reason: 'and where it arrived');
      expect(await pixel(tester, before), isNot(accent), reason: 'and not left behind');
    });

    testWidgets('leaves the button Tab focused once the pointer clicks another, and a key brings it back',
        (tester) async {
      final p = ZenithPalette.dark(AccentChoice.violet);
      await pumpButtons(tester, follow: true);
      final primary = find.byType(FilledButton);
      final ghost = find.byType(TextButton);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expectRing(tester, primary, p.accent);

      await tester.tap(ghost, kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      expect(FocusManager.instance.highlightMode, FocusHighlightMode.touch);
      expectNoRing(reason: 'the click hid the ring');

      // Shift held for a click is no keyboard use.
      await tester.sendKeyEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
      expectNoRing(reason: 'a modifier alone');

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(FocusManager.instance.highlightMode, FocusHighlightMode.traditional);
      expectRing(tester, find.byType(OutlinedButton), p.accent);
    });

    testWidgets("is drawn around a button whose own style sets its border, the mod page's favourite", (tester) async {
      final p = ZenithPalette.dark(AccentChoice.violet);
      await pumpButtons(
        tester,
        children: [
          IconButton.outlined(
            style: IconButton.styleFrom(side: BorderSide(color: p.control), backgroundColor: p.raised),
            isSelected: false,
            onPressed: () {},
            icon: const Icon(Icons.star_outline_rounded),
          ),
        ],
      );
      final button = find.byType(IconButton);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expectRing(tester, button, p.accent);
      expect(tester.renderObject(button), paints..drrect(color: p.control), reason: 'its own frame stays');
    });

    testWidgets('is the border of a button with no Overlay to draw in, through focusRingOr', (tester) async {
      final p = ZenithPalette.dark(AccentChoice.violet);
      FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTraditional;
      await tester.pumpWidget(
        Theme(
          data: buildAppTheme(brightness: Brightness.dark, accent: AccentChoice.violet),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Center(
              child: TextButton(
                autofocus: true,
                clipBehavior: Clip.none,
                style: ButtonStyle(side: focusRingOr(p, null)),
                onPressed: () {},
                child: const Text('Action'),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final button = find.byType(TextButton);
      final edge = RRect.fromRectAndRadius(Offset.zero & tester.getSize(button), const Radius.circular(8));
      expect(
        tester.renderObject(button),
        paints..drrect(outer: edge.inflate(4), inner: edge.inflate(2), color: p.accent),
      );
      expectNoRing(reason: 'no second ring');

      // A click hides it: the button rebuilds for the new highlight mode.
      FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTouch;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.renderObject(button), isNot(paints..drrect()));
    });

    testWidgets('is drawn around the focused segment of a segmented button', (tester) async {
      final p = ZenithPalette.dark(AccentChoice.violet);
      await pumpButtons(
        tester,
        children: [
          KeyboardFocusRing(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
            child: SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 0, label: Text('Light')),
                ButtonSegment(value: 1, label: Text('System')),
              ],
              selected: const {0},
              showSelectedIcon: false,
              onSelectionChanged: (_) {},
            ),
          ),
        ],
      );
      // The ring's painter alone, without the segmented button's own outline under it.
      final layer = tester.renderObject<RenderCustomPaint>(
        find.descendant(of: find.byType(KeyboardFocusRing), matching: find.byType(CustomPaint)).first,
      );
      void ring(Canvas canvas) => layer.foregroundPainter!.paint(canvas, layer.size);
      expect(ring, isNot(paints..drrect()));

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      final origin = tester.getTopLeft(find.byType(KeyboardFocusRing));
      final segment = tester.getRect(find.widgetWithText(TextButton, 'System')).shift(-origin);
      final edge = RRect.fromRectAndRadius(segment, const Radius.circular(7));
      expect(ring, paints..drrect(outer: edge.inflate(4), inner: edge.inflate(2), color: p.accent));
    });
  });
}
