import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/gamebanana/gamebanana.dart';
import 'package:mod_manager_flutter/services/gamebanana/gamebanana_client.dart';
import 'package:mod_manager_flutter/services/gamebanana/gamebanana_endpoints.dart';
import 'package:mod_manager_flutter/services/gamebanana/gamebanana_response_cache.dart';
import 'package:mod_manager_flutter/services/bulk_update_check.dart';

import '../support/fake_http_transport.dart';
import '../support/fixtures.dart';

/// The client, exercised entirely offline through the injected transport.
/// Nothing here touches the network — if it ever does, the seam is wrong.
void main() {
  late FakeHttpTransport transport;
  late DateTime clock;
  late List<Duration> slept;

  const endpoints = GameBananaEndpoints(gameId: 19567);

  GameBananaClient buildClient({int maxRetries = 2}) {
    return GameBananaClient(
      transport: transport,
      cache: GameBananaResponseCache(now: () => clock),
      endpoints: endpoints,
      maxRetries: maxRetries,
      sleep: (d) async => slept.add(d),
    );
  }

  setUp(() {
    transport = FakeHttpTransport();
    clock = DateTime.utc(2026, 8, 1, 12);
    slept = <Duration>[];
  });

  group('requests', () {
    test('modProfile fetches and parses the profile', () async {
      transport.stub(endpoints.modProfile(531649),
          body: loadGbFixture('mod_profile_531649'));

      final mod = await buildClient().modProfile(531649);

      expect(mod.idRow, 531649);
      expect(mod.files, hasLength(6));
      expect(transport.requests.single, endpoints.modProfile(531649));
    });

    test('searchMods parses the envelope', () async {
      transport.stub(endpoints.search('ellen'),
          body: loadGbFixture('search_ellen'));

      final page = await buildClient().searchMods('ellen');

      expect(page.records, hasLength(15));
      expect(page.perPage, 15, reason: 'server caps search at 15 silently');
      expect(page.recordCount, greaterThan(15));
    });

    test('searchMods short-circuits an empty query without a request', () async {
      final page = await buildClient().searchMods('   ');
      expect(page.records, isEmpty);
      expect(transport.callCount, 0);
    });

    test('browseMods parses the envelope', () async {
      transport.stub(endpoints.modIndex(perPage: 5),
          body: loadGbFixture('mod_index_p1'));

      final page = await buildClient().browseMods(perPage: 5);

      expect(page.records, hasLength(5));
      expect(page.recordCount, greaterThan(1000));
    });

    test('categories parses the bare array', () async {
      transport.stub(endpoints.categories(), body: loadGbFixture('categories_root'));

      final roots = await buildClient().categories();

      expect(roots, hasLength(4));
      expect(roots.map((c) => c.idRow), contains(30305));
    });

  });

  group('headers', () {
    test('identifies the app and does not impersonate a browser', () async {
      transport.stub(endpoints.modProfile(1), body: '{"_idRow":1}');
      await buildClient().modProfile(1);

      final userAgent = transport.sentHeaders.single['User-Agent'];
      expect(userAgent, startsWith('zzz-mod-manager/'));
      expect(userAgent, isNot(contains('Mozilla')));
      expect(userAgent, isNot(contains('Chrome')));
    });
  });

  group('errors', () {
    test('a 400 error envelope becomes a typed GbApiException', () async {
      transport.stub(endpoints.modIndex(),
          statusCode: 400, body: loadGbFixture('error_input_errors'));

      await expectLater(
        buildClient().browseMods(),
        throwsA(isA<GbApiException>()
            .having((e) => e.code, 'code', 'INPUT_ERRORS')
            .having((e) => e.statusCode, 'statusCode', 400)
            .having((e) => e.fieldErrors['_sSort']?.code, '_sSort error',
                'UNKNOWN_SORT')),
      );
    });

    test('a 404 route error is recognisable as not-found', () async {
      transport.stub(endpoints.modProfile(1),
          statusCode: 404, body: loadGbFixture('error_no_such_route'));

      await expectLater(
        buildClient().modProfile(1),
        throwsA(isA<GbApiException>()
            .having((e) => e.code, 'code', 'NO_SUCH_ROUTE')
            .having((e) => e.isNotFound, 'isNotFound', isTrue)),
      );
    });

    test('an error envelope served with a 200 still throws', () async {
      transport.stub(endpoints.modProfile(1),
          statusCode: 200, body: loadGbFixture('error_input_errors'));

      await expectLater(buildClient().modProfile(1),
          throwsA(isA<GbApiException>()));
    });

    test('an HTML body becomes GbFormatException, not a raw FormatException',
        () async {
      transport.stub(endpoints.modProfile(1),
          body: '<html><body>Just a moment…</body></html>');

      await expectLater(
          buildClient().modProfile(1), throwsA(isA<GbFormatException>()));
    });

    test('a transport failure becomes GbNetworkException', () async {
      transport.enqueueError(
          endpoints.modProfile(1), const SocketExceptionStub());

      await expectLater(
          buildClient().modProfile(1), throwsA(isA<GbNetworkException>()));
    });

    test('a profile with no _idRow is a format error, not a null mod', () async {
      transport.stub(endpoints.modProfile(1), body: '{"_sName":"orphan"}');

      await expectLater(
          buildClient().modProfile(1), throwsA(isA<GbFormatException>()));
    });
  });

  group('reactive backoff', () {
    test('retries a 429 and succeeds', () async {
      final url = endpoints.modProfile(531649);
      transport.enqueue(url, statusCode: 429, body: '{}');
      transport.enqueue(url, body: loadGbFixture('mod_profile_531649'));

      final mod = await buildClient().modProfile(531649);

      expect(mod.idRow, 531649);
      expect(transport.callCount, 2);
      expect(slept, [const Duration(seconds: 1)]);
    });

    test('honours Retry-After when the server sends one', () async {
      final url = endpoints.modProfile(1);
      transport.enqueue(url,
          statusCode: 503, body: '{}', headers: {'retry-after': '7'});
      transport.enqueue(url, body: '{"_idRow":1}');

      await buildClient().modProfile(1);

      expect(slept, [const Duration(seconds: 7)]);
    });

    test('gives up after maxRetries and reports rate limiting', () async {
      final url = endpoints.modProfile(1);
      transport.stub(url, statusCode: 503, body: '{}');

      await expectLater(
          buildClient().modProfile(1), throwsA(isA<GbRateLimitException>()));

      expect(transport.callCount, 3, reason: 'initial attempt + 2 retries');
      expect(slept, [const Duration(seconds: 1), const Duration(seconds: 2)]);
    });

    test('a 400 is NEVER retried', () async {
      // It means our url is wrong. Retrying just makes the same mistake three
      // times and delays the real error.
      transport.stub(endpoints.modProfile(1),
          statusCode: 400, body: loadGbFixture('error_input_errors'));

      await expectLater(
          buildClient().modProfile(1), throwsA(isA<GbApiException>()));

      expect(transport.callCount, 1);
      expect(slept, isEmpty);
    });
  });

  /// A `200` with nothing in it.
  ///
  /// Measured against the live API on mod 712159: two consecutive requests
  /// answered `200` with a zero-byte body, and the same url served 14,926 bytes
  /// of valid JSON a minute later. It is a transient upstream fault, so the
  /// client treats it like one — the same reactive retry a 429 gets.
  group('an empty response body', () {
    test('is retried, and the retry is what the caller sees', () async {
      final url = endpoints.modProfile(1);
      transport.enqueue(url, body: '');
      transport.enqueue(url, body: '{"_idRow":1}');
      final client = buildClient();

      final mod = await client.modProfile(1);

      expect(mod.idRow, 1);
      expect(transport.callCount, 2);
      expect(slept, [const Duration(seconds: 1)],
          reason: 'spaced out, not hammered');
    });

    test('whitespace is just as empty', () async {
      final url = endpoints.modProfile(1);
      transport.enqueue(url, body: '   \n  ');
      transport.enqueue(url, body: '{"_idRow":1}');

      expect((await buildClient().modProfile(1)).idRow, 1);
    });

    test('says the server sent nothing, rather than blaming the shape of it',
        () async {
      // "We couldn't read what GameBanana sent" is untrue and unactionable when
      // nothing was sent. This is a distinct failure so the screen can say so.
      transport.stub(endpoints.modProfile(1), body: '');
      final client = buildClient();

      await expectLater(
        client.modProfile(1),
        throwsA(isA<GbEmptyResponseException>()),
      );
      expect(transport.callCount, 3, reason: 'the initial call plus 2 retries');
    });

    test('is never cached, however many times it happens', () async {
      final url = endpoints.modProfile(1);
      transport.stub(url, body: '');
      final client = buildClient(maxRetries: 0);

      await expectLater(client.modProfile(1),
          throwsA(isA<GbEmptyResponseException>()));
      await expectLater(client.modProfile(1),
          throwsA(isA<GbEmptyResponseException>()));

      expect(transport.callCount, 2,
          reason: 'the second press asked again instead of replaying the '
              'empty body from cache');
    });

    test('an empty body on a 404 is still a 404', () async {
      // Status first: an empty body is only interesting when the server claimed
      // success. A missing mod that answers with nothing must stay not-found,
      // or the client would retry something that will never come good.
      transport.stub(endpoints.modProfile(1), statusCode: 404, body: '');
      final client = buildClient();

      await expectLater(
        client.modProfile(1),
        throwsA(isA<GbApiException>().having((e) => e.isNotFound, 'isNotFound', isTrue)),
      );
      expect(transport.callCount, 1, reason: 'not retried');
    });
  });

  group('caching', () {
    test('a repeat call is served from cache', () async {
      transport.stub(endpoints.modProfile(531649),
          body: loadGbFixture('mod_profile_531649'));
      final client = buildClient();

      await client.modProfile(531649);
      await client.modProfile(531649);

      expect(transport.callCount, 1);
    });

    test('the entry expires after the default 10 minutes', () async {
      transport.stub(endpoints.modProfile(531649),
          body: loadGbFixture('mod_profile_531649'));
      final client = buildClient();

      await client.modProfile(531649);
      clock = clock.add(const Duration(seconds: 601));
      await client.modProfile(531649);

      expect(transport.callCount, 2);
    });

    test("the server's own max-age wins over the default", () async {
      transport.stub(
        endpoints.modProfile(1),
        body: '{"_idRow":1}',
        headers: {'cache-control': 'public, max-age=60'},
      );
      final client = buildClient();

      await client.modProfile(1);
      clock = clock.add(const Duration(seconds: 30));
      await client.modProfile(1);
      expect(transport.callCount, 1, reason: 'still inside the 60s max-age');

      clock = clock.add(const Duration(seconds: 31));
      await client.modProfile(1);
      expect(transport.callCount, 2);
    });

    test('refresh: true bypasses the cache but still refills it', () async {
      transport.stub(endpoints.modProfile(1), body: '{"_idRow":1}');
      final client = buildClient();

      await client.modProfile(1);
      await client.modProfile(1, refresh: true);
      expect(transport.callCount, 2);

      await client.modProfile(1);
      expect(transport.callCount, 2, reason: 'refresh repopulated the cache');
    });

    test('errors are not cached, so a retry can succeed', () async {
      final url = endpoints.modProfile(1);
      transport.enqueue(url, statusCode: 404, body: loadGbFixture('error_no_such_route'));
      transport.enqueue(url, body: '{"_idRow":1}');
      final client = buildClient();

      await expectLater(client.modProfile(1), throwsA(isA<GbApiException>()));
      final mod = await client.modProfile(1);

      expect(mod.idRow, 1);
      expect(transport.callCount, 2);
    });

    test('an unreadable body is not cached, so pressing again re-asks',
        () async {
      // **The bug this exists for.** GameBanana intermittently answers a
      // perfectly good request with `200` and nothing in it. Cached, that one
      // hiccup became a mod that could not be opened for the next ten minutes —
      // every retry served the same empty body from memory without a request,
      // so it read as a permanent fault in that one mod's page.
      //
      // The rule is general, not about emptiness: a body that cannot be parsed
      // is a body that must not be kept.
      final url = endpoints.modProfile(1);
      transport.enqueue(url, body: '<html>nope</html>');
      transport.enqueue(url, body: '{"_idRow":1}');
      final client = buildClient();

      await expectLater(
          client.modProfile(1), throwsA(isA<GbFormatException>()));
      final mod = await client.modProfile(1);

      expect(mod.idRow, 1);
      expect(transport.callCount, 2, reason: 'the second call asked again');
    });

    test('a profile that parsed but carried no _idRow is not kept either',
        () async {
      // Reached through a different throw site — the client's own check, after
      // a successful decode — and it poisons the cache exactly the same way.
      final url = endpoints.modProfile(1);
      transport.enqueue(url, body: '{"_sName":"no id here"}');
      transport.enqueue(url, body: '{"_idRow":1}');
      final client = buildClient();

      await expectLater(
          client.modProfile(1), throwsA(isA<GbFormatException>()));

      expect((await client.modProfile(1)).idRow, 1);
      expect(transport.callCount, 2);
    });

    test('clearCache forces a refetch', () async {
      transport.stub(endpoints.modProfile(1), body: '{"_idRow":1}');
      final client = buildClient();

      await client.modProfile(1);
      client.clearCache();
      await client.modProfile(1);

      expect(transport.callCount, 2);
    });

    test('different urls are cached separately', () async {
      transport.stub(endpoints.modProfile(1), body: '{"_idRow":1}');
      transport.stub(endpoints.modProfile(2), body: '{"_idRow":2}');
      final client = buildClient();

      await client.modProfile(1);
      await client.modProfile(2);

      expect(transport.callCount, 2);
    });
  });

  group('in-flight coalescing', () {
    test('two concurrent identical requests issue one call', () async {
      // A grid and a detail view racing for the same profile shouldn't both
      // hit the network.
      transport.stub(endpoints.modProfile(531649),
          body: loadGbFixture('mod_profile_531649'));
      final client = buildClient();

      final results = await Future.wait([
        client.modProfile(531649),
        client.modProfile(531649),
      ]);

      expect(transport.callCount, 1);
      expect(results.map((m) => m.idRow), [531649, 531649]);
    });

    test('a failed in-flight request is not left behind', () async {
      final url = endpoints.modProfile(1);
      transport.enqueue(url, statusCode: 404, body: loadGbFixture('error_no_such_route'));
      transport.enqueue(url, body: '{"_idRow":1}');
      final client = buildClient();

      await expectLater(client.modProfile(1), throwsA(isA<GbApiException>()));

      // If the failed future stuck around, this would resolve to the failure.
      expect((await client.modProfile(1)).idRow, 1);
    });
  });

  group('the two batch endpoints, which parse differently', () {
    // `Mod/Multi` returns a **bare array** and `Mod/<id>/Updates` an
    // **envelope**, so they go through `parseBareList` and `parseEnvelope`
    // respectively. Swapping them is the one mistake `gb_page.dart` exists to
    // throw loudly on, and nothing else in the suite would catch it.
    test('modsMulti parses a bare array', () async {
      transport.stub(
        endpoints.modsMulti(const [531649, 528481, 541825], updateCheckProperties),
        body: loadGbFixture('mod_multi_files'),
      );

      final records = await buildClient().modsMulti(
        const [531649, 528481, 541825],
        properties: updateCheckProperties,
      );

      expect(records.map((m) => m.idRow), [531649, 528481, 541825]);
      // The union of current and archived, which is this endpoint's own shape.
      expect(records.first.files, hasLength(14));
      expect(records.first.currentFiles, hasLength(6));
    });

    test('modsMulti asks for nothing when given no ids', () async {
      expect(
        await buildClient().modsMulti(const [], properties: const ['_idRow']),
        isEmpty,
      );
      expect(transport.callCount, 0);
    });

    test('modUpdates parses an envelope and reads the released file ids',
        () async {
      transport.stub(endpoints.modUpdates(549029),
          body: loadGbFixture('mod_updates_549029'));

      final updates = await buildClient().modUpdates(549029);

      expect(updates, hasLength(2));
      expect(updates.first.name, 'Version 1.5');
      // The field the whole variant-suppression rule rests on.
      expect(updates.first.fileRowIds, {1484606, 1484607});
    });

    test('modUpdates reads the release notes in both shapes', () async {
      transport.stub(endpoints.modUpdates(549029),
          body: loadGbFixture('mod_updates_549029'));

      final updates = await buildClient().modUpdates(549029);

      // `_aChangeLog` is **the one object in this API with unprefixed keys** —
      // bare `text` and `cat`, not `_sText` / `_sCat`. Reading them the usual
      // way yields an empty changelog for every mod, silently, which is exactly
      // how the `_aTags` two-shape bug went unnoticed.
      expect(updates.first.changeLog, hasLength(5));
      expect(
        updates.first.changeLog.first.text,
        'Leotard, OG Dress and Tights added',
      );
      expect(updates.first.changeLog.first.category, 'Addition');
      // Prose and bullets are complementary, not alternatives: this record
      // carries both, and the second one carries neither a changelog nor a
      // version.
      expect(updates.first.text, contains('she got her banner back'));
      expect(updates.first.hasNotes, isTrue);
      expect(updates.last.changeLog, isEmpty);
      expect(updates.last.hasNotes, isTrue);
    });

    test('an unknown id fails the whole batch, and says which field', () async {
      // Captured from the live API. The recovery in `bulk_update_check.dart`
      // branches on *which* field `_aErrorData` names — anything but
      // `_csvRowIds` means our url is wrong and every split would fail
      // identically — so the shape of this body is load-bearing.
      transport.stub(
        endpoints.modsMulti(const [531649, 999999999], const ['_idRow']),
        statusCode: 400,
        body: loadGbFixture('error_no_such_record'),
      );

      await expectLater(
        buildClient()
            .modsMulti(const [531649, 999999999], properties: const ['_idRow']),
        throwsA(
          isA<GbApiException>()
              .having((e) => e.code, 'code', 'INPUT_ERRORS')
              .having(
                (e) => e.fieldErrors['_csvRowIds']?.code,
                'offending field',
                'NO_SUCH_RECORD',
              ),
        ),
      );
    });
  });

  test('close releases the transport', () {
    buildClient().close();
    expect(transport.closed, isTrue);
  });
}

/// Stands in for a `dart:io` SocketException without importing it, so this
/// test file stays platform-free.
class SocketExceptionStub implements Exception {
  const SocketExceptionStub();
}
