import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../services/download/download_queue.dart';
import '../dialogs/update_modal.dart';
import 'library_actions_host.dart';

/// "Update 3", beside Check all for updates on All mods and on the Updates page: opens [UpdateModal] with every mod
/// that has a newer file to install, and hands what the user picked to the host, which starts them as a run.
///
/// Absent while no mod has a file to install, which is not the sidebar's count: a verdict with no file to name is an
/// update to know about and nothing to install. Pressed while a check runs, it works from the verdicts in hand; a
/// folder written since the check started keeps the verdict the write left. A run never disables it: it counts the
/// mods not already in the run ([modsToUpdateProvider]), and a press adds those.
class UpdateCountButton extends ConsumerWidget {
  const UpdateCountButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(modsToUpdateCountProvider);
    if (count == 0) return const SizedBox.shrink();
    return FilledButton.icon(
      onPressed: () => unawaited(_open(context)),
      icon: const Icon(Icons.arrow_circle_up_outlined),
      label: Text(context.loc.t('library.all.update_n', params: {'count': '$count'})),
    );
  }

  Future<void> _open(BuildContext context) async {
    final actions = LibraryActionsHost.of(context);
    final picks = await showUpdateModal(context);
    if (picks == null || picks.isEmpty) return;
    actions.updateMods(picks);
  }
}
