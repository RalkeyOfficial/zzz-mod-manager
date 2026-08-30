import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_category.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_enums.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_image.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_mod.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_page.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/screens/components/marketplace/gb_detail_view.dart';
import 'package:mod_manager_flutter/services/gamebanana/content_filter.dart';
import 'package:mod_manager_flutter/services/installed_mods_index.dart';
import 'package:mod_manager_flutter/utils/markdown_style.dart';
import 'package:mod_manager_flutter/utils/marketplace_providers.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

import 'support/fixtures.dart';
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
    // The whole profile, for the tests that are about a field rather than about
    // the gallery. Defaults to the shared fixture.
    GbMod? profile,
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
        ).overrideWith((ref) async => profile ?? mod(imageCount: imageCount)),
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

  group('the dates', () {
    /// The two timestamps as the api sends them, in **seconds**.
    GbMod dated({DateTime? added, DateTime? updated}) => GbMod(
      idRow: 700727,
      name: 'A Mod',
      visibility: GbVisibility.show,
      files: const [],
      dateAdded: added,
      dateUpdated: updated,
    );

    testWidgets('the first release is shown', (tester) async {
      // It was missing entirely: the screen only ever rendered one date slot.
      await pumpDetail(
        tester,
        profile: dated(added: DateTime.utc(2024, 9, 12, 12)),
      );
      expect(find.textContaining('released 2024-09-12'), findsOneWidget);
    });

    testWidgets('a mod that has never been updated says so by omission',
        (tester) async {
      // `_tsDateUpdated` is null until a mod is actually updated, and the old
      // `dateUpdated ?? dateAdded` fallback turned that null into "updated
      // <release date>" — the one reading of these fields that states something
      // untrue.
      await pumpDetail(
        tester,
        profile: dated(added: DateTime.utc(2024, 9, 12, 12)),
      );
      expect(find.textContaining('updated'), findsNothing);
    });

    testWidgets('both are shown once there is an update', (tester) async {
      await pumpDetail(
        tester,
        profile: dated(
          added: DateTime.utc(2024, 9, 12, 12),
          updated: DateTime.utc(2026, 3, 4, 12),
        ),
      );
      expect(find.textContaining('released 2024-09-12'), findsOneWidget);
      expect(find.textContaining('updated 2026-03-04'), findsOneWidget);
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

  group('the category links to everything else under it', () {
    /// The detail view over [category], with a container so the query it writes
    /// can be read back.
    Future<ProviderContainer> pumpCategory(
      WidgetTester tester,
      GbCategoryRef? category, {
      GbCategoryRef? root,
      VoidCallback? onBack,
    }) async {
      final container = ProviderContainer(overrides: [
        modProfileProvider(700727).overrideWith((ref) async => GbMod(
              idRow: 700727,
              name: 'A Mod',
              visibility: GbVisibility.show,
              files: const [],
              category: category,
              rootCategory: root,
            )),
        contentFilterProvider.overrideWith((ref) => ContentFilterMode.show),
        installedModsIndexProvider
            .overrideWith((ref) async => InstalledModsIndex.empty),
      ]);
      addTearDown(container.dispose);

      await pumpLocalized(
        tester,
        GbDetailView(
          modId: 700727,
          onBack: onBack ?? () {},
          onDownload: (_, __) {},
          onOpenInBrowser: (_) {},
        ),
        container: container,
      );
      expectBuilt(GbDetailView);
      return container;
    }

    testWidgets('tapping it filters the grid and goes back', (tester) async {
      var wentBack = false;
      final container = await pumpCategory(
        tester,
        const GbCategoryRef(idRow: 30306, name: 'Ellen Joe'),
        root: const GbCategoryRef(idRow: 30305, name: 'Character Skins'),
        onBack: () => wentBack = true,
      );

      await tester.tap(find.text('Ellen Joe'));
      await tester.pumpAndSettle();

      final query = container.read(marketplaceQueryProvider);
      expect(query.categoryId, 30306);
      expect(query.page, 1, reason: 'a new filter starts at the first page');
      expect(query.mode, MarketplaceMode.browse);
      expect(wentBack, isTrue, reason: 'the grid has to be on screen to see it');
    });

    testWidgets('expands the root so the selection is visible', (tester) async {
      // The panel highlights a child only while its parent is open; without
      // this the grid comes back filtered and the panel looks untouched.
      final container = await pumpCategory(
        tester,
        const GbCategoryRef(idRow: 30306, name: 'Ellen Joe'),
        root: const GbCategoryRef(idRow: 30305, name: 'Character Skins'),
      );

      await tester.tap(find.text('Ellen Joe'));
      await tester.pumpAndSettle();

      expect(container.read(expandedCategoryProvider), 30305);
    });

    testWidgets('a root category works the same way', (tester) async {
      // "Bangboo Skins" and the rest are reached through `displayCategory`'s
      // fallback, so they take the identical path.
      final container = await pumpCategory(
        tester,
        null,
        root: const GbCategoryRef(idRow: 30702, name: 'Bangboo Skins'),
      );

      await tester.tap(find.text('Bangboo Skins'));
      await tester.pumpAndSettle();

      expect(container.read(marketplaceQueryProvider).categoryId, 30702);
    });

    testWidgets('is inert when the record carries no id', (tester) async {
      // A listing's `_aRootCategory` has no `_idRow`, and the url fallback only
      // helps when there is a url. A link that filtered by nothing would look
      // broken rather than absent.
      var wentBack = false;
      final container = await pumpCategory(
        tester,
        const GbCategoryRef(name: 'Unknown Category'),
        onBack: () => wentBack = true,
      );

      expect(find.text('Unknown Category'), findsOneWidget);
      await tester.tap(find.text('Unknown Category'));
      await tester.pumpAndSettle();

      expect(wentBack, isFalse);
      expect(container.read(marketplaceQueryProvider).categoryId, isNull);
    });
  });

  group('tags', () {
    // `GbMod.tags` had no reader at all, which is exactly how the two-shape
    // parse bug survived: a profile's tags came back empty and nothing showed
    // them, so nothing looked wrong. Driving the captured profile through the
    // widget is what makes the parse self-evidently correct rather than only
    // test-correct.
    testWidgets('a profile response renders its own tags', (tester) async {
      final tagged = GbMod.fromJson(
        parseObject(loadGbFixture('mod_profile_tagged')),
      )!;

      await pumpDetail(tester, profile: tagged);

      expect(tagged.tags, isNotEmpty, reason: 'the fixture must carry tags');
      for (final tag in tagged.tags) {
        // Scrolled to rather than found where it lands: the page is a lazy
        // `ListView` and this profile's 16:9 gallery is ~650px on its own, so
        // the tags start below the fold and are not built yet.
        await tester.scrollUntilVisible(find.text(tag), 200,
            scrollable: find.byType(Scrollable).first);
        expect(find.text(tag), findsOneWidget, reason: tag);
      }
    });

    testWidgets('shown in the form the library stores', (tester) async {
      // An install copies these strings straight onto the mod, so a tag has to
      // read identically on the page and on the folder it became.
      await pumpDetail(
        tester,
        profile: GbMod(
          idRow: 700727,
          name: 'A Mod',
          visibility: GbVisibility.show,
          files: const [],
          tags: const ['Software Used: Blender', 'Ellen: school uniform'],
        ),
      );

      expect(find.text('Software Used: Blender'), findsOneWidget);
      expect(find.text('Ellen: school uniform'), findsOneWidget);
    });

    testWidgets('sits above the file list, not below the description',
        (tester) async {
      // Where they go is the only layout decision here: tags describe the mod,
      // so they belong with its metadata rather than after the author's prose,
      // which on a real profile is several screens down.
      await pumpDetail(
        tester,
        profile: GbMod(
          idRow: 700727,
          name: 'A Mod',
          text: 'Some description',
          visibility: GbVisibility.show,
          files: const [],
          tags: const ['Ellen: school uniform'],
        ),
      );

      expect(
        tester.getTopLeft(find.text('Ellen: school uniform')).dy,
        lessThan(tester.getTopLeft(find.text('Description')).dy),
      );
    });
  });
}
