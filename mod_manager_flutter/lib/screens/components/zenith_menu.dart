import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/palette.dart';
import '../../core/type_scale.dart';

/// Something in a [showZenithMenu] list: an entry or a separator.
sealed class ZenithMenuItem {
  const ZenithMenuItem();
}

/// A line between two groups of entries.
class ZenithMenuSeparator extends ZenithMenuItem {
  const ZenithMenuSeparator();
}

/// One action in a menu.
///
/// [accelerator] runs it from the keyboard as soon as the menu is open, whichever row is hot, and [shortcut] is the
/// key's name drawn at the row's end. The name is the physical key's, so it is not translated.
class ZenithMenuEntry extends ZenithMenuItem {
  const ZenithMenuEntry({
    required this.label,
    required this.icon,
    required this.onSelected,
    this.shortcut,
    this.accelerator,
    this.danger = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback onSelected;
  final String? shortcut;
  final LogicalKeyboardKey? accelerator;

  /// Text and icon in [ZenithPalette.redText].
  final bool danger;
}

/// Opens a menu at [position] in the window, or under the button that opened it when [anchor] is given, and runs the
/// chosen entry once the menu is gone.
///
/// Material's menus put nothing in focus when they open, so a key pressed straight away would do nothing; this one
/// takes focus itself, which is what lets [ZenithMenuEntry.accelerator]s work. Up and Down move the hot row and wrap,
/// Home and End jump, Enter runs the hot row, and Escape or a press outside closes the menu.
Future<void> showZenithMenu(
  BuildContext context, {
  required String title,
  String? subtitle,
  required List<ZenithMenuItem> items,
  Offset? position,
  Rect? anchor,
}) async {
  assert(position != null || anchor != null, 'a menu needs somewhere to open');
  final target = anchor ?? Rect.fromLTWH(position!.dx, position.dy, 0, 0);
  final chosen = await showZenithPopover<ZenithMenuEntry>(
    context,
    target: target,
    gap: anchor == null ? 0 : 6,
    builder: (context) => _ZenithMenu(title: title, subtitle: subtitle, items: items),
  );
  if (chosen == null) return;
  // The route is popped but its widgets are still there until the frame that removes them.
  await WidgetsBinding.instance.endOfFrame;
  chosen.onSelected();
}

/// Shows [builder] as a popover next to [target], in the window's coordinates, without a scrim.
///
/// It opens below the target and flips above when there is no room, left-aligned to the target's left edge and
/// flipped to its right edge when it would pass the window's, and never closer than 8px to the window.
/// A press outside, or Escape, closes it with a null result.
Future<T?> showZenithPopover<T>(
  BuildContext context, {
  required Rect target,
  required WidgetBuilder builder,
  double gap = 6,
}) => showGeneralDialog<T>(
  context: context,
  barrierDismissible: true,
  barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
  barrierColor: Colors.transparent,
  transitionDuration: Duration.zero,
  pageBuilder: (context, _, _) => CustomSingleChildLayout(
    delegate: _PopoverLayout(target, gap),
    child: builder(context),
  ),
);

class _PopoverLayout extends SingleChildLayoutDelegate {
  _PopoverLayout(this.target, this.gap);

  final Rect target;
  final double gap;

  static const double _margin = 8;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.loose(Size(constraints.maxWidth - 2 * _margin, constraints.maxHeight - 2 * _margin));

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    var x = target.left;
    if (x + childSize.width > size.width - _margin) x = target.right - childSize.width;
    var y = target.bottom + gap;
    if (y + childSize.height > size.height - _margin) {
      final above = target.top - gap - childSize.height;
      y = above >= _margin ? above : size.height - _margin - childSize.height;
    }
    return Offset(
      x.clamp(_margin, math.max(_margin, size.width - _margin - childSize.width)),
      y.clamp(_margin, math.max(_margin, size.height - _margin - childSize.height)),
    );
  }

  @override
  bool shouldRelayout(_PopoverLayout old) => old.target != target || old.gap != gap;
}

/// The surface a menu or a picker's list sits on: the canvas's `.menu`.
class ZenithMenuSurface extends StatelessWidget {
  const ZenithMenuSurface({super.key, required this.child, this.width});

  final Widget child;
  final double? width;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    return Material(
      type: MaterialType.transparency,
      child: Container(
        width: width,
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: palette.menu,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: palette.menuBorder),
          boxShadow: [BoxShadow(color: palette.dialogShadow, offset: const Offset(0, 20), blurRadius: 50)],
        ),
        child: child,
      ),
    );
  }
}

