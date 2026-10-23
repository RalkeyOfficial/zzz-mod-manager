import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'button_working.dart';
import 'palette.dart';

/// The keyboard focus ring, the canvas's `:focus-visible` outline: 2px of the accent, 2px out from the edge, so it
/// stays visible around a button filled in the accent. `strokeAlign` 3 centres the 2px stroke 3px out.
BorderSide focusRingSide(ZenithPalette palette) => BorderSide(color: palette.accent, width: 2, strokeAlign: 3);

/// Whether keyboard focus is shown now. A pointer press hides it (`KeyboardFocusHighlight`), so a click never draws
/// a ring.
bool get keyboardFocusShown => FocusManager.instance.highlightMode == FocusHighlightMode.traditional;

/// The ring as a button's border, for a button with no `Overlay` above it to draw [ButtonFeedback]'s ring in, such as
/// a notification's: [focusRingSide] while it has keyboard focus, else [idle]; null keeps the shape's own border.
///
/// The button must not clip (`clipBehavior: Clip.none`), since a border outside the shape is cut off by the clip
/// that a [ButtonStyle.backgroundBuilder] otherwise turns on.
WidgetStateProperty<BorderSide?> focusRingOr(ZenithPalette palette, BorderSide? idle) => WidgetStateProperty.resolveWith(
      (states) => states.contains(WidgetState.focused) && keyboardFocusShown ? focusRingSide(palette) : idle,
    );

/// Each pressed button's scale, keyed by the set of states it resolves its style with, which [ButtonFeedback] is
/// handed too. A button's [ButtonStyle] resolves from its states alone, so this is how its shape learns how far
/// into the press it is.
final Expando<double> _pressScales = Expando('press scale');

/// A button's shape, [base], shrunk about its centre while the button is pressed ([ButtonFeedback.pressedScale]).
///
/// Material paints a button's fill and border from its shape, and a theme has no way to wrap the button in a
/// transform, so the press scales the shape. A call site whose style sets `shape` passes it through this, or its
/// fill and border stay their size while the label shrinks.
WidgetStateProperty<OutlinedBorder?> pressShape(OutlinedBorder base) => WidgetStateProperty.resolveWith((states) {
      final scale = _pressScales[states];
      return scale == null ? base : PressedBorder(base, scale);
    });

/// [base] scaled by [factor] about the centre of the box it is drawn in: its fill, its border and its outline.
@immutable
class PressedBorder extends OutlinedBorder {
  PressedBorder(this.base, this.factor) : super(side: base.side);

  final OutlinedBorder base;
  final double factor;

  Matrix4 _about(Rect rect) {
    final c = rect.center;
    return Matrix4.translationValues(c.dx, c.dy, 0)
      ..multiply(Matrix4.diagonal3Values(factor, factor, 1))
      ..multiply(Matrix4.translationValues(-c.dx, -c.dy, 0));
  }

  @override
  EdgeInsetsGeometry get dimensions => base.dimensions;

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      base.getInnerPath(rect, textDirection: textDirection).transform(_about(rect).storage);

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) =>
      base.getOuterPath(rect, textDirection: textDirection).transform(_about(rect).storage);

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    canvas
      ..save()
      ..transform(_about(rect).storage);
    base.paint(canvas, rect, textDirection: textDirection);
    canvas.restore();
  }

  @override
  OutlinedBorder copyWith({BorderSide? side}) => PressedBorder(base.copyWith(side: side), factor);

  @override
  ShapeBorder scale(double t) => PressedBorder(base.scale(t) as OutlinedBorder, factor);

  @override
  bool operator ==(Object other) => other is PressedBorder && other.base == base && other.factor == factor;

  @override
  int get hashCode => Object.hash(base, factor);
}

