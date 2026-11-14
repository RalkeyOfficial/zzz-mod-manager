/// What a finished update says about one mod beyond its outcome (`docs/update-runs.md` §5): the files the write removed,
/// the hotkeys it changed with a small list of before and after, and the archive's folders it left out.
/// The Updates page's row and the Downloads panel's Finished line draw the same lines from the same job.
library;

import 'package:flutter/material.dart';

import '../../core/palette.dart';
import '../../core/type_scale.dart';
import '../../l10n/app_localizations.dart';
import '../../services/download/download_job.dart';
import '../../services/update_apply/keybind_changes.dart';
import '../../services/update_apply/update_write.dart' show UpdateReportOf;
import 'zenith_controls.dart';
import 'zenith_dialog.dart';

/// What a finished update job did for one of its mods, read off its report.
class UpdateFinishedFacts {
  const UpdateFinishedFacts({
    this.heldFileDate,
    this.folderId,
    this.dropped = 0,
    this.hotkeys = const <KeybindChange>[],
    this.leftOut = const <String>[],
  });

  /// The upload date of the file the mod held before the write, the one its snapshot keeps.
  final DateTime? heldFileDate;

  /// The folder the write changed: the mod's own, or the one its file went into as a patch. Null when it wrote none.
  final String? folderId;

  /// How many files that were in that folder are not there now.
  final int dropped;

  /// The keys the write moved or removed in that folder.
  final List<KeybindChange> hotkeys;

  /// The archive's top-level folders no written folder took, by name: the job's, said once for all its mods.
  final List<String> leftOut;

  /// The facts of the mod in the folder [modId] of [job]: what the write did for a mod it wrote and Undo has not taken back,
  /// into its own folder or another's, and only the date of the file it held otherwise, which an undone mod is back on.
  static UpdateFinishedFacts of(DownloadJob job, String modId) {
    final report = job.updateReport;
    final result = job.resultFor(modId);
    final held = report?.removedMarks[modId]?.installedFile?.dateAdded;
    final write = result != null && result.hasWrite && !result.undone ? report?.writeFor(modId) : null;
    if (report == null || write == null) return UpdateFinishedFacts(heldFileDate: held);
    return UpdateFinishedFacts(
      heldFileDate: held,
      folderId: write.mod.id,
      dropped: write.result.droppedFiles.length,
      hotkeys: write.result.keybindChanges,
      leftOut: report.leftOut,
    );
  }

  /// The same facts without [leftOut], for a line among the job's others that says it once for them all.
  UpdateFinishedFacts get ownOnly =>
      UpdateFinishedFacts(heldFileDate: heldFileDate, folderId: folderId, dropped: dropped, hotkeys: hotkeys);
}

/// "14 old files removed · 2 hotkeys changed · not installed from the file: Previews", in that order and only what is true,
/// led by [lead] when given. "2 hotkeys changed" opens the list of before and after for [modName], the mod of the folder they changed in.
class UpdateFinishedDetail extends StatelessWidget {
  const UpdateFinishedDetail({
    super.key,
    required this.facts,
    required this.modName,
    this.lead,
    this.alignEnd = false,
  });

  final UpdateFinishedFacts facts;
  final String modName;
  final String? lead;

  /// Right-aligned, as the Updates page's status cell is.
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(color: palette.text3);
    final hotkeys = facts.hotkeys.length;
    final parts = <Widget>[
      if (lead case final lead?) Text(lead, style: style),
      if (facts.dropped > 0)
        Text(loc.plural('downloads.update.dropped', facts.dropped, params: {'count': '${facts.dropped}'}), style: style),
      if (hotkeys > 0)
        ZenithLink(
          loc.plural('downloads.update.hotkeys', hotkeys, params: {'count': '$hotkeys'}),
          onTap: () => showHotkeyChanges(context, modName: modName, changes: facts.hotkeys),
          style: style?.copyWith(color: palette.link),
        ),
      if (facts.leftOut.isNotEmpty)
        Text(loc.t('downloads.update.left_out', params: {'folders': facts.leftOut.join(', ')}), style: style),
    ];
    if (parts.isEmpty) return const SizedBox.shrink();
    return Wrap(
      alignment: alignEnd ? WrapAlignment.end : WrapAlignment.start,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final (i, part) in parts.indexed) ...[
          if (i > 0) Text(' · ', style: style),
          part,
        ],
      ],
    );
  }
}

/// The hotkeys an update of [modName] changed, each as it was and as it is now: the one place a rebound key the author's `.ini` replaced shows before the game.
Future<void> showHotkeyChanges(
  BuildContext context, {
  required String modName,
  required List<KeybindChange> changes,
}) {
  final loc = context.loc;
  return showDialog<void>(
    context: context,
    builder: (dialogContext) {
      final palette = ZenithPalette.of(dialogContext);
      final text = Theme.of(dialogContext).textTheme;
      final keyStyle = ZenithType.of(dialogContext).mono.copyWith(color: palette.text);
      return ZenithDialog.compact(
        width: 440,
        title: loc.plural('downloads.update.hotkeys', changes.length, params: {'count': '${changes.length}'}),
        subtitle: modName,
        body: Table(
          columnWidths: const {0: FlexColumnWidth(), 1: IntrinsicColumnWidth(), 2: IntrinsicColumnWidth(), 3: IntrinsicColumnWidth()},
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          children: [
            TableRow(children: [
              for (final heading in ['downloads.update.hotkeys_key', 'downloads.update.hotkeys_before', '', 'downloads.update.hotkeys_after'])
                Padding(
                  padding: const EdgeInsets.only(bottom: 8, right: 12),
                  child: Text(
                    heading.isEmpty ? '' : loc.t(heading).toUpperCase(),
                    style: ZenithType.of(dialogContext).caps.copyWith(color: palette.text3),
                  ),
                ),
            ]),
            for (final change in changes)
              TableRow(children: [
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(change.displayName, style: text.bodyMedium?.copyWith(color: palette.text)),
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Text(change.before, style: keyStyle.copyWith(color: palette.text2)),
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Icon(Icons.arrow_forward_rounded, size: 16, color: palette.text3),
                ),
                switch (change.after) {
                  final after? => Text(after, style: keyStyle),
                  null => Text(loc.t('downloads.update.hotkeys_removed'), style: text.bodySmall?.copyWith(color: palette.amber)),
                },
              ]),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(loc.t('downloads.update.hotkeys_close')),
          ),
        ],
      );
    },
  );
}
