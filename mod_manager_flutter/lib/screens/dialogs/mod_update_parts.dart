import 'package:flutter/material.dart';

import '../../core/palette.dart';
import '../../core/type_scale.dart';

/// A line of 12px grey text under a block of the update dialog: a caveat, a hint, a note. [prose] sets it at the
/// 13px body size in the reading colour, for a sentence that is the point of its block.
class UpdateHint extends StatelessWidget {
  const UpdateHint(this.text, {super.key, this.prose = false});

  final String text;
  final bool prose;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    final style = prose ? Theme.of(context).textTheme.bodyMedium : Theme.of(context).textTheme.bodySmall;
    return Text(text, style: style?.copyWith(color: prose ? palette.textProse : palette.text3));
  }
}

/// A group of rows under its caps label (the boards' `.lbl`): "You have", "Newer on GameBanana". [caption] is a grey line under it.
class UpdateGroup extends StatelessWidget {
  const UpdateGroup({super.key, required this.label, required this.child, this.caption});

  final String label;
  final Widget child;
  final String? caption;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    spacing: 6,
    children: [
      Semantics(
        header: true,
        child: Text(label.toUpperCase(), style: ZenithType.of(context).caps.copyWith(color: ZenithPalette.of(context).text3)),
      ),
      child,
      if (caption case final caption?) UpdateHint(caption),
    ],
  );
}

/// A line of information in the blue pair, above the files, for a state the user is in rather than a fact about them.
class UpdateStrip extends StatelessWidget {
  const UpdateStrip(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final tone = ZenithPalette.of(context).badgeInfo;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: tone.background,
        borderRadius: BorderRadius.circular(10),
        border: tone.border == null ? null : Border.all(color: tone.border!),
      ),
      child: Text(text, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tone.foreground)),
    );
  }
}

/// The wait for the check to answer.
class UpdateSpinner extends StatelessWidget {
  const UpdateSpinner({super.key});

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(vertical: 24),
    child: Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))),
  );
}
