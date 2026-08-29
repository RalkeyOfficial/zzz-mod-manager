import 'package:flutter/material.dart';

/// One setting: a label, a sentence explaining it, and its control.
///
/// The **description is the point of this widget**, and why the Settings tab's
/// older `_buildSettingRow` could not be reused. That row is label-plus-control
/// and nothing else, which is enough for *Dark mode* and for nothing that has a
/// consequence. Every setting below carries one — one contacts the network at
/// startup, the other decides whether adult content is on screen — and a bare
/// label leaves the user to guess what a switch commits them to.
///
/// The chrome deliberately matches that older row (card colour, 8px radius,
/// hairline border) so the sections do not read as two different screens.
class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    required this.label,
    required this.description,
    required this.trailing,
  });

  final String label;
  final String description;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.1)
              : Colors.black.withValues(alpha: 0.05),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // The text takes the slack and the control keeps its intrinsic size:
          // the reverse wraps a switch into a sliver at a narrow window, which
          // is where this tab's layout has broken before.
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          trailing,
        ],
      ),
    );
  }
}
