import 'package:flutter/material.dart';

import '../../../core/palette.dart';
import '../../../core/type_scale.dart';
import '../../../l10n/app_localizations.dart';
import '../settings/settings_widgets.dart';

/// One row of the Largest mods list, in the words it shows.
class LargestModView {
  const LargestModView({
    required this.name,
    required this.detail,
    required this.size,
    required this.fraction,
    required this.onOpen,
  });

  final String name;

  /// The line under the name: the character and how many saved versions.
  final String detail;

  /// The size, or "Linked elsewhere" for a mod whose folder lives elsewhere.
  final String size;

  /// How wide the bar is, against the largest of the list.
  final double fraction;

  /// Opens the mod's page, or null for a mod the library does not hold.
  final VoidCallback? onOpen;
}

/// The mods that take the most, each a button to its page.
class LargestMods extends StatelessWidget {
  const LargestMods({super.key, required this.rows});

  final List<LargestModView> rows;

  /// The row's width under which the bar is left out.
  static const double barBelow = 460;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final sizeWidth = rows.any((row) => row.size.length > 10) ? 120.0 : 88.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 12,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          spacing: 12,
          children: [
            Semantics(
              header: true,
              child: Text(loc.t('storage.largest.title'), style: text.titleMedium?.copyWith(color: palette.text)),
            ),
            Expanded(
              child: Text(
                loc.t('storage.largest.subtitle'),
                textAlign: TextAlign.right,
                style: text.bodySmall?.copyWith(color: palette.text3),
              ),
            ),
          ],
        ),
        SettingsGroup(
          children: [for (final row in rows) _Row(row: row, sizeWidth: sizeWidth)],
        ),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.row, required this.sizeWidth});

  final LargestModView row;
  final double sizeWidth;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;

    final label = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          row.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: text.bodyMedium?.copyWith(color: palette.text, fontWeight: FontWeight.w600),
        ),
        Text(
          row.detail,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: text.bodySmall?.copyWith(color: palette.text3),
        ),
      ],
    );

    return Semantics(
      button: row.onOpen != null,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: row.onOpen,
          hoverColor: palette.rowHover,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final bar = constraints.maxWidth >= LargestMods.barBelow;
                return Row(
                  spacing: 16,
                  children: [
                    Expanded(flex: 13, child: label),
                    if (bar)
                      Expanded(
                        flex: 10,
                        child: LinearProgressIndicator(
                          value: row.fraction.clamp(0.0, 1.0),
                          minHeight: 6,
                          // Rounds the fill's end as well as the track's, which a clip around the bar would not.
                          borderRadius: BorderRadius.circular(99),
                          backgroundColor: palette.barTrack,
                          color: palette.storageCategories[0],
                        ),
                      ),
                    SizedBox(
                      width: sizeWidth,
                      child: Text(
                        row.size,
                        textAlign: TextAlign.right,
                        style: text.bodyMedium?.copyWith(fontFamily: kMonoFont, color: palette.text),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
