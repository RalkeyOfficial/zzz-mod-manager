import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../services/storage/storage_usage.dart';
import '../../../utils/byte_format.dart';

/// The rows under an expanded category: its biggest items, then the fold.
///
/// The tail row is not decoration. Without it the visible rows come to less
/// than the category's own figure, and a reader who adds them up finds the
/// page disagreeing with itself.
class StorageCategoryDetail extends StatelessWidget {
  const StorageCategoryDetail({super.key, required this.category});

  final StorageCategory category;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final theme = Theme.of(context);

    if (category.items.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(32, 4, 8, 12),
        child: Text(
          loc.t('storage.empty'),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.textTheme.bodySmall?.color?.withValues(alpha: 0.6),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 0, 8, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final item in category.items) _ItemRow(item: item),
          if (category.tailCount > 0)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      loc.plural('storage.more', category.tailCount,
                          params: {'count': '${category.tailCount}'}),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.textTheme.bodySmall?.color
                            ?.withValues(alpha: 0.6),
                      ),
                    ),
                  ),
                  Text(
                    formatBytes(category.tailBytes),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.textTheme.bodySmall?.color
                          ?.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({required this.item});

  final StorageItem item;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final theme = Theme.of(context);
    final linked = item.kind == StorageItemKind.linked;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(_iconFor(item.kind), size: 15, color: theme.dividerColor),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.label,
                  style: theme.textTheme.bodySmall,
                  overflow: TextOverflow.ellipsis,
                ),
                if (_subtitle(loc, item) case final subtitle?)
                  Text(
                    subtitle,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.textTheme.labelSmall?.color
                          ?.withValues(alpha: 0.6),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            // A link holds no bytes of its own, and "0 B" beside a mod's name
            // reads as an empty mod rather than as one living elsewhere.
            linked ? loc.t('storage.item.linked') : formatBytes(item.bytes),
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: linked ? FontWeight.w400 : FontWeight.w600,
              fontStyle: linked ? FontStyle.italic : FontStyle.normal,
            ),
          ),
        ],
      ),
    );
  }

  static String? _subtitle(AppLocalizations loc, StorageItem item) {
    if (item.kind == StorageItemKind.snapshotGroup) {
      return loc.plural('storage.item.versions', item.fileCount,
          params: {'count': '${item.fileCount}'});
    }
    if (item.detailKey != null) return loc.t(item.detailKey!);
    return null;
  }

  static IconData _iconFor(StorageItemKind kind) => switch (kind) {
        StorageItemKind.modFolder => Icons.folder_outlined,
        StorageItemKind.snapshotGroup => Icons.history_rounded,
        StorageItemKind.snapshot => Icons.history_rounded,
        StorageItemKind.archive => Icons.archive_outlined,
        StorageItemKind.partialDownload => Icons.downloading_rounded,
        StorageItemKind.directory => Icons.folder_outlined,
        StorageItemKind.file => Icons.description_outlined,
        StorageItemKind.linked => Icons.link_rounded,
      };
}
