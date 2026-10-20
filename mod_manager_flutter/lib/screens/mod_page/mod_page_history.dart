import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/palette.dart';
import '../../core/type_scale.dart';
import '../../l10n/app_localizations.dart';
import '../../models/character_info.dart';
import '../../models/gamebanana/gb_file.dart';
import '../../models/gamebanana/gb_mod.dart';
import '../../models/gamebanana/gb_update.dart';
import '../../models/installed_file.dart';
import '../../models/mod_download.dart';
import '../../models/origin_enums.dart';
import '../../services/backup/snapshot_service.dart';
import '../../services/gamebanana/file_selection.dart';
import '../../services/installed_record.dart';
import '../../services/patch_removal.dart';
import '../../services/update_check.dart';
import '../../utils/byte_format.dart';
import '../../utils/html_to_markdown.dart';
import '../../utils/state_providers.dart';
import '../components/character_tile.dart';
import '../components/mod_detail_parts.dart';
import '../components/resolve/resolve_fragments.dart' show formatResolveDate;
import '../components/zenith_controls.dart';
import '../dialogs/reinstall_flow.dart' show canReinstall;
import '../dialogs/restore_snapshot_flow.dart';
import 'mod_page.dart' show PageHeading;

/// The History tab of a mod's page: the file in use and the snapshots to go back to, the author's latest update
/// post, the patches on top, and an update the user ignored (`docs/library-screen.md` §15).
///
/// A file's name and upload date come from a page this session holds, which opening the page fetches; without one, a
/// snapshot is named by when it was saved.
class ModHistoryTab extends ConsumerWidget {
  const ModHistoryTab({
    super.key,
    required this.mod,
    required this.updates,
    required this.onReinstall,
    required this.onRestore,
    required this.onTakeOut,
    required this.onStopIgnoring,
  });

  final ModInfo mod;

  /// The base mod's update posts, newest first. Null while they load or when there are none to load.
  final List<GbUpdate>? updates;
  final VoidCallback onReinstall;
  final ValueChanged<ModSnapshot> onRestore;
  final ValueChanged<ModDownload> onTakeOut;
  final ValueChanged<ModDownload> onStopIgnoring;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = context.loc;
    final records = ref.watch(knownModPagesProvider);
    final uid = mod.uid;
    final snapshots = uid == null
        ? const <SnapshotEntry>[]
        : ref.watch(modSnapshotsProvider(uid)).valueOrNull ?? const <SnapshotEntry>[];
    final origin = mod.origin;
    final patches = origin?.patches ?? const <ModDownload>[];
    final ignored = [for (final download in origin?.downloads ?? const <ModDownload>[]) if (download.updatesDismissedUntil != null) download];
    final post = _latestPost(updates);
    // While a restore, a patch removal or a stop-ignoring writes this folder, nothing else may start on it.
    final busy = ref.watch(modWritesInProgressProvider).contains(mod.id);
    VoidCallback? unlessBusy(VoidCallback action) => busy ? null : action;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 12,
      children: [
        PageHeading(loc.t('library.history.installed_files'), aside: loc.t('library.history.retention')),
        _Box(
          children: [
            _CurrentRow(mod: mod, records: records, onReinstall: unlessBusy(onReinstall)),
            for (final entry in snapshots)
              _SnapshotRow(entry: entry, records: records, onRestore: unlessBusy(() => onRestore(entry.snapshot))),
          ],
        ),
        if (post != null) _UpdatePost(post: post),
        if (patches.isNotEmpty)
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 8,
            children: [
              SectionHeading(loc.t('library.history.patches'), aside: loc.t('library.history.patches_order'), large: true),
              for (final patch in patches)
                _PatchRow(mod: mod, patch: patch, records: records, onTakeOut: unlessBusy(() => onTakeOut(patch))),
              _Footnote(loc.t('library.history.take_out_note')),
            ],
          ),
        if (ignored.isNotEmpty)
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 8,
            children: [
              SectionHeading(loc.t('library.history.ignored'), aside: loc.t('library.history.ignored_note'), large: true),
              for (final download in ignored)
                _IgnoredRow(
                  mod: mod,
                  download: download,
                  records: records,
                  onStopIgnoring: unlessBusy(() => onStopIgnoring(download)),
                ),
            ],
          ),
      ],
    );
  }

  /// The newest post that says something: a post with no text and no change list is a file upload, not news.
  static GbUpdate? _latestPost(List<GbUpdate>? updates) {
    GbUpdate? latest;
    for (final update in updates ?? const <GbUpdate>[]) {
      if (!update.hasNotes) continue;
      final date = update.dateAdded;
      final best = latest?.dateAdded;
      if (latest == null || (date != null && (best == null || date.isAfter(best)))) latest = update;
    }
    return latest;
  }
}

