import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_file.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_mod.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_page.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_update.dart';
import 'package:mod_manager_flutter/models/mod_companion.dart';
import 'package:mod_manager_flutter/models/mod_ingest.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/services/update_check.dart';

import 'support/fixtures.dart';
import 'support/origin_shorthand.dart';

/// The update comparator, against **real captured mod pages**.
///
/// Fixtures rather than hand-written mods, for the reason the file-selection
/// rule needed them: a hand-written fixture would have tidy version strings in
/// `_sVersion` and the whole rule would look obviously right while being wrong
/// on the actual data. The two profiles below disagree about what the variant
/// label even means — RabbitFX uses it for the variant (`Main file`, `Glow
/// demo`) and Megalodon uses it for the version (`v3.4`, `v3.0`) — and every
/// interesting case here comes out of that disagreement.
void main() {
  GbMod profile(String name) => GbMod.fromJson(parseObject(loadGbFixture(name)))!;

  final rabbitFx = profile('mod_profile_531649');
  final megalodon = profile('mod_profile_rated');

  ModOrigin origin({
    int? modId = 531649,
    OriginConfidence modIdConfidence = OriginConfidence.user,
    int? fileId,
    String? versionLabel,
    OriginConfidence versionConfidence = OriginConfidence.user,
    String? archiveMd5,
    DateTime? baseline,
    DateTime? dismissedUntil,
    OriginTracking tracking = OriginTracking.auto,
    bool patchShaped = false,
    List<ModCompanion> companions = const [],
  }) =>
      originFixture(
        source: 'gamebanana',
        modId: modId,
        modIdConfidence: modIdConfidence,
        fileId: fileId,
        versionLabel: versionLabel,
        versionConfidence: versionConfidence,
        provenance: OriginProvenance.downloaded,
        archiveMd5: archiveMd5,
        baselineRemoteDate: baseline,
        updatesDismissedUntil: dismissedUntil,
        tracking: tracking,
        ingest: patchShaped ? const ModIngest(patchShaped: true) : null,
        companions: companions,
      );

  /// A second identity in the same folder, at the tier the resolve dialog
  /// writes — `user`, never `exact`: we did not download it.
  ModCompanion companion(
    int modId, {
    int? fileId,
    CompanionRole role = CompanionRole.base,
  }) =>
      ModCompanion(
        role: role,
        modId: modId,
        modIdConfidence: OriginConfidence.user,
        fileId: fileId,
        versionConfidence:
            fileId == null ? OriginConfidence.unknown : OriginConfidence.user,
      );

  // RabbitFX file ids, from the fixture.
  const mainV77 = 1732269; // current, newest, "Main file"
  const mainV74 = 1696178; // archived, "Main file"
  const glowDemo = 1492636; // current, "Glow demo"

  // Megalodon, used as the *other* mod in a mixed folder. It writes its
  // versions into `_sDescription` — the variant field — so no two files share
  // a label and the strongest verdict its data supports is `possiblyOutdated`.
  // That is the realistic case rather than a weakness of the fixture.
  const megalodonId = 528481;
  const megalodonOldFile = 1258541; // "v3.0"
  const megalodonNewestFile = 1462303; // "v3.4", the current newest

  group('nothing to check', () {
    test('a mod with no origin block is untracked', () {
      expect(
        checkForUpdate(origin: null, remote: rabbitFx).outcome,
        UpdateOutcome.untracked,
      );
    });

    test('a block with no mod id is untracked', () {
      expect(
        checkForUpdate(origin: origin(modId: null), remote: rabbitFx).outcome,
        UpdateOutcome.untracked,
      );
    });

    test('"it\'s my own" wins over a stale mod id still in the block', () {
      // The same precedence the status slot uses. A `source_url` the user has
      // since disowned must not talk them back into being tracked.
      final check = checkForUpdate(
        origin: origin(fileId: mainV74, tracking: OriginTracking.off),
        remote: rabbitFx,
      );
      expect(check.outcome, UpdateOutcome.trackingOff);
    });

    test('an identified mod with no recorded file cannot be judged', () {
      final check = checkForUpdate(
        origin: origin(versionConfidence: OriginConfidence.unknown),
        remote: rabbitFx,
      );
      expect(check.outcome, UpdateOutcome.versionUnknown);
    });

    test('a response that carried no file list says so, not "up to date"', () {
      // `files == null` is "not requested", and concluding "nothing newer" from
      // a question we never asked is the one silent way this feature fails.
      const bare = GbMod(idRow: 531649);
      final check = checkForUpdate(origin: origin(fileId: mainV77), remote: bare);
      expect(check.outcome, UpdateOutcome.indeterminate);
    });

    test('an upstream-gone mod is read from its flags, not from a 404', () {
      const gone = GbMod(idRow: 531649, isTrashed: true, files: []);
      expect(
        checkForUpdate(origin: origin(fileId: mainV77), remote: gone).outcome,
        UpdateOutcome.sourceGone,
      );
    });
  });

  group('the installed file is known', () {
    test('the newest file of its variant is up to date', () {
      final check = checkForUpdate(
        origin: origin(fileId: mainV77, versionLabel: 'Main file'),
        remote: rabbitFx,
      );
      expect(check.outcome, UpdateOutcome.upToDate);
      expect(check.candidate, isNull);
      expect(check.isGuess, isFalse);
    });

    test('a file that has been archived is a confirmed update', () {
      // The strongest verdict available, and it needs no version comparison at
      // all: the file the user installed is no longer offered.
      final check = checkForUpdate(
        origin: origin(fileId: mainV74, versionLabel: 'Main file'),
        remote: rabbitFx,
      );
      expect(check.outcome, UpdateOutcome.updateAvailable);
      expect(check.candidate?.idRow, mainV77);
      expect(check.installedFile?.version, '7.4');
      expect(check.evidence, InstalledFileEvidence.recorded);
    });

    test('a still-offered file beside newer *other* variants is only possibly '
        'outdated', () {
      // A demo published in 2025 with a `Main file` from 2026 beside it. The
      // mod moved on; this file did not. Saying "an update is available" would
      // point the user at a different thing entirely.
      final check = checkForUpdate(
        origin: origin(fileId: glowDemo, versionLabel: 'Glow demo'),
        remote: rabbitFx,
      );
      expect(check.outcome, UpdateOutcome.possiblyOutdated);
      expect(check.candidate?.idRow, mainV77);
    });

    test('a label used as a version number never yields a false "up to date"',
        () {
      // Megalodon publishes ten *current* files labelled v1.2 … v3.4. Nothing
      // is archived, so a rule that only looked for a same-label successor
      // would report an installed v3.0 as current — the silent failure this
      // whole file is shaped to avoid.
      final check = checkForUpdate(
        origin: origin(modId: 528481, fileId: 1258541, versionLabel: 'v3.0'),
        remote: megalodon,
      );
      expect(check.outcome, UpdateOutcome.possiblyOutdated);
      expect(check.candidate?.description, 'v3.4');
    });

    test('the newest file of that same mod is up to date', () {
      final check = checkForUpdate(
        origin: origin(modId: 528481, fileId: 1462303, versionLabel: 'v3.4'),
        remote: megalodon,
      );
      expect(check.outcome, UpdateOutcome.upToDate);
    });

    test('a file deleted from the page outright still resolves a successor',
        () {
      // No published record left to read a label from, so the one stored at
      // install time is what finds the successor. Without it the verdict would
      // be "something changed, no idea what".
      final check = checkForUpdate(
        origin: origin(fileId: 999999, versionLabel: 'Main file'),
        remote: rabbitFx,
      );
      expect(check.outcome, UpdateOutcome.updateAvailable);
      expect(check.installedFile, isNull);
      expect(check.candidate?.idRow, mainV77);
    });

    test('a banked archive hash identifies the file with no file id at all',
        () {
      final archived =
          rabbitFx.archivedFiles!.firstWhere((f) => f.idRow == mainV74);
      final check = checkForUpdate(
        origin: origin(
          versionConfidence: OriginConfidence.unknown,
          archiveMd5: archived.md5Checksum!.toUpperCase(),
          versionLabel: 'Main file',
        ),
        remote: rabbitFx,
      );
      expect(check.evidence, InstalledFileEvidence.archiveHash);
      expect(check.outcome, UpdateOutcome.updateAvailable);
      // A checksum match is exact evidence whatever tier the block records, so
      // it does not get capped down to "possibly".
      expect(check.isGuess, isFalse);
    });
  });

  group('a guess may only inform', () {
    test('a guessed file caps the verdict at "possibly"', () {
      final check = checkForUpdate(
        origin: origin(
          fileId: mainV74,
          versionLabel: 'Main file',
          versionConfidence: OriginConfidence.inferred,
        ),
        remote: rabbitFx,
      );
      expect(check.outcome, UpdateOutcome.possiblyOutdated);
      expect(check.isGuess, isTrue);
      // The finding itself is unchanged — only how strongly it may be stated.
      expect(check.candidate?.idRow, mainV77);
    });

    test('a guessed identity caps it too, even with the file confirmed', () {
      // An `inferred` mod id came from a free-form field a human typed. If it
      // names the wrong mod, every file below belongs to somebody else's mod.
      final check = checkForUpdate(
        origin: origin(
          modIdConfidence: OriginConfidence.inferred,
          fileId: mainV74,
          versionLabel: 'Main file',
        ),
        remote: rabbitFx,
      );
      expect(check.outcome, UpdateOutcome.possiblyOutdated);
      expect(check.isGuess, isTrue);
    });

    test('a clean answer from a guess is still labelled a guess', () {
      // "Probably nothing new" and "nothing new" are different claims.
      final check = checkForUpdate(
        origin: origin(
          fileId: mainV77,
          versionConfidence: OriginConfidence.inferred,
        ),
        remote: rabbitFx,
      );
      expect(check.outcome, UpdateOutcome.upToDate);
      expect(check.isGuess, isTrue);
    });
  });

  group('tracked by date only', () {
    test('anything published after the baseline is possibly outdated', () {
      final check = checkForUpdate(
        origin: origin(
          versionConfidence: OriginConfidence.assumedLatest,
          baseline: DateTime.utc(2026, 1, 1),
        ),
        remote: rabbitFx,
      );
      expect(check.outcome, UpdateOutcome.possiblyOutdated);
      expect(check.candidate?.idRow, mainV77);
      expect(check.isGuess, isTrue);
    });

    test('a baseline past everything published is clean', () {
      final check = checkForUpdate(
        origin: origin(
          versionConfidence: OriginConfidence.assumedLatest,
          baseline: DateTime.utc(2027),
        ),
        remote: rabbitFx,
      );
      expect(check.outcome, UpdateOutcome.upToDate);
      expect(check.isGuess, isTrue);
    });

    test('the baseline is clamped to the mod\'s own creation date', () {
      // The bulk "assume current" action writes an **unclamped** baseline by
      // design — it makes no requests, so it cannot know the mod's creation
      // date. An install date proxied from file timestamps can read years
      // early, leaving a baseline from before the mod existed. Clamping here is
      // what stops that being compared against.
      final mod = GbMod(
        idRow: 1,
        dateAdded: DateTime.utc(2026, 6, 1),
        files: [
          GbFile(idRow: 10, dateAdded: DateTime.utc(2026, 5, 1)),
        ],
      );
      final check = checkForUpdate(
        origin: origin(
          modId: 1,
          versionConfidence: OriginConfidence.assumedLatest,
          baseline: DateTime.utc(2020),
        ),
        remote: mod,
      );
      expect(check.comparedAgainst, DateTime.utc(2026, 6, 1));
      // The file predates the clamped floor, so it cannot be newer than the
      // install. Against the raw 2020 baseline it would have flagged.
      expect(check.outcome, UpdateOutcome.upToDate);
    });

    test('a content update with no dated file still counts', () {
      final mod = GbMod(
        idRow: 1,
        dateAdded: DateTime.utc(2024),
        dateUpdated: DateTime.utc(2026, 6, 1),
        // Bumped by cosmetic edits too, so it must not be what decides.
        dateModified: DateTime.utc(2027),
        files: const [GbFile(idRow: 10)],
      );
      final check = checkForUpdate(
        origin: origin(
          modId: 1,
          versionConfidence: OriginConfidence.assumedLatest,
          baseline: DateTime.utc(2025),
        ),
        remote: mod,
      );
      expect(check.outcome, UpdateOutcome.possiblyOutdated);
      expect(check.candidate, isNull);

      // …and a mod whose only later timestamp is `_tsDateModified` does not.
      final cosmetic = GbMod(
        idRow: 1,
        dateAdded: DateTime.utc(2024),
        dateUpdated: DateTime.utc(2024, 6),
        dateModified: DateTime.utc(2027),
        files: const [GbFile(idRow: 10)],
      );
      expect(
        checkForUpdate(
          origin: origin(
            modId: 1,
            versionConfidence: OriginConfidence.assumedLatest,
            baseline: DateTime.utc(2025),
          ),
          remote: cosmetic,
        ).outcome,
        UpdateOutcome.upToDate,
      );
    });
  });

  test('obsolete is carried separately from the verdict', () {
    // The author flagging a mod superseded says nothing about whether the file
    // you hold is the newest one it publishes. Folding the two together would
    // report a current install as outdated.
    final mod = GbMod(
      idRow: 1,
      isObsolete: true,
      files: [GbFile(idRow: 10, dateAdded: DateTime.utc(2026))],
    );
    final check = checkForUpdate(origin: origin(modId: 1, fileId: 10), remote: mod);
    expect(check.outcome, UpdateOutcome.upToDate);
    expect(check.isObsolete, isTrue);
  });

  group('files released together are variants, not successors', () {
    // Both false positives found on a real 17-mod library were this, and
    // neither is fixable by comparing labels or dates: the second file is
    // newer, differently labelled, and still not an update. The author's own
    // release grouping is what settles it.
    ReleaseGroups releasesFrom(String fixture) => ReleaseGroups.fromUpdates(
          parseEnvelope(loadGbFixture(fixture), GbUpdate.fromJson).records,
        );

    test('an SFW install is not updated by the NSFW variant beside it', () {
      // Mod 549029: "Version 1.5" shipped 1484606 (SFW) and 1484607 (NSFW)
      // ninety seconds apart. Installing the first flagged the second.
      final releases = releasesFrom('mod_updates_549029');
      final remote = GbMod(
        idRow: 549029,
        files: [
          GbFile(
            idRow: 1484606,
            description: 'SFW Variants Only',
            dateAdded: DateTime.utc(2025, 7, 26, 1, 43),
          ),
          GbFile(
            idRow: 1484607,
            description: 'NSFW Variants Included',
            dateAdded: DateTime.utc(2025, 7, 26, 1, 45),
          ),
        ],
      );
      final block = origin(
        modId: 549029,
        fileId: 1484606,
        versionLabel: 'SFW Variants Only',
      );

      expect(
        checkForUpdate(origin: block, remote: remote).outcome,
        UpdateOutcome.possiblyOutdated,
        reason: 'without the release feed this is the old, wrong answer',
      );
      expect(
        checkForUpdate(origin: block, remote: remote, releases: releases)
            .outcome,
        UpdateOutcome.upToDate,
      );
    });

    test('four proportion variants in one post are one release', () {
      // Mod 675945: update 421423 shipped 1701139/1701140/1701141/1701164.
      final releases = releasesFrom('mod_updates_675945');
      expect(releases.sameRelease(1701140, 1701164), isTrue);
      expect(releases.sameRelease(1701140, 1701141), isTrue);
      // A different post's files are not siblings of it.
      expect(releases.sameRelease(1701140, 1698077), isFalse);
    });

    test('a genuinely later release still gets through', () {
      // The rule may only ever *remove* a flag it can prove wrong. Two files
      // from two different update posts stay a successor and a predecessor.
      final releases = releasesFrom('mod_updates_675945');
      final remote = GbMod(
        idRow: 675945,
        files: [
          GbFile(
            idRow: 1698077,
            description: 'Old',
            dateAdded: DateTime.utc(2026, 5, 10),
          ),
          GbFile(
            idRow: 1701140,
            description: 'Old',
            dateAdded: DateTime.utc(2026, 5, 14),
          ),
        ],
      );
      final check = checkForUpdate(
        origin: origin(modId: 675945, fileId: 1698077, versionLabel: 'Old'),
        remote: remote,
        releases: releases,
      );
      expect(check.outcome, UpdateOutcome.updateAvailable);
      expect(check.candidate?.idRow, 1701140);
    });

    test('no release feed changes nothing', () {
      // Most mods have no update posts, and a feed can fail to load. Absent
      // groups must leave the louder, unrefined answer rather than suppress it.
      expect(ReleaseGroups.empty.isEmpty, isTrue);
      expect(
        checkForUpdate(
          origin: origin(fileId: mainV74, versionLabel: 'Main file'),
          remote: rabbitFx,
          releases: ReleaseGroups.empty,
        ).outcome,
        UpdateOutcome.updateAvailable,
      );
    });

    test('a sibling is still not the successor once your file is archived', () {
      // The one place the two suppressions differ in reach, and the docs got it
      // wrong first: the same-version rule is confined to the still-offered
      // branch, but a release group survives onto the archived one. A file
      // shipped alongside yours is the *old* build of the other variant, so it
      // cannot be your replacement whatever happened to yours since.
      final mod = GbMod(
        idRow: 1,
        files: [
          GbFile(
            idRow: 11,
            description: 'NSFW',
            dateAdded: DateTime.utc(2026, 2),
          ),
        ],
        archivedFiles: [
          GbFile(
            idRow: 10,
            description: 'SFW',
            dateAdded: DateTime.utc(2026),
            isArchived: true,
          ),
        ],
      );
      final groups = ReleaseGroups.fromUpdates([
        const GbUpdate(idRow: 1, fileRowIds: {10, 11}),
      ]);
      final holding = origin(modId: 1, fileId: 10, versionLabel: 'SFW');

      // The verdict is untouched — the archive flag is a fact and no grouping
      // may argue with it. What changes is which file gets *named*.
      final grouped =
          checkForUpdate(origin: holding, remote: mod, releases: groups);
      expect(grouped.outcome, UpdateOutcome.updateAvailable);
      expect(grouped.candidate, isNull);
      expect(grouped.newerFiles, isEmpty);

      final ungrouped = checkForUpdate(origin: holding, remote: mod);
      expect(ungrouped.outcome, UpdateOutcome.updateAvailable);
      expect(ungrouped.candidate?.idRow, 11);
    });

    test('a single-file update post groups nothing', () {
      // `_aFileRowIds` with one entry says only "this file shipped", which is
      // never evidence that two files are siblings.
      final groups = ReleaseGroups.fromUpdates([
        const GbUpdate(idRow: 1, fileRowIds: {10}),
        const GbUpdate(idRow: 2, fileRowIds: {11}),
      ]);
      expect(groups.isEmpty, isTrue);
      expect(groups.sameRelease(10, 11), isFalse);
    });
  });

  group('the same declared version is a variant, not a successor', () {
    // The case no release group can catch: mod 621749 published `FULL MOD` and
    // then `NSFW MOD` nine days later in a *separate* update post — but stamped
    // both `1.01`. Comparing two free-form versions for an ordering is
    // hopeless; comparing them for equality is not.
    final shortcake = GbMod(
      idRow: 621749,
      files: [
        GbFile(
          idRow: 1544647,
          version: '1.01',
          description: 'NSFW MOD',
          dateAdded: DateTime.utc(2025, 10, 22),
        ),
        GbFile(
          idRow: 1537945,
          version: '1.01',
          description: 'FULL MOD',
          dateAdded: DateTime.utc(2025, 10, 13),
        ),
      ],
    );

    test('a newer file stamped with my version is not an update', () {
      final check = checkForUpdate(
        origin: origin(modId: 621749, fileId: 1537945, versionLabel: 'FULL MOD'),
        remote: shortcake,
      );
      expect(check.outcome, UpdateOutcome.upToDate);
    });

    test('a bumped version still is', () {
      final bumped = GbMod(
        idRow: 621749,
        files: [
          GbFile(
            idRow: 1544647,
            version: '1.02',
            description: 'NSFW MOD',
            dateAdded: DateTime.utc(2025, 10, 22),
          ),
          shortcake.files!.last,
        ],
      );
      expect(
        checkForUpdate(
          origin:
              origin(modId: 621749, fileId: 1537945, versionLabel: 'FULL MOD'),
          remote: bumped,
        ).outcome,
        UpdateOutcome.possiblyOutdated,
      );
    });

    test('two files declaring no version agree about nothing', () {
      // Absent is not equal. Treating two nulls as a match would silence every
      // unversioned mod on the site — which is most of them.
      final check = checkForUpdate(
        origin: origin(modId: 528481, fileId: 1258541, versionLabel: 'v3.0'),
        remote: megalodon,
      );
      expect(check.outcome, UpdateOutcome.possiblyOutdated);
    });

    test('it never argues with a file that has actually been archived', () {
      // Rule one is a fact, not a comparison, and no version string may
      // override it. Both RabbitFX `Main file` rows would compare equal if the
      // versions matched; the archived one is superseded regardless.
      final mod = GbMod(
        idRow: 1,
        files: [
          GbFile(
            idRow: 11,
            version: '2.0',
            description: 'Main',
            dateAdded: DateTime.utc(2026, 2),
          ),
        ],
        archivedFiles: [
          GbFile(
            idRow: 10,
            version: '2.0',
            description: 'Main',
            dateAdded: DateTime.utc(2026),
            isArchived: true,
          ),
        ],
      );
      final check = checkForUpdate(
        origin: origin(modId: 1, fileId: 10, versionLabel: 'Main'),
        remote: mod,
      );
      expect(check.outcome, UpdateOutcome.updateAvailable);
      expect(check.candidate?.idRow, 11);
    });
  });

  group('a mod that publishes several variants at once', () {
    // The shape most ZZZ mods actually have: an SFW and an NSFW build, both
    // updated together. What matters is that the check follows *the user's*
    // variant rather than the newest file on the page.
    final v1 = DateTime.utc(2026, 1, 1);
    final v2 = DateTime.utc(2026, 6, 1);
    GbFile file(int id, String? desc, DateTime added, {bool archived = false}) =>
        GbFile(
          idRow: id,
          description: desc,
          dateAdded: added,
          isArchived: archived,
        );

    ModOrigin holdingSfw({DateTime? ignored}) => origin(
          modId: 1,
          fileId: 10,
          versionLabel: 'SFW Variants Only',
          dismissedUntil: ignored,
        );

    test('the successor of *your* variant wins over the newest file', () {
      // File 21 (NSFW v2) is the newest thing on the page by two minutes, and
      // it is not the answer. The label match beats recency, which is the whole
      // reason the label is ranked before the date.
      final remote = GbMod(idRow: 1, files: [
        file(10, 'SFW Variants Only', v1),
        file(11, 'NSFW Variants Included', v1.add(const Duration(minutes: 2))),
        file(20, 'SFW Variants Only', v2),
        file(21, 'NSFW Variants Included', v2.add(const Duration(minutes: 2))),
      ]);
      final check = checkForUpdate(origin: holdingSfw(), remote: remote);
      expect(check.outcome, UpdateOutcome.updateAvailable);
      expect(check.candidate?.idRow, 20);
    });

    test('an old ignore never carries forward to the next release', () {
      // Having ignored the *previous* NSFW build must not silence a genuine
      // update published later. This is the property the date buys over a
      // file id, and it is the one worth pinning.
      final remote = GbMod(idRow: 1, files: [
        file(10, 'SFW Variants Only', v1),
        file(11, 'NSFW Variants Included', v1.add(const Duration(minutes: 2))),
        file(20, 'SFW Variants Only', v2),
        file(21, 'NSFW Variants Included', v2.add(const Duration(minutes: 2))),
      ]);
      final check = checkForUpdate(
        origin: holdingSfw(ignored: v1.add(const Duration(minutes: 2))),
        remote: remote,
      );
      expect(check.dismissed, isFalse);
      expect(check.hasUpdate, isTrue);
      expect(check.candidate?.idRow, 20, reason: 'still your variant');
    });

    test('a renamed variant label costs the candidate, not the verdict', () {
      // The author shortened `SFW Variants Only` to `SFW`. Nothing can match
      // the two, so the check falls back to the newest file — which here is the
      // *other* variant. It is reported as `possiblyOutdated` rather than as a
      // confirmed update, which is the honest strength for a guess, but the
      // named file is wrong and the user has to choose for themselves.
      final remote = GbMod(idRow: 1, files: [
        file(10, 'SFW Variants Only', v1),
        file(20, 'SFW', v2),
        file(21, 'NSFW', v2.add(const Duration(minutes: 2))),
      ]);
      final check = checkForUpdate(origin: holdingSfw(), remote: remote);
      expect(check.outcome, UpdateOutcome.possiblyOutdated);
      expect(check.candidate?.idRow, 21);
    });

    test('a superseded install with no matching successor names none', () {
      // Definitely out of date — the installed file is archived — but the mod
      // now publishes two files and neither is identifiably its replacement.
      // A null candidate is a real answer here: "pick one", not a guess dressed
      // up as an answer.
      final remote = GbMod(
        idRow: 1,
        files: [
          file(20, 'SFW', v2),
          file(21, 'NSFW', v2.add(const Duration(minutes: 2))),
        ],
        archivedFiles: [
          file(10, 'SFW Variants Only', v1, archived: true),
        ],
      );
      final check = checkForUpdate(origin: holdingSfw(), remote: remote);
      expect(check.outcome, UpdateOutcome.updateAvailable);
      expect(check.candidate, isNull);
    });
  });

  group('dismissing an update', () {
    UpdateCheck live() => checkForUpdate(
          origin: origin(fileId: mainV74, versionLabel: 'Main file'),
          remote: rabbitFx,
        );

    test('silences the badge but keeps the finding', () {
      final flagged = live();
      expect(flagged.hasUpdate, isTrue);

      final check = checkForUpdate(
        origin: origin(
          fileId: mainV74,
          versionLabel: 'Main file',
          dismissedUntil: flagged.dismissableUpTo,
        ),
        remote: rabbitFx,
      );
      expect(check.dismissed, isTrue);
      expect(check.hasUpdate, isFalse, reason: 'the card goes quiet');
      // …and the dialog can still say what it is, so the user can change their
      // mind without re-deriving anything.
      expect(check.outcome, UpdateOutcome.updateAvailable);
      expect(check.candidate?.idRow, mainV77);
    });

    test('speaks again the moment something newer is published', () {
      // A date rather than a file id, so it expires by itself.
      final check = checkForUpdate(
        origin: origin(
          fileId: mainV74,
          versionLabel: 'Main file',
          dismissedUntil: DateTime.utc(2026, 6, 19).subtract(
            const Duration(days: 1),
          ),
        ),
        remote: rabbitFx,
      );
      expect(check.dismissed, isFalse);
      expect(check.hasUpdate, isTrue);
    });

    test('never suppresses a finding it cannot date', () {
      // With nothing to compare the dismissal against, erring toward still
      // flagging is the safe direction.
      final mod = GbMod(
        idRow: 1,
        files: const [GbFile(idRow: 11, description: 'a')],
      );
      final check = checkForUpdate(
        origin: origin(
          modId: 1,
          fileId: 10,
          versionLabel: 'a',
          dismissedUntil: DateTime.utc(2030),
        ),
        remote: mod,
      );
      expect(check.dismissableUpTo, isNull);
      expect(check.dismissed, isFalse);
      expect(check.hasUpdate, isTrue);
    });

    test('covers everything the finding reported, not just the candidate', () {
      // The two come apart exactly where the label rule is doing its job: the
      // successor to *your* variant can be older than some other file on the
      // page, so keying the dismissal on the candidate leaves later files
      // silenced while the copy promises anything newer will speak up.
      final mod = GbMod(idRow: 1, files: [
        GbFile(idRow: 10, description: 'SFW', dateAdded: DateTime.utc(2026, 1)),
        GbFile(idRow: 20, description: 'SFW', dateAdded: DateTime.utc(2026, 6)),
        GbFile(idRow: 21, description: 'NSFW', dateAdded: DateTime.utc(2026, 7)),
      ]);
      final holding = origin(modId: 1, fileId: 10, versionLabel: 'SFW');

      final found = checkForUpdate(origin: holding, remote: mod);
      expect(found.candidate?.idRow, 20, reason: 'your variant, not the newest');
      // …but the dismissal has to reach the newest thing it *showed* the user.
      expect(found.dismissableUpTo, DateTime.utc(2026, 7));

      final after = checkForUpdate(
        origin: origin(
          modId: 1,
          fileId: 10,
          versionLabel: 'SFW',
          dismissedUntil: found.dismissableUpTo,
        ),
        remote: mod,
      );
      expect(after.dismissed, isTrue);
      expect(after.hasUpdate, isFalse);

      // And something genuinely later still gets through.
      final later = GbMod(idRow: 1, files: [
        ...mod.files!,
        GbFile(idRow: 30, description: 'SFW', dateAdded: DateTime.utc(2026, 9)),
      ]);
      expect(
        checkForUpdate(
          origin: origin(
            modId: 1,
            fileId: 10,
            versionLabel: 'SFW',
            dismissedUntil: found.dismissableUpTo,
          ),
          remote: later,
        ).hasUpdate,
        isTrue,
      );
    });

    test('is dropped when the folder is rebound to another mod', () {
      // It is a statement about one mod page's releases and means nothing
      // against a different one.
      final rebound = origin(
        fileId: mainV74,
        dismissedUntil: DateTime.utc(2030),
      ).boundTo(
        modId: 999,
        confidence: OriginConfidence.user,
        source: 'gamebanana',
      );
      expect(rebound.updatesDismissedUntil, isNull);
    });
  });

  group('the two response shapes', () {
    test('Mod/Multi folds archived files into _aFiles, and it still works', () {
      // A canary as much as a test. `ProfilePage` splits current and superseded
      // across two keys; `Mod/Multi` returns the union under one, flagged by
      // `_bIsArchived`. Reading "what is offered now" off the *key* rather than
      // the flag would make every mod on the bulk path look up to date.
      final records = parseBareList(
        loadGbFixture('mod_multi_files'),
        GbMod.fromJson,
      );
      final multi = records.firstWhere((m) => m.idRow == 531649);

      expect(multi.files, hasLength(14), reason: 'union of current + archived');
      expect(multi.archivedFiles, isNull, reason: 'the key is not requested');
      expect(multi.currentFiles, hasLength(6));
      expect(rabbitFx.currentFiles, hasLength(6));

      final check = checkForUpdate(
        origin: origin(fileId: mainV74, versionLabel: 'Main file'),
        remote: multi,
      );
      expect(check.outcome, UpdateOutcome.updateAvailable);
      expect(check.candidate?.idRow, mainV77);
    });
  });

  group('a folder that holds a patch', () {
    // The failure this exists for: the origin block names the *patch's* page,
    // so "nothing newer there" is true about the page we asked and says nothing
    // about the mod the folder actually contains. A patch folder is legible
    // only at install — once the base mod's files are dragged in around it,
    // every reference resolves and no scan can tell it apart.
    test('is never called up to date', () {
      final check = checkForUpdate(
        origin: origin(
          fileId: mainV77,
          versionLabel: 'Main file',
          patchShaped: true,
        ),
        remote: rabbitFx,
      );

      expect(check.outcome, UpdateOutcome.tracksPatchOnly);
      expect(check.hasUpdate, isFalse, reason: 'nothing newer was found');
    });

    test('keeps the evidence it gathered', () {
      // The verdict is downgraded, not thrown away — which file is installed
      // and how we know are still true and still worth showing.
      final plain = checkForUpdate(
        origin: origin(fileId: mainV77, versionLabel: 'Main file'),
        remote: rabbitFx,
      );
      final patched = checkForUpdate(
        origin: origin(
          fileId: mainV77,
          versionLabel: 'Main file',
          patchShaped: true,
        ),
        remote: rabbitFx,
      );

      expect(plain.outcome, UpdateOutcome.upToDate);
      expect(patched.installedFile?.idRow, plain.installedFile?.idRow);
      expect(patched.evidence, plain.evidence);
      expect(patched.isGuess, plain.isGuess);
    });

    test('a real update to the patch itself still reports', () {
      // Only the clean verdict is suppressed. If the patch has genuinely been
      // superseded that is a true finding about the page we track, and hiding
      // it would trade one silence for another.
      final check = checkForUpdate(
        origin: origin(fileId: mainV74, patchShaped: true),
        remote: rabbitFx,
      );

      expect(check.outcome, UpdateOutcome.updateAvailable);
      expect(check.hasUpdate, isTrue);
    });

    test('naming the base mod retires the verdict', () {
      // `tracksPatchOnly` is a statement that we cannot answer the question,
      // and it stops being true the moment there is a second identity to ask
      // about. Note the base's record is supplied: without one, the check has
      // still not looked (below).
      final check = checkForUpdate(
        origin: origin(
          fileId: mainV77,
          versionLabel: 'Main file',
          patchShaped: true,
          companions: [companion(megalodonId)],
        ),
        remote: rabbitFx,
        companionRemotes: {megalodonId: megalodon},
      );

      expect(check.outcome, isNot(UpdateOutcome.tracksPatchOnly));
    });
  });

  group('two identities in one folder', () {
    // The payoff. The folder's primary is the patch (RabbitFX, up to date on
    // its newest file); the companion is the mod it patches, which has
    // published something newer.
    UpdateCheck folded({
      required ModOrigin primary,
      Map<int, GbMod> remotes = const {},
    }) =>
        checkForUpdate(
          origin: primary,
          remote: rabbitFx,
          companionRemotes: remotes,
        );

    test('an update on the companion is reported for the folder', () {
      final check = folded(
        primary: origin(
          fileId: mainV77,
          versionLabel: 'Main file',
          companions: [companion(megalodonId, fileId: megalodonOldFile)],
        ),
        remotes: {megalodonId: megalodon},
      );

      expect(check.outcome, UpdateOutcome.possiblyOutdated,
          reason: 'the base mod stamps its versions into the variant field, so '
              'no label matches and "possibly" is the honest ceiling');
      expect(check.hasUpdate, isTrue);
      expect(
        check.subjectModId,
        megalodonId,
        reason: 'the top-level fields describe the identity that won the fold, '
            'so the dialog can say which mod the files belong to',
      );
      expect(check.candidate?.idRow, megalodonNewestFile);
    });

    test('every identity keeps its own verdict', () {
      // The card folds to one state; the dialog shows both. Losing the
      // per-identity answers would make "up to date" and "update available"
      // indistinguishable from "we only looked at one of them".
      final check = folded(
        primary: origin(
          fileId: mainV77,
          versionLabel: 'Main file',
          companions: [companion(megalodonId, fileId: megalodonOldFile)],
        ),
        remotes: {megalodonId: megalodon},
      );

      expect(check.companions.length, 1);
      expect(check.companions.single.companion.modId, megalodonId);
      expect(check.companions.single.check.outcome,
          UpdateOutcome.possiblyOutdated);
    });

    test('up to date is only claimed when every identity agrees', () {
      final check = folded(
        primary: origin(fileId: mainV77, versionLabel: 'Main file'),
        remotes: {},
      );
      expect(check.outcome, UpdateOutcome.upToDate,
          reason: 'no companions at all is the ordinary case, unchanged');

      final withUnasked = folded(
        primary: origin(
          fileId: mainV77,
          versionLabel: 'Main file',
          companions: [companion(megalodonId)],
        ),
        remotes: const {},
      );
      expect(
        withUnasked.outcome,
        UpdateOutcome.indeterminate,
        reason: 'a companion we never fetched a record for is silence, and '
            'silence is not evidence — claiming clean here is the false clean '
            'this whole feature exists to avoid',
      );
    });

    test('the primary still wins when it is the one with the update', () {
      final check = folded(
        primary: origin(
          fileId: mainV74, // archived — superseded
          companions: [companion(megalodonId, fileId: megalodonNewestFile)],
        ),
        remotes: {megalodonId: megalodon},
      );
      expect(check.outcome, UpdateOutcome.updateAvailable);
      expect(check.subjectModId, isNull,
          reason: 'null means the folder\'s own primary identity');
    });

    test('a companion that cannot be judged is not silently clean', () {
      // Identity known, file unknown, nothing local to identify it — the
      // resolve dialog's job, and the folder should say so rather than
      // reporting the primary's clean bill for both.
      final check = folded(
        primary: origin(
          fileId: mainV77,
          versionLabel: 'Main file',
          companions: [companion(megalodonId)],
        ),
        remotes: {megalodonId: megalodon},
      );

      expect(check.outcome, UpdateOutcome.versionUnknown);
    });

    test('"it\'s my own" silences the whole folder, companions included', () {
      // One switch per folder, which is exactly why a companion carries no
      // tracking of its own. It must not be possible for a muted mod to speak
      // through its second identity.
      final check = folded(
        primary: origin(
          tracking: OriginTracking.off,
          companions: [companion(megalodonId, fileId: megalodonOldFile)],
        ),
        remotes: {megalodonId: megalodon},
      );
      expect(check.outcome, UpdateOutcome.trackingOff);
      expect(check.companions, isEmpty,
          reason: 'nothing is asked about a folder the user declared local');
    });

    test('a dismissal on one identity does not silence the other', () {
      // `updates_dismissed_until` is per identity for this reason: waving away
      // the patch's release must not hide the base mod's.
      final check = folded(
        primary: origin(
          fileId: mainV74, // superseded, so the primary has a finding
          dismissedUntil: DateTime.utc(2030),
          companions: [companion(megalodonId, fileId: megalodonOldFile)],
        ),
        remotes: {megalodonId: megalodon},
      );

      expect(check.hasUpdate, isTrue);
      expect(check.subjectModId, megalodonId);
      expect(
        check.companions.single.check.dismissed,
        isFalse,
        reason: 'the dismissal was written against the primary\'s releases',
      );
    });

    test('"I don\'t know which file" on the companion still reports', () {
      // The answer a user gives when they cannot say which variant of the
      // other mod is in the folder. It compares against a baseline instead of
      // a file, and it must still be able to find something.
      final check = checkForUpdate(
        origin: origin(fileId: mainV77, versionLabel: 'Main file', companions: [
          ModCompanion(
            role: CompanionRole.base,
            modId: megalodonId,
            modIdConfidence: OriginConfidence.user,
            versionConfidence: OriginConfidence.assumedLatest,
            baselineRemoteDate: DateTime.utc(2024),
          ),
        ]),
        remote: rabbitFx,
        companionRemotes: {megalodonId: megalodon},
      );

      expect(check.outcome, UpdateOutcome.possiblyOutdated);
      expect(check.subjectModId, megalodonId);
    });

    test('the fold prefers a live finding over a dismissed stronger one', () {
      // Pinned because the naive fold — rank by outcome alone — picks the
      // primary's `updateAvailable` and then reports `hasUpdate: false`,
      // leaving a folder that has a real update rendering as if it had none.
      final check = folded(
        primary: origin(
          fileId: mainV74,
          dismissedUntil: DateTime.utc(2030),
          companions: [companion(megalodonId, fileId: megalodonOldFile)],
        ),
        remotes: {megalodonId: megalodon},
      );
      expect(check.outcome, UpdateOutcome.possiblyOutdated);
      expect(check.hasUpdate, isTrue);
    });
  });
}
