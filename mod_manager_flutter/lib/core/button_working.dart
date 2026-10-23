import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Marks the part of an action the button shows as working: [task], the wait on disk, network or the game. A
/// question the action asks first, such as a confirmation, stays outside it.
typedef WorkSpan = Future<T> Function<T>(Future<T> Function() task);

/// A [WorkSpan] for a flow run with no button to show its wait.
Future<T> noWorkSpan<T>(Future<T> Function() task) => task();

/// A button's action, handed the [WorkSpan] of the [WorkingAction] that runs it.
typedef WorkingCallback = Future<void> Function(WorkSpan work);

/// A button's action that can wait, and the button showing it working, the canvas's `ButtonStates` Working column.
///
/// [builder] builds one button, wired to the `onPressed` it is handed. The action gets a [WorkSpan] to wrap its wait
/// in. Once a wait has run [showAfter], the button shows the working state until the wait ends, and for at least
/// [holdFor] so it never flickers; a wait shorter than [showAfter] shows nothing. The result is not held back: only
/// the drawing lingers. While the action runs, a press does nothing. During its wait the button keeps looking
/// pressable even if the caller turns its `onPressed` off meanwhile, as the check buttons do while any check runs:
/// only the button that started the work shows it. After its wait, while the rest of the action runs, such as a
/// check writing what it found before its results screen, the button is off.
///
/// The working state itself is drawn by the theme's `ButtonFeedback`: the 8% overlay, no press, and a spinner in
/// place of the label. A button with an icon puts it in a [WorkingIcon], and the spinner takes the icon's place
/// instead, so the label stays.
class WorkingAction extends StatefulWidget {
  const WorkingAction({super.key, required this.onPressed, required this.builder});

  static const Duration showAfter = Duration(milliseconds: 200);
  static const Duration holdFor = Duration(milliseconds: 500);

  /// The action, or null for a disabled button.
  final WorkingCallback? onPressed;
  final Widget Function(BuildContext context, VoidCallback? onPressed) builder;

  @override
  State<WorkingAction> createState() => _WorkingActionState();
}

class _WorkingActionState extends State<WorkingAction> {
  final ButtonWork _work = ButtonWork._();
  bool _running = false;

  /// Whether the running action has reached a wait yet.
  bool _waited = false;

  /// The action's waits under way.
  int _waits = 0;
  Timer? _show;

  /// Runs for [WorkingAction.holdFor] from the moment the working state shows.
  Timer? _hold;

  @override
  void initState() {
    super.initState();
    _work.addListener(_onWork);
  }

  @override
  void dispose() {
    _show?.cancel();
    _hold?.cancel();
    _work.dispose();
    super.dispose();
  }

  // The button's `onPressed` depends on whether it is working.
  void _onWork() => setState(() {});

  void _press() {
    if (_running || _waits > 0 || _work.working) return;
    setState(() {
      _running = true;
      _waited = false;
    });
    unawaited(
      widget.onPressed!(_span).whenComplete(() {
        if (mounted) setState(() => _running = false);
      }),
    );
  }

  Future<T> _span<T>(Future<T> Function() task) async {
    // A flow can reach its wait after the button has gone, such as a delete that closes the page it was pressed on.
    if (!mounted) return task();
    _begin();
    try {
      return await task();
    } finally {
      if (mounted) _end();
    }
  }

  void _begin() {
    _waited = true;
    if (_waits++ > 0 || _work.working) return;
    _show = Timer(WorkingAction.showAfter, () {
      _work._set(true);
      _hold = Timer(WorkingAction.holdFor, () {
        if (_waits == 0) _work._set(false);
      });
    });
  }

  void _end() {
    if (--_waits > 0) return;
    // The button goes from looking pressable to off for the rest of the action ([build]).
    setState(() {});
    _show?.cancel();
    // Shown and held long enough: back to rest now. Still within the hold, the hold's end does it.
    if (_work.working && !(_hold?.isActive ?? false)) _work._set(false);
  }

