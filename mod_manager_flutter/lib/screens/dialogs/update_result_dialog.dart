import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../models/character_info.dart';
import '../../models/gamebanana/gamebanana.dart';
import '../../services/gamebanana/file_selection.dart';
import '../../services/update_apply/update_applier.dart';
import '../../services/update_apply/update_target.dart';
import '../components/dialog_section.dart';

/// What the update did, said once, right afterwards.
///
/// **Sectioned rather than run together.** The first version was a paragraph
/// followed by two greyed lines and then a bare list of keybinds, and it read as
/// a pile of unrelated facts — the list in particular, which arrived with no
/// heading that explained why it was there. The three things this dialog has to
/// say are answers to three different questions, so each gets its own headed
/// block: *what landed*, *what you lost*, *how to undo it*.
///
/// The keybind block is the one that has to carry its own explanation, because
/// it is the only place the update path's accepted loss becomes visible. It is
/// also **a diff and not an inventory** — see `keybind_changes.dart` — so it is
/// absent entirely when the author changed no keys, which is the common case.
///
/// **One block per folder when one download went into several.** Kept per mod
/// rather than summarised: the keybind diff is the only place an accepted loss
/// becomes visible, and a group write is not all-or-nothing, so which folder a
/// fact belongs to is part of the fact.
Future<void> showUpdateResultDialog(
  BuildContext context, {
  required ModInfo mod,
  required GbFile file,
  required UpdateApplyResult result,
  bool reinstall = false,
  List<AppliedUpdate> others = const <AppliedUpdate>[],
}) =>
    showDialog<void>(
      context: context,
      builder: (_) => _UpdateResultDialog(
        mod: mod,
        file: file,
        result: result,
        reinstall: reinstall,
        others: others,
      ),
    );

class _UpdateResultDialog extends StatelessWidget {
  const _UpdateResultDialog({
    required this.mod,
    required this.file,
    required this.result,
    this.reinstall = false,
    this.others = const <AppliedUpdate>[],
  });

  final ModInfo mod;
  final GbFile file;
  final UpdateApplyResult result;

  /// The other folders this one download was written into.
  final List<AppliedUpdate> others;

  /// The version already installed, written again — so the headline says the
  /// mod was repaired rather than updated. Everything below it is the same
  /// report either way.
  final bool reinstall;

  List<AppliedUpdate> get _all =>
      [AppliedUpdate(mod: mod, result: result), ...others];

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final scheme = Theme.of(context).colorScheme;
    final all = _all;
    // **Only ever false for a group.** A single failure goes out as a
    // notification and never reaches this dialog, so the one place the icon can
    // be wrong is the case it was hard-coded for: every folder failing, under a
    // primary-coloured tick. `_modBlock` is careful not to print "0 files
    // written" beside a failure; a tick over "0 mods updated" undoes that.
    final anySuccess = all.any((entry) => entry.result.success);

