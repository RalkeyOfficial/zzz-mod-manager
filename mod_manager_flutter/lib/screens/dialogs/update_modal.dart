import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/palette.dart';
import '../../l10n/app_localizations.dart';
import '../../models/character_info.dart';
import '../../models/gamebanana/gamebanana.dart';
import '../../models/mod_download.dart';
import '../../models/origin_enums.dart';
import '../../services/origin_summary.dart';
import '../../services/origin_write.dart';
import '../../services/update_check.dart';
import '../../utils/categories.dart' show libraryGroupOf;
import '../../utils/notifications.dart';
import '../../utils/state_providers.dart';
import '../components/character_tile.dart' show libraryGroupName;
import '../components/mod_thumb.dart';
import '../components/update_file_rows.dart';
import '../components/zenith_controls.dart';
import '../components/zenith_dialog.dart';

/// One file picked for one mod in [UpdateModal]: what `LibraryActions.updateMods` writes.
class UpdatePick {
  const UpdatePick({required this.modId, required this.file, required this.subject, required this.published});

  /// The mod's folder id. The mod itself is read again when its turn comes, since a rescan replaces every `ModInfo`.
  final String modId;
  final GbFile file;

  /// The layer the file belongs to: the folder's own mod, or a patch over it.
  final DownloadKey? subject;

  /// Every file the check found newer, so a pick below the newest records the rest as passed over.
  final List<GbFile> published;
}

/// Every mod with a newer file in one list: a file to pick for each, and Ignore for the ones to leave. Resolves to the
/// picks, or null when the user left without pressing Update. Nothing is written by this dialog but the ignores, which
/// are written at once and are undone by Undo here or on the mod's History tab, never by leaving.
///
/// Opens nothing, and resolves to null, while the list is already open or a run of updates is under way.
///
/// [writer] is the seam the ignore writes through, for tests only.
Future<List<UpdatePick>?> showUpdateModal(BuildContext context, {OriginWriter? writer}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final open = container.read(updateModalOpenProvider.notifier);
  if (open.state || container.read(libraryUpdateRunProvider)) return null;
  open.state = true;
  try {
    return await showDialog<List<UpdatePick>>(context: context, builder: (_) => UpdateModal(writer: writer));
  } finally {
    open.state = false;
  }
}

class UpdateModal extends ConsumerStatefulWidget {
  const UpdateModal({super.key, this.writer});

  final OriginWriter? writer;

  @override
  ConsumerState<UpdateModal> createState() => _UpdateModalState();
}

/// A mod's verdict as it stood when the dialog opened.
class _Entry {
  const _Entry(this.mod, this.check);

  final ModInfo mod;
  final UpdateCheck check;

  String get id => mod.id;
}

class _UpdateModalState extends ConsumerState<UpdateModal> {
  /// **A snapshot, not a watch.** An ignore turns the verdict into "no update", and a card built from the live
  /// verdicts would vanish before Undo could be pressed.
  late final List<_Entry> _entries = [for (final (mod, check) in ref.read(updatableModsProvider)) _Entry(mod, check)];

  /// The file picked for each mod, by folder id and file id. A mod with exactly one newer file starts picked; with
  /// several, nothing is, since which variant is wanted is the user's to say.
  late final Map<String, int> _picked = {
    for (final entry in _entries)
      if (entry.check.newerFiles.length == 1) entry.id: entry.check.newerFiles.single.idRow,
  };

  /// What an ignore dismissed, by folder id: the layers Undo takes back. Present while the card is collapsed.
  final Map<String, Set<DownloadKey>> _ignored = {};

  /// Folders with an ignore or an undo of this dialog's still being written.
  final Set<String> _working = {};

  AppLocalizations get loc => context.loc;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final palette = ZenithPalette.of(context);
    final library = {for (final mod in ref.watch(modsProvider)) mod.id: mod};
    final writing = ref.watch(modWritesInProgressProvider);
    final count = _entries.where((e) => !_ignored.containsKey(e.id) && _picked.containsKey(e.id)).length;

