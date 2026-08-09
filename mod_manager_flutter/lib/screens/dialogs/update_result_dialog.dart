import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../models/character_info.dart';
import '../../models/gamebanana/gamebanana.dart';
import '../../services/gamebanana/file_selection.dart';
import '../../services/update_apply/update_applier.dart';
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
Future<void> showUpdateResultDialog(
  BuildContext context, {
  required ModInfo mod,
  required GbFile file,
  required UpdateApplyResult result,
}) =>
    showDialog<void>(
      context: context,
      builder: (_) => _UpdateResultDialog(mod: mod, file: file, result: result),
    );

class _UpdateResultDialog extends StatelessWidget {
  const _UpdateResultDialog({
    required this.mod,
    required this.file,
    required this.result,
  });

  final ModInfo mod;
  final GbFile file;
  final UpdateApplyResult result;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final scheme = Theme.of(context).colorScheme;

    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.check_circle_outline, color: scheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              loc.t('mods.update_apply.done_title', params: {'mod': mod.name}),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
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
                  if (result.reactivated)
                    DialogFact(
                      icon: Icons.toggle_on_outlined,
                      label: loc.t('mods.update_apply.done_state_label'),
                      value: loc.t('mods.update_apply.done_reactivated'),
                    ),
                ],
              ),
              if (result.keybindChanges.isNotEmpty) ..._keybinds(context, loc),
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

  /// The accepted loss, named.
  ///
  /// A reset keybind is otherwise self-announcing in the worst way — the user
  /// finds out by pressing the old key in-game and having nothing happen. The
  /// heading says what happened, the sentence under it says why nothing was put
  /// back and where to change it, and each row is a before → after so it can be
  /// read without remembering anything.
  List<Widget> _keybinds(BuildContext context, AppLocalizations loc) {
    final scheme = Theme.of(context).colorScheme;
    final count = result.keybindChanges.length;
    return [
      const SizedBox(height: 18),
      DialogSection(
        title: loc.t(
          count == 1
              ? 'mods.update_apply.keybinds_heading_single'
              : 'mods.update_apply.keybinds_heading_plural',
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
