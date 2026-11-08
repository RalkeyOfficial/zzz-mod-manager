import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/palette.dart';
import '../../core/type_scale.dart';
import '../../l10n/app_localizations.dart';
import '../../services/api_service.dart';
import '../../services/import_review.dart';
import '../../utils/byte_format.dart';
import '../../utils/state_providers.dart';
import '../../utils/zzz_characters.dart';
import '../components/character_pick.dart';
import '../components/character_tile.dart' show libraryGroupName;
import '../components/resolve/resolve_fragments.dart' show formatResolveDate;
import '../components/zenith_controls.dart';
import '../components/zenith_dialog.dart';
import '../components/zenith_switch.dart';

/// What the user settled in the review: every row as it stands, and whether the new mods are turned on afterwards.
class ImportReviewResult {
  const ImportReviewResult({required this.rows, required this.turnOn});

  final List<ImportRow> rows;
  final bool turnOn;
}

/// Saves the Turn on after import switch. A seam so a test does not write the developer's `config.json`.
typedef ImportTurnOnWriter = Future<void> Function(bool turnOn);

/// Shows what each dropped or pasted mod will be called and filed under, flags the ones the library already has, and
/// asks before anything is copied (`docs/importing-mods.md` §2 to §4).
///
/// Answers with the rows to import, or null when the user cancelled.
Future<ImportReviewResult?> showImportReviewDialog(
  BuildContext context, {
  required List<ImportItem> items,
  required List<ExistingMod> library,
  ImportTurnOnWriter? turnOnWriter,
}) => showDialog<ImportReviewResult>(
  context: context,
  builder: (_) => ImportReviewDialog(items: items, library: library, turnOnWriter: turnOnWriter),
);

class ImportReviewDialog extends ConsumerStatefulWidget {
  const ImportReviewDialog({super.key, required this.items, required this.library, this.turnOnWriter});

  final List<ImportItem> items;
  final List<ExistingMod> library;
  final ImportTurnOnWriter? turnOnWriter;

  @override
  ConsumerState<ImportReviewDialog> createState() => _ImportReviewDialogState();
}

class _ImportReviewDialogState extends ConsumerState<ImportReviewDialog> {
  late List<ImportItem> _items = widget.items;

  ImportReview get _review => evaluateImport(_items, widget.library);

  void _edit(int index, ImportItem item) => setState(() => _items = [..._items]..[index] = item);

  void _setTurnOn(bool on) {
    ref.read(importTurnOnAfterProvider.notifier).state = on;
    (widget.turnOnWriter ?? ApiService.setImportTurnOnAfter)(on);
  }

  void _confirm() {
    final review = _review;
    if (!review.canImport) return;
    Navigator.pop(context, ImportReviewResult(rows: review.rows, turnOn: ref.read(importTurnOnAfterProvider)));
  }

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final review = _review;
    final turnOn = ref.watch(importTurnOnAfterProvider);
    final blocked = review.blocked;
    final count = review.rows.length;

    return ZenithDialog.sectioned(
      title: loc.plural('mods.import.title', count, params: {'count': '$count'}),
      subtitle: loc.t('mods.import.subtitle'),
      width: 720,
      headerPadding: const EdgeInsets.fromLTRB(24, 22, 24, 16),
      footerPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      onSubmit: review.canImport ? _confirm : null,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 10,
        children: [
          for (var i = 0; i < review.rows.length; i++)
            _ItemCard(
              key: ValueKey(review.rows[i].item.id),
              row: review.rows[i],
              autofocus: i == 0,
              onChanged: (item) => _edit(i, item),
            ),
        ],
      ),
      footerStart: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 10,
        children: [
          ZenithSwitch(value: turnOn, semanticLabel: loc.t('mods.import.turn_on'), onChanged: _setTurnOn),
          GestureDetector(
            onTap: () => _setTurnOn(!turnOn),
            child: Text(loc.t('mods.import.turn_on'), style: text.bodyMedium?.copyWith(color: palette.text2)),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(loc.t('mods.dialog.cancel'))),
        FilledButton(
          key: const ValueKey('import_confirm'),
          onPressed: review.canImport ? _confirm : null,
          child: Text(loc.t('mods.import.confirm', params: {'count': '$count'})),
        ),
      ],
      belowCard: blocked == null ? null : Text(_blockedText(loc, blocked), key: const ValueKey('import_blocked')),
    );
  }

  String _blockedText(AppLocalizations loc, Blocked blocked) {
    final base = switch (blocked.kind) {
      BlockedKind.character => 'mods.import.blocked_character',
      BlockedKind.name => 'mods.import.blocked_name',
    };
    return blocked.more == 0
        ? loc.t(base, params: {'name': blocked.name})
        : loc.t('${base}_more', params: {'name': blocked.name, 'count': '${blocked.more}'});
  }
}

