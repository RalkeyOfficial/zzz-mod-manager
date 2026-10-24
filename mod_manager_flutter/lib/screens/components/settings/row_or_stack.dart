import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// A settings row's two halves: the text beside the control, or the control under the text when the text would be left
/// with less than [minTextWidth].
///
/// The canvas's row is a wrapping flex with the text at `flex: 1 1 280`, so the control wraps exactly when the control's
/// own width no longer leaves the text 280px. A fixed breakpoint cannot say that: the same row needs more room in a
/// language whose control is wider. The first child is the text, the second the control.
class RowOrStack extends MultiChildRenderObjectWidget {
  RowOrStack({
    super.key,
    required Widget text,
    required Widget control,
    this.minTextWidth = 280,
    this.gap = 24,
    this.stackedGap = 24,
  }) : super(children: [text, control]);

  final double minTextWidth;
  final double gap;
  final double stackedGap;

  @override
  RenderObject createRenderObject(BuildContext context) => RenderRowOrStack(minTextWidth, gap, stackedGap);

  @override
  void updateRenderObject(BuildContext context, RenderRowOrStack renderObject) {
    renderObject
      ..minTextWidth = minTextWidth
      ..gap = gap
      ..stackedGap = stackedGap;
  }
}

class RowOrStackParentData extends ContainerBoxParentData<RenderBox> {}

/// The render object behind [RowOrStack]. It has no intrinsic sizes, so a row must not sit inside an
/// `IntrinsicHeight` or `IntrinsicWidth`, and it needs a bounded width.
class RenderRowOrStack extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, RowOrStackParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, RowOrStackParentData> {
  RenderRowOrStack(this._minTextWidth, this._gap, this._stackedGap);

  double _minTextWidth;
  double _gap;
  double _stackedGap;

  set minTextWidth(double value) {
    if (value == _minTextWidth) return;
    _minTextWidth = value;
    markNeedsLayout();
  }

  set gap(double value) {
    if (value == _gap) return;
    _gap = value;
    markNeedsLayout();
  }

  set stackedGap(double value) {
    if (value == _stackedGap) return;
    _stackedGap = value;
    markNeedsLayout();
  }

  RenderBox get _text => firstChild!;
  RenderBox get _control => lastChild!;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! RowOrStackParentData) child.parentData = RowOrStackParentData();
  }

  /// Lays the two out under [constraints] with [layout], and answers the size and where each goes.
  ({Size size, Offset text, Offset control}) _arrange(BoxConstraints constraints, ChildLayouter layout) {
    final width = constraints.maxWidth;
    final controlSize = layout(_control, BoxConstraints(maxWidth: width));
    final sideBySide = width - _gap - controlSize.width >= _minTextWidth;
    if (sideBySide) {
      final textSize = layout(_text, BoxConstraints.tightFor(width: width - _gap - controlSize.width));
      final height = math.max(textSize.height, controlSize.height);
      return (
        size: constraints.constrain(Size(width, height)),
        text: Offset(0, (height - textSize.height) / 2),
        control: Offset(width - controlSize.width, (height - controlSize.height) / 2),
      );
    }
    final textSize = layout(_text, BoxConstraints.tightFor(width: width));
    return (
      size: constraints.constrain(Size(width, textSize.height + _stackedGap + controlSize.height)),
      text: Offset.zero,
      control: Offset(0, textSize.height + _stackedGap),
    );
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      _arrange(constraints, ChildLayoutHelper.dryLayoutChild).size;

  @override
  void performLayout() {
    final arranged = _arrange(constraints, ChildLayoutHelper.layoutChild);
    (_text.parentData! as RowOrStackParentData).offset = arranged.text;
    (_control.parentData! as RowOrStackParentData).offset = arranged.control;
    size = arranged.size;
  }

  @override
  void paint(PaintingContext context, Offset offset) => defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}
