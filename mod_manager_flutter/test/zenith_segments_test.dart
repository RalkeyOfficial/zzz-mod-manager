import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/core/palette.dart';
import 'package:mod_manager_flutter/screens/components/zenith_controls.dart';

import 'support/localized_harness.dart';

/// The segmented choice Settings and the Import review share, and the danger button.
void main() {
  Future<void> pump(WidgetTester tester, {bool dense = false, required ValueChanged<int> onChanged}) => pumpLocalized(
    tester,
    Align(
      alignment: Alignment.topLeft,
      child: ZenithSegments<int>(
        value: 0,
        dense: dense,
        options: const [(0, 'Update it'), (1, 'Keep both')],
        onChanged: onChanged,
      ),
    ),
  );

  testWidgets('the regular form is 30px segments in a tray, and the dense one 28px', (tester) async {
    await pump(tester, onChanged: (_) {});
    final regular = tester.getSize(find.byType(ZenithSegments<int>)).height;
    await pump(tester, dense: true, onChanged: (_) {});
    final dense = tester.getSize(find.byType(ZenithSegments<int>)).height;

    expect(regular, 30 + 6 + 2, reason: '3px of tray inside a 1px border');
    expect(dense, 28 + 6 + 2);
  });

  testWidgets('hugs its words instead of filling the width it is given', (tester) async {
    await pump(tester, dense: true, onChanged: (_) {});

    expect(tester.getSize(find.byType(ZenithSegments<int>)).width, lessThan(300));
  });

  testWidgets('pressing a word picks it', (tester) async {
    int? picked;
    await pump(tester, onChanged: (value) => picked = value);
    await tester.tap(find.text('Keep both'));

    expect(picked, 1);
  });

  testWidgets('the picked word is on the hover fill in the text colour, the rest in text2', (tester) async {
    await pump(tester, onChanged: (_) {});

    final palette = ZenithPalette.dark(AccentChoice.violet);
    expect(tester.widget<Text>(find.text('Update it')).style!.color, palette.text);
    expect(tester.widget<Text>(find.text('Keep both')).style!.color, palette.text2);
    final selected = tester.widget<Material>(
      find.ancestor(of: find.text('Update it'), matching: find.byType(Material)).first,
    );
    expect(selected.color, palette.hover);
  });

  testWidgets('the group is labelled, and a word says whether it is picked', (tester) async {
    await pumpLocalized(
      tester,
      ZenithSegments<int>(
        value: 0,
        semanticLabel: 'What to do with the existing mod',
        options: const [(0, 'Update it'), (1, 'Keep both')],
        onChanged: (_) {},
      ),
    );

    expect(find.bySemanticsLabel('What to do with the existing mod'), findsOneWidget);
  });

  testWidgets('dangerButtonStyle fills with red and its ink, in either theme', (tester) async {
    for (final brightness in Brightness.values) {
      late ButtonStyle style;
      await pumpLocalized(
        tester,
        Builder(
          builder: (context) {
            style = dangerButtonStyle(context);
            return const SizedBox();
          },
        ),
        brightness: brightness,
      );
      final palette = ZenithPalette.forBrightness(brightness, AccentChoice.violet);

      expect(style.backgroundColor!.resolve({}), palette.red);
      expect(style.foregroundColor!.resolve({}), palette.onRed);
    }
  });
}
