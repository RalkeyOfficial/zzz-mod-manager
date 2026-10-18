import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/palette.dart';
import '../../core/type_scale.dart';

/// The design's 30px button, for toolbars and panel headers. Merged over whichever button it styles, so a
/// `TextButton` stays ghost and an `OutlinedButton` stays secondary.
ButtonStyle smallButtonStyle(BuildContext context, {bool iconOnly = false}) => ButtonStyle(
  minimumSize: WidgetStatePropertyAll(Size(iconOnly ? 30 : 0, 30)),
  fixedSize: iconOnly ? const WidgetStatePropertyAll(Size(30, 30)) : null,
  padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: iconOnly ? 0 : 10)),
  textStyle: WidgetStatePropertyAll(Theme.of(context).textTheme.labelMedium),
  shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(7))),
);

/// A 28px filter chip, with an optional count after its label. Selected takes [ZenithPalette.selected].
class ZenithChip extends StatelessWidget {
  const ZenithChip({super.key, required this.label, required this.selected, required this.onTap, this.count});

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final int? count;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final foreground = selected ? palette.selected.foreground : palette.text2;
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected ? palette.selected.background : palette.chip,
        shape: StadiumBorder(side: BorderSide(color: selected ? palette.selected.border! : palette.line)),
        child: InkWell(
          customBorder: const StadiumBorder(),
          hoverColor: palette.rowHover,
          onTap: onTap,
          child: SizedBox(
            height: 28,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 11),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                spacing: 6,
                children: [
                  Text(label, style: text.labelMedium?.copyWith(color: foreground)),
                  if (count != null)
                    Text(
                      '$count',
                      style: ZenithType.of(context).monoSmall.copyWith(color: foreground.withValues(alpha: 0.8)),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A 22px status badge in one of the palette's pairs: [ZenithPalette.badgeOn], `badgeUpdate`, `badgeInfo`,
/// `badgeNeutral`, `badgeMissing`, or an element tile.
class ZenithBadge extends StatelessWidget {
  const ZenithBadge({super.key, required this.label, required this.tone, this.tooltip, this.onTap});

  final String label;
  final TonePair tone;
  final String? tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    Widget badge = Container(
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: tone.background,
        borderRadius: BorderRadius.circular(6),
        border: tone.border == null ? null : Border.all(color: tone.border!),
      ),
      // A row so the badge hugs its label wherever it is placed, and the label is centred in its height.
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: tone.foreground)),
        ],
      ),
    );
    if (onTap case final press?) {
      badge = _PressableBadge(label: label, onTap: press, child: badge);
    }
    if (tooltip != null) badge = Tooltip(message: tooltip, child: badge);
    return badge;
  }
}

/// A badge that is a button to the keyboard and a screen reader too, not only to the pointer, with an accent ring
/// while it has keyboard focus.
class _PressableBadge extends StatefulWidget {
  const _PressableBadge({required this.label, required this.onTap, required this.child});

  final String label;
  final VoidCallback onTap;
  final Widget child;

  @override
  State<_PressableBadge> createState() => _PressableBadgeState();
}

class _PressableBadgeState extends State<_PressableBadge> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: widget.label,
    excludeSemantics: true,
    onTap: widget.onTap,
    child: FocusableActionDetector(
      mouseCursor: SystemMouseCursors.click,
      onShowFocusHighlight: (focused) => setState(() => _focused = focused),
      actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => widget.onTap())},
      child: GestureDetector(
        onTap: widget.onTap,
        child: DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            border: _focused ? Border.all(color: ZenithPalette.of(context).accent, width: 2) : null,
          ),
          child: widget.child,
        ),
      ),
    ),
  );
}

/// [ground]'s background with a grid of dots, behind [child]: a character's header, a cover with no image.
class DottedGround extends StatelessWidget {
  const DottedGround({super.key, required this.ground, this.spacing = 9, this.child});

  final ElementGround ground;
  final double spacing;
  final Widget? child;

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _DotsPainter(ground.background, ground.dot, spacing),
    child: child,
  );
}

class _DotsPainter extends CustomPainter {
  _DotsPainter(this.background, this.dot, this.spacing);

  final Color background;
  final Color dot;
  final double spacing;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = background);
    final points = <Offset>[
      for (var y = spacing / 2; y < size.height; y += spacing)
        for (var x = spacing / 2; x < size.width; x += spacing) Offset(x, y),
    ];
    canvas.drawPoints(
      ui.PointMode.points,
      points,
      Paint()
        ..color = dot
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_DotsPainter old) => old.background != background || old.dot != dot || old.spacing != spacing;
}

/// Initials drawn as an outline, slanted, faintly over a dotted ground.
class OutlinedInitials extends StatelessWidget {
  const OutlinedInitials(this.text, {super.key, required this.style, required this.color});

  final String text;
  final TextStyle style;
  final Color color;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Transform(
      transform: Matrix4.skewX(-8 * math.pi / 180),
      alignment: Alignment.center,
      child: Text(
        text,
        maxLines: 1,
        softWrap: false,
        style: style.copyWith(
          foreground: Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = color,
        ),
      ),
    ),
  );
}

/// A rounded box with a dashed border, the design's drop zone.
class DashedBox extends StatelessWidget {
  const DashedBox({super.key, required this.color, required this.child, this.radius = 12, this.width = 1.5});

  final Color color;
  final double radius;
  final double width;
  final Widget child;

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _DashedBorderPainter(color, radius, width),
    child: child,
  );
}

class _DashedBorderPainter extends CustomPainter {
  _DashedBorderPainter(this.color, this.radius, this.width);

  final Color color;
  final double radius;
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(width / 2);
    final path = Path()..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(radius)));
    final paint = Paint()
      ..color = color
      ..strokeWidth = width
      ..style = PaintingStyle.stroke;
    const dash = 6.0;
    const gap = 4.0;
    for (final metric in path.computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += dash + gap) {
        canvas.drawPath(metric.extractPath(d, d + dash), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorderPainter old) => old.color != color || old.radius != radius || old.width != width;
}
