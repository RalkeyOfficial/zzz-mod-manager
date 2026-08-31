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
    test('a bare game asset with no .ini is a patch', () {
      final assessment = assessAssetPatch(files: assetPatch, hasIni: false);
      expect(assessment.looksLikePatch, isTrue);
      expect(assessment.assets, 1);
    });

    test('it does not depend on the mod it patches being installed', () {
      // **The whole reason the rule is intrinsic.** Downloading a patch before
      // its base mod is ordinary — you find the patch, then go and get what it
      // patches — and a rule that compared against the library called that
      // ordering "the mod may be incomplete", which points at the wrong fix.
      //
      // The judgement is about this download and nothing else, so there is no
      // ordering in which it can be wrong, and no library walk to pay for.
      expect(
        assessAssetPatch(files: assetPatch, hasIni: false).looksLikePatch,
        isTrue,
      );
      expect(
        assessAssetPatch(files: baseMod, hasIni: true).looksLikePatch,
        isFalse,
      );
    });

    test('a download carrying an .ini is left to the reference rule', () {
      // One question, one owner. A download with an `.ini` is judged on what it
      // references — two rules answering for the same folder is how they come
      // to disagree.
      expect(
        assessAssetPatch(files: assetPatch, hasIni: true).looksLikePatch,
        isFalse,
      );
    });

    test('an empty download is nothing, not a patch of everything', () {
      expect(
        assessAssetPatch(files: const <String>{}, hasIni: false).looksLikePatch,
        isFalse,
      );
    });

    test('buffers and index buffers count as much as textures', () {
      // A patch can replace geometry rather than a texture. All three are
      // things only an `.ini` can load, which is the whole of the rule.
      for (final file in const [
        'charabodyblend.buf',
        'charabodya.ib',
        'charabodyposition.vb',
      ]) {
        expect(
          assessAssetPatch(files: {file}, hasIni: false).looksLikePatch,
          isTrue,
          reason: file,
        );
      }
    });

    test('a folder of screenshots is not a patch', () {
      // The case the "may be incomplete" warning is actually for: a `previews`
      // folder installed as its own mod. Images are not loaded through an
      // `.ini`, so nothing here is waiting for one.
      expect(
        assessAssetPatch(
          files: const {'preview.png', '01.jpg', 'readme.txt'},
          hasIni: false,
        ).looksLikePatch,
        isFalse,
      );
    });

    test('a patch shipping a screenshot beside its texture is still a patch',
        () {
      // The auxiliary file rides along. What decides is that *something* here
      // needs an `.ini` that is not here.
      final assessment = assessAssetPatch(
        files: const {'charabodyadiffuse.dds', 'preview.png'},
        hasIni: false,
      );
      expect(assessment.looksLikePatch, isTrue);
      expect(assessment.assets, 1,
          reason: 'the screenshot is not one of the files needing an .ini');
    });

    test('an archive nested inside the folder is not an asset', () {
      // A download that unpacked to another archive is a broken download, and
      // telling the user it is a patch would send them looking for a mod to
      // apply it to.
      expect(
        assessAssetPatch(
          files: const {'mod.zip'},
          hasIni: false,
        ).looksLikePatch,
        isFalse,
      );
    });

    test('over a real library, when one is present', () async {
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
        print('PATCH ${entry.key} (${entry.value.assets} asset(s) needing '
            'an .ini that is not there)');
      }
      for (final name in noIni) {
        if (found.containsKey(name)) continue;
        // ignore: avoid_print
        print('incomplete $name');
      }

      // The invariant that holds for any library: every mod reported is one
      // that actually ships an asset, and a mod with an `.ini` never reaches
      // this list at all.
      for (final entry in found.entries) {
        expect(entry.value.assets, greaterThan(0));
      }
    }, skip: Platform.environment['ZZZ_ASSET_PATCH_LIBRARY'] == null);
  });
}
