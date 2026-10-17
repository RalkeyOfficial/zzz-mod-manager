import 'package:flutter/material.dart';

/// The accent picked in Settings › Appearance, stored by [name] under `config.json`'s `accent` key.
enum AccentChoice {
  violet,
  paper,
  lime,
  teal;

  /// Reads a stored value, falling back to [violet] for anything this build doesn't know.
  static AccentChoice parse(Object? value) =>
      values.firstWhere((a) => a.name == value, orElse: () => violet);
}

/// A character's element, which colours the tile its portrait sits on.
///
/// [neutral] is the tile for anything that isn't an agent: the built-in categories and `unknown`.
enum ElementTone { ice, fire, electric, ether, physical, neutral }

/// A background, foreground and optional border that belong together: a badge, a portrait tile.
@immutable
class TonePair {
  const TonePair(this.background, this.foreground, [this.border]);

  final Color background;
  final Color foreground;
  final Color? border;

  static TonePair lerp(TonePair a, TonePair b, double t) => TonePair(
    Color.lerp(a.background, b.background, t)!,
    Color.lerp(a.foreground, b.foreground, t)!,
    Color.lerp(a.border, b.border, t),
  );
}

/// Every colour the app paints with. `core/app_theme.dart` builds the Material theme from it, and a widget that
/// needs a colour Material has no slot for reads it here through [ZenithPalette.of], never from a literal.
///
/// Two grounds, dark ink and light paper, each with four accents. [accent] marks what is on or selected, and links.
/// [primary] fills the primary button: the accent itself on ink, ink on paper.
@immutable
class ZenithPalette extends ThemeExtension<ZenithPalette> {
  const ZenithPalette({
    required this.brightness,
    required this.chrome,
    required this.ground,
    required this.card,
    required this.raised,
    required this.hover,
    required this.field,
    required this.divider,
    required this.outline,
    required this.line,
    required this.control,
    required this.fieldBorder,
    required this.text,
    required this.textProse,
    required this.text2,
    required this.text3,
    required this.accent,
    required this.onAccent,
    required this.primary,
    required this.onPrimary,
    required this.amber,
    required this.red,
    required this.onRed,
    required this.blue,
    required this.overlay,
    required this.badgeUpdate,
    required this.badgeMissing,
    required this.badgeInfo,
    required this.badgeNeutral,
    required this.elements,
  });

  final Brightness brightness;

  /// Title bar, sidebar and status bar.
  final Color chrome;

  /// Behind every page.
  final Color ground;

  /// Cards, mod tiles, list rows.
  final Color card;

  /// Secondary buttons, keycaps, a selected row.
  final Color raised;

  /// A raised surface under the pointer.
  final Color hover;

  /// Inputs and grouped settings rows.
  final Color field;

  /// Between the chrome and the page, and between rows of a group.
  final Color divider;

  /// Around cards, groups and dialogs.
  final Color outline;

  /// Chips, badges and separators inside a surface.
  final Color line;

  /// Around buttons, switches and keycaps.
  final Color control;

  final Color fieldBorder;

  /// Headings and anything the eye lands on first.
  final Color text;

  /// Running text: descriptions, notes, values in a list.
  final Color textProse;

  /// Secondary text and idle controls.
  final Color text2;

  /// Hints, captions and labels.
  final Color text3;

  final Color accent;
  final Color onAccent;
  final Color primary;
  final Color onPrimary;

  /// Updates.
  final Color amber;

  /// Missing folders and anything destructive.
  final Color red;
  final Color onRed;

  /// Where a mod came from, and other plain information.
  final Color blue;

  /// The scrim behind a dialog.
  final Color overlay;

  final TonePair badgeUpdate;
  final TonePair badgeMissing;
  final TonePair badgeInfo;
  final TonePair badgeNeutral;

  /// Portrait tiles, one per [ElementTone].
  final Map<ElementTone, TonePair> elements;

  /// A selected chip or segment: the accent washed into the card.
  Color get accentWash => Color.lerp(card, accent, 0.14)!;

  /// The border of a selected chip or option.
  Color get accentEdge => Color.lerp(card, accent, 0.5)!;

  /// Text on [accentWash].
  Color get accentText => Color.lerp(accent, text, 0.3)!;

  TonePair get badgeOn => TonePair(accent, onAccent);

  TonePair element(ElementTone tone) => elements[tone]!;

