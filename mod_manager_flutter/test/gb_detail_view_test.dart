import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_enums.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_image.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_mod.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/screens/components/marketplace/gb_detail_view.dart';
import 'package:mod_manager_flutter/services/gamebanana/content_filter.dart';
import 'package:mod_manager_flutter/services/installed_mods_index.dart';
import 'package:mod_manager_flutter/utils/markdown_style.dart';
import 'package:mod_manager_flutter/utils/marketplace_providers.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

import 'support/localized_harness.dart';

/// The mod detail screen, with its gallery navigation.
///
/// This file exists because nothing covered this widget, and two gallery bugs went
/// out through that gap — a stale preview on switch, and a strip that could only be
/// moved with shift+scroll. Both are only reachable by driving the thing.
void main() {
  GbImage image(String name) => GbImage.fromJson({
    '_sBaseUrl': 'https://images.gamebanana.com/img/ss/mods',
    '_sFile': '$name.jpg',
    '_sFile100': '100-_$name.jpg',
    '_sFile220': '220-_$name.jpg',
    '_sFile800': '800-_$name.jpg',
  })!;

  GbMod mod({int imageCount = 4}) => GbMod(
    idRow: 700727,
    name: 'A Mod',
    text: 'Some description',
    visibility: GbVisibility.show,
    files: const [],
    images: [for (var i = 0; i < imageCount; i++) image('img$i')],
  );

  Future<void> pumpDetail(
    WidgetTester tester, {
    int imageCount = 4,
    Size surfaceSize = const Size(1200, 800),
    // Overridden rather than left to load: unoverridden it reaches for
    // `ApiService`, which needs a real `SharedPreferences` and so resolves to an
    // error — silently, as an unread `AsyncValue`. Every "no badge" assertion
    // would then pass for the wrong reason.
    InstalledModsIndex installed = InstalledModsIndex.empty,
  }) async {
    await pumpLocalized(
      tester,
      GbDetailView(
        modId: 700727,
        onBack: () {},
        onDownload: (_, __) {},
        onOpenInBrowser: (_) {},
      ),
      surfaceSize: surfaceSize,
      overrides: [
        modProfileProvider(
          700727,
        ).overrideWith((ref) async => mod(imageCount: imageCount)),
        contentFilterProvider.overrideWith((ref) => ContentFilterMode.show),
        installedModsIndexProvider.overrideWith((ref) async => installed),
      ],
    );
    expectBuilt(GbDetailView);
  }

  /// The url the large preview is currently showing.
  String heroUrl(WidgetTester tester) {
    // The hero is the only 800px request on screen.
    final images = tester.widgetList<Image>(find.byType(Image));
    for (final img in images) {
      final provider = img.image;
      if (provider is ResizeImage && provider.width == 800) {
        return (provider.imageProvider as NetworkImage).url;
      }
    }
    fail('no 800px hero image found');
  }

  IconButton arrow(WidgetTester tester, IconData icon) =>
      tester.widget<IconButton>(
        find.ancestor(of: find.byIcon(icon), matching: find.byType(IconButton)),
      );

  group('gallery arrows', () {
    testWidgets('step forward and back through the previews', (tester) async {
      await pumpDetail(tester);
      expect(heroUrl(tester), contains('img0'));

      await tester.tap(find.byIcon(Icons.chevron_right));
      await tester.pumpAndSettle();
      expect(heroUrl(tester), contains('img1'));

      await tester.tap(find.byIcon(Icons.chevron_right));
      await tester.pumpAndSettle();
      expect(heroUrl(tester), contains('img2'));

      await tester.tap(find.byIcon(Icons.chevron_left));
      await tester.pumpAndSettle();
      expect(heroUrl(tester), contains('img1'));
    });

    testWidgets('clamp at both ends rather than wrapping', (tester) async {
      // Matches the "best of" carousel: a disabled arrow states where the list ends,
      // where looping silently reads as a glitch.
      await pumpDetail(tester, imageCount: 2);

      expect(
        arrow(tester, Icons.chevron_left).onPressed,
        isNull,
        reason: 'nothing before the first preview',
      );
      expect(arrow(tester, Icons.chevron_right).onPressed, isNotNull);

      await tester.tap(find.byIcon(Icons.chevron_right));
      await tester.pumpAndSettle();

      expect(arrow(tester, Icons.chevron_left).onPressed, isNotNull);
      expect(
        arrow(tester, Icons.chevron_right).onPressed,
        isNull,
        reason: 'nothing after the last preview',
      );
    });

    testWidgets('are absent for a single-image mod', (tester) async {
      // Nothing to step through, so the arrows would only obscure the preview.
      await pumpDetail(tester, imageCount: 1);
      expect(find.byIcon(Icons.chevron_left), findsNothing);
      expect(find.byIcon(Icons.chevron_right), findsNothing);
    });

    testWidgets('tapping a thumbnail still selects it', (tester) async {
      // The arrows are additive; the existing interaction must keep working.
      await pumpDetail(tester);
      // Scoped to the strip: the header's back button and "open in browser" are
      // InkWells too, so an unscoped index taps the wrong thing and this asserts
      // nothing.
      final thumbs = find.descendant(
        of: find.byType(Scrollbar),
        matching: find.byType(InkWell),
      );
      expect(thumbs, findsNWidgets(4));

      await tester.tap(thumbs.at(2));
      await tester.pumpAndSettle();
      expect(heroUrl(tester), contains('img2'));
    });
  });

  group('the thumbnail strip', () {
    testWidgets('has a permanently visible scrollbar', (tester) async {
      // A strip that scrolls with no indication that it scrolls is the reported
      // problem, so hover-to-discover is not enough.
      await pumpDetail(tester);
      final bar = tester.widget<Scrollbar>(find.byType(Scrollbar));
      expect(bar.thumbVisibility, isTrue);
      expect(
        bar.controller,
        isNotNull,
        reason: 'the bar and the list must share one controller',
      );
    });

    testWidgets('accepts mouse dragging', (tester) async {
      // Flutter's desktop scroll behaviour leaves the mouse out of `dragDevices`,
      // which is exactly why the strip could previously only be moved with
      // shift+scroll.
      await pumpDetail(tester);

      final config = tester.widget<ScrollConfiguration>(
        find
            .ancestor(
              of: find.byType(Scrollbar),
              matching: find.byType(ScrollConfiguration),
            )
            .first,
      );
      final devices = config.behavior.dragDevices;
      expect(devices, contains(PointerDeviceKind.mouse));
      expect(devices, contains(PointerDeviceKind.touch));
    });

    testWidgets('the mouse-drag override covers only the strip', (
      tester,
    ) async {
      // Scoped deliberately: the page is a vertical ListView holding selectable
      // description text, and mouse-dragging *that* would fight text selection. So
      // the override must contain exactly one scrollable — the strip — and not the
      // page it sits inside.
      await pumpDetail(tester);

      final override = find
          .ancestor(
            of: find.byType(Scrollbar),
            matching: find.byType(ScrollConfiguration),
          )
          .first;

      expect(
        find.descendant(of: override, matching: find.byType(Scrollable)),
        findsOneWidget,
        reason: 'two would mean the page inherited the override as well',
      );
    });

    testWidgets('a mouse drag actually moves it', (tester) async {
      await pumpDetail(tester, imageCount: 24);
      final strip = find.byType(Scrollbar);
      final controller = tester.widget<Scrollbar>(strip).controller!;
      expect(controller.offset, 0);

      await tester.drag(
        strip,
        const Offset(-200, 0),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();

      expect(
        controller.offset,
        greaterThan(100),
        reason: 'dragging with a mouse must scroll the strip',
      );
    });

    testWidgets('is absent for a single-image mod', (tester) async {
      await pumpDetail(tester, imageCount: 1);
      expect(find.byType(Scrollbar), findsNothing);
    });
  });

  group('the description column', () {
    testWidgets('stops at a readable measure and stays centred', (
      tester,
    ) async {
      // A maximised window is far wider than anyone can comfortably read
      // across, and GameBanana itself lays a description out in a ~522px
      // column — so the text it was written for is this shape, not the window's.
      await pumpDetail(tester, surfaceSize: const Size(1400, 2400));

      final description = tester.getRect(find.byType(MarkdownBody));
      expect(description.width, MarkdownScale.readingWidth);
      expect(description.center.dx, 1400 / 2);
    });

    testWidgets('gives way on a window narrower than the cap', (tester) async {
      // The cap is a maximum, not a width: below it the column must still fit
      // the window rather than overflow it.
      await pumpDetail(tester, surfaceSize: const Size(420, 2400));

      final description = tester.getRect(find.byType(MarkdownBody));
      expect(description.width, lessThan(MarkdownScale.readingWidth));
      expect(description.left, greaterThanOrEqualTo(0));
      expect(description.right, lessThanOrEqualTo(420));
      expect(tester.takeException(), isNull);
    });

    testWidgets('the heading stays aligned with the text it labels', (
      tester,
    ) async {
      await pumpDetail(tester, surfaceSize: const Size(1400, 2400));

      final heading = tester.getRect(find.text('Description'));
      final description = tester.getRect(find.byType(MarkdownBody));
      expect(heading.left, description.left);
    });
  });

  group('the "in your library" notice', () {
    testWidgets('is absent for a mod the library does not have',
        (tester) async {
      await pumpDetail(tester);
      expect(find.textContaining('In your library'), findsNothing);
    });

    testWidgets('names the folders, at mod level', (tester) async {
      // Mod level on purpose: for a library that predates the origin block this
      // is the *only* answer available — nothing local survives extraction to
      // identify which file was installed — so the screen must be able to say
      // "you have this mod" without pretending to know which file.
      await pumpDetail(
        tester,
        installed: InstalledModsIndex.fromMods([
          ModInfo(
            id: 'Remielle Swim',
            name: 'Remielle Swim',
            characterId: 'unknown',
            isActive: false,
            origin: const ModOrigin(
              provenance: OriginProvenance.importedFolder,
              source: 'gamebanana',
              modId: 700727,
              modIdConfidence: OriginConfidence.inferred,
            ),
          ),
        ]),
      );
      expect(
        find.text('In your library as Remielle Swim'),
        findsOneWidget,
      );
    });
  });
}
