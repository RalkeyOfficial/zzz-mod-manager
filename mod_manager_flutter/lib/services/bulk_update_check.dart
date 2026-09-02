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
    this.records = const <int, GbMod>{},
    this.abortedBy,
  });

  /// Mod folder id -> verdict, for every mod that got one.
  final Map<String, UpdateCheck> checks;

  /// Remote mod id -> the record the pass fetched for it.
  ///
  /// Handed back rather than discarded because **the results screen is also the
  /// bulk *resolution* screen**, and every question it asks — which file of this
  /// mod do you have, is this really your mod, is the page gone — is answered by
  /// the same response the verdicts came from. Re-fetching it would spend a
  /// second round of requests to learn what is already in hand, and would let
  /// the two halves of one screen describe different states of the mod page.
  ///
  /// Absent for any id the pass never reached, which is why the screen builds
  /// rows from this map rather than from the plan.
  final Map<int, GbMod> records;

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
    required this.checkable,
    required this.skipped,
  });

  /// Remote mod id -> the local folders that need it answered.
  ///
  /// A list rather than a single mod because **one mod page is routinely
  /// several folders** — two variants of one mod installed side by side, two
  /// occurrences in a real 23-mod library. They share one remote record and
  /// each gets its own verdict, since each has its own `file_id`.
  ///
  /// And **one folder is routinely under several ids**: a mixed folder holds a
  /// patch plus the mod it patches, and both pages have to be asked before
  /// anything can be said about it.
  final Map<int, List<ModInfo>> byModId;

  /// One entry per folder that will get a verdict.
  ///
  /// Separate from [byModId] because the two count different things: that map
  /// is the *requests*, this list is the *answers*. A mixed folder is two
  /// entries there and one here, and conflating them makes the toolbar promise
  /// more work than the user can see.
  final List<ModInfo> checkable;

  /// Verdicts that need no network at all: untracked mods and ones the user
  /// declared their own. Included rather than dropped so the caller can render
  /// a complete picture without a second rule for "mods we didn't ask about".
  final Map<String, UpdateCheck> skipped;

  List<int> get modIds => byModId.keys.toList();

  /// How many **mods** a run would report on. What the toolbar button counts —
  /// the user counts cards, not requests.
  int get checkableCount => checkable.length;

  bool get hasWork => byModId.isNotEmpty;
}

