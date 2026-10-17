import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/core/app_theme.dart';
import 'package:mod_manager_flutter/core/palette.dart';
import 'package:mod_manager_flutter/core/type_scale.dart';

/// The theme is built from the palette and the type scale; these pin the values a user would see go wrong.
void main() {
  group('palette', () {
    test('the primary button is the accent on ink and ink on paper', () {
      final dark = buildAppTheme(brightness: Brightness.dark, accent: AccentChoice.violet);
      expect(dark.colorScheme.primary, const Color(0xFFA98BFF));
      expect(dark.colorScheme.onPrimary, const Color(0xFF0B0C0E));
      expect(dark.scaffoldBackgroundColor, const Color(0xFF0B0C0E));

      final light = buildAppTheme(brightness: Brightness.light, accent: AccentChoice.violet);
      expect(light.colorScheme.primary, const Color(0xFF15161C));
      expect(ZenithPalette.light(AccentChoice.violet).accent, const Color(0xFF6B45D9));
    });

    test('the theme carries the palette for what Material has no slot for', () {
      final theme = buildAppTheme(brightness: Brightness.dark, accent: AccentChoice.teal);
      final palette = theme.extension<ZenithPalette>()!;
      expect(palette.accent, const Color(0xFF5FE1D9));
      expect(palette.amber, const Color(0xFFFFB547));
      expect(palette.elements.keys, unorderedEquals(ElementTone.values));
    });

    test('the paper accent becomes ink on the paper theme, where paper would vanish', () {
      final palette = ZenithPalette.light(AccentChoice.paper);
      expect(palette.accent, const Color(0xFF15161C));
      expect(palette.onAccent, isNot(palette.accent));
    });

    test('an unknown stored accent falls back to violet', () {
      expect(AccentChoice.parse('teal'), AccentChoice.teal);
      expect(AccentChoice.parse('dark-blue'), AccentChoice.violet);
      expect(AccentChoice.parse(null), AccentChoice.violet);
    });
  });

  group('type scale', () {
    testWidgets('roles survive localization with their fonts and sizes', (tester) async {
      late ThemeData resolved;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(brightness: Brightness.dark, accent: AccentChoice.violet),
          home: Builder(
            builder: (context) {
              resolved = Theme.of(context);
              return const SizedBox();
            },
          ),
        ),
      );

      final text = resolved.textTheme;
      expect(text.bodyMedium!.fontSize, 13);
      expect(text.bodyMedium!.fontFamily, kUiFont);
      expect(text.bodyMedium!.color, const Color(0xFFECEDEE));
      expect(text.headlineSmall!.fontFamily, kDisplayFont);
      expect(text.displayMedium!.fontWeight, FontWeight.w800);
      expect(ZenithType.of(tester.element(find.byType(SizedBox))).mono.fontFamily, kMonoFont);
    });
  });
}
