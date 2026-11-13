/// The folders window, "Pick what to install" (board `FoldersModal`): which of an archive's folders are installed, in two contexts.
///
/// An install's makes new mods: the folders ticked, and whether they are one mod or each its own.
/// An update's fills one mod that already exists: there is nothing to name and no separate mods, the ticked folders replace what the mod has, together,
/// and the mod keeps its name, its character and whether it is on (`docs/update-runs.md` §6).
///
/// Nothing is ticked for the user in either. The hints beside a folder are guesses from what is inside it and decide nothing.
library;

import 'package:flutter/material.dart';

import '../../core/palette.dart';
import '../../core/type_scale.dart';
import '../../l10n/app_localizations.dart';
import '../../models/character_info.dart';
import '../../services/archive_folder_summary.dart';
import '../../utils/byte_format.dart';
import '../components/question_parts.dart';
import '../components/resolve/resolve_fragments.dart' show formatResolveDate;
import '../components/zenith_dialog.dart';
import 'import_selection_dialog.dart' show ImportFolderChoice;
import 'mod_update_parts.dart' show UpdateGroup;

/// Which of the two the folders window is.
sealed class FoldersContext {
  const FoldersContext({this.archiveName});

  /// The archive's file name, with its extension. Null for folders that came from no archive, such as a drop of several.
  final String? archiveName;
}

/// An install: the ticked folders become new mods, one or each its own.
final class FoldersInstall extends FoldersContext {
  const FoldersInstall({super.archiveName, required this.defaultCombinedName, this.characterId});

  /// The name One mod starts with.
  final String defaultCombinedName;

  /// The install's character, whose ground the header's tile is drawn on.
  final String? characterId;
}

/// An update of [mod]: the ticked folders replace what it has, together.
final class FoldersUpdate extends FoldersContext {
  const FoldersUpdate({
    super.archiveName,
    required this.mod,
    this.current,
    this.heldFileDate,
    this.reinstall = false,
  });

  final ModInfo mod;

  /// What the mod's folder holds now, for "You have now".
  final FolderSummary? current;

  /// The upload date of the file the mod holds.
  final DateTime? heldFileDate;

  /// Writing the file the mod holds again, from the one-mod window's Reinstall.
  final bool reinstall;
}

/// What the folders window was answered with: the folders ticked and how they are installed, or Don't install or Skip this update ([declined]).
/// Closing the window answers nothing, which is null.
class FolderPick {
  const FolderPick({required this.folders, this.combine = false, this.combinedName = ''}) : declined = false;

  const FolderPick.declined()
      : folders = const <String>[],
        combine = false,
        combinedName = '',
        declined = true;

  /// The ticked folders' paths, in the order offered.
  final List<String> folders;

  /// One mod, named [combinedName]; otherwise each folder is its own.
  final bool combine;
  final String combinedName;

  final bool declined;
}

/// Opens the folders window over [choices], each summarised in [summaries] by its path.
Future<FolderPick?> showFoldersModal(
  BuildContext context, {
  required FoldersContext question,
  required List<ImportFolderChoice> choices,
  Map<String, FolderSummary> summaries = const <String, FolderSummary>{},
}) =>
    showDialog<FolderPick>(
      context: context,
      builder: (_) => FoldersModal(question: question, choices: choices, summaries: summaries),
    );

class FoldersModal extends StatefulWidget {
  const FoldersModal({
    super.key,
    required this.question,
    required this.choices,
    this.summaries = const <String, FolderSummary>{},
  });

  final FoldersContext question;
  final List<ImportFolderChoice> choices;
  final Map<String, FolderSummary> summaries;

  @override
  State<FoldersModal> createState() => _FoldersModalState();
}

class _FoldersModalState extends State<FoldersModal> {
  final Set<String> _ticked = <String>{};
  bool _combine = false;
  late final TextEditingController _name = TextEditingController(
    text: switch (widget.question) {
      FoldersInstall(:final defaultCombinedName) => defaultCombinedName,
      FoldersUpdate() => '',
    },
  );

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool get _update => widget.question is FoldersUpdate;

  bool get _ready => _ticked.isNotEmpty && (!_combine || _name.text.trim().isNotEmpty);

