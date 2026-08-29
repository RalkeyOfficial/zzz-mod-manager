import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../models/mod_origin.dart';
import '../../services/api_service.dart';
import '../../services/bulk_assume_current.dart';
import '../../utils/notifications.dart';

/// Writes one mod's origin block. Injected only by tests — `ApiService` lazily
/// builds a `ConfigService` against the developer's **real**
/// `<appData>/config.json`, so a widget test that merely pressed the confirm
/// button would rewrite their library paths and favourites.
typedef BulkOriginWriter = Future<bool> Function(
  String modName,
  ModOrigin? Function(ModOrigin? current) update,
);

/// How a bulk run ended.
///
/// Three outcomes, not two, and separating the last two is the point.
/// `updateOrigin` answers a bare `false` for both "the folder is unwritable" and
/// "the transform declined" — but those are opposite facts. A failure is a state
/// worth reporting, since nothing re-attempts an origin write. A **decline** is
/// the guard working: the mod was already resolved by the time its turn came,
/// which is precisely what the re-read exists to notice. Collapsing them would
/// report the guard's own correct behaviour as a filesystem permission error,
/// and the reachable case is mundane — press the button, then press it again
/// before the rescan has refreshed the plan.
class BulkAssumeCurrentOutcome {
  const BulkAssumeCurrentOutcome({
    required this.written,
    required this.skipped,
    required this.failed,
  });

  /// Sidecars actually rewritten.
  final int written;

  /// Mods the transform declined because they no longer needed the action.
  final int skipped;

  /// Mods whose sidecar could not be written.
  final int failed;
}

/// Confirms the bulk "assume current" action and, if the user agrees, applies
/// it. Returns null when they cancelled.
///
/// **The confirmation states the size before acting**, which is the whole reason
/// it exists rather than the button just doing the work: the answer is usually
/// either nothing or most of the library, and a user who presses expecting the
/// first and gets the second has had 47 mods rewritten on a guess. It also names
/// the two groups it is *not* touching, because "12 mods" is a very different
/// offer from "12 of your 47".
Future<BulkAssumeCurrentOutcome?> confirmAndApplyAssumeCurrent(
  BuildContext context,
  BulkAssumeCurrentPlan plan, {
  BulkOriginWriter writer = ApiService.updateModOrigin,
}) async {
  if (!plan.hasWork) return null;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => _AssumeCurrentConfirmation(plan: plan),
  );
  if (confirmed != true) return null;

  var written = 0;
  var skipped = 0;
  var failed = 0;
  for (final mod in plan.eligible) {
    // Sequential on purpose. These are small sidecar rewrites through one
    // service, and the ordering keeps a failure attributable to a mod rather
    // than to the batch.
    //
    // The transform is wrapped rather than passed straight through so its
    // *decline* can be told apart from a failed write — the write path answers
    // one `false` for both. Checking `plan.eligible`'s own blocks instead would
    // not do: the plan is exactly the thing that has gone stale in the case
    // that matters, so it would agree the mod is eligible right up until the
    // fresh read disagrees.
    var declined = false;
    final ok = await writer(mod.id, (current) {
      final next = bulkAssumeCurrent(current);
      if (next == null) declined = true;
      return next;
    });
    if (ok) {
      written++;
    } else if (declined) {
      skipped++;
    } else {
      failed++;
    }
  }
  return BulkAssumeCurrentOutcome(
    written: written,
    skipped: skipped,
    failed: failed,
  );
}

/// Reports the outcome once, in one message.
///
/// A partial run deliberately gets its own wording rather than two stacked
/// notifications: "31 done, 4 couldn't be saved" is one fact about one action,
/// and splitting it makes the failure look like a separate event the user
/// missed.
///
/// A run that only *declined* says so plainly and calmly — it is not a failure
/// and must not be coloured or worded like one.
void showAssumeCurrentOutcome(
  BuildContext context,
  BulkAssumeCurrentOutcome outcome,
) {
  final loc = context.loc;
  String plural(String key, int count) =>
      loc.plural(key, count, params: {'count': '$count'});

  // Each half is pluralised on the count it is actually about: the title on
  // what was written, the body on what failed.
  final (title, body, severity) = switch (outcome) {
    // Nothing was written and nothing broke: every mod had already been sorted
    // out. Almost always a second press before the rescan caught up.
    BulkAssumeCurrentOutcome(written: 0, failed: 0) => (
        loc.t('mods.assume_current.nothing_to_change'),
        plural('mods.assume_current.already_done', outcome.skipped),
        NotificationSeverity.info,
      ),
    BulkAssumeCurrentOutcome(failed: 0) => (
        plural('mods.assume_current.done_partial_title', outcome.written),
        plural('mods.assume_current.done', outcome.written),
        NotificationSeverity.success,
      ),
    BulkAssumeCurrentOutcome(written: 0) => (
        loc.t('mods.assume_current.not_saved_title'),
        plural('mods.assume_current.failed', outcome.failed),
        NotificationSeverity.warning,
      ),
    _ => (
        plural('mods.assume_current.done_partial_title', outcome.written),
        plural('mods.assume_current.done_partial_body', outcome.failed),
        NotificationSeverity.warning,
      ),
  };
  // No portrait: this is about a count across the library, not about one mod.
  context.notify.show(title, body: body, severity: severity);
}

class _AssumeCurrentConfirmation extends StatelessWidget {
  const _AssumeCurrentConfirmation({required this.plan});

  final BulkAssumeCurrentPlan plan;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final muted = TextStyle(
      fontSize: 12,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );

    // A library with one unresolved mod is an ordinary state, not an edge case,
    // and "Mark 1 mods" is not what you want to read immediately before a bulk
    // rewrite. `t` has no plural machinery, so this follows the pattern the
    // import summary already uses: a `_single` / `_plural` key pair.
    String plural(String key, int count) =>
        loc.plural(key, count, params: {'count': '$count'});

    return AlertDialog(
      title: Text(plural('mods.assume_current.title', plan.eligible.length)),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(loc.t('mods.assume_current.body')),
              const SizedBox(height: 10),
              // Said plainly and never buried: the point of this action is that
              // it records a *date* instead of guessing a version, and a user
              // who thinks it filled in version numbers would trust the result
              // far more than it deserves.
              Text(loc.t('mods.assume_current.no_version'), style: muted),
              if (plan.anyBaselineIsProxy) ...[
                const SizedBox(height: 8),
                Text(loc.t('mods.assume_current.proxy_caveat'), style: muted),
              ],
              if (plan.untracked.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  plural('mods.assume_current.excluded_untracked',
                      plan.untracked.length),
                  style: muted,
                ),
              ],
              if (plan.undatable.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  plural('mods.assume_current.excluded_undatable',
                      plan.undatable.length),
                  style: muted,
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(loc.t('mods.assume_current.cancel')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(
            plural('mods.assume_current.confirm', plan.eligible.length),
          ),
        ),
      ],
    );
  }
}
