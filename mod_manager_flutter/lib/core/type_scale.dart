import 'package:flutter/material.dart';

/// Unbounded: page titles, a character's name, the wordmark. Always 700 or 800.
const String kDisplayFont = 'Unbounded';

/// Geist: everything a user reads or presses.
const String kUiFont = 'Geist';

/// Geist Mono: paths, file names, keys.
const String kMonoFont = 'Geist Mono';

/// The app's type scale. This file is the only place a text size is set: widgets take a role from
/// `Theme.of(context).textTheme`, or one of the [ZenithType] styles, never a `fontSize:` literal.
/// Markdown keeps its own scale in `MarkdownScale`, built on the same 13px body.
///
/// The roles, from the v3 design:
/// - display: hero text in Unbounded 800, 40 / 34 / 28;
/// - headline: page and dialog titles in Unbounded 700, 26 / 24 / 20;
/// - title: headings in Geist 600, 17 / 15 / 14;
/// - body: 14 / 13 / 12, where `bodyMedium` is running text and `bodySmall` the line that explains it;
/// - label: 13 / 12 for buttons and chips, and 11/600 for badges and counters.
///
/// The styles carry family, size, weight, height and spacing but no colour, so they merge onto a theme's
/// coloured text theme without replacing it.
TextTheme appTextGeometry() {
  TextStyle display(double size, FontWeight weight, double height) => TextStyle(
    fontFamily: kDisplayFont,
    fontSize: size,
    fontWeight: weight,
    height: height,
    letterSpacing: size * -0.01,
  );
  TextStyle ui(double size, FontWeight weight, double height, {double tracking = 0}) => TextStyle(
    fontFamily: kUiFont,
    fontSize: size,
    fontWeight: weight,
    height: height,
    letterSpacing: size * tracking,
  );

  return TextTheme(
    displayLarge: display(40, FontWeight.w800, 1.05),
    displayMedium: display(34, FontWeight.w800, 1.05),
    displaySmall: display(28, FontWeight.w800, 1.05),
    headlineLarge: display(26, FontWeight.w700, 1.15),
    headlineMedium: display(24, FontWeight.w700, 1.15),
    headlineSmall: display(20, FontWeight.w700, 1.25),
    titleLarge: ui(17, FontWeight.w600, 1.3),
    titleMedium: ui(15, FontWeight.w600, 1.35),
    titleSmall: ui(14, FontWeight.w600, 1.35),
    bodyLarge: ui(14, FontWeight.w400, 1.5),
    bodyMedium: ui(13, FontWeight.w400, 1.45),
    bodySmall: ui(12, FontWeight.w400, 1.4),
    labelLarge: ui(13, FontWeight.w500, 1.2),
    labelMedium: ui(12, FontWeight.w500, 1.2),
    labelSmall: ui(11, FontWeight.w600, 1.2, tracking: 0.02),
  );
}

/// The styles the design uses that Material has no role for. Read through [ZenithType.of].
@immutable
class ZenithType extends ThemeExtension<ZenithType> {
  const ZenithType({
    required this.caps,
    required this.mono,
    required this.monoSmall,
    required this.wordmark,
    required this.pageTitle,
    required this.lead,
    required this.watermark,
    required this.watermarkMedium,
    required this.watermarkLarge,
    required this.initials,
  });

  /// A section label such as LIBRARY or IN-GAME KEYS. The widget upper-cases the text; the style only tracks it out.
  final TextStyle caps;

  /// A path or a file name.
  final TextStyle mono;

  /// A keycap, a shortcut in a menu, a counter in the sidebar (which sets 500 on it).
  final TextStyle monoSmall;

  /// ZENITH in the title bar.
  final TextStyle wordmark;

  /// A mod's name at the top of its page.
  final TextStyle pageTitle;

  /// The one sentence a section leads with, such as the Updates page's coverage line.
  final TextStyle lead;

  /// The large initials drawn faintly behind an empty cover.
  final TextStyle watermark;

