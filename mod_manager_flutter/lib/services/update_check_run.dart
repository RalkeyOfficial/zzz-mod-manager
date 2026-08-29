/// Running the whole-library check, and folding its answers into what is
/// already known.
///
/// Two surfaces start this pass — the Mods toolbar's *Check for updates*, and
/// the opt-in check that runs by itself at startup — and they must not be two
/// implementations. What they share is not just the call: it is the cache
/// decision below and the merge rule, both of which are wrong in a way nobody
/// would notice if one copy drifted.
///
/// Deliberately Flutter-free. The providers the results land in are read and
/// written by the callers; the rules for *what* to write are here.
library;

import '../models/gamebanana/gamebanana.dart';
import 'bulk_update_check.dart';
import 'gamebanana/gamebanana_client.dart';
import 'update_check.dart';

/// Issues the requests for [plan].
///
/// [fetch] and [fetchUpdates] exist for tests, which must not reach the live
/// API. In production both are built from [client].
///
/// **Both bypass the client's response cache**, for the reason the
/// marketplace's refresh button does: a "check for updates" answerable from a
/// ten-minute-old copy is a control that sometimes cannot check for updates,
/// with no way for the user to tell which press was which. That holds for the
/// launch check too — on a cold start there is nothing cached to bypass, and on
/// a warm one the answer should still be current.
Future<BulkUpdateCheckOutcome> runLibraryUpdateCheck({
  required BulkUpdateCheckPlan plan,
  required GameBananaClient client,
  ModRecordFetcher? fetch,
  ModUpdatesFetcher? fetchUpdates,
}) {
  return runBulkUpdateCheck(
    plan: plan,
    fetch: fetch ??
        (ids) => client.modsMulti(
              ids,
              properties: updateCheckProperties,
              refresh: true,
            ),
    fetchUpdates:
        fetchUpdates ?? (modId) => client.modUpdates(modId, refresh: true),
  );
}

/// The verdicts after a pass, **merged into what was already known**.
///
/// Merged rather than replaced: a per-mod check the user ran on a mod this pass
/// could not reach is still the best answer available for it, and a pass that
/// aborted early would otherwise wipe every verdict on screen.
Map<String, UpdateCheck> mergedChecks(
  Map<String, UpdateCheck> existing,
  BulkUpdateCheckOutcome outcome,
) =>
    {...existing, ...outcome.checks};

/// The fetched mod pages, merged on the same rule and for a second reason: they
/// are what lets the bulk resolution screen be re-opened without spending
/// another request.
Map<int, GbMod> mergedRecords(
  Map<int, GbMod> existing,
  BulkUpdateCheckOutcome outcome,
) =>
    {...existing, ...outcome.records};