/// Rows in one rounded box, a line between each.
class _Box extends StatelessWidget {
  const _Box({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, child) in children.indexed)
            DecoratedBox(
              decoration: BoxDecoration(
                border: i == children.length - 1 ? null : Border(bottom: BorderSide(color: palette.divider)),
              ),
              child: child,
            ),
        ],
      ),
    );
  }
}

/// A file's row: its name in mono, the author's words for it in grey under it, a line of facts, and what can be done.
class _FileRow extends StatelessWidget {
  const _FileRow({required this.title, required this.variant, required this.facts, required this.trailing, this.current = false});

  /// The file's name, or what stands for it when the file is not known.
  final Widget title;

  /// The file's description: null when the file is not known, empty when its author wrote none.
  final String? variant;
  final String facts;
  final List<Widget> trailing;
  final bool current;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    return Container(
      color: current ? palette.card : null,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        spacing: 14,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 3,
              children: [
                title,
                if (variant case final variant?)
                  Text(
                    variant.isEmpty ? loc.t('library.history.no_variant') : variant,
                    style: text.bodySmall?.copyWith(
                      color: variant.isEmpty ? palette.text3 : palette.text2,
                      fontStyle: variant.isEmpty ? FontStyle.italic : null,
                    ),
                  ),
                Text(facts, style: text.bodySmall?.copyWith(color: palette.text3)),
              ],
            ),
          ),
          ...trailing,
        ],
      ),
    );
  }
}

/// [file]'s name, in mono, or [fallback] in grey when there is no file to name.
Widget _fileTitle(BuildContext context, GbFile? file, {required String fallback, bool current = false}) {
  final palette = ZenithPalette.of(context);
  final mono = ZenithType.of(context).mono;
  if (file == null) return Text(fallback, style: mono.copyWith(color: palette.text2));
  return Text(
    fileDisplayName(file),
    style: mono.copyWith(color: current ? palette.text : palette.textProse, fontWeight: current ? FontWeight.w600 : null),
  );
}

/// The file the folder holds now. Reinstall writes that same file over the folder again.
class _CurrentRow extends ConsumerWidget {
  const _CurrentRow({required this.mod, required this.records, required this.onReinstall});

  final ModInfo mod;
  final Map<int, GbMod> records;

  /// Null while another write holds the folder.
  final VoidCallback? onReinstall;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final origin = mod.origin;
    final base = origin?.base;
    final named = base?.versionConfidence.namesFile ?? false;
    final (page: _, file: recorded) = installedRecord(mod, records);
    final file = named ? recorded : null;
    final size = ref.watch(modSizeProvider(mod.id)).valueOrNull;
    final facts = [
      loc.t('library.history.current'),
      if (file?.dateAdded case final date?) loc.t('library.details.uploaded_on', params: {'date': formatResolveDate(date)}),
      if (origin?.installedAt case final date?)
        loc.t('library.page.installed', params: {'date': formatResolveDate(date)}),
      if (size != null && size.bytes > 0) formatBytes(size.bytes),
    ].join(' · ');
    return _FileRow(
      current: true,
      title: _fileTitle(context, file, fallback: loc.t('library.history.file_unknown'), current: true),
      variant: file == null ? null : (base?.versionLabel ?? ''),
      facts: facts,
      trailing: [
        if (canReinstall(mod))
          OutlinedButton.icon(
            style: smallButtonStyle(context),
            onPressed: onReinstall,
            icon: const Icon(Icons.download_rounded),
            label: Text(loc.t('library.history.reinstall')),
          ),
        ZenithBadge(label: loc.t('library.history.in_use'), tone: palette.badgeOn),
      ],
    );
  }
}

