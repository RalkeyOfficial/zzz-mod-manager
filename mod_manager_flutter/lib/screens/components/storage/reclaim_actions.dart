import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/button_working.dart';
import '../../../core/palette.dart';
import '../../../l10n/app_localizations.dart';
import '../../../services/log/confirmations.dart';
import '../../../services/storage/reclaim_plan.dart';
import '../../../services/storage/reclaim_service.dart';
import '../../../services/storage/storage_providers.dart';
import '../../../utils/byte_format.dart';
import '../../../utils/notifications.dart';

/// Runs a reclaim over [targets]. Production goes through [reclaimControllerProvider]; a widget test passes a closure,
/// so a press needs no temp directory and cannot reach the developer's own app data.
typedef ReclaimRunner = Future<ReclaimOutcome?> Function(Set<ReclaimTarget> targets);

/// What a category's button does: the stores it may take from, and the words of its confirmation.
///
/// Covers & metadata has none, and the sidecars are not a [ReclaimTarget] at all: a sidecar holds a mod's origin tracking and the user's own covers, which cannot be fetched again (`docs/disk-usage.md` §8).
enum StorageAction {
  cleanUpLeftovers({ReclaimTarget.legacyImages, ReclaimTarget.tempExtracts}),
  clearDownloads({ReclaimTarget.completedArchives, ReclaimTarget.abandonedPartials}),
  clearLogs({ReclaimTarget.oldLogs}),
  clearVersions({ReclaimTarget.unclaimedSnapshots});

  const StorageAction(this.targets);

  final Set<ReclaimTarget> targets;
}

/// Asks, runs and reports one action. Resolves once the report is on screen, or at once when the user declines.
///
/// Everything the end needs is captured before the first await: the press can be the last thing the section's context sees, since a page switch disposes it.
/// [work] wraps the wait in the pressed button's working state.
Future<void> runStorageAction(
  BuildContext context,
  StorageAction action, {
  required WorkSpan work,
  ReclaimRunner? runner,
}) async {
  final loc = context.loc;
  final notify = context.notify;
  final container = ProviderScope.containerOf(context, listen: false);

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => _Confirmation(action: action),
  );
  logConfirmation(
    'storage.reclaim',
    accepted: confirmed ?? false,
    subject: action.name,
    fields: {'targets': action.targets.map((t) => t.name).join(',')},
    dismissed: confirmed == null,
  );
  if (confirmed != true) return;

  final ReclaimOutcome? outcome;
  try {
    outcome = await work(
      () => runner != null
          ? runner(action.targets)
          : container.read(reclaimControllerProvider.notifier).run(action.targets),
    );
  } catch (e) {
    notify.error(loc.t('storage.reclaim.failed_title'), body: e.toString());
    return;
  }
  if (outcome == null) return;
  reportReclaim(loc, notify, outcome);
}

/// One card for the result: what was freed, and what was left alone and why.
/// A sweep that quietly did less than it offered is worse than one that did nothing, and a second card reads as a second event.
void reportReclaim(AppLocalizations loc, NotificationCenter notify, ReclaimOutcome outcome) {
  final refusals = _refusals(loc, outcome);

  if (outcome.isEmpty) {
    notify.note(
      loc.t('storage.reclaim.nothing_title'),
      // A refusal is the reason nothing went, so "nothing to remove" beside it would contradict it.
      body: refusals.isEmpty ? loc.t('storage.reclaim.nothing_body') : refusals.join('\n'),
    );
    return;
  }

  notify.done(
    // What the volume actually gave back where that could be measured: on a compressed or copy-on-write filesystem the sum of file lengths is not what comes free, so the honest figure is the one the OS reports and the apparent sum is the fallback.
    loc.t('storage.reclaim.done_title', params: {'size': formatBytes(outcome.freeSpaceDelta ?? outcome.freedBytes)}),
    body: [
      loc.plural('storage.reclaim.done_body', outcome.removedCount, params: {'count': '${outcome.removedCount}'}),
      ...refusals,
    ].join('\n'),
  );
}

/// One line for each store the button asked about and was refused, worded for that store: a result names only what belongs to the pressed button, since [outcome] holds only its targets.
List<String> _refusals(AppLocalizations loc, ReclaimOutcome outcome) {
  final keys = <String>{};
  for (final refused in outcome.refused) {
    final key = switch ((refused.refusal!, refused.target)) {
      (ReclaimSkipReason.downloadsActive, _) => 'storage.reclaim.skipped_downloads',
      (ReclaimSkipReason.installInProgress, ReclaimTarget.tempExtracts) => 'storage.reclaim.skipped_install',
      (ReclaimSkipReason.installInProgress, _) => 'storage.reclaim.skipped_downloads_install',
      (ReclaimSkipReason.downloadWaiting, _) => 'storage.reclaim.skipped_waiting',
      (ReclaimSkipReason.libraryUnreadable, ReclaimTarget.unclaimedSnapshots) => 'storage.reclaim.skipped_library_versions',
      (ReclaimSkipReason.libraryUnreadable, _) => 'storage.reclaim.skipped_library_images',
      (ReclaimSkipReason.libraryHasDeadLink, ReclaimTarget.unclaimedSnapshots) => 'storage.reclaim.skipped_dead_link_versions',
      (ReclaimSkipReason.libraryHasDeadLink, _) => 'storage.reclaim.skipped_dead_link_images',
      _ => null,
    };
    if (key != null) keys.add(key);
  }
  return [for (final key in keys) loc.t(key)];
}

/// The confirmation: what goes, said before it is asked.
/// No figure is promised, since the space that comes back is only known afterwards.
class _Confirmation extends StatelessWidget {
  const _Confirmation({required this.action});

  final StorageAction action;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final (title, body, note, confirm) = switch (action) {
      StorageAction.cleanUpLeftovers => (
        loc.t('storage.confirm.leftovers_title'),
        loc.t('storage.confirm.leftovers_body'),
        loc.t('storage.confirm.leftovers_note'),
        loc.t('storage.confirm.leftovers_confirm'),
      ),
      StorageAction.clearDownloads => (
        loc.t('storage.confirm.downloads_title'),
        loc.t('storage.confirm.downloads_body'),
        loc.t('storage.confirm.downloads_note'),
        loc.t('storage.confirm.downloads_confirm'),
      ),
      StorageAction.clearLogs => (
        loc.t('storage.confirm.logs_title'),
        loc.t('storage.confirm.logs_body'),
        null,
        loc.t('storage.confirm.logs_confirm'),
      ),
      StorageAction.clearVersions => (
        loc.t('storage.confirm.versions_title'),
        loc.t('storage.confirm.versions_body'),
        loc.t('storage.confirm.versions_note'),
        loc.t('storage.confirm.versions_confirm'),
      ),
    };

    return AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 12,
          children: [
            Text(body, style: text.bodyMedium?.copyWith(color: palette.textProse)),
            if (note != null)
              Text(
                note,
                // Where the deletion cannot be undone, the sentence that says so is the one that must be read.
                style: text.bodyMedium?.copyWith(
                  color: action == StorageAction.clearVersions ? palette.text : palette.textProse,
                  fontWeight: action == StorageAction.clearVersions ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(loc.t('storage.reclaim.cancel'))),
        FilledButton(
          // A transparent overlay, so the theme's press is drawn rather than Material's ink for the foreground.
          style: FilledButton.styleFrom(
            backgroundColor: palette.red,
            foregroundColor: palette.onRed,
            overlayColor: Colors.transparent,
          ),
          onPressed: () => Navigator.pop(context, true),
          child: Text(confirm),
        ),
      ],
    );
  }
}
