import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_image.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_mod.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_page.dart';

import '../support/fixtures.dart';

/// The image size ladder. Only `_sFile` and `_sFile100` are guaranteed by the
/// API, so the rule under test is: **never fabricate a variant filename.**
/// Building `530-90_<file>.jpg` for an image that has no 530 produces a url
/// that 404s, and a broken thumbnail grid is the visible symptom.
void main() {
  late GbMod profile;

  setUp(() {
    profile = GbMod.fromJson(parseObject(loadGbFixture('mod_profile_531649')))!;
  });

  test('the anchor fixture carries both ladder cases', () {
    // Guards the fixture itself: if a re-capture picked images that all have
    // the same variants, the tests below would silently stop proving anything.
    expect(profile.images.length, greaterThan(1));
    expect(profile.images.first.variants.keys, containsAll(<int>[100, 220, 530]));
    expect(profile.images[1].variants.keys, [100]);
  });

  group('an image with the full ladder', () {
    test('urlAtLeast picks the smallest variant that is big enough', () {
      final image = profile.images.first;
      expect(image.urlAtLeast(200), endsWith('/220-90_66a8054aa3360.jpg'));
      expect(image.urlAtLeast(530), endsWith('/530-90_66a8054aa3360.jpg'));
    });

    test('urlAtLeast falls back to full size rather than inventing a size', () {
      // This fixture has no 800 variant. The honest answer is the original.
      final image = profile.images.first;
      expect(image.variants.containsKey(800), isFalse);
      expect(image.urlAtLeast(800), image.fullUrl);
      expect(image.urlAtLeast(800), endsWith('/66a8054aa3360.jpg'));
    });

    test('urlAtMost picks the largest variant that fits', () {
      expect(profile.images.first.urlAtMost(530),
          endsWith('/530-90_66a8054aa3360.jpg'));
    });

    test('thumbnailUrl uses the 220 variant', () {
      expect(profile.images.first.thumbnailUrl,
          endsWith('/220-90_66a8054aa3360.jpg'));
    });
  });

  group('an image with only _sFile and _sFile100', () {
    test('thumbnailUrl degrades to the 100 variant', () {
      expect(profile.images[1].thumbnailUrl,
          endsWith('/100-90_66a805529113e.jpg'));
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
}