  /// The app's palette, or the default dark one where no app theme is installed (a bare test harness).
  static ZenithPalette of(BuildContext context) =>
      Theme.of(context).extension<ZenithPalette>() ?? ZenithPalette.dark(AccentChoice.violet);

  factory ZenithPalette.forBrightness(Brightness brightness, AccentChoice accent) =>
      brightness == Brightness.dark ? ZenithPalette.dark(accent) : ZenithPalette.light(accent);

  factory ZenithPalette.dark(AccentChoice accent) {
    final accentColor = switch (accent) {
      AccentChoice.violet => const Color(0xFFA98BFF),
      AccentChoice.paper => const Color(0xFFF3EFEB),
      AccentChoice.lime => const Color(0xFFC8F031),
      AccentChoice.teal => const Color(0xFF5FE1D9),
    };
    const onAccent = Color(0xFF0B0C0E);
    return ZenithPalette(
      brightness: Brightness.dark,
      chrome: const Color(0xFF0A0B0D),
      ground: const Color(0xFF0B0C0E),
      card: const Color(0xFF121316),
      raised: const Color(0xFF1A1C20),
      hover: const Color(0xFF24272C),
      field: const Color(0xFF101114),
      divider: const Color(0xFF1E2024),
      outline: const Color(0xFF23262B),
      line: const Color(0xFF2A2D33),
      control: const Color(0xFF363A42),
      fieldBorder: const Color(0xFF2F3239),
      text: const Color(0xFFECEDEE),
      textProse: const Color(0xFFC9CCD2),
      text2: const Color(0xFFA9ADB5),
      text3: const Color(0xFF80858F),
      accent: accentColor,
      onAccent: onAccent,
      primary: accentColor,
      onPrimary: onAccent,
      amber: const Color(0xFFFFB547),
      red: const Color(0xFFFF6B5B),
      onRed: const Color(0xFF160605),
      blue: const Color(0xFF6CB6FF),
      overlay: const Color(0xB3060708),
      badgeUpdate: const TonePair(Color(0xFF3A2A0C), Color(0xFFFFC870), Color(0xFF6A4C14)),
      badgeMissing: const TonePair(Color(0xFF3A1512), Color(0xFFFF9A8E), Color(0xFF6B2620)),
      badgeInfo: const TonePair(Color(0xFF0F2236), Color(0xFF9CCBFF), Color(0xFF1F4468)),
      badgeNeutral: const TonePair(Color(0xFF1A1C20), Color(0xFFA9ADB5), Color(0xFF2A2D33)),
      elements: const {
        ElementTone.ice: TonePair(Color(0xFF12303D), Color(0xFF9FE1FA)),
        ElementTone.fire: TonePair(Color(0xFF3D1A10), Color(0xFFFFA27A)),
        ElementTone.electric: TonePair(Color(0xFF14244A), Color(0xFF8DB8FF)),
        ElementTone.ether: TonePair(Color(0xFF331741), Color(0xFFEBA0FF)),
        ElementTone.physical: TonePair(Color(0xFF382F10), Color(0xFFF5D46A)),
        ElementTone.neutral: TonePair(Color(0xFF1E2126), Color(0xFFA9ADB5)),
      },
    );
  }