/// A 34px row of a menu or a picker: [leading], [label], and [trailing] at the end, on [ZenithPalette.hover] while
/// [hot].
class ZenithMenuRow extends StatelessWidget {
  const ZenithMenuRow({
    super.key,
    required this.label,
    required this.onTap,
    this.leading,
    this.trailing,
    this.hot = false,
    this.danger = false,
    this.onHover,
    this.semanticsHint,
  });

  final String label;
  final Widget? leading;
  final Widget? trailing;
  final bool hot;
  final bool danger;
  final VoidCallback onTap;
  final ValueChanged<bool>? onHover;
  final String? semanticsHint;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    final textColor = danger ? palette.redText : palette.text;
    return Semantics(
      button: true,
      label: label,
      hint: semanticsHint,
      excludeSemantics: true,
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => onHover?.call(true),
        onExit: (_) => onHover?.call(false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Container(
            height: 34,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: hot ? palette.hover : Colors.transparent,
              borderRadius: BorderRadius.circular(7),
            ),
            child: Row(
              spacing: 10,
              children: [
                if (leading case final leading?)
                  IconTheme.merge(
                    data: IconThemeData(color: danger ? palette.redText : palette.text2, size: 16),
                    child: leading,
                  ),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: textColor),
                  ),
                ),
                ?trailing,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ZenithMenu extends StatefulWidget {
  const _ZenithMenu({required this.title, required this.subtitle, required this.items});

  final String title;
  final String? subtitle;
  final List<ZenithMenuItem> items;

  @override
  State<_ZenithMenu> createState() => _ZenithMenuState();
}

class _ZenithMenuState extends State<_ZenithMenu> {
  /// The hot row, as an index into [_entries].
  int? _hot;

  List<ZenithMenuEntry> get _entries => widget.items.whereType<ZenithMenuEntry>().toList();

  void _choose(ZenithMenuEntry entry) => Navigator.of(context).pop(entry);

  void _move(int step) {
    final count = _entries.length;
    if (count == 0) return;
    setState(() => _hot = _hot == null ? (step > 0 ? 0 : count - 1) : (_hot! + step) % count);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed || keyboard.isAltPressed || keyboard.isMetaPressed) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final entries = _entries;
    if (key == LogicalKeyboardKey.arrowDown) {
      _move(1);
    } else if (key == LogicalKeyboardKey.arrowUp) {
      _move(-1);
    } else if (key == LogicalKeyboardKey.home && event is KeyDownEvent) {
      setState(() => _hot = 0);
    } else if (key == LogicalKeyboardKey.end && event is KeyDownEvent) {
      setState(() => _hot = entries.length - 1);
    } else if (key == LogicalKeyboardKey.escape && event is KeyDownEvent) {
      Navigator.of(context).pop();
    } else if ((key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) && event is KeyDownEvent) {
      if (_hot case final hot?) _choose(entries[hot]);
    } else if (event is KeyDownEvent && entries.any((entry) => entry.accelerator == key)) {
      _choose(entries.firstWhere((entry) => entry.accelerator == key));
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final mono = ZenithType.of(context).monoSmall.copyWith(color: palette.text3);
    var index = 0;
    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: Semantics(
        scopesRoute: true,
        namesRoute: true,
        explicitChildNodes: true,
        role: ui.SemanticsRole.menu,
        label: widget.title,
        child: ZenithMenuSurface(
          width: 268,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
                child: ExcludeSemantics(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 1,
                    children: [
                      Text(
                        widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.labelMedium?.copyWith(color: palette.text, fontWeight: FontWeight.w600),
                      ),
                      if (widget.subtitle case final subtitle?)
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.labelSmall?.copyWith(color: palette.text3, fontWeight: FontWeight.w400),
                        ),
                    ],
                  ),
                ),
              ),
              for (final item in widget.items)
                switch (item) {
                  ZenithMenuSeparator() => Container(
                    height: 1,
                    margin: const EdgeInsets.symmetric(vertical: 5, horizontal: 4),
                    color: palette.line,
                  ),
                  ZenithMenuEntry() => _row(item, index++, mono),
                },
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(ZenithMenuEntry entry, int index, TextStyle mono) => ZenithMenuRow(
    label: entry.label,
    leading: Icon(entry.icon),
    trailing: entry.shortcut == null ? null : Text(entry.shortcut!, style: mono),
    hot: _hot == index,
    danger: entry.danger,
    semanticsHint: entry.shortcut,
    onHover: (inside) => setState(() {
      if (inside) {
        _hot = index;
      } else if (_hot == index) {
        _hot = null;
      }
    }),
    onTap: () => _choose(entry),
  );
}
