import 'package:flutter/material.dart';

/// One row of the sidebar's tab list — an icon, and a label when the sidebar is
/// open.
///
/// **Nothing here may overflow at any width between the two resting points**,
/// and that is the whole design. The sidebar animates its width between
/// [collapsedWidth] and [expandedWidth] over 300ms, while [collapsed] flips in a
/// single frame — so on *expand* the label is inserted immediately, into a row
/// still only as wide as the collapsed sidebar. That threw `RenderFlex
/// overflowed by 28 pixels` on every open.
///
/// Two things make it impossible rather than unlikely:
///
/// - **The horizontal padding is constant.** It used to widen from 12 to 16 on
///   expand, in the same frame as the label appeared, leaving `80 - 32 - 32 =
///   16` for a 22px icon — so at the first frame the *icon alone* did not fit
///   and no amount of shrinking the label would have helped. At a constant 12
///   the narrowest the row ever gets is `80 - 32 - 24 = 24`, which the icon
///   always fits inside.
/// - **The label and the gap before it are one [Flexible] unit**, ellipsising
///   together. The gap used to be a rigid `SizedBox`, so `22 + 14` exceeded the
///   24 available before the text was even measured. Flexed, the pair simply
///   collapses to nothing mid-animation and grows to its natural size once
///   there is room.
///
/// The icon fitting the narrowest row is therefore the single invariant the
/// whole widget rests on, and it holds with 2px to spare.
///
/// **A `LayoutBuilder` deciding all this from the live width was tried first and
/// cannot be used here.** The sidebar is inside an `IntrinsicHeight`, which asks
/// its children for intrinsic dimensions, and `LayoutBuilder` refuses to answer
/// that — it threw on every frame and the app never finished rendering. Any
/// future fix in this subtree is under the same constraint.
class SidebarNavItem extends StatelessWidget {
  const SidebarNavItem({
    super.key,
    required this.icon,
    required this.label,
    required this.isActive,
    required this.collapsed,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool isActive;

  /// Whether the sidebar is collapsed. Flips a frame before the width finishes
  /// animating — see the class doc for why that is survivable here.
  final bool collapsed;

  final VoidCallback onTap;

  /// The two widths the sidebar animates between.
  static const double collapsedWidth = 80;
  static const double expandedWidth = 220;

  /// Constant, and load-bearing. See the class doc.
  static const double _horizontalPadding = 12;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Tooltip(
        message: collapsed ? label : '',
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(12),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              padding: const EdgeInsets.symmetric(
                horizontal: _horizontalPadding,
                vertical: 14,
              ),
              decoration: BoxDecoration(
                gradient: isActive
                    ? const LinearGradient(
                        colors: [Color(0xFF0EA5E9), Color(0xFF06B6D4)],
                      )
                    : null,
                color: isActive ? null : Colors.transparent,
                borderRadius: BorderRadius.circular(12),
                boxShadow: isActive
                    ? [
                        BoxShadow(
                          color: const Color(0xFF0EA5E9).withValues(alpha: 0.4),
                          blurRadius: 12,
                          spreadRadius: 1,
                          offset: const Offset(0, 4),
                        ),
                      ]
                    : null,
              ),
              child: Row(
                mainAxisAlignment: collapsed
                    ? MainAxisAlignment.center
                    : MainAxisAlignment.start,
                children: [
                  AnimatedScale(
                    scale: isActive ? 1.1 : 1.0,
                    duration: const Duration(milliseconds: 200),
                    child: Icon(
                      icon,
                      size: 22,
                      color: isActive ? Colors.white : Colors.grey[600],
                    ),
                  ),
                  if (!collapsed)
                    // Gap and label together, so the pair shrinks as one. A
                    // rigid gap outside the Flexible would overflow on its own
                    // before the text was ever measured.
                    Flexible(
                      child: Padding(
                        padding: const EdgeInsets.only(left: 14),
                        child: AnimatedDefaultTextStyle(
                          duration: const Duration(milliseconds: 300),
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight:
                                isActive ? FontWeight.w600 : FontWeight.w500,
                            color: isActive ? Colors.white : Colors.grey[600],
                            letterSpacing: 0.3,
                          ),
                          child: Text(
                            label,
                            maxLines: 1,
                            softWrap: false,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
