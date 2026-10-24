import 'package:flutter/material.dart';

import '../../../core/palette.dart';
import '../../../core/type_scale.dart';
import '../../../l10n/app_localizations.dart';
import '../../../services/storage/storage_usage.dart';
import '../../../utils/byte_format.dart';

/// The groups of saved versions under the Saved versions row: each mod's name, how many it has and what they take, largest first, then the fold, so the rows still add up to the category's own figure.
/// Every group [clear] would take is listed, however small, so the fold never hides one.
///
/// [unclaimed] holds the uids of the groups no mod in the library carries, or is null while the library is not read.
/// [clear] is the button that takes those groups, shown by the caller.
class SavedVersionsDetail extends StatelessWidget {
  const SavedVersionsDetail({super.key, required this.category, required this.unclaimed, this.clear});

  final StorageCategory category;
  final Set<String>? unclaimed;
  final Widget? clear;

  /// Groups listed before the rest are folded into one row.
  static const int listed = 20;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final folded = foldTail(category.items, cap: listed, keep: (item) => unclaimed?.contains(item.id) ?? false);

    return Container(
      decoration: BoxDecoration(border: Border(top: BorderSide(color: palette.rowDivider))),
      padding: const EdgeInsets.fromLTRB(46, 8, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (category.items.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(loc.t('storage.empty'), style: text.bodySmall?.copyWith(color: palette.text3)),
            ),
          for (final item in folded.items) _Group(item: item, orphan: unclaimed?.contains(item.id) ?? false),
          if (folded.tailCount > 0)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                spacing: 12,
                children: [
                  Expanded(
                    child: Text(
                      loc.plural('storage.more', folded.tailCount, params: {'count': '${folded.tailCount}'}),
                      style: text.bodySmall?.copyWith(color: palette.text3),
                    ),
                  ),
                  Text(formatBytes(folded.tailBytes), style: ZenithType.of(context).mono.copyWith(color: palette.text3)),
                ],
              ),
            ),
          if (clear != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Align(alignment: Alignment.centerLeft, child: clear),
            ),
        ],
      ),
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.item, required this.orphan});

  final StorageItem item;
  final bool orphan;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final versions = loc.plural('storage.item.versions', item.fileCount, params: {'count': '${item.fileCount}'});

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 12,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodyMedium?.copyWith(color: palette.text, fontWeight: FontWeight.w600),
                ),
                Text(
                  orphan ? '$versions · ${loc.t('storage.item.orphan')}' : versions,
                  style: text.bodySmall?.copyWith(color: orphan ? palette.amber : palette.text3),
                ),
              ],
            ),
          ),
          Text(formatBytes(item.bytes), style: ZenithType.of(context).mono.copyWith(color: palette.textProse)),
        ],
      ),
    );
  }
}
