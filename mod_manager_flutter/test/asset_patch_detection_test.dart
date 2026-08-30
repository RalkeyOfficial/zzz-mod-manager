import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_mod.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_page.dart';
import 'package:mod_manager_flutter/services/archive_service.dart';
import 'package:mod_manager_flutter/services/ini_resources.dart';
import 'package:mod_manager_flutter/services/patch_detection.dart';
import 'package:mod_manager_flutter/services/patch_scan.dart';

import 'support/fixtures.dart';

/// A patch that ships **no `.ini` at all** — just the asset it replaces.
///
/// The measured `.ini`-reference rule cannot see this class, and not because a
/// threshold is wrong: it is defined over what the `.ini` files reference, and
/// there are none. The whole download is one `.dds`.
///
/// **Taken from a real pair, with the mods anonymised.** Two live GameBanana
/// pages were fetched and both archives downloaded and extracted; the file
/// counts, sizes, dates, the one-file/two-variant shape and the naming
/// convention below are what they actually held. The names, ids and checksums
/// in the fixtures are not — a captured page carries the author's name, member
/// id, avatar and donation links, and none of that belongs in this repo.
///
/// What the real pair established, and what these fixtures stand in for:
///
/// - The patch is a 6.7 MB `.rar` containing **exactly one file**, a `.dds`,
///   and no `.ini`.
/// - The mod it patches ships **17 files** including a `.dds` of that same
///   name, and its `.ini` references that name.
/// - So dropping the first into the second's folder replaces one texture, every
///   reference still resolves, and the folder becomes indistinguishable from an
///   ordinary mod — the mixed folder this whole feature exists for.
/// - The target publishes two current files labelled `SFW Variants Only` and
///   `NSFW Variants Included`, which is the variant pair the update check's
///   label rule exists for.
void main() {
  /// The base mod's contents, in the spelling `FolderContents` produces:
  /// relative to the mod folder root, `/`-separated, lower-cased.
  ///
  /// The **naming convention is the real one** and it is the point: ZZZ assets
  /// are `<character><component><maptype>.<ext>`, so a filename is specific
  /// enough for a collision to mean something. A rule matching on `body.dds`
  /// would be worthless.
  const baseMod = <String>{
    'charabatterya.ib',
    'charabatteryb.ib',
    'charabatteryblend.buf',
    'charabatteryposition.buf',
    'charabatterytexcoord.buf',
    'charabh.ini',
    'charabodyadiffuse.dds',
    'charabodyaglowmap.dds',
    'charabodya.ib',
    'charabodyalightmap.dds',
    'charabodyamaterialmap.dds',
    'charabodyanormalmap.dds',
    'charabodyb.ib',
    'charabodyblend.buf',
    'charabodyposition.buf',
    'charabodytexcoord.buf',
    'charafaceheaddiffuse.dds',
  };

  /// The whole of what the patch ships.
  const assetPatch = <String>{'charabodyadiffuse.dds'};

  group('the fixtures carry the shape', () {
    test('the patch publishes one file and the target two variants', () {
      final patch =
          GbMod.fromJson(parseObject(loadGbFixture('mod_profile_asset_patch')))!;
      final target = GbMod.fromJson(
          parseObject(loadGbFixture('mod_profile_patch_target')))!;

      expect(patch.idRow, 900460);
      expect(patch.files!.single.file, 'character_a_body_retexture_fix.rar');
      expect(patch.files!.single.md5Checksum,
          '00000000000000000000000000000001');

      expect(target.idRow, 900282);
      expect(
        target.currentFiles!.map((f) => f.description),
        ['SFW Variants Only', 'NSFW Variants Included'],
        reason: 'the variant-label pair the update check\'s label rule exists '
            'for — the one thing about these two files taken verbatim',
      );
    });
  });

  group('the .ini rule is structurally blind to it', () {
    test('an archive with no .ini is never assessed at all', () {
      // Not "assessed and found innocent" — `looksLikePatch` requires
      // `hasIni`, so there is no verdict to give. Pinned so nobody tunes the
      // reference rule expecting this case to start working.
      final assessment = assessPatchShape(
        references: IniReferences.none,
        files: assetPatch,
        directories: const <String>{},
        hasIni: false,
      );
      expect(assessment.looksLikePatch, isFalse);
      expect(assessment.required, 0,
          reason: 'no .ini means no references to require anything');
    });
  });

  group('assessAssetPatch', () {
    test('names the library mod a bare asset replaces', () {
      final assessment = assessAssetPatch(
        files: assetPatch,
        hasIni: false,
        library: const {'CharA-AltProportions(NSFW)': baseMod},
      );

      expect(assessment.looksLikePatch, isTrue);
      expect(assessment.targets, ['CharA-AltProportions(NSFW)']);
    });

    test('a download that brings something new is not a patch', () {
      // The distinction that matters, and the reason "every file" rather than
      // "any file": a mod shipping one familiar texture beside its own new
      // meshes is a mod. Only a download with **nothing new in it** is
      // replacing rather than adding.
      final assessment = assessAssetPatch(
        files: const {'charabodyadiffuse.dds', 'brandnewmesh.ib'},
        hasIni: false,
        library: const {'CharA-AltProportions(NSFW)': baseMod},
      );
      expect(assessment.looksLikePatch, isFalse);
      expect(assessment.targets, isEmpty);
    });

    test('a genuinely incomplete download matches nothing', () {
      // The case the "may be incomplete" warning is actually for. It must keep
      // getting that warning rather than being told it is a patch.
      final assessment = assessAssetPatch(
        files: const {'somethingelse.dds'},
        hasIni: false,
        library: const {'CharA-AltProportions(NSFW)': baseMod},
      );
      expect(assessment.looksLikePatch, isFalse);
    });

    test('a download carrying an .ini is left to the reference rule', () {
      // One question, one owner. A download with an `.ini` is judged on what it
      // references — two rules answering for the same folder is how they come
      // to disagree.
      final assessment = assessAssetPatch(
        files: assetPatch,
        hasIni: true,
        library: const {'CharA-AltProportions(NSFW)': baseMod},
      );
      expect(assessment.looksLikePatch, isFalse);
    });

    test('an empty download is nothing, not a patch of everything', () {
      expect(
        assessAssetPatch(
          files: const <String>{},
          hasIni: false,
          library: const {'A': baseMod},
        ).looksLikePatch,
        isFalse,
      );
    });

    test('matching is on the file name, not on where it sits', () {
      // The patch author has no idea what folder layout you used — they ship
      // the file bare and expect you to drop it in. Requiring the same relative
      // path would miss every base mod that keeps its textures in a subfolder.
      final assessment = assessAssetPatch(
        files: const {'charabodyadiffuse.dds'},
        hasIni: false,
        library: const {
          'Base': {'res/textures/charabodyadiffuse.dds', 'chara.ini'},
        },
      );
      expect(assessment.targets, ['Base']);
    });

    test('several candidates are all reported, never picked between', () {
      // Two variants of one mod installed side by side is ordinary, and both
      // hold the file. Guesses may inform, never drive — so the user chooses.
      final assessment = assessAssetPatch(
        files: assetPatch,
        hasIni: false,
        library: const {
          'Base SFW': baseMod,
          'Base NSFW': baseMod,
        },
      );
      expect(assessment.targets, ['Base NSFW', 'Base SFW'],
          reason: 'sorted, so what the user reads does not depend on the order '
              'the filesystem enumerated the library in');
    });

    test('auxiliary files never make a match', () {
      // Every mod in a library has a `preview.png`, so counting them would make
      // a preview pack read as a patch of whatever it happened to be compared
      // against — and would let one shared name carry a whole download.
      final assessment = assessAssetPatch(
        files: const {'preview.png', 'readme.txt'},
        hasIni: false,
        library: const {
          'Some Mod': {'preview.png', 'readme.txt', 'body.dds'},
        },
      );
      expect(assessment.looksLikePatch, isFalse);
    });

    test('an auxiliary file rides along without breaking a real match', () {
      // A patch shipping its texture plus a screenshot is still a patch. The
      // rule is about what it *replaces*, and a preview replaces nothing.
      final assessment = assessAssetPatch(
        files: const {'charabodyadiffuse.dds', 'preview.png'},
        hasIni: false,
        library: const {'CharA-AltProportions(NSFW)': baseMod},
      );
      expect(assessment.looksLikePatch, isTrue);
      expect(assessment.targets, ['CharA-AltProportions(NSFW)']);
    });

    test('against a real library, when one is present', () async {
      // The I/O side, over actual extracted archives. Skipped unless
      // `ZZZ_ASSET_PATCH_LIBRARY` points at a directory laid out as a mods
      // folder — one extracted mod per subdirectory. Archives are hundreds of
      // megabytes and are nobody's business to check in, so this cannot be a
      // normal test; it exists so the claim above can be re-derived rather than
      // trusted.
      //
      //   ZZZ_ASSET_PATCH_LIBRARY=/path/to/mods flutter test \
      //     test/asset_patch_detection_test.dart
      final root = Platform.environment['ZZZ_ASSET_PATCH_LIBRARY'];
      final dir = Directory(root!);
      final names = [
        for (final e in dir.listSync())
          if (e is Directory) e.path.split(Platform.pathSeparator).last,
      ];
      final noIni = await ArchiveService.modsWithoutIni(dir.path, names);
      final found = await assetPatchesAmong(dir.path, noIni);

      for (final entry in found.entries) {
        // ignore: avoid_print
        print('PATCH ${entry.key} -> ${entry.value.targets.join(", ")} '
            '(${entry.value.replaced} file(s) replaced)');
      }
      for (final name in noIni) {
        if (found.containsKey(name)) continue;
        // ignore: avoid_print
        print('incomplete $name');
      }

      // The invariant that holds for any library: nothing reports itself, and
      // a mod with an `.ini` is never in the no-`.ini` list to begin with.
      for (final entry in found.entries) {
        expect(entry.value.targets, isNot(contains(entry.key)));
      }
    }, skip: Platform.environment['ZZZ_ASSET_PATCH_LIBRARY'] == null);

    test('the mod being installed is not compared against itself', () {
      // The check runs after the copy, so the incoming folder is *in* the
      // library by then. Every one of its files matches itself perfectly, and
      // without excluding it every no-.ini import would report itself as its
      // own patch.
      final assessment = assessAssetPatch(
        files: assetPatch,
        hasIni: false,
        library: const {
          'character_a_body_retexture_fix': assetPatch,
          'CharA-AltProportions(NSFW)': baseMod,
        },
        exclude: const {'character_a_body_retexture_fix'},
      );
      expect(assessment.targets, ['CharA-AltProportions(NSFW)']);
    });
  });
}