  @override
  Widget build(BuildContext context) {
    // While its own wait runs or shows, it looks pressable whatever the caller says. Once that wait is over and the
    // rest of the action still runs, a press would start nothing, so it is off rather than at rest and deaf. Before
    // its wait, such as during its question, it stays as it was, so a press doesn't flash it off.
    final pressable = (widget.onPressed != null && !(_running && _waited)) || _waits > 0 || _work.working;
    return _WorkScope(
      notifier: _work,
      child: Builder(builder: (context) => widget.builder(context, pressable ? _press : null)),
    );
  }
}

/// Whether the button under a [WorkingAction] is working, for the theme's `ButtonFeedback` and [WorkingIcon].
class ButtonWork extends ChangeNotifier {
  ButtonWork._();

  bool _shown = false;

  /// The [WorkingIcon]s mounted below, so the spinner takes the icon's place rather than the label's.
  int _icons = 0;

  bool get hasIcon => _icons > 0;

  bool get working => _shown;

  void _set(bool shown) {
    if (_shown == shown) return;
    _shown = shown;
    notifyListeners();
  }

  /// The [ButtonWork] of the [WorkingAction] above [context], if any.
  static ButtonWork? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_WorkScope>()?.notifier;
}

class _WorkScope extends InheritedNotifier<ButtonWork> {
  const _WorkScope({required super.notifier, required super.child});
}

/// A button's icon, which a [ZenithSpinner] replaces while the button's [WorkingAction] is working.
class WorkingIcon extends StatefulWidget {
  const WorkingIcon(this.icon, {super.key});

  final Widget icon;

  @override
  State<WorkingIcon> createState() => _WorkingIconState();
}

class _WorkingIconState extends State<WorkingIcon> {
  ButtonWork? _work;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final work = ButtonWork.maybeOf(context);
    if (work == _work) return;
    _work?._icons--;
    work?._icons++;
    _work = work;
  }

  @override
  void dispose() {
    _work?._icons--;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!(_work?.working ?? false)) return widget.icon;
    final size = switch (widget.icon) {
      Icon(:final size?) => size,
      _ => IconTheme.of(context).size ?? 16,
    };
    return ZenithSpinner(size: size);
  }
}

/// The canvas's working spinner: half a ring in the text colour, turning every 0.8 s, or every 2.4 s with reduced
/// motion.
class ZenithSpinner extends StatefulWidget {
  const ZenithSpinner({super.key, this.size = 16, this.color});

  final double size;

  /// Null takes the icon colour, which in a button is its text colour.
  final Color? color;

  @override
  State<ZenithSpinner> createState() => _ZenithSpinnerState();
}

class _ZenithSpinnerState extends State<ZenithSpinner> with SingleTickerProviderStateMixin {
  late final AnimationController _turn = AnimationController(vsync: this);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final period = Duration(milliseconds: still ? 2400 : 800);
    if (_turn.duration != period) {
      _turn
        ..duration = period
        ..repeat();
    }
  }

  @override
  void dispose() {
    _turn.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox.square(
        dimension: widget.size,
        child: CustomPaint(
          painter: _SpinnerPainter(turn: _turn, color: widget.color ?? IconTheme.of(context).color ?? Colors.white),
        ),
      );
}

class _SpinnerPainter extends CustomPainter {
  _SpinnerPainter({required this.turn, required this.color}) : super(repaint: turn);

  final Animation<double> turn;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // The canvas's 20-unit circle of radius 7 and stroke 2.2, dashed 22 on 40: half the ring.
    final unit = size.shortestSide / 20;
    final ring = Rect.fromCircle(center: size.center(Offset.zero), radius: 7 * unit);
    canvas.drawArc(
      ring,
      turn.value * 2 * math.pi,
      math.pi,
      false,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2 * unit
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_SpinnerPainter old) => old.color != color;
}
