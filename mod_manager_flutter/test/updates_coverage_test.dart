import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_file.dart';
import 'package:mod_manager_flutter/models/mod_download.dart';
import 'package:mod_manager_flutter/models/mod_ingest.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/screens/updates/updates_coverage.dart';
import 'package:mod_manager_flutter/services/update_check.dart';

import 'support/origin_shorthand.dart';

/// The Updates page's sorting of the library: which mods the app can check, and which have a newer file.
void main() {
  final added = DateTime.utc(2026, 5, 8);

  ModOrigin tracked({
    OriginConfidence versionConfidence = OriginConfidence.unknown,
    List<ModDownload> patches = const [],
    ModIngest? ingest,
    OriginTracking tracking = OriginTracking.auto,
  }) =>
      originFixture(
        modId: 1,
        modIdConfidence: OriginConfidence.user,
        fileId: versionConfidence == OriginConfidence.unknown ? null : 10,
        versionConfidence: versionConfidence,
        installedAt: added,
        ingest: ingest,
        tracking: tracking,
        patches: patches,
      );

  ModInfo mod(String name, [ModOrigin? origin]) =>
      ModInfo(id: name, name: name, characterId: 'ellen', isActive: false, origin: origin);

  group('a mod\'s cell', () {
    test('a known or worked-out file is checked, a date alone is dated only', () {
      expect(coverageOf(mod('a', tracked(versionConfidence: OriginConfidence.exact))), CoverageKind.checked);
      expect(coverageOf(mod('a', tracked(versionConfidence: OriginConfidence.user))), CoverageKind.checked);
      expect(coverageOf(mod('a', tracked(versionConfidence: OriginConfidence.inferred))), CoverageKind.checked);
      expect(coverageOf(mod('a', tracked(versionConfidence: OriginConfidence.assumedLatest))), CoverageKind.datedOnly);
    });

    test('the questions are their own cells', () {
      expect(coverageOf(mod('a', tracked())), CoverageKind.whichFile);
      expect(coverageOf(mod('a')), CoverageKind.notTracked);
      expect(
        coverageOf(mod('a', tracked(versionConfidence: OriginConfidence.exact, ingest: const ModIngest(patchShaped: true)))),
        CoverageKind.baseUnknown,
      );
    });

    test('a folder is checked only when every layer is', () {
      final patch = const ModDownload(modId: 2, modIdConfidence: OriginConfidence.user);
      expect(
        coverageOf(mod('a', tracked(versionConfidence: OriginConfidence.exact, patches: [patch]))),
        CoverageKind.whichFile,
      );
    });

    test('a Local mod has no cell', () {
      expect(coverageOf(mod('a', tracked(tracking: OriginTracking.off))), isNull);
    });
  });

  const answered = UpdateCheck(outcome: UpdateOutcome.upToDate);

  test('the strip runs checked, dated only, not checked yet, which file?, base unknown, not tracked', () {
    final coverage = coverageFor(
      [
        mod('untracked'),
        mod('b which', tracked()),
        mod('local', tracked(tracking: OriginTracking.off)),
        mod('dated', tracked(versionConfidence: OriginConfidence.assumedLatest)),
        mod('a which', tracked()),
        mod('known', tracked(versionConfidence: OriginConfidence.exact)),
        mod('waiting', tracked(versionConfidence: OriginConfidence.exact)),
      ],
      {'known': answered, 'dated': answered},
    );

    expect(
      [for (final (m, _) in coverage.cells) m.name],
      ['known', 'dated', 'waiting', 'a which', 'b which', 'untracked'],
    );
    expect(coverage.total, 6);
    expect(coverage.local, 1);
    expect(coverage.checked, 2, reason: 'dated only counts as checked');
    expect(coverage.count(CoverageKind.unchecked), 1);
    expect(coverage.count(CoverageKind.whichFile), 2);
  });

  group('the pills', () {
    test('start as empty pills with the mods that can\'t be checked after them', () {
      final pills = coveragePills(
        [CoverageKind.unchecked, CoverageKind.unchecked, CoverageKind.whichFile],
        minimum: 5,
      );
      expect(pills, [null, null, null, null, CoverageKind.whichFile]);
    });

    test('take an empty pill\'s place for each mod checked, then grow a pill per mod', () {
      List<CoverageKind?> kinds(int checked) => coveragePills([
            for (var i = 0; i < 6; i++) i < checked ? CoverageKind.checked : CoverageKind.unchecked,
            CoverageKind.whichFile,
          ], minimum: 5);
      expect(kinds(2), [CoverageKind.checked, CoverageKind.checked, null, null, CoverageKind.whichFile]);
      expect(kinds(4), [...List.filled(4, CoverageKind.checked), CoverageKind.whichFile]);
      expect(kinds(6), [...List.filled(6, CoverageKind.checked), CoverageKind.whichFile], reason: 'past the minimum');
    });
  });

  group('the pills that change', () {
    const c = CoverageKind.checked;
    const w = CoverageKind.whichFile;

    test('are the places that now show something else, from the left', () {
      expect(pillChanges([null, null, null, null, w], [c, c, null, null, w]), [(0, null, 0), (1, null, 1)]);
      expect(pillChanges([c, c, null, null, w], [c, c, c, null, w]), [(2, null, 2)],
          reason: "a mod sorted in among the checked ones doesn't move the colours already there");
    });

    test('as the strip grows, the new places fill and the questions keep theirs', () {
      // Places 4 and 5 are new, so they fade from empty, not from the blue pill that sat at 4 before.
      expect(pillChanges([c, c, c, c, w], [c, c, c, c, c, c, w]), [(4, null, null), (5, null, null)]);
    });

    test('a question settled since leaves an empty pill, not a change', () {
      expect(pillChanges([c, null, w], [c, null, null]), isEmpty);
    });

    test('each place is followed to where it was, so a fade keeps to its own pill', () {
      // The strip grows by two: the questions move two places right, the rest stay.
      expect(pillPlacesBefore([c, c, w, w], [c, c, c, c, w, w]), [0, 1, null, null, 2, 3]);
      // And shrinks back.
      expect(pillPlacesBefore([c, c, c, c, w, w], [c, c, w, w]), [0, 1, 4, 5]);
    });
  });

  group('a mod the app can check', () {
    final known = mod('known', tracked(versionConfidence: OriginConfidence.exact));

    test('is not checked until this session has an answer from its page', () {
      expect(coverageFor([known], const {}).cells.single.$2, CoverageKind.unchecked);
      for (final outcome in [UpdateOutcome.updateAvailable, UpdateOutcome.upToDate, UpdateOutcome.sourceGone]) {
        expect(coverageFor([known], {'known': UpdateCheck(outcome: outcome)}).cells.single.$2, CoverageKind.checked);
      }
    });

    test("isn't checked by a page that couldn't be compared, or a verdict about other tracking", () {
      for (final outcome in [UpdateOutcome.indeterminate, UpdateOutcome.versionUnknown, UpdateOutcome.untracked]) {
        expect(
          coverageFor([known], {'known': UpdateCheck(outcome: outcome)}).cells.single.$2,
          CoverageKind.unchecked,
          reason: '$outcome',
        );
      }
    });

    test("isn't checked by date the moment it is marked, though the patch on it had an update", () {
      final marked = mod(
        'marked',
        tracked(
          versionConfidence: OriginConfidence.assumedLatest,
          patches: [patchFixture(modId: 2, fileId: 20, versionConfidence: OriginConfidence.user)],
        ),
      );
      final origin = marked.origin!;
      // The verdict from before the marking: the base asked which file, the patch had a newer one.
      final held = foldDownloads([
        DownloadCheck(
          download: origin.downloads[0],
          key: origin.keyAt(0),
          check: const UpdateCheck(outcome: UpdateOutcome.versionUnknown),
        ),
        DownloadCheck(
          download: origin.downloads[1],
          key: origin.keyAt(1),
          check: const UpdateCheck(outcome: UpdateOutcome.updateAvailable),
        ),
      ]);
      expect(coverageOf(marked), CoverageKind.datedOnly);
      expect(coverageFor([marked], {'marked': held}).cells.single.$2, CoverageKind.unchecked);
    });

    test('is checked as soon as the running check reaches it', () {
      expect(coverageFor([known], const {}, reached: {'known'}).cells.single.$2, CoverageKind.checked);
    });

    test('a question needs no check to be drawn', () {
      expect(coverageFor([mod('which', tracked())], const {}).cells.single.$2, CoverageKind.whichFile);
    });
  });

  test('newer files are the mods with an update to show, the newest upload first', () {
    UpdateCheck found(DateTime uploaded, {bool dismissed = false}) => UpdateCheck(
          outcome: UpdateOutcome.updateAvailable,
          newerFiles: [GbFile(idRow: 1, dateAdded: uploaded)],
          dismissed: dismissed,
        );
    final mods = [mod('older'), mod('newer'), mod('ignored'), mod('current'), mod('unchecked')];
    final found_ = newerFilesOf(mods, {
      'older': found(DateTime.utc(2026, 8)),
      'newer': found(DateTime.utc(2026, 10)),
      'ignored': found(DateTime.utc(2026, 9), dismissed: true),
      'current': const UpdateCheck(outcome: UpdateOutcome.upToDate),
    });
    expect([for (final (m, _) in found_) m.name], ['newer', 'older']);
  });
}
