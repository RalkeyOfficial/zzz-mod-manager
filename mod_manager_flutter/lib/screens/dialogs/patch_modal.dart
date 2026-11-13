/// The patch window, "This looks like a patch" (board `PatchModal`): where a patch-shaped download goes, in two contexts.
///
/// An install's: into a mod the library already has, or as a new mod of its own, with the mod it patches named and fetched when the user says which.
/// An update's (`docs/update-runs.md` §6): on top of the mod the update is for, preselected, since the user picked this file for that mod,
/// or into a different mod the library has. There is no new mod here, since an update has a mod.
///
/// Either way the library list is every mod, ordered by how well each answers for the patch and never shortened, and nothing in it is picked for the user (`docs/patch-destinations.md` §3).
/// Its hints say what puts a row where it is and decide nothing.
library;

import 'package:flutter/material.dart';

import '../../core/palette.dart';
import '../../core/type_scale.dart';
import '../../l10n/app_localizations.dart';
import '../../models/character_info.dart';
import '../../services/origin_summary.dart';
import '../../services/patch_destination_ranking.dart';
import '../../utils/byte_format.dart';
import '../../utils/categories.dart';
import '../../utils/zzz_characters.dart';
import '../components/character_tile.dart';
import '../components/mod_thumb.dart';
import '../components/question_parts.dart';
import '../components/resolve/resolve_fragments.dart';
import '../components/zenith_controls.dart';
import '../components/zenith_dialog.dart';
import 'companion_resolve_dialog.dart';
import 'patch_install_prompt.dart';

/// How many missing names the disclosure lists before "and N more".
const int _missingShown = 7;

/// The archive the patch was downloaded in, for the window's subtitle.
class PatchSource {
  const PatchSource({required this.fileName, this.bytes});

  final String fileName;

  /// The archive's size, when known.
  final int? bytes;
}

/// Which of the two the patch window is.
sealed class PatchModalContext {
  const PatchModalContext({required this.library, this.source});

  /// Every folder in the library, tracked or not: a destination needs no remote identity of its own.
  final List<ModInfo> library;

  final PatchSource? source;
}

/// An install that found one or more patches among the mods it is about to create.
final class PatchInstallContext extends PatchModalContext {
  const PatchInstallContext({
    required this.subjects,
    required super.library,
    super.source,
    this.combined = false,
    this.characterId,
    this.patchAuthor,
  });

  final List<PatchInstallSubject> subjects;

  /// The folder picker chose One mod, so the patch cannot go into a mod already in the library.
  final bool combined;

  /// The install's character: the header's ground, and "Same character" on a row.
  final String? characterId;

  /// Who made the patch, when the page said: "Same author" on a row.
  final String? patchAuthor;
}

/// An update of [mod] whose download looks like a patch.
final class PatchUpdateContext extends PatchModalContext {
  const PatchUpdateContext({
    required this.mod,
    required this.subject,
    required super.library,
    super.source,
  });

  final ModInfo mod;

  /// The download, as the rows and the disclosure read it. Its [PatchInstallSubject.destinations] rank the library.
  final PatchInstallSubject subject;
}

/// What an update's patch window was answered with: the folder the patch goes on top of, or Skip this update.
/// Closing the window answers nothing, which is null.
class UpdatePatchAnswer {
  const UpdatePatchAnswer.into(String this.modId);

  const UpdatePatchAnswer.skipped() : modId = null;

  /// The folder id: the mod the update is for, or a different one.
  final String? modId;

  bool get skipped => modId == null;
}

/// Opens the patch window for an install. Null when closed without an answer.
Future<PatchPromptAnswer?> showInstallPatchModal(BuildContext context, PatchInstallContext question) =>
    showDialog<PatchPromptAnswer>(
      context: context,
      // A patch installed without an answer is a folder that does nothing until the user acts, so a stray tap outside does not close it.
      barrierDismissible: false,
      builder: (_) => PatchModal(question: question),
    );

/// Opens the patch window for an update. Null when closed without an answer, which leaves the question waiting.
Future<UpdatePatchAnswer?> showUpdatePatchModal(BuildContext context, PatchUpdateContext question) =>
    showDialog<UpdatePatchAnswer>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PatchModal(question: question),
    );

/// The window itself, for both contexts. It pops a [PatchPromptAnswer] for an install and an [UpdatePatchAnswer] for an update.
class PatchModal extends StatefulWidget {
  const PatchModal({super.key, required this.question});

