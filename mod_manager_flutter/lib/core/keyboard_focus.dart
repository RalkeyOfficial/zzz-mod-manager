import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Shows keyboard focus only while the keyboard is in use, as a browser's `:focus-visible` does: a press of the
/// pointer hides every focus highlight, and a key other than a modifier on its own brings it back.
///
/// A click takes no focus from the button Tab left focused, and on a desktop Flutter's own
/// [FocusHighlightStrategy.automatic] stays traditional for a mouse, so without this the ring stays on that button.
/// It sets [FocusManager.highlightStrategy], so everything that reads [FocusManager.highlightMode] follows: the
/// buttons' ring (`ButtonFeedback`), `FocusableActionDetector.onShowFocusHighlight` and an `InkWell`'s focus
/// highlight. Shift or Ctrl held for a click is no keyboard use, so a modifier alone changes nothing.
///
/// Mounted once, above the app's `Navigator`.
class KeyboardFocusHighlight extends StatefulWidget {
  const KeyboardFocusHighlight({super.key, required this.child});

  final Widget child;

  @override
  State<KeyboardFocusHighlight> createState() => _KeyboardFocusHighlightState();
}

class _KeyboardFocusHighlightState extends State<KeyboardFocusHighlight> {
  static final Set<LogicalKeyboardKey> _modifiers = {
    ...LogicalKeyboardKey.expandSynonyms({
      LogicalKeyboardKey.shift,
      LogicalKeyboardKey.control,
      LogicalKeyboardKey.alt,
      LogicalKeyboardKey.meta,
    }),
    LogicalKeyboardKey.capsLock,
    LogicalKeyboardKey.numLock,
    LogicalKeyboardKey.fn,
  };

  @override
  void initState() {
    super.initState();
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
    HardwareKeyboard.instance.removeHandler(_onKey);
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic;
    super.dispose();
  }

  void _onPointer(PointerEvent event) {
    if (event is PointerDownEvent) _follow(FocusHighlightStrategy.alwaysTouch);
  }

  bool _onKey(KeyEvent event) {
    if (event is KeyDownEvent && !_modifiers.contains(event.logicalKey)) {
      _follow(FocusHighlightStrategy.alwaysTraditional);
    }
    return false;
  }

  void _follow(FocusHighlightStrategy strategy) {
    if (FocusManager.instance.highlightStrategy != strategy) FocusManager.instance.highlightStrategy = strategy;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