BulkUpdateCheckPlan planBulkUpdateCheck(List<ModInfo> mods) {
  final byModId = <int, List<ModInfo>>{};
  final checkable = <ModInfo>[];
  final skipped = <String, UpdateCheck>{};

  for (final mod in mods) {
    // The same rule `checkForUpdate` opens with, shared rather than restated:
    // if the two lists ever disagreed, a mod would be requested and then given
    // an answer that ignored the response.
    //
    // It settles the **folder**, companions included: "it's my own" is the
    // folder-level switch, and a muted mod must not be able to speak through
    // its second identity.
    if (verdictWithoutAsking(mod.origin) case final settled?) {
      skipped[mod.id] = settled;
      continue;
    }
    final origin = mod.origin!;
    checkable.add(mod);
    // Every layer that names a page. A folder appears under each of them, and a
    // page shared by two folders is fetched once.
    for (final download in origin.trackable) {
      byModId.putIfAbsent(download.modId!, () => <ModInfo>[]).add(mod);
    }
  }

  return BulkUpdateCheckPlan(
    byModId: byModId,
    checkable: checkable,
    skipped: skipped,
  );
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
  // Kept so phase two can re-fold a verdict without re-fetching the mod — and
  // returned, so the results screen can ask its resolution questions against the
  // same response rather than fetching the library a second time.
  final records = <int, GbMod>{};
  final failed = <String>{};
  final ids = plan.modIds;
  var requests = 0;
  Object? aborted;

  /// A page the server says is not there.
  ///
  /// Recorded as a record rather than as an absence so that it reaches the
  /// comparator as the *answer* it is. The distinction matters most for a
  /// companion: "we asked and the mod is gone" and "we never asked" are
  /// different facts, and only the first is `sourceGone`.
  GbMod gone(int id) => GbMod(idRow: id, isTrashed: true);

  void markGone(List<int> batch) {
    for (final id in batch) {
      records[id] = gone(id);
    }
  }

  /// Fetches [batch] and banks it, halving on a per-id input error.
  ///
  /// **Nothing is folded here.** A folder can be under two ids that land in
  /// different batches, and folding on arrival would write one identity's
  /// verdict and then overwrite it with the other's — whichever came last
  /// silently becoming the folder's whole answer. Every record is collected
  /// first and each folder is folded once, below.
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
        markGone(batch);
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
    }
    // An id we asked for that came back in nothing. The endpoint errors on an
    // unknown id rather than omitting it, so this should not happen — but
    // "should not" is how a mod silently keeps its old verdict, and a mod page
    // that has been hidden rather than deleted is the plausible way in.
    markGone([
      for (final id in batch)
        if (!seen.contains(id)) id,
    ]);
    return true;
  }

  for (var start = 0; start < ids.length; start += batchSize) {
    final end = start + batchSize < ids.length ? start + batchSize : ids.length;
    if (!await resolve(ids.sublist(start, end))) break;
  }

  /// One folder's verdict, across every identity it carries.
  ///
  /// [groupsFor] supplies release groups per remote mod id; phase one has none
  /// and phase two has them for exactly the identity that flagged.
  UpdateCheck? foldFor(
    ModInfo mod, {
    Map<int, ReleaseGroups> groupsFor = const <int, ReleaseGroups>{},
  }) {
    final origin = mod.origin!;
    final baseModId = origin.base?.modId;
    if (baseModId == null) return null;
    final baseRecord = records[baseModId];
    if (baseRecord == null) return null;
    return checkForUpdate(
      origin: origin,
      remote: baseRecord,
      releases: groupsFor[baseModId] ?? ReleaseGroups.empty,
      companionRemotes: <int, GbMod>{
        for (final download in origin.patches)
          if (download.modId case final id?)
            if (records[id] case final record?) id: record,
      },
      companionReleases: groupsFor,
    );
  }

  // ---- fold: one verdict per folder, after every record has landed ---------
  for (final mod in plan.checkable) {
    final check = foldFor(mod);
    if (check == null) {
      // The primary's page was never reached, so there is nothing to fold.
      failed.add(mod.id);
      continue;
    }
    checks[mod.id] = check;
    // Half an answer is not an answer. The verdict is kept — it refuses to
    // claim clean without the missing half — but the folder is reported
    // unchecked, because the pass did not finish asking about it.
    if (mod.origin!.patches.any((download) =>
        download.hasIdentity && !records.containsKey(download.modId))) {
      failed.add(mod.id);
    }
  }

  // ---- phase two: ask the author which files shipped together --------------
  //
  // Only for mods that flagged. A release group can turn a flag *off* and can
  // never turn one on, so a failure here is not an error state: the verdict
  // simply stays as phase one left it, which is the direction that errs toward
  // telling the user.
  //
  // **The feed asked for is the one belonging to the identity that produced the
  // finding**, which for a mixed folder is frequently not its primary. Groups
  // refine one mod's verdict; the patch's grouping says nothing about the base
  // mod's files, so asking the wrong page spends a request and refines nothing.
  if (fetchUpdates != null) {
    final needFeed = <int, List<ModInfo>>{};
    for (final mod in plan.checkable) {
      final check = checks[mod.id];
      if (!(check?.hasUpdate ?? false)) continue;
      final subject = check!.subjectModId ?? mod.origin!.base?.modId;
      if (subject == null) continue;
      needFeed.putIfAbsent(subject, () => <ModInfo>[]).add(mod);
    }

    for (final entry in needFeed.entries) {
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
      for (final mod in entry.value) {
        // Re-folded rather than patched: suppressing the finding the folder was
        // reporting means its *other* identity's verdict is now the folder's,
        // and only a fold can work that out.
        final refolded = foldFor(mod, groupsFor: {entry.key: groups});
        if (refolded != null) checks[mod.id] = refolded;
      }
    }
  }

  // Everything the pass never got to. A run that stopped at batch two leaves
  // the rest unanswered, and "no entry" is indistinguishable from "not in the
  // library" to the caller — so say so explicitly rather than letting the
  // summary quietly describe a third of the work as if it were all of it.
  if (aborted != null) {
    for (final mod in plan.checkable) {
      if (!checks.containsKey(mod.id)) failed.add(mod.id);
    }
  }

  return BulkUpdateCheckOutcome(
    checks: checks,
    failed: failed,
    requests: requests,
    records: records,
    abortedBy: aborted,
  );
}
