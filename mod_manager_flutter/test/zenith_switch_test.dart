import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/screens/components/zenith_switch.dart';

import 'support/localized_harness.dart';

void main() {
  Future<List<bool>> pumpSwitch(WidgetTester tester, {required bool value, bool enabled = true}) async {
    final changes = <bool>[];
    await pumpLocalized(
      tester,
      Center(
        child: ZenithSwitch(value: value, semanticLabel: 'Check on launch', onChanged: enabled ? changes.add : null),
      ),
    );
    expectBuilt(ZenithSwitch);
    return changes;
  }

  testWidgets('is drawn at the design size', (tester) async {
    await pumpSwitch(tester, value: false);
    expect(tester.getSize(find.byType(ZenithSwitch)), ZenithSwitch.size);
  });

  testWidgets('a tap asks for the other value', (tester) async {
    final changes = await pumpSwitch(tester, value: false);
    await tester.tap(find.byType(ZenithSwitch));
    expect(changes, [true]);
  });

  testWidgets('space toggles it once focused', (tester) async {
    final changes = await pumpSwitch(tester, value: true);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(changes, [false]);
  });

  testWidgets('without onChanged it does nothing and says it is disabled', (tester) async {
    final handle = tester.ensureSemantics();
    final changes = await pumpSwitch(tester, value: true, enabled: false);
    await tester.tap(find.byType(ZenithSwitch));
    expect(changes, isEmpty);
    expect(
      tester.getSemantics(find.byType(ZenithSwitch)),
      matchesSemantics(label: 'Check on launch', hasToggledState: true, isToggled: true, hasEnabledState: true),
    );
    handle.dispose();
  });

  testWidgets('reads as a labelled toggle', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpSwitch(tester, value: false);
    expect(
      tester.getSemantics(find.byType(ZenithSwitch)),
      matchesSemantics(
        label: 'Check on launch',
        hasToggledState: true,
        hasEnabledState: true,
        isEnabled: true,
        isFocusable: true,
        hasTapAction: true,
        hasFocusAction: true,
      ),
    );
    handle.dispose();
  });
}
