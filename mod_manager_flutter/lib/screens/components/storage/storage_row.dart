import 'package:flutter/material.dart';

import '../../../core/palette.dart';
import '../../../core/type_scale.dart';

/// One category of the Storage section: its colour, what it is, what it holds, how much it takes and what can be done about it.
///
/// A row narrower than [stackBelow] puts its buttons under the text, since the size and the percentage keep their width and would squeeze the description into a sliver.
class StorageRow extends StatelessWidget {
  const StorageRow({
    super.key,
    required this.color,
    required this.name,
    required this.description,
    required this.size,
    required this.percent,
    required this.actions,
    required this.highlighted,
    required this.onHover,
    this.detail,
  });

  final Color color;
  final String name;
  final String description;

  /// The size as words: `7.9 GB`, `at least 7.9 GB`, or why there is none.
  final String size;
  final String percent;
  final List<Widget> actions;

  /// The row's category is the one pointed at on the meter or on this row.
  final bool highlighted;
  final ValueChanged<bool> onHover;

  /// Drawn under the row, such as the saved versions it lists.
  final Widget? detail;

  /// The row's width under which its buttons sit below the text.
  static const double stackBelow = 560;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final mono = ZenithType.of(context).mono;
    // The size is 13px mono, the body size in the mono face.
    final sizeStyle = text.bodyMedium?.copyWith(fontFamily: kMonoFont, fontWeight: FontWeight.w500, color: palette.text);

    final label = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 2,
      children: [
        Text(name, style: text.bodyMedium?.copyWith(color: palette.text, fontWeight: FontWeight.w600)),
        Text(description, style: text.bodySmall?.copyWith(color: palette.text3)),
      ],
    );
    final sizeText = ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 88),
      child: Text(size, textAlign: TextAlign.right, style: sizeStyle),
    );
    final percentText = ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 52),
      child: Text(percent, textAlign: TextAlign.right, style: mono.copyWith(color: palette.text3)),
    );
    // The canvas sets the 12px dot in a 14px column.
    final dot = SizedBox(
      width: 14,
      child: Align(
        alignment: Alignment.centerLeft,
        child: DecoratedBox(
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3)),
          child: const SizedBox.square(dimension: 12),
        ),
      ),
    );

    return MouseRegion(
      onEnter: (_) => onHover(true),
      onExit: (_) => onHover(false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        color: highlighted ? palette.chip : Colors.transparent,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  if (constraints.maxWidth < stackBelow) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      spacing: 10,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          spacing: 14,
                          children: [
                            Padding(padding: const EdgeInsets.only(top: 3), child: dot),
                            Expanded(child: label),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              spacing: 2,
                              children: [sizeText, percentText],
                            ),
                          ],
                        ),
                        Padding(
                          padding: const EdgeInsets.only(left: 28),
                          child: Wrap(spacing: 6, runSpacing: 6, children: actions),
                        ),
                      ],
                    );
                  }
                  return Row(
                    spacing: 16,
                    children: [
                      dot,
                      Expanded(child: label),
                      sizeText,
                      percentText,
                      Row(mainAxisSize: MainAxisSize.min, spacing: 6, children: actions),
                    ],
                  );
                },
              ),
            ),
            ?detail,
          ],
        ),
      ),
    );
  }
}