/// A [ButtonStyle.backgroundBuilder] that draws [ButtonFeedback] in every button of a style.
///
/// [hover] false for a button whose own style already fills under the pointer, as a notification's actions do: it
/// keeps the press and leaves the hover to that fill.
ButtonLayerBuilder buttonFeedback({bool hover = true}) =>
    (context, states, child) => ButtonFeedback(states: states, hover: hover, child: child);

/// What a button draws on itself, the canvas's `ButtonStates` board: its own text colour over its fill, 8% under the
/// pointer and 16% while pressed, in over 60 ms and out over 150 ms; the whole button at 97% while pressed, on the
/// same timing (none with reduced motion); the working state of a [WorkingAction] above it; and [focusRingSide]
/// around it while it has keyboard focus.
///
/// The press starts on the pointer's down rather than on the button's `pressed` state, which a button in a
/// scrolling list only reaches 100 ms later or at the release, so even a quick click shows. A key that presses the
/// button shows it through that state.
///
/// A style that sets an overlay of its own, as `styleFrom(foregroundColor:)` does, keeps that one, and this draws
/// nothing, so the two never add up.
///
/// The ring is drawn in the nearest `Overlay`, at the button and clipped to its scroll view ([ButtonFocusRing]): a
/// button with a background builder clips to its shape, so a ring 2px out drawn by the button itself would be cut
/// off, and a border set by the call site (`side`) can't replace it.
class ButtonFeedback extends StatefulWidget {
  const ButtonFeedback({super.key, required this.states, this.hover = true, this.child});

  static const double hoverOpacity = 0.08;
  static const double pressedOpacity = 0.16;
  static const double pressedScale = 0.97;
  static const Duration inDuration = Duration(milliseconds: 60);
  static const Duration outDuration = Duration(milliseconds: 150);

  /// The canvas's `cubic-bezier(.2,.8,.2,1)`, for the press's scale.
  static const Curve curve = Cubic(0.2, 0.8, 0.2, 1);

  final Set<WidgetState> states;
  final bool hover;
  final Widget? child;

  @override
  State<ButtonFeedback> createState() => _ButtonFeedbackState();
}

class _ButtonFeedbackState extends State<ButtonFeedback> with TickerProviderStateMixin {
  late final AnimationController _opacity = AnimationController(vsync: this, value: _target);

  /// How far into the press the button is, 0 to 1, eased: 1 is [ButtonFeedback.pressedScale].
  late final AnimationController _press = AnimationController(vsync: this)..addListener(_onPress);
  ButtonWork? _work;
  Color? _restColour;

  // The ring, present only while this button shows keyboard focus, so an unfocused button costs nothing for it.
  OverlayEntry? _ringEntry;
  OverlayState? _overlay;
  ScrollableState? _scrollable;
  OutlinedBorder? _shape;
  ZenithPalette? _palette;

  /// Bumped whenever the ring's place changes, which [_watchRing] looks for after every frame while it shows.
  final ValueNotifier<int> _ringMoved = ValueNotifier(0);
  RingGeometry? _ringAt;
  bool _down = false;
  bool _still = false;

  bool get _disabled => widget.states.contains(WidgetState.disabled);

  bool get _working => _work?.working ?? false;

  bool get _focused => widget.states.contains(WidgetState.focused) && !_disabled;

  bool get _pressed => !_disabled && !_working && (_down || widget.states.contains(WidgetState.pressed));

  double get _scale => 1 - (1 - ButtonFeedback.pressedScale) * _press.value;

  // The button resolves its shape from [pressShape] when it builds, so each step of the press rebuilds it.
  void _onPress() {
    _pressScales[widget.states] = _press.value == 0 ? null : _scale;
    (context.findAncestorStateOfType<State<ButtonStyleButton>>()?.context as Element?)?.markNeedsBuild();
  }

