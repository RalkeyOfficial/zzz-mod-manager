import 'package:flutter/material.dart';

import 'palette.dart';
import 'type_scale.dart';

/// Builds the app's theme from a [ZenithPalette]: the Material colour scheme, every component theme the design
/// specifies, the type scale, and the palette itself as an extension for what Material has no slot for.
///
/// Sizes in here are geometry from the design (control heights, radii, padding). Text sizes come from
/// `type_scale.dart` only.
ThemeData buildAppTheme({required Brightness brightness, required AccentChoice accent}) {
  final p = ZenithPalette.forBrightness(brightness, accent);
  final text = appTextGeometry();

  final scheme = ColorScheme(
    brightness: brightness,
    primary: p.primary,
    onPrimary: p.onPrimary,
    primaryContainer: p.selected.background,
    onPrimaryContainer: p.selected.foreground,
    secondary: p.accent,
    onSecondary: p.onAccent,
    secondaryContainer: p.accentWash,
    onSecondaryContainer: Color.lerp(p.accent, p.text, 0.3),
    tertiary: p.blue,
    onTertiary: p.ground,
    error: p.red,
    onError: p.onRed,
    errorContainer: p.badgeMissing.background,
    onErrorContainer: p.badgeMissing.foreground,
    surface: p.ground,
    onSurface: p.text,
    onSurfaceVariant: p.text2,
    surfaceContainerLowest: p.chrome,
    surfaceContainerLow: p.field,
    surfaceContainer: p.card,
    surfaceContainerHigh: p.raised,
    surfaceContainerHighest: p.hover,
    outline: p.control,
    outlineVariant: p.outline,
    shadow: Colors.black,
    scrim: p.overlay,
    inverseSurface: p.text,
    onInverseSurface: p.ground,
    inversePrimary: p.accent,
    surfaceTint: Colors.transparent,
  );

  RoundedRectangleBorder rounded(double radius, [Color? side]) => RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(radius),
    side: side == null ? BorderSide.none : BorderSide(color: side),
  );

  // Buttons: 36px tall, 8px corners, 16px icons. The secondary button is the default shape; primary fills with
  // p.primary, ghost drops the fill and the border, danger fills red.
  const buttonPadding = EdgeInsets.symmetric(horizontal: 14);
  const buttonSize = Size(36, 36);
  const iconSize = WidgetStatePropertyAll(16.0);
  final buttonText = WidgetStatePropertyAll(text.labelLarge);

  WidgetStateProperty<Color?> onHover(Color idle, Color hovered) =>
      WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.hovered) ? hovered : idle);
  WidgetStateProperty<Color?> disabledOr(Color enabled, Color disabled) =>
      WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.disabled) ? disabled : enabled);

  // Keyboard focus draws a 2px accent ring 2px out from the button, the canvas's `:focus-visible` outline: the gap
  // keeps it visible around a primary button filled in the accent. A click never focuses a button, so it draws none.
  // Unfocused, [idle] is the button's own border, and null keeps whatever border a local shape carries.
  final focusRing = BorderSide(color: p.accent, width: 2, strokeAlign: 3);
  WidgetStateProperty<BorderSide?> ringOr(BorderSide? idle) => WidgetStateProperty.resolveWith(
    (states) =>
        states.contains(WidgetState.focused) && FocusManager.instance.highlightMode == FocusHighlightMode.traditional
        ? focusRing
        : idle,
  );

  final secondaryButton = ButtonStyle(
    minimumSize: const WidgetStatePropertyAll(buttonSize),
    padding: const WidgetStatePropertyAll(buttonPadding),
    textStyle: buttonText,
    iconSize: iconSize,
    shape: WidgetStatePropertyAll(rounded(8)),
    side: ringOr(BorderSide(color: p.control)),
    backgroundColor: onHover(p.raised, p.hover),
    foregroundColor: disabledOr(p.text, p.text3),
    overlayColor: const WidgetStatePropertyAll(Colors.transparent),
    elevation: const WidgetStatePropertyAll(0),
  );

  final primaryButton = ButtonStyle(
    minimumSize: const WidgetStatePropertyAll(buttonSize),
    padding: const WidgetStatePropertyAll(buttonPadding),
    textStyle: WidgetStatePropertyAll(text.labelLarge!.copyWith(fontWeight: FontWeight.w600)),
    iconSize: iconSize,
    shape: WidgetStatePropertyAll(rounded(8)),
    // Disabled is the whole button at 45%, as the design fades it.
    backgroundColor: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.disabled)) return p.primary.withValues(alpha: 0.45);
      if (states.contains(WidgetState.hovered)) return primaryHover(p);
      return p.primary;
    }),
    foregroundColor: disabledOr(p.onPrimary, p.onPrimary.withValues(alpha: 0.45)),
    side: ringOr(null),
    overlayColor: const WidgetStatePropertyAll(Colors.transparent),
    elevation: const WidgetStatePropertyAll(0),
  );

  final ghostButton = ButtonStyle(
    minimumSize: const WidgetStatePropertyAll(buttonSize),
    padding: const WidgetStatePropertyAll(buttonPadding),
    textStyle: buttonText,
    iconSize: iconSize,
    shape: WidgetStatePropertyAll(rounded(8)),
    backgroundColor: onHover(Colors.transparent, p.raised),
    foregroundColor: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.disabled)) return p.text3;
      if (states.contains(WidgetState.hovered)) return p.text;
      return p.text2;
    }),
    side: ringOr(null),
    overlayColor: const WidgetStatePropertyAll(Colors.transparent),
  );

  OutlineInputBorder fieldBorder(Color color) =>
      OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: color));

  // Fields are 36px tall. A TextField sets its text in bodyLarge, so the padding is what is left of 36 around one
  // line of it; the minimum height keeps a field with smaller text at 36 too, and the icon boxes are cut from
  // Material's 48 to the same height.
  const fieldHeight = 36.0;
  final fieldLine = text.bodyLarge!.fontSize! * text.bodyLarge!.height!;
  final fieldPadding = EdgeInsets.symmetric(horizontal: 12, vertical: (fieldHeight - fieldLine) / 2);

  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    fontFamily: kUiFont,
    scaffoldBackgroundColor: p.ground,
    canvasColor: p.ground,
    cardColor: p.card,
    dividerColor: p.line,
    hoverColor: p.rowHover,
    focusColor: p.accentWash,
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    visualDensity: VisualDensity.standard,
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    extensions: [p],
    cardTheme: CardThemeData(
      color: p.card,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: rounded(12, p.outline),
      clipBehavior: Clip.antiAlias,
    ),
    dividerTheme: DividerThemeData(color: p.divider, thickness: 1, space: 1),
    filledButtonTheme: FilledButtonThemeData(style: primaryButton),
    elevatedButtonTheme: ElevatedButtonThemeData(style: secondaryButton),
    outlinedButtonTheme: OutlinedButtonThemeData(style: secondaryButton),
    textButtonTheme: TextButtonThemeData(style: ghostButton),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(buttonSize),
        iconSize: iconSize,
        shape: WidgetStatePropertyAll(rounded(8)),
        backgroundColor: onHover(Colors.transparent, p.raised),
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) return p.text3;
          if (states.contains(WidgetState.selected)) return p.accent;
          if (states.contains(WidgetState.hovered)) return p.text;
          return p.text2;
        }),
        side: ringOr(null),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
    ),
    iconTheme: IconThemeData(color: p.text2, size: 16),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.field,
      isDense: true,
      contentPadding: fieldPadding,
      constraints: const BoxConstraints(minHeight: fieldHeight),
      prefixIconConstraints: const BoxConstraints(minWidth: fieldHeight, minHeight: fieldHeight),
      suffixIconConstraints: const BoxConstraints(minWidth: fieldHeight, minHeight: fieldHeight),
      hintStyle: text.bodyMedium!.copyWith(color: p.text3),
      labelStyle: text.bodyMedium!.copyWith(color: p.text2),
      helperStyle: text.bodySmall!.copyWith(color: p.text3),
      prefixIconColor: p.text3,
      suffixIconColor: p.text3,
      border: fieldBorder(p.fieldBorder),
      enabledBorder: fieldBorder(p.fieldBorder),
      focusedBorder: fieldBorder(Color.lerp(p.fieldBorder, p.accent, 0.6)!),
      errorBorder: fieldBorder(p.red),
      focusedErrorBorder: fieldBorder(p.red),
      disabledBorder: fieldBorder(p.outline),
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: p.accent,
      selectionColor: p.accent.withValues(alpha: 0.3),
      selectionHandleColor: p.accent,
    ),
    // The app's switches are `ZenithSwitch`, drawn at the design's 38×22, which Material's switch cannot be. These
    // colours only keep a stray Material one from looking foreign.
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? p.onAccent : p.text3,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? p.accent : p.track,
      ),
      trackOutlineColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? p.accent : p.edge,
      ),
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    checkboxTheme: CheckboxThemeData(
      shape: rounded(5),
      side: BorderSide(color: p.check, width: 1.5),
      fillColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? p.accent : Colors.transparent,
      ),
      checkColor: WidgetStatePropertyAll(p.onAccent),
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? p.accent : p.check,
      ),
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: p.chip,
      selectedColor: p.selected.background,
      disabledColor: p.chip,
      side: WidgetStateBorderSide.resolveWith(
        (states) => BorderSide(color: states.contains(WidgetState.selected) ? p.selected.border! : p.line),
      ),
      shape: const StadiumBorder(),
      labelStyle: text.labelMedium!.copyWith(color: p.text2),
      secondaryLabelStyle: text.labelMedium!.copyWith(color: p.selected.foreground),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      showCheckmark: false,
      checkmarkColor: p.selected.foreground,
      iconTheme: IconThemeData(color: p.text2, size: 14),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(0, 30)),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 14)),
        textStyle: WidgetStatePropertyAll(text.labelMedium),
        shape: WidgetStatePropertyAll(rounded(7)),
        side: WidgetStatePropertyAll(BorderSide(color: p.outline)),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? p.hover : p.ground,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? p.text : p.text2,
        ),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: p.text,
      unselectedLabelColor: p.text2,
      labelStyle: text.labelLarge,
      unselectedLabelStyle: text.labelLarge,
      indicatorColor: p.accent,
      indicatorSize: TabBarIndicatorSize.label,
      dividerColor: p.divider,
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.dialog,
      surfaceTintColor: Colors.transparent,
      elevation: 24,
      shadowColor: Colors.black.withValues(alpha: 0.6),
      barrierColor: p.overlay,
      shape: rounded(18, p.line),
      titleTextStyle: text.headlineSmall!.copyWith(color: p.text),
      contentTextStyle: text.bodyMedium!.copyWith(color: p.text2),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: p.menu,
      surfaceTintColor: Colors.transparent,
      elevation: 12,
      shape: rounded(12, p.menuBorder),
      textStyle: text.bodyMedium!.copyWith(color: p.text),
      labelTextStyle: WidgetStatePropertyAll(text.bodyMedium!.copyWith(color: p.text)),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(p.menu),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(12),
        // None, so an item's hover fills the menu edge to edge; the menu clips it to the rounded corners.
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
        shape: WidgetStatePropertyAll(rounded(12, p.menuBorder)),
      ),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: p.hover,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: p.control),
      ),
      textStyle: text.bodySmall!.copyWith(color: p.text),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      waitDuration: const Duration(milliseconds: 400),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: p.text2,
      textColor: p.text,
      selectedColor: p.text,
      selectedTileColor: p.raised,
      shape: rounded(8),
      dense: true,
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStatePropertyAll(p.line),
      thickness: const WidgetStatePropertyAll(6),
      radius: const Radius.circular(3),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: p.accent,
      linearTrackColor: p.raised,
      circularTrackColor: Colors.transparent,
      linearMinHeight: 6,
      borderRadius: BorderRadius.circular(99),
    ),
    badgeTheme: BadgeThemeData(
      backgroundColor: p.badgeUpdate.background,
      textColor: p.badgeUpdate.foreground,
      textStyle: text.labelSmall,
    ),
  );

  return withAppTypeScale(base);
}

/// The primary button under the pointer: the design's `brightness(1.08)`. Scaling ink's channels leaves it ink, so
/// on paper the button is lifted toward white instead.
Color primaryHover(ZenithPalette p) {
  if (p.brightness == Brightness.light) return Color.lerp(p.primary, Colors.white, 0.14)!;
  double up(double channel) => (channel * 1.08).clamp(0.0, 1.0);
  return Color.from(alpha: p.primary.a, red: up(p.primary.r), green: up(p.primary.g), blue: up(p.primary.b));
}