  final PatchModalContext question;

  @override
  State<PatchModal> createState() => _PatchModalState();
}

/// Where one subject's answer stands.
enum _Mode {
  /// Into a mod the library already has; for an update, a different one.
  library,

  /// An install's new mod of its own; an update's own mod, the patch on top.
  own,
}

class _PatchModalState extends State<PatchModal> {
  final Map<String, _Mode> _modes = {};
  final Map<String, ModInfo> _picked = {};
  final Map<String, InstallAsNewMod> _named = {};

  /// Each subject's library search, kept while its card is closed so the box and the list it filters agree when it opens again.
  final Map<String, TextEditingController> _searches = {};
  final Set<String> _missingOpen = {};

  @override
  void dispose() {
    for (final search in _searches.values) {
      search.dispose();
    }
    super.dispose();
  }

  PatchModalContext get _question => widget.question;

  List<PatchInstallSubject> get _subjects => switch (_question) {
        PatchInstallContext(:final subjects) => subjects,
        PatchUpdateContext(:final subject) => [subject],
      };

  bool get _update => _question is PatchUpdateContext;

  bool get _canOfferLibrary => switch (_question) {
        PatchInstallContext(:final combined, :final library) => !combined && library.isNotEmpty,
        PatchUpdateContext(:final library, :final mod) => library.any((m) => m.id != mod.id),
      };

  _Mode _modeOf(PatchInstallSubject subject) =>
      _modes[subject.modName] ?? (_update ? _Mode.own : (_canOfferLibrary ? _Mode.library : _Mode.own));

  bool _answered(PatchInstallSubject subject) =>
      _modeOf(subject) == _Mode.own || _picked.containsKey(subject.modName);

  void _confirm() {
    if (!_subjects.every(_answered)) return;
    final question = _question;
    switch (question) {
      case PatchUpdateContext(:final mod, :final subject):
        final into = _modeOf(subject) == _Mode.own ? mod : _picked[subject.modName]!;
        Navigator.of(context).pop(UpdatePatchAnswer.into(into.id));
      case PatchInstallContext():
        Navigator.of(context).pop(PatchPromptAnswer({
          for (final subject in _subjects)
            subject.modName: _modeOf(subject) == _Mode.library
                ? InstallIntoMod(
                    modId: _picked[subject.modName]!.id,
                    modName: _picked[subject.modName]!.name,
                    characterId: _picked[subject.modName]!.characterId,
                  )
                : _named[subject.modName] ?? const InstallAsNewMod(),
        }));
    }
  }

  void _decline() => Navigator.of(context).pop(switch (_question) {
        PatchUpdateContext() => const UpdatePatchAnswer.skipped(),
        PatchInstallContext() => const PatchPromptAnswer.declined(),
      });

