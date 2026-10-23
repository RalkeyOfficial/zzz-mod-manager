import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/core/app_theme.dart';
import 'package:mod_manager_flutter/core/button_feedback.dart';
import 'package:mod_manager_flutter/core/button_working.dart';
import 'package:mod_manager_flutter/core/palette.dart';

/// The working state of a button whose action waits (the canvas's `ButtonStates` Working column).
void main() {
  late Completer<void> wait;
  late int presses;

  setUp(() => presses = 0);

  Future<void> pump(WidgetTester tester, {bool icon = false, ValueNotifier<bool>? enabled, bool still = false}) async {
    enabled ??= ValueNotifier(true);
    // Made in the test's own zone, so its completion runs on the test's clock.
    wait = Completer<void>();
    Future<void> action(WorkSpan work) async {
      presses++;
      await work(() => wait.future);
    }

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(brightness: Brightness.dark, accent: AccentChoice.violet),
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: still),
          child: Scaffold(
            body: Center(
              child: ValueListenableBuilder<bool>(
                valueListenable: enabled,
                builder: (context, on, _) => WorkingAction(
                  onPressed: on ? action : null,
                  builder: (context, onPressed) => icon
                      ? FilledButton.icon(
                          onPressed: onPressed,
                          icon: const WorkingIcon(Icon(Icons.download_rounded)),
                          label: const Text('Install 1 file'),
                        )
                      : OutlinedButton(onPressed: onPressed, child: const Text('Restore')),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  final spinner = find.byType(ZenithSpinner);

  testWidgets('shows once the wait has run 200 ms, in the label\'s place, keeping the width', (tester) async {
    await pump(tester);
    final button = find.byType(OutlinedButton);
    final width = tester.getSize(button).width;

    await tester.tap(button);
    await tester.pump(const Duration(milliseconds: 190));
    expect(spinner, findsNothing, reason: 'not before 200 ms');
    await tester.pump(const Duration(milliseconds: 20));
    expect(spinner, findsOneWidget);
    expect(tester.getSize(button).width, width, reason: 'keeps its width');
    expect(tester.getSize(spinner), const Size.square(16));
    // The label is still laid out, keeping the width, but not drawn.
    expect(find.ancestor(of: find.text('Restore'), matching: find.byWidgetPredicate((w) => w is Visibility && !w.visible)),
        findsOneWidget);
    // The 8% overlay stays on while it works.
    final p = ZenithPalette.dark(AccentChoice.violet);
    final layer = find.descendant(
      of: find.descendant(of: button, matching: find.byType(ButtonFeedback)),
      matching: find.byType(CustomPaint),
    ).first;
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.renderObject(layer), paints..path(color: p.text.withValues(alpha: p.text.a * 0.08)));

    wait.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('a wait shorter than 200 ms shows nothing', (tester) async {
    await pump(tester);
    await tester.tap(find.byType(OutlinedButton));
    await tester.pump(const Duration(milliseconds: 100));
    wait.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(spinner, findsNothing);
  });

  testWidgets('stays at least 500 ms once shown, and goes back to rest', (tester) async {
    await pump(tester);
    await tester.tap(find.byType(OutlinedButton));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 50));
    expect(spinner, findsOneWidget);

    wait.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(spinner, findsOneWidget, reason: 'held for 500 ms');
    await tester.pump(const Duration(milliseconds: 150));
    expect(spinner, findsNothing);
    expect(find.text('Restore'), findsOneWidget);
  });

  testWidgets('ignores a press while it works', (tester) async {
    await pump(tester);
    final button = find.byType(OutlinedButton);
    await tester.tap(button);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(button);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(button);
    await tester.pump();
    expect(presses, 1);
    wait.complete();
    await tester.pumpAndSettle();
    await tester.tap(button);
    expect(presses, 2, reason: 'pressable again once done');
    await tester.pump();
  });

  testWidgets('the spinner takes the icon\'s place and the label stays', (tester) async {
    await pump(tester, icon: true);
    await tester.tap(find.byType(FilledButton));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byIcon(Icons.download_rounded), findsNothing);
    expect(find.descendant(of: find.byType(WorkingIcon), matching: spinner), findsOneWidget);
    expect(find.ancestor(of: find.text('Install 1 file'), matching: find.byType(Visibility)), findsNothing);
    wait.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('stays on while its own work runs though the caller turned it off, as the check buttons do',
      (tester) async {
    final enabled = ValueNotifier(true);
    await pump(tester, enabled: enabled);
    final button = find.byType(OutlinedButton);
    await tester.tap(button);
    enabled.value = false;
    await tester.pump(const Duration(milliseconds: 250));
    expect(tester.widget<OutlinedButton>(button).onPressed, isNotNull, reason: 'not greyed: it shows its own work');
    expect(spinner, findsOneWidget);
    await tester.tap(button);
    await tester.pump();
    expect(presses, 1);

    wait.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(spinner, findsNothing);
    expect(tester.widget<OutlinedButton>(button).onPressed, isNull, reason: 'off once its work is done');
  });

  testWidgets('is off, not at rest and deaf, while its action runs on after its wait', (tester) async {
    final afterwards = Completer<void>();
    final check = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(brightness: Brightness.dark, accent: AccentChoice.violet),
        home: Center(
          child: WorkingAction(
            // A check: its requests, then what it found written before its results screen.
            onPressed: (work) async {
              presses++;
              await work(() => check.future);
              await afterwards.future;
            },
            builder: (context, onPressed) => OutlinedButton(onPressed: onPressed, child: const Text('Check all')),
          ),
        ),
      ),
    );
    final button = find.byType(OutlinedButton);
    OutlinedButton widget() => tester.widget<OutlinedButton>(button);

    await tester.tap(button);
    await tester.pump();
    expect(widget().onPressed, isNotNull, reason: 'pressable-looking during its wait');
    check.complete();
    await tester.pump();
    expect(widget().onPressed, isNull, reason: 'off once the wait is over and the action runs on');
    afterwards.complete();
    await tester.pump();
    expect(widget().onPressed, isNotNull, reason: 'back once the action is done');
    await tester.tap(button);
    expect(presses, 2);
    await tester.pump();
  });

  testWidgets('a wait the action reaches after the button has gone still runs', (tester) async {
    WorkSpan? span;
    final shown = ValueNotifier(true);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(brightness: Brightness.dark, accent: AccentChoice.violet),
        home: ValueListenableBuilder<bool>(
          valueListenable: shown,
          builder: (context, on, _) => on
              ? WorkingAction(
                  onPressed: (work) async => span = work,
                  builder: (context, onPressed) => FilledButton(onPressed: onPressed, child: const Text('Go')),
                )
              : const SizedBox(),
        ),
      ),
    );
    await tester.tap(find.byType(FilledButton));
    await tester.pump();
    shown.value = false;
    await tester.pump();
    final result = span!(() async => 7);
    await tester.pump(const Duration(milliseconds: 300));
    expect(await result, 7);
    expect(tester.takeException(), isNull);
  });

  testWidgets('turns every 0.8 s, and every 2.4 s with reduced motion', (tester) async {
    for (final (still, period) in [(false, 800), (true, 2400)]) {
      await pump(tester, still: still);
      await tester.tap(find.byType(OutlinedButton));
      await tester.pump(const Duration(milliseconds: 250));
      final arc = find.descendant(of: spinner, matching: find.byType(CustomPaint)).first;
      double start() {
        late double angle;
        expect(
          tester.renderObject(arc),
          paints..everything((method, args) {
            if (method == #drawArc) angle = args[1] as double;
            return true;
          }),
        );
        return angle;
      }

      // Half a ring, turning a full circle per period: 100 ms is a 1/8 turn at 0.8 s, 1/24 at 2.4 s.
      final before = start();
      await tester.pump(const Duration(milliseconds: 100));
      final turned = (start() - before) % (2 * 3.141592653589793);
      expect(turned, closeTo(2 * 3.141592653589793 * 100 / period, 1e-6), reason: 'still: $still');
      wait.complete();
      await tester.pumpAndSettle();
    }
  });
}
