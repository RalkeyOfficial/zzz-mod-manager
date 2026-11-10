import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../utils/state_providers.dart';
import '../dialogs/update_modal.dart';
import 'library_actions_host.dart';

/// "Update 3", beside Check all for updates on All mods and on the Updates page: opens [UpdateModal] with every mod
/// that has a newer file to install, and hands what the user picked to the host's run.
///
/// Absent while no mod has a file to install, which is not the sidebar's count: a verdict with no file to name is an
/// update to know about and nothing to install ([updatableModsProvider]). Pressed while a check runs, it works from the
/// verdicts in hand; a folder written since the check started keeps the verdict the write left. Disabled while a run of
/// updates is under way, since two runs would write the same folders at once.
class UpdateCountButton extends ConsumerWidget {
  const UpdateCountButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(updatableModsCountProvider);
    if (count == 0) return const SizedBox.shrink();
    final loc = context.loc;
    final running = ref.watch(libraryUpdateRunProvider);
    final button = FilledButton.icon(
      onPressed: running ? null : () => unawaited(_open(context)),
      icon: const Icon(Icons.arrow_circle_up_outlined),
      label: Text(loc.t('library.all.update_n', params: {'count': '$count'})),
    );
    return running ? Tooltip(message: loc.t('library.all.update_n_running'), child: button) : button;
  }

  Future<void> _open(BuildContext context) async {
    final actions = LibraryActionsHost.of(context);
    final picks = await showUpdateModal(context);
    if (picks == null || picks.isEmpty) return;
    await actions.updateMods(picks);
  }
}