  // An overlay entry can't be added while the tree builds, so a change made then lands a frame later.
  void _syncRing() {
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) _syncRing();
      });
      return;
    }
    final shown = _focused && keyboardFocusShown && _palette != null;
    if (shown && _ringEntry == null) {
      final overlay = Overlay.maybeOf(context);
      if (overlay == null) return;
      _overlay = overlay;
      _ringEntry = OverlayEntry(
        builder: (_) => ButtonFocusRing(
          geometry: _ringGeometry,
          shape: (_shape ?? RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)))
              .copyWith(side: focusRingSide(_palette!)),
          repaint: Listenable.merge([_ringMoved, ?_scrollable?.position]),
        ),
      );
      overlay.insert(_ringEntry!);
      _ringAt = null;
      SchedulerBinding.instance.addPostFrameCallback(_watchRing);
    } else if (!shown) {
      _removeRing();
    }
  }

  // The button can move with nothing telling it: an outer scroll view scrolling, a layout shift, an ancestor's
  // animation. So after every frame while the ring shows, its place is measured again and the ring repainted when it
  // moved. A post-frame callback asks for no frame of its own, so a still screen costs nothing.
  void _watchRing(Duration _) {
    if (!mounted || _ringEntry == null) return;
    final at = _ringGeometry();
    if (at != _ringAt) {
      _ringAt = at;
      _ringMoved.value++;
    }
    SchedulerBinding.instance.addPostFrameCallback(_watchRing);
  }

  void _removeRing() {
    _ringEntry
      ?..remove()
      ..dispose();
    _ringEntry = null;
  }

  /// Where the ring goes, in the overlay's coordinates: the button's transform and size, and the boxes of the scroll
  /// views it is in, every one up to the overlay, which the ring is clipped to so it never draws over what a view
  /// scrolls under.
  RingGeometry? _ringGeometry() {
    if (!mounted) return null;
    final box = context.findRenderObject();
    final overlay = _overlay?.context.findRenderObject();
    if (box is! RenderBox || overlay is! RenderBox || !box.attached || !box.hasSize) return null;
    Rect? clip;
    var scrollable = context.findAncestorStateOfType<ScrollableState>();
    while (scrollable != null) {
      final viewport = scrollable.context.findRenderObject();
      if (viewport is RenderBox && viewport.attached && viewport.hasSize) {
        final rect = MatrixUtils.transformRect(viewport.getTransformTo(overlay), Offset.zero & viewport.size);
        clip = clip?.intersect(rect) ?? rect;
      }
      scrollable = scrollable.context.findAncestorStateOfType<ScrollableState>();
    }
    return (transform: box.getTransformTo(overlay), size: box.size, clip: clip);
  }

  double get _target {
    if (_disabled) return 0;
    if (_working) return ButtonFeedback.hoverOpacity;
    if (_pressed) return ButtonFeedback.pressedOpacity;
    if (widget.hover && widget.states.contains(WidgetState.hovered)) return ButtonFeedback.hoverOpacity;
    return 0;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    // Also called when the work starts or ends.
    _work = ButtonWork.maybeOf(context);
    _retarget();
  }

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addHighlightModeListener(_onHighlightMode);
    _syncRing();
  }

  @override
  void didUpdateWidget(ButtonFeedback oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_disabled) _down = false;
    _retarget();
    _syncRing();
  }

  @override
  void dispose() {
    FocusManager.instance.removeHighlightModeListener(_onHighlightMode);
    _pressScales[widget.states] = null;
    _removeRing();
    _ringMoved.dispose();
    _opacity.dispose();
    _press.dispose();
    super.dispose();
  }

  void _onHighlightMode(FocusHighlightMode _) {
    if (!mounted) return;
    _syncRing();
    // A [focusRingOr] border is resolved only when the button builds.
    if (_focused) (context.findAncestorStateOfType<State<ButtonStyleButton>>()?.context as Element?)?.markNeedsBuild();
  }

  // What each animation is heading for, so a rebuild on the way leaves it running rather than starting it over.
  double? _opacityTo;
  double? _pressTo;

  void _retarget() {
    final target = _target;
    if (target != _opacityTo && (target != _opacity.value || _opacity.isAnimating)) {
      _opacityTo = target;
      final pressing = target == ButtonFeedback.pressedOpacity;
      _opacity.animateTo(target, duration: pressing ? ButtonFeedback.inDuration : ButtonFeedback.outDuration);
    }
    final press = _pressed && !_still ? 1.0 : 0.0;
    if (press != _pressTo && (press != _press.value || _press.isAnimating)) {
      _pressTo = press;
      _press.animateTo(
        press,
        duration: press == 1 ? ButtonFeedback.inDuration : ButtonFeedback.outDuration,
        curve: ButtonFeedback.curve,
      );
    }
  }

  void _setDown(bool down) {
    if (_down == down || (down && _disabled)) return;
    _down = down;
    _retarget();
  }

  @override
  Widget build(BuildContext context) {
    final material = context.findAncestorWidgetOfExactType<Material>();
    final shape = material?.shape is OutlinedBorder
        ? material!.shape! as OutlinedBorder
        : RoundedRectangleBorder(borderRadius: BorderRadius.circular(8));
    final ownOverlay = context
        .findAncestorWidgetOfExactType<InkWell>()
        ?.overlayColor
        ?.resolve(const {WidgetState.pressed});
    // The overlay is the button's text colour at rest: a ghost button's text lightens under the pointer, and the
    // canvas's overlay keeps the grey it had.
    final textColour = IconTheme.of(context).color ?? DefaultTextStyle.of(context).style.color;
    if (!widget.states.contains(WidgetState.hovered) && !widget.states.contains(WidgetState.pressed) && !_down) {
      _restColour = textColour;
    }
    var label = widget.child;
    final work = _work;
    if (work != null && work.working && !work.hasIcon) {
      // The spinner takes the label's place, and the label keeps the button's width.
      label = Stack(
        alignment: Alignment.center,
        children: [
          Visibility(visible: false, maintainSize: true, maintainAnimation: true, maintainState: true, child: label!),
          ZenithSpinner(size: IconTheme.of(context).size ?? 16),
        ],
      );
    }
    final content = Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (event) => _setDown(event.buttons & kPrimaryButton != 0),
      onPointerUp: (_) => _setDown(false),
      onPointerCancel: (_) => _setDown(false),
      child: CustomPaint(
        painter: _FeedbackPainter(
          opacity: _opacity,
          shape: shape,
          color: ownOverlay != null && ownOverlay.a > 0 ? null : _restColour ?? textColour,
        ),
        // The fill and border shrink through the button's shape ([pressShape]); its label shrinks here.
        child: AnimatedBuilder(
          animation: _press,
          builder: (context, label) => Transform.scale(scale: _scale, child: label),
          child: label,
        ),
      ),
    );
    _palette = Theme.of(context).extension<ZenithPalette>();
    _scrollable = Scrollable.maybeOf(context);
    if (_ringEntry != null && shape != _shape) {
      // The ring's own outline; its place and size [_watchRing] follows.
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) _ringEntry?.markNeedsBuild();
      });
    }
    _shape = shape;
    if (_ringEntry == null && _focused && keyboardFocusShown) {
      _syncRing();
    }
    return content;
  }
}

