import 'package:flutter/material.dart';

import '../../core/palette.dart';
import '../../core/type_scale.dart';

/// A key drawn as a keycap, such as F10 or Ctrl.
class Keycap extends StatelessWidget {
  const Keycap(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: palette.raised,
        borderRadius: BorderRadius.circular(5),
        border: Border(
          top: BorderSide(color: palette.control),
          left: BorderSide(color: palette.control),
          right: BorderSide(color: palette.control),
          bottom: BorderSide(color: palette.control, width: 2),
        ),
      ),
      child: Text(label, style: ZenithType.of(context).monoSmall.copyWith(color: palette.textProse)),
    );
  }
}

/// A translated sentence with a keycap where its `{key}` placeholder is, as spans for a `Text.rich`.
///
/// The placeholder rather than two halves, so each language puts the key where its own word order wants it.
List<InlineSpan> keycapSentence(BuildContext context, String sentence, String key) {
  final parts = sentence.split('{key}');
  return [
    for (var i = 0; i < parts.length; i++) ...[
      if (parts[i].isNotEmpty) TextSpan(text: parts[i]),
      if (i < parts.length - 1)
        WidgetSpan(alignment: PlaceholderAlignment.middle, child: Keycap(key)),
    ],
  ];
}
