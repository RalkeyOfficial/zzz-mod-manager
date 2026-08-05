import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../models/gamebanana/gb_file.dart';
import '../../../services/gamebanana/file_selection.dart';

/// The mod detail screen's file list: one row per downloadable file, each with
/// its label, upload date, size, scan result and a download button.
///
/// The selection rule is not implemented here — it lives in
/// `services/gamebanana/file_selection.dart` so it can be unit-tested against
/// real captured profiles. This widget only *renders* the outcome, including
/// saying out loud when the user has to choose.
class GbFileList extends StatelessWidget {
  const GbFileList({
    super.key,
    required this.files,
    required this.archivedFiles,
    required this.onDownload,
    this.showArchived = false,
    this.onToggleArchived,
  });

  /// Current files. Null means the response never carried a list.
  final List<GbFile>? files;

  /// Superseded but still downloadable files.
  final List<GbFile>? archivedFiles;

  final void Function(GbFile file) onDownload;

  final bool showArchived;
  final VoidCallback? onToggleArchived;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final theme = Theme.of(context);
    final defaultChoice = selectDefaultFile(files);
    final current = files ?? const <GbFile>[];
    final archived = archivedFiles ?? const <GbFile>[];

    if (defaultChoice.reason == FileDefaultReason.noFiles && archived.isEmpty) {
      return _notice(context, loc.t('marketplace.no_files'), Icons.block);
    }
    if (defaultChoice.reason == FileDefaultReason.notLoaded) {
      return _notice(context, loc.t('marketplace.files_not_loaded'), Icons.help_outline);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              loc.t('marketplace.files_title'),
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const Spacer(),
            if (archived.isNotEmpty && onToggleArchived != null)
              TextButton.icon(
                onPressed: onToggleArchived,
                icon: Icon(
                  showArchived ? Icons.expand_less : Icons.history,
                  size: 16,
                ),
                label: Text(
                  loc.t(
                    showArchived
                        ? 'marketplace.hide_archived'
                        : 'marketplace.show_archived',
                    params: {'count': '${archived.length}'},
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        // Told, not implied. When several files exist the app genuinely cannot
        // tell which one the user wants — see selectDefaultFile for why that is
        // a property of the data, not a missing feature — so it says so instead
        // of preselecting one and hoping.
        if (defaultChoice.reason == FileDefaultReason.ambiguous)
          _notice(
            context,
            loc.t('marketplace.pick_a_file'),
            Icons.info_outline,
          ),
        const SizedBox(height: 4),
        for (final file in current)
          _FileRow(
            file: file,
            isDefault: defaultChoice.file?.idRow == file.idRow,
            onDownload: () => onDownload(file),
          ),
        if (showArchived)
          for (final file in archived)
            _FileRow(
              file: file,
              isDefault: false,
              onDownload: () => onDownload(file),
            ),
      ],
    );
  }

  Widget _notice(BuildContext context, String message, IconData icon) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(icon, size: 15, color: scheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

class _FileRow extends StatelessWidget {
  const _FileRow({
    required this.file,
    required this.isDefault,
    required this.onDownload,
  });

  final GbFile file;
  final bool isDefault;
  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isDefault
              ? scheme.primary.withValues(alpha: 0.5)
              : scheme.outlineVariant.withValues(alpha: 0.4),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        fileDisplayLabel(file),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                    if (file.isArchived) ...[
                      const SizedBox(width: 6),
                      _chip(context, loc.t('marketplace.badge_archived'),
                          scheme.onSurfaceVariant),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  _subtitle(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // `_sAvResult` is shown verbatim because, unlike an md5 match, it
          // genuinely is a safety signal.
          if (file.avResult case final av? when av.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _chip(
                context,
                av,
                av.toLowerCase() == 'clean' ? Colors.green : scheme.tertiary,
              ),
            ),
          FilledButton.icon(
            onPressed: onDownload,
            icon: const Icon(Icons.download, size: 16),
            label: Text(loc.t('marketplace.download')),
          ),
        ],
      ),
    );
  }

  /// Filename · size · upload date, skipping whatever the response omitted.
  String _subtitle() {
    final parts = <String>[
      if (file.file case final name? when name.isNotEmpty) name,
      if (file.filesize case final bytes?) _size(bytes),
      if (file.dateAdded case final date?) _date(date),
    ];
    return parts.isEmpty ? '#${file.idRow}' : parts.join(' · ');
  }

  Widget _chip(BuildContext context, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.w600),
      ),
    );
  }

  static String _size(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '$bytes B';
  }

  static String _date(DateTime date) {
    final d = date.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }
}
