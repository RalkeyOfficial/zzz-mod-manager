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
    primaryContainer: p.accentWash,
    onPrimaryContainer: p.accentText,
    secondary: p.accent,
    onSecondary: p.onAccent,
    secondaryContainer: p.accentWash,
    onSecondaryContainer: p.accentText,
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

  // Buttons: 36px tall, 8px corners. The secondary button is the default shape; primary fills with the accent,
  // ghost drops the fill and the border, danger fills red.
  const buttonPadding = EdgeInsets.symmetric(horizontal: 14);
  const buttonSize = Size(36, 36);
  final buttonText = WidgetStatePropertyAll(text.labelLarge);

  WidgetStateProperty<Color?> onHover(Color idle, Color hovered) =>
      WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.hovered) ? hovered : idle);
  WidgetStateProperty<Color?> disabledOr(Color enabled, Color disabled) =>
      WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.disabled) ? disabled : enabled);

  final secondaryButton = ButtonStyle(
    minimumSize: const WidgetStatePropertyAll(buttonSize),
    padding: const WidgetStatePropertyAll(buttonPadding),
    textStyle: buttonText,
    shape: WidgetStatePropertyAll(rounded(8)),
    side: WidgetStatePropertyAll(BorderSide(color: p.control)),
    backgroundColor: onHover(p.raised, p.hover),
    foregroundColor: disabledOr(p.text, p.text3),
    overlayColor: const WidgetStatePropertyAll(Colors.transparent),
    elevation: const WidgetStatePropertyAll(0),
  );

  final primaryButton = ButtonStyle(
    minimumSize: const WidgetStatePropertyAll(buttonSize),
    padding: const WidgetStatePropertyAll(buttonPadding),
    textStyle: WidgetStatePropertyAll(text.labelLarge!.copyWith(fontWeight: FontWeight.w600)),
    shape: WidgetStatePropertyAll(rounded(8)),
    backgroundColor: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.disabled)) return p.raised;
      if (states.contains(WidgetState.hovered)) return Color.lerp(p.primary, p.text, 0.08);
      return p.primary;
    }),
    foregroundColor: disabledOr(p.onPrimary, p.text3),
    overlayColor: const WidgetStatePropertyAll(Colors.transparent),
    elevation: const WidgetStatePropertyAll(0),
  );

  final ghostButton = ButtonStyle(
    minimumSize: const WidgetStatePropertyAll(buttonSize),
    padding: const WidgetStatePropertyAll(buttonPadding),
    textStyle: buttonText,
    shape: WidgetStatePropertyAll(rounded(8)),
    backgroundColor: onHover(Colors.transparent, p.raised),
    foregroundColor: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.disabled)) return p.text3;
      if (states.contains(WidgetState.hovered)) return p.text;
      return p.text2;
    }),
    overlayColor: const WidgetStatePropertyAll(Colors.transparent),
  );

  OutlineInputBorder fieldBorder(Color color) =>
      OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: color));

  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    fontFamily: kUiFont,
    scaffoldBackgroundColor: p.ground,
    canvasColor: p.ground,
    cardColor: p.card,
    dividerColor: p.line,
    hoverColor: p.raised,
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
        shape: WidgetStatePropertyAll(rounded(8)),
        backgroundColor: onHover(Colors.transparent, p.raised),
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) return p.text3;
          if (states.contains(WidgetState.selected)) return p.accent;
          if (states.contains(WidgetState.hovered)) return p.text;
          return p.text2;
        }),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
    ),
    iconTheme: IconThemeData(color: p.text2, size: 18),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.field,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? p.onAccent : p.text3,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? p.accent : p.raised,
      ),
      trackOutlineColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? p.accent : p.control,
      ),
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    checkboxTheme: CheckboxThemeData(
      shape: rounded(5),
      side: BorderSide(color: p.text3, width: 1.5),
      fillColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? p.accent : Colors.transparent,
      ),
      checkColor: WidgetStatePropertyAll(p.onAccent),
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? p.accent : p.text3,
      ),
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: p.card,
      selectedColor: p.accentWash,
      disabledColor: p.card,
      side: WidgetStateBorderSide.resolveWith(
        (states) => BorderSide(color: states.contains(WidgetState.selected) ? p.accentEdge : p.line),
      ),
      shape: const StadiumBorder(),
      labelStyle: text.labelMedium!.copyWith(color: p.text2),
      secondaryLabelStyle: text.labelMedium!.copyWith(color: p.accentText),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      showCheckmark: false,
      checkmarkColor: p.accentText,
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
      backgroundColor: p.field,
      surfaceTintColor: Colors.transparent,
      elevation: 24,
      shadowColor: Colors.black.withValues(alpha: 0.6),
      barrierColor: p.overlay,
      shape: rounded(18, p.line),
      titleTextStyle: text.headlineSmall!.copyWith(color: p.text),
      contentTextStyle: text.bodyMedium!.copyWith(color: p.text2),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: p.raised,
      surfaceTintColor: Colors.transparent,
      elevation: 12,
      shape: rounded(12, p.control),
      textStyle: text.bodyMedium!.copyWith(color: p.text),
      labelTextStyle: WidgetStatePropertyAll(text.bodyMedium!.copyWith(color: p.text)),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(p.raised),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(12),
        padding: const WidgetStatePropertyAll(EdgeInsets.all(6)),
        shape: WidgetStatePropertyAll(rounded(12, p.control)),
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
