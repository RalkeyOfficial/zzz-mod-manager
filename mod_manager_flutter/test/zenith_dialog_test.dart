import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/core/palette.dart';
import 'package:mod_manager_flutter/screens/components/zenith_dialog.dart';

import 'support/localized_harness.dart';

/// The card every v3 dialog is drawn on: the canvas's two kinds, the window it must fit, and the keys it answers.
void main() {
  /// Opens [dialog] from a button, in a window of [size].
  Future<void> open(WidgetTester tester, Widget Function(BuildContext) dialog, {Size size = const Size(1200, 800)}) async {
    await pumpLocalized(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => showDialog<void>(context: context, builder: dialog),
          child: const Text('open'),
        ),
      ),
      surfaceSize: size,
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expectBuilt(ZenithDialog);
  }

  ZenithDialog sectioned({
    bool busy = false,
    Widget? footerStart,
    Widget? belowCard,
    Widget? body,
    double width = 720,
    VoidCallback? onSubmit,
  }) => ZenithDialog.sectioned(
    title: 'Import 3 mods',
    subtitle: 'Check where each one goes.',
    width: width,
    body: body ?? const SizedBox(height: 100),
    footerStart: footerStart,
    belowCard: belowCard,
    busy: busy,
    onSubmit: onSubmit,
    actions: [TextButton(onPressed: () {}, child: const Text('Cancel')), FilledButton(onPressed: () {}, child: const Text('Import 3'))],
  );

  group('sectioned', () {
    testWidgets('a header with the title, the subtitle and a close button, a body and a footer', (tester) async {
      await open(tester, (_) => sectioned(footerStart: const Text('a note')));

      expect(find.text('Import 3 mods'), findsOneWidget);
      expect(find.text('Check where each one goes.'), findsOneWidget);
      expect(find.byTooltip('Close'), findsOneWidget);
      expect(find.text('a note'), findsOneWidget);
      // The note is at the footer's start and the buttons at its end.
      expect(tester.getTopLeft(find.text('a note')).dx, lessThan(tester.getTopLeft(find.text('Cancel')).dx));
      final card = tester.getRect(find.byType(DecoratedBox).first);
      expect(tester.getTopRight(find.text('Import 3')).dx, closeTo(card.right - 24 - 14, 12), reason: 'the primary ends the row');
    });

    testWidgets('is as wide as asked, and gives way to a narrow window by 16px a side', (tester) async {
      await open(tester, (_) => sectioned(width: 920), size: const Size(800, 500));

      final card = tester.getRect(find.descendant(of: find.byType(ZenithDialog), matching: find.byType(SizedBox)).first);
      expect(card.width, 800 - 32);
    });

    testWidgets('a long body scrolls inside a card that fits a 500px window, header and footer staying', (tester) async {
      await open(tester, (_) => sectioned(body: const SizedBox(height: 2000)), size: const Size(800, 500));

      final card = tester.getRect(find.descendant(of: find.byType(ZenithDialog), matching: find.byType(SizedBox)).first);
      expect(card.height, lessThanOrEqualTo(500 - 48));
      expect(find.text('Import 3 mods'), findsOneWidget);
      expect(find.text('Import 3'), findsOneWidget);
      expect(tester.getBottomLeft(find.text('Import 3')).dy, lessThan(500));
      expect(find.byType(SingleChildScrollView), findsOneWidget);
    });

    testWidgets('the close button, Escape and a press on the scrim close it', (tester) async {
      await open(tester, (_) => sectioned());
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(ZenithDialog), findsNothing);

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(ZenithDialog), findsNothing);

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(find.byType(ZenithDialog), findsNothing);
    });

    testWidgets('while busy, Escape, the scrim and the close button do nothing', (tester) async {
      await open(tester, (_) => sectioned(busy: true));

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(ZenithDialog), findsOneWidget);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(find.byType(ZenithDialog), findsOneWidget);
      await tester.tap(find.byTooltip('Close'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.byType(ZenithDialog), findsOneWidget);
    });

    testWidgets('a line under the card sits right-aligned beneath it', (tester) async {
      await open(tester, (_) => sectioned(belowCard: const Text('Choose a character to continue')));

      final card = tester.getRect(find.byType(DecoratedBox).first);
      final line = tester.getRect(find.text('Choose a character to continue'));
      expect(line.top, greaterThan(card.bottom));
      expect(line.right, closeTo(card.right - 24, 1));
    });

    testWidgets('has the card, border and shadow of the palette', (tester) async {
      await open(tester, (_) => sectioned());

      final palette = ZenithPalette.dark(AccentChoice.violet);
      final box = tester.widget<DecoratedBox>(find.byType(DecoratedBox).first).decoration as BoxDecoration;
      expect(box.color, palette.dialog);
      expect(box.border, Border.all(color: palette.line));
      expect(box.borderRadius, BorderRadius.circular(18));
      expect(box.boxShadow!.single.color, palette.dialogShadow);
      expect(box.boxShadow!.single.offset, const Offset(0, 30));
      expect(box.boxShadow!.single.blurRadius, 80);
    });
  });

  group('compact', () {
    testWidgets('a title, a subtitle, a body and buttons at the end, with no close button', (tester) async {
      await open(
        tester,
        (_) => ZenithDialog.compact(
          width: 480,
          title: 'Delete Winter Maid?',
          subtitle: 'Ellen Joe',
          body: const Text('The folder goes to the trash.'),
          actions: [TextButton(onPressed: () {}, child: const Text('Cancel')), FilledButton(onPressed: () {}, child: const Text('Delete'))],
        ),
      );

      expect(find.text('Delete Winter Maid?'), findsOneWidget);
      expect(find.text('Ellen Joe'), findsOneWidget);
      expect(find.byTooltip('Close'), findsNothing);
      final dialog = tester.getRect(find.descendant(of: find.byType(ZenithDialog), matching: find.byType(SizedBox)).first);
      expect(dialog.width, 480);
      expect(tester.getTopRight(find.text('Delete')).dx, lessThan(dialog.right - 24));
      expect(tester.getTopLeft(find.text('Cancel')).dx, greaterThan(dialog.left + dialog.width / 2));
    });
  });

  group('Enter', () {
    Future<int> pressEnterIn(WidgetTester tester, {int maxLines = 1, bool wired = true}) async {
      var submitted = 0;
      await open(
        tester,
        (_) => sectioned(onSubmit: wired ? () => submitted++ : null, body: TextField(autofocus: true, maxLines: maxLines)),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      return submitted;
    }

    testWidgets('in a single-line field presses the primary action', (tester) async {
      expect(await pressEnterIn(tester), 1);
    });

    testWidgets('in a field of several lines is a new line, not a press', (tester) async {
      expect(await pressEnterIn(tester, maxLines: 3), 0);
    });

    testWidgets('does nothing while there is no primary action to press', (tester) async {
      expect(await pressEnterIn(tester, wired: false), 0);
    });
  });
}
