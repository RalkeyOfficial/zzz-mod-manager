/// Running the whole-library check, and folding its answers into what is
/// already known.
///
/// Two surfaces start this pass — the All mods table's *Check all for updates*
/// (and its selection bar's check of the ticked mods), and the opt-in check
/// that runs by itself at startup — and they must not be two
/// implementations. What they share is not just the call: it is the cache
/// decision below and the merge rule, both of which are wrong in a way nobody
/// would notice if one copy drifted.
///
/// Deliberately Flutter-free. The providers the results land in are read and
/// written by the callers; the rules for *what* to write are here.
library;

import '../models/character_info.dart';
import '../models/gamebanana/gamebanana.dart';
import '../models/mod_origin.dart';
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
  ModProfileFetcher? fetchProfile,
  void Function(Set<String> reached)? onProgress,
}) {
  return runBulkUpdateCheck(
    plan: plan,
    onProgress: onProgress,
    fetch: fetch ??
        (ids) => client.modsMulti(
              ids,
              properties: updateCheckProperties,
              refresh: true,
            ),
    fetchUpdates:
        fetchUpdates ?? (modId) => client.modUpdates(modId, refresh: true),
    fetchProfile:
        fetchProfile ?? (modId) => client.modProfile(modId, refresh: true),
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
/// **A withheld mod comes back as its `ProfilePage`**, which `Mod/Multi` blanks
/// ([isBlankedRecord]), exactly as the whole-library pass replaces it.
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
    if (record.idRow != modId) continue;
    // A withheld mod's files are on its profile only.
    if (isBlankedRecord(record)) return client.modProfile(modId, refresh: refresh);
    return record;
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
///
/// The folders in [keep] keep what they have: their tracking changed while the
/// pass ran ([UpdateCheckStart.changedSince]), so its answer is about a block
/// that is gone.
Map<String, UpdateCheck> mergedChecks(
  Map<String, UpdateCheck> existing,
  BulkUpdateCheckOutcome outcome, {
  Set<String> keep = const {},
}) =>
    {
      ...existing,
      for (final MapEntry(key: id, value: check) in outcome.checks.entries)
        if (!keep.contains(id)) id: check,
    };

/// What a pass started from, to tell at its end which folders changed under it.
///
/// An Ignore, an update, a marking or its Undo, the tracking screen, a patch
/// taken out or put in can write a folder while a pass runs. The pass's answer
/// was worked out from the block as it was, so merging it would bring back
/// what the write took away.
class UpdateCheckStart {
  UpdateCheckStart({
    required Map<String, UpdateCheck> checks,
    required Iterable<ModInfo> mods,
    required Map<String, int> writesStarted,
    required Set<String> writing,
  })  : _checks = checks,
        _origins = {for (final mod in mods) mod.id: mod.origin},
        _writesStarted = writesStarted,
        _writingAtStart = writing;

  final Map<String, UpdateCheck> _checks;
  final Map<String, ModOrigin?> _origins;
  final Map<String, int> _writesStarted;
  final Set<String> _writingAtStart;

  /// The folders whose verdict the pass must not write: one being written when
  /// it started, written since or being written now ([writesStarted] and
  /// [writing], both kept by `whileWritingMod`), whose session verdict was set
  /// or dropped since, whose tracking on the last scan differs from what it
  /// started with, or that is gone.
  ///
  /// The count covers every write that goes through `whileWritingMod`, ended
  /// or not, rescanned or not. The verdict covers the update dialog's own
  /// check, which writes nothing; the scan covers a write made some other way,
  /// once its rescan has landed.
  Set<String> changedSince({
    required Map<String, UpdateCheck> checks,
    required Iterable<ModInfo> mods,
    required Set<String> writing,
    required Map<String, int> writesStarted,
  }) {
    final now = {for (final mod in mods) mod.id: mod.origin};
    return {
      for (final id in _origins.keys)
        if (_writingAtStart.contains(id) ||
            writesStarted[id] != _writesStarted[id] ||
            writing.contains(id) ||
            !identical(_checks[id], checks[id]) ||
            !now.containsKey(id) ||
            now[id] != _origins[id])
          id,
    };
  }
}

/// The fetched mod pages, merged on the same rule and for a second reason: they
/// are what lets the bulk resolution screen be re-opened without spending
/// another request.
Map<int, GbMod> mergedRecords(
  Map<int, GbMod> existing,
  BulkUpdateCheckOutcome outcome,
) =>
    {...existing, ...outcome.records};
