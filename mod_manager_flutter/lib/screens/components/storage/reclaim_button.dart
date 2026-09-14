import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../../services/log/confirmations.dart';
import '../../../services/storage/reclaim_plan.dart';
import '../../../services/storage/reclaim_service.dart';
import '../../../services/storage/storage_providers.dart';
import '../../../utils/byte_format.dart';
import '../../../utils/notifications.dart';

/// Runs the sweep. Production passes nothing; a widget test passes a closure,
/// so the button can be pressed without a temp directory and without any risk
/// of reaching the developer's own app data.
typedef ReclaimRunner = Future<ReclaimOutcome?> Function();

/// **Free up space**, with the confirmation in front of it.
///
/// Deletion is normally silent in this app — the user confirmed it and can see
/// the result. This one speaks because there is nothing to see: the effect is
/// invisible and the figure *is* the message.
class ReclaimButton extends ConsumerStatefulWidget {
  const ReclaimButton({super.key, this.runner});

  final ReclaimRunner? runner;

  @override
  ConsumerState<ReclaimButton> createState() => _ReclaimButtonState();
}

class _ReclaimButtonState extends ConsumerState<ReclaimButton> {
  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final running = ref.watch(reclaimControllerProvider).isLoading;

    return FilledButton.icon(
      onPressed: running ? null : _press,
      icon: running
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.cleaning_services_rounded, size: 18),
      label: Text(
        running ? loc.t('storage.reclaim.working') : loc.t('storage.reclaim.action'),
      ),
    );
  }

  Future<void> _press() async {
    // Captured before the await: this widget's context dies with the tab.
    final loc = context.loc;
    final notify = context.notify;

    final confirmed = await _confirm(context);
    logConfirmation('storage.reclaim',
        accepted: confirmed, subject: 'reclaimable data');
    if (!confirmed) return;

    final outcome = widget.runner != null
        ? await widget.runner!()
        : await _runThroughController();
    if (outcome == null) return;

    // One card, not two. What was refused belongs in the same breath as what
    // was freed — a sweep that quietly did less than it offered is worse than
    // one that did nothing, and a second notification reads as a second event.
    final refusals = _refusals(loc, outcome);

    if (outcome.isEmpty) {
      notify.info(
        loc.t('storage.reclaim.nothing_title'),
        body: [loc.t('storage.reclaim.nothing_body'), ...refusals].join('\n'),
      );
      return;
    }

    notify.success(
      loc.t('storage.reclaim.done_title', params: {
        // What the volume actually gave back where that could be measured: on a
        // compressed or copy-on-write filesystem the sum of file lengths is not
        // what comes free, so the honest number is the one the OS reports and
        // the apparent sum is the fallback.
        'size': formatBytes(outcome.freeSpaceDelta ?? outcome.freedBytes),
      }),
      body: [
        loc.t('storage.reclaim.done_body',
            params: {'count': '${outcome.removedCount}'}),
        ...refusals,
      ].join('\n'),
    );
  }

  static List<String> _refusals(AppLocalizations loc, ReclaimOutcome outcome) {
    final seen = <ReclaimSkipReason>{};
    final lines = <String>[];
    for (final refused in outcome.refused) {
      if (!seen.add(refused.refusal!)) continue;
      final key = switch (refused.refusal!) {
        ReclaimSkipReason.downloadsActive => 'storage.reclaim.skipped_downloads',
        ReclaimSkipReason.installInProgress => 'storage.reclaim.skipped_install',
        ReclaimSkipReason.libraryUnreadable => 'storage.reclaim.skipped_library',
        _ => null,
      };
      if (key != null) lines.add(loc.t(key));
    }
    return lines;
  }

  Future<ReclaimOutcome?> _runThroughController() async {
    await ref.read(reclaimControllerProvider.notifier).run();
    return ref.read(reclaimControllerProvider).valueOrNull;
  }

  static Future<bool> _confirm(BuildContext context) async {
    final loc = context.loc;
    final answer = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.warning_amber_rounded,
                size: 24, color: Colors.red),
            const SizedBox(width: 12),
            Expanded(child: Text(loc.t('storage.reclaim.title'))),
          ],
        ),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(loc.t('storage.reclaim.body')),
              const SizedBox(height: 12),
              // The reassurance is the load-bearing half. Everything this
              // deletes can be got again; what the user is afraid of losing is
              // the two things it cannot touch, so they are named.
              Text(
                loc.t('storage.reclaim.safe'),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(loc.t('storage.reclaim.cancel')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(loc.t('storage.reclaim.confirm')),
          ),
        ],
      ),
    );
    return answer ?? false;
  }
}
