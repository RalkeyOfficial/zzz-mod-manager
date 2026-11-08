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
          top: BorderSide(color: palette.edge),
          left: BorderSide(color: palette.edge),
          right: BorderSide(color: palette.edge),
          bottom: BorderSide(color: palette.edge, width: 2),
        ),
      ),
      child: Text(label, style: ZenithType.of(context).monoSmall.copyWith(color: palette.textProse)),
    );
  }
}

/// A translated sentence with a keycap where its `{key}` placeholder is, as spans for a `Text.rich`.
///
/// The placeholder rather than two halves, so each language puts the key where its own word order wants it.
List<InlineSpan> keycapSentence(BuildContext context, String sentence, String key) =>
    placeholderSentence(sentence, {'key': WidgetSpan(alignment: PlaceholderAlignment.middle, child: Keycap(key))});

/// A translated [sentence] with each `{name}` in [spans] replaced by its span, as spans for a `Text.rich`: a file
/// name in mono, a keycap. A placeholder [spans] has no entry for stays as written.
List<InlineSpan> placeholderSentence(String sentence, Map<String, InlineSpan> spans) {
  final result = <InlineSpan>[];
  var rest = sentence;
  while (rest.isNotEmpty) {
    final next = RegExp(r'\{(\w+)\}').allMatches(rest).where((m) => spans.containsKey(m.group(1))).firstOrNull;
    if (next == null) {
      result.add(TextSpan(text: rest));
      break;
    }
    if (next.start > 0) result.add(TextSpan(text: rest.substring(0, next.start)));
    result.add(spans[next.group(1)]!);
    rest = rest.substring(next.end);
  }
  return result;
}
