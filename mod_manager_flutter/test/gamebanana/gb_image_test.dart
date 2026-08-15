import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_image.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_mod.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_page.dart';

import '../support/fixtures.dart';

/// The image size ladder, which is **not uniform**: on apiv13 a cover publishes
/// 220 and 530 while the gallery images behind it publish only 100. So the rule
/// under test is: **never fabricate a variant filename.**
///
/// That rule got stricter with apiv13, which is worth knowing before touching
/// this. Under apiv11 a variant name was derivable from the original
/// (`66a8054aa3360.jpg` → `530-90_66a8054aa3360.jpg`), so fabricating one was at
/// least *possible*. apiv13 names thumbnails by a hash of its own
/// (`sgi_common_thumbs_f971c2553300cb0be23b4b50b45fc62f_530.webp`) that has no
/// relationship to `_sFile` — a variant that wasn't published cannot be
/// constructed at all, only fallen back from.
void main() {
  late GbMod profile;

  setUp(() {
    profile = GbMod.fromJson(parseObject(loadGbFixture('mod_profile_531649')))!;
  });

  test('the anchor fixture carries both ladder cases', () {
    // Guards the fixture itself: if a re-capture picked images that all have
    // the same variants, the tests below would silently stop proving anything.
    expect(profile.images.length, greaterThan(1));
    expect(profile.images.first.variants.keys, containsAll(<int>[220, 530]));
    expect(profile.images[1].variants.keys, [100]);
  });

  group('an image with the full ladder', () {
    test('urlAtLeast picks the smallest variant that is big enough', () {
      final image = profile.images.first;
      expect(
        image.urlAtLeast(200),
        endsWith(
          '/sgi_common_thumbs_f971c2553300cb0be23b4b50b45fc62f_220.webp',
        ),
      );
      expect(
        image.urlAtLeast(530),
        endsWith(
          '/sgi_common_thumbs_f971c2553300cb0be23b4b50b45fc62f_530.webp',
        ),
      );
    });

    test('urlAtLeast falls back to full size rather than inventing a size', () {
      // This fixture has no 800 variant. The honest answer is the original.
      final image = profile.images.first;
      expect(image.variants.containsKey(800), isFalse);
      expect(image.urlAtLeast(800), image.fullUrl);
      expect(image.urlAtLeast(800), endsWith('/66a8054aa3360.jpg'));
    });

    test('urlAtMost picks the largest variant that fits', () {
      expect(
        profile.images.first.urlAtMost(530),
        endsWith(
          '/sgi_common_thumbs_f971c2553300cb0be23b4b50b45fc62f_530.webp',
        ),
      );
    });

    test('thumbnailUrl uses the 220 variant', () {
      expect(
        profile.images.first.thumbnailUrl,
        endsWith(
          '/sgi_common_thumbs_f971c2553300cb0be23b4b50b45fc62f_220.webp',
        ),
      );
    });
  });

  group('an image with only _sFile and _sFile100', () {
    test('thumbnailUrl degrades to the 100 variant', () {
      expect(
        profile.images[1].thumbnailUrl,
        endsWith(
          '/sgi_common_thumbs_cb198343248ecf2a89bc6c7e808fda7d_100.webp',
        ),
      );
    });

    test('anything larger falls through to full size', () {
      final image = profile.images[1];
      expect(image.urlAtLeast(220), image.fullUrl);
      expect(image.urlAtLeast(530), image.fullUrl);
      expect(image.fullUrl, endsWith('/66a805529113e.jpg'));
    });
  });

  test('urls join base and file with exactly one slash', () {
    final image = profile.images.first;
    expect(image.fullUrl,
        'https://images.gamebanana.com/img/ss/mods/66a8054aa3360.jpg');
    expect(image.fullUrl, isNot(contains('//66a')));
  });

  test('a trailing slash on the base url does not double up', () {
    final image = GbImage.fromJson({
      '_sBaseUrl': 'https://images.gamebanana.com/img/ss/mods/',
      '_sFile': 'x.jpg',
    })!;
    expect(image.fullUrl, 'https://images.gamebanana.com/img/ss/mods/x.jpg');
  });

  test('dimensions are read where the API supplies them', () {
    expect(profile.images.first.dimensions[220], (width: 220, height: 193));
    expect(profile.images.first.dimensions[530], (width: 530, height: 466));
  });

  test('an entry without _sFile is dropped rather than half-parsed', () {
    expect(GbImage.fromJson({'_sBaseUrl': 'https://x.test'}), isNull);
  });

  test('an unknown future variant size is picked up for free', () {
    // Variants are discovered by scanning keys, so a size GameBanana starts
    // emitting needs no code change here.
    final image = GbImage.fromJson({
      '_sBaseUrl': 'https://x.test',
      '_sFile': 'a.jpg',
      '_sFile1600': '1600_a.jpg',
    })!;
    expect(image.urlAtLeast(1000), 'https://x.test/1600_a.jpg');
  });

  test('the pixelated SFW twin is ignored, not treated as a variant', () {
    // apiv13 publishes `_sFileNNNSfw` for `warn`/`hide` mods. We deliberately do
    // not use it — `GbThumbnail` applies its own blur — and the thing that would
    // actually break is subtler than "an unused feature": a key-scanning parser
    // that accepted it would file the *censored* image as a normal 220 variant
    // and serve it to users who had asked to see everything.
    final image = GbImage.fromJson({
      '_sBaseUrl': 'https://x.test',
      '_sFile': 'a.jpg',
      '_sFile220': 'a_220.webp',
      '_sFile220Sfw': 'a_220_sfw.webp',
      '_hFile220Sfw': 137,
    })!;
    expect(image.variants.keys, [220]);
    expect(image.urlAtLeast(220), 'https://x.test/a_220.webp');
    expect(image.variants.values, isNot(contains(contains('sfw'))));
  });

  group('listFromPreviewContent handles both container spellings', () {
    // The asymmetry is apiv13's, not ours: a profile sends the whole gallery
    // under `screenshots`, every listing sends only the cover under a singular
    // `screenshot` **object**. Reading one key would fail silently as an empty
    // gallery rather than as an error.
    test('a profile yields the full gallery from `screenshots`', () {
      expect(profile.images.length, 15);
    });

    test('a listing yields exactly one image from `screenshot`', () {
      final listed = GbImage.listFromPreviewContent({
        'screenshot': {'_sBaseUrl': 'https://x.test', '_sFile': 'cover.jpg'},
      });
      expect(listed, hasLength(1));
      expect(listed.single.fullUrl, 'https://x.test/cover.jpg');
    });

    test('absent or malformed preview content is empty, not an error', () {
      for (final raw in <Object?>[null, 'nope', 42, <String, dynamic>{}]) {
        expect(GbImage.listFromPreviewContent(raw), isEmpty, reason: '$raw');
      }
    });
  });
}
