import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/core/palette.dart';
import 'package:mod_manager_flutter/screens/components/zenith_menu.dart';

import 'support/localized_harness.dart';

/// The custom menu: where it opens, which row is hot, the keys that work the moment it opens, and when an action runs.
void main() {
  late List<String> ran;
  late bool menuWasOpenWhenRun;

  List<ZenithMenuItem> items() => [
    ZenithMenuEntry(
      label: 'Turn off',
      icon: Icons.close_rounded,
      shortcut: 'Space',
      accelerator: LogicalKeyboardKey.space,
      onSelected: () => ran.add('toggle'),
    ),
    ZenithMenuEntry(
      label: 'Remove from favorites',
      icon: Icons.star_rounded,
      shortcut: 'F',
      accelerator: LogicalKeyboardKey.keyF,
      onSelected: () => ran.add('favorite'),
    ),
    const ZenithMenuSeparator(),
    ZenithMenuEntry(label: 'Open in file explorer', icon: Icons.folder_open_outlined, onSelected: () => ran.add('folder')),
    ZenithMenuEntry(
      label: 'Delete…',
      icon: Icons.delete_outline_rounded,
      shortcut: 'Del',
      accelerator: LogicalKeyboardKey.delete,
      danger: true,
      onSelected: () {
        ran.add('delete');
        menuWasOpenWhenRun = find.byType(ZenithMenuSurface).evaluate().isNotEmpty;
      },
    ),
  ];

  Future<void> open(WidgetTester tester, {Offset position = const Offset(100, 100), Size size = const Size(1200, 800)}) async {
    ran = [];
    menuWasOpenWhenRun = true;
    await pumpLocalized(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => showZenithMenu(context, title: 'Winter Maid Uniform', subtitle: 'Ellen Joe · Local', items: items(), position: position),
          child: const Text('open'),
        ),
      ),
      surfaceSize: size,
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expectBuilt(ZenithMenuSurface);
  }

  Rect surface(WidgetTester tester) => tester.getRect(find.byType(ZenithMenuSurface));
  Finder row(String label) => find.byWidgetPredicate((w) => w is ZenithMenuRow && w.label == label);
  bool hot(WidgetTester tester, String label) => tester.widget<ZenithMenuRow>(row(label)).hot;

  testWidgets('opens at the pointer, 268 wide, with its header and rows of 34px', (tester) async {
    await open(tester);

    expect(surface(tester).topLeft, const Offset(100, 100));
    expect(surface(tester).width, 268);
    expect(find.text('Winter Maid Uniform'), findsOneWidget);
    expect(find.text('Ellen Joe · Local'), findsOneWidget);
    expect(find.text('Space'), findsOneWidget);
    expect(tester.getSize(row('Turn off')).height, 34);
    expect(tester.getSize(row('Delete…')).height, 34);
  });

  testWidgets('is drawn in the menu colours, the danger row in redText', (tester) async {
    await open(tester);

    final palette = ZenithPalette.dark(AccentChoice.violet);
    final box = tester.widget<Container>(find.descendant(of: find.byType(ZenithMenuSurface), matching: find.byType(Container)).first);
    final decoration = box.decoration! as BoxDecoration;
    expect(decoration.color, palette.menu);
    expect(decoration.border, Border.all(color: palette.menuBorder));
    expect(decoration.borderRadius, BorderRadius.circular(12));
    expect(tester.widget<Text>(find.text('Delete…')).style!.color, palette.redText);
    expect(tester.widget<Text>(find.text('Turn off')).style!.color, palette.text);
  });

  group('position', () {
    testWidgets('flips left and up when it would pass the window, and stays 8px inside it', (tester) async {
      await open(tester, position: const Offset(1190, 790));

      final rect = surface(tester);
      expect(rect.right, lessThanOrEqualTo(1200 - 8));
      expect(rect.bottom, lessThanOrEqualTo(800 - 8));
      expect(rect.right, 1190, reason: 'flipped to the pointer\'s left');
      expect(rect.bottom, 790, reason: 'flipped above the pointer');
    });

    testWidgets('a pointer at the edge is held 8px in', (tester) async {
      await open(tester, position: const Offset(0, 0));

      expect(surface(tester).topLeft, const Offset(8, 8));
    });
  });

  group('keys', () {
    testWidgets('the arrow keys move the hot row and wrap, Home and End jump', (tester) async {
      await open(tester);
      expect(hot(tester, 'Turn off'), isFalse);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(hot(tester, 'Turn off'), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(hot(tester, 'Delete…'), isTrue, reason: 'wraps from the first to the last');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(hot(tester, 'Turn off'), isTrue, reason: 'and back');
      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.pump();
      expect(hot(tester, 'Delete…'), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await tester.pump();
      expect(hot(tester, 'Turn off'), isTrue);
    });

    testWidgets('Enter runs the hot row after the menu has closed', (tester) async {
      await open(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(ran, ['delete']);
      expect(menuWasOpenWhenRun, isFalse, reason: 'the action runs once the menu is gone');
      expect(find.byType(ZenithMenuSurface), findsNothing);
    });

    testWidgets('Enter with no row hot does nothing', (tester) async {
      await open(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(ran, isEmpty);
      expect(find.byType(ZenithMenuSurface), findsOneWidget);
    });

    for (final (key, label, expected) in [
      (LogicalKeyboardKey.space, 'Space', 'toggle'),
      (LogicalKeyboardKey.keyF, 'F', 'favorite'),
      (LogicalKeyboardKey.delete, 'Del', 'delete'),
    ]) {
      testWidgets('$label runs its row the moment the menu opens, and closes the menu', (tester) async {
        await open(tester);
        await tester.sendKeyEvent(key);
        await tester.pumpAndSettle();

        expect(ran, [expected]);
        expect(find.byType(ZenithMenuSurface), findsNothing);
      });
    }

    testWidgets('an accelerator wins over the row that is hot', (tester) async {
      await open(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();

      expect(ran, ['toggle']);
    });

    testWidgets('a key with Ctrl held is not an accelerator', (tester) async {
      await open(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(ran, isEmpty);
    });

    testWidgets('Escape closes the menu and runs nothing', (tester) async {
      await open(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(ran, isEmpty);
      expect(find.byType(ZenithMenuSurface), findsNothing);
    });
  });

  group('the pointer', () {
    testWidgets('a press on a row runs it', (tester) async {
      await open(tester);
      await tester.tap(find.text('Open in file explorer'));
      await tester.pumpAndSettle();

      expect(ran, ['folder']);
      expect(find.byType(ZenithMenuSurface), findsNothing);
    });

    testWidgets('a press outside closes the menu and runs nothing', (tester) async {
      await open(tester);
      await tester.tapAt(const Offset(900, 600));
      await tester.pumpAndSettle();

      expect(ran, isEmpty);
      expect(find.byType(ZenithMenuSurface), findsNothing);
    });

    testWidgets('hovering a row makes it hot', (tester) async {
      await open(tester);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: tester.getCenter(row('Open in file explorer')));
      await tester.pump();

      expect(hot(tester, 'Open in file explorer'), isTrue);
      await mouse.removePointer();
    });
  });
}
