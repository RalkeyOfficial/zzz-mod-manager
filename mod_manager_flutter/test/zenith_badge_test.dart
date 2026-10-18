import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/core/palette.dart';
import 'package:mod_manager_flutter/screens/components/zenith_controls.dart';

import 'support/localized_harness.dart';

/// A [ZenithBadge] with an `onTap`, such as the card's status badge, is a button: reached with Tab, pressed with
/// Enter or Space, and announced as one.
void main() {
  Future<List<String>> pumpBadge(WidgetTester tester) async {
    final pressed = <String>[];
    await pumpLocalized(tester, _PressableBadge(pressed));
    expectBuilt(_PressableBadge);
    return pressed;
  }

  testWidgets('Tab reaches it and Enter presses it', (tester) async {
    final pressed = await pumpBadge(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(pressed, ['Newer file']);
  });

  testWidgets('Space presses it too', (tester) async {
    final pressed = await pumpBadge(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();

    expect(pressed, ['Newer file']);
  });

  testWidgets('it is announced as a focusable button with its label', (tester) async {
    await pumpBadge(tester);

    expect(
      tester.getSemantics(find.text('Newer file')),
      matchesSemantics(
        label: 'Newer file',
        isButton: true,
        hasTapAction: true,
        isFocusable: true,
        hasFocusAction: true,
      ),
    );
  });

  testWidgets('without onTap it is only text, and Tab passes it by', (tester) async {
    await pumpLocalized(tester, const _PlainBadge());
    expectBuilt(_PlainBadge);

    expect(find.byType(FocusableActionDetector), findsNothing);
  });
}

class _PressableBadge extends StatelessWidget {
  const _PressableBadge(this.pressed);

  final List<String> pressed;

  @override
  Widget build(BuildContext context) => Center(
    child: ZenithBadge(
      label: 'Newer file',
      tone: ZenithPalette.of(context).badgeUpdate,
      onTap: () => pressed.add('Newer file'),
    ),
  );
}

class _PlainBadge extends StatelessWidget {
  const _PlainBadge();

  @override
  Widget build(BuildContext context) =>
      Center(child: ZenithBadge(label: 'Local', tone: ZenithPalette.of(context).badgeNeutral));
}
