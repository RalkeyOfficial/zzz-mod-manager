import 'package:flutter/material.dart';

import '../../core/palette.dart';
import '../../core/type_scale.dart';

/// One row of the sidebar: an icon, a label and an optional count.
///
/// The current row is raised and outlined, with its icon in the accent. A [hot] count is an amber pill, for the
/// one count that asks for attention (updates). Tab reaches the row and Enter or Space presses it; a focused row is
/// outlined in the accent.
class SidebarNavItem extends StatefulWidget {
  const SidebarNavItem({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.selected = false,
    this.count,
    this.hot = false,
    this.badge,
  });

  static const double height = 38;

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool selected;
  final int? count;
  final bool hot;

  /// Drawn where the count goes, in place of it: a [SidebarBadge].
  final Widget? badge;

  @override
  State<SidebarNavItem> createState() => _SidebarNavItemState();
}

class _SidebarNavItemState extends State<SidebarNavItem> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final selected = widget.selected;
    final background = selected ? palette.rowSelected : (_hovered ? palette.rowHover : Colors.transparent);
    final foreground = selected || _hovered ? palette.text : palette.text2;
    final border = _focused ? palette.accent : (selected ? palette.line : Colors.transparent);

    return Semantics(
      button: true,
      selected: selected,
      onTap: widget.onTap,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowHoverHighlight: (hovered) => setState(() => _hovered = hovered),
        onShowFocusHighlight: (focused) => setState(() => _focused = focused),
        actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => widget.onTap())},
        child: GestureDetector(
          onTap: widget.onTap,
          excludeFromSemantics: true,
          child: Container(
            height: SidebarNavItem.height,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: border),
            ),
            child: Row(
              spacing: 12,
              children: [
                Icon(widget.icon, size: 16, color: selected ? palette.accent : foreground),
                Expanded(
                  child: Text(
                    widget.label,
                    overflow: TextOverflow.ellipsis,
                    style: text.labelLarge?.copyWith(color: foreground),
                  ),
                ),
                if (widget.badge case final badge?)
                  badge
                else if (widget.count != null)
                  _Count(count: widget.count!, hot: widget.hot),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A pill for a sidebar row: a 12px [icon] and a [count] in [tone], such as the Downloads row's amber triangle for
/// downloads waiting for an answer. [label] is its tooltip and what a screen reader says for it.
class SidebarBadge extends StatelessWidget {
  const SidebarBadge({
    super.key,
    required this.icon,
    required this.count,
    required this.tone,
    required this.label,
  });

  final IconData icon;
  final int count;
  final TonePair tone;
  final String label;

  @override
  Widget build(BuildContext context) {
    final style = ZenithType.of(context).monoSmall.copyWith(fontWeight: FontWeight.w600, color: tone.foreground);
    return Tooltip(
      message: label,
      excludeFromSemantics: true,
      child: Semantics(
        label: label,
        excludeSemantics: true,
        child: Container(
          padding: const EdgeInsets.fromLTRB(5, 3, 6, 3),
          decoration: BoxDecoration(color: tone.background, borderRadius: BorderRadius.circular(5)),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 4,
            children: [
              Icon(icon, size: 12, color: tone.foreground),
              Text('$count', style: style),
            ],
          ),
        ),
      ),
    );
  }
}

class _Count extends StatelessWidget {
  const _Count({required this.count, required this.hot});

  final int count;
  final bool hot;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    final style = ZenithType.of(context).monoSmall.copyWith(fontWeight: FontWeight.w500);
    if (!hot) return Text('$count', style: style.copyWith(color: palette.text3));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: palette.badgeUpdate.background,
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text('$count', style: style.copyWith(color: palette.badgeUpdate.foreground)),
    );
  }
}