  /// The paper theme. The accents are darkened to read on paper; the paper accent, which would vanish, becomes ink.
  factory ZenithPalette.light(AccentChoice accent) {
    final accentColor = switch (accent) {
      AccentChoice.violet => const Color(0xFF6B45D9),
      AccentChoice.paper => const Color(0xFF15161C),
      AccentChoice.lime => const Color(0xFF4D6A00),
      AccentChoice.teal => const Color(0xFF00736D),
    };
    final onAccent = accent == AccentChoice.paper ? const Color(0xFFF3EFEB) : const Color(0xFFFFFFFF);
    return ZenithPalette(
      brightness: Brightness.light,
      chrome: const Color(0xFFE8E2DB),
      ground: const Color(0xFFEFEAE4),
      card: const Color(0xFFF8F5F1),
      raised: const Color(0xFFFDFBF8),
      hover: const Color(0xFFE9E3DC),
      field: const Color(0xFFFBF9F6),
      divider: const Color(0xFFE0D9D1),
      outline: const Color(0xFFDCD5CD),
      line: const Color(0xFFD3CBC2),
      control: const Color(0xFFCBC3BA),
      fieldBorder: const Color(0xFFD3CBC2),
      text: const Color(0xFF15161C),
      textProse: const Color(0xFF2E2D33),
      text2: const Color(0xFF55525A),
      text3: const Color(0xFF67636B),
      accent: accentColor,
      onAccent: onAccent,
      primary: const Color(0xFF15161C),
      onPrimary: const Color(0xFFF3EFEB),
      amber: const Color(0xFF9A5B00),
      red: const Color(0xFFC2361F),
      onRed: const Color(0xFFFFFFFF),
      blue: const Color(0xFF1D63B8),
      overlay: const Color(0x6615161C),
      badgeUpdate: const TonePair(Color(0xFFF8E6C4), Color(0xFF7A4600), Color(0xFFE8C98E)),
      badgeMissing: const TonePair(Color(0xFFF8DDD8), Color(0xFF9E2A17), Color(0xFFEDB7AD)),
      badgeInfo: const TonePair(Color(0xFFDCE9F8), Color(0xFF1B4F8F), Color(0xFFB5CDEB)),
      badgeNeutral: const TonePair(Color(0xFFF8F5F1), Color(0xFF55525A), Color(0xFFDCD5CD)),
      elements: const {
        ElementTone.ice: TonePair(Color(0xFFCFE6EF), Color(0xFF1D5A73)),
        ElementTone.fire: TonePair(Color(0xFFF5D7C9), Color(0xFF93370F)),
        ElementTone.electric: TonePair(Color(0xFFD5DFF6), Color(0xFF284A9E)),
        ElementTone.ether: TonePair(Color(0xFFEAD7F1), Color(0xFF76278F)),
        ElementTone.physical: TonePair(Color(0xFFEFE3BC), Color(0xFF6E5600)),
        ElementTone.neutral: TonePair(Color(0xFFE4DED7), Color(0xFF55525A)),
      },
    );
  }

  @override
  ZenithPalette copyWith({Color? accent, Color? onAccent, Color? primary, Color? onPrimary}) => ZenithPalette(
    brightness: brightness,
    chrome: chrome,
    ground: ground,
    card: card,
    raised: raised,
    hover: hover,
    field: field,
    divider: divider,
    outline: outline,
    line: line,
    control: control,
    fieldBorder: fieldBorder,
    text: text,
    textProse: textProse,
    text2: text2,
    text3: text3,
    accent: accent ?? this.accent,
    onAccent: onAccent ?? this.onAccent,
    primary: primary ?? this.primary,
    onPrimary: onPrimary ?? this.onPrimary,
    amber: amber,
    red: red,
    onRed: onRed,
    blue: blue,
    overlay: overlay,
    badgeUpdate: badgeUpdate,
    badgeMissing: badgeMissing,
    badgeInfo: badgeInfo,
    badgeNeutral: badgeNeutral,
    elements: elements,
  );

  @override
  ZenithPalette lerp(ZenithPalette? other, double t) {
    if (other == null) return this;
    Color c(Color a, Color b) => Color.lerp(a, b, t)!;
    return ZenithPalette(
      brightness: t < 0.5 ? brightness : other.brightness,
      chrome: c(chrome, other.chrome),
      ground: c(ground, other.ground),
      card: c(card, other.card),
      raised: c(raised, other.raised),
      hover: c(hover, other.hover),
      field: c(field, other.field),
      divider: c(divider, other.divider),
      outline: c(outline, other.outline),
      line: c(line, other.line),
      control: c(control, other.control),
      fieldBorder: c(fieldBorder, other.fieldBorder),
      text: c(text, other.text),
      textProse: c(textProse, other.textProse),
      text2: c(text2, other.text2),
      text3: c(text3, other.text3),
      accent: c(accent, other.accent),
      onAccent: c(onAccent, other.onAccent),
      primary: c(primary, other.primary),
      onPrimary: c(onPrimary, other.onPrimary),
      amber: c(amber, other.amber),
      red: c(red, other.red),
      onRed: c(onRed, other.onRed),
      blue: c(blue, other.blue),
      overlay: c(overlay, other.overlay),
      badgeUpdate: TonePair.lerp(badgeUpdate, other.badgeUpdate, t),
      badgeMissing: TonePair.lerp(badgeMissing, other.badgeMissing, t),
      badgeInfo: TonePair.lerp(badgeInfo, other.badgeInfo, t),
      badgeNeutral: TonePair.lerp(badgeNeutral, other.badgeNeutral, t),
      elements: {
        for (final tone in ElementTone.values)
          tone: TonePair.lerp(elements[tone]!, other.elements[tone]!, t),
      },
    );
  }
}
