import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../services/storage/storage_usage.dart';

/// One arc of the ring.
class DonutSlice {
  const DonutSlice({
    required this.id,
    required this.bytes,
    required this.color,
  });

  final StorageCategoryId id;
  final int bytes;
  final Color color;
}

/// The breakdown as a ring, with the total in the hole.
///
/// Hand-painted because the project carries no charting package and one arc is
/// not worth adding a dependency for.
///
/// **Sweeps come from [donutSweeps], not from the raw proportions**, so a
/// category thousands of times smaller than the biggest is still a visible
/// sliver. The ring answers "roughly what is this made of"; the legend beside
/// it carries the figures, and it is the legend that is exact.
class StorageDonut extends StatelessWidget {
  const StorageDonut({
    super.key,
    required this.slices,
    required this.centerLabel,
    required this.centerCaption,
    this.diameter = 200,
    this.thickness = 26,
  });

  final List<DonutSlice> slices;

  /// The total, already formatted.
  final String centerLabel;
  final String centerCaption;

  final double diameter;
  final double thickness;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final empty = slices.every((slice) => slice.bytes <= 0);

    return SizedBox(
      width: diameter,
      height: diameter,
      child: CustomPaint(
        painter: _DonutPainter(
          slices: slices,
          thickness: thickness,
          emptyColor: theme.dividerColor.withValues(alpha: 0.35),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                centerLabel,
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 2),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  centerCaption,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.textTheme.bodySmall?.color
                        ?.withValues(alpha: empty ? 0.5 : 0.75),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DonutPainter extends CustomPainter {
  _DonutPainter({
    required this.slices,
    required this.thickness,
    required this.emptyColor,
  });

  final List<DonutSlice> slices;
  final double thickness;
  final Color emptyColor;

  /// A hair of background between arcs, so two adjacent slices of similar
  /// colour still read as two.
  static const double _gap = 0.012;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(
      thickness / 2,
      thickness / 2,
      size.width - thickness,
      size.height - thickness,
    );
    final sweeps = donutSweeps([for (final slice in slices) slice.bytes]);
    final visible = sweeps.where((sweep) => sweep > 0).length;

    if (visible == 0) {
      canvas.drawArc(
        rect,
        0,
        2 * math.pi,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = thickness
          ..color = emptyColor,
      );
      return;
    }

    // Twelve o'clock, clockwise — where a reader expects a chart to start.
    var start = -math.pi / 2;
    for (var i = 0; i < slices.length; i++) {
      final sweep = sweeps[i];
      if (sweep <= 0) continue;
      // Never let the gap eat a slice that only just earned its minimum.
      final inset = visible > 1 ? math.min(_gap, sweep / 3) : 0.0;
      canvas.drawArc(
        rect,
        start + inset / 2,
        sweep - inset,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = thickness
          ..strokeCap = StrokeCap.butt
          ..color = slices[i].color,
      );
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(_DonutPainter old) =>
      old.thickness != thickness ||
      old.emptyColor != emptyColor ||
      old.slices.length != slices.length ||
      List.generate(slices.length, (i) => i).any((i) =>
          old.slices[i].bytes != slices[i].bytes ||
          old.slices[i].color != slices[i].color);
}
