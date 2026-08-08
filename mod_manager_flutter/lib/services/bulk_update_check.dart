/// Checking a whole library for updates in a couple of requests.
///
/// The decision about *whether one mod has an update* is `update_check.dart`
/// and is pure. This file is the pass around it: which mods are worth asking
/// about, how to batch the asking, and — the part that is easy to get wrong —
/// how to recover when the batch endpoint refuses the whole request because of
/// one bad id.
///
/// The remote call is injected as [ModRecordFetcher], so the whole pass is
/// testable with no network.
library;

import '../models/character_info.dart';
import '../models/gamebanana/gb_exceptions.dart';
import '../models/gamebanana/gb_mod.dart';
import '../models/gamebanana/gb_update.dart';
import 'update_check.dart';

/// Fetches the records for a batch of mod ids. Throws like the client does.
typedef ModRecordFetcher = Future<List<GbMod>> Function(List<int> modIds);

/// Fetches one mod's release feed. Throws like the client does.
typedef ModUpdatesFetcher = Future<List<GbUpdate>> Function(int modId);

/// The fields `Mod/Multi` is asked for.
///
/// Deliberately minimal — every extra property is bytes multiplied by the batch
/// size. Note what is **absent and cannot be added**: `_aArchivedFiles` is
/// rejected by this endpoint as an unknown property. It costs nothing, because
/// `Mod/Multi` folds archived files into `_aFiles` and flags them with
/// `_bIsArchived` (see `GbMod.currentFiles`).
const List<String> updateCheckProperties = <String>[
  '_idRow',
  '_sName',
  '_sVersion',
  '_tsDateAdded',
  '_tsDateUpdated',
  '_bIsObsolete',
  '_bIsPrivate',
  '_bIsTrashed',
  '_bIsWithheld',
  '_aFiles',
];

/// What a whole-library check concluded.
class BulkUpdateCheckOutcome {
  const BulkUpdateCheckOutcome({
    required this.checks,
    required this.failed,
    required this.requests,
    this.abortedBy,
  });

  /// Mod folder id -> verdict, for every mod that got one.
  final Map<String, UpdateCheck> checks;

  /// Mod folder ids whose remote lookup failed for a reason that is **not** an
  /// answer — connectivity, a timeout, throttling. Distinct from
  /// [UpdateOutcome.sourceGone], which is a fact about the mod page.
  final Set<String> failed;

  /// How many requests the pass actually issued.
  ///
  /// Counted because the bisect below and the per-mod release feeds can both
  /// multiply it, and a number that is never counted is one nobody notices
  /// growing. Nothing renders it today — it is asserted in tests and is what a
  /// measurement quotes; if it ever needs watching in the field, the snackbar
  /// is where it would go.
  final int requests;

  /// Set when the pass gave up early — a url-level error, or a network failure
  /// that would repeat for every remaining batch.
  final Object? abortedBy;

  int get updatesFound =>
      checks.values.where((check) => check.hasUpdate).length;
}

/// The mods a check would actually ask the network about, and the answers the
/// rest already have.
///
/// Pure, and split out so the button above it can show a count without running
/// anything.
class BulkUpdateCheckPlan {
  const BulkUpdateCheckPlan({
    required this.byModId,
    required this.skipped,
  });

  /// Remote mod id -> the local folders bound to it.
  ///
  /// A list rather than a single mod because **one mod page is routinely
  /// several folders** — two variants of one mod installed side by side, two
  /// occurrences in a real 23-mod library. They share one remote record and
  /// each gets its own verdict, since each has its own `file_id`.
  final Map<int, List<ModInfo>> byModId;

  /// Verdicts that need no network at all: untracked mods and ones the user
  /// declared their own. Included rather than dropped so the caller can render
  /// a complete picture without a second rule for "mods we didn't ask about".
  final Map<String, UpdateCheck> skipped;

  List<int> get modIds => byModId.keys.toList();

  /// How many mods a run would look up. What the toolbar button counts.
  int get checkableCount =>
      byModId.values.fold(0, (sum, mods) => sum + mods.length);

  bool get hasWork => byModId.isNotEmpty;
}

BulkUpdateCheckPlan planBulkUpdateCheck(List<ModInfo> mods) {
  final byModId = <int, List<ModInfo>>{};
  final skipped = <String, UpdateCheck>{};

  for (final mod in mods) {
    // The same rule `checkForUpdate` opens with, shared rather than restated:
    // if the two lists ever disagreed, a mod would be requested and then given
    // an answer that ignored the response.
    if (verdictWithoutAsking(mod.origin) case final settled?) {
      skipped[mod.id] = settled;
      continue;
    }
    byModId.putIfAbsent(mod.origin!.modId!, () => <ModInfo>[]).add(mod);
  }

  return BulkUpdateCheckPlan(byModId: byModId, skipped: skipped);
}

