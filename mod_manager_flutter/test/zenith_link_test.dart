import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/screens/components/zenith_controls.dart';

import 'support/localized_harness.dart';

/// [ZenithLink] is reached with Tab and pressed with Enter or Space, like a button.
void main() {
  Future<List<String>> pumpLinks(WidgetTester tester) async {
    final pressed = <String>[];
    await pumpLocalized(tester, _TwoLinks(pressed));
    expectBuilt(_TwoLinks);
    return pressed;
  }

  testWidgets('Tab reaches each link in turn, and Enter presses the one with focus', (tester) async {
    final pressed = await pumpLinks(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(pressed, ['Second']);
  });

  testWidgets('Space presses it too', (tester) async {
    final pressed = await pumpLinks(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();

    expect(pressed, ['First']);
  });

  testWidgets('a press with the pointer works as before', (tester) async {
    final pressed = await pumpLinks(tester);

    await tester.tap(find.text('First'));
    expect(pressed, ['First']);
  });

  testWidgets('it is announced as a link with its label', (tester) async {
    await pumpLinks(tester);

    expect(
      tester.getSemantics(find.text('First')),
      matchesSemantics(label: 'First', isLink: true, hasTapAction: true, isFocusable: true, hasFocusAction: true),
    );
  });
}

class _TwoLinks extends StatelessWidget {
  const _TwoLinks(this.pressed);

  final List<String> pressed;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      ZenithLink('First', onTap: () => pressed.add('First')),
      ZenithLink('Second', onTap: () => pressed.add('Second')),
    ],
  );
}