  Future<void> _nameBase(PatchInstallSubject subject) async {
    final current = _named[subject.modName];
    final outcome = await showCompanionResolveDialog(
      context,
      modName: subject.modName,
      heldFileIds: {?subject.patchFileId},
      existing: current?.base,
    );
    if (outcome == null || !mounted) return;
    setState(() {
      switch (outcome) {
        case CompanionNamed(:final companion, :final modName, :final file):
          _named[subject.modName] = InstallAsNewMod(base: companion, baseName: modName, baseFile: file);
        case CompanionRemoved():
          _named.remove(subject.modName);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final subjects = _subjects;
    final question = _question;
    final many = subjects.length > 1;

    final String title;
    final String leave;
    String label;
    String? status;
    switch (question) {
      case PatchUpdateContext(:final subject):
        title = loc.t('mods.patch_modal.title_update');
        leave = loc.t('mods.patch_modal.skip_update');
        final picked = _picked[subject.modName];
        (label, status) = switch (_modeOf(subject)) {
          _Mode.own => (loc.t('mods.patch_modal.go_on_top'), null),
          _Mode.library when picked != null => (loc.t('mods.patch_modal.go_patch', params: {'mod': picked.name}), null),
          _Mode.library => (loc.t('mods.patch_modal.go_patch_disabled'), loc.t('mods.patch_modal.status_pick_mod')),
        };
      case PatchInstallContext():
        title = loc.t(many ? 'mods.patch_modal.title_many' : 'mods.patch_modal.title');
        leave = loc.t('mods.patch_modal.dont_install');
        if (many) {
          final done = subjects.where(_answered).length;
          label = loc.t('mods.patch_modal.go_install');
          status = done == subjects.length
              ? null
              : loc.t('mods.patch_modal.status_answered', params: {'done': '$done', 'total': '${subjects.length}'});
        } else {
          final subject = subjects.single;
          final picked = _picked[subject.modName];
          (label, status) = switch (_modeOf(subject)) {
            _Mode.library when picked != null => (loc.t('mods.patch_modal.go_patch', params: {'mod': picked.name}), null),
            _Mode.library => (loc.t('mods.patch_modal.go_install'), loc.t('mods.patch_modal.status_pick_mod')),
            _Mode.own when _named.containsKey(subject.modName) => (loc.t('mods.patch_modal.go_new'), null),
            _Mode.own => (loc.t('mods.patch_modal.go_alone'), null),
          };
        }
    }
    final ready = subjects.every(_answered);

    return ZenithDialog.sectioned(
      width: 720,
      title: title,
      leading: switch (question) {
        PatchUpdateContext(:final mod) => QuestionTile(mod: mod),
        PatchInstallContext(:final characterId) => QuestionTile(characterId: characterId),
      },
      subtitleWidget: _subtitle(context),
      closeAlignsStart: false,
      headerPadding: const EdgeInsets.fromLTRB(24, 20, 24, 14),
      footerStart: TextButton(onPressed: _decline, child: Text(leave)),
      actions: [QuestionFooterEnd(status: status, label: label, onPressed: ready ? _confirm : null)],
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: many ? 24 : 12,
        children: [for (final subject in subjects) _section(context, subject, named: many)],
      ),
    );
  }

  Widget? _subtitle(BuildContext context) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final source = _question.source;
    final where = switch (_question) {
      PatchUpdateContext(:final mod) => loc.t('mods.patch_modal.source_update', params: {'mod': mod.name}),
      PatchInstallContext() when source == null => null,
      PatchInstallContext() => loc.t('mods.patch_modal.source_gamebanana'),
    };
    final style = Theme.of(context).textTheme.bodySmall!.copyWith(color: palette.text3);
    final rest = [?where, if (source?.bytes case final bytes? when bytes > 0) formatBytes(bytes)];
    if (source == null && rest.isEmpty) return null;
    return Text.rich(
      TextSpan(children: [
        if (source != null) TextSpan(text: source.fileName, style: ZenithType.of(context).mono.copyWith(color: palette.text3)),
        if (rest.isNotEmpty) TextSpan(text: '${source == null ? '' : ' · '}${rest.join(' · ')}'),
      ]),
      style: style,
    );
  }

  Widget _section(BuildContext context, PatchInstallSubject subject, {required bool named}) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final mode = _modeOf(subject);
    final question = _question;
    final libraryCard = ChoiceCard(
      selected: mode == _Mode.library,
      title: loc.t(_update ? 'mods.patch_modal.into_other' : 'mods.patch_modal.into'),
      description: _canOfferLibrary
          ? loc.t('mods.patch_modal.into_desc')
          : loc.t(switch (question) {
              PatchInstallContext(combined: true) => 'mods.patch_modal.into_combined',
              PatchInstallContext() => 'mods.patch_modal.into_no_library',
              PatchUpdateContext() => 'mods.patch_modal.into_no_other',
            }),
      onTap: _canOfferLibrary ? () => setState(() => _modes[subject.modName] = _Mode.library) : null,
      body: _LibraryPicker(
        subject: subject,
        question: question,
        search: _searches.putIfAbsent(subject.modName, TextEditingController.new),
        picked: _picked[subject.modName]?.id,
        onQuery: (_) => setState(() {}),
        onPick: (mod) => setState(() => _picked[subject.modName] = mod),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 12,
      children: [
        if (named) Text(subject.modName, style: ZenithType.of(context).mono.copyWith(color: palette.text)),
        _intro(context, subject),
        ChoiceGroup(
          label: subject.modName,
          spacing: 12,
          children: [
            if (question case PatchUpdateContext(:final mod))
              ChoiceCard(
                selected: mode == _Mode.own,
                title: loc.t('mods.patch_modal.on_top', params: {'mod': mod.name}),
                titleTrailing: DashedHint(loc.t('mods.patch_modal.on_top_hint')),
                description: loc.t('mods.patch_modal.on_top_desc'),
                onTap: () => setState(() => _modes[subject.modName] = _Mode.own),
              ),
            libraryCard,
            if (question is PatchInstallContext)
              ChoiceCard(
                selected: mode == _Mode.own,
                title: loc.t('mods.patch_modal.new_mod'),
                description: loc.t('mods.patch_modal.new_mod_desc'),
                onTap: () => setState(() => _modes[subject.modName] = _Mode.own),
                body: _baseRow(context, subject),
              ),
          ],
        ),
      ],
    );
  }

  /// What the patch is, and the files it expects or brings, behind a disclosure.
  Widget _intro(BuildContext context, PatchInstallSubject subject) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final names = subject.missingFiles;
    final count = names.length;
    final assets = subject.kind == PatchKind.assets;
    final intro = count == 0
        ? loc.t('mods.patch_modal.intro')
        : loc.plural(assets ? 'mods.patch_modal.intro_asset' : 'mods.patch_modal.intro_ini', count,
            params: {'count': '$count'});
    final open = _missingOpen.contains(subject.modName);
    final shown = names.take(_missingShown).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 6,
      children: [
        Text(intro, style: text.bodyMedium?.copyWith(color: palette.textProse)),
        if (count > 0) ...[
          Semantics(
            button: true,
            expanded: open,
            child: InkWell(
              onTap: () => setState(() => open ? _missingOpen.remove(subject.modName) : _missingOpen.add(subject.modName)),
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 6,
                  children: [
                    Icon(open ? Icons.expand_more_rounded : Icons.chevron_right_rounded, size: 14, color: palette.text2),
                    Text(
                      loc.plural(assets ? 'mods.patch_modal.files_show' : 'mods.patch_modal.missing_show', count,
                          params: {'count': '$count'}),
                      style: text.bodySmall?.copyWith(color: palette.text2),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (open)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: palette.ground,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: palette.outline),
              ),
              child: Text(
                [
                  ...shown,
                  if (count > shown.length) loc.t('mods.patch_modal.missing_more', params: {'count': '${count - shown.length}'}),
                ].join(' · '),
                style: ZenithType.of(context).monoSmall.copyWith(color: palette.text2, height: 1.8),
              ),
            ),
        ],
      ],
    );
  }

