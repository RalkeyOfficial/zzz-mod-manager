import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_enums.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_page.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_top_sub.dart';
import 'package:mod_manager_flutter/services/gamebanana/content_filter.dart';

import '../support/fixtures.dart';

/// `Game/<id>/TopSubs` — the "best of period" list behind the featured carousel.
///
/// Tested against a real captured response because this endpoint is undocumented
/// even by the standards of the rest of apiv11: it appears in no field list, takes
/// no parameters, and returns a shape that exists nowhere else in the API.
void main() {
  group('GbTopSubPeriod.parse', () {
    test('round-trips every wire value', () {
      for (final period in GbTopSubPeriod.values) {
        expect(GbTopSubPeriod.parse(period.wire), period);
      }
    });

    test('an unknown window is null, not a fallback member', () {
      // Null so the entry gets dropped. A fallback of `today` would relabel a new
      // upstream window as something it isn't, which is worse than omitting it.
      for (final value in <Object?>[null, '', 'decade', '2month', 42, true]) {
        expect(GbTopSubPeriod.parse(value), isNull, reason: 'parse($value)');
      }
    });

    test('declaration order is shortest window first', () {
      expect(GbTopSubPeriod.values.map((p) => p.wire).toList(), [
        'today',
        'week',
        'month',
        '3month',
        '6month',
        'year',
        'alltime',
      ]);
    });
  });

  group('parsing the captured response', () {
    late List<GbTopSub> subs;

    setUpAll(() {
      subs = parseBareList(loadGbFixture('topsubs_19567'), GbTopSub.fromJson);
    });

    test('yields 21 entries — three per window', () {
      expect(subs.length, 21);
      final groups = groupTopSubs(subs);
      expect(groups.length, GbTopSubPeriod.values.length);
      for (final group in groups) {
        expect(group.mods.length, 3, reason: group.period.wire);
      }
    });

    test('every entry carries what a tile needs', () {
      for (final sub in subs) {
        expect(sub.idRow, greaterThan(0));
        expect(sub.name, isNotNull);
        expect(sub.thumbnailUrl, isNotNull, reason: 'mod ${sub.idRow}');
        expect(sub.likeCount, isNotNull, reason: 'mod ${sub.idRow}');
        expect(sub.submitter?.name, isNotNull, reason: 'mod ${sub.idRow}');
      }
    });

    test('images are finished urls, not a base plus variants', () {
      // The reason this is its own DTO rather than a GbMod: there is no size
      // ladder to negotiate here.
      expect(subs.first.thumbnailUrl, startsWith('https://'));
      expect(subs.first.imageUrl, startsWith('https://'));
      expect(subs.first.thumbnailUrl, contains('220-'));
    });

    test('carries the visibility hint, so the filter applies', () {
      for (final sub in subs) {
        expect(sub.visibility, isNotNull, reason: 'mod ${sub.idRow}');
      }
    });

    test('the list skews heavily adult, so hiding empties it', () {
      // Load-bearing for the widget: with the filter on `hide`, almost nothing
      // survives, so the carousel must collapse rather than render empty headers.
      final flagged = subs
          .where((s) => s.effectiveVisibility.needsContentWarning)
          .length;
      expect(flagged, 20, reason: '20 of 21 captured entries are warn/hide');

      final surviving = subs.where((s) =>
          contentTreatment(s.effectiveVisibility, ContentFilterMode.hide) !=
          ContentTreatment.omit);
      expect(surviving.length, 1,
          reason: 'a single entry survives the hide filter');
    });

    test('only the root category is available, never a character', () {
      // Unlike Mod/Index there is no _aSubCategory here, so a tile cannot show a
      // character name.
      expect(subs.first.rootCategory?.name, isNotNull);
      expect(
        subs.map((s) => s.rootCategory?.name).whereType<String>(),
        everyElement(isNot('Ellen Joe')),
      );
    });

    test('a description is optional decoration, not a field to rely on', () {
      final withText = subs.where((s) => (s.description ?? '').isNotEmpty);
      expect(withText.length, lessThan(subs.length));
    });
  });

  group('groupTopSubs', () {
    GbTopSub sub(int id, GbTopSubPeriod period) =>
        GbTopSub(idRow: id, period: period, visibility: GbVisibility.show);

    test('orders by declaration, not by input order', () {
      final grouped = groupTopSubs([
        sub(1, GbTopSubPeriod.allTime),
        sub(2, GbTopSubPeriod.today),
        sub(3, GbTopSubPeriod.month),
      ]);
      expect(grouped.map((g) => g.period).toList(), [
        GbTopSubPeriod.today,
        GbTopSubPeriod.month,
        GbTopSubPeriod.allTime,
      ]);
    });

    test('omits windows with nothing in them', () {
      final grouped = groupTopSubs([sub(1, GbTopSubPeriod.week)]);
      expect(grouped.length, 1);
      expect(grouped.single.period, GbTopSubPeriod.week);
    });

    test('an empty input yields no groups at all', () {
      expect(groupTopSubs(const []), isEmpty);
    });

    test('preserves order within a window', () {
      final grouped = groupTopSubs([
        sub(10, GbTopSubPeriod.today),
        sub(11, GbTopSubPeriod.today),
        sub(12, GbTopSubPeriod.today),
      ]);
      expect(grouped.single.mods.map((m) => m.idRow).toList(), [10, 11, 12]);
    });
  });

  group('GbTopSub.fromJson', () {
    test('drops a row with no id', () {
      expect(GbTopSub.fromJson({'_sPeriod': 'today'}), isNull);
    });

    test('drops a row with an unrecognised period', () {
      expect(GbTopSub.fromJson({'_idRow': 1, '_sPeriod': 'fortnight'}), isNull);
    });

    test('an absent visibility field fails closed to warn', () {
      final sub = GbTopSub.fromJson({'_idRow': 1, '_sPeriod': 'today'})!;
      expect(sub.visibility, isNull);
      expect(sub.effectiveVisibility, GbVisibility.warn);
    });
  });
}
