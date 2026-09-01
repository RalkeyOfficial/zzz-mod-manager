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

/// One mod's record for a **per-mod** check, over `Mod/Multi`.
///
/// The same endpoint and the same [updateCheckProperties] the whole-library pass
/// uses, and that is the point rather than a convenience: [checkForUpdate] reads
/// six fields off a `GbMod`, the card badge's verdict is folded from a
/// `Mod/Multi` record, and the dialog's is folded from whatever this returns. One
/// property list means the two surfaces cannot answer differently about one mod.
///
/// It is also a quarter of the bytes — measured live against apiv13: 7.7 KB
/// where `Mod/<id>/ProfilePage` sends 31 KB, and 11 KB where it sends 48 KB for a
/// mod with a long description. A profile carries a gallery, the author's HTML
/// description, credits, licence text and requirements, none of which a
/// comparator can use.
///
/// **`Mod/<id>/DownloadPage` is cheaper on paper and cannot be used.** It returns
/// the two file lists plus `_bIsTrashed` / `_bIsWithheld` and nothing else, so
/// `_tsDateAdded`, `_tsDateUpdated`, `_bIsObsolete` and `_bIsPrivate` are all
/// absent. The first two are what an `assumed_latest` baseline is clamped and
/// compared against, so a check without them is *wrong* rather than merely
/// quieter; the third silently drops the author's "superseded" flag from every
/// verdict. `Mod/Multi` is smaller than it anyway (measured: 7.7 KB against
/// 8.1 KB), because it sends no licence or submitter instructions.
///
/// **One id per request, not one request for the folder.** A batch is
/// all-or-nothing: a companion whose page has been deleted would fail the
/// primary's check with it, where the dialog's rule is that an unreachable
/// companion is left out and the folder is simply not called clean. Recovering
/// from that inside a batch is the halving `runBulkUpdateCheck` does, and it is
/// not worth it for the two or three ids a folder has.
///
/// Throws like the client does.
Future<GbMod> fetchModRecord(
  GameBananaClient client,
  int modId, {
  bool refresh = false,
}) async {
  final records = await client.modsMulti(
    [modId],
    properties: updateCheckProperties,
    refresh: refresh,
  );
  for (final record in records) {
    if (record.idRow == modId) return record;
  }
  // The endpoint errors on an unknown id rather than omitting it, so this is
  // "should not happen" — raised rather than returned as a null so it cannot be
  // read as "this mod has no files", which is the shape of a false "up to date".
  throw GbFormatException('Mod $modId: Mod/Multi returned no matching record');
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