  /// An install's new mod: the mod the patch is for, when the user named it, with Change; or the button that names it.
  Widget _baseRow(BuildContext context, PatchInstallSubject subject) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final named = _named[subject.modName];
    final base = named?.base;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        if (base == null)
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              style: smallButtonStyle(context),
              onPressed: () => _nameBase(subject),
              child: Text(loc.t('mods.patch_modal.find_base')),
            ),
          )
        else
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: palette.dialog,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: palette.outline),
            ),
            child: Row(
              spacing: 12,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        named!.baseName ?? '#${base.modId}',
                        style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600, color: palette.text),
                      ),
                      Text(
                        describeRecordedFile(loc, summarizeDownload(base)),
                        style: text.bodySmall?.copyWith(color: palette.text3),
                      ),
                    ],
                  ),
                ),
                TextButton(
                  style: smallButtonStyle(context),
                  onPressed: () => _nameBase(subject),
                  child: Text(loc.t('mods.patch_modal.change')),
                ),
              ],
            ),
          ),
        Text(
          loc.t(base == null ? 'mods.patch_modal.alone_note' : 'mods.patch_modal.new_note'),
          style: text.bodySmall?.copyWith(color: palette.text3),
        ),
      ],
    );
  }
}

/// The library, searched and in ranked order, with nothing picked for the user.
class _LibraryPicker extends StatelessWidget {
  const _LibraryPicker({
    required this.subject,
    required this.question,
    required this.search,
    required this.picked,
    required this.onQuery,
    required this.onPick,
  });