  /// The same, behind the empty gallery of a mod's page.
  final TextStyle watermarkMedium;

  /// The same, behind a character's header.
  final TextStyle watermarkLarge;

  /// A character's initials on a small tile with no portrait.
  final TextStyle initials;

  static final ZenithType standard = ZenithType(
    caps: const TextStyle(
      fontFamily: kUiFont,
      fontSize: 11,
      fontWeight: FontWeight.w600,
      height: 1.2,
      letterSpacing: 11 * 0.08,
    ),
    mono: const TextStyle(fontFamily: kMonoFont, fontSize: 12, fontWeight: FontWeight.w400, height: 1.4),
    monoSmall: const TextStyle(fontFamily: kMonoFont, fontSize: 11, fontWeight: FontWeight.w400, height: 1),
    wordmark: const TextStyle(
      fontFamily: kDisplayFont,
      fontSize: 13,
      fontWeight: FontWeight.w700,
      height: 1,
      letterSpacing: 13 * 0.08,
    ),
    pageTitle: const TextStyle(
      fontFamily: kDisplayFont,
      fontSize: 30,
      fontWeight: FontWeight.w700,
      height: 1.1,
      letterSpacing: 30 * -0.01,
    ),
    lead: const TextStyle(
      fontFamily: kUiFont,
      fontSize: 18,
      fontWeight: FontWeight.w500,
      height: 1.35,
      letterSpacing: 18 * -0.01,
    ),
    watermark: const TextStyle(
      fontFamily: kDisplayFont,
      fontSize: 56,
      fontWeight: FontWeight.w800,
      height: 1,
      letterSpacing: 56 * -0.01,
    ),
    watermarkMedium: const TextStyle(
      fontFamily: kDisplayFont,
      fontSize: 120,
      fontWeight: FontWeight.w800,
      height: 1,
      letterSpacing: 120 * -0.01,
    ),
    watermarkLarge: const TextStyle(
      fontFamily: kDisplayFont,
      fontSize: 168,
      fontWeight: FontWeight.w800,
      height: 1,
      letterSpacing: 168 * -0.01,
    ),
    initials: const TextStyle(fontFamily: kDisplayFont, fontSize: 11, fontWeight: FontWeight.w700, height: 1),
  );

  static ZenithType of(BuildContext context) => Theme.of(context).extension<ZenithType>() ?? standard;

  @override
  ZenithType copyWith({
    TextStyle? caps,
    TextStyle? mono,
    TextStyle? monoSmall,
    TextStyle? wordmark,
    TextStyle? pageTitle,
    TextStyle? lead,
    TextStyle? watermark,
    TextStyle? watermarkMedium,
    TextStyle? watermarkLarge,
    TextStyle? initials,
  }) => ZenithType(
    caps: caps ?? this.caps,
    mono: mono ?? this.mono,
    monoSmall: monoSmall ?? this.monoSmall,
    wordmark: wordmark ?? this.wordmark,
    pageTitle: pageTitle ?? this.pageTitle,
    lead: lead ?? this.lead,
    watermark: watermark ?? this.watermark,
    watermarkMedium: watermarkMedium ?? this.watermarkMedium,
    watermarkLarge: watermarkLarge ?? this.watermarkLarge,
    initials: initials ?? this.initials,
  );

  @override
  ZenithType lerp(ZenithType? other, double t) => t < 0.5 || other == null ? this : other;
}

/// Puts the app's type scale on [theme]: the [appTextGeometry] roles and the [ZenithType] styles.
///
/// The roles are merged onto the theme's own text themes, which keep their colours. The theme's text styles
/// inherit, so when the theme is localized they merge over Material's geometry and keep these sizes.
ThemeData withAppTypeScale(ThemeData theme) {
  final geometry = appTextGeometry();
  return theme.copyWith(
    textTheme: theme.textTheme.merge(geometry),
    primaryTextTheme: theme.primaryTextTheme.merge(geometry),
    extensions: [...theme.extensions.values.where((e) => e is! ZenithType), ZenithType.standard],
  );
}
