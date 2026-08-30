import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/gamebanana/gamebanana.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/services/origin_resolution.dart';

import 'support/fixtures.dart';

/// The two captured profiles this suite leans on, because they are the two
/// shapes the file-selection rules were designed around:
///
/// - `531649` — a main file at 7.7 beside patchers and demos, plus eight
///   archived releases. The "you have an old one" case.
/// - `541825` — four current variants and four archived ones, all with real
///   filenames, which is what the folder-name match is checked against.
GbMod profile(String fixture) =>
    GbMod.fromJson(parseObject(loadGbFixture(fixture)))!;

ModOrigin bound(int modId, {String? archiveMd5, DateTime? installedAt}) =>
    ModOrigin(
      source: 'gamebanana',
      modId: modId,
      modIdConfidence: OriginConfidence.inferred,
      provenance: OriginProvenance.importedFolder,
      installedAt: installedAt,
      archiveMd5: archiveMd5,
    );

void main() {
  group('rankResolveCandidates', () {
    test('no files at all resolves to nothing', () {
      final resolution = rankResolveCandidates(
        files: null,
        archivedFiles: null,
        folderName: 'Ellen',
      );
      expect(resolution.isEmpty, isTrue);
      expect(resolution.preselected, isNull);
      expect(resolution.isSettled, isFalse);
    });

    test('a banked hash pins an archived file and settles the question', () {
      // The whole point of matching `_aArchivedFiles` too: an old install
      // matches a superseded file far more often than the current one.
      final mod = profile('mod_profile_531649');
      final resolution = rankResolveCandidates(
        files: mod.files,
        archivedFiles: mod.archivedFiles,
        folderName: 'RabbitFX',
        // v7.3, archived.
        archiveMd5: '18b741db96df8c640d7c897681c5e478',
      );
      expect(resolution.isSettled, isTrue);
      expect(resolution.preselected!.file.idRow, 1695165);
      expect(resolution.preselected!.reason, FileMatchReason.archiveHash);
      expect(resolution.preselected!.isExact, isTrue);
      // Every file is still listed — the match is a fast path, not a filter.
      expect(resolution.candidates, hasLength(14));
    });

    test('a hash is matched case- and whitespace-insensitively', () {
      // A sidecar is a public interchange format and can arrive hand-edited; a
      // case mismatch would look exactly like "no match" and never be noticed.
      final mod = profile('mod_profile_531649');
      final resolution = rankResolveCandidates(
        files: mod.files,
        archivedFiles: mod.archivedFiles,
        folderName: 'RabbitFX',
        archiveMd5: '  362BB10D2EBE1BB78AFE99911C307E98 ',
      );
      expect(resolution.preselected!.file.idRow, 1732269);
    });

    test('an unmatched hash falls through instead of blocking', () {
      // Null-or-exact: a miss teaches us nothing and costs nothing, which is
      // the common case for a re-zipped archive.
      final mod = profile('mod_profile_531649');
      final resolution = rankResolveCandidates(
        files: mod.files,
        archivedFiles: mod.archivedFiles,
        folderName: 'RabbitFX',
        archiveMd5: '00000000000000000000000000000000',
        installedAt: DateTime.utc(2026, 3, 1),
      );
      expect(resolution.isSettled, isFalse);
      expect(resolution.candidates.first.reason, FileMatchReason.installDate);
    });

    test('the folder name matches an archive name across separators', () {
      final mod = profile('mod_profile_tagged');
      final resolution = rankResolveCandidates(
        files: mod.files,
        archivedFiles: mod.archivedFiles,
        folderName: 'Jane Swimsuit - Hazeker Redux',
      );
      final top = resolution.candidates.first;
      expect(top.file.idRow, 1639524);
      expect(top.reason, FileMatchReason.folderName);
      // Suggested, never preselected: it informs, it does not drive.
      expect(resolution.preselected, isNull);
      expect(resolution.isSettled, isFalse);
    });

    test('the date candidate is the newest file that already existed', () {
      // A file uploaded *after* the install cannot be the installed one, so the
      // candidate is drawn from the ones that could be rather than by absolute
      // distance.
      //
      // 15:00 on 2026-05-08 is chosen to separate the two rules, and it is the
      // only window in this fixture that does: v7.4 landed at 12:29 that day
      // (151 min before) and v7.5 at 15:56 (56 min after), so nearest-distance
      // picks v7.5 — a file that did not yet exist. An install at 13:00 or
      // 14:00 has both rules agreeing on v7.4, which is why the earlier
      // 14:00 version of this test proved nothing. A plain "newest" is wrong
      // here too: it picks v7.7, the current main file.
      final mod = profile('mod_profile_531649');
      final resolution = rankResolveCandidates(
        files: mod.files,
        archivedFiles: mod.archivedFiles,
        folderName: 'no match at all',
        installedAt: DateTime.utc(2026, 5, 8, 15),
      );
      final top = resolution.candidates.first;
      expect(top.reason, FileMatchReason.installDate);
      expect(top.file.version, '7.4');
    });

    test('an install date older than every file suggests nothing', () {
      // The proxy install date can read years early for a hand-copied library.
      // Saying nothing is the honest outcome; the picker still lists everything.
      final mod = profile('mod_profile_531649');
      final resolution = rankResolveCandidates(
        files: mod.files,
        archivedFiles: mod.archivedFiles,
        folderName: 'no match at all',
        installedAt: DateTime.utc(2019),
      );
      expect(
        resolution.candidates.every((c) => c.reason == FileMatchReason.none),
        isTrue,
      );
      expect(resolution.preselected, isNull);
    });

    test('exactly one published file preselects it', () {
      final only = GbFile(idRow: 42, file: 'thing.zip', version: '2');
      final resolution = rankResolveCandidates(
        files: [only],
        archivedFiles: null,
        folderName: 'unrelated',
      );
      expect(resolution.preselected!.reason, FileMatchReason.onlyFile);
      // Unambiguous is not the same as exact: picking it is still the user
      // telling us, so it must not claim the tier that gates auto-update.
      expect(resolution.preselected!.isExact, isFalse);
      expect(resolution.isSettled, isFalse);
    });

    test('one file stays preselected when something else also matched it', () {
      // "There is only one file" is a fact about the list, not a reason on a
      // row, so stronger evidence must not cost the preselect. Deciding it off
      // the winning *reason* had it backwards: the mod preselected only while
      // nothing local pointed at it. The date case is the common one — the
      // dialog probes an install date for any mod that lacks one, so every
      // single-file mod uploaded before its install lands here.
      final only =
          GbFile(idRow: 42, file: 'thing.zip', dateAdded: DateTime.utc(2025));

      final byName = rankResolveCandidates(
        files: [only],
        archivedFiles: null,
        folderName: 'thing',
      );
      expect(byName.candidates.single.reason, FileMatchReason.folderName);
      expect(byName.preselected?.file.idRow, 42);

      final byDate = rankResolveCandidates(
        files: [only],
        archivedFiles: null,
        folderName: 'nothing like it',
        installedAt: DateTime.utc(2025, 6),
      );
      expect(byDate.candidates.single.reason, FileMatchReason.installDate);
      expect(byDate.preselected?.file.idRow, 42);
      // Still not exact — only a checksum match ever is.
      expect(byDate.preselected!.isExact, isFalse);
      expect(byDate.isSettled, isFalse);
    });

    test('unsuggested rows list current files before superseded ones', () {
      final mod = profile('mod_profile_tagged');
      final resolution = rankResolveCandidates(
        files: mod.files,
        archivedFiles: mod.archivedFiles,
        folderName: 'nothing matches this',
      );
      final archivedFrom =
          resolution.candidates.indexWhere((c) => c.file.isArchived);
      expect(archivedFrom, 4);
      expect(
        resolution.candidates.skip(archivedFrom).every((c) => c.file.isArchived),
        isTrue,
      );
    });

    test('ten files with no version string at all still rank', () {
      // The corpus case that killed version ordering: every file null, the
      // version living in the variant field. Nothing here reads `_sVersion`.
      final mod = profile('mod_profile_rated');
      expect(mod.files!.every((f) => f.version == null), isTrue);
      final resolution = rankResolveCandidates(
        files: mod.files,
        archivedFiles: mod.archivedFiles,
        folderName: 'Megalodon Maid Ellen',
        installedAt: DateTime.utc(2024, 9, 1),
      );
      expect(resolution.candidates.first.file.description, 'v3.0');
      expect(resolution.candidates.first.reason, FileMatchReason.installDate);
    });
  });

  group('ModOrigin.boundTo', () {
    // Tested directly as well as through its two callers, because the branch
    // that matters most is the one neither of them reaches with anything to
    // lose: binding to the *same* mod, where every field has to survive.
    test('binding to the same mod preserves everything but the claim', () {
      final existing = bound(555, archiveMd5: 'abc').copyWith(
        fileId: 900,
        version: '2.0',
        versionLabel: 'white hair ver',
        versionConfidence: OriginConfidence.user,
        baselineRemoteDate: DateTime.utc(2025),
        installedAt: DateTime.utc(2024),
        remoteMissing: true,
      );

      final result = existing.boundTo(
        modId: 555,
        confidence: OriginConfidence.exact,
        source: 'gamebanana',
      );

      expect(result.modIdConfidence, OriginConfidence.exact);
      expect(result.source, 'gamebanana');
      expect(result.fileId, 900);
      expect(result.version, '2.0');
      expect(result.versionLabel, 'white hair ver');
      expect(result.versionConfidence, OriginConfidence.user);
      expect(result.baselineRemoteDate, DateTime.utc(2025));
      expect(result.installedAt, DateTime.utc(2024));
      expect(result.archiveMd5, 'abc');
      expect(result.remoteMissing, isTrue);
    });

    test('source is overwritten rather than kept', () {
      // The field is a service discriminator, and a block being re-bound to a
      // GameBanana mod is a GameBanana mod whatever it used to say.
      final result = bound(1).copyWith(source: 'elsewhere').boundTo(
            modId: 1,
            confidence: OriginConfidence.user,
            source: 'gamebanana',
          );
      expect(result.source, 'gamebanana');
    });
  });

  group('OriginResolution.bind', () {
    test('a mod with no block at all gets one at user confidence', () {
      final origin = OriginResolution.bind(null, 555);
      expect(origin.modId, 555);
      expect(origin.modIdConfidence, OriginConfidence.user);
      expect(origin.source, 'gamebanana');
      expect(origin.provenance, OriginProvenance.importedFolder);
      // Trusted, but not exact: the user did not download this file and no
      // checksum matched it.
      expect(origin.allowsUnattendedUpdate, isFalse);
    });

    test('confirming the id the backfill guessed keeps the file data', () {
      final existing = bound(555).copyWith(
        fileId: 900,
        version: '2.0',
        versionConfidence: OriginConfidence.user,
      );
      final origin = OriginResolution.bind(existing, 555);
      expect(origin.modIdConfidence, OriginConfidence.user);
      expect(origin.fileId, 900);
      expect(origin.versionConfidence, OriginConfidence.user);
    });

    test('rebinding to a different mod clears what described the old one', () {
      final existing = bound(555, archiveMd5: 'abc').copyWith(
        fileId: 900,
        version: '2.0',
        versionLabel: 'white hair ver',
        versionConfidence: OriginConfidence.exact,
        baselineRemoteDate: DateTime.utc(2025),
        remoteMissing: true,
      );
      final origin = OriginResolution.bind(existing, 777);
      expect(origin.modId, 777);
      expect(origin.fileId, isNull);
      expect(origin.version, isNull);
      expect(origin.versionLabel, isNull);
      expect(origin.versionConfidence, OriginConfidence.unknown);
      expect(origin.baselineRemoteDate, isNull);
      expect(origin.remoteMissing, isFalse);
      // The hash describes the archive, not which mod we think it is — so it
      // survives, and can be matched against the new mod's checksums.
      expect(origin.archiveMd5, 'abc');
    });
  });

  group('OriginResolution.pickFile', () {
    final file = GbFile(
      idRow: 1732269,
      file: 'v77.zip',
      version: '7.7',
      description: 'Main file',
    );

    test('records the two strings separately and lands at user', () {
      final origin =
          OriginResolution.pickFile(bound(1), modId: 1, file: file, exact: false)!;
      expect(origin.fileId, 1732269);
      expect(origin.version, '7.7');
      expect(origin.versionLabel, 'Main file');
      expect(origin.versionConfidence, OriginConfidence.user);
    });

    test('a hash-matched pick is exact and can drive auto-update', () {
      final origin = OriginResolution.pickFile(
        bound(1).copyWith(modIdConfidence: OriginConfidence.exact),
        modId: 1,
        file: file,
        exact: true,
      )!;
      expect(origin.versionConfidence, OriginConfidence.exact);
      expect(origin.allowsUnattendedUpdate, isTrue);
    });

    test('abandons rather than writing a file id against the wrong mod', () {
      // The write path re-reads the sidecar; if it was rebound underneath the
      // open dialog, this decision no longer means anything.
      expect(
        OriginResolution.pickFile(bound(2), modId: 1, file: file, exact: false),
        isNull,
      );
      expect(
        OriginResolution.pickFile(null, modId: 1, file: file, exact: false),
        isNull,
      );
    });
  });

  group('OriginResolution.assumeCurrent', () {
    test('uses the install date as the baseline', () {
      final origin = OriginResolution.assumeCurrent(
        bound(1, installedAt: DateTime.utc(2026, 3, 1)),
      )!;
      expect(origin.versionConfidence, OriginConfidence.assumedLatest);
      expect(origin.baselineRemoteDate, DateTime.utc(2026, 3, 1));
      expect(origin.fileId, isNull);
    });

    test('clamps a proxy date that predates the mod itself', () {
      // A hand-copied library keeps the author's build timestamps, so the proxy
      // can read years before the mod was ever published. Unclamped, that flags
      // every file the mod has ever released.
      final origin = OriginResolution.assumeCurrent(
        bound(1, installedAt: DateTime.utc(2019)),
        remoteCreatedAt: DateTime.utc(2024, 7, 16),
      )!;
      expect(origin.baselineRemoteDate, DateTime.utc(2024, 7, 16));
    });

    test('a probed date is recorded and flagged as a proxy', () {
      final origin = OriginResolution.assumeCurrent(
        bound(1),
        installedAt: DateTime.utc(2025, 5, 5),
      )!;
      expect(origin.installedAt, DateTime.utc(2025, 5, 5));
      expect(origin.installedAtIsProxy, isTrue);
    });

    test('no date anywhere means the action cannot be offered', () {
      // `assumed_latest` with no baseline compares against nothing.
      expect(OriginResolution.assumeCurrent(bound(1)), isNull);
      expect(OriginResolution.assumeCurrent(null), isNull);
    });

    test('does not claim a proxy install date it never supplied', () {
      final origin = OriginResolution.assumeCurrent(
        bound(1),
        remoteCreatedAt: DateTime.utc(2024),
      )!;
      expect(origin.installedAt, isNull);
      expect(origin.installedAtIsProxy, isFalse);
    });
  });

  group('OriginResolution tracking', () {
    test('stopping tracking writes a block even where there was none', () {
      // The don't-litter rule says an untracked mod gets no sidecar — but
      // absence means "not looked at yet", which is the thing being switched off.
      final origin = OriginResolution.stopTracking(null);
      expect(origin.tracking, OriginTracking.off);
      expect(origin.modId, isNull);
    });

    test('keeps the identity so resuming is a real undo', () {
      final off = OriginResolution.stopTracking(bound(555));
      expect(off.modId, 555);
      expect(off.allowsUnattendedUpdate, isFalse);
      expect(OriginResolution.resumeTracking(off).tracking, OriginTracking.auto);
    });
  });
}
