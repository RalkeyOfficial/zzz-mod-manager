import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/core/app_theme.dart';
import 'package:mod_manager_flutter/core/palette.dart';
import 'package:mod_manager_flutter/core/type_scale.dart';

/// The theme is built from the palette and the type scale; these pin the values a user would see go wrong.
void main() {
  group('palette', () {
    test('the primary button is the accent on ink, and on paper takes the ButtonStates fills', () {
      final dark = buildAppTheme(brightness: Brightness.dark, accent: AccentChoice.violet);
      expect(dark.colorScheme.primary, const Color(0xFFA98BFF));
      expect(dark.colorScheme.onPrimary, const Color(0xFF0B0C0E));
      expect(dark.scaffoldBackgroundColor, const Color(0xFF0B0C0E));
      expect(ZenithPalette.light(AccentChoice.violet).accent, const Color(0xFF6B45D9));

      const onPaper = {
        AccentChoice.violet: (Color(0xFF6B45D9), Color(0xFFFFFFFF)),
        AccentChoice.paper: (Color(0xFF15161C), Color(0xFFF3EFEB)),
        AccentChoice.lime: (Color(0xFFC8F031), Color(0xFF0B0C0E)),
        AccentChoice.teal: (Color(0xFF5FE1D9), Color(0xFF0B0C0E)),
      };
      for (final MapEntry(key: accent, value: (fill, text)) in onPaper.entries) {
        final light = buildAppTheme(brightness: Brightness.light, accent: accent);
        // The fills are the button's alone: older screens read the scheme's primary as text, so on paper it is the
        // readable accent.
        final p = ZenithPalette.light(accent);
        expect(light.colorScheme.primary, p.accent, reason: accent.name);
        expect(light.colorScheme.onPrimary, p.onAccent, reason: accent.name);
        expect(p.primary, fill, reason: accent.name);
        final style = light.filledButtonTheme.style!;
        expect(style.backgroundColor!.resolve({}), fill, reason: accent.name);
        expect(style.foregroundColor!.resolve({}), text, reason: accent.name);
      }
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

    test("the Downloads panel's scrim and shadow and a badge over art take the artboards' values", () {
      final dark = ZenithPalette.dark(AccentChoice.violet);
      // `Downloads`: rgba(4,5,6,.6) behind the panel, rgba(0,0,0,.5) for its shadow.
      expect(dark.downloadsScrim, const Color(0x99040506));
      expect(dark.downloadsShadow, const Color(0x80000000));
      // `.b-off` on Browse and BrowseCreator: rgba(11,12,14,.75), the same over art in either theme.
      for (final palette in [dark, ZenithPalette.light(AccentChoice.violet)]) {
        expect(palette.badgeOverArt.background, const Color(0xBF0B0C0E));
      }
      expect(dark.overlay, const Color(0xB3060708), reason: "a dialog's scrim is not the panel's");
      expect(dark.artworkScrim, const Color(0xA60B0C0E), reason: 'the veil and the arrows over art keep theirs');
    });

    test('accent text on ink is the accent mixed 70% into white, violet with the Paper accent', () {
      expect(ZenithPalette.dark(AccentChoice.teal).accentOnInk, ZenithPalette.dark(AccentChoice.teal).selected.foreground);
      expect(ZenithPalette.dark(AccentChoice.paper).accentOnInk, ZenithPalette.dark(AccentChoice.violet).accentOnInk);
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

    // Hover, press and the keyboard focus ring are in button_feedback_test.dart.
    testWidgets('a button keeps its fill and border under the pointer and pressed', (tester) async {
      final palette = ZenithPalette.dark(AccentChoice.violet);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(brightness: Brightness.dark, accent: AccentChoice.violet),
          home: Scaffold(body: Center(child: OutlinedButton(onPressed: () {}, child: const Text('Default')))),
        ),
      );
      Material material() =>
          tester.widget<Material>(find.descendant(of: find.byType(OutlinedButton), matching: find.byType(Material)));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: tester.getCenter(find.byType(OutlinedButton)));
      await mouse.down(tester.getCenter(find.byType(OutlinedButton)));
      await tester.pumpAndSettle();
      expect(material().color, palette.raised);
      expect((material().shape! as OutlinedBorder).side, BorderSide(color: palette.control));
      await mouse.up();
      await mouse.removePointer();
    });
  });
}
