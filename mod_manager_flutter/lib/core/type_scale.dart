import 'package:flutter/material.dart';

/// Raises Material's type scale by 2px, making body text 16 rather than 14.
///
/// Text sizes come from roles on the text theme, never pixel literals, so this is the one place the app's scale is set.
/// The widget-test harness applies it as well, so a layout test measures the text the app actually renders.
/// Markdown keeps its own scale in `MarkdownScale`, built on the same 16px body.
///
/// The delta goes on the typography's geometry because a built theme's text theme carries only colours:
/// sizes are merged in from the geometry when the theme is localized.
ThemeData withAppTypeScale(ThemeData theme) => theme.copyWith(
  typography: Typography.material2021(
    platform: theme.platform,
    colorScheme: theme.colorScheme,
    englishLike: Typography.englishLike2021.apply(fontSizeDelta: 2),
    dense: Typography.dense2021.apply(fontSizeDelta: 2),
    tall: Typography.tall2021.apply(fontSizeDelta: 2),
  ),
);