    return ZenithDialog.sectioned(
      width: 760,
      headerPadding: const EdgeInsets.fromLTRB(24, 20, 24, 14),
      bodyPadding: const EdgeInsets.fromLTRB(24, 4, 24, 18),
      title: loc.plural('mods.update_bulk.title', _entries.length, params: {'count': '${_entries.length}'}),
      subtitleWidget: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600),
        child: Text(loc.t('mods.update_bulk.intro'), style: text.bodyMedium?.copyWith(color: palette.text2)),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 12,
        children: [
          for (final entry in _entries)
            _ModCard(
              key: ValueKey(entry.id),
              entry: entry,
              mod: library[entry.id] ?? entry.mod,
              picked: _picked[entry.id],
              ignored: _ignored.containsKey(entry.id),
              busy: _working.contains(entry.id) || writing.contains(entry.id),
              onPick: (file) => setState(() => _picked[entry.id] = file.idRow),
              onIgnore: () => unawaited(_ignore(entry)),
              onUndo: () => unawaited(_undo(entry)),
            ),
          Text(loc.t('mods.update_bulk.footnote'), style: text.bodySmall?.copyWith(color: palette.text3)),
        ],
      ),
      footerStart: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Text(loc.t('mods.update_bulk.footer'), style: text.bodySmall?.copyWith(color: palette.text2)),
      ),
      actions: [
        OutlinedButton(onPressed: () => Navigator.of(context).pop(), child: Text(loc.t('mods.update.later'))),
        FilledButton(
          onPressed: count == 0 ? null : () => Navigator.of(context).pop(_picks()),
          child: Text(
            count == 0
                ? loc.t('mods.update_bulk.action_none')
                : loc.plural('mods.update_bulk.action', count, params: {'count': '$count'}),
          ),
        ),
      ],
    );
  }

  List<UpdatePick> _picks() => [
    for (final entry in _entries)
      if (!_ignored.containsKey(entry.id))
        if (_picked[entry.id] case final fileId?)
          UpdatePick(
            modId: entry.id,
            file: entry.check.newerFiles.firstWhere((file) => file.idRow == fileId),
            subject: entry.check.subject,
            published: entry.check.newerFiles,
          ),
  ];

  /// The mod as the library holds it now: a rescan after any write replaces every `ModInfo`.
  ModInfo _current(_Entry entry) {
    for (final mod in ref.read(modsProvider)) {
      if (mod.id == entry.id) return mod;
    }
    return entry.mod;
  }

  void _failed(NotificationCenter notify, AppLocalizations loc, ModInfo mod) => notify.error(
    loc.t('mods.update.dismiss_failed_title'),
    body: loc.t('mods.update.dismiss_failed', params: {'mod': mod.name}),
    characterId: mod.characterId,
  );

  /// Writes the ignore at once, as the Updates page's Ignore does, and collapses the card.
  Future<void> _ignore(_Entry entry) async {
    final notify = context.notify;
    final loc = this.loc;
    final container = ProviderScope.containerOf(context, listen: false);
    final mod = _current(entry);
    setState(() => _working.add(entry.id));
    final dismissed = await ignoreUpdate(container, mod: mod, check: entry.check, writer: widget.writer);
    if (dismissed.isEmpty) _failed(notify, loc, mod);
    if (!mounted) return;
    setState(() {
      _working.remove(entry.id);
      if (dismissed.isNotEmpty) {
        _ignored[entry.id] = dismissed;
        _picked.remove(entry.id);
      }
    });
  }

  /// Takes back every layer the ignore dismissed, then reopens the card with no file picked.
  Future<void> _undo(_Entry entry) async {
    final notify = context.notify;
    final loc = this.loc;
    final container = ProviderScope.containerOf(context, listen: false);
    final mod = _current(entry);
    final remaining = {...?_ignored[entry.id]};
    setState(() => _working.add(entry.id));
    for (final key in remaining.toList()) {
      final ok = await stopIgnoringUpdate(container, mod: _current(entry), subject: key, writer: widget.writer);
      if (ok) {
        remaining.remove(key);
      } else {
        _failed(notify, loc, mod);
        break;
      }
    }
    if (!mounted) return;
    setState(() {
      _working.remove(entry.id);
      if (remaining.isEmpty) {
        _ignored.remove(entry.id);
      } else {
        _ignored[entry.id] = remaining;
      }
    });
  }
}

