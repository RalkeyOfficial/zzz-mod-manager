import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/mod_companion.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/services/installed_mods_index.dart';

/// The "do I already have this?" lookup.
///
/// Pure, and therefore exactly the kind of thing that should be tested rather
/// than clicked: every question it answers becomes a badge somewhere, and a badge
/// that is wrong in the *unlisted* direction (claiming you own something you
/// don't) is worse than no badge at all.
void main() {
  ModInfo mod(
    String name, {
    int? modId,
    int? fileId,
    String? archiveMd5,
    OriginConfidence modIdConfidence = OriginConfidence.inferred,
    OriginTracking tracking = OriginTracking.auto,
    bool noOrigin = false,
  }) {
    return ModInfo(
      id: name,
      name: name,
      characterId: 'unknown',
      isActive: false,
      origin: noOrigin
          ? null
          : ModOrigin(
              source: 'gamebanana',
              modId: modId,
              modIdConfidence: modIdConfidence,
              fileId: fileId,
              archiveMd5: archiveMd5,
              tracking: tracking,
              provenance: OriginProvenance.importedFolder,
            ),
    );
  }

  group('mod identity', () {
    test('an unknown mod id is simply absent', () {
      final index = InstalledModsIndex.fromMods([mod('Ellen', modId: 111)]);
      expect(index.hasMod(222), isFalse);
      expect(index.installsOfMod(222), isEmpty);
    });

    test('reports every folder installed from one remote mod', () {
      // The shape a real 23-mod library actually has: two pairs of folders each
      // sharing one mod id — two variants of one GameBanana page installed side
      // by side. Returning only the first would under-report the library, and
      // §4's updating must not read a shared id as a sibling *group* either.
      final index = InstalledModsIndex.fromMods([
        mod('Shortcake-JuFufu (NSFW)', modId: 621749),
        mod('Shortcake-JuFufu', modId: 621749),
        mod('lucia elegant v5 og_proportions glasses', modId: 675945),
        mod('lucia elegant v5 no_glasses', modId: 675945),
        mod('Healthbar', modId: 547423),
      ]);

      expect(index.hasMod(621749), isTrue);
      expect(index.installsOfMod(621749),
          ['Shortcake-JuFufu', 'Shortcake-JuFufu (NSFW)']);
      expect(index.installsOfMod(675945), [
        'lucia elegant v5 no_glasses',
        'lucia elegant v5 og_proportions glasses',
      ]);
      expect(index.installsOfMod(547423), ['Healthbar']);
    });

    test('folder order does not depend on the filesystem enumeration order', () {
      final forwards = InstalledModsIndex.fromMods([
        mod('alpha', modId: 1),
        mod('Beta', modId: 1),
      ]);
      final backwards = InstalledModsIndex.fromMods([
        mod('Beta', modId: 1),
        mod('alpha', modId: 1),
      ]);
      expect(forwards.installsOfMod(1), ['alpha', 'Beta']);
      expect(backwards.installsOfMod(1), forwards.installsOfMod(1));
    });

    test('a mod with no origin block at all is untracked, not an error', () {
      final index = InstalledModsIndex.fromMods([
        mod('hand made', noOrigin: true),
        mod('Ellen', modId: 111),
      ]);
      expect(index.installsOfMod(111), ['Ellen']);
    });

    test('an inferred mod id still counts as installed', () {
      // Badging on a guess is explicitly allowed — the rule is that anything
      // short of `exact` may badge, suggest and prompt, and only `exact` may
      // overwrite files unattended. The badge names the folder so the user can
      // see what we matched rather than being asked to trust it.
      final index = InstalledModsIndex.fromMods([
        mod('Ellen', modId: 111, modIdConfidence: OriginConfidence.inferred),
      ]);
      expect(index.installsOfMod(111), ['Ellen']);
    });

    test('tracking: off keeps a stale mod id out of the identity index', () {
      // "Not from GameBanana / it's my own" is a decision the user made, and a
      // wrong `source_url` is exactly why they might have made it. Badging that
      // mod's page as "in your library" would contradict them.
      final index = InstalledModsIndex.fromMods([
        mod('my own thing',
            modId: 111, fileId: 9, tracking: OriginTracking.off),
      ]);
      expect(index.hasMod(111), isFalse);
      expect(index.installsOfMod(111), isEmpty);
      expect(index.matchFile(fileId: 9).isInstalled, isFalse);
    });

    test('tracking: off still banks its archive hash', () {
      // A hash is a fact about bytes on disk, not a claim about which remote mod
      // they are — so local dedup keeps working for a mod declared local.
      final index = InstalledModsIndex.fromMods([
        mod('my own thing',
            archiveMd5: 'abc123', tracking: OriginTracking.off),
      ]);
      expect(index.installsOfArchive('abc123'), ['my own thing']);
    });
  });

  group('file identity', () {
    test('a file id match is reported as such', () {
      final index =
          InstalledModsIndex.fromMods([mod('Ellen', modId: 111, fileId: 999)]);
      final match = index.matchFile(fileId: 999);
      expect(match.evidence, InstalledFileEvidence.fileId);
      expect(match.folders, ['Ellen']);
      expect(match.isInstalled, isTrue);
    });

    test('a hash match is reported as a hash match, not as a file id', () {
      // The two must stay distinguishable: one is a record of what we installed,
      // the other says the bytes were identical. They are worded differently in
      // the UI precisely because an md5 match is a matching key and nothing more.
      final index = InstalledModsIndex.fromMods([
        mod('Ellen', modId: 111, archiveMd5: 'd41d8cd98f00b204e9800998ecf8427e'),
      ]);
      final match = index.matchFile(
        fileId: 999,
        md5: 'd41d8cd98f00b204e9800998ecf8427e',
      );
      expect(match.evidence, InstalledFileEvidence.archiveHash);
      expect(match.folders, ['Ellen']);
    });

    test('the file id wins when both would match', () {
      final index = InstalledModsIndex.fromMods([
        mod('by id', modId: 111, fileId: 999),
        mod('by hash', modId: 111, archiveMd5: 'abc'),
      ]);
      expect(
        index.matchFile(fileId: 999, md5: 'abc').evidence,
        InstalledFileEvidence.fileId,
      );
    });

    test('no evidence yields an empty, non-installed match', () {
      final index = InstalledModsIndex.fromMods([mod('Ellen', modId: 111)]);
      final match = index.matchFile(fileId: 999, md5: 'abc');
      expect(match.evidence, InstalledFileEvidence.none);
      expect(match.folders, isEmpty);
      expect(match.isInstalled, isFalse);
    });

    test('a legacy library answers at mod level and stays silent at file level',
        () {
      // Measured, not assumed: in a real 23-mod library every mod carries a
      // `mod_id` recovered from its `source_url` and **none** carries a `file_id`
      // or an `archive_md5`, because the archive is deleted after extraction. So
      // "this mod is in your library" works from the first launch while "this is
      // the file you have" cannot, and nothing may be built on the latter being
      // available.
      final index = InstalledModsIndex.fromMods([
        for (final id in [655007, 583037, 628289, 583004])
          mod('legacy $id', modId: id),
      ]);
      expect(index.hasMod(655007), isTrue);
      expect(index.matchFile(fileId: 1, md5: 'abc').isInstalled, isFalse);
    });
  });

  group('archive hashes', () {
    test('finds every folder unpacked from one archive', () {
      // One archive can legitimately become several mods, and the dedup answer
      // is "you already have this as A, B, C" rather than three separate hits.
      final index = InstalledModsIndex.fromMods([
        mod('Mod B', archiveMd5: 'aa'),
        mod('Mod A', archiveMd5: 'aa'),
        mod('Other', archiveMd5: 'bb'),
      ]);
      expect(index.installsOfArchive('aa'), ['Mod A', 'Mod B']);
      expect(index.installsOfArchive('bb'), ['Other']);
      expect(index.installsOfArchive('cc'), isEmpty);
    });

    test('hash lookups are case- and whitespace-insensitive', () {
      // A sidecar is a public interchange format and can arrive hand-edited. A
      // case mismatch would turn every lookup into a miss, which is
      // indistinguishable from "no match" and would never be noticed.
      final index =
          InstalledModsIndex.fromMods([mod('Ellen', archiveMd5: ' ABC123 ')]);
      expect(index.installsOfArchive('abc123'), ['Ellen']);
      expect(index.installsOfArchive('ABC123'), ['Ellen']);
    });

    test('a null or blank hash matches nothing', () {
      // Null-or-exact: a miss teaches us nothing and costs nothing. What it must
      // never do is match every other mod that also has no hash.
      final index = InstalledModsIndex.fromMods([
        mod('Ellen', archiveMd5: null),
        mod('Belle', archiveMd5: '   '),
      ]);
      expect(index.installsOfArchive(null), isEmpty);
      expect(index.installsOfArchive(''), isEmpty);
      expect(index.installsOfArchive('   '), isEmpty);
      expect(index.matchFile(fileId: 1, md5: null).isInstalled, isFalse);
    });
  });

  group('companions', () {
    // The one place a second identity is a straight gain rather than a cost:
    // the base mod's files really are in the library, and until now its page
    // showed no badge because the folder is named after the patch.
    ModInfo mixed(
      String name, {
      required int primary,
      required int companion,
      int? companionFileId,
      OriginTracking tracking = OriginTracking.auto,
    }) =>
        ModInfo(
          id: name,
          name: name,
          characterId: 'unknown',
          isActive: false,
          origin: ModOrigin(
            source: 'gamebanana',
            modId: primary,
            modIdConfidence: OriginConfidence.exact,
            provenance: OriginProvenance.downloaded,
            tracking: tracking,
            companions: [
              ModCompanion(
                role: CompanionRole.base,
                modId: companion,
                modIdConfidence: OriginConfidence.user,
                fileId: companionFileId,
              ),
            ],
          ),
        );

    test('the base mod counts as installed, under the folder it is in', () {
      final index = InstalledModsIndex.fromMods([
        mixed('EllenBikini', primary: 222, companion: 111),
      ]);
      expect(index.hasMod(222), isTrue);
      expect(index.hasMod(111), isTrue);
      expect(index.installsOfMod(111), ['EllenBikini']);
    });

    test('a companion file id marks that row as installed', () {
      final index = InstalledModsIndex.fromMods([
        mixed('EllenBikini',
            primary: 222, companion: 111, companionFileId: 1490003),
      ]);
      final match = index.matchFile(fileId: 1490003);
      expect(match.isInstalled, isTrue);
      expect(match.evidence, InstalledFileEvidence.fileId);
      expect(match.folders, ['EllenBikini']);
    });

    test('one page installed as a folder and as a companion lists both', () {
      // Nothing stops a user owning the base mod in its own folder *and*
      // having it inside a patched one, and both are true answers to "where
      // is this in my library".
      final index = InstalledModsIndex.fromMods([
        mod('Ellen Bikini', modId: 111),
        mixed('EllenBikini Patched', primary: 222, companion: 111),
      ]);
      expect(index.installsOfMod(111), ['Ellen Bikini', 'EllenBikini Patched']);
    });

    test('tracking off excludes the companion too', () {
      // The switch is about the folder, which is exactly why a companion does
      // not carry one of its own. A stale identity of either kind must not
      // badge somebody else's mod page.
      final index = InstalledModsIndex.fromMods([
        mixed('EllenBikini',
            primary: 222, companion: 111, tracking: OriginTracking.off),
      ]);
      expect(index.hasMod(222), isFalse);
      expect(index.hasMod(111), isFalse);
    });
  });

  test('the empty index answers no to everything', () {
    // What every caller sees while the library snapshot loads. It must render as
    // "nothing known" rather than throwing or claiming a match.
    expect(InstalledModsIndex.empty.hasMod(1), isFalse);
    expect(InstalledModsIndex.empty.installsOfMod(1), isEmpty);
    expect(InstalledModsIndex.empty.installsOfArchive('abc'), isEmpty);
    expect(
      InstalledModsIndex.empty.matchFile(fileId: 1, md5: 'abc').isInstalled,
      isFalse,
    );
  });
}
