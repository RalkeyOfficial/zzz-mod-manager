import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/core/constants.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/screens/components/mod_card_widget.dart';

import 'support/localized_harness.dart';

/// Mod covers must be decoded at card size, not at file size.
///
/// This guards a bug with no visible symptom where it is caused. `ImageCache` is
/// bounded by **decoded** bytes (100 MiB by default), and a cover is a full
/// screenshot: measured on a real library, 49 covers came to 213 MB decoded at
/// native size, single images reaching 14 MB. About seven cards therefore evicted
/// everything else in the cache — including the marketplace's network thumbnails,
/// which is where it *did* show up: switching to Mods and back re-downloaded every
/// preview image.
///
/// So the assertion is about the `cacheWidth` reaching the decoder, because nothing
/// on screen looks different either way.
void main() {
  late Directory temp;
  late String imagePath;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('zzz_cover_test_');
    // A real file has to exist: the card checks `existsSync()` before building an
    // Image at all, so a fake path would make this pass by rendering nothing.
    imagePath = '${temp.path}/cover.png';
    await File(imagePath).writeAsBytes(_onePixelPng);
  });

  tearDown(() async {
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  ModInfo modWith(String? image) => ModInfo(
        id: 'Some Mod',
        name: 'Some Mod',
        characterId: 'ellen',
        isActive: false,
        imagePath: image,
      );

  Future<void> pumpCard(WidgetTester tester, ModInfo mod) async {
    await pumpLocalized(
      tester,
      SizedBox(
        width: AppConstants.modCardWidth,
        height: 260,
        child: ModCardWidget(
          mod: mod,
          isDarkMode: true,
          onFavoriteToggle: () {},
          onShowDetails: () {},
          onOpenLink: () {},
        ),
      ),
    );
    expectBuilt(ModCardWidget);
  }

  testWidgets('the cover is decoded at the card width, not the file width',
      (tester) async {
    await pumpCard(tester, modWith(imagePath));

    final image = tester.widget<Image>(find.byType(Image));
    // `cacheWidth` wraps the provider in a ResizeImage — that is the observable
    // effect, and its absence is exactly the bug.
    expect(image.image, isA<ResizeImage>(),
        reason: 'an unbounded decode holds the full-resolution bitmap');
    expect((image.image as ResizeImage).width, AppConstants.modCardDecodeWidth);
  });

  testWidgets('the decode width stays well under a real cover', (tester) async {
    // Not a tautology: it pins the *intent*. Raising this to native resolution
    // would silently restore the eviction problem while every test still passed.
    expect(AppConstants.modCardDecodeWidth,
        greaterThanOrEqualTo(AppConstants.modCardWidth.toInt()),
        reason: 'must stay sharp on a hi-DPI display');
    expect(AppConstants.modCardDecodeWidth, lessThan(1600),
        reason: 'real covers are 2000-2560px wide; decoding those is the bug');

    // 640x361x4 bytes is well under a megabyte, against ~14 MB unbounded.
    const bytes = AppConstants.modCardDecodeWidth *
        (AppConstants.modCardDecodeWidth * 9 ~/ 16) *
        4;
    expect(bytes, lessThan(2 * 1024 * 1024));
  });

  testWidgets('a mod with no cover builds no Image at all', (tester) async {
    await pumpCard(tester, modWith(null));
    expect(find.byType(Image), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

/// Smallest valid PNG — the test asserts how the file is decoded, not what it is.
final List<int> _onePixelPng = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
];
