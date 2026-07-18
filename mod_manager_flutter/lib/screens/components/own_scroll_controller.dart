import 'package:flutter/material.dart';

/// Gives its [builder] a private [ScrollController] tied to this element's
/// lifetime. The mods grid and the grouped view live inside an
/// [AnimatedSwitcher], so during a tab transition the outgoing and incoming
/// lists are briefly mounted together; a shared controller would then have two
/// ScrollPositions, which the desktop Scrollbar forbids. A controller per
/// instance keeps each list's position independent.
class OwnScrollController extends StatefulWidget {
  const OwnScrollController({super.key, required this.builder});

  final Widget Function(BuildContext context, ScrollController controller)
  builder;

  @override
  State<OwnScrollController> createState() => _OwnScrollControllerState();
}

class _OwnScrollControllerState extends State<OwnScrollController> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _controller);
}
