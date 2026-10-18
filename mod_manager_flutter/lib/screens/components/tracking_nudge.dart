import 'package:flutter/material.dart';

import '../../core/palette.dart';
import '../../l10n/app_localizations.dart';
import 'zenith_controls.dart';

/// Persists the reminder's dismissal. Production is `ApiService.setTrackingNudgeDismissed`;
/// tests inject one so mounting the widget never reaches the developer's own `config.json`.
typedef NudgeDismissWriter = Future<void> Function(bool dismissed);

/// The reminder above the mod grid that some mods are not set up for update checking. Blue, the colour of
/// tracking: it asks for something, and nothing is wrong.
class TrackingNudge extends StatelessWidget {
  const TrackingNudge({
    super.key,
    required this.count,
    required this.onSortOut,
    required this.onDismiss,
  });

  final int count;

  /// Null while an update check is running, which the button would otherwise start a second of.
  final VoidCallback? onSortOut;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final tone = palette.badgeInfo;

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
      decoration: BoxDecoration(
        color: tone.background,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: tone.border!),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline_rounded, color: tone.foreground),
          const SizedBox(width: 10),
          // A Wrap so the button drops under the text when the two do not fit side by side.
          Expanded(
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 4,
              children: [
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      loc.plural('mods.nudge.title', count, params: {'count': '$count'}),
                      style: text.bodyMedium?.copyWith(color: palette.text, fontWeight: FontWeight.w600),
                    ),
                    Text(loc.t('mods.nudge.hint'), style: text.bodySmall?.copyWith(color: palette.text2)),
                  ],
                ),
                OutlinedButton(
                  style: smallButtonStyle(context),
                  onPressed: onSortOut,
                  child: Text(loc.t('mods.toolbar.sort_out_tracking')),
                ),
              ],
            ),
          ),
          IconButton(
            style: smallButtonStyle(context, iconOnly: true),
            icon: const Icon(Icons.close_rounded),
            tooltip: loc.t('mods.nudge.dismiss'),
            onPressed: onDismiss,
          ),
        ],
      ),
    );
  }
}