    return AlertDialog(
      title: Row(
        children: [
          Icon(
            anySuccess ? Icons.check_circle_outline : Icons.error_outline,
            color: anySuccess ? scheme.primary : scheme.error,
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(_title(loc, all))),
        ],
      ),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final entry in all) ...[
                // Named only when there is more than one, so a single update
                // reads as one report rather than a list of one.
                if (all.length > 1) _modHeading(context, entry),
                ..._modBlock(context, loc, entry.result),
                if (entry != all.last) const SizedBox(height: 18),
              ],
              const SizedBox(height: 18),
              DialogNotice(
                icon: Icons.history,
                message: loc.t('mods.update_apply.rollback_hint'),
              ),
            ],
          ),
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(loc.t('mods.update.close')),
        ),
      ],
    );
  }

  /// One mod's name, or how many folders were written.
  String _title(AppLocalizations loc, List<AppliedUpdate> all) {
    if (all.length == 1) {
      return loc.t(
        reinstall
            ? 'mods.reinstall.done_title'
            : 'mods.update_apply.done_title',
        params: {'mod': mod.name},
      );
    }
    final wrote = all.where((e) => e.result.success).length;
    // Its own sentence rather than the plural of "{count} mods updated" at
    // zero, which reads as a successful count of nothing.
    if (wrote == 0) return loc.t('mods.update_apply.group_done_none_title');
    return loc.plural(
      'mods.update_apply.group_done_title',
      wrote,
      params: {'count': '$wrote'},
    );
  }

  Widget _modHeading(BuildContext context, AppliedUpdate entry) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Icon(
            entry.result.success ? Icons.folder_outlined : Icons.error_outline,
            size: 18,
            color: entry.result.success ? scheme.onSurfaceVariant : scheme.error,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              entry.mod.name,
              style: Theme.of(context)
                  .textTheme
                  .bodyLarge
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  /// What happened to one folder.
  ///
  /// A folder that failed reports the reason and nothing else: every fact below
  /// describes a write that landed, and printing "0 files written" beside a
  /// failure invites reading it as a successful no-op.
  List<Widget> _modBlock(
    BuildContext context,
    AppLocalizations loc,
    UpdateApplyResult result,
  ) {
    if (!result.success) {
      return [
        DialogSection(
          title: loc.t('mods.update_apply.group_done_failed_heading'),
          children: [
            DialogNotice(
              icon: Icons.error_outline,
              emphasis: true,
              message: loc.t(switch (result.failure) {
                UpdateApplyFailure.snapshot =>
                  'mods.update_apply.snapshot_failed_title',
                UpdateApplyFailure.modMissing =>
                  'mods.update_apply.mod_missing_title',
                UpdateApplyFailure.copy => 'mods.update_apply.copy_failed_title',
                _ => 'mods.update_apply.layout_failed_title',
              }),
            ),
          ],
        ),
      ];
    }
    return [
              DialogSection(
                title: loc.t('mods.update_apply.done_what_heading'),
                children: [
                  DialogFact(
                    icon: Icons.arrow_circle_up,
                    label: loc.t('mods.update_apply.done_installed'),
                    value: fileDisplayName(file),
                  ),
                  DialogFact(
                    icon: Icons.description_outlined,
                    label: loc.t('mods.update_apply.done_written'),
                    value: loc.t(
                      'mods.update_apply.done_written_value',
                      params: {'count': '${result.filesWritten}'},
                    ),
                  ),
                  if (result.removedInis.isNotEmpty)
                    DialogFact(
                      icon: Icons.delete_outline,
                      label: loc.t('mods.update_apply.done_removed_label'),
                      value: result.removedInis.join(', '),
                    ),
                  // Its own row rather than folded into the one above: those
                  // were `.ini` files the user ticked a box for, and these are
                  // the ones the record settled without asking.
                  if (result.droppedFiles.isNotEmpty)
                    DialogFact(
                      icon: Icons.auto_delete_outlined,
                      label: loc.t('mods.update_apply.done_dropped_label'),
                      value: loc.plural(
                        'mods.update_apply.done_dropped',
                        result.droppedFiles.length,
                        params: {'count': '${result.droppedFiles.length}'},
                      ),
                    ),
                  // Only a patch update ever has these: the mod's own files,
                  // back at paths the patch has stopped writing over.
                  if (result.restoredFiles.isNotEmpty)
                    DialogFact(
                      icon: Icons.undo,
                      label: loc.t('mods.update_apply.done_restored_label'),
                      value: loc.plural(
                        'mods.update_apply.done_restored',
                        result.restoredFiles.length,
                        params: {'count': '${result.restoredFiles.length}'},
                      ),
                    ),
                  if (result.reactivated)
                    DialogFact(
                      icon: Icons.toggle_on_outlined,
                      label: loc.t('mods.update_apply.done_state_label'),
                      value: loc.t('mods.update_apply.done_reactivated'),
                    ),
                ],
              ),
      if (result.keybindChanges.isNotEmpty)
        ..._keybinds(context, loc, result),
    ];
  }

  /// The accepted loss, named.
  ///
  /// A reset keybind is otherwise self-announcing in the worst way — the user
  /// finds out by pressing the old key in-game and having nothing happen. The
  /// heading says what happened, the sentence under it says why nothing was put
  /// back and where to change it, and each row is a before → after so it can be
  /// read without remembering anything.
  List<Widget> _keybinds(
    BuildContext context,
    AppLocalizations loc,
    UpdateApplyResult result,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final count = result.keybindChanges.length;
    return [
      const SizedBox(height: 18),
      DialogSection(
        title: loc.plural(
          'mods.update_apply.keybinds_heading',
          count,
          params: {'count': '$count'},
        ),
        subtitle: loc.t('mods.update_apply.keybinds_explainer'),
        children: [
          // Bounded and scrolling inside itself, like every other list in these
          // dialogs: a mod with a dozen cycle keys must not push the one button
          // off the screen.
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 180),
            child: ListView(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              children: [
                for (final change in result.keybindChanges)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    // A Wrap, not a Row. A binding can be `ctrl alt shift F9`
                    // and none of these four parts can ellipsise, so a Row
                    // that does not fit degrades into a red stripe rather than
                    // into anything — which a test caught at 480px before a
                    // user could.
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 2,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          change.displayName,
                          style: Theme.of(context).textTheme.bodyLarge,
                        ),
                        Text(
                          change.before,
                          style: Theme.of(context)
                              .textTheme
                              .bodyLarge
                              ?.copyWith(
                                decoration: TextDecoration.lineThrough,
                                color: scheme.onSurfaceVariant,
                              ),
                        ),
                        Icon(
                          Icons.arrow_forward,
                          size: 16,
                          color: scheme.onSurfaceVariant,
                        ),
                        Text(
                          change.after ??
                              loc.t('mods.update_apply.keybind_gone'),
                          style: Theme.of(context)
                              .textTheme
                              .bodyLarge
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    ];
  }
}
