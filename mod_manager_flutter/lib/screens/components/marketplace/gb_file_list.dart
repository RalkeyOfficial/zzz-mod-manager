import 'package:flutter/material.dart';

import '../../../core/palette.dart';
import '../../../core/type_scale.dart';
import '../../../l10n/app_localizations.dart';
import '../../../models/gamebanana/gb_file.dart';
import '../../../services/gamebanana/file_selection.dart';
import '../../../services/installed_mods_index.dart';
import '../../../utils/byte_format.dart';
import '../mod_detail_parts.dart' show SectionHeading;
import '../zenith_controls.dart';
import 'gb_mod_card.dart' show relativeAgeLabel;

/// The files picked when a mod page opens: its one current file, or none when it publishes several, since which one
/// the user wants can't be told from what GameBanana publishes (`selectDefaultFile`).
Set<int> defaultPickedFiles(List<GbFile>? files) => {?selectDefaultFile(files).file?.idRow};

/// The mod page's Files: one row per current file, each picked or not with its square check, and the older files
/// behind a link under them, pickable too.
///
/// The selection rule is not implemented here, it lives in `services/gamebanana/file_selection.dart` so it can be
/// unit-tested against real captured profiles; this widget renders the picks it is handed.
class GbFileList extends StatelessWidget {
  const GbFileList({
    super.key,
    required this.files,
    required this.archivedFiles,
    required this.picked,
    required this.onToggle,
    this.showArchived = false,
    this.onToggleArchived,
    this.matchInstalled,
    this.now,
  });

  /// Current files. Null means the response never carried a list.
  final List<GbFile>? files;

  /// Superseded but still downloadable files.
  final List<GbFile>? archivedFiles;

  /// The ids of the files picked.
  final Set<int> picked;

  final ValueChanged<GbFile> onToggle;

  final bool showArchived;
  final VoidCallback? onToggleArchived;

  /// What the local library already has for one file. Null means "don't say", which is what a caller without a
  /// library snapshot gets.
  final InstalledFileMatch Function(GbFile file)? matchInstalled;

  /// What an upload's age is measured from; the clock when null.
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final current = files ?? const <GbFile>[];
    final archived = archivedFiles ?? const <GbFile>[];
    final at = now ?? DateTime.now().toUtc();

    Widget row(GbFile file) => GbFileRow(
      key: ValueKey('file_${file.idRow}'),
      file: file,
      picked: picked.contains(file.idRow),
      installed: matchInstalled?.call(file) ?? InstalledFileMatch.none,
      onTap: () => onToggle(file),
      now: at,
    );

    // What Show would reveal: the older files not already listed for being picked.
    final hidden = showArchived ? 0 : archived.where((file) => !picked.contains(file.idRow)).length;

    final String? notice = files == null
        ? loc.t('marketplace.files_not_loaded')
        : current.isEmpty && archived.isEmpty
        ? loc.t('marketplace.no_files')
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        SectionHeading(loc.t('marketplace.files_title')),
        if (notice != null)
          Text(notice, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: palette.text3))
        else ...[
          for (final file in current) row(file),
          // A picked older file keeps its row while hidden: Install counts and queues it, so it stays where it can be
          // seen and let go.
          for (final file in archived)
            if (showArchived || picked.contains(file.idRow)) row(file),
          if ((showArchived ? archived.isNotEmpty : hidden > 0) && onToggleArchived != null)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: ZenithLink(
                showArchived
                    ? loc.t('marketplace.hide_archived')
                    : loc.plural('marketplace.show_archived', hidden, params: {'count': '$hidden'}),
                onTap: onToggleArchived!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: palette.link),
              ),
            ),
        ],
      ],
    );
  }
}

/// One file as the design's `.file` row: the square check, the file name in mono, its variant text and upload age
/// under it, and its size at the right. Pressing the row picks it or lets it go.
class GbFileRow extends StatelessWidget {
  const GbFileRow({
    super.key,
    required this.file,
    required this.picked,
    required this.installed,
    required this.onTap,
    required this.now,
  });

