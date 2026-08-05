import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_image.dart';
import 'package:mod_manager_flutter/screens/components/marketplace/gb_thumbnail.dart';
import 'package:mod_manager_flutter/services/gamebanana/content_filter.dart';

import 'support/localized_harness.dart';

/// Progressive loading for GameBanana previews.
///
/// The behaviour: switching preview images on the detail screen used to leave the
/// frame empty for the length of an 800px download, even though the strip below had
/// already fetched a small copy of the very same image. So the small one now holds
/// the frame and the large one fades in over it.
///
/// The assertion that actually matters is the **cache key**: the placeholder is only
/// free if it resolves to the identical `ResizeImage(NetworkImage(url))` that another
/// widget already requested. If it doesn't, this "optimisation" is a second download.
void main() {
  /// An image published with the full variant ladder.
  GbImage laddered() => GbImage.fromJson(const {
        '_sBaseUrl': 'https://images.gamebanana.com/img/ss/mods',
        '_sFile': 'original.jpg',
        '_sFile100': '100-_original.jpg',
        '_sFile220': '220-_original.jpg',
        '_sFile530': '530-_original.jpg',
        '_sFile800': '800-_original.jpg',
      })!;

  /// The common real case: only the two guaranteed sizes.
  GbImage sparse() => GbImage.fromJson(const {
        '_sBaseUrl': 'https://images.gamebanana.com/img/ss/mods',
        '_sFile': 'sparse.jpg',
        '_sFile100': '100-_sparse.jpg',
      })!;

  Future<void> pump(
    WidgetTester tester, {
    required GbImage? image,
    int minWidth = 800,
    int? placeholderMinWidth,
    ContentTreatment treatment = ContentTreatment.show,
  }) async {
    await pumpLocalized(
      tester,
      SizedBox(
        width: 900,
        height: 500,
        child: GbThumbnail(
          image: image,
          treatment: treatment,
          minWidth: minWidth,
          placeholderMinWidth: placeholderMinWidth,
        ),
      ),
    );
    expectBuilt(GbThumbnail);
  }

  /// The two layers, low-res first.
  List<Image> layers(WidgetTester tester) =>
      tester.widgetList<Image>(find.byType(Image)).toList();

  ResizeImage providerOf(Image image) => image.image as ResizeImage;
  String urlOf(Image image) =>
      (providerOf(image).imageProvider as NetworkImage).url;

  group('with a placeholder width', () {
    testWidgets('stacks a small copy under the large one', (tester) async {
      await pump(tester, image: laddered(), placeholderMinWidth: 100);
      final built = layers(tester);
      expect(built.length, 2, reason: 'small underneath, large on top');
      expect(urlOf(built.first), contains('100-'));
      expect(urlOf(built.last), contains('800-'));
    });

    testWidgets('does not cross-fade', (tester) async {
      // Asked for explicitly: the swap should be instant, not animated. Scoped to
      // this widget's own subtree — the enclosing MaterialApp brings its own
      // FadeTransitions, which an unscoped finder would pick up and blame on us.
      await pump(tester, image: laddered(), placeholderMinWidth: 100);
      Finder inside(Type type) =>
          find.descendant(of: find.byType(GbThumbnail), matching: find.byType(type));

      expect(inside(FadeInImage), findsNothing);
      expect(inside(AnimatedOpacity), findsNothing);
      expect(inside(FadeTransition), findsNothing);
    });

    testWidgets('the small layer key matches what the strip requests',
        (tester) async {
      // The strip renders `GbThumbnail(minWidth: 100)`, i.e. `Image.network(url,
      // cacheWidth: 100)` — which is `ResizeImage(NetworkImage(url), width: 100)`.
      // This layer must be byte-identical to that, or it is a fresh download and the
      // whole point is lost.
      await pump(tester, image: laddered(), placeholderMinWidth: 100);
      expect(
        providerOf(layers(tester).first),
        ResizeImage(NetworkImage(laddered().urlAtLeast(100)), width: 100),
        reason: 'same cache key as the strip, so this layer is a lookup',
      );
    });

    testWidgets('both layers keep their decode bounded', (tester) async {
      await pump(tester, image: laddered(), placeholderMinWidth: 100);
      final built = layers(tester);
      expect(providerOf(built.first).width, 100);
      expect(providerOf(built.last).width, 800,
          reason: 'the decode bound must survive the change');
    });

    testWidgets('both layers use the same fit so nothing shifts',
        (tester) async {
      await pump(tester, image: laddered(), placeholderMinWidth: 100);
      final built = layers(tester);
      expect(built.first.fit, built.last.fit);
    });
  });

  group('the stand-in is softened', () {
    /// The ImageFiltered wrapping the low-res layer (the only one when the NSFW
    /// treatment is `show`).
    ImageFiltered upscaleBlur(WidgetTester tester) =>
        tester.widget<ImageFiltered>(find.byType(ImageFiltered));

    testWidgets('only the small layer is blurred, not the large one',
        (tester) async {
      // Blurring the sharp image would defeat the point of downloading it.
      await pump(tester, image: laddered(), placeholderMinWidth: 100);

      expect(find.byType(ImageFiltered), findsOneWidget);
      final blurred = find.descendant(
        of: find.byType(ImageFiltered),
        matching: find.byType(Image),
      );
      expect(blurred, findsOneWidget);
      expect(urlOf(tester.widget<Image>(blurred)), contains('100-'),
          reason: 'the softened layer must be the stand-in');
    });

    testWidgets('the blur scales with how far the image is stretched',
        (tester) async {
      // 100px into an 800px frame is eight source pixels per displayed block, so
      // half a block is a sigma of 4.
      await pump(tester, image: laddered(), minWidth: 800, placeholderMinWidth: 100);
      expect(upscaleBlur(tester).imageFilter,
          ImageFilter.blur(sigmaX: 4.0, sigmaY: 4.0));
    });

    testWidgets('a barely-stretched stand-in gets the floor, not a smear',
        (tester) async {
      // 220 into 530 is close to 1:1; the same sigma as the 8x case would look
      // smeared rather than soft.
      await pump(tester, image: laddered(), minWidth: 530, placeholderMinWidth: 220);
      expect(upscaleBlur(tester).imageFilter,
          ImageFilter.blur(sigmaX: 1.5, sigmaY: 1.5));
    });

    testWidgets('a single-layer thumbnail is never blurred', (tester) async {
      await pump(tester, image: laddered());
      expect(find.byType(ImageFiltered), findsNothing);
    });
  });

  group('switching to a different image', () {
    GbImage other() => GbImage.fromJson(const {
          '_sBaseUrl': 'https://images.gamebanana.com/img/ss/mods',
          '_sFile': 'other.jpg',
          '_sFile100': '100-_other.jpg',
          '_sFile800': '800-_other.jpg',
        })!;

    Future<void> pumpImage(WidgetTester tester, GbImage image) => pumpLocalized(
          tester,
          SizedBox(
            width: 900,
            height: 500,
            child: GbThumbnail(
              image: image,
              treatment: ContentTreatment.show,
              minWidth: 800,
              placeholderMinWidth: 100,
            ),
          ),
        );

    testWidgets('never holds the previous image while loading', (tester) async {
      // The property that was broken. `FadeInImage` kept the previously loaded
      // image on a provider change, so the preview showed the wrong mod until the
      // download finished. A plain Image defaults to gaplessPlayback: false, which
      // clears instead — letting the small copy underneath show through.
      await pumpImage(tester, laddered());
      await pumpImage(tester, other());

      for (final layer in layers(tester)) {
        expect(layer.gaplessPlayback, isFalse,
            reason: 'gapless playback is what pinned the stale image');
      }
    });

    testWidgets('both layers point at the new image', (tester) async {
      await pumpImage(tester, laddered());
      await pumpImage(tester, other());

      final built = layers(tester);
      expect(urlOf(built.first), contains('100-_other'),
          reason: 'the stand-in must be the new image, not the old one');
      expect(urlOf(built.last), contains('800-_other'));
    });
  });

  group('when a placeholder would be pointless', () {
    testWidgets('no placeholder width means a plain image', (tester) async {
      await pump(tester, image: laddered());
      expect(find.byType(FadeInImage), findsNothing);
      expect(find.byType(Image), findsOneWidget);
    });

    testWidgets('an image with no smaller variant renders a single layer',
        (tester) async {
      // `sparse` has only `_sFile100` and the original. Asking for 100 at both ends
      // resolves to the same file, so a second layer would be a duplicate request
      // stacked on itself.
      await pump(tester, image: sparse(), minWidth: 100, placeholderMinWidth: 100);
      expect(find.byType(Image), findsOneWidget,
          reason: 'same url both sides — no reason for two layers');
    });

    testWidgets('a sparse image still gets a stand-in for the large view',
        (tester) async {
      // This is the case that benefits most: the 800px request falls back to the
      // full-resolution original, which is the slowest download of all.
      await pump(tester, image: sparse(), minWidth: 800, placeholderMinWidth: 100);

      final built = layers(tester);
      expect(built.length, 2);
      expect(providerOf(built.first).width, 100);
      expect(urlOf(built.last), contains('sparse.jpg'),
          reason: 'no 800 variant published, so it falls back to the original');
    });

    testWidgets('a null image renders the empty placeholder only', (tester) async {
      await pump(tester, image: null, placeholderMinWidth: 100);
      expect(find.byType(Image), findsNothing);
      expect(find.byIcon(Icons.image_not_supported_outlined), findsOneWidget);
    });
  });

  testWidgets('the blur treatment still wraps both layers', (tester) async {
    // The NSFW blur must not be lost by the restructure — that would un-blur adult
    // content, and blurring only the top layer would leave the small copy sharp.
    await pump(
      tester,
      image: laddered(),
      placeholderMinWidth: 100,
      treatment: ContentTreatment.blur,
    );
    // Two now: the outer NSFW blur, and the inner one softening the stand-in.
    // Tree order is outermost first, and the outer one must contain both layers —
    // blurring only the sharp image would leave the stand-in legible.
    expect(find.byType(ImageFiltered), findsNWidgets(2));
    expect(
      find.descendant(
        of: find.byType(ImageFiltered).first,
        matching: find.byType(Image),
      ),
      findsNWidgets(2),
      reason: 'the content blur must cover both layers',
    );
  });
}