/// Where [ButtonFocusRing] draws: the button's transform into the overlay, its size, and the scroll view's box to
/// clip to, if it is in one.
typedef RingGeometry = ({Matrix4 transform, Size size, Rect? clip});

/// [ButtonFeedback]'s ring, in the `Overlay`: [shape], with the ring as its border, painted around the button where
/// [geometry] puts it, and again whenever [repaint] says the button moved, such as its scroll view scrolling.
class ButtonFocusRing extends StatelessWidget {
  const ButtonFocusRing({super.key, required this.geometry, required this.shape, required this.repaint});

  final RingGeometry? Function() geometry;
  final OutlinedBorder shape;
  final Listenable repaint;

  @override
  Widget build(BuildContext context) =>
      IgnorePointer(child: CustomPaint(painter: _OverlayRingPainter(geometry, shape, repaint), size: Size.infinite));
}

class _OverlayRingPainter extends CustomPainter {
  _OverlayRingPainter(this.geometry, this.shape, Listenable repaint) : super(repaint: repaint);

  final RingGeometry? Function() geometry;
  final OutlinedBorder shape;

  @override
  void paint(Canvas canvas, Size size) {
    final at = geometry();
    if (at == null) return;
    canvas.save();
    if (at.clip case final clip?) canvas.clipRect(clip);
    canvas.transform(at.transform.storage);
    shape.paint(canvas, Offset.zero & at.size);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_OverlayRingPainter old) => true;
}

