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

    test('the paper accent fills the primary button and a selected chip, and leaves links and on-states violet', () {
      final dark = ZenithPalette.dark(AccentChoice.paper);
      expect(dark.primary, const Color(0xFFF3EFEB));
      expect(dark.selected.background, const Color(0xFFF3EFEB));
      expect(dark.accent, ZenithPalette.dark(AccentChoice.violet).accent);
      expect(dark.link, ZenithPalette.dark(AccentChoice.violet).link);

      final light = ZenithPalette.light(AccentChoice.paper);
      expect(light.selected.background, const Color(0xFF15161C));
      expect(light.accent, ZenithPalette.light(AccentChoice.violet).accent);
      expect(light.link, const Color(0xFF5A35C8));
    });

    test('the primary button changes under the pointer for every accent on both grounds', () {
      for (final brightness in Brightness.values) {
        for (final accent in AccentChoice.values) {
          final theme = buildAppTheme(brightness: brightness, accent: accent);
          final style = theme.filledButtonTheme.style!.backgroundColor!;
          final idle = style.resolve({})!;
          final hovered = style.resolve({WidgetState.hovered})!;
          final shift = [
            (idle.r - hovered.r).abs(),
            (idle.g - hovered.g).abs(),
            (idle.b - hovered.b).abs(),
          ].reduce((a, b) => a > b ? a : b);
          expect(shift, greaterThan(8 / 255), reason: '$brightness $accent');
        }
      }
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

  group('controls', () {
    testWidgets('a text field is 36px tall, as the design draws it, with or without icons', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(brightness: Brightness.dark, accent: AccentChoice.violet),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 240,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const TextField(),
                    Builder(
                      builder: (context) => TextField(style: Theme.of(context).textTheme.bodyMedium),
                    ),
                    const TextField(
                      decoration: InputDecoration(
                        prefixIcon: Icon(Icons.search, size: 18),
                        suffixIcon: IconButton(onPressed: null, icon: Icon(Icons.close)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      for (final field in find.byType(TextField).evaluate()) {
        expect(tester.getSize(find.byWidget(field.widget)).height, 36);
      }
    });
  });
}
