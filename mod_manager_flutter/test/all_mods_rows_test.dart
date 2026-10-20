import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/l10n/app_localizations.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_mod.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_submitter.dart';
import 'package:mod_manager_flutter/models/mod_ingest.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/screens/all_mods/all_mods_rows.dart';
import 'package:mod_manager_flutter/services/platform_service.dart';
import 'package:mod_manager_flutter/services/update_check.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';
import 'package:mod_manager_flutter/utils/zzz_characters.dart';

import 'support/origin_shorthand.dart';

/// The All mods table's pure half: what each chip counts, what the search and the filters keep, what the Updates
/// column says, the sort and the grouping.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppLocalizations loc;

  setUpAll(() async {
    loc = AppLocalizations(const Locale('en'));
    await loc.load();
  });

  ModInfo mod(
    String name, {
    String characterId = 'ellen',
    bool active = false,
    bool favorite = false,
    int? modId,
  }) =>
      ModInfo(
        id: name,
        name: name,
        characterId: characterId,
        isActive: active,
        isFavorite: favorite,
        origin: modId == null
            ? null
            : originFixture(
                modId: modId,
                modIdConfidence: OriginConfidence.user,
                fileId: 10,
                versionConfidence: OriginConfidence.user,
                provenance: OriginProvenance.downloaded,
              ),
      );

  const missing = [DeadModLink(name: 'Gone', target: '/drive/Gone')];

  AllModsContext session({
    Map<String, UpdateCheck> checks = const {},
    Map<int, GbMod> pages = const {},
    Map<String, int> sizes = const {},
  }) =>
      AllModsContext(checks: checks, pages: pages, sizes: sizes, loc: loc);

  List<String> names(List<AllModsRow> rows) => [for (final row in rows) row.name];

  List<AllModsRow> visible({
    required List<ModInfo> mods,
    List<DeadModLink> dead = const [],
    AllModsFilter filter = AllModsFilter.all,
    String search = '',
    AllModsSort sort = const AllModsSort(AllModsColumn.name, descending: false),
    AllModsContext? context,
  }) =>
      visibleAllModsRows(
        mods: mods,
        missing: dead,
        filter: filter,
        search: search,
        sort: sort,
        session: context ?? session(),
      );

  group('the counts', () {
    final library = [
      mod('on', active: true, modId: 1),
      mod('off starred', favorite: true, modId: 2),
      mod('untracked'),
    ];

    test('count every chip over the whole table, All counting mods only, as the sidebar and the header do', () {
      final counts = countAllMods(library, missing, const {});
      expect(counts.all, 3, reason: 'the missing folder is listed under All but is not a mod');
      expect(counts.active, 1);
      expect(counts.off, 2);
      expect(counts.folderMissing, 1);
      expect(counts.favorites, 1);
      expect(counts.needsAttention, 1, reason: 'only the untracked mod');
    });

    test('have no Updates number before any check', () {
      // "0 updates" would claim a check ran.
      expect(countAllMods(library, missing, const {}).updates, isNull);
      expect(countAllMods(library, missing, const {}).of(AllModsFilter.updates), isNull);
    });

    test('count the mods with an update once a check ran', () {
      final checks = {
        'on': const UpdateCheck(outcome: UpdateOutcome.updateAvailable),
        'off starred': const UpdateCheck(outcome: UpdateOutcome.upToDate),
      };
      expect(countAllMods(library, missing, checks).updates, 1);
    });

    test('a check that found nothing counts zero', () {
      final checks = {'on': const UpdateCheck(outcome: UpdateOutcome.upToDate)};
      expect(countAllMods(library, missing, checks).updates, 0);
    });
  });

  group('the search', () {
    final library = [
      mod('Swimsuit', modId: 1),
      mod('Kimono', characterId: 'miyabi', modId: 2),
      mod('Hairpin', characterId: 'cat_ui'),
    ];
    final pages = {1: const GbMod(idRow: 1, submitter: GbSubmitter(idRow: 9, name: 'Gloomy'))};

    test('matches the name, ignoring case', () {
      expect(names(visible(mods: library, search: 'kimONO')), ['Kimono']);
    });

    test("doesn't match the author, which nobody searches by", () {
      expect(names(visible(mods: library, search: 'gloomy', context: session(pages: pages))), isEmpty);
    });

    test('matches the character', () {
      expect(names(visible(mods: library, search: 'miyabi')), ['Kimono']);
    });

    test('matches a missing folder by its name only', () {
      expect(names(visible(mods: library, dead: missing, search: 'gone')), ['Gone']);
      expect(names(visible(mods: library, dead: missing, search: 'drive')), isEmpty);
    });
  });

  group("a heading's presses", () {
    test('pick a column in its natural direction, reverse it, then clear the sort', () {
      final first = AllModsSort.next(null, AllModsColumn.name);
      expect(first, const AllModsSort(AllModsColumn.name, descending: false));
      final second = AllModsSort.next(first, AllModsColumn.name);
      expect(second, const AllModsSort(AllModsColumn.name, descending: true));
      expect(AllModsSort.next(second, AllModsColumn.name), isNull);
    });

    test('start a number or a date largest first', () {
      expect(AllModsSort.next(null, AllModsColumn.size), const AllModsSort(AllModsColumn.size, descending: true));
    });

    test('start Updates most needed first, reverse it, then go back to newest added first', () {
      final first = AllModsSort.next(null, AllModsColumn.updates);
      expect(first, const AllModsSort(AllModsColumn.updates, descending: false));
      final second = AllModsSort.next(first, AllModsColumn.updates);
      expect(second, const AllModsSort(AllModsColumn.updates, descending: true));
      expect(AllModsSort.next(second, AllModsColumn.updates), isNull);
    });

    test('on another column start that one afresh', () {
      const bySize = AllModsSort(AllModsColumn.size, descending: false);
      expect(AllModsSort.next(bySize, AllModsColumn.status), const AllModsSort(AllModsColumn.status, descending: false));
    });
  });

  group('the sort', () {
    final library = [mod('a'), mod('b'), mod('c'), mod('no size')];
    final sizes = {'a': 10, 'b': 30, 'c': 20};

    test('puts the rows with no value last, ascending', () {
      final rows = visible(
        mods: library,
        dead: missing,
        sort: const AllModsSort(AllModsColumn.size, descending: false),
        context: session(sizes: sizes),
      );
      expect(names(rows), ['a', 'c', 'b', 'Gone', 'no size']);
    });

    test('and descending', () {
      final rows = visible(
        mods: library,
        dead: missing,
        sort: const AllModsSort(AllModsColumn.size, descending: true),
        context: session(sizes: sizes),
      );
      expect(names(rows), ['b', 'c', 'a', 'Gone', 'no size']);
    });

    test('ties fall back to the name', () {
      final rows = visible(
        mods: [mod('b'), mod('a')],
        sort: const AllModsSort(AllModsColumn.size, descending: true),
        context: session(sizes: {'a': 5, 'b': 5}),
      );
      expect(names(rows), ['a', 'b']);
    });

    test('by status is Active, Off, then Folder missing, and the reverse descending', () {
      final mods = [mod('off'), mod('on', active: true)];
      expect(
        names(visible(mods: mods, dead: missing, sort: const AllModsSort(AllModsColumn.status, descending: false))),
        ['on', 'off', 'Gone'],
      );
      expect(
        names(visible(mods: mods, dead: missing, sort: const AllModsSort(AllModsColumn.status, descending: true))),
        ['Gone', 'off', 'on'],
      );
    });
  });

  group('the grouping', () {
    List<AllModsRow> rows() => visible(
      mods: [
        mod('ui', characterId: 'cat_ui', active: true),
        mod('unassigned', characterId: unknownCharacterId),
        mod('ellen on', active: true),
        mod('ellen off'),
      ],
      dead: missing,
    );

    test('by character follows the character list, with a missing folder under Unassigned', () {
      final groups = groupAllModsRows(rows(), AllModsGrouping.character, loc);
      expect([for (final g in groups) g.id], ['ellen', 'cat_ui', unknownCharacterId]);
      expect(names(groups.first.rows), ['ellen off', 'ellen on']);
      expect(names(groups.last.rows), ['Gone', 'unassigned']);
      expect(groups.first.characterId, 'ellen');
    });

    test('leaves out an empty group', () {
      final groups = groupAllModsRows(visible(mods: [mod('off')]), AllModsGrouping.character, loc);
      expect([for (final g in groups) g.id], ['ellen']);
    });
  });

  group('the Updates column', () {
    ModInfo withOrigin(String name, ModOrigin? origin) =>
        ModInfo(id: name, name: name, characterId: 'ellen', isActive: false, origin: origin);

    ModOrigin onFile(OriginConfidence versionConfidence) => originFixture(
          modId: 1,
          modIdConfidence: OriginConfidence.user,
          fileId: 10,
          versionConfidence: versionConfidence,
        );

    final local = withOrigin('local', originFixture(modId: 1, tracking: OriginTracking.off));
    final untracked = withOrigin('untracked', null);
    final whichFile = withOrigin('which', originFixture(modId: 1, modIdConfidence: OriginConfidence.user));
    final patch = withOrigin(
      'patch',
      originFixture(
        modId: 1,
        modIdConfidence: OriginConfidence.user,
        fileId: 10,
        versionConfidence: OriginConfidence.user,
        ingest: const ModIngest(patchShaped: true),
      ),
    );
    final known = withOrigin('known', onFile(OriginConfidence.exact));
    final dated = withOrigin('dated', onFile(OriginConfidence.assumedLatest));
    final guessed = withOrigin('guessed', onFile(OriginConfidence.inferred));

    UpdateCheck verdict(UpdateOutcome outcome, {bool dismissed = false}) =>
        UpdateCheck(outcome: outcome, dismissed: dismissed);

    test('a Local mod is Local, whatever a check said', () {
      expect(updatesCellOf(local, null), UpdatesCell.local);
      expect(updatesCellOf(local, verdict(UpdateOutcome.updateAvailable)), UpdatesCell.local);
    });

    test('an untracked mod is Not tracked', () {
      expect(updatesCellOf(untracked, null), UpdatesCell.notTracked);
      expect(updatesCellOf(untracked, verdict(UpdateOutcome.untracked)), UpdatesCell.notTracked);
    });

    test('Which file? stays the prompt, even beside an update', () {
      expect(updatesCellOf(whichFile, null), UpdatesCell.whichFile);
      expect(updatesCellOf(whichFile, verdict(UpdateOutcome.updateAvailable)), UpdatesCell.whichFile);
    });

    test("Base unknown is the prompt until the patch's page has a live update", () {
      expect(updatesCellOf(patch, null), UpdatesCell.baseUnknown);
      expect(updatesCellOf(patch, verdict(UpdateOutcome.tracksPatchOnly)), UpdatesCell.baseUnknown);
      expect(updatesCellOf(patch, verdict(UpdateOutcome.updateAvailable)), UpdatesCell.newerFile);
      expect(updatesCellOf(patch, verdict(UpdateOutcome.possiblyOutdated)), UpdatesCell.maybeNewer);
      expect(updatesCellOf(patch, verdict(UpdateOutcome.updateAvailable, dismissed: true)), UpdatesCell.baseUnknown);
    });

    test('a known, guessed or dated file with no check has no verdict', () {
      for (final mod in [known, guessed, dated]) {
        expect(updatesCellOf(mod, null), UpdatesCell.unchecked, reason: mod.name);
      }
    });

    test("a known, guessed or dated file reads the check's verdict", () {
      for (final mod in [known, guessed, dated]) {
        expect(updatesCellOf(mod, verdict(UpdateOutcome.updateAvailable)), UpdatesCell.newerFile, reason: mod.name);
        expect(updatesCellOf(mod, verdict(UpdateOutcome.possiblyOutdated)), UpdatesCell.maybeNewer, reason: mod.name);
        expect(updatesCellOf(mod, verdict(UpdateOutcome.upToDate)), UpdatesCell.upToDate, reason: mod.name);
        expect(updatesCellOf(mod, verdict(UpdateOutcome.sourceGone)), UpdatesCell.notOnGameBanana, reason: mod.name);
        expect(updatesCellOf(mod, verdict(UpdateOutcome.indeterminate)), UpdatesCell.couldntCheck, reason: mod.name);
      }
    });

    test('an ignored update reads Up to date', () {
      expect(updatesCellOf(known, verdict(UpdateOutcome.updateAvailable, dismissed: true)), UpdatesCell.upToDate);
      expect(updatesCellOf(guessed, verdict(UpdateOutcome.possiblyOutdated, dismissed: true)), UpdatesCell.upToDate);
    });

    test("an ignored update in one layer of two reads Couldn't check when the other couldn't be checked", () {
      final stacked = withOrigin(
        'stacked',
        originFixture(
          modId: 1,
          modIdConfidence: OriginConfidence.user,
          fileId: 10,
          versionConfidence: OriginConfidence.user,
          patches: [patchFixture(modId: 2, fileId: 20, versionConfidence: OriginConfidence.user)],
        ),
      );
      final layers = stacked.origin!.downloads;
      final folded = foldDownloads([
        DownloadCheck(download: layers[0], check: verdict(UpdateOutcome.updateAvailable, dismissed: true)),
        DownloadCheck(download: layers[1], check: verdict(UpdateOutcome.indeterminate)),
      ]);
      expect(updatesCellOf(stacked, folded), UpdatesCell.couldntCheck);
    });

    test('a verdict about tracking the mod no longer has is no verdict', () {
      expect(updatesCellOf(known, verdict(UpdateOutcome.versionUnknown)), UpdatesCell.unchecked);
    });

    group('sorted', () {
      final library = [known, guessed, dated, whichFile, patch, untracked, local, withOrigin('unchecked', onFile(OriginConfidence.exact))];
      final checks = {
        'known': verdict(UpdateOutcome.upToDate),
        'guessed': verdict(UpdateOutcome.possiblyOutdated),
        'dated': verdict(UpdateOutcome.updateAvailable),
      };

      test('by need, with the rows that have no verdict last', () {
        final rows = visible(
          mods: library,
          dead: missing,
          sort: AllModsSort.next(null, AllModsColumn.updates)!,
          context: session(checks: checks),
        );
        expect(names(rows), ['dated', 'guessed', 'which', 'patch', 'untracked', 'known', 'local', 'Gone', 'unchecked']);
      });

      test('reversed, still with the rows that have no verdict last', () {
        final first = AllModsSort.next(null, AllModsColumn.updates);
        final rows = visible(
          mods: library,
          dead: missing,
          sort: AllModsSort.next(first, AllModsColumn.updates)!,
          context: session(checks: checks),
        );
        expect(names(rows), ['local', 'known', 'untracked', 'patch', 'which', 'guessed', 'dated', 'Gone', 'unchecked']);
      });

      test('puts Not on GameBanana and Couldn\'t check between Not tracked and Up to date', () {
        final rows = visible(
          mods: [
            withOrigin('a gone', onFile(OriginConfidence.exact)),
            withOrigin('b silent', onFile(OriginConfidence.exact)),
            known,
            untracked,
          ],
          sort: const AllModsSort(AllModsColumn.updates, descending: false),
          context: session(checks: {
            'a gone': verdict(UpdateOutcome.sourceGone),
            'b silent': verdict(UpdateOutcome.indeterminate),
            'known': verdict(UpdateOutcome.upToDate),
          }),
        );
        expect(names(rows), ['untracked', 'a gone', 'b silent', 'known']);
      });
    });
  });

  test('a missing folder is listed under All and Folder missing only', () {
    final library = [
      mod('on', active: true, favorite: true),
      mod('untracked'),
    ];
    final checks = {'on': const UpdateCheck(outcome: UpdateOutcome.updateAvailable)};
    for (final filter in AllModsFilter.values) {
      final rows = visible(mods: library, dead: missing, filter: filter, context: session(checks: checks));
      final listed = rows.whereType<MissingRow>().isNotEmpty;
      expect(listed, filter == AllModsFilter.all || filter == AllModsFilter.folderMissing, reason: '$filter');
    }
    expect(
      names(visible(mods: library, dead: missing, filter: AllModsFilter.folderMissing)),
      ['Gone'],
      reason: 'Folder missing lists no mod',
    );
  });
}
