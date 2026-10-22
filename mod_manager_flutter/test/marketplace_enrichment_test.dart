import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/gamebanana/gamebanana.dart';
import 'package:mod_manager_flutter/services/gamebanana/file_selection.dart';
import 'package:mod_manager_flutter/services/gamebanana/gamebanana_client.dart';
import 'package:mod_manager_flutter/utils/marketplace_providers.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

import 'support/fake_http_transport.dart';
import 'support/fixtures.dart';

/// The `Mod/Multi` enrichment that fills out a Browse card: download count, category and files, which a listing
/// does not carry. Parsed from two captured responses (2026-10-21): one for the ids of `mod_index_p1`, and one for
/// a page of the newest mods plus the withheld mod 581980.
void main() {
  List<GbMod> records(String fixture) => parseBareList(loadGbFixture(fixture), GbMod.fromJson);

  group('the captured page', () {
    final enriched = enrichmentByMod(records('mod_multi_enrich_p1'));

    test('every mod of the listing page comes back', () {
      final listed = parseEnvelope(loadGbFixture('mod_index_p1'), GbMod.fromJson).records.map((m) => m.idRow);
      expect(enriched.keys, unorderedEquals(listed));
    });

    test('carries the download count the listing lacks', () {
      expect(enriched[533785]!.downloadCount, 151081);
      expect(enriched[537466]!.downloadCount, 903016);
    });

    test("carries the character for a skin, and the root for a mod filed under one", () {
      expect(enriched[533785]!.category?.name, 'Ellen Joe');
      expect(enriched[541825]!.category?.name, 'Jane Doe');
      expect(enriched[527935]!.category?.name, 'Other/Misc');
      expect(enriched[537466]!.category?.name, 'Character Skins');
    });

    test('folds archived files in with current ones, told apart by the flag', () {
      final jane = enriched[541825]!;
      expect(jane.files, hasLength(8));
      expect(jane.currentFiles, hasLength(4));
    });

    test('a mod with several current files has no file to install', () {
      expect(selectDefaultFile(enriched[541825]!.files).file, isNull);
      expect(selectDefaultFile(enriched[533785]!.files).file, isNull);
    });
  });

  group('the captured newest page', () {
    final enriched = enrichmentByMod(records('mod_multi_enrich_newest'));

    test('a mod with one current file names it', () {
      expect(selectDefaultFile(enriched[730505]!.files).file?.idRow, 1858310);
    });

    test("a day-old mod's zero downloads is a count, not a blank", () {
      expect(enriched[730505]!.downloadCount, 0);
    });

    test('the withheld mod comes back blank and is left out', () {
      final blank = records('mod_multi_enrich_newest').firstWhere((m) => m.idRow == 581980);
      expect(blank.downloadCount, isNull);
      expect(blank.category, isNull);
      expect(enriched.containsKey(581980), isFalse);
      expect(enriched, hasLength(15));
    });
  });

  group('the provider', () {
    test('asks for the four properties, once per id list', () async {
      final transport = FakeHttpTransport()..stubAnything(body: loadGbFixture('mod_multi_enrich_p1'));
      final container = ProviderContainer(
        overrides: [gameBananaClientProvider.overrideWithValue(GameBananaClient(transport: transport))],
      );
      addTearDown(container.dispose);

      const key = ModIdList([527935, 537466, 541825, 533785, 571038]);
      final sub = container.listen(modEnrichmentProvider(key), (_, _) {});
      addTearDown(sub.close);
      final map = await container.read(modEnrichmentProvider(key).future);
      // Built at run time, so it is equal to the key without being the same object.
      final equal = ModIdList([for (final id in key.ids) id]);
      expect(equal, isNot(same(key)));
      await container.read(modEnrichmentProvider(equal).future);

      expect(map, hasLength(5));
      expect(transport.callCount, 1, reason: 'an equal id list is the same provider');
      final sent = transport.requests.single.toString();
      expect(sent, contains('Mod/Multi'));
      expect(Uri.decodeFull(sent), contains('_csvProperties=_idRow,_nDownloadCount,_aCategory,_aFiles'));
    });

    test('a failed request is no enrichment, not an error', () async {
      final transport = FakeHttpTransport()..stubAnything(statusCode: 500, body: '{}');
      final container = ProviderContainer(
        overrides: [gameBananaClientProvider.overrideWithValue(GameBananaClient(transport: transport, maxRetries: 0))],
      );
      addTearDown(container.dispose);

      const key = ModIdList([1, 2]);
      final sub = container.listen(modEnrichmentProvider(key), (_, _) {});
      addTearDown(sub.close);
      expect(await container.read(modEnrichmentProvider(key).future), isEmpty);
    });
  });
}
