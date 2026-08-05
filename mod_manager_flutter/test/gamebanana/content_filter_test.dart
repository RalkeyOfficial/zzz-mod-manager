import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_enums.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_mod.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_page.dart';
import 'package:mod_manager_flutter/services/gamebanana/content_filter.dart';

import '../support/fixtures.dart';

/// The NSFW filter. GameBanana applies none of its own — it ships a rendering
/// hint and trusts the client — so this matrix is the whole filter, and the
/// corners nobody clicks through by hand are exactly where it would rot.
void main() {
  group('ContentFilterMode.parse', () {
    test('round-trips every wire value', () {
      for (final mode in ContentFilterMode.values) {
        expect(ContentFilterMode.parse(mode.wire), mode);
      }
    });

    test('anything unrecognised fails to blur, not to show', () {
      // Failing to `show` would un-blur adult content on a corrupt setting;
      // failing to `hide` would silently empty the grid. Blur is wrong in
      // neither direction.
      for (final value in <Object?>[null, '', 'SHOW', 'nsfw', 42, true, []]) {
        expect(ContentFilterMode.parse(value), ContentFilterMode.blur,
            reason: 'parse($value)');
      }
    });
  });

  group('contentTreatment', () {
    test('an unflagged mod always renders, whatever the setting', () {
      for (final mode in ContentFilterMode.values) {
        expect(
          contentTreatment(GbVisibility.show, mode),
          ContentTreatment.show,
          reason: 'show + $mode',
        );
      }
    });

    test('blur mode blurs both warn and hide', () {
      expect(contentTreatment(GbVisibility.warn, ContentFilterMode.blur),
          ContentTreatment.blur);
      expect(contentTreatment(GbVisibility.hide, ContentFilterMode.blur),
          ContentTreatment.blur);
    });

    test('show mode overrides the hint completely, including hide', () {
      // A setting called "show everything" that still hid a subset would be a
      // setting that lies.
      expect(contentTreatment(GbVisibility.warn, ContentFilterMode.show),
          ContentTreatment.show);
      expect(contentTreatment(GbVisibility.hide, ContentFilterMode.show),
          ContentTreatment.show);
    });

    test('hide mode omits both warn and hide', () {
      expect(contentTreatment(GbVisibility.warn, ContentFilterMode.hide),
          ContentTreatment.omit);
      expect(contentTreatment(GbVisibility.hide, ContentFilterMode.hide),
          ContentTreatment.omit);
    });
  });

  group('against real captured responses', () {
    test('listing records carry the hint, so the grid can filter offline', () {
      // If listings omitted _sInitialVisibility, GbMod.effectiveVisibility would
      // fail closed to `warn` and blur the entire grid. They don't — asserted
      // here because the whole filter silently degrades to "blur everything" if
      // that ever changes upstream.
      final page = parseEnvelope(loadGbFixture('mod_index_p1'), GbMod.fromJson);
      expect(page.records, isNotEmpty);
      for (final mod in page.records) {
        expect(mod.visibility, isNotNull, reason: 'mod ${mod.idRow}');
      }
    });

    test('a captured page is mostly flagged, so the default must be usable', () {
      // 4 of these 5 records are `hide`. A default of "omit" would show the user
      // an almost-empty marketplace on first launch, which is why the default is
      // blur-and-reveal.
      final page = parseEnvelope(loadGbFixture('mod_index_p1'), GbMod.fromJson);
      final omitted = page.records
          .where((m) =>
              contentTreatment(m.effectiveVisibility, ContentFilterMode.hide) ==
              ContentTreatment.omit)
          .length;
      expect(omitted, 4);

      final blurred = page.records
          .where((m) =>
              contentTreatment(m.effectiveVisibility, ContentFilterMode.blur) ==
              ContentTreatment.blur)
          .length;
      expect(blurred, 4);
    });

    test('a rated profile names its reasons; listings only flag a boolean', () {
      // The detail view can say *why* a mod is flagged; a card cannot, because
      // _aContentRatings is absent from listing records.
      final rated = GbMod.fromJson(parseObject(loadGbFixture('mod_profile_rated')))!;
      expect(rated.effectiveVisibility, GbVisibility.warn);
      expect(rated.contentRatings, {'sa': 'Skimpy Attire'});

      final page = parseEnvelope(loadGbFixture('mod_index_p1'), GbMod.fromJson);
      final flagged = page.records.where((m) => m.hasContentRatings);
      expect(flagged, isNotEmpty);
      expect(flagged.every((m) => m.contentRatings.isEmpty), isTrue,
          reason: 'listings flag but never explain');
    });
  });
}
