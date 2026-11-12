import 'package:flutter/material.dart';

import '../../core/palette.dart';

/// A rounded bar on the track colour: [value] filled in the accent, or a sweep when null, for work that reports no
/// fraction. [dimmed] for one not moving. [sweepColor] is the sweep's, the accent's by default.
///
/// The Downloads panel's row bar and the Updates page's mini bar.
class ProgressTrack extends StatelessWidget {
  const ProgressTrack({super.key, required this.value, required this.height, this.dimmed = false, this.sweepColor});

  final double? value;
  final double height;
  final bool dimmed;
  final Color? sweepColor;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    final fill = palette.accent.withValues(alpha: dimmed ? 0.4 : 1);
    final value = this.value;
    return ClipRRect(
      borderRadius: BorderRadius.circular(99),
      child: SizedBox(
        height: height,
        child: ColoredBox(
          color: palette.track,
          child: value == null
              ? _Sweep(color: sweepColor ?? palette.accent.withValues(alpha: 0.7))
              : Align(
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: value.clamp(0.0, 1.0),
                    heightFactor: 1,
                    child: DecoratedBox(
                      decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(99)),
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}

/// A third of the bar running across it.
class _Sweep extends StatefulWidget {
  const _Sweep({required this.color});

  final Color color;

  @override
  State<_Sweep> createState() => _SweepState();
}

class _SweepState extends State<_Sweep> with SingleTickerProviderStateMixin {
  late final AnimationController _run =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat();

  @override
  void dispose() {
    _run.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          final span = constraints.maxWidth * 0.35;
          return AnimatedBuilder(
            animation: _run,
            builder: (context, _) => Stack(
              children: [
                Positioned(
                  left: -span + (constraints.maxWidth + span) * _run.value,
                  top: 0,
                  bottom: 0,
                  width: span,
                  child: DecoratedBox(
                    decoration: BoxDecoration(color: widget.color, borderRadius: BorderRadius.circular(99)),
                  ),
                ),
              ],
            ),
          );
        },
      );
}
