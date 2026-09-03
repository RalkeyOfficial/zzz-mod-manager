import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../models/character_info.dart';
import '../../models/gamebanana/gamebanana.dart';
import '../../services/gamebanana/file_selection.dart';
import '../../services/update_apply/sibling_group.dart';
import '../../services/update_apply/update_applier.dart';
import '../../services/update_apply/update_layout.dart';
import '../../services/update_apply/update_target.dart';
import '../components/dialog_section.dart';

/// The last screen before an update touches a live install.
///
/// Everything on it is something that cannot be said afterwards. It exists
/// because this app's update mechanism deliberately accepts a small set of
/// losses — a rebound keybind reverted by a shipped `.ini`, a patch overwritten
/// by the mod it patches — on the grounds that the user was told and the
/// snapshot is the way back. Both halves of that have to be true here or the
/// trade is not one.
///
/// **The snapshot leads its section.** Overwriting the folder and reverting the
/// user's keybinds are only acceptable because a copy was taken, so within
/// "what this does to the folder" the copy is stated before the two things it
/// pays for — not at the top of the dialog, where it would answer a question
/// nobody has asked yet.
///
/// It answers one question, `removeStaleInis`, and refuses in three cases it
/// cannot answer at all. That asymmetry is the design: a dialog that offered
/// "install anyway" against an unreconcilable layout would be inviting the user
/// to guess where the app would not.
///
/// **One archive can be going into several folders**, when the mod was installed
/// alongside siblings out of the same download. Every one of them is a row here
/// with its own facts, because they are separate mods being overwritten and the
/// user is consenting to each. What stays shared is stated once: the snapshot,
/// the overwrite, the keybinds, and the one question.
class UpdateConfirmChoice {
  const UpdateConfirmChoice({
    required this.removeStaleInis,
    this.accepted = const <String>{},
  });

  final bool removeStaleInis;

  /// The mod folder ids the user left ticked. Empty when the dialog offered a
  /// single mod, which the caller already has in hand.
  final Set<String> accepted;
}

Future<UpdateConfirmChoice?> showUpdateConfirmDialog(
  BuildContext context, {
  required ModInfo mod,
  required GbFile file,
  required UpdatePreview preview,
  bool flattensPatch = false,
  bool reinstall = false,
  List<UpdateTarget> siblings = const <UpdateTarget>[],
  List<SiblingRefused> refused = const <SiblingRefused>[],
  List<String> otherFolders = const <String>[],
}) =>
    showDialog<UpdateConfirmChoice>(
      context: context,
      builder: (_) => _UpdateConfirmDialog(
        mod: mod,
        file: file,
        preview: preview,
        flattensPatch: flattensPatch,
        reinstall: reinstall,
        siblings: siblings,
        refused: refused,
        otherFolders: otherFolders,
      ),
    );

class _UpdateConfirmDialog extends StatefulWidget {
  const _UpdateConfirmDialog({
    required this.mod,
    required this.file,
    required this.preview,
    this.flattensPatch = false,
    this.reinstall = false,
    this.siblings = const <UpdateTarget>[],
    this.refused = const <SiblingRefused>[],
    this.otherFolders = const <String>[],
  });

  final ModInfo mod;
  final GbFile file;
  final UpdatePreview preview;

  /// The other mods this archive installed, each with its own preview.
  final List<UpdateTarget> siblings;

  /// Members of the archive that are **not** offered, with the reason. Listed
  /// rather than omitted: a user who can see two of three mods being updated
  /// deserves to know what happened to the third.
  ///
  /// **This may name the mod the user pressed Update on**, and that is the only
  /// channel by which it can: a contested folder is a refusal the primary's own
  /// preview cannot carry, because the ambiguity needs two folders to see.
  ///
  /// The row derives its state from this list rather than from a second
  /// parameter. A caller can still drop the refusal altogether — the mapping
  /// into this list is hand-written — but it can no longer list the primary as
  /// refused *and* have it written, which is the contradiction that shipped: a
  /// forgotten refusal now shows as a missing line rather than as a screen
  /// saying two opposite things about the same folder.
  final List<SiblingRefused> refused;

  /// Folders in the archive that belong to no mod in the library.
  ///
  /// Replaces the per-mod "unused folders" notice whenever a group is on screen:
  /// a folder that is another of the user's mods is not unused, and calling it
  /// that is the misleading half of the single-mod wording.
  final List<String> otherFolders;