  void _confirm() {
    if (!_ready) return;
    Navigator.of(context).pop(FolderPick(
      folders: [for (final choice in widget.choices) if (_ticked.contains(choice.path)) choice.path],
      combine: !_update && _combine,
      combinedName: _name.text.trim(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final question = widget.question;
    final count = _ticked.length;

    final (String leave, String go, String status) = switch (question) {
      FoldersUpdate(:final mod, :final reinstall) => (
          loc.t(reinstall ? 'mods.dialog.cancel' : 'mods.folders.skip_update'),
          loc.t(reinstall ? 'mods.folders.reinstall_mod' : 'mods.folders.update_mod', params: {'mod': mod.name}),
          count == 0
              ? loc.t('mods.folders.update_status_none')
              : loc.plural('mods.folders.update_status', count, params: {'count': '$count', 'mod': mod.name}),
        ),
      FoldersInstall() => (
          loc.t('mods.folders.dont_install'),
          count == 0
              ? loc.t('mods.folders.install')
              : loc.plural('mods.folders.install_mods', _combine ? 1 : count, params: {'count': '${_combine ? 1 : count}'}),
          count == 0
              ? loc.t('mods.folders.status_none')
              : loc.plural(_combine ? 'mods.folders.status_one' : 'mods.folders.status_separate', count,
                  params: {'count': '$count'}),
        ),
    };

    return ZenithDialog.sectioned(
      width: 700,
      title: loc.t('mods.folders.title'),
      leading: switch (question) {
        FoldersUpdate(:final mod) => QuestionTile(mod: mod),
        FoldersInstall(:final characterId) => QuestionTile(characterId: characterId),
      },
      subtitleWidget: _subtitle(context),
      closeAlignsStart: false,
      headerPadding: const EdgeInsets.fromLTRB(24, 20, 24, 14),
      onSubmit: _ready ? _confirm : null,
      footerStart: TextButton(
        onPressed: () => Navigator.of(context).pop(const FolderPick.declined()),
        child: Text(leave),
      ),
      actions: [QuestionFooterEnd(status: status, label: go, onPressed: _ready ? _confirm : null)],
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 16,
        children: [
          if (question case FoldersUpdate(:final mod, :final current, :final heldFileDate))
            UpdateGroup(label: loc.t('mods.folders.label_have'), child: _HaveBox(mod: mod, current: current, heldFileDate: heldFileDate)),
          UpdateGroup(
            label: loc.t('mods.folders.label_folders'),
            caption: loc.t('mods.folders.caption_hints'),
            child: _folderGroup(context),
          ),
          if (question case FoldersUpdate(:final mod))
            Text(
              loc.t('mods.folders.update_note', params: {'mod': mod.name}),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: ZenithPalette.of(context).text2, height: 1.6),
            ),
          if (question is FoldersInstall) ..._installAs(context),
        ],
      ),
    );
  }

  Widget _subtitle(BuildContext context) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final style = Theme.of(context).textTheme.bodySmall!.copyWith(color: palette.text3);
    final n = widget.choices.length;
    final archive = widget.question.archiveName;
    final tail = switch (widget.question) {
      FoldersUpdate(:final mod) => loc.t('mods.folders.subtitle_update', params: {'mod': mod.name}),
      FoldersInstall() => switch (widget.summaries.values.fold(0, (sum, s) => sum + s.bytes)) {
          0 => null,
          final bytes => formatBytes(bytes),
        },
    };
    final count = archive == null
        ? loc.plural('mods.folders.subtitle_folders', n, params: {'count': '$n'})
        : loc.plural('mods.folders.subtitle_has', n, params: {'count': '$n'});
    return Text.rich(
      TextSpan(children: [
        if (archive != null) ...[
          TextSpan(text: archive, style: ZenithType.of(context).mono.copyWith(color: palette.text3)),
          const TextSpan(text: ' '),
        ],
        TextSpan(text: [count, ?tail].join(' · ')),
      ]),
      style: style,
    );
  }

  Widget _folderGroup(BuildContext context) {
    final palette = ZenithPalette.of(context);
    final loc = context.loc;
    return Semantics(
      container: true,
      label: loc.t('mods.folders.label_folders'),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: palette.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: palette.line),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (i, choice) in widget.choices.indexed)
              _FolderRow(
                choice: choice,
                summary: widget.summaries[choice.path],
                hint: _hintFor(loc, choice),
                ticked: _ticked.contains(choice.path),
                last: i == widget.choices.length - 1,
                onTap: () => setState(() {
                  if (!_ticked.remove(choice.path)) _ticked.add(choice.path);
                }),
              ),
          ],
        ),
      ),
    );
  }

  /// The one guess said about a folder, or none.
  String? _hintFor(AppLocalizations loc, ImportFolderChoice choice) {
    final question = widget.question;
    if (question case FoldersUpdate(:final mod)) {
      if (namedLikeMod(choice.name, modId: mod.id, recorded: mod.origin?.ingest?.folders ?? const <String>[])) {
        return loc.t('mods.folders.hint_same_name');
      }
      if (namedLikeArchive(choice.name, question.archiveName)) return loc.t('mods.folders.hint_named_like_file');
    }
    if (widget.summaries[choice.path]?.looksLikePreviews ?? false) return loc.t('mods.folders.hint_previews');
    return null;
  }

  List<Widget> _installAs(BuildContext context) {
    final loc = context.loc;
    return [
      UpdateGroup(
        label: loc.t('mods.folders.label_install_as'),
        child: ChoiceGroup(
          label: loc.t('mods.folders.label_install_as'),
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                final cards = [
                  ChoiceCard(
                    compact: true,
                    selected: _combine,
                    title: loc.t('mods.folders.one_title'),
                    description: loc.t('mods.folders.one_desc'),
                    onTap: () => setState(() => _combine = true),
                  ),
                  ChoiceCard(
                    compact: true,
                    selected: !_combine,
                    title: loc.t('mods.folders.separate_title'),
                    description: loc.t('mods.folders.separate_desc'),
                    onTap: () => setState(() => _combine = false),
                  ),
                ];
                if (constraints.maxWidth < 500) {
                  return Column(crossAxisAlignment: CrossAxisAlignment.stretch, spacing: 10, children: cards);
                }
                return IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    spacing: 10,
                    children: [for (final card in cards) Expanded(child: card)],
                  ),
                );
              },
            ),
          ],
        ),
      ),
      if (_combine && _ticked.isNotEmpty)
        UpdateGroup(
          label: loc.t('mods.folders.label_name'),
          child: TextField(
            controller: _name,
            onChanged: (_) => setState(() {}),
            style: Theme.of(context).textTheme.bodyMedium,
            decoration: InputDecoration(isDense: true, hintText: loc.t('mods.folders.field_mod_name')),
          ),
        ),
    ];
  }
}

