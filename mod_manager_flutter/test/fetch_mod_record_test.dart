import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_exceptions.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_mod.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/services/bulk_update_check.dart';
import 'package:mod_manager_flutter/services/gamebanana/gamebanana_client.dart';
import 'package:mod_manager_flutter/services/gamebanana/gamebanana_endpoints.dart';
import 'package:mod_manager_flutter/services/update_check.dart';
import 'package:mod_manager_flutter/services/update_check_run.dart';

import 'support/fake_http_transport.dart';
import 'support/fixtures.dart';
import 'support/origin_shorthand.dart';

/// The request a **per-mod** update check makes.
///
/// The interesting property is not that it parses — `gamebanana_client_test`
/// covers `Mod/Multi` — but that it asks for the *same fields* as the
/// whole-library pass. The comparator is shared, so a property list that drifted
/// would let the card badge and the dialog give one mod two different verdicts,
/// and neither surface would look wrong on its own.
void main() {
  final endpoints = GameBananaEndpoints(gameId: 19567);
  late FakeHttpTransport transport;

  setUp(() => transport = FakeHttpTransport());

  GameBananaClient client() =>
      GameBananaClient(transport: transport, endpoints: endpoints);

  Uri url(int modId) =>
      endpoints.modsMulti([modId], updateCheckProperties);

  test('one id, over Mod/Multi, with the bulk pass\'s properties', () async {
    transport.stub(url(531649), body: gbMultiRecordFixture(531649));

    final record = await fetchModRecord(client(), 531649);

    expect(transport.requests, [url(531649)]);
    expect(record.idRow, 531649);
    // Every field the comparator reads, and the four a `DownloadPage` response
    // would be missing are the point of this list: without the two dates an
    // `assumed_latest` verdict is wrong rather than quieter, and without
    // `_bIsObsolete` the author's "superseded" flag silently leaves every
    // verdict.
    expect(record.dateAdded, isNotNull);
    expect(record.dateUpdated, isNotNull);
    expect(record.isObsolete, isFalse);
    expect(record.isRemoteMissing, isFalse);
    // The union under one key, which is this endpoint's shape rather than a
    // profile's two.
    expect(record.files, hasLength(14));
    expect(record.currentFiles, hasLength(6));
  });

  test('the record folds to the same verdict a profile does', () async {
    // The claim that makes the swap safe. `update_check_test` pins the same
    // equality against the batch fixture; this one goes through the real
    // request path, so a property dropped from `updateCheckProperties` fails
    // here rather than quietly changing an answer.
    transport.stub(url(531649), body: gbMultiRecordFixture(531649));
    final record = await fetchModRecord(client(), 531649);

    final check = checkForUpdate(
      // Installed on RabbitFX's archived "Main file" v7.4, whose successor
      // under the same label is v7.7 — the one case where the strong verdict is
      // earned rather than folded down to a guess.
      origin: originFixture(
        source: 'gamebanana',
        modId: 531649,
        modIdConfidence: OriginConfidence.user,
        fileId: 1696178,
        versionLabel: 'Main file',
        versionConfidence: OriginConfidence.user,
        provenance: OriginProvenance.downloaded,
      ),
      remote: record,
    );

    expect(check.outcome, UpdateOutcome.updateAvailable);
    expect(check.candidate?.idRow, 1732269);
  });

  test('a withheld mod is read from its profile, since Mod/Multi blanks it', () async {
    // Both are real responses for 581980, a "softhold": the page and both files
    // are public, and `Mod/Multi` sends the name, nulls the rest and says it is
    // not withheld. If this blank ever comes back whole, this test still passes
    // through the profile, but the canary below fails.
    transport.stub(url(581980), body: loadGbFixture('mod_multi_withheld_581980'));
    transport.stub(
      endpoints.modProfile(581980),
      body: loadGbFixture('mod_profile_withheld_581980'),
    );

    final record = await fetchModRecord(client(), 581980);

    expect(transport.requests, [url(581980), endpoints.modProfile(581980)]);
    expect(record.isWithheld, isTrue);
    expect(record.isRemoteMissing, isFalse);
    expect(record.currentFiles, hasLength(2));
  });

  test('canary: Mod/Multi blanks a withheld mod rather than flagging it', () {
    final multi = GbMod.fromJson(
      (jsonDecode(loadGbFixture('mod_multi_withheld_581980')) as List).single
          as Map<String, dynamic>,
    )!;
    final profile = GbMod.fromJson(
      jsonDecode(loadGbFixture('mod_profile_withheld_581980'))
          as Map<String, dynamic>,
    )!;

    expect(multi.isWithheld, isFalse);
    expect(multi.dateAdded, isNull);
    expect(multi.currentFiles, isEmpty);
    expect(isBlankedRecord(multi), isTrue);
    expect(isBlankedRecord(profile), isFalse);
    // Every real Mod/Multi record of a published mod carries its date.
    expect(isBlankedRecord(GbMod.fromJson(
      (jsonDecode(gbMultiRecordFixture(531649)) as List).single
          as Map<String, dynamic>,
    )!), isFalse);
  });

  test('only a softhold counts as public; any other hold reads as gone', () {
    // No other hold has been captured, so the real softhold profile stands in
    // with its type changed: what is unmeasured fails closed, rather than offer
    // an update whose files may not be public.
    Map<String, dynamic> profileJson() =>
        jsonDecode(loadGbFixture('mod_profile_withheld_581980'))
            as Map<String, dynamic>;

    expect(GbMod.fromJson(profileJson())!.withholdType, 'softhold');
    expect(GbMod.fromJson(profileJson())!.isRemoteMissing, isFalse);

    final hardhold = profileJson();
    (hardhold['_aWithholdNotice'] as Map<String, dynamic>)['_sType'] = 'hardhold';
    expect(GbMod.fromJson(hardhold)!.isRemoteMissing, isTrue);

    final noNotice = profileJson()..remove('_aWithholdNotice');
    expect(GbMod.fromJson(noNotice)!.isRemoteMissing, isTrue);
  });

  test('a response that names another mod is an error, never an empty answer',
      () async {
    // The endpoint errors on an unknown id rather than omitting it, so this is
    // "cannot happen" — and it must stay loud if it does. Returning null here
    // would reach the comparator as a mod with no files, which reads as *up to
    // date*: a false negative, the one failure this feature cannot afford.
    transport.stub(url(531649), body: gbMultiRecordFixture(528481));

    await expectLater(
      fetchModRecord(client(), 531649),
      throwsA(isA<GbFormatException>()),
    );
  });

  test('a missing mod arrives as the API error, not as a verdict', () async {
    // `Mod/Multi` answers `400` + `INPUT_ERRORS` with `NO_SUCH_RECORD` under
    // `_csvRowIds`, where a profile answers a bare `404` (both verified against
    // the live API). Callers see one exception type either way; what tells them
    // an *id* was the problem rather than our url is the field name, which is
    // exactly what `runBulkUpdateCheck` splits on.
    transport.stub(
      url(999999999),
      statusCode: 400,
      body: '{"_sErrorCode":"INPUT_ERRORS","_aErrorData":{"_csvRowIds":'
          '{"_sErrorCode":"NO_SUCH_RECORD",'
          '"_sErrorMessage":"Record Mod.999999999 doesn\'t exist"}}}',
    );

    await expectLater(
      fetchModRecord(client(), 999999999),
      throwsA(
        isA<GbApiException>()
            .having((e) => e.code, 'code', 'INPUT_ERRORS')
            .having(
              (e) => e.fieldErrors.keys,
              'the field blamed',
              contains('_csvRowIds'),
            ),
      ),
    );
  });
}
