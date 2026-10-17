import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/palette.dart';
import '../../core/type_scale.dart';
import '../../l10n/app_localizations.dart';

/// The window's title bar, drawn by the app. See `docs/desktop-integration.md` §4.
///
/// Dragging it moves the window, a double-click maximises or restores, and a right-click opens the desktop's own
/// window menu. Edge resizing is the platform's: GTK draws a resize border outside the window on Linux, and Windows
/// keeps its own border on every side but the top, which [_TopResizeEdge] covers.
class ZenithTitleBar extends StatefulWidget {
  const ZenithTitleBar({super.key});

  static const double height = 44;

  @override
  State<ZenithTitleBar> createState() => _ZenithTitleBarState();
}

class _ZenithTitleBarState extends State<ZenithTitleBar> with WindowListener {
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    windowManager.isMaximized().then((value) {
      if (mounted) setState(() => _maximized = value);
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() => setState(() => _maximized = true);

  @override
  void onWindowUnmaximize() => setState(() => _maximized = false);

  Future<void> _toggleMaximize() async =>
      _maximized ? windowManager.unmaximize() : windowManager.maximize();

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    final loc = context.loc;

    // A Material of its own: the bar sits above the navigator, outside every page's Scaffold, and text with no
    // Material ancestor renders in Flutter's debug style.
    return Material(
      color: palette.chrome,
      child: Container(
      height: ZenithTitleBar.height,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: palette.divider)),
      ),
      child: Stack(
        children: [
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanStart: (_) => windowManager.startDragging(),
                  onDoubleTap: _toggleMaximize,
                  onSecondaryTap: () => windowManager.popUpWindowMenu(),
                  child: const Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: EdgeInsets.only(left: 16),
                      child: _Wordmark(),
                    ),
                  ),
                ),
              ),
              _WindowButton(
                label: loc.t('shell.window.minimize'),
                icon: Icons.remove_rounded,
                onPressed: () => windowManager.minimize(),
              ),
              _WindowButton(
                label: loc.t(_maximized ? 'shell.window.restore' : 'shell.window.maximize'),
                icon: _maximized ? Icons.filter_none_rounded : Icons.crop_square_rounded,
                onPressed: _toggleMaximize,
              ),
              _WindowButton(
                label: loc.t('shell.window.close'),
                icon: Icons.close_rounded,
                onPressed: () => windowManager.close(),
                isClose: true,
              ),
            ],
          ),
          if (!_maximized) const _TopResizeEdge(),
        ],
      ),
      ),
    );
  }
}

class _Wordmark extends StatelessWidget {
  const _Wordmark();

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 10,
      children: [
        Image.asset(
          palette.brightness == Brightness.dark
              ? 'assets/brand/logo-mark-on-dark.png'
              : 'assets/brand/logo-mark-on-light.png',
          width: 26,
          height: 26,
          filterQuality: FilterQuality.medium,
        ),
        Text(context.loc.t('app.wordmark'), style: ZenithType.of(context).wordmark.copyWith(color: palette.text)),
      ],
    );
  }
}

class _WindowButton extends StatefulWidget {
  const _WindowButton({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.isClose = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  final bool isClose;

  @override
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    final background = !_hovered
        ? Colors.transparent
        : (widget.isClose ? palette.windowClose : palette.raised);
    final foreground = !_hovered ? palette.text2 : (widget.isClose ? Colors.white : palette.text);

    return Semantics(
      button: true,
      label: widget.label,
      excludeSemantics: true,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          child: Container(
            width: 46,
            height: ZenithTitleBar.height,
            color: background,
            alignment: Alignment.center,
            child: Icon(widget.icon, size: 16, color: foreground),
          ),
        ),
      ),
    );
  }
}

/// A strip along the top edge that resizes the window. Windows keeps no native resize border above a hidden title
/// bar; on Linux GTK's border sits outside the window and this one just adds to it.
class _TopResizeEdge extends StatelessWidget {
  const _TopResizeEdge();

  static const double _thickness = 4;
  static const double _corner = 12;

  @override
  Widget build(BuildContext context) {
    Widget edge(ResizeEdge resize, MouseCursor cursor) => MouseRegion(
      cursor: cursor,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) => windowManager.startResizing(resize),
      ),
    );

    return Positioned(
      left: 0,
      right: 0,
      top: 0,
      height: _thickness,
      child: Row(
        children: [
          SizedBox(width: _corner, child: edge(ResizeEdge.topLeft, SystemMouseCursors.resizeUpLeft)),
          Expanded(child: edge(ResizeEdge.top, SystemMouseCursors.resizeUp)),
          SizedBox(width: _corner, child: edge(ResizeEdge.topRight, SystemMouseCursors.resizeUpRight)),
        ],
      ),
    );
  }
}