/// What a folder holds, in a line: its first `.ini` and how many other files, or what it holds instead of one.
String folderDescription(AppLocalizations loc, FolderSummary? summary, {String? shaderSource}) {
  final parts = <String>[
    if (summary != null)
      switch (summary) {
        FolderSummary(:final firstIni?) when summary.files <= 1 => loc.t('mods.folders.desc_ini_only', params: {'ini': firstIni}),
        FolderSummary(:final firstIni?) => loc.plural('mods.folders.desc_ini', summary.files - 1,
            params: {'ini': firstIni, 'count': '${summary.files - 1}'}),
        FolderSummary(shaderOnly: true) => loc.t('mods.folders.desc_shader_only'),
        _ when summary.looksLikePreviews =>
          loc.plural('mods.folders.desc_images', summary.images, params: {'count': '${summary.images}'}),
        _ => loc.plural('mods.folders.desc_files', summary.files, params: {'count': '${summary.files}'}),
      },
    if (shaderSource != null) loc.t('mods.dialog.import_select_shader_source', params: {'folder': shaderSource}),
  ];
  return parts.join(' · ');
}

class _FolderRow extends StatelessWidget {
  const _FolderRow({
    required this.choice,
    required this.summary,
    required this.hint,
    required this.ticked,
    required this.last,
    required this.onTap,
  });

  final ImportFolderChoice choice;
  final FolderSummary? summary;
  final String? hint;
  final bool ticked;
  final bool last;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final description = folderDescription(loc, summary, shaderSource: choice.shaderSource);
    final size = summary == null ? null : formatBytes(summary!.bytes);
    return Semantics(
      checked: ticked,
      onTap: onTap,
      excludeSemantics: true,
      label: ['${choice.name}/', if (description.isNotEmpty) description, ?hint, ?size].join(', '),
      child: Material(
        color: ticked ? pickedRowFill(palette, palette.card) : Colors.transparent,
        child: InkWell(
          onTap: onTap,
          hoverColor: palette.rowHover,
          child: Container(
            padding: _FolderLine.padding,
            decoration: BoxDecoration(border: last ? null : Border(bottom: BorderSide(color: palette.rowDivider))),
            child: _FolderLine(
              leading: ChoiceCheck(ticked: ticked),
              name: choice.name,
              line: description,
              hint: hint,
              bytes: summary?.bytes,
            ),
          ),
        ),
      ),
    );
  }
}

/// "You have now": the mod's folder, what it holds and from which file, and its size.
class _HaveBox extends StatelessWidget {
  const _HaveBox({required this.mod, required this.current, required this.heldFileDate});

  final ModInfo mod;
  final FolderSummary? current;
  final DateTime? heldFileDate;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final what = folderDescription(loc, current);
    final line = [
      if (what.isNotEmpty) what,
      if (heldFileDate case final date?) loc.t('mods.folders.have_from', params: {'date': formatResolveDate(date)}),
    ].join(' · ');
    return Container(
      padding: _FolderLine.padding,
      decoration: BoxDecoration(
        color: palette.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.line),
      ),
      child: _FolderLine(name: mod.id, line: line, bytes: current?.bytes),
    );
  }
}

/// A folder's line: a folder icon, its name with what it holds under it, a hint, and its size at the right.
class _FolderLine extends StatelessWidget {
  const _FolderLine({required this.name, required this.line, this.leading, this.hint, this.bytes});

  static const EdgeInsets padding = EdgeInsets.symmetric(horizontal: 14, vertical: 11);

  final String name;
  final String line;
  final Widget? leading;
  final String? hint;
  final int? bytes;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    final type = ZenithType.of(context);
    return Row(
      spacing: 12,
      children: [
        ?leading,
        Icon(Icons.folder_outlined, size: 16, color: palette.text3),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 2,
            children: [
              Text('$name/', style: type.mono.copyWith(color: palette.text)),
              if (line.isNotEmpty) Text(line, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: palette.text3)),
            ],
          ),
        ),
        if (hint case final hint?) ConstrainedBox(constraints: const BoxConstraints(maxWidth: 220), child: DashedHint(hint)),
        SizedBox(
          width: 56,
          child: bytes == null
              ? null
              : Text(formatBytes(bytes!), textAlign: TextAlign.end, style: type.monoSmall.copyWith(color: palette.text3)),
        ),
      ],
    );
  }
}