  final GbFile file;
  final bool picked;
  final InstalledFileMatch installed;
  final VoidCallback onTap;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final type = ZenithType.of(context);
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10),
      side: BorderSide(color: picked ? pickedBorder(palette) : palette.line),
    );
    final chips = [
      if (file.isArchived) ZenithBadge(label: loc.t('marketplace.badge_archived'), tone: palette.badgeNeutral, small: true),
      ?_installedChip(loc, palette),
      // `_sAvResult` is a real safety signal, unlike an md5 match, so a result other than clean is shown verbatim.
      if (file.avResult case final av? when av.isNotEmpty && av.toLowerCase() != 'clean')
        ZenithBadge(label: av, tone: palette.badgeUpdate, small: true),
    ];

    return Semantics(
      checked: picked,
      child: Material(
        color: picked ? pickedGround(palette) : palette.field,
        shape: shape,
        child: InkWell(
          customBorder: shape,
          hoverColor: palette.rowHover,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 12,
              children: [
                Padding(padding: const EdgeInsets.only(top: 1), child: _PickBox(on: picked)),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        fileDisplayName(file),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: type.mono.copyWith(color: palette.text),
                      ),
                      Text(
                        _detail(loc),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall?.copyWith(color: palette.text3),
                      ),
                      if (chips.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Wrap(spacing: 6, runSpacing: 4, children: chips),
                        ),
                    ],
                  ),
                ),
                if (file.filesize case final bytes?)
                  Text(formatBytes(bytes), style: type.monoSmall.copyWith(color: palette.text3, height: 1.45)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// "“Full dress” · uploaded 5 days ago", or "no variant text · uploaded …" when the author gave the file none.
  String _detail(AppLocalizations loc) {
    final variant = fileDisplayDetail(file);
    return [
      if (variant != null)
        loc.t('marketplace.file_variant', params: {'variant': variant})
      else
        loc.t('marketplace.file_no_variant'),
      if (file.dateAdded case final date?)
        loc.t('marketplace.file_uploaded', params: {'age': relativeAgeLabel(loc, date, now)}),
    ].join(' · ');
  }

  /// "installed" or "you have this", or null when the library says nothing.
  ///
  /// The two are separate labels on purpose. A `file_id` match means *we installed this file*, a direct record. A
  /// hash match means the archive on the way in was **byte-identical** to this published file, a statement about
  /// bytes and not an identity we recorded. Neither is a safety or integrity claim: md5 is a matching key only, so
  /// there is no checkmark and no shield here.
  Widget? _installedChip(AppLocalizations loc, ZenithPalette palette) {
    final mods = installed.folders.join(', ');
    return switch (installed.evidence) {
      InstalledFileEvidence.none => null,
      InstalledFileEvidence.fileId => ZenithBadge(
        label: loc.t('marketplace.badge_file_installed'),
        tone: palette.badgeOn,
        small: true,
        tooltip: loc.t('marketplace.file_installed_as', params: {'mods': mods}),
      ),
      InstalledFileEvidence.archiveHash => ZenithBadge(
        label: loc.t('marketplace.badge_file_same'),
        tone: palette.badgeOn,
        small: true,
        tooltip: loc.t('marketplace.file_same_as', params: {'mods': mods}),
      ),
    };
  }
}

/// The border of a picked row or card: the accent mixed 60% into the line, the design's `.file.on`.
Color pickedBorder(ZenithPalette palette) => Color.lerp(palette.line, palette.accent, 0.6)!;

/// The ground of a picked row or card: the accent washed 7% into the field.
Color pickedGround(ZenithPalette palette) => Color.lerp(palette.field, palette.accent, 0.07)!;

/// The design's `.rad`: an 18px square check, filled with the accent and ticked when on.
class _PickBox extends StatelessWidget {
  const _PickBox({required this.on});

  final bool on;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    return Container(
      width: 18,
      height: 18,
      decoration: BoxDecoration(
        color: on ? palette.accent : null,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: on ? palette.accent : palette.check, width: 1.5),
      ),
      child: on ? Icon(Icons.check_rounded, size: 12, color: palette.onAccent) : null,
    );
  }
}
