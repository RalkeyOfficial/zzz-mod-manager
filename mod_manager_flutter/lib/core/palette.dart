import 'package:flutter/material.dart';

/// The accent picked in Settings › Appearance, stored by [name] under `config.json`'s `accent` key.
enum AccentChoice {
  violet,

  /// Paper-white fills the primary button and a selected chip; everything else the accent marks stays violet, since
  /// paper beside paper-white text would mark nothing.
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
enum ElementTone { ice, fire, electric, ether, physical, wind, lumiflux, neutral }

/// The dotted ground behind a character's header and behind a mod with no cover, in its character's element:
/// [background] with [dot]s on a grid, and [stroke] for the outlined initials drawn over it.
@immutable
class ElementGround {
  const ElementGround(this.background, this.dot, this.stroke);

  final Color background;
  final Color dot;
  final Color stroke;

  static ElementGround lerp(ElementGround a, ElementGround b, double t) => ElementGround(
    Color.lerp(a.background, b.background, t)!,
    Color.lerp(a.dot, b.dot, t)!,
    Color.lerp(a.stroke, b.stroke, t)!,
  );
}

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
/// [primary] fills the primary button: the accent on ink, or paper-white with the Paper accent; always ink on paper.
@immutable
class ZenithPalette extends ThemeExtension<ZenithPalette> {
  const ZenithPalette({
    required this.brightness,
    required this.chrome,
    required this.ground,
    required this.card,
    required this.raised,
    required this.hover,
    required this.rowHover,
    required this.rowSelected,
    required this.field,
    required this.dialog,
    required this.menu,
    required this.chip,
    required this.track,
    required this.divider,
    required this.rowDivider,
    required this.outline,
    required this.line,
    required this.control,
    required this.edge,
    required this.check,
    required this.menuBorder,
    required this.fieldBorder,
    required this.text,
    required this.textProse,
    required this.text2,
    required this.text3,
    required this.accent,
    required this.onAccent,
    required this.primary,
    required this.onPrimary,
    required this.link,
    required this.selected,
    required this.amber,
    required this.red,
    required this.onRed,
    required this.redText,
    required this.windowClose,
    required this.blue,
    required this.overlay,
    required this.badgeUpdate,
    required this.badgeMissing,
    required this.badgeInfo,
    required this.badgeNeutral,
    required this.elements,
    required this.grounds,
    required this.panel,
    required this.artworkScrim,
    required this.onArtwork,
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

  /// A row, a menu item or a sidebar entry under the pointer.
  final Color rowHover;

  /// The current sidebar entry.
  final Color rowSelected;

  /// Inputs and grouped settings rows.
  final Color field;

  final Color dialog;

  /// Menus and dropdowns.
  final Color menu;

  /// An unselected chip.
  final Color chip;

  /// The track of a switch that is off.
  final Color track;

  /// Between the chrome and the page.
  final Color divider;

  /// Between the rows of a group.
  final Color rowDivider;

  /// Around cards, groups and dialogs.
  final Color outline;

  /// Chips, badges and separators inside a surface.
  final Color line;

  /// Around buttons and fields.
  final Color control;

  /// Around a switch and a keycap, and a card under the pointer.
  final Color edge;

  /// Around a checkbox or a radio button that is off.
  final Color check;

  final Color menuBorder;
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

  /// Link text, the accent darkened a step on paper.
  final Color link;

  /// A selected chip or option.
  final TonePair selected;

  /// Updates.
  final Color amber;

  /// Missing folders and anything destructive.
  final Color red;
  final Color onRed;

  /// A destructive action drawn as an icon or text on a plain button, lighter than [red] so it reads at 16px.
  final Color redText;

  /// The title bar's close button under the pointer, with white on it.
  final Color windowClose;

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

  /// Dotted grounds, one per [ElementTone].
  final Map<ElementTone, ElementGround> grounds;

  /// A column beside the page: the Library's character list and details panel.
  final Color panel;

  /// Behind a control drawn over a mod's cover art, which is dark or light whatever the theme.
  final Color artworkScrim;

  /// A control drawn on [artworkScrim].
  final Color onArtwork;

  /// The accent washed into the card, behind something focused.
  Color get accentWash => Color.lerp(card, accent, 0.14)!;

  TonePair get badgeOn => TonePair(accent, onAccent);

  TonePair element(ElementTone tone) => elements[tone]!;

  ElementGround groundFor(ElementTone tone) => grounds[tone]!;

  /// The app's palette, or the default dark one where no app theme is installed (a bare test harness).
  static ZenithPalette of(BuildContext context) =>
      Theme.of(context).extension<ZenithPalette>() ?? ZenithPalette.dark(AccentChoice.violet);

  factory ZenithPalette.forBrightness(Brightness brightness, AccentChoice accent) =>
      brightness == Brightness.dark ? ZenithPalette.dark(accent) : ZenithPalette.light(accent);

  factory ZenithPalette.dark(AccentChoice accent) {
    const violet = Color(0xFFA98BFF);
    const paper = Color(0xFFF3EFEB);
    const ink = Color(0xFF15161C);
    const card = Color(0xFF121316);
    final accentColor = switch (accent) {
      AccentChoice.violet || AccentChoice.paper => violet,
      AccentChoice.lime => const Color(0xFFC8F031),
      AccentChoice.teal => const Color(0xFF5FE1D9),
    };
    const onAccent = Color(0xFF0B0C0E);
    final isPaper = accent == AccentChoice.paper;
    return ZenithPalette(
      brightness: Brightness.dark,
      chrome: const Color(0xFF0A0B0D),
      ground: const Color(0xFF0B0C0E),
      card: card,
      raised: const Color(0xFF1A1C20),
      hover: const Color(0xFF24272C),
      rowHover: const Color(0xFF17191D),
      rowSelected: const Color(0xFF1C1F24),
      field: const Color(0xFF101114),
      dialog: const Color(0xFF0F1012),
      menu: const Color(0xFF17191D),
      chip: const Color(0xFF15171A),
      track: const Color(0xFF22252A),
      divider: const Color(0xFF1E2024),
      rowDivider: const Color(0xFF1A1C20),
      outline: const Color(0xFF23262B),
      line: const Color(0xFF2A2D33),
      control: const Color(0xFF363A42),
      edge: const Color(0xFF3A3E46),
      check: const Color(0xFF4A4E57),
      menuBorder: const Color(0xFF33363D),
      fieldBorder: const Color(0xFF2F3239),
      text: const Color(0xFFECEDEE),
      textProse: const Color(0xFFC9CCD2),
      text2: const Color(0xFFA9ADB5),
      text3: const Color(0xFF80858F),
      accent: accentColor,
      onAccent: onAccent,
      primary: isPaper ? paper : accentColor,
      onPrimary: isPaper ? ink : onAccent,
      link: accentColor,
      selected: isPaper
          ? const TonePair(paper, ink, paper)
          : TonePair(
              Color.lerp(card, accentColor, 0.14)!,
              Color.lerp(accentColor, Colors.white, 0.3)!,
              Color.lerp(card, accentColor, 0.45),
            ),
      amber: const Color(0xFFFFB547),
      red: const Color(0xFFFF6B5B),
      onRed: const Color(0xFF160605),
      redText: const Color(0xFFFF8A7D),
      windowClose: const Color(0xFFC4352B),
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
        ElementTone.wind: TonePair(Color(0xFF0F2F24), Color(0xFF8EEBBF)),
        ElementTone.lumiflux: TonePair(Color(0xFF3A1626), Color(0xFFFFA3C7)),
        ElementTone.neutral: TonePair(Color(0xFF1E2126), Color(0xFFA9ADB5)),
      },
      grounds: const {
        ElementTone.ice: ElementGround(Color(0xFF0E1D25), Color(0xFF1F4556), Color(0xFF2A5568)),
        ElementTone.fire: ElementGround(Color(0xFF25130D), Color(0xFF552B19), Color(0xFF6E3820)),
        ElementTone.electric: ElementGround(Color(0xFF0F1730), Color(0xFF243F73), Color(0xFF2F5290)),
        ElementTone.ether: ElementGround(Color(0xFF21112A), Color(0xFF4E275E), Color(0xFF643478)),
        ElementTone.physical: ElementGround(Color(0xFF221E0D), Color(0xFF4F4519), Color(0xFF665A22)),
        ElementTone.wind: ElementGround(Color(0xFF0C1F18), Color(0xFF1D4A38), Color(0xFF27604A)),
        ElementTone.lumiflux: ElementGround(Color(0xFF24101A), Color(0xFF55253D), Color(0xFF6E304F)),
        ElementTone.neutral: ElementGround(Color(0xFF14161A), Color(0xFF2C3038), Color(0xFF3A3E46)),
      },
      panel: const Color(0xFF0D0E10),
      artworkScrim: const Color(0xA60B0C0E),
      onArtwork: const Color(0xFFC9CCD2),
    );
  }

  /// The paper theme. The accents are darkened to read on paper, and the primary button is ink whatever the accent.
  factory ZenithPalette.light(AccentChoice accent) {
    const ink = Color(0xFF15161C);
    const paper = Color(0xFFF3EFEB);
    final (accentColor, link, selected) = switch (accent) {
      AccentChoice.violet || AccentChoice.paper => (
        const Color(0xFF6B45D9),
        const Color(0xFF5A35C8),
        accent == AccentChoice.paper
            ? const TonePair(ink, paper, ink)
            : const TonePair(Color(0xFFE6DEFB), Color(0xFF3D2496), Color(0xFFB9A6F0)),
      ),
      AccentChoice.lime => (
        const Color(0xFF4D6A00),
        const Color(0xFF415A00),
        const TonePair(Color(0xFFE1E6D4), Color(0xFF2E4000), Color(0xFFAEBC8C)),
      ),
      AccentChoice.teal => (
        const Color(0xFF00736D),
        const Color(0xFF00625D),
        const TonePair(Color(0xFFD4E7E6), Color(0xFF00453F), Color(0xFF8CC0BD)),
      ),
    };
    return ZenithPalette(
      brightness: Brightness.light,
      chrome: const Color(0xFFE8E2DB),
      ground: const Color(0xFFEFEAE4),
      card: const Color(0xFFF8F5F1),
      raised: const Color(0xFFF8F5F1),
      hover: const Color(0xFFE9E3DC),
      rowHover: const Color(0xFFF2EDE7),
      rowSelected: const Color(0xFFF8F5F1),
      field: const Color(0xFFFBF9F6),
      dialog: const Color(0xFFF4F0EB),
      menu: const Color(0xFFFDFBF8),
      chip: const Color(0xFFF8F5F1),
      track: const Color(0xFFE2DBD3),
      divider: const Color(0xFFDCD5CD),
      rowDivider: const Color(0xFFE9E3DC),
      outline: const Color(0xFFDCD5CD),
      line: const Color(0xFFD3CBC2),
      control: const Color(0xFFCBC3BA),
      edge: const Color(0xFFBDB4AA),
      check: const Color(0xFF9C948B),
      menuBorder: const Color(0xFFD3CBC2),
      fieldBorder: const Color(0xFFD3CBC2),
      text: ink,
      textProse: const Color(0xFF2E2D33),
      text2: const Color(0xFF55525A),
      text3: const Color(0xFF67636B),
      accent: accentColor,
      onAccent: const Color(0xFFFFFFFF),
      primary: ink,
      onPrimary: paper,
      link: link,
      selected: selected,
      amber: const Color(0xFF9A5B00),
      red: const Color(0xFFC2361F),
      onRed: const Color(0xFFFFFFFF),
      redText: const Color(0xFFC2361F),
      windowClose: const Color(0xFFC4352B),
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
        ElementTone.wind: TonePair(Color(0xFFD3ECDF), Color(0xFF1C6644)),
        ElementTone.lumiflux: TonePair(Color(0xFFF4D6E2), Color(0xFF8C2353)),
        ElementTone.neutral: TonePair(Color(0xFFE4DED7), Color(0xFF55525A)),
      },
      grounds: const {
        ElementTone.ice: ElementGround(Color(0xFFDCEAF0), Color(0xFFB9D4DF), Color(0xFF9DC0CF)),
        ElementTone.fire: ElementGround(Color(0xFFF3DFD5), Color(0xFFE2BBA8), Color(0xFFD4A08A)),
        ElementTone.electric: ElementGround(Color(0xFFDDE3F4), Color(0xFFBCC8EA), Color(0xFF9FB0DE)),
        ElementTone.ether: ElementGround(Color(0xFFEBDDF1), Color(0xFFD3B8E0), Color(0xFFC29ED4)),
        ElementTone.physical: ElementGround(Color(0xFFEEE6CC), Color(0xFFDACB98), Color(0xFFC9B676)),
        ElementTone.wind: ElementGround(Color(0xFFD9EEE3), Color(0xFFB2DBC5), Color(0xFF91CBAB)),
        ElementTone.lumiflux: ElementGround(Color(0xFFF4DCE5), Color(0xFFE5B6C8), Color(0xFFD697B0)),
        ElementTone.neutral: ElementGround(Color(0xFFE6E0D9), Color(0xFFD0C8BF), Color(0xFFBDB4AA)),
      },
      panel: const Color(0xFFECE6E0),
      artworkScrim: const Color(0xA60B0C0E),
      onArtwork: const Color(0xFFC9CCD2),
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
    rowHover: rowHover,
    rowSelected: rowSelected,
    field: field,
    dialog: dialog,
    menu: menu,
    chip: chip,
    track: track,
    divider: divider,
    rowDivider: rowDivider,
    outline: outline,
    line: line,
    control: control,
    edge: edge,
    check: check,
    menuBorder: menuBorder,
    fieldBorder: fieldBorder,
    text: text,
    textProse: textProse,
    text2: text2,
    text3: text3,
    accent: accent ?? this.accent,
    onAccent: onAccent ?? this.onAccent,
    primary: primary ?? this.primary,
    onPrimary: onPrimary ?? this.onPrimary,
    link: link,
    selected: selected,
    amber: amber,
    red: red,
    onRed: onRed,
    redText: redText,
    windowClose: windowClose,
    blue: blue,
    overlay: overlay,
    badgeUpdate: badgeUpdate,
    badgeMissing: badgeMissing,
    badgeInfo: badgeInfo,
    badgeNeutral: badgeNeutral,
    elements: elements,
    grounds: grounds,
    panel: panel,
    artworkScrim: artworkScrim,
    onArtwork: onArtwork,
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
      rowHover: c(rowHover, other.rowHover),
      rowSelected: c(rowSelected, other.rowSelected),
      field: c(field, other.field),
      dialog: c(dialog, other.dialog),
      menu: c(menu, other.menu),
      chip: c(chip, other.chip),
      track: c(track, other.track),
      divider: c(divider, other.divider),
      rowDivider: c(rowDivider, other.rowDivider),
      outline: c(outline, other.outline),
      line: c(line, other.line),
      control: c(control, other.control),
      edge: c(edge, other.edge),
      check: c(check, other.check),
      menuBorder: c(menuBorder, other.menuBorder),
      fieldBorder: c(fieldBorder, other.fieldBorder),
      text: c(text, other.text),
      textProse: c(textProse, other.textProse),
      text2: c(text2, other.text2),
      text3: c(text3, other.text3),
      accent: c(accent, other.accent),
      onAccent: c(onAccent, other.onAccent),
      primary: c(primary, other.primary),
      onPrimary: c(onPrimary, other.onPrimary),
      link: c(link, other.link),
      selected: TonePair.lerp(selected, other.selected, t),
      amber: c(amber, other.amber),
      red: c(red, other.red),
      onRed: c(onRed, other.onRed),
      redText: c(redText, other.redText),
      windowClose: c(windowClose, other.windowClose),
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
      grounds: {
        for (final tone in ElementTone.values)
          tone: ElementGround.lerp(grounds[tone]!, other.grounds[tone]!, t),
      },
      panel: c(panel, other.panel),
      artworkScrim: c(artworkScrim, other.artworkScrim),
      onArtwork: c(onArtwork, other.onArtwork),
    );
  }
}
