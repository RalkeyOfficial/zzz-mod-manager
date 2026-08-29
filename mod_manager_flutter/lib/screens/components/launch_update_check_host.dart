import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/bulk_update_check.dart';
import '../../services/launch_update_check.dart';
import '../../services/update_check_run.dart';
import '../../utils/state_providers.dart';
import 'update_check_feedback.dart';

/// Runs the whole-library update check once at startup, when the user has asked
/// for it.
///
/// **It checks; it never updates anything.** Applying an update overwrites a
/// live install, and in a scene with no standard the person who has to
/// understand and repair a bad one has to be at the keyboard when it happens.
/// So the automatic half stops at drawing badges — see
/// `docs/applying-updates.md` §7.
///
/// **Where it is mounted is part of the design.** The check is started by
/// nobody and outlives whatever the user does next, so it cannot be owned by a
/// tab: the three tabs are keyed `AnimatedSwitcher` children with no
/// keep-alive, so `ModsToolbar` — which owns the *manual* check — is disposed
/// the moment the user looks at the marketplace, taking a pass in flight with
/// it. This wraps the switcher instead, like `DownloadQueueHost`. Unlike that
/// host it raises no dialog, so it does not need to sit below the `Navigator`.
///
/// **It never opens the bulk resolution screen.** The manual check does, when
/// the pass turned up mods whose tracking could be sorted out — but that screen
/// is a modal, and one thrown over an app the user has just opened is the
/// interruption the whole notification-or-screen arrangement exists to avoid.
/// It stays reachable from *Sort out mod tracking…* in the library menu, which
/// rebuilds itself from the records this pass leaves behind and therefore costs
/// no second request.
///
/// **It waits for the library rather than for a timer.** The plan is derived
/// from the scan `ModsScreen` runs on the way in, so it is empty until that
/// lands and empty forever for a library with no tracked mods — which is why
/// there is no "has the scan finished" condition here. The first plan with
/// anything checkable in it is the signal — and it is also where the startup
/// moment *ends*, including when the setting was off, so that switching it on
/// mid-session takes effect at the next start rather than at the next rescan.
class LaunchUpdateCheckHost extends ConsumerStatefulWidget {
  const LaunchUpdateCheckHost({
    super.key,
    required this.child,
    this.updateFetcher,
    this.updatesFetcher,
  });

  final Widget child;

  /// Injected only by tests. Defaults to the shared GameBanana client, which a
  /// widget test must not be allowed to reach — the same seam `ModsToolbar`
  /// carries for the manual check.
  final ModRecordFetcher? updateFetcher;

  /// Injected only by tests, for the same reason: the second phase, asking each
  /// flagged mod's release feed which files shipped together.
  final ModUpdatesFetcher? updatesFetcher;

  @override
  ConsumerState<LaunchUpdateCheckHost> createState() =>
      _LaunchUpdateCheckHostState();
}

class _LaunchUpdateCheckHostState extends ConsumerState<LaunchUpdateCheckHost> {
  /// Whether the startup moment has passed.
  ///
  /// Set **before** the first await rather than after the pass returns: the
  /// library is rescanned on a favourite, an import, a rename and a resolve,
  /// and each rescan rebuilds the plan and fires the listener below. Setting it
  /// afterwards would let an ordinary afternoon issue the batch a dozen times,
  /// and would let two passes overlap and race their results into one map.
  ///
  /// It is set even when the check was **switched off**, which is
  /// [LaunchCheckAction.close] — see there for why the moment has to end either
  /// way.
  bool _windowClosed = false;

  @override
  void initState() {
    super.initState();
    // Whatever the plan already holds, rather than only the next change to it.
    // A hot reload rebuilds this host under a library that was scanned long
    // ago, and reacting only to changes would mean the check never runs.
    //
    // **After the frame, not during it.** The pass writes to providers, and
    // Riverpod refuses that while the tree is building.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_maybeRun(ref.read(bulkUpdateCheckPlanProvider)));
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<BulkUpdateCheckPlan>(
      bulkUpdateCheckPlanProvider,
      (_, plan) => unawaited(_maybeRun(plan)),
    );
    return widget.child;
  }

  Future<void> _maybeRun(BulkUpdateCheckPlan plan) async {
    final action = launchCheckAction(
      enabled: ref.read(updateCheckOnLaunchProvider),
      windowClosed: _windowClosed,
      plan: plan,
    );
    if (action == LaunchCheckAction.wait) return;
    _windowClosed = true;
    if (action == LaunchCheckAction.close) return;

    final BulkUpdateCheckOutcome outcome;
    try {
      outcome = await runLibraryUpdateCheck(
        plan: plan,
        client: ref.read(gameBananaClientProvider),
        fetch: widget.updateFetcher,
        fetchUpdates: widget.updatesFetcher,
      );
    } catch (e) {
      // Silent, and deliberately. Nobody asked for this pass, so a failure is
      // not something the user has to act on — and the commonest cause by far
      // is starting the app offline. A card saying "couldn't check for updates"
      // on every offline launch is what gets the setting switched off. The
      // toolbar's check is the one that reports, and it is one click away.
      debugPrint('LaunchUpdateCheckHost: startup check failed: $e');
      return;
    }

    if (!mounted) return;
    final checks = ref.read(modUpdateChecksProvider.notifier);
    checks.state = mergedChecks(checks.state, outcome);
    final records = ref.read(modUpdateRecordsProvider.notifier);
    records.state = mergedRecords(records.state, outcome);

    // Only when it found something. The badges carry the answer either way, and
    // this pass has no press behind it to justify a card that says "nothing".
    final found = launchCheckFindings(outcome);
    if (found == null || !mounted) return;
    showLaunchUpdateCheckOutcome(context, outcome, found);
  }
}
