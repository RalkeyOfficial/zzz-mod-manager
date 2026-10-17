import 'package:flutter/material.dart';

import '../../core/palette.dart';

/// The design's switch: a 38×22 track with a 14px knob. Material's switch has a fixed 52×32 track, so the app
/// draws its own.
///
/// Off is the knob in [ZenithPalette.text3] on [ZenithPalette.track]; on is the accent with an [ZenithPalette.onAccent]
/// knob. A null [onChanged] disables it, faded to 45%.
class ZenithSwitch extends StatefulWidget {
  const ZenithSwitch({super.key, required this.value, required this.onChanged, this.semanticLabel});

  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? semanticLabel;

  static const Size size = Size(38, 22);

  @override
  State<ZenithSwitch> createState() => _ZenithSwitchState();
}

class _ZenithSwitchState extends State<ZenithSwitch> {
  static const double _knob = 14;
  static const double _inset = 4;
  static const Duration _slide = Duration(milliseconds: 140);

  bool _focused = false;

  bool get _enabled => widget.onChanged != null;

  void _toggle() => widget.onChanged?.call(!widget.value);

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    final on = widget.value;

    Widget track = AnimatedContainer(
      duration: _slide,
      curve: Curves.easeOut,
      width: ZenithSwitch.size.width,
      height: ZenithSwitch.size.height,
      decoration: BoxDecoration(
        color: on ? palette.accent : palette.track,
        borderRadius: BorderRadius.circular(ZenithSwitch.size.height / 2),
        border: Border.all(color: on ? palette.accent : palette.edge),
        boxShadow: _focused ? [BoxShadow(color: palette.accentWash, spreadRadius: 3)] : null,
      ),
      child: AnimatedAlign(
        duration: _slide,
        curve: Curves.easeOut,
        alignment: on ? Alignment.centerRight : Alignment.centerLeft,
        child: Padding(
          // The border takes 1px of the inset.
          padding: const EdgeInsets.symmetric(horizontal: _inset - 1),
          child: AnimatedContainer(
            duration: _slide,
            width: _knob,
            height: _knob,
            decoration: BoxDecoration(color: on ? palette.onAccent : palette.text3, shape: BoxShape.circle),
          ),
        ),
      ),
    );
    if (!_enabled) track = Opacity(opacity: 0.45, child: track);

    return Semantics(
      container: true,
      toggled: on,
      enabled: _enabled,
      label: widget.semanticLabel,
      onTap: _enabled ? _toggle : null,
      child: FocusableActionDetector(
        enabled: _enabled,
        mouseCursor: _enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onShowFocusHighlight: (focused) => setState(() => _focused = focused),
        actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => _toggle())},
        child: GestureDetector(onTap: _enabled ? _toggle : null, excludeFromSemantics: true, child: track),
      ),
    );
  }
}