/// A snapshot to go back to: the file the folder held when it was saved, when its copy of the sidecar names one and
/// this session holds the page, and otherwise the time it was saved.
class _SnapshotRow extends StatelessWidget {
  const _SnapshotRow({required this.entry, required this.records, required this.onRestore});

  final SnapshotEntry entry;
  final Map<int, GbMod> records;
  final VoidCallback? onRestore;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final snapshot = entry.snapshot;
    final base = entry.origin?.base;
    final named = base?.versionConfidence.namesFile ?? false;
    final file = named && base != null ? downloadRecord(base, records).file : null;
    final time = formatSnapshotTime(snapshot.takenAt);
    final facts = [
      loc.t('library.history.snapshot'),
      if (file?.dateAdded case final date?) loc.t('library.details.uploaded_on', params: {'date': formatResolveDate(date)}),
      // The time is the title when there is no file to name.
      if (file != null)
        loc.t('library.history.saved', params: {'time': time, 'reason': loc.t(snapshotReasonKey(snapshot.reason))})
      else
        loc.t(snapshotReasonKey(snapshot.reason)),
      if (snapshot.sizeBytes > 0) formatBytes(snapshot.sizeBytes),
    ].join(' · ');
    return _FileRow(
      title: _fileTitle(context, file, fallback: time),
      variant: file == null ? null : (base?.versionLabel ?? ''),
      facts: facts,
      trailing: [
        OutlinedButton.icon(
          style: smallButtonStyle(context),
          onPressed: onRestore,
          icon: const Icon(Icons.history_rounded),
          label: Text(loc.t('mods.backups.restore')),
        ),
      ],
    );
  }
}

/// The newest of the author's update posts: its title, the change list and the text.
class _UpdatePost extends StatelessWidget {
  const _UpdatePost({required this.post});

  final GbUpdate post;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final prose = post.text == null ? '' : htmlToMarkdown(post.text!).trim();
    final heading = [
      loc.t('library.history.latest_post'),
      if (post.dateAdded case final date?) formatResolveDate(date),
    ].join(' · ');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: palette.dialog,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 6,
        children: [
          SectionHeading(heading),
          if (post.name case final name? when name.trim().isNotEmpty)
            Text(name, style: text.bodyMedium?.copyWith(color: palette.text, fontWeight: FontWeight.w600)),
          for (final entry in post.changeLog)
            Text(
              entry.category == null ? '• ${entry.text}' : '• ${entry.text} (${entry.category})',
              style: text.bodyMedium?.copyWith(color: palette.textProse),
            ),
          if (prose.isNotEmpty) ModDescription(key: ValueKey('post_${post.idRow}'), text: prose),
          Text(loc.t('library.history.post_source'), style: text.bodySmall?.copyWith(color: palette.text3)),
        ],
      ),
    );
  }
}

/// One patch on top of the base: its name and file, who made it and when, what it changed in the folder, and Take
/// out when the app knows which files are its.
class _PatchRow extends StatelessWidget {
  const _PatchRow({required this.mod, required this.patch, required this.records, required this.onTakeOut});

  final ModInfo mod;
  final ModDownload patch;
  final Map<int, GbMod> records;
  final VoidCallback? onTakeOut;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final (:page, file: recorded) = downloadRecord(patch, records);
    final file = patch.versionConfidence.namesFile ? recorded : null;
    final added = patch.files.where((f) => f.role == InstalledFileRole.added).length;
    final replaced = patch.files.length - added;
    final tracked = patch.hasIdentity && mod.origin?.tracking != OriginTracking.off;
    final removable = removablePatches(mod.origin).contains(patch);

