import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/gamebanana/gamebanana.dart';

import '../support/fixtures.dart';

void main() {
  group('ProfilePage', () {
    late GbMod mod;

    setUp(() {
      mod = GbMod.fromJson(parseObject(loadGbFixture('mod_profile_531649')))!;
    });

    test('maps the mod-level fields', () {
      expect(mod.idRow, 531649);
      expect(mod.name, 'ZZMI RabbitFX - Glow FX + Censor Remover');
      expect(mod.version, '7.7');
      expect(mod.profileUrl, 'https://gamebanana.com/mods/531649');
      // Live counters, so these move whenever the fixture is re-captured —
      // they pin which key lands in which field, not the mod's popularity.
      expect(mod.likeCount, 3813);
      expect(mod.viewCount, 1069167);
      expect(mod.downloadCount, 452906);
      expect(mod.dateAdded!.isUtc, isTrue);
      expect(mod.dateAdded!.millisecondsSinceEpoch, 1722287660 * 1000);
      expect(mod.dateUpdated, isNotNull);
    });

    test('_sText is HTML and is carried through as-is', () {
      // Ours is markdown; converting is the install path's job, not the
      // parser's. This only pins that we do not silently drop it.
      expect(mod.text, isNotNull);
      expect(mod.text, contains('<'));
    });

    test('parses the submitter and category', () {
      expect(mod.submitter?.idRow, 2987570);
      expect(mod.submitter?.name, 'caverabbit');
      expect(mod.category?.idRow, 29874);
      expect(mod.category?.name, 'Other/Misc');
    });

    test('upstream-gone flags are read explicitly, not inferred', () {
      expect(mod.isPrivate, isFalse);
      expect(mod.isTrashed, isFalse);
      expect(mod.isWithheld, isFalse);
      expect(mod.isRemoteMissing, isFalse);
      // A different thing entirely: still present, author flagged it superseded.
      expect(mod.isObsolete, isFalse);
    });

    group('_aFiles', () {
      test('parses every file with its identifying fields', () {
        expect(mod.files, hasLength(6));
        final file = mod.files!.firstWhere((f) => f.idRow == 1491924);
        expect(file.file, isNotNull);
        expect(file.filesize, 7675340);
        expect(file.md5Checksum, 'ed55759a72c577a6aa682ba88d149fc3');
        expect(file.avResult, 'clean');
        expect(file.dateAdded, isNotNull);
        expect(file.isArchived, isFalse);
      });

      test('version and description are SEPARATE fields', () {
        // The single most important distinction in the file shape. `_sVersion`
        // is a version; `_sDescription` is the *variant* label. Conflating them
        // makes two variants of one release look like two releases.
        final file = mod.files!.firstWhere((f) => f.idRow == 1491924);
        expect(file.version, '1.0');
        expect(file.description, 'RabbitFX Fixer EXE Version');
        expect(file.version, isNot(file.description));
      });

      test('a file with no _sVersion yields null, not an empty string', () {
        final file = mod.files!.firstWhere((f) => f.idRow == 1492636);
        expect(file.version, isNull);
        expect(file.description, 'Glow demo');
      });
    });

    group('_aArchivedFiles', () {
      test('are parsed and flagged', () {
        // Superseded files still download, and an old local install matches one
        // of these more often than it matches the current file.
        expect(mod.archivedFiles, hasLength(8));
        expect(mod.archivedFiles!.every((f) => f.isArchived), isTrue);
        expect(mod.archivedFiles!.every((f) => f.md5Checksum != null), isTrue);
      });

      test('allFiles spans current and archived for hash matching', () {
        expect(mod.allFiles, hasLength(14));
      });
    });

    test('visibility and content ratings on an unrated mod', () {
      expect(mod.visibility, GbVisibility.show);
      expect(mod.effectiveVisibility, GbVisibility.show);
      expect(mod.contentRatings, isEmpty);
      expect(mod.hasContentRatings, isFalse);
    });
  });

  group('a content-rated ProfilePage', () {
    test('carries the hint and the reasons', () {
      final mod =
          GbMod.fromJson(parseObject(loadGbFixture('mod_profile_rated')))!;
      expect(mod.idRow, 528481);
      expect(mod.visibility, GbVisibility.warn);
      expect(mod.effectiveVisibility.needsContentWarning, isTrue);
      expect(mod.contentRatings, {'sa': 'Skimpy Attire'});
      expect(mod.hasContentRatings, isTrue);
    });
  });

  group('null means "not in this response", never zero', () {
    late GbMod listed;

    setUp(() {
      listed = parseEnvelope(loadGbFixture('mod_index_p1'), GbMod.fromJson)
          .records
          .first;
    });

    test('a listing record omits fields the profile has', () {
      // Index returns a compact subset. These must read as unknown, so the UI
      // renders nothing rather than a confident "0 downloads".
      expect(listed.downloadCount, isNull);
      expect(listed.text, isNull);
      expect(listed.files, isNull);
      expect(listed.archivedFiles, isNull);
      expect(listed.allFiles, isNull);
    });

    test('but the fields it does carry are populated', () {
      expect(listed.idRow, isPositive);
      expect(listed.name, isNotNull);
      expect(listed.likeCount, isNotNull);
      expect(listed.visibility, isNotNull);
    });

    test('a listing exposes the root category id via its url', () {
      // `_aRootCategory` carries no `_idRow` — only `_sProfileUrl` — yet the id
      // is what the Generic_Category browse filter needs.
      expect(listed.rootCategory, isNotNull);
      expect(listed.rootCategory!.idRow, isNotNull);
      expect(listed.rootCategory!.profileUrl,
          contains('/mods/cats/${listed.rootCategory!.idRow}'));
      expect(listed.displayCategory, isNotNull);
    });

    test('an absent visibility field falls closed to warn', () {
      final bare = GbMod.fromJson({'_idRow': 1})!;
      expect(bare.visibility, isNull);
      expect(bare.effectiveVisibility, GbVisibility.warn);
    });

    test('an unrecognised visibility value falls closed to warn', () {
      final odd = GbMod.fromJson({'_idRow': 1, '_sInitialVisibility': 'brand_new'})!;
      expect(odd.visibility, GbVisibility.warn);
    });

    test('an empty _aFiles is distinguishable from an absent one', () {
      expect(GbMod.fromJson({'_idRow': 1, '_aFiles': <dynamic>[]})!.files, isEmpty);
      expect(GbMod.fromJson({'_idRow': 1})!.files, isNull);
    });
  });

  group('wire-format quirks', () {
    test('_ts of 0 becomes null, not 1970', () {
      final mod = GbMod.fromJson({'_idRow': 1, '_tsDateUpdated': 0})!;
      expect(mod.dateUpdated, isNull);
    });

    test('_nStatus arriving as a string does not break the parse', () {
      final mod = GbMod.fromJson({'_idRow': 1, '_nStatus': '0'});
      expect(mod, isNotNull);
      expect(mod!.idRow, 1);
    });

    test('a record with no _idRow is dropped rather than half-parsed', () {
      expect(GbMod.fromJson({'_sName': 'orphan'}), isNull);
    });
  });

  group('envelope vs bare array', () {
    test('parseEnvelope reads _aMetadata and _aRecords', () {
      final page = parseEnvelope(loadGbFixture('mod_index_p1'), GbMod.fromJson);
      expect(page.records, hasLength(5));
      expect(page.recordCount, greaterThan(1000));
      expect(page.perPage, 5);
      expect(page.pageCount, isNotNull);
    });

    test('perPage is what the SERVER applied, not what we asked for', () {
      // The search fixture was captured with _nPerpage=30. The server silently
      // caps at 15 with no error, so trusting the request would be a lie.
      final page = parseEnvelope(loadGbFixture('search_ellen'), GbMod.fromJson);
      expect(page.perPage, 15);
      expect(page.records, hasLength(15));
    });

    test('parseBareList reads the array Mod/Categories returns', () {
      final roots =
          parseBareList(loadGbFixture('categories_root'), GbCategoryNode.fromJson);
      expect(roots, hasLength(4));
      final skins = roots.firstWhere((c) => c.idRow == 30305);
      expect(skins.name, 'Character Skins');
      expect(skins.itemCount, greaterThan(1000));
      expect(skins.hasChildren, isTrue);
    });

    test('the character subtree parses as nodes with counts', () {
      final children =
          parseBareList(loadGbFixture('categories_30305'), GbCategoryNode.fromJson);
      expect(children, hasLength(60));
      expect(children.every((c) => c.idRow > 0), isTrue);
      expect(children.first.itemCount, isPositive);
    });

    test('feeding an envelope to parseBareList throws loudly', () {
      // Silently tolerating the wrong shape would surface as an empty grid far
      // from the cause, so this must fail at the parse.
      expect(
        () => parseBareList(loadGbFixture('mod_index_p1'), GbMod.fromJson),
        throwsA(isA<GbFormatException>()),
      );
    });

    test('feeding a bare array to parseEnvelope throws loudly', () {
      expect(
        () => parseEnvelope(loadGbFixture('categories_root'), GbMod.fromJson),
        throwsA(isA<GbFormatException>()),
      );
    });

    test('an envelope without _aRecords throws', () {
      expect(
        () => parseEnvelope('{"_aMetadata":{}}', GbMod.fromJson),
        throwsA(isA<GbFormatException>()),
      );
    });

    test('a non-JSON body throws GbFormatException, not a raw FormatException', () {
      // What a Cloudflare interstitial looks like from here.
      expect(
        () => parseEnvelope('<html><body>Just a moment…</body></html>',
            GbMod.fromJson),
        throwsA(isA<GbFormatException>()),
      );
      expect(() => gbDecode(''), throwsA(isA<GbFormatException>()));
    });
  });

  group('DownloadPage', () {
    test('carries the file lists', () {
      // **The app does not request this endpoint** — the update check gets its
      // file lists from `Mod/Multi` (50 mods per request, where this is one) and
      // its release grouping from `Mod/<id>/Updates`, so no `Uri` is built for
      // it. The capture and this test stay anyway: they are recorded evidence
      // about an undocumented API, they cost nothing when our own code changes,
      // and they are what would make wiring it up cheap if a per-mod "did the
      // file list change?" check is ever wanted.
      //
      // The detail that would bite whoever does: it carries no `_idRow`, so the
      // caller has to supply the mod id — every other response identifies itself.
      final json = parseObject(loadGbFixture('download_page_531649'));
      expect(GbFile.listFrom(json['_aFiles']), hasLength(6));
      expect(GbFile.listFrom(json['_aArchivedFiles']), hasLength(8));
      expect(json.containsKey('_idRow'), isFalse);
    });
  });
}
