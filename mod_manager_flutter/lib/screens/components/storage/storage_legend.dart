import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../services/storage/storage_usage.dart';
import '../../../utils/byte_format.dart';

/// One category's row beneath the ring: swatch, name, size, and what to say
/// when there is no size to give.
///
/// **The size slot is where "nothing" and "don't know" are kept apart.** A
/// library with no folder set renders the reason, not `0 B` — the two read
/// completely differently to someone wondering where their disk went.
class StorageLegendRow extends StatelessWidget {
  const StorageLegendRow({
    super.key,
    required this.category,
    required this.color,
    required this.label,
    required this.hint,
    this.expanded = false,
    this.onTap,
  });

  final StorageCategory category;
  final Color color;
  final String label;

  /// What this category actually holds, in the user's words. Not optional:
  /// "Leftovers" and "Covers & metadata" mean nothing on their own, and a
  /// figure the reader cannot name is a figure they cannot act on.
  final String hint;

  final bool expanded;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final drillable = onTap != null && category.items.isNotEmpty;

    return InkWell(
      onTap: drillable ? onTap : null,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: Row(
          children: [
            Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: category.hasMeasurement && category.bytes > 0
                    ? color
                    : theme.dividerColor,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            const SizedBox(width: 12),
            // The label takes the slack and the value keeps its intrinsic size;
            // the reverse squeezes the number to an ellipsis at a narrow window.
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: theme.textTheme.bodyMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    hint,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.textTheme.labelSmall?.color
                          ?.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            _Value(category: category),
            if (drillable) ...[
              const SizedBox(width: 4),
              Icon(
                expanded ? Icons.expand_less : Icons.chevron_right,
                size: 18,
                color: theme.iconTheme.color?.withValues(alpha: 0.6),
              ),
            ] else
              const SizedBox(width: 22),
          ],
        ),
      ),
    );
  }
}

class _Value extends StatelessWidget {
  const _Value({required this.category});

  final StorageCategory category;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final theme = Theme.of(context);

    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.textTheme.bodySmall?.color?.withValues(alpha: 0.6),
      fontStyle: FontStyle.italic,
    );

    return switch (category.read) {
      StorageRead.notConfigured =>
        Text(loc.t('storage.read.not_configured'), style: muted),
      StorageRead.absent => Text(loc.t('storage.read.absent'), style: muted),
      StorageRead.unreadable =>
        Text(loc.t('storage.read.unreadable'), style: muted),
      StorageRead.partial => Text(
          loc.t('storage.at_least',
              params: {'size': formatBytes(category.bytes)}),
          style: theme.textTheme.bodyMedium
              ?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
        ),
      StorageRead.ok => Text(
          formatBytes(category.bytes),
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
    };
  }
}