  /// This folder holds a patch and **nothing records which files are its**, so
  /// the write cannot put it back on top afterwards.
  ///
  /// A folder merged by hand, or one installed before that record existed. The
  /// write is still offered — the update is what the user wants and the snapshot
  /// makes it reversible — but it must not happen without this said, because the
  /// loss is otherwise invisible: the folder looks complete either way.
  final bool flattensPatch;

  /// The version already installed, going on again — a repair rather than an
  /// update. Changes the headline and the button and nothing else: what the
  /// write does to the folder is identical, and every notice below describes
  /// the write.
  final bool reinstall;

  @override
  State<_UpdateConfirmDialog> createState() => _UpdateConfirmDialogState();
}

class _UpdateConfirmDialogState extends State<_UpdateConfirmDialog> {
  /// Default on. An orphaned `.ini` is live the moment the loader reads the
  /// folder, and the rule that produced this list already refused every
  /// leftover it could not prove describes the incoming content — so what is
  /// left is a duplicate fighting the file that just landed.
  bool _removeStale = true;

  /// Ticked on open, every folder the archive can be written into.
  ///
  /// **Opt out rather than opt in**: one download covers all of them, which is
  /// the whole reason they are on one screen. Each row is still the user's to
  /// untick, and unticking is what a mod they want left alone needs.
  ///
  /// The exception is a row carrying a [SiblingCaution] — one holding something
  /// newer than this file, or one whose updates the user waved away. Both are
  /// offered, because the archive is already downloaded and they may well be
  /// wanted; neither is something to do by default.
  late final Set<String> _accepted = {
    for (final target in _targets)
      if (target.startsAccepted) target.mod.id,
  };

  AppLocalizations get loc => context.loc;

  /// The mod the user pressed Update on, first, then the archive's other mods.
  ///
  /// The primary is an ordinary row and may be unticked like any other: with the
  /// archive already downloaded, "update the others and not this one" is a
  /// coherent thing to ask for.
  List<UpdateTarget> get _targets => [
        UpdateTarget(
          mod: widget.mod,
          preview: widget.preview,
          flattensPatch: widget.flattensPatch,
          // **Read off the refused list, never passed separately.** A second
          // channel for the same fact is a channel a caller can forget, and
          // forgetting this one writes a folder the group refused.
          refusal: _refusalOf(widget.mod.id),
        ),
        ...widget.siblings,
      ];

  SiblingRefusal? _refusalOf(String modId) {
    for (final entry in widget.refused) {
      if (entry.mod.id == modId) return entry.reason;
    }
    return null;
  }

  List<UpdateTarget> get _writable => [
        for (final target in _targets)
          if (target.canProceed) target,
      ];

  List<UpdateTarget> get _chosen => [
        for (final target in _writable)
          if (_accepted.contains(target.mod.id)) target,
      ];

  /// Whether the member list is on screen at all.
  ///
  /// A refusal alone is enough: one mod being written while two are not is
  /// exactly when the user needs to see the list.
  bool get _isGroup => widget.siblings.isNotEmpty || widget.refused.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    // **Nothing at all can be written** is the refusing state, and only that.
    // A primary whose layout cannot be reconciled must not take its siblings
    // down with it, and with no siblings this is exactly the single-mod
    // condition it always was.
    final writable = _writable;
    final nothingWritable = writable.isEmpty;
    // Null where the refusal is the group's rather than the layout's — the
    // primary's own archive folder is fine, another mod just claims it too, and
    // the refused list below is what says so.
    final problem = nothingWritable ? widget.preview.layout.problem : null;
    final chosen = _chosen;

