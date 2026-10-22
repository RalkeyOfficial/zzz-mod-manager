import 'dart:convert';
import 'dart:io';

/// Loads a checked-in API response from `test/fixtures/`.
///
/// These are **real captured responses**, not hand-written mocks. GameBanana's
/// `apiv13` is undocumented and discoverable only by probing, so a fixture is
/// the only thing that keeps the parser honest about field names and shapes
/// that nobody can look up. Re-capture with curl if the API shifts; don't
/// hand-edit them to make a test pass.
///
/// Captured from **apiv13** on 2026-08-15, pretty-printed for reviewability —
/// only whitespace differs from the wire bytes. The withheld pair,
/// `mod_multi_withheld_581980` and `mod_profile_withheld_581980`, on 2026-10-20.
/// The Browse enrichment pair on 2026-10-21, both `Mod/Multi` with
/// `_csvProperties=_idRow,_nDownloadCount,_aCategory,_aFiles`: `mod_multi_enrich_p1`
/// for the ids of `mod_index_p1`, and `mod_multi_enrich_newest` for a page of
/// `Generic_Newest` plus the withheld mod 581980. The creator page's pair on 2026-10-21, both `Mod/Index` with
/// `_aFilters[Generic_Submitter]`, `_sSort=Generic_Newest&_nPerpage=50&_nPage=1`: `mod_index_submitter_2307694`
/// (Exce, 24 mods across 20 characters and two Bangboo skins) and `mod_index_submitter_3549585` (summersby, UI and
/// Other/Misc mods filed directly under the root).
///
/// Two things to know before re-capturing:
///
/// - **Match the original request, not just the endpoint.** `mod_index_p1` is
///   `_sSort=Generic_MostLiked&_nPerpage=5`; capturing it under a different sort
///   silently changes the *content mix*, and `content_filter_test` reads this
///   fixture as evidence that a ZZZ listing skews adult.
/// - **`error_no_such_route` is deliberately still an apiv11 capture.** apiv13
///   answers an unrecognised route with a `200` and an HTML error page rather
///   than the JSON envelope, so there is nothing equivalent to capture — while
///   the shape it holds is still live, because a missing *mod* (the case that
///   actually reaches users) still returns `404` with this exact envelope.
String loadFixture(String relativePath) {
  final file = File('test/fixtures/$relativePath');
  if (!file.existsSync()) {
    throw StateError(
      'Missing fixture: ${file.path}\n'
      '(tests run with the package root as the working directory)',
    );
  }
  return file.readAsStringSync();
}

/// Shorthand for the GameBanana fixture directory.
String loadGbFixture(String name) => loadFixture('gamebanana/$name.json');

/// One mod's record out of the captured `Mod/Multi` batch, as the bare array a
/// single-id request answers with.
///
/// Sliced from `mod_multi_files` rather than captured again, because a batch
/// record and a one-id record are the same shape — verified against the live API
/// — and re-capturing would mean two files to keep in step. **Still real data**:
/// nothing here builds a record, it only narrows the array.
///
/// This is the shape a per-mod check sees (`fetchModRecord`), and it differs from
/// a profile in the one way that matters: `_aFiles` is the union of current and
/// archived, flagged by `_bIsArchived`.
String gbMultiRecordFixture(int modId) {
  final decoded = jsonDecode(loadGbFixture('mod_multi_files'));
  if (decoded is! List) {
    throw StateError('mod_multi_files is not a bare array');
  }
  final record = decoded.firstWhere(
    (r) => r is Map && r['_idRow'] == modId,
    orElse: () => throw StateError(
      'mod_multi_files holds no record for mod $modId — '
      'capture it into that batch rather than writing one by hand',
    ),
  );
  return jsonEncode([record]);
}

/// A one-page search whose results are the `mod_multi_files` mods [modIds].
///
/// For a test that picks a search result and goes on to fetch that mod's record:
/// the captured `search_ellen` lists mods this batch holds no record for, and
/// `fetchModRecord` refuses a record carrying another mod's id. Only the id and
/// the captured name are carried over, which is all a result row needs to be
/// shown and picked; the search parser itself is tested against `search_ellen`.
String gbSearchOfMultiRecords(List<int> modIds) {
  final records = [
    for (final id in modIds)
      jsonDecode(gbMultiRecordFixture(id)).single as Map<String, dynamic>,
  ];
  return jsonEncode({
    '_aMetadata': {'_nRecordCount': records.length, '_bIsComplete': true},
    '_aRecords': [
      for (final record in records)
        {'_idRow': record['_idRow'], '_sName': record['_sName']},
    ],
  });
}