/// Runs the plan: batch, fetch, fold.
///
/// [batchSize] is our own cap rather than the server's — 60 ids in one url were
/// verified to work, and 50 leaves room while matching the page size the rest
/// of the API is limited to.
/// [fetchUpdates] is the **second phase**, and it is deliberately optional and
/// deliberately narrow. `Mod/<id>/Updates` is one request *per mod*, so running
/// it across a library would undo everything `Mod/Multi` buys — but it only ever
/// tells us that a flag is wrong, so it is worth running for exactly the mods
/// that flagged. Note that is the count *before* the refinement, not after: on
/// a real 17-mod library four mods flagged in phase one and two survived, so it
/// costs four extra requests rather than seventeen. Omit it and the verdicts
/// stand unrefined.
Future<BulkUpdateCheckOutcome> runBulkUpdateCheck({
  required BulkUpdateCheckPlan plan,
  required ModRecordFetcher fetch,
  ModUpdatesFetcher? fetchUpdates,
  int batchSize = 50,
}) async {
  final checks = <String, UpdateCheck>{...plan.skipped};
  // Kept so phase two can re-fold a verdict without re-fetching the mod.
  final records = <int, GbMod>{};
  final failed = <String>{};
  final ids = plan.modIds;
  var requests = 0;
  Object? aborted;

  void recordAll(List<ModInfo> mods, UpdateCheck check) {
    for (final mod in mods) {
      checks[mod.id] = check;
    }
  }

  /// Fetches [batch] and folds it in, halving on a per-id input error.
  ///
  /// Returns false to stop the whole pass.
  Future<bool> resolve(List<int> batch) async {
    if (batch.isEmpty) return true;
    final List<GbMod> fetched;
    try {
      requests++;
      fetched = await fetch(batch);
    } on GbApiException catch (error) {
      // **The only error worth splitting on.** `Mod/Multi` is all-or-nothing:
      // one id it doesn't recognise fails the request for the other forty-nine,
      // and it names only the first offender — so there is nothing to skip and
      // retry, only a range to narrow. Halving costs ~2·log2(n) requests per
      // bad id, which is the price of not reporting a whole library as
      // unreachable because one `source_url` was a wrong paste.
      //
      // The guard is what keeps that bounded: if the offending field is *not*
      // `_csvRowIds`, our url is wrong rather than an id, and every split would
      // fail identically — a hundred requests to learn what the first one said.
      if (!error.fieldErrors.containsKey('_csvRowIds')) {
        aborted = error;
        return false;
      }
      if (batch.length == 1) {
        // Narrowed to one, and the server says it doesn't exist. That *is* the
        // answer: the mod page is gone. Not a failure to report.
        recordAll(
          plan.byModId[batch.single] ?? const <ModInfo>[],
          const UpdateCheck(outcome: UpdateOutcome.sourceGone),
        );
        return true;
      }
      final mid = batch.length ~/ 2;
      return await resolve(batch.sublist(0, mid)) &&
          await resolve(batch.sublist(mid));
    } catch (error) {
      // Connectivity, a timeout, exhausted backoff. Deliberately **not** split:
      // an outage would repeat for every half, and the answer would still be
      // "we could not look". The remaining batches are abandoned for the same
      // reason.
      for (final id in batch) {
        for (final mod in plan.byModId[id] ?? const <ModInfo>[]) {
          failed.add(mod.id);
        }
      }
      aborted = error;
      return false;
    }

    final seen = <int>{};
    for (final record in fetched) {
      seen.add(record.idRow);
      records[record.idRow] = record;
      for (final mod in plan.byModId[record.idRow] ?? const <ModInfo>[]) {
        checks[mod.id] = checkForUpdate(origin: mod.origin, remote: record);
      }
    }
    // An id we asked for that came back in nothing. The endpoint errors on an
    // unknown id rather than omitting it, so this should not happen — but
    // "should not" is how a mod silently keeps its old verdict, and a mod page
    // that has been hidden rather than deleted is the plausible way in.
    for (final id in batch) {
      if (seen.contains(id)) continue;
      recordAll(
        plan.byModId[id] ?? const <ModInfo>[],
        const UpdateCheck(outcome: UpdateOutcome.sourceGone),
      );
    }
    return true;
  }

  for (var start = 0; start < ids.length; start += batchSize) {
    final end = start + batchSize < ids.length ? start + batchSize : ids.length;
    if (!await resolve(ids.sublist(start, end))) break;
  }

  // ---- phase two: ask the author which files shipped together --------------
  //
  // Only for mods that flagged, and only for the ones we have a remote record
  // for. A release group can turn a flag *off* and can never turn one on, so a
  // failure here is not an error state: the verdict simply stays as phase one
  // left it, which is the direction that errs toward telling the user.
  if (fetchUpdates != null) {
    for (final entry in plan.byModId.entries) {
      final flagged = [
        for (final mod in entry.value)
          if (checks[mod.id]?.hasUpdate ?? false) mod,
      ];
      if (flagged.isEmpty) continue;
      final record = records[entry.key];
      if (record == null) continue;
      final ReleaseGroups groups;
      try {
        requests++;
        groups = ReleaseGroups.fromUpdates(await fetchUpdates(entry.key));
      } catch (_) {
        // Not recorded as a failure: phase one answered this mod, and that
        // answer is still the honest one.
        continue;
      }
      if (groups.isEmpty) continue;
      for (final mod in flagged) {
        checks[mod.id] = checkForUpdate(
          origin: mod.origin,
          remote: record,
          releases: groups,
        );
      }
    }
  }

  // Everything the pass never got to. A run that stopped at batch two leaves
  // the rest unanswered, and "no entry" is indistinguishable from "not in the
  // library" to the caller — so say so explicitly rather than letting the
  // summary quietly describe a third of the work as if it were all of it.
  if (aborted != null) {
    for (final mods in plan.byModId.values) {
      for (final mod in mods) {
        if (!checks.containsKey(mod.id)) failed.add(mod.id);
      }
    }
  }

  return BulkUpdateCheckOutcome(
    checks: checks,
    failed: failed,
    requests: requests,
    abortedBy: aborted,
  );
}