  final PatchInstallSubject subject;
  final PatchModalContext question;
  final TextEditingController search;
  final String? picked;
  final ValueChanged<String> onQuery;
  final ValueChanged<ModInfo> onPick;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final needle = search.text.trim().toLowerCase();
    final rows = [
      for (final row in _ordered())
        if (needle.isEmpty || _searchable(loc, row.mod).any((field) => field.toLowerCase().contains(needle))) row,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        QuestionSearchField(hint: loc.t('mods.patch_modal.search'), controller: search, onChanged: onQuery),
        if (rows.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(loc.t('mods.patch_install.destination_no_match'), style: text.bodySmall?.copyWith(color: palette.text3)),
          )
        else
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240),
            child: SingleChildScrollView(
              child: ChoiceGroup(
                label: loc.t('mods.patch_modal.list_label'),
                children: [for (final row in rows) _row(context, row.mod, row.rank)],
              ),
            ),
          ),
        Text(loc.t('mods.patch_modal.list_note'), style: text.bodySmall?.copyWith(color: palette.text3)),
      ],
    );
  }

  Widget _row(BuildContext context, ModInfo mod, DestinationRank? rank) {
    final loc = context.loc;
    final held = _holdsPatchFile(mod);
    final hints = held ? const <String>[] : _hints(loc, mod, rank);
    final sub = held
        ? loc.t('mods.resolve.file_in_folder')
        : [libraryGroupName(libraryGroupOf(mod.characterId), loc), ?mod.author, ?mod.origin?.base?.versionLabel]
            .join(' · ');
    return PickRow(
      selected: !held && mod.id == picked,
      onTap: held ? null : () => onPick(mod),
      leading: ModThumb(mod: mod, width: 40, height: 28, radius: 5),
      title: mod.name,
      subtitle: sub,
      hints: [for (final hint in hints) DashedHint(hint)],
      semanticsLabel: [mod.name, sub, ...hints].join(', '),
    );
  }

  /// Everything the row shows, which is everything the search matches.
  List<String> _searchable(AppLocalizations loc, ModInfo mod) => [
        mod.name,
        ?mod.author,
        ?mod.origin?.base?.versionLabel,
        libraryGroupName(libraryGroupOf(mod.characterId), loc),
      ];

  /// The patch's character and author, which a row may share.
  (String?, String?) get _patchOwn => switch (question) {
        PatchUpdateContext(:final mod) => (mod.characterId, mod.author),
        PatchInstallContext(:final characterId, :final patchAuthor) => (characterId, patchAuthor),
      };

  /// What puts a row where it is, in order: the author's own requirement, the files it holds, the same author; the same character only when nothing else is said.
  List<String> _hints(AppLocalizations loc, ModInfo mod, DestinationRank? rank) {
    final (character, author) = _patchOwn;
    final hints = <String>[
      if (rank != null && rank.requiredByAuthor) loc.t('mods.patch_install.destination_required'),
      if (rank != null && rank.matched > 0)
        subject.kind == PatchKind.assets
            ? loc.plural('mods.patch_install.destination_match', rank.fingerprint,
                params: {'matched': '${rank.matched}', 'count': '${rank.fingerprint}'})
            : loc.plural('mods.patch_modal.match_ini', rank.fingerprint,
                params: {'matched': '${rank.matched}', 'count': '${rank.fingerprint}'}),
      if (author != null && mod.author != null && author.toLowerCase() == mod.author!.toLowerCase())
        loc.t('mods.patch_modal.hint_same_author'),
    ];
    if (hints.isEmpty && character != null && character != unknownCharacterId && character == mod.characterId) {
      hints.add(loc.t('mods.patch_modal.hint_same_character'));
    }
    return hints;
  }

  /// Whether [mod]'s base is the patch's own file, which no folder can be patched with: a page is never refused, only its file.
  bool _holdsPatchFile(ModInfo mod) {
    final fileId = subject.patchFileId;
    final base = mod.origin?.base;
    return fileId != null && base != null && base.modId == subject.patchModId && base.fileId == fileId;
  }

  /// The library in ranked order, each folder with its standing if it has one.
  /// Nothing is dropped: a folder the ranking never covered keeps its place at the end. An update's own mod is its own card, not a row.
  List<({ModInfo mod, DestinationRank? rank})> _ordered() {
    final own = switch (question) {
      PatchUpdateContext(:final mod) => mod.id,
      PatchInstallContext() => null,
    };
    final library = [for (final mod in question.library) if (mod.id != own) mod];
    if (subject.destinations.isEmpty) return [for (final mod in library) (mod: mod, rank: null)];
    final byId = {for (final mod in library) mod.id: mod};
    final placed = <String>{};
    final ordered = <({ModInfo mod, DestinationRank? rank})>[];
    for (final rank in subject.destinations) {
      final mod = byId[rank.modId];
      if (mod == null) continue;
      ordered.add((mod: mod, rank: rank));
      placed.add(mod.id);
    }
    for (final mod in library) {
      if (!placed.contains(mod.id)) ordered.add((mod: mod, rank: null));
    }
    return ordered;
  }
}
