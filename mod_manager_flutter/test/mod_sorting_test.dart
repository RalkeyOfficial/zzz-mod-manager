import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/utils/mod_sorting.dart';

import 'support/origin_shorthand.dart';

/// "Recently added", over a library where most mods have no date at all.
///
/// The undated majority is the case that decides the design: a library that has
/// never had a `source_url` pasted into it has no origin block anywhere, and a
/// sort that shuffled those on every scan would be worse than the arbitrary
/// order it replaced.
void main() {
  ModInfo mod(String name, {DateTime? installedAt, bool proxy = false}) =>
      ModInfo(
        id: name,
        name: name,
        characterId: 'ellen',
        isActive: false,
        origin: installedAt == null
            ? null
            : ModOrigin(
                provenance: OriginProvenance.downloaded,
                installedAt: installedAt,
                installedAtIsProxy: proxy,
              ),
      );

  List<String> namesOf(List<ModInfo> mods) => [for (final m in mods) m.name];

  DateTime day(int d) => DateTime(2026, 1, d);

  test('newest first', () {
    final sorted = sortedByInstallDate([
      mod('Oldest', installedAt: day(1)),
      mod('Newest', installedAt: day(9)),
      mod('Middle', installedAt: day(5)),
    ]);

    expect(namesOf(sorted), ['Newest', 'Middle', 'Oldest']);
  });

  test('undated mods go last, keeping the order they arrived in', () {
    // Not alphabetical, deliberately: their existing scan order is the only
    // thing that describes them, and replacing it with a different arbitrary
    // order gains nothing.
    final sorted = sortedByInstallDate([
      mod('Zebra'),
      mod('Dated', installedAt: day(3)),
      mod('Apple'),
      mod('Mango'),
    ]);

    expect(namesOf(sorted), ['Dated', 'Zebra', 'Apple', 'Mango']);
  });

  test('a library with no dates at all is left exactly as it was', () {
    // The common case for a legacy library, and the one where doing nothing is
    // the right answer.
    final input = [mod('C'), mod('A'), mod('B')];
    expect(namesOf(sortedByInstallDate(input)), ['C', 'A', 'B']);
  });

  test('equal dates break ties by name rather than by luck', () {
    // One archive installing as several mods gives them the same timestamp to
    // the second, and Dart's sort is not stable — without the tiebreak these
    // could come back in a different order on the next scan.
    final sorted = sortedByInstallDate([
      mod('Charlie', installedAt: day(4)),
      mod('alpha', installedAt: day(4)),
      mod('Bravo', installedAt: day(4)),
    ]);

    expect(namesOf(sorted), ['alpha', 'Bravo', 'Charlie']);
  });

  test('the order is the same however the input is arranged', () {
    // The property the tiebreak exists for, stated directly.
    final a = sortedByInstallDate([
      mod('One', installedAt: day(4)),
      mod('Two', installedAt: day(4)),
      mod('Three', installedAt: day(4)),
    ]);
    final b = sortedByInstallDate([
      mod('Three', installedAt: day(4)),
      mod('One', installedAt: day(4)),
      mod('Two', installedAt: day(4)),
    ]);

    expect(namesOf(a), namesOf(b));
  });

  test('a proxy date sorts alongside a real one', () {
    // The backfill's date is the oldest file mtime, which can read years early
    // — but demoting it to "undated" would drop most of a legacy library into
    // the tail, which is the state the backfill exists to get out of.
    final sorted = sortedByInstallDate([
      mod('Real', installedAt: day(2)),
      mod('Proxy', installedAt: day(7), proxy: true),
    ]);

    expect(namesOf(sorted), ['Proxy', 'Real']);
  });

  test('an origin block with no date counts as undated', () {
    // `tracking: off` and a freshly resolved identity both produce one.
    final withOrigin = ModInfo(
      id: 'Tracked',
      name: 'Tracked',
      characterId: 'ellen',
      isActive: false,
      origin: originFixture(
        provenance: OriginProvenance.importedFolder,
        modId: 5,
      ),
    );

    final sorted = sortedByInstallDate([
      withOrigin,
      mod('Dated', installedAt: day(1)),
    ]);

    expect(namesOf(sorted), ['Dated', 'Tracked']);
  });

  test('an empty library sorts to an empty library', () {
    expect(sortedByInstallDate([]), isEmpty);
  });
}
