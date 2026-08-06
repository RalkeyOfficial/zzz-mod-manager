import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../models/gamebanana/gb_file.dart';
import '../../../services/gamebanana/file_selection.dart';
import '../../../services/installed_mods_index.dart';

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
    this.matchInstalled,
  });

  /// Current files. Null means the response never carried a list.
  final List<GbFile>? files;

  /// Superseded but still downloadable files.
  final List<GbFile>? archivedFiles;

  final void Function(GbFile file) onDownload;

  final bool showArchived;
  final VoidCallback? onToggleArchived;

  /// What the local library already has for one file. Null means "don't say" —
  /// which is what tests and any caller without a library snapshot get.
  final InstalledFileMatch Function(GbFile file)? matchInstalled;

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
            installed: matchInstalled?.call(file) ?? InstalledFileMatch.none,
            onDownload: () => onDownload(file),
          ),
        if (showArchived)
          for (final file in archived)
            _FileRow(
              file: file,
              isDefault: false,
              installed: matchInstalled?.call(file) ?? InstalledFileMatch.none,
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
    required this.installed,
    required this.onDownload,
  });

  final GbFile file;
  final bool isDefault;
  final InstalledFileMatch installed;
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
                // A `Wrap`, not a `Row`, and that is load-bearing since the
                // second chip landed here. The chips are fixed-width — their
                // labels are three words, so there is nothing to ellipsise — so
                // in a `Row` the only thing that could give way was the
                // filename, and once it had shrunk to nothing the row simply
                // overflowed. Measured: with only the `older` chip it survived a
                // 2× OS text scale, with an installed chip beside it it broke at
                // **1.3×** in a minimum-width window. `Wrap` gives the label the
                // full width to ellipsise within and moves the chips to a second
                // line when they no longer fit beside it, so overflow is not
                // expressible — and the row has no fixed height, so growing is
                // free.
                Wrap(
                  spacing: 6,
                  runSpacing: 2,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      fileDisplayLabel(file),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    if (file.isArchived)
                      _chip(context, loc.t('marketplace.badge_archived'),
                          scheme.onSurfaceVariant),
                    if (_installedChip(context, loc) case final chip?) chip,
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

  /// "installed" or "you have this", or null when the library says nothing.
  ///
  /// The two are separate labels on purpose, and the difference is not cosmetic.
  /// A `file_id` match means *we installed this file* — a direct record. A hash
  /// match means the archive on the way in was **byte-identical** to this
  /// published file, which is a statement about bytes and not an identity we
  /// recorded, so it is worded as one. Neither is a safety or integrity claim:
  /// md5 is a matching key only, so there is no checkmark and no shield here.
  ///
  /// Both use `primary`, the same colour as the card's badge and the detail view's
  /// notice — one colour per meaning across the marketplace, so "you already have
  /// this" doesn't change hue depending on which screen you are looking at.
  Widget? _installedChip(BuildContext context, AppLocalizations loc) {
    final colour = Theme.of(context).colorScheme.primary;
    final mods = installed.folders.join(', ');
    return switch (installed.evidence) {
      InstalledFileEvidence.none => null,
      InstalledFileEvidence.fileId => Tooltip(
          message: loc.t('marketplace.file_installed_as',
              params: {'mods': mods}),
          child: _chip(
            context,
            loc.t('marketplace.badge_file_installed'),
            colour,
          ),
        ),
      InstalledFileEvidence.archiveHash => Tooltip(
          message: loc.t('marketplace.file_same_as', params: {'mods': mods}),
          child: _chip(
            context,
            loc.t('marketplace.badge_file_same'),
            colour,
          ),
        ),
    };
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