/// Draws [focusRingSide] around whichever control inside [child] has keyboard focus, for a control that cannot draw
/// it on itself: a `SegmentedButton` clips its segments to its own outline, so a ring 2px out of a segment would be
/// cut off. [shape] is the ring's outline around that control's box.
class KeyboardFocusRing extends StatefulWidget {
  const KeyboardFocusRing({super.key, required this.shape, required this.child});

  final OutlinedBorder shape;
  final Widget child;

  @override
  State<KeyboardFocusRing> createState() => _KeyboardFocusRingState();
}

class _KeyboardFocusRingState extends State<KeyboardFocusRing> {
  // Unfocusable itself, so it only says whether focus is somewhere inside.
  final FocusNode _within = FocusNode(canRequestFocus: false, skipTraversal: true);

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addHighlightModeListener(_onHighlightMode);
  }

  @override
  void dispose() {
    FocusManager.instance.removeHighlightModeListener(_onHighlightMode);
    _within.dispose();
    super.dispose();
  }

  void _onHighlightMode(FocusHighlightMode _) {
    if (mounted) setState(() {});
  }

  /// The focused control's box in this widget's coordinates, or null while nothing inside has keyboard focus.
  Rect? _focusedRect() {
    if (!_within.hasFocus || !keyboardFocusShown) return null;
    final focused = FocusManager.instance.primaryFocus?.context?.findRenderObject();
    final self = context.findRenderObject();
    if (focused is! RenderBox || self is! RenderBox || !focused.hasSize || !focused.attached) return null;
    return MatrixUtils.transformRect(focused.getTransformTo(self), Offset.zero & focused.size);
  }

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<ZenithPalette>();
    return Focus(
      focusNode: _within,
      onFocusChange: (_) => setState(() {}),
      child: CustomPaint(
        foregroundPainter: palette == null
            ? null
            : _RingPainter(rect: _focusedRect, shape: widget.shape.copyWith(side: focusRingSide(palette))),
        child: widget.child,
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({required this.rect, required this.shape}) : super(repaint: FocusManager.instance);

  final Rect? Function() rect;
  final OutlinedBorder shape;

  @override
  void paint(Canvas canvas, Size size) {
    if (rect() case final rect?) shape.paint(canvas, rect);
  }

  @override
  bool shouldRepaint(_RingPainter old) => true;
}

class _FeedbackPainter extends CustomPainter {
  _FeedbackPainter({required this.opacity, required this.shape, required this.color}) : super(repaint: opacity);

  final Animation<double> opacity;
  final OutlinedBorder shape;

  /// The overlay's colour, or null for a button that draws its own.
  final Color? color;

  @override
  void paint(Canvas canvas, Size size) {
    final color = this.color;
    if (color == null || opacity.value == 0) return;
    final rect = Offset.zero & size;
    // Inside the button's border, which the canvas draws over the overlay, and never out under a focus ring.
    final path = shape.side.strokeInset > 0
        ? shape.getInnerPath(rect)
        : shape.copyWith(side: BorderSide.none).getOuterPath(rect);
    canvas.drawPath(path, Paint()..color = color.withValues(alpha: color.a * opacity.value));
  }

  @override
  bool shouldRepaint(_FeedbackPainter old) => old.shape != shape || old.color != color;
}
