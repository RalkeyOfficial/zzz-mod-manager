import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../models/character_info.dart';
import '../../models/gamebanana/gamebanana.dart';
import '../../services/gamebanana/file_selection.dart';
import '../../services/update_apply/update_applier.dart';
import '../../services/update_apply/update_layout.dart';
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
class UpdateConfirmChoice {
  const UpdateConfirmChoice({required this.removeStaleInis});

  final bool removeStaleInis;
}

Future<UpdateConfirmChoice?> showUpdateConfirmDialog(
  BuildContext context, {
  required ModInfo mod,
  required GbFile file,
  required UpdatePreview preview,
  bool flattensPatch = false,
}) =>
    showDialog<UpdateConfirmChoice>(
      context: context,
      builder: (_) => _UpdateConfirmDialog(
        mod: mod,
        file: file,
        preview: preview,
        flattensPatch: flattensPatch,
      ),
    );

class _UpdateConfirmDialog extends StatefulWidget {
  const _UpdateConfirmDialog({
    required this.mod,
    required this.file,
    required this.preview,
    this.flattensPatch = false,
  });

  final ModInfo mod;
  final GbFile file;
  final UpdatePreview preview;

  /// This folder holds a patch and **nothing records which files are its**, so
  /// the write cannot put it back on top afterwards.
  ///
  /// A folder merged by hand, or one installed before that record existed. The
  /// write is still offered — the update is what the user wants and the snapshot
  /// makes it reversible — but it must not happen without this said, because the
  /// loss is otherwise invisible: the folder looks complete either way.
  final bool flattensPatch;

  @override
  State<_UpdateConfirmDialog> createState() => _UpdateConfirmDialogState();
}

class _UpdateConfirmDialogState extends State<_UpdateConfirmDialog> {
  /// Default on. An orphaned `.ini` is live the moment the loader reads the
  /// folder, and the rule that produced this list already refused every
  /// leftover it could not prove describes the incoming content — so what is
  /// left is a duplicate fighting the file that just landed.
  bool _removeStale = true;

  AppLocalizations get loc => context.loc;

  @override
  Widget build(BuildContext context) {
    final preview = widget.preview;
    final blocked = preview.layout.problem;

    return AlertDialog(
      title: Text(
        loc.t(
          blocked == null
              ? 'mods.update_apply.title'
              : 'mods.update_apply.blocked_title',
          params: {'mod': widget.mod.name},
        ),
      ),
      content: SizedBox(
        width: 500,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: blocked != null
                ? _blockedBody(blocked)
                : _confirmBody(preview),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(
            loc.t(
              blocked == null
                  ? 'mods.update_apply.cancel'
                  : 'mods.update.close',
            ),
          ),
        ),
        if (blocked == null)
          FilledButton(
            onPressed: () => Navigator.of(context).pop(
              UpdateConfirmChoice(removeStaleInis: _removeStale),
            ),
            child: Text(loc.t('mods.update_apply.confirm')),
          ),
      ],
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

  List<Widget> _confirmBody(UpdatePreview preview) {
    return [
      DialogSection(
        title: loc.t('mods.update_apply.what_heading'),
        children: [
          DialogFact(
            icon: Icons.arrow_circle_up,
            label: loc.t('mods.update_apply.installing'),
            value: fileDisplayName(widget.file),
            detail: fileDisplayDetail(widget.file),
          ),
          DialogFact(
            icon: Icons.folder_outlined,
            label: loc.t('mods.update_apply.into_folder'),
            value: widget.mod.name,
          ),
        ],
      ),

      // The one genuinely alarming state, and the only place `emphasis` is used
      // on this dialog — it changes what the user should expect the update to
      // do, where everything else merely describes it.
      if (preview.incomingIsPatch) ...[
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
          if (preview.dropped.remove.isNotEmpty)
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
          if (widget.flattensPatch)
            DialogNotice(
              icon: Icons.call_split,
              message: loc.t('mods.update_apply.patch_unrecorded_note'),
            ),
          if (preview.layout.unused.isNotEmpty)
            DialogNotice(
              icon: Icons.folder_off_outlined,
              message: loc.t(
                'mods.update_apply.unused_folders',
                params: {'folders': preview.layout.unused.join(', ')},
              ),
            ),
        ],
      ),

      if (preview.staleInis.stale.isNotEmpty ||
          preview.staleInis.keptUndecidable.isNotEmpty) ...[
        const SizedBox(height: 16),
        DialogSection(
          title: loc.t('mods.update_apply.leftovers_heading'),
          subtitle: preview.staleInis.stale.isEmpty
              ? null
              : loc.t('mods.update_apply.remove_stale_why'),
          children: [
            if (preview.staleInis.stale.isNotEmpty)
              CheckboxListTile(
                value: _removeStale,
                onChanged: (value) =>
                    setState(() => _removeStale = value ?? true),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(
                  loc.plural(
                    'mods.update_apply.remove_stale',
                    preview.staleInis.stale.length,
                    params: {
                      'count': '${preview.staleInis.stale.length}',
                      // The real spelling, not the normalised one this rule
                      // compares in: naming a file the user does not have is
                      // its own small lie, and it is the same mistake that made
                      // the deletion silently do nothing.
                      'files': preview.staleInis.stale
                          .map((s) => preview.onDisk(s.path))
                          .join(', '),
                    },
                  ),
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ),
            // Never offered for deletion, and said out loud. These are the
            // hand-merged-second-mod case: an .ini naming files this download
            // knows nothing about belongs to something else in the same folder.
            if (preview.staleInis.keptUndecidable.isNotEmpty)
              Text(
                loc.t(
                  'mods.update_apply.kept_inis',
                  params: {
                    'files': preview.staleInis.keptUndecidable
                        .map(preview.onDisk)
                        .join(', '),
                  },
                ),
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
          ],
        ),
      ],
    ];
  }
}
