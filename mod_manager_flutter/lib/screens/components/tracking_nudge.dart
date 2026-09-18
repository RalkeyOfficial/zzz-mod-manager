import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import 'mod_status_slot.dart';

/// Persists the reminder's dismissal. Production is `ApiService.setTrackingNudgeDismissed`;
/// tests inject one so mounting the widget never reaches the developer's own `config.json`.
typedef NudgeDismissWriter = Future<void> Function(bool dismissed);

/// The reminder above the toolbar that some mods are not set up for update checking.
class TrackingNudge extends StatelessWidget {
  const TrackingNudge({
    super.key,
    required this.count,
    required this.onSortOut,
    required this.onDismiss,
  });

  final int count;
  final VoidCallback onSortOut;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final scheme = Theme.of(context).colorScheme;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        color: ModStatusSlot.amber.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: ModStatusSlot.amber.withValues(alpha: 0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Icon(Icons.priority_high, size: 18, color: ModStatusSlot.amber),
          ),
          const SizedBox(width: 8),
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
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                    Text(
                      loc.t('mods.nudge.hint'),
                      style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
                TextButton(
                  onPressed: onSortOut,
                  child: Text(loc.t('mods.toolbar.sort_out_tracking')),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 16),
            tooltip: loc.t('mods.nudge.dismiss'),
            onPressed: onDismiss,
          ),
        ],
      ),
    );
  }
}