    return AlertDialog(
      title: Text(_titleFor(nothingWritable, writable)),
      content: SizedBox(
        width: 500,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: problem != null
                ? _blockedBody(problem)
                : _confirmBody(chosen),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(
            loc.t(
              nothingWritable
                  ? 'mods.update.close'
                  : 'mods.update_apply.cancel',
            ),
          ),
        ),
        if (!nothingWritable)
          FilledButton(
            // Every row unticked is a coherent state and not a mistake to
            // block: the user is deciding, and the way out is Cancel.
            onPressed: chosen.isEmpty
                ? null
                : () => Navigator.of(context).pop(
                      UpdateConfirmChoice(
                        removeStaleInis: _removeStale,
                        accepted: {for (final t in chosen) t.mod.id},
                      ),
                    ),
            child: Text(_confirmLabel(chosen)),
          ),
      ],
    );
  }

  /// Names the one mod being written, or counts them.
  ///
  /// The name comes from the writable row rather than from the primary: with a
  /// blocked primary and one writable sibling, the mod named in the headline has
  /// to be the one about to change.
  String _titleFor(bool nothingWritable, List<UpdateTarget> writable) {
    if (nothingWritable) {
      return loc.t('mods.update_apply.blocked_title',
          params: {'mod': widget.mod.name});
    }
    if (writable.length == 1) {
      return loc.t(
        widget.reinstall ? 'mods.reinstall.title' : 'mods.update_apply.title',
        params: {'mod': writable.single.mod.name},
      );
    }
    return loc.plural(
      'mods.update_apply.group_title',
      writable.length,
      params: {'count': '${writable.length}'},
    );
  }

  String _confirmLabel(List<UpdateTarget> chosen) {
    if (widget.reinstall) return loc.t('mods.reinstall.confirm');
    // The plain word while the button is disabled: "Update 0 mods" is a count
    // of nothing, and the row the user just unticked is what says why.
    if (!_isGroup || chosen.isEmpty) {
      return loc.t('mods.update_apply.confirm');
    }
    return loc.plural(
      'mods.update_apply.group_confirm',
      chosen.length,
      params: {'count': '${chosen.length}'},
    );
  }

  // ------------------------------------------------------------------ blocked

  /// The three states where the app stops rather than guessing.
  ///
  /// `layoutUnknown` is by far the commonest and is not an error: nothing was
  /// ever recorded about how this mod was installed, because `ingest` is
  /// written by this build and the whole pre-existing library predates it. The
  /// wording says that rather than implying something is broken.
  List<Widget> _blockedBody(UpdateLayoutProblem problem) {
    final key = switch (problem) {
      UpdateLayoutProblem.nothingToInstall => 'mods.update_apply.blocked_empty',
      UpdateLayoutProblem.layoutUnknown => 'mods.update_apply.blocked_unknown',
      UpdateLayoutProblem.layoutChanged => 'mods.update_apply.blocked_changed',
    };
    return [
      DialogNotice(
        icon: Icons.help_outline,
        message: loc.t(key),
        emphasis: true,
      ),
      if (widget.preview.layout.unused.isNotEmpty) ...[
        const SizedBox(height: 12),
        DialogSection(
          title: loc.t('mods.update_apply.blocked_folders_heading'),
          children: [
            for (final folder in widget.preview.layout.unused)
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 4),
                child: Text(
                  '• $folder',
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ),
          ],
        ),
      ],
      const SizedBox(height: 14),
      Text(
        loc.t('mods.update_apply.blocked_hint'),
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      ),
    ];
  }

  // ------------------------------------------------------------------ confirm

  List<Widget> _confirmBody(List<UpdateTarget> chosen) {
    // The mod the user pressed the button on, whose facts are the ones stated
    // inline when there is only one folder to describe.
    final preview = widget.preview;
    final patchShaped = [
      for (final target in chosen)
        if (target.preview.incomingIsPatch) target.mod.name,
    ];
    final flattening = [
      for (final target in chosen)
        if (target.flattensPatch) target.mod.name,
    ];

    return [
      DialogSection(
        title: loc.t('mods.update_apply.what_heading'),
        children: [
          DialogFact(
            icon: widget.reinstall ? Icons.restart_alt : Icons.arrow_circle_up,
            label: loc.t(widget.reinstall
                ? 'mods.reinstall.installing'
                : 'mods.update_apply.installing'),
            value: fileDisplayName(widget.file),
            detail: fileDisplayDetail(widget.file),
          ),
          // The member list says where it goes when there is more than one
          // folder, so a single "Into" row would be naming one of several.
          if (!_isGroup)
            DialogFact(
              icon: Icons.folder_outlined,
              label: loc.t('mods.update_apply.into_folder'),
              value: widget.mod.name,
            ),
        ],
      ),

      if (_isGroup) ..._membersSection(),
      if (widget.refused.isNotEmpty) ..._refusedSection(),

      // The one genuinely alarming state, and the only place `emphasis` is used
      // on this dialog — it changes what the user should expect the update to
      // do, where everything else merely describes it.
      //
      // A count of missing files for one folder; the folders it applies to when
      // there are several, since the count is that folder's and not the group's.
      if (!_isGroup && preview.incomingIsPatch) ...[
        const SizedBox(height: 4),
        DialogNotice(
          icon: Icons.extension_outlined,
          emphasis: true,
          message: loc.t(
            'mods.update_apply.patch_warning',
            params: {'count': '${preview.patch.missing.length}'},
          ),
        ),
      ],
      if (_isGroup && patchShaped.isNotEmpty) ...[
        const SizedBox(height: 4),
        DialogNotice(
          icon: Icons.extension_outlined,
          emphasis: true,
          message: loc.t(
            'mods.update_apply.group_patch_warning',
            params: {'mods': patchShaped.join(', ')},
          ),
        ),
      ],

      const SizedBox(height: 16),
      DialogSection(
        title: loc.t('mods.update_apply.effects_heading'),
        children: [
          // First **in this section**: it is the promise that makes the two
          // below it an acceptable trade, so it is read before them rather
          // than after.
          DialogNotice(
            icon: Icons.history,
            message: loc.t('mods.update_apply.snapshot_note'),
          ),
          DialogNotice(
            icon: Icons.layers_outlined,
            message: loc.t('mods.update_apply.overwrite_note'),
          ),
          // **Directly under the overwrite note**, because it is the one thing
          // an overwrite would not do on its own. A count rather than a list:
          // a version that reorganises its textures drops dozens of files, and
          // the folder is not what the user is deciding about.
          //
          // For a group the count belongs on each row instead: it differs per
          // folder, and summing it would describe nothing the user can act on.
          if (!_isGroup && preview.dropped.remove.isNotEmpty)
            DialogNotice(
              icon: Icons.auto_delete_outlined,
              message: loc.plural(
                'mods.update_apply.dropped_note',
                preview.dropped.remove.length,
                params: {'count': '${preview.dropped.remove.length}'},
              ),
            ),
          // The accepted loss, named rather than discovered. Re-applying the
          // user's .ini edits was considered and rejected — there is no pristine
          // baseline to diff against, so a merge reports every *author* change
          // as a user conflict — and the snapshot is what makes that defensible.
          DialogNotice(
            icon: Icons.keyboard_outlined,
            message: loc.t('mods.update_apply.keybind_note'),
          ),
          // **The one loss on this screen that is not paid for by a rule.** A
          // patch whose files are recorded is set aside and placed back; this
          // folder's are not on record, so anything the new version ships the
          // same name for replaces it. Said here because it cannot be seen
          // afterwards — the folder looks complete either way.
          if (!_isGroup && widget.flattensPatch)
            DialogNotice(
              icon: Icons.call_split,
              message: loc.t('mods.update_apply.patch_unrecorded_note'),
            ),
          if (_isGroup && flattening.isNotEmpty)
            DialogNotice(
              icon: Icons.call_split,
              message: loc.t(
                'mods.update_apply.group_flattens',
                params: {'mods': flattening.join(', ')},
              ),
            ),
          // **Only where nothing else in the archive is a mod of the user's.**
          // With a group on screen a leftover folder is usually another of their
          // mods, and "isn't part of this mod" is the misleading half of that
          // sentence — so the group names what belongs to nobody instead.
          if (!_isGroup && preview.layout.unused.isNotEmpty)
            DialogNotice(
              icon: Icons.folder_off_outlined,
              message: loc.t(
                'mods.update_apply.unused_folders',
                params: {'folders': preview.layout.unused.join(', ')},
              ),
            ),
          if (_isGroup && widget.otherFolders.isNotEmpty)
            DialogNotice(
              icon: Icons.folder_off_outlined,
              message: loc.t(
                'mods.update_apply.group_other_folders',
                params: {'folders': widget.otherFolders.join(', ')},
              ),
            ),
        ],
      ),

      ..._leftoversSection(chosen),
    ];
  }

  // ------------------------------------------------------------------ members

  /// One row per folder the archive goes into, ticked.
  ///
  /// Each row carries only what differs between folders — how much lands, what
  /// gets dropped, what is left over. Everything the write does the same way
  /// everywhere stays in the effects section below, said once.
  List<Widget> _membersSection() => [
        const SizedBox(height: 16),
        DialogSection(
          title: loc.t('mods.update_apply.group_heading'),
          children: [
            for (final target in _writable)
              CheckboxListTile(
                value: _accepted.contains(target.mod.id),
                onChanged: (value) => setState(() {
                  if (value ?? false) {
                    _accepted.add(target.mod.id);
                  } else {
                    _accepted.remove(target.mod.id);
                  }
                }),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(
                  target.mod.name,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                subtitle: Text(
                  _rowDetail(target),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ),
          ],
        ),
      ];

  String _rowDetail(UpdateTarget target) {
    final dropped = target.preview.dropped.remove.length;
    final leftovers = target.leftoverCount;
    return <String>[
      // **First, because it is why the row is unticked.** The counts describe
      // what the write would do; this says whether it should happen at all.
      if (target.caution case final caution?)
        loc.t(switch (caution) {
          SiblingCaution.holdsNewer => 'mods.update_apply.group_row_newer',
          SiblingCaution.dismissed => 'mods.update_apply.group_row_dismissed',
        }),
      loc.plural(
        'mods.update_apply.group_row_files',
        target.preview.incoming.files.length,
        params: {'count': '${target.preview.incoming.files.length}'},
      ),
      if (dropped > 0)
        loc.plural(
          'mods.update_apply.group_row_dropped',
          dropped,
          params: {'count': '$dropped'},
        ),
      if (leftovers > 0)
        loc.plural(
          'mods.update_apply.group_row_leftovers',
          leftovers,
          params: {'count': '$leftovers'},
        ),
    ].join(' · ');
  }

  /// The members of the archive that are not offered, and why.
  ///
  /// A literal key per reason rather than one interpolated from the enum name:
  /// `l10n_keys_test` finds keys by regex over the source, and a key it cannot
  /// see is a key nothing stops from going missing.
  List<Widget> _refusedSection() => [
        const SizedBox(height: 16),
        DialogSection(
          title: loc.t('mods.update_apply.group_refused_heading'),
          children: [
            for (final entry in widget.refused)
              DialogNotice(
                icon: Icons.block_outlined,
                message: loc.t(
                  switch (entry.reason) {
                    SiblingRefusal.notBase =>
                      'mods.update_apply.group_refused_not_base',
                    SiblingRefusal.alreadyCurrent =>
                      'mods.update_apply.group_refused_already_current',
                    SiblingRefusal.layoutChanged =>
                      'mods.update_apply.group_refused_layout',
                    SiblingRefusal.sourceCollision =>
                      'mods.update_apply.group_refused_collision',
                  },
                  params: {'mod': entry.mod.name},
                ),
              ),
          ],
        ),
      ];

  // ---------------------------------------------------------------- leftovers

  /// The one question this dialog asks, asked **once** for the whole group.
  ///
  /// A checkbox per folder would be a quiz whose answer is the same every time:
  /// an orphaned `.ini` is live the moment the loader reads the folder, and the
  /// rule that produced each list already refused every leftover it could not
  /// prove describes the incoming content. So the count is the total across the
  /// ticked folders, and where more than one contributes the folders are named
  /// instead of the files — the same filename in two mods is two files.
  List<Widget> _leftoversSection(List<UpdateTarget> chosen) {
    final contributing = [
      for (final target in chosen)
        if (target.leftoverCount > 0) target,
    ];
    final total = contributing.fold<int>(0, (sum, t) => sum + t.leftoverCount);
    final kept = [
      for (final target in chosen)
        for (final path in target.preview.staleInis.keptUndecidable)
          target.preview.onDisk(path),
    ];
    if (total == 0 && kept.isEmpty) return const <Widget>[];

    return [
      const SizedBox(height: 16),
      DialogSection(
        title: loc.t('mods.update_apply.leftovers_heading'),
        subtitle:
            total == 0 ? null : loc.t('mods.update_apply.remove_stale_why'),
        children: [
          if (total > 0)
            CheckboxListTile(
              value: _removeStale,
              onChanged: (value) =>
                  setState(() => _removeStale = value ?? true),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(
                _removeStaleLabel(contributing, total),
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            ),
          // Never offered for deletion, and said out loud. These are the
          // hand-merged-second-mod case: an .ini naming files this download
          // knows nothing about belongs to something else in the same folder.
          if (kept.isNotEmpty)
            Text(
              loc.t(
                'mods.update_apply.kept_inis',
                params: {'files': kept.join(', ')},
              ),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
        ],
      ),
    ];
  }

  String _removeStaleLabel(List<UpdateTarget> contributing, int total) {
    if (contributing.length == 1) {
      final only = contributing.single.preview;
      return loc.plural(
        'mods.update_apply.remove_stale',
        total,
        params: {
          'count': '$total',
          // The real spelling, not the normalised one this rule compares in:
          // naming a file the user does not have is its own small lie, and it
          // is the same mistake that made the deletion silently do nothing.
          'files':
              only.staleInis.stale.map((s) => only.onDisk(s.path)).join(', '),
        },
      );
    }
    return loc.plural(
      'mods.update_apply.group_remove_stale',
      total,
      params: {
        'count': '$total',
        'mods': contributing.map((t) => t.mod.name).join(', '),
      },
    );
  }
}