    final facts = [
      if (page?.submitter?.name case final author?) loc.t('library.details.by', params: {'author': author}),
      if (file?.dateAdded case final date?) loc.t('library.details.uploaded_on', params: {'date': formatResolveDate(date)}),
      if (patch.hasFileRecord)
        [
          if (added > 0) loc.plural('library.history.files_added', added, params: {'count': '$added'}),
          if (replaced > 0) loc.plural('library.history.files_replaced', replaced, params: {'count': '$replaced'}),
        ].join(', '),
      if (tracked) loc.t('library.history.tracked') else if (!patch.hasIdentity) loc.t('library.history.local_file'),
    ].join(' · ');

    final String? why = removable
        ? null
        : !patch.hasFileRecord
        ? loc.t('library.history.cant_take_out_files')
        : loc.t('library.history.cant_take_out_page');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: palette.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.outline),
      ),
      child: Row(
        spacing: 12,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              width: 44,
              height: 30,
              child: DottedGround(ground: palette.groundFor(elementToneOf(mod.characterId)), spacing: 6),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 2,
              children: [
                DownloadTitle(download: patch, folderName: mod.name, page: page),
                if (file != null)
                  Text(fileDisplayName(file), style: ZenithType.of(context).mono.copyWith(color: palette.textProse)),
                if (facts.isNotEmpty) Text(facts, style: text.bodySmall?.copyWith(color: palette.text3)),
                if (why != null) Text(why, style: text.bodySmall?.copyWith(color: palette.text3, fontStyle: FontStyle.italic)),
              ],
            ),
          ),
          if (removable)
            OutlinedButton(style: smallButtonStyle(context), onPressed: onTakeOut, child: Text(loc.t('library.history.take_out'))),
        ],
      ),
    );
  }
}

/// An update the user ignored on one of the folder's downloads: the files it covered when this session's check
/// listed them, otherwise the date it covers up to.
class _IgnoredRow extends ConsumerWidget {
  const _IgnoredRow({required this.mod, required this.download, required this.records, required this.onStopIgnoring});

  final ModInfo mod;
  final ModDownload download;
  final Map<int, GbMod> records;
  final VoidCallback? onStopIgnoring;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final check = _checkOf(ref.watch(modUpdateChecksProvider.select((checks) => checks[mod.id])));
    final files = check != null && check.dismissed ? check.newerFiles : const <GbFile>[];
    final until = formatResolveDate(download.updatesDismissedUntil!);
    final stacked = (mod.origin?.downloads.length ?? 0) > 1;
    final (:page, file: _) = downloadRecord(download, records);

    return DashedBox(
      color: palette.fieldBorder,
      radius: 12,
      width: 1,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          spacing: 12,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 2,
                children: [
                  // In a folder of several downloads, which one's update this is.
                  if (stacked) DownloadTitle(download: download, folderName: mod.name, page: page),
                  for (final file in files) ...[
                    Text(fileDisplayName(file), style: ZenithType.of(context).mono.copyWith(color: palette.textProse)),
                    if (file.description case final words? when words.trim().isNotEmpty)
                      Text(words.trim(), style: text.bodySmall?.copyWith(color: palette.text2)),
                    if (file.dateAdded case final date?)
                      Text(
                        loc.t('library.details.uploaded_on', params: {'date': formatResolveDate(date)}),
                        style: text.bodySmall?.copyWith(color: palette.text3),
                      ),
                  ],
                  Text(
                    loc.t('library.history.ignored_until', params: {'date': until}),
                    style: text.bodySmall?.copyWith(color: palette.text3),
                  ),
                ],
              ),
            ),
            OutlinedButton(
              style: smallButtonStyle(context),
              onPressed: onStopIgnoring,
              child: Text(loc.t('library.history.stop_ignoring')),
            ),
          ],
        ),
      ),
    );
  }

  /// This download's own verdict out of the folder's.
  UpdateCheck? _checkOf(UpdateCheck? folder) {
    if (folder == null) return null;
    for (final layer in folder.layers) {
      if (layer.download.modId == download.modId) return layer.check;
    }
    return folder.subjectModId == download.modId ? folder : null;
  }
}

class _Footnote extends StatelessWidget {
  const _Footnote(this.text);

  final String text;

  @override
  Widget build(BuildContext context) =>
      Text(text, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: ZenithPalette.of(context).text3));
}