/// One mod: its name and where it stands, the file it holds, and the newer ones to pick from.
class _ModCard extends StatelessWidget {
  const _ModCard({
    super.key,
    required this.entry,
    required this.mod,
    required this.picked,
    required this.ignored,
    required this.busy,
    required this.onPick,
    required this.onIgnore,
    required this.onUndo,
  });

  final _Entry entry;
  final ModInfo mod;
  final int? picked;
  final bool ignored;
  final bool busy;
  final void Function(GbFile file) onPick;
  final VoidCallback onIgnore;
  final VoidCallback onUndo;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final check = entry.check;
    final character = libraryGroupName(libraryGroupOf(mod.characterId), loc);
    final state = loc.t(mod.isActive ? 'mods.update_bulk.state_on' : 'mods.update_bulk.state_off');
    final isPatch = check.subject?.role == DownloadRole.patch;
    final guess = (check.isGuess || check.outcome == UpdateOutcome.possiblyOutdated) &&
        check.outcome != UpdateOutcome.untracked;

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: palette.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              spacing: 12,
              children: [
                ModThumb(mod: mod, width: 48, height: 32, radius: 6, spacing: 7),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(mod.name, style: text.bodyMedium?.copyWith(color: palette.text, fontWeight: FontWeight.w600)),
                          if (isPatch)
                            ZenithBadge(label: loc.t('mods.folder.role_patch'), tone: palette.badgeNeutral, small: true),
                        ],
                      ),
                      Text('$character · $state', style: text.bodySmall?.copyWith(color: palette.text3)),
                    ],
                  ),
                ),
                if (ignored)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    spacing: 2,
                    children: [
                      Text(
                        '${loc.t('mods.update_bulk.ignored')} ·',
                        style: text.bodySmall?.copyWith(color: palette.text3),
                      ),
                      TextButton(
                        key: ValueKey('undo_${entry.id}'),
                        style: smallButtonStyle(context).copyWith(foregroundColor: WidgetStatePropertyAll(palette.accent)),
                        onPressed: busy ? null : onUndo,
                        child: Text(loc.t('library.updates.undo')),
                      ),
                    ],
                  )
                else
                  TextButton.icon(
                    key: ValueKey('ignore_${entry.id}'),
                    style: smallButtonStyle(context),
                    onPressed: busy || check.dismissableUpTo == null ? null : onIgnore,
                    icon: const Icon(Icons.visibility_off_outlined, size: 16),
                    label: Text(loc.t('library.updates.ignore')),
                  ),
              ],
            ),
          ),
          if (!ignored) ...[
            if (guess)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
                child: Text(loc.t('mods.update.guess_caveat'), style: text.bodySmall?.copyWith(color: palette.text3)),
              ),
            YouHaveStrip(
              YouHaveParts.of(loc, check, recordedLabel: _recordedLabel()),
              label: loc.t('mods.update.you_have'),
            ),
            FileRadioGroup(
              framed: false,
              label: loc.t('mods.update_bulk.group_label', params: {'mod': mod.name}),
              rows: [
                for (final file in check.newerFiles)
                  FileRadioRow(
                    file: file,
                    selected: file.idRow == picked,
                    verticalPadding: 9,
                    chip: _chip(context, file),
                    onTap: busy ? null : () => onPick(file),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// The layer's own recorded version label, for a mod whose installed file the check could not find.
  String? _recordedLabel() {
    final subject = entry.check.subject;
    final download = subject == null ? null : mod.origin?.downloadOf(subject);
    return summarizeDownload(download, provenance: mod.origin?.provenance ?? OriginProvenance.importedFolder).versionLabel;
  }

  /// Why the app would suggest a file, on that file's row. It never picks it: the chip is shown only where there is a
  /// choice to make, and says nothing about whether the file is the right one.
  ZenithBadge? _chip(BuildContext context, GbFile file) {
    final check = entry.check;
    if (check.newerFiles.length < 2 || check.candidate?.idRow != file.idRow) return null;
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    return check.candidateMatchesVariant
        ? ZenithBadge(label: loc.t('mods.update.pick_variant'), tone: palette.badgeInfo, small: true)
        : ZenithBadge(label: loc.t('mods.update.pick_newest'), tone: palette.badgeNeutral, small: true);
  }
}