/// One mod about to be created: where it came from, what it is filed under and called, and what to do about a mod
/// of that name the library has.
class _ItemCard extends StatefulWidget {
  const _ItemCard({super.key, required this.row, required this.autofocus, required this.onChanged});

  final ImportRow row;
  final bool autofocus;
  final ValueChanged<ImportItem> onChanged;

  @override
  State<_ItemCard> createState() => _ItemCardState();
}

class _ItemCardState extends State<_ItemCard> {
  late final TextEditingController _name = TextEditingController(text: widget.row.item.name);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final row = widget.row;
    final item = row.item;
    final mono = ZenithType.of(context).mono.copyWith(color: palette.text3);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: palette.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: row.clashes ? palette.itemWarn : palette.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 10,
        children: [
          Row(
            spacing: 8,
            children: [
              Icon(
                item.kind == ImportSourceKind.archive ? Icons.archive_outlined : Icons.folder_outlined,
                size: 14,
                color: palette.text3,
              ),
              Expanded(
                child: Text(_sourceLine(loc), maxLines: 1, overflow: TextOverflow.ellipsis, style: mono),
              ),
            ],
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 10,
            children: [
              Expanded(
                flex: 10,
                child: CharacterPick(
                  groupId: row.character,
                  onChanged: (id) => widget.onChanged(item.copyWith(pickedCharacter: id)),
                ),
              ),
              Expanded(
                flex: 12,
                child: Semantics(
                  label: loc.t('mods.import.name_aria'),
                  child: TextField(
                    key: ValueKey('import_name_${item.id}'),
                    controller: _name,
                    autofocus: widget.autofocus,
                    onChanged: (value) => widget.onChanged(item.copyWith(name: value)),
                    decoration: InputDecoration(
                      errorText: switch (row.problem) {
                        NameProblem.empty => loc.t('mods.import.name_empty'),
                        NameProblem.invalid => loc.t('mods.dialog.rename_invalid'),
                        _ => null,
                      },
                      errorMaxLines: 2,
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (row.problem == NameProblem.twin) _line(context, loc.t('mods.import.twin'), warn: true),
          if (row.existing case final existing?) ..._clash(context, loc, existing),
        ],
      ),
    );
  }

  String _sourceLine(AppLocalizations loc) {
    final item = widget.row.item;
    final parts = switch (item.kind) {
      ImportSourceKind.archive => [item.label],
      ImportSourceKind.folder => ['${item.label}/', loc.t('mods.import.kind_folder')],
      ImportSourceKind.combined => [
        loc.plural('mods.import.source_combined', item.sources.length, params: {'count': '${item.sources.length}'}),
      ],
    };
    return [...parts, if (item.bytes != null) formatBytes(item.bytes!)].join(' · ');
  }

  List<Widget> _clash(BuildContext context, AppLocalizations loc, ExistingMod existing) {
    final palette = ZenithPalette.of(context);
    final row = widget.row;
    final agent = characterById(existing.characterId) != null;
    final params = {
      'character': libraryGroupName(existing.characterId, loc),
      if (existing.installedAt != null) 'date': formatResolveDate(existing.installedAt!),
    };
    final sentence = loc.t(
      '${agent ? 'mods.import.exists_agent' : 'mods.import.exists_other'}${existing.installedAt == null ? '_undated' : ''}',
      params: params,
    );
    final note = switch ((row.choice, existing.busy)) {
      (_, true) => loc.t('mods.import.update_busy', params: {'name': existing.id}),
      (OnClash.update, _) => loc.t('mods.import.update_note'),
      (OnClash.keepBoth, _) => loc.t('mods.import.keep_both_note', params: {'name': row.finalName}),
    };
    return [
      Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 12,
        runSpacing: 8,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Text(
              sentence,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: palette.badgeUpdate.foreground),
            ),
          ),
          ZenithSegments<OnClash>(
            dense: true,
            semanticLabel: loc.t('mods.import.existing_aria'),
            value: row.choice,
            options: [
              if (!existing.busy) (OnClash.update, loc.t('mods.import.update_it')),
              (OnClash.keepBoth, loc.t('mods.import.keep_both')),
            ],
            onChanged: (choice) => widget.onChanged(widget.row.item.copyWith(choice: choice, clearPick: true)),
          ),
        ],
      ),
      _line(context, note),
      if (row.updates && existing.flattensPatch) _line(context, loc.t('mods.import.update_flattens')),
    ];
  }

  Widget _line(BuildContext context, String text, {bool warn = false}) {
    final palette = ZenithPalette.of(context);
    return Text(
      text,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
        color: warn ? palette.badgeUpdate.foreground : palette.text3,
      ),
    );
  }
}
