import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/core/palette.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/gamebanana/gamebanana.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/screens/components/marketplace/gb_browse_view.dart';
import 'package:mod_manager_flutter/screens/components/marketplace/gb_character_picker.dart';
import 'package:mod_manager_flutter/screens/components/marketplace/gb_mod_card.dart';
import 'package:mod_manager_flutter/screens/components/marketplace/gb_state_view.dart';
import 'package:mod_manager_flutter/screens/components/marketplace/gb_top_subs_carousel.dart';
import 'package:mod_manager_flutter/screens/components/zenith_controls.dart';
import 'package:mod_manager_flutter/screens/components/zenith_switch.dart';
import 'package:mod_manager_flutter/services/gamebanana/content_filter.dart';
import 'package:mod_manager_flutter/services/gamebanana/gamebanana_client.dart';
import 'package:mod_manager_flutter/services/installed_mods_index.dart';
import 'package:mod_manager_flutter/utils/marketplace_providers.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

import 'support/fake_http_transport.dart';
import 'support/fixtures.dart';
import 'support/localized_harness.dart';
import 'support/origin_shorthand.dart';

/// The Browse page: header and search, the carousel, the pinned filter bar with its chips, switch and menus, and the
/// grid's infinite scroll. Every provider is faked so nothing touches the network, and the listing is a fetcher
/// that hands back pages by number.
void main() {
  final roots = parseBareList(loadGbFixture('categories_root'), GbCategoryNode.fromJson);
  final roster = parseBareList(loadGbFixture('categories_30305'), GbCategoryNode.fromJson);

  GbMod mod(int id, {GbVisibility visibility = GbVisibility.show}) => GbMod(
    idRow: id,
    name: 'Mod $id',
    likeCount: 298,
    visibility: visibility,
    submitter: const GbSubmitter(idRow: 1, name: 'someone'),
    subCategory: const GbCategoryRef(name: 'Ellen Joe'),
  );

  GbPage<GbMod> page(Iterable<int> ids, {int total = 100, bool complete = false}) =>
      GbPage(records: [for (final id in ids) mod(id)], recordCount: total, isComplete: complete);

  final topSubs = [
    GbTopSub(
      idRow: 900,
      period: GbTopSubPeriod.today,
      name: 'Top Today',
      image: GbImage(baseUrl: 'https://example.invalid', file: '900.jpg'),
      visibility: GbVisibility.show,
      likeCount: 500,
    ),
  ];

  InstalledModsIndex libraryWith(Iterable<int> modIds) => InstalledModsIndex.fromMods([
    for (final id in modIds)
      ModInfo(
        id: 'Folder $id',
        name: 'Folder $id',
        characterId: 'ellen',
        isActive: false,
        origin: originFixture(
          provenance: OriginProvenance.importedFolder,
          source: 'gamebanana',
          modId: id,
          modIdConfidence: OriginConfidence.inferred,
        ),
      ),
  ]);

  Future<ProviderContainer> pumpBrowse(
    WidgetTester tester, {
    required _Listing listing,
    InstalledModsIndex? installed,
    bool hideInstalled = false,
    ContentFilterMode filter = ContentFilterMode.show,
    ContentFilterMode? Function(ContentFilterMode)? onFilter,
    void Function(GbModSort)? onSort,
    void Function(bool)? onHide,
    Size size = const Size(1200, 800),
    bool settle = true,
    List<GbCategoryNode>? rootNodes,
  }) async {
    final container = ProviderContainer(
      overrides: [
        marketplacePageFetcherProvider.overrideWithValue(listing.fetch),
        rootCategoriesProvider.overrideWith((ref) async => rootNodes ?? roots),
        categoryChildrenProvider.overrideWith((ref, id) async => roster),
        topSubsProvider.overrideWith((ref) async => topSubs),
        modEnrichmentProvider.overrideWith((ref, key) async => const {}),
        contentFilterProvider.overrideWith((ref) => filter),
        marketplaceHideInstalledProvider.overrideWith((ref) => hideInstalled),
        installedModsIndexProvider.overrideWith((ref) async => installed ?? InstalledModsIndex.empty),
      ],
    );
    addTearDown(container.dispose);
    await pumpLocalized(
      tester,
      GbBrowseView(
        onOpenMod: (_) {},
        carouselAutoAdvance: null,
        contentFilterWriter: (mode) async => onFilter?.call(mode),
        sortWriter: (sort) async => onSort?.call(sort),
        hideInstalledWriter: (hide) async => onHide?.call(hide),
      ),
      container: container,
      surfaceSize: size,
      settle: settle,
    );
    expectBuilt(GbBrowseView);
    return container;
  }

  /// The grid's own scrollable: the first under the scroll view, above the carousel's and the search field's.
  double offset(WidgetTester tester) => tester
      .state<ScrollableState>(
        find.descendant(of: find.byType(CustomScrollView), matching: find.byType(Scrollable)).first,
      )
      .position
      .pixels;

  /// The cards built, which is the ones on screen and the grid's cache around them.
  Iterable<int> shownIds(WidgetTester tester) =>
      tester.widgetList<GbModCard>(find.byType(GbModCard, skipOffstage: false)).map((c) => c.mod.idRow);

  /// Every mod the grid has loaded, built or not.
  Iterable<int> loadedIds(ProviderContainer container) =>
      container.read(marketplaceFeedProvider).requireValue.records.map((m) => m.idRow);

  testWidgets('lays out the header, the carousel, the bar and the grid', (tester) async {
    await pumpBrowse(
      tester,
      listing: _Listing({
        1: page([1, 2], complete: true),
      }),
    );
    expect(tester.takeException(), isNull);

    expect(find.text('Browse'), findsOneWidget);
    expect(find.text('Zenless Zone Zero mods on GameBanana'), findsOneWidget);
    expect(find.text('Search GameBanana, or paste a mod link'), findsOneWidget);
    expect(find.byType(GbTopSubsCarousel), findsOneWidget);
    expect(find.text('Any character'), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w is SizedBox && w.width == 1 && w.height == 20), findsOneWidget);
    expect(find.text('Hide installed'), findsOneWidget);
    expect(find.byType(GbModCard), findsNWidgets(2));

    // The title is the page-title role, measured rather than assumed.
    final title = tester.widget<Text>(find.text('Browse'));
    expect(title.style?.fontFamily, 'Unbounded');
    expect(title.style?.fontWeight, FontWeight.w700);
    expect(tester.getSize(find.byType(TextField)).height, 40);
    expect(tester.getSize(find.byType(TextField)).width, 420);
  });

  testWidgets('survives the narrowest window, with the bar wrapped', (tester) async {
    await pumpBrowse(
      tester,
      listing: _Listing({
        1: page([1, 2], complete: true),
      }),
      size: const Size(584, 700),
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(GbModCard), findsNWidgets(2));
  });

  group('the filter bar', () {
    Rect refresh(WidgetTester tester) => tester.getRect(
      find.ancestor(of: find.byIcon(Icons.refresh_rounded), matching: find.byType(OutlinedButton)),
    );

    for (final (width, wraps) in [(1200.0, false), (584.0, true)]) {
      testWidgets('keeps its right-hand group at the right at $width px, wrapped: $wraps', (tester) async {
        await pumpBrowse(
          tester,
          listing: _Listing({
            1: page([1], complete: true),
          }),
          size: Size(width, 700),
        );
        expect(refresh(tester).right, moreOrLessEquals(width - 32, epsilon: 0.5));
        final chips = tester.getRect(find.byType(GbCharacterPicker));
        expect(chips.left, moreOrLessEquals(32, epsilon: 0.5));
        final group = tester.getRect(find.byType(ZenithSwitch));
        expect(group.top > chips.bottom, wraps);
      });
    }

    testWidgets('draws the divider after the character chip only with a type chip beside it', (tester) async {
      final divider = find.byWidgetPredicate((w) => w is SizedBox && w.width == 1 && w.height == 20);
      await pumpBrowse(
        tester,
        listing: _Listing({
          1: page([1], complete: true),
        }),
        rootNodes: const [],
      );
      expect(find.byType(GbCharacterPicker), findsOneWidget);
      expect(find.byType(ZenithChip), findsNothing, reason: 'no type chips');
      expect(divider, findsNothing);
    });
  });

  group('the type chips', () {
    testWidgets('are the live roots in the canvas order, with the short labels', (tester) async {
      await pumpBrowse(
        tester,
        listing: _Listing({
          1: page([1], complete: true),
        }),
      );
      final labels = [for (final chip in tester.widgetList<ZenithChip>(find.byType(ZenithChip))) chip.label];
      expect(labels, ['Character', 'Bangboo', 'UI', 'Misc']);
    });

    testWidgets('are single-select, and the one that is on turns off', (tester) async {
      final listing = _Listing({
        1: page([1], complete: true),
      });
      final container = await pumpBrowse(tester, listing: listing);

      await tester.tap(find.text('UI'));
      await tester.pumpAndSettle();
      expect(container.read(marketplaceQueryProvider).categoryId, 30395);
      expect(tester.widget<ZenithChip>(find.widgetWithText(ZenithChip, 'UI')).selected, isTrue);
      expect(listing.asked.last, (30395, 1), reason: 'a new filter starts again at page 1');

      await tester.tap(find.text('Misc'));
      await tester.pumpAndSettle();
      expect(container.read(marketplaceQueryProvider).categoryId, 29874);
      expect(tester.widget<ZenithChip>(find.widgetWithText(ZenithChip, 'UI')).selected, isFalse);

      await tester.tap(find.text('Misc'));
      await tester.pumpAndSettle();
      expect(container.read(marketplaceQueryProvider).categoryId, isNull);
    });
  });

  group('the character picker', () {
    Finder popover() => find.byWidgetPredicate((w) => w is Semantics && w.properties.label == 'Pick a character');
    Finder inPopover(String name) => find.descendant(of: popover(), matching: find.text(name));

    Future<void> pick(WidgetTester tester, String name) async {
      await tester.tap(find.text('Any character'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(inPopover(name));
      await tester.pumpAndSettle();
      await tester.tap(inPopover(name));
      await tester.pumpAndSettle();
    }

    testWidgets('lists the live roster by name', (tester) async {
      await pumpBrowse(
        tester,
        listing: _Listing({
          1: page([1], complete: true),
        }),
      );
      await tester.tap(find.text('Any character'));
      await tester.pumpAndSettle();
      expect(find.text('Every agent, A to Z'), findsOneWidget);
      for (final node in roster) {
        expect(inPopover(node.name!), findsOneWidget);
      }
    });

    testWidgets('picking a character turns Character on, painted as selected', (tester) async {
      final container = await pumpBrowse(
        tester,
        listing: _Listing({
          1: page([1], complete: true),
        }),
      );
      await tester.tap(find.text('UI'));
      await tester.pumpAndSettle();

      await pick(tester, 'Ellen Joe');

      final query = container.read(marketplaceQueryProvider);
      expect(query.character?.name, 'Ellen Joe');
      expect(query.categoryId, query.character!.id);
      final character = tester.widget<ZenithChip>(find.widgetWithText(ZenithChip, 'Character'));
      expect(character.selected, isTrue);
      expect(tester.widget<ZenithChip>(find.widgetWithText(ZenithChip, 'UI')).selected, isFalse);

      final fill = tester.widget<Material>(
        find.descendant(of: find.widgetWithText(ZenithChip, 'Character'), matching: find.byType(Material)).first,
      );
      expect(fill.color, ZenithPalette.dark(AccentChoice.violet).selected.background);
    });

    testWidgets('picking another type clears the character', (tester) async {
      final container = await pumpBrowse(
        tester,
        listing: _Listing({
          1: page([1], complete: true),
        }),
      );
      await pick(tester, 'Ellen Joe');

      await tester.tap(find.text('Bangboo'));
      await tester.pumpAndSettle();

      expect(container.read(marketplaceQueryProvider).character, isNull);
      expect(container.read(marketplaceQueryProvider).categoryId, 30702);
      expect(find.text('Any character'), findsOneWidget);
    });

    testWidgets('the × clears the character and leaves Character on', (tester) async {
      final container = await pumpBrowse(
        tester,
        listing: _Listing({
          1: page([1], complete: true),
        }),
      );
      await pick(tester, 'Ellen Joe');
      expect(find.descendant(of: find.byType(GbCharacterPicker), matching: find.text('Ellen Joe')), findsOneWidget);

      await tester.tap(find.descendant(of: find.byType(GbCharacterPicker), matching: find.byIcon(Icons.close_rounded)));
      await tester.pumpAndSettle();

      expect(container.read(marketplaceQueryProvider).character, isNull);
      expect(container.read(marketplaceQueryProvider).categoryId, kCharacterSkinsCategoryId);
      expect(popover(), findsNothing, reason: 'the × does not open the popover');
    });
  });

  group('the search', () {
    testWidgets('combines with the chips, and hides the carousel', (tester) async {
      final container = await pumpBrowse(
        tester,
        listing: _Listing({
          1: page([1], complete: true),
        }),
      );

      await tester.tap(find.text('Misc'));
      await tester.pumpAndSettle();
      expect(find.byType(GbTopSubsCarousel), findsOneWidget, reason: 'a chip keeps the carousel');

      await tester.enterText(find.byType(TextField), 'ellen');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();

      final query = container.read(marketplaceQueryProvider);
      expect(query.text, 'ellen');
      expect(query.categoryId, 29874);
      expect(find.byType(GbTopSubsCarousel), findsNothing);
    });

    testWidgets('the box empties when the search is lifted from elsewhere', (tester) async {
      final container = await pumpBrowse(
        tester,
        listing: _Listing({
          1: page([1], complete: true),
        }),
      );
      await tester.enterText(find.byType(TextField), 'ellen');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();

      container.read(marketplaceQueryProvider.notifier).state = container.read(marketplaceQueryProvider).withText('');
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('ellen'), findsNothing);
    });
  });

  testWidgets('the filter bar stays pinned at the top as the grid scrolls', (tester) async {
    await pumpBrowse(
      tester,
      listing: _Listing({
        for (var p = 1; p <= 3; p++) p: page([for (var i = 0; i < 12; i++) p * 100 + i], total: 36),
      }),
    );
    final before = tester.getRect(find.text('Hide installed')).top;

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -1500));
    await tester.pumpAndSettle();
    final pinned = tester.getRect(find.text('Hide installed')).top;
    expect(pinned, lessThan(before - 200));
    expect(pinned, lessThan(40), reason: 'the bar sits at the top of the viewport');

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(tester.getRect(find.text('Hide installed')).top, moreOrLessEquals(pinned, epsilon: 0.5));
  });

  group('infinite scroll', () {
    List<int> ids(int p) => [for (var i = 0; i < 12; i++) p * 100 + i];

    testWidgets('loads pages until the content passes the viewport, then on scroll', (tester) async {
      final listing = _Listing({1: page(ids(1), total: 48), 2: page(ids(2), total: 48), 3: page(ids(3), total: 48)});
      final container = await pumpBrowse(tester, listing: listing);
      // Page 1's twelve cards end within a viewport of the bottom, so page 2 follows on its own; with both in, the
      // end is further than that and nothing more is asked.
      expect(listing.asked, [(null, 1), (null, 2)]);
      expect(loadedIds(container), hasLength(24));

      await tester.drag(find.byType(CustomScrollView), const Offset(0, -1500));
      await tester.pumpAndSettle();
      expect(listing.asked.map((a) => a.$2), [1, 2, 3]);
      expect(loadedIds(container), containsAllInOrder([100, 200, 300, 311]));
    });

    testWidgets('shows the ring while a page is in flight, and nothing once the last is in', (tester) async {
      final late = Completer<GbPage<GbMod>>();
      final listing = _Listing({1: page(ids(1), total: 24), 2: late});
      final container = await pumpBrowse(tester, listing: listing, settle: false);
      await tester.pump();
      await tester.pump();

      await tester.drag(find.byType(CustomScrollView), const Offset(0, -2000));
      await tester.pump();
      expect(find.text('Loading more'), findsOneWidget);
      final ring = tester.getSize(
        find.descendant(of: find.byType(GbBrowseView), matching: find.byType(CircularProgressIndicator)),
      );
      expect(ring, const Size(14, 14));

      late.complete(page(ids(2), total: 24));
      await tester.pumpAndSettle();
      expect(find.text('Loading more'), findsNothing);
      expect(find.text("Couldn't load more"), findsNothing);
      expect(loadedIds(container), contains(211));
      expect(container.read(marketplaceFeedProvider).requireValue.isComplete, isTrue);
    });

    testWidgets('a failed page says so with Try again, and keeps the cards', (tester) async {
      final listing = _Listing({1: page(ids(1), total: 24), 2: StateError('offline')});
      final container = await pumpBrowse(tester, listing: listing);

      await tester.drag(find.byType(CustomScrollView), const Offset(0, -2000));
      await tester.pumpAndSettle();
      expect(find.text("Couldn't load more"), findsOneWidget);
      expect(loadedIds(container), hasLength(12));
      expect(listing.asked.where((a) => a.$2 == 2), hasLength(1), reason: 'a failed page waits for Try again');

      listing.pages[2] = page(ids(2), total: 24);
      await tester.ensureVisible(find.text('Try again'));
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();

      expect(find.text("Couldn't load more"), findsNothing);
      expect(loadedIds(container), contains(211));
    });

    testWidgets('a query change starts again at page 1, at the top', (tester) async {
      final listing = _Listing({1: page(ids(1), total: 48), 2: page(ids(2), total: 48), 3: page(ids(3), total: 48)});
      await pumpBrowse(tester, listing: listing);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -1200));
      await tester.pumpAndSettle();
      expect(offset(tester), greaterThan(500));

      await tester.tap(find.text('UI'));
      await tester.pumpAndSettle();

      expect(offset(tester), 0);
      expect(listing.asked.where((a) => a.$1 == 30395).first, (30395, 1));
    });

    testWidgets("a failed first page of a new query shows the failure, never the old cards or its page 2", (
      tester,
    ) async {
      final listing = _Listing({
        1: page(ids(1), total: 48),
        2: page(ids(2), total: 48),
      }, failingCategory: 30702);
      final container = await pumpBrowse(tester, listing: listing);
      expect(find.byType(GbModCard), findsWidgets);

      await tester.tap(find.text('Bangboo'));
      await tester.pumpAndSettle();

      expect(find.byType(GbFailureState), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
      expect(find.byType(GbModCard, skipOffstage: false), findsNothing);
      expect(listing.asked.where((a) => a.$1 == 30702), [(30702, 1)]);
      expect(container.read(marketplaceFeedProvider).hasError, isTrue);
    });
  });

  group('Hide installed', () {
    testWidgets('drops the mods the library has, and is written', (tester) async {
      bool? written;
      final container = await pumpBrowse(
        tester,
        listing: _Listing({
          1: page([1, 2, 3], complete: true),
        }),
        installed: libraryWith([2]),
        onHide: (hide) => written = hide,
      );
      expect(shownIds(tester), [1, 2, 3]);

      await tester.tap(find.byType(ZenithSwitch));
      await tester.pumpAndSettle();

      expect(written, isTrue);
      expect(container.read(marketplaceHideInstalledProvider), isTrue);
      expect(shownIds(tester), [1, 3]);
    });

    testWidgets('a page it empties loads the next without a scroll', (tester) async {
      final listing = _Listing({
        1: page([1, 2, 3], total: 6),
        2: page([4, 5, 6], total: 6),
      });
      await pumpBrowse(tester, listing: listing, installed: libraryWith([1, 2, 3]), hideInstalled: true);

      expect(listing.asked.map((a) => a.$2), [1, 2]);
      expect(shownIds(tester), [4, 5, 6]);
      expect(find.text('You have every one of these installed.'), findsNothing);
    });

    testWidgets('every loaded mod installed says so, and Show installed turns it off', (tester) async {
      bool? written;
      final container = await pumpBrowse(
        tester,
        listing: _Listing({
          1: page([1, 2], complete: true),
        }),
        installed: libraryWith([1, 2]),
        hideInstalled: true,
        onHide: (hide) => written = hide,
      );
      expect(find.text('You have every one of these installed.'), findsOneWidget);

      await tester.tap(find.text('Show installed'));
      await tester.pumpAndSettle();

      expect(written, isFalse);
      expect(container.read(marketplaceHideInstalledProvider), isFalse);
      expect(shownIds(tester), [1, 2]);
    });

    testWidgets("with the content filter dropping the rest, it is the filter's state, never the installed one", (
      tester,
    ) async {
      await pumpBrowse(
        tester,
        listing: _Listing({
          1: GbPage(records: [mod(1, visibility: GbVisibility.warn), mod(2)], recordCount: 2, isComplete: true),
        }),
        installed: libraryWith([2]),
        hideInstalled: true,
        filter: ContentFilterMode.hide,
      );

      expect(find.text('You have every one of these installed.'), findsNothing);
      expect(find.text('Show installed'), findsNothing);
      expect(find.text('Every result is hidden by your adult-content filter or by Hide installed.'), findsOneWidget);
      expect(find.text('Blur them instead'), findsOneWidget);
    });
  });

  group('the menus', () {
    testWidgets('Mature content shows the three modes and writes the setting', (tester) async {
      ContentFilterMode? written;
      final container = await pumpBrowse(
        tester,
        listing: _Listing({
          1: page([1], complete: true),
        }),
        onFilter: (mode) => written = mode,
      );

      await tester.tap(find.byTooltip('Mature content: Show without blur'));
      await tester.pumpAndSettle();
      expect(find.text('MATURE CONTENT'), findsOneWidget);
      expect(find.text('Thumbnails blurred, still listed'), findsOneWidget);
      expect(find.text('Listed like any other mod'), findsOneWidget);
      expect(find.text('Left out of Browse'), findsOneWidget);
      expect(find.text('Also changes the setting in Settings'), findsOneWidget);
      final current = find.ancestor(of: find.text('Show without blur'), matching: find.byType(MenuItemButton));
      expect(find.descendant(of: current, matching: find.byIcon(Icons.check_rounded)), findsOneWidget);

      await tester.tap(find.text('Hide entirely'));
      await tester.pumpAndSettle();

      expect(written, ContentFilterMode.hide);
      expect(container.read(contentFilterProvider), ContentFilterMode.hide);
      expect(find.byTooltip('Mature content: Hide entirely'), findsOneWidget);
      expect(find.byIcon(Icons.visibility_off_outlined), findsWidgets);
    });

    testWidgets('Sort offers six sorts and writes the one picked', (tester) async {
      GbModSort? written;
      final listing = _Listing({
        1: page([1], complete: true),
      });
      final container = await pumpBrowse(tester, listing: listing, onSort: (sort) => written = sort);

      await tester.tap(find.byTooltip('Sort: Newest'));
      await tester.pumpAndSettle();
      expect(find.text('SORT BY'), findsOneWidget);
      expect(find.byType(MenuItemButton), findsNWidgets(6));
      expect(find.text('Recent discussion'), findsNothing);

      await tester.tap(find.text('Most liked'));
      await tester.pumpAndSettle();

      expect(written, GbModSort.mostLiked);
      expect(container.read(marketplaceQueryProvider).sort, GbModSort.mostLiked);
      expect(listing.sorts.last, GbModSort.mostLiked);
      expect(find.byTooltip('Sort: Most liked'), findsOneWidget);
    });

    testWidgets('the same pick reloads nothing: the current sort, or the same search again', (tester) async {
      final listing = _Listing({1: page(List.generate(30, (i) => i + 1), total: 30, complete: true)});
      await pumpBrowse(tester, listing: listing);
      await tester.enterText(find.byType(TextField), 'ellen');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -400));
      await tester.pumpAndSettle();
      final asked = listing.asked.length;
      final scrolled = offset(tester);
      expect(scrolled, greaterThan(100));

      await tester.tap(find.byTooltip('Sort: Newest'));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: find.byType(MenuItemButton), matching: find.text('Newest')));
      await tester.pumpAndSettle();
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();

      expect(listing.asked, hasLength(asked));
      expect(offset(tester), scrolled, reason: 'an equal query does not scroll back to the top');
    });

    testWidgets('a menu button is drawn open while its menu is', (tester) async {
      final palette = ZenithPalette.dark(AccentChoice.violet);
      await pumpBrowse(
        tester,
        listing: _Listing({
          1: page([1], complete: true),
        }),
      );
      Finder button(IconData icon) => find.ancestor(of: find.byIcon(icon), matching: find.byType(OutlinedButton));
      Material fill(IconData icon) =>
          tester.widget<Material>(find.descendant(of: button(icon), matching: find.byType(Material)).first);

      for (final icon in [Icons.swap_vert_rounded, Icons.visibility_outlined]) {
        final closed = fill(icon);
        expect(closed.color, isNot(palette.hover), reason: '$icon closed');

        await tester.tap(button(icon));
        await tester.pumpAndSettle();
        final open = fill(icon);
        expect(open.color, palette.hover, reason: '$icon open');
        expect((open.shape! as OutlinedBorder).side.color, palette.check, reason: '$icon open');

        await tester.tap(button(icon));
        await tester.pumpAndSettle();
        expect(find.byType(MenuItemButton), findsNothing);
        expect(fill(icon).color, closed.color, reason: '$icon closed again');
      }
    });
  });

  group('nothing to show', () {
    testWidgets('a fruitless search offers to clear itself', (tester) async {
      final container = await pumpBrowse(tester, listing: _Listing({1: page([], total: 0, complete: true)}));
      await tester.enterText(find.byType(TextField), 'zzzzqqq');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();

      expect(find.text('No mods found.'), findsOneWidget);
      await tester.tap(find.text('Clear search'));
      await tester.pumpAndSettle();
      expect(container.read(marketplaceQueryProvider).text, isEmpty);
    });

    testWidgets('an empty browse offers nothing', (tester) async {
      await pumpBrowse(tester, listing: _Listing({1: page([], total: 0, complete: true)}));
      expect(find.text('No mods found.'), findsOneWidget);
      expect(find.text('Clear search'), findsNothing);
    });
  });

  group('the refresh button', () {
    /// A real client over a fake transport, so "did it hit the network" is observable.
    const body = '{"_aMetadata":{"_nRecordCount":1,"_nPerpage":30},"_aRecords":[{"_idRow":1,"_sName":"Only Mod"}]}';

    Future<FakeHttpTransport> pumpWithRealClient(WidgetTester tester, {int? maxRetries}) async {
      final transport = FakeHttpTransport()..stubAnything(body: body);
      final client = maxRetries == null
          ? GameBananaClient(transport: transport)
          : GameBananaClient(transport: transport, maxRetries: maxRetries);
      await pumpLocalized(
        tester,
        GbBrowseView(onOpenMod: (_) {}, carouselAutoAdvance: null),
        overrides: [
          gameBananaClientProvider.overrideWithValue(client),
          rootCategoriesProvider.overrideWith((ref) async => roots),
          categoryChildrenProvider.overrideWith((ref, id) async => roster),
          topSubsProvider.overrideWith((ref) async => topSubs),
          modEnrichmentProvider.overrideWith((ref, key) async => const {}),
          contentFilterProvider.overrideWith((ref) => ContentFilterMode.show),
          installedModsIndexProvider.overrideWith((ref) async => InstalledModsIndex.empty),
        ],
      );
      expectBuilt(GbBrowseView);
      return transport;
    }

    OutlinedButton button(WidgetTester tester) => tester.widget<OutlinedButton>(
      find.ancestor(of: find.byIcon(Icons.refresh_rounded), matching: find.byType(OutlinedButton)),
    );

    testWidgets('re-fetches over the network', (tester) async {
      final transport = await pumpWithRealClient(tester);
      final before = transport.callCount;
      expect(before, greaterThan(0));

      await tester.tap(find.byIcon(Icons.refresh_rounded));
      await tester.pumpAndSettle();

      expect(transport.callCount, greaterThan(before), reason: 'refresh must bypass the cache and ask again');
    });

    testWidgets('is a 30px button that spins and disables itself while in flight', (tester) async {
      await pumpWithRealClient(tester);
      final size = tester.getSize(
        find.ancestor(of: find.byIcon(Icons.refresh_rounded), matching: find.byType(OutlinedButton)),
      );
      expect(size, const Size(30, 30));
      expect(find.byTooltip('Refresh'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.refresh_rounded));
      await tester.pump(const Duration(milliseconds: 200));
      expect(button(tester).onPressed, isNull, reason: 'still spinning 200ms in, despite the instant response');
      expect(find.byTooltip('Refreshing…'), findsOneWidget);

      await tester.pumpAndSettle();
      expect(button(tester).onPressed, isNotNull);
    });

    testWidgets('a failed refresh re-enables the button', (tester) async {
      final transport = await pumpWithRealClient(tester, maxRetries: 0);
      transport.stubAnything(statusCode: 500, body: '{}');

      await tester.tap(find.byIcon(Icons.refresh_rounded));
      await tester.pumpAndSettle();

      expect(button(tester).onPressed, isNotNull);
    });
  });
}

/// The listing, page by page: a page, an error to throw, or a completer to hold the request open. Every page of
/// [failingCategory] fails.
class _Listing {
  _Listing(this.pages, {this.failingCategory});

  final Map<int, Object> pages;
  final int? failingCategory;

  /// Every request, as the category it asked for and the page.
  final List<(int?, int)> asked = [];
  final List<GbModSort> sorts = [];

  Future<GbPage<GbMod>> fetch(MarketplaceQuery query, int page, {bool refresh = false}) {
    asked.add((query.categoryId, page));
    sorts.add(query.sort);
    if (failingCategory != null && query.categoryId == failingCategory) {
      return Future.error(const GbNetworkException('offline'));
    }
    return switch (pages[page]) {
      final GbPage<GbMod> result => Future.value(result),
      final Completer<GbPage<GbMod>> pending => pending.future,
      final Object error => Future.error(error),
      null => Future.value(const GbPage<GbMod>(records: [], recordCount: 0, isComplete: true)),
    };
  }
}
