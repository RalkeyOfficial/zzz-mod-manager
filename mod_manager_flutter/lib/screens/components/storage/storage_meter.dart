import 'package:flutter/material.dart';

import '../../../core/button_feedback.dart';
import '../../../core/palette.dart';
import '../../../core/type_scale.dart';
import '../../../services/storage/storage_usage.dart';

/// One segment of the meter, with the words its tooltip and screen-reader label need.
class MeterSegment {
  const MeterSegment({
    required this.id,
    required this.name,
    required this.size,
    required this.share,
    required this.bytes,
    required this.color,
  });

  final StorageCategoryId id;
  final String name;

  /// The category's size, such as `7.9 GB`.
  final String size;

  /// "12% of the total", the tooltip's second half.
  final String share;
  final int bytes;
  final Color color;
}

/// The canvas's segmented bar: one segment per category with bytes, as wide as its share and never under a few pixels.
///
/// A segment under the pointer or holding keyboard focus is reported through [onHover], and a tooltip names it over whatever is below the bar.
/// [footer] is drawn under the bar and under that tooltip.
class StorageMeter extends StatelessWidget {
  const StorageMeter({
    super.key,
    required this.segments,
    required this.hovered,
    required this.onHover,
    required this.semanticLabel,
    required this.footer,
  });

  final List<MeterSegment> segments;

  /// The category being pointed at, from the bar or from its row; the other segments dim.
  final StorageCategoryId? hovered;
  final ValueChanged<StorageCategoryId?> onHover;
  final String semanticLabel;
  final Widget footer;

  static const double _barHeight = 36;
  static const double _segmentHeight = 16;
  static const double _gap = 2;
  static const double _tipWidth = 220;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final widths = meterWidths([for (final s in segments) s.bytes], width, gap: _gap);
        final shown = [for (var i = 0; i < segments.length; i++) if (widths[i] > 0) i];

        // The middle of the hovered segment, to centre the tooltip over it.
        double? middle;
        var offset = 0.0;
        for (final i in shown) {
          if (segments[i].id == hovered) middle = offset + widths[i] / 2;
          offset += widths[i] + _gap;
        }
        final tipped = segments.where((s) => s.id == hovered && widths[segments.indexOf(s)] > 0).firstOrNull;

        return Stack(
          clipBehavior: Clip.none,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 16,
              children: [
                SizedBox(
                  height: _barHeight,
                  child: Semantics(
                    container: true,
                    label: semanticLabel,
                    child: shown.isEmpty
                        ? Center(
                            child: Container(
                              height: _segmentHeight,
                              decoration: BoxDecoration(color: palette.barTrack, borderRadius: BorderRadius.circular(4)),
                            ),
                          )
                        : KeyboardFocusRing(
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                            child: Row(
                              spacing: _gap,
                              children: [
                                for (final (n, i) in shown.indexed)
                                  _Segment(
                                    key: ValueKey('meter_${segments[i].id.name}'),
                                    segment: segments[i],
                                    width: widths[i],
                                    first: n == 0,
                                    last: n == shown.length - 1,
                                    dimmed: hovered != null && hovered != segments[i].id,
                                    onHover: onHover,
                                  ),
                              ],
                            ),
                          ),
                  ),
                ),
                footer,
              ],
            ),
            if (tipped != null && middle != null)
              Positioned(
                top: _barHeight + 4,
                left: (middle - _tipWidth / 2).clamp(0.0, (width - _tipWidth).clamp(0.0, double.infinity)),
                width: width < _tipWidth ? width : _tipWidth,
                child: IgnorePointer(child: _Tip(segment: tipped)),
              ),
          ],
        );
      },
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({
    super.key,
    required this.segment,
    required this.width,
    required this.first,
    required this.last,
    required this.dimmed,
    required this.onHover,
  });

  final MeterSegment segment;
  final double width;
  final bool first;
  final bool last;
  final bool dimmed;
  final ValueChanged<StorageCategoryId?> onHover;

  @override
  Widget build(BuildContext context) {
    const edge = Radius.circular(4);
    return Semantics(
      focusable: true,
      label: '${segment.name}, ${segment.size}',
      child: MouseRegion(
        onEnter: (_) => onHover(segment.id),
        onExit: (_) => onHover(null),
        child: Focus(
          onFocusChange: (focused) => onHover(focused ? segment.id : null),
          child: AnimatedOpacity(
            opacity: dimmed ? 0.3 : 1,
            duration: const Duration(milliseconds: 120),
            child: Container(
              width: width,
              height: StorageMeter._segmentHeight,
              decoration: BoxDecoration(
                color: segment.color,
                borderRadius: BorderRadius.horizontal(
                  left: first ? edge : Radius.zero,
                  right: last ? edge : Radius.zero,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Tip extends StatelessWidget {
  const _Tip({required this.segment});

  final MeterSegment segment;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final toast = palette.toast;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: toast.background,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: toast.border!),
        boxShadow: [BoxShadow(color: palette.downloadsShadow, blurRadius: 32, offset: const Offset(0, 12))],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 4,
          children: [
            Row(
              spacing: 8,
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(color: segment.color, borderRadius: BorderRadius.circular(3)),
                  child: const SizedBox.square(dimension: 12),
                ),
                Expanded(
                  child: Text(
                    segment.name,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodySmall?.copyWith(color: toast.foreground, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: segment.size, style: ZenithType.of(context).mono),
                  TextSpan(text: ' · ${segment.share}'),
                ],
              ),
              style: text.bodySmall?.copyWith(color: palette.textProse),
            ),
          ],
        ),
      ),
    );
  }
}
