import 'package:flutter/material.dart';

import '../../core/palette.dart';
import '../../core/type_scale.dart';

/// One row of the sidebar: an icon, a label and an optional count.
///
/// The current row is raised and outlined, with its icon in the accent. A [hot] count is an amber pill, for the
/// one count that asks for attention (updates).
class SidebarNavItem extends StatefulWidget {
  const SidebarNavItem({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.selected = false,
    this.count,
    this.hot = false,
  });

  static const double height = 38;

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool selected;
  final int? count;
  final bool hot;

  @override
  State<SidebarNavItem> createState() => _SidebarNavItemState();
}

class _SidebarNavItemState extends State<SidebarNavItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final selected = widget.selected;
    final background = selected ? palette.raised : (_hovered ? palette.rowHover : Colors.transparent);
    final foreground = selected || _hovered ? palette.text : palette.text2;

    return Semantics(
      button: true,
      selected: selected,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            height: SidebarNavItem.height,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: selected ? palette.line : Colors.transparent),
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
                if (widget.count != null) _Count(count: widget.count!, hot: widget.hot),
              ],
            ),
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
