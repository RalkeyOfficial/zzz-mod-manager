import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart' show FontLoader, rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/core/palette.dart';
import 'package:mod_manager_flutter/core/type_scale.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/gamebanana/gamebanana.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/screens/components/marketplace/gb_browse_view.dart';
import 'package:mod_manager_flutter/screens/components/marketplace/gb_creator_view.dart';
import 'package:mod_manager_flutter/screens/components/marketplace/gb_mod_card.dart';
import 'package:mod_manager_flutter/screens/components/zenith_controls.dart' show OutlinedInitials;
import 'package:mod_manager_flutter/screens/components/zenith_switch.dart';
import 'package:mod_manager_flutter/services/gamebanana/content_filter.dart';
import 'package:mod_manager_flutter/services/installed_mods_index.dart';
import 'package:mod_manager_flutter/utils/marketplace_providers.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

import 'support/all_mods_harness.dart' show loadTableFonts;
import 'support/fixtures.dart';
import 'support/localized_harness.dart';
import 'support/origin_shorthand.dart';

bool _displayFontLoaded = false;

/// Loads Unbounded, which the member's name and the tiles' numerals are set in.
Future<void> loadDisplayFont(WidgetTester tester) async {
  if (_displayFontLoaded) return;
  await tester.runAsync(() async {
    final display = FontLoader(kDisplayFont);
    for (final weight in ['Bold', 'ExtraBold']) {
      display.addFont(rootBundle.load('assets/fonts/unbounded/Unbounded-$weight.ttf'));
    }
    await display.load();
  });
  _displayFontLoaded = true;
}

/// A creator's page, on a real captured `Generic_Submitter` listing: Exce (member 2307694), 24 mods, three of them
/// Jane Doe skins.
void main() {
  final exce = parseEnvelope(loadGbFixture('mod_index_submitter_2307694'), GbMod.fromJson);
  const member = GbSubmitter(idRow: 2307694, name: 'Exce', profileUrl: 'https://gamebanana.com/members/2307694');
  const janeMods = [715093, 562764, 550118];

  InstalledModsIndex libraryWith(Iterable<int> modIds) => InstalledModsIndex.fromMods([
    for (final id in modIds)
      ModInfo(
        id: 'Folder $id',
        name: 'Folder $id',
        characterId: 'jane',
        isActive: false,
        origin: originFixture(
          provenance: OriginProvenance.importedFolder,
          source: 'gamebanana',
          modId: id,
          modIdConfidence: OriginConfidence.inferred,
        ),
      ),
  ]);

  /// A fetcher answering [pages] by number, recording each request in [asked].
  CreatorPageFetcher fetcher(Map<int, FutureOr<GbPage<GbMod>> Function()> pages, [List<(GbModSort, int)>? asked]) =>
      (listing, page) async {
        asked?.add((listing.sort, page));
        final answer = pages[page];
        if (answer == null) throw StateError('page $page was not expected');
        return answer();
      };

  Future<ProviderContainer> pumpCreator(
    WidgetTester tester, {
    required CreatorPageFetcher fetch,
    Future<InstalledModsIndex>? installed,
    bool hideInstalled = false,
    ContentFilterMode filter = ContentFilterMode.show,
    void Function(bool)? onHide,
    bool settle = true,
    Size size = const Size(1240, 900),
    String parent = 'Nocturne of Light',
    AccentChoice accent = AccentChoice.violet,
  }) async {
    final container = ProviderContainer(
      overrides: [
        accentProvider.overrideWith((ref) => accent),
        creatorPageFetcherProvider.overrideWithValue(fetch),
        modEnrichmentProvider.overrideWith((ref, key) async => const {}),
        contentFilterProvider.overrideWith((ref) => filter),
        marketplaceHideInstalledProvider.overrideWith((ref) => hideInstalled),
        installedModsIndexProvider.overrideWith((ref) => installed ?? Future.value(InstalledModsIndex.empty)),
      ],
    );
    addTearDown(container.dispose);
    await pumpLocalized(
      tester,
      GbCreatorView(
        member: member,
        onBack: () {},
        onBrowse: () {},
        parent: (label: parent, onTap: () {}),
        onOpenMod: (_) {},
        onOpenInBrowser: (_) {},
        hideInstalledWriter: (hide) async => onHide?.call(hide),
        contentFilterWriter: (_) async {},
      ),
      container: container,
      surfaceSize: size,
      settle: settle,
    );
    expectBuilt(GbCreatorView);
    return container;
  }

  Iterable<GbModCard> cards(WidgetTester tester) =>
      tester.widgetList<GbModCard>(find.byType(GbModCard, skipOffstage: false));

  String countLine(WidgetTester tester) => tester.widget<Text>(find.byKey(const ValueKey('creator_count'))).data!;

  /// Pumps frames for [duration] without settling, for a page whose loading ring never stops.
  Future<void> pumpFor(WidgetTester tester, [Duration duration = const Duration(milliseconds: 600)]) async {
    for (var elapsed = Duration.zero; elapsed < duration; elapsed += const Duration(milliseconds: 50)) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// Scrolls the page to its end, where the footer is built.
  Future<void> toEnd(WidgetTester tester) async {
    for (var i = 0; i < 3; i++) {
      final position = tester
          .state<ScrollableState>(
            find.descendant(of: find.byType(CustomScrollView), matching: find.byType(Scrollable)).first,
          )
          .position;
      position.jumpTo(position.maxScrollExtent);
      await tester.pump();
    }
  }

  group('the header', () {
    testWidgets('names the member and counts their mods and the ones in the library', (tester) async {
      await pumpCreator(
        tester,
        fetch: fetcher({1: () => exce}),
        installed: Future.value(libraryWith([715093, 667621])),
      );

      expect(find.text('24 mods for Zenless Zone Zero. 2 of them are in your library.'), findsOneWidget);
      final name = tester.widget<Text>(find.byKey(const ValueKey('creator_name')));
      expect(name.data, 'Exce');
      expect(name.style?.fontFamily, 'Unbounded');
      expect(name.style?.fontWeight, FontWeight.w800);
      expect(tester.getSize(find.byKey(const ValueKey('creator_name'))).height, 34);
      expect(tester.getSize(find.byKey(const ValueKey('creator_avatar'))), const Size(76, 76));
      expect(find.text('EX'), findsOneWidget, reason: 'the initials stand in for an avatar the member has not got');
      expect(find.text('Open on GameBanana'), findsOneWidget);
    });

    testWidgets('says none are in the library, and leaves that out until the library is read', (tester) async {
      await pumpCreator(tester, fetch: fetcher({1: () => exce}));
      expect(find.text('24 mods for Zenless Zone Zero. None of them are in your library.'), findsOneWidget);
    });

    testWidgets('leaves the library sentence out while the library loads', (tester) async {
      await pumpCreator(tester, fetch: fetcher({1: () => exce}), installed: Completer<InstalledModsIndex>().future);
      expect(find.text('24 mods for Zenless Zone Zero.'), findsOneWidget);
    });

    testWidgets('a member with no mods for the game says so', (tester) async {
      await pumpCreator(
        tester,
        fetch: fetcher({1: () => const GbPage<GbMod>(records: [], recordCount: 0, isComplete: true)}),
      );
      expect(find.text('Exce has no Zenless Zone Zero mods.'), findsOneWidget);
      expect(find.byType(GbModCard), findsNothing);
      expect(find.byKey(const ValueKey('cast_all')), findsNothing);
    });
  });

  group('the tiles', () {
    testWidgets('are All mods, then one per character or type, most mods first, 96 by 128', (tester) async {
      await pumpCreator(tester, fetch: fetcher({1: () => exce}));

      expect(tester.getSize(find.byKey(const ValueKey('cast_all'))), const Size(96, 128));
      final jane = find.byKey(const ValueKey('cast_character:jane'));
      expect(tester.getSize(jane), const Size(96, 128));
      final order = [
        'cast_all',
        'cast_character:jane',
        'cast_type:30702',
        'cast_character:yanagi',
      ].map((key) => tester.getRect(find.byKey(ValueKey(key))).left).toList();
      expect(order, [...order]..sort());
      expect(tester.getRect(find.byKey(const ValueKey('cast_type:30702'))).left - tester.getRect(jane).right, 10);

      // The portrait, from the one place that spells its path; a type has none and shows its initials.
      final portrait = tester.widget<Image>(find.descendant(of: jane, matching: find.byType(Image)));
      expect((portrait.image as AssetImage).assetName, endsWith('/jane.png'));
      expect(
        find.descendant(of: find.byKey(const ValueKey('cast_type:30702')), matching: find.text('BA')),
        findsOneWidget,
      );
      expect(find.descendant(of: jane, matching: find.text('3 mods')), findsOneWidget);
      expect(
        find.descendant(of: find.byKey(const ValueKey('cast_all')), matching: find.text('All mods')),
        findsOneWidget,
      );
    });

    testWidgets('one filters the grid, the count line follows, and pressing it again shows all', (tester) async {
      await pumpCreator(tester, fetch: fetcher({1: () => exce}));
      expect(countLine(tester), 'All 24 mods');
      expect(find.byType(ColorFiltered), findsNothing);

      await tester.tap(find.byKey(const ValueKey('cast_character:jane')));
      await tester.pumpAndSettle();

      expect(countLine(tester), '3 mods for Jane Doe');
      expect(cards(tester).map((c) => c.mod.idRow), janeMods);
      expect(find.text('Show all 24'), findsOneWidget);
      // The other portraits dim; the one that is on does not.
      expect(
        find.descendant(of: find.byKey(const ValueKey('cast_character:jane')), matching: find.byType(ColorFiltered)),
        findsNothing,
      );
      expect(
        find.descendant(of: find.byKey(const ValueKey('cast_character:yanagi')), matching: find.byType(ColorFiltered)),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('cast_character:jane')));
      await tester.pumpAndSettle();
      expect(countLine(tester), 'All 24 mods');
      expect(find.text('Show all 24'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('cast_type:30702')));
      await tester.pumpAndSettle();
      expect(countLine(tester), '2 mods for Bangboo');
      await tester.tap(find.text('Show all 24'));
      await tester.pumpAndSettle();
      expect(cards(tester), hasLength(greaterThan(2)));
    });

    testWidgets("the name on the tile that is on reads on the tile's shade with the Paper accent", (tester) async {
      await pumpCreator(tester, fetch: fetcher({1: () => exce}), accent: AccentChoice.paper);
      await tester.tap(find.byKey(const ValueKey('cast_character:jane')));
      await tester.pumpAndSettle();

      final name = tester.widget<Text>(
        find.descendant(of: find.byKey(const ValueKey('cast_character:jane')), matching: find.text('Jane Doe')),
      );
      // The artboard's `color-mix(accent 70%, white)`, on the accent Paper marks on-states with.
      expect(name.style?.color, Color.lerp(const Color(0xFFA98BFF), Colors.white, 0.3));
      final ink = ZenithPalette.dark(AccentChoice.paper);
      final contrast = (name.style!.color!.computeLuminance() + 0.05) / (ink.ground.computeLuminance() + 0.05);
      expect(contrast, greaterThan(4.5));
    });

    testWidgets("the All mods tile's numeral fits the tile at four digits", (tester) async {
      await loadTableFonts(tester);
      await loadDisplayFont(tester);
      await pumpCreator(
        tester,
        fetch: fetcher({
          1: () => GbPage(
            records: [for (var i = 0; i < 1000; i++) GbMod(idRow: i + 1, name: 'Mod $i', visibility: GbVisibility.show)],
            recordCount: 1000,
            isComplete: true,
          ),
        }),
      );
      final all = find.byKey(const ValueKey('cast_all'));
      final numeral = find.descendant(
        of: find.descendant(of: all, matching: find.byType(OutlinedInitials)),
        matching: find.text('1000'),
      );
      final paragraph = tester.renderObject<RenderParagraph>(numeral);
      expect(
        paragraph.size.width,
        greaterThanOrEqualTo(paragraph.getMaxIntrinsicWidth(double.infinity) - 0.5),
        reason: 'laid out whole, not clipped to the tile',
      );
      final tile = tester.getRect(all);
      final drawn = tester.getRect(numeral);
      expect(drawn.left, greaterThanOrEqualTo(tile.left));
      expect(drawn.right, lessThanOrEqualTo(tile.right));
    });
  });

  testWidgets('the bar keeps Hide installed and Sort at the right, down to the narrowest window', (tester) async {
    await pumpCreator(tester, fetch: fetcher({1: () => exce}));
    expect(tester.getRect(find.byType(GbSortMenu)).right, moreOrLessEquals(1240 - 32, epsilon: 0.5));
    expect(tester.getRect(find.byKey(const ValueKey('creator_count'))).left, moreOrLessEquals(32, epsilon: 0.5));
  });

  testWidgets('fits the 800px window with a long mod name in the crumbs and a tile on', (tester) async {
    // The app's fonts: the test font draws every glyph a full em wide, which no layout is chosen for.
    await loadTableFonts(tester);
    await loadDisplayFont(tester);
    await pumpCreator(
      tester,
      fetch: fetcher({1: () => exce}),
      size: const Size(584, 700),
      parent: 'Trigger | Enhanced,Sportswear,Pasties,Nude & More',
    );
    await tester.tap(find.byKey(const ValueKey('cast_character:jane')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(tester.getRect(find.byType(GbSortMenu)).right, moreOrLessEquals(584 - 32, epsilon: 0.5));
    expect(find.text('Show all 24'), findsOneWidget);
    expect(find.text('Exce').hitTestable(), findsWidgets, reason: "the page's own crumb keeps its room");
  });

  testWidgets('a card names the character in place of the author, and its cover does not', (tester) async {
    await pumpCreator(tester, fetch: fetcher({1: () => exce}));
    await tester.tap(find.byKey(const ValueKey('cast_character:jane')));
    await tester.pumpAndSettle();

    final card = cards(tester).first;
    expect(card.bylineSubject, 'Jane Doe');
    expect(card.showCategory, isFalse);
    expect(
      find.descendant(of: find.byType(GbModCard).first, matching: find.textContaining('Jane Doe · ')),
      findsOneWidget,
    );
    expect(find.descendant(of: find.byType(GbModCard).first, matching: find.text('Jane Doe')), findsNothing);
  });

  group('Hide installed', () {
    testWidgets('drops the installed mods, counts what is left, and is written', (tester) async {
      bool? written;
      final container = await pumpCreator(
        tester,
        fetch: fetcher({1: () => exce}),
        installed: Future.value(libraryWith(janeMods)),
        onHide: (hide) => written = hide,
      );

      await tester.tap(find.byType(ZenithSwitch));
      await tester.pumpAndSettle();

      expect(written, isTrue);
      expect(container.read(marketplaceHideInstalledProvider), isTrue);
      expect(countLine(tester), '21 not installed');
      expect(cards(tester).map((c) => c.mod.idRow), isNot(contains(715093)));
      expect(
        find.descendant(of: find.byKey(const ValueKey('cast_character:jane')), matching: find.text('3 mods')),
        findsOneWidget,
        reason: "a tile counts the member's mods, whatever the grid hides",
      );
    });

    testWidgets('hiding everything a tile shows says so, and Show installed turns it off', (tester) async {
      bool? written;
      await pumpCreator(
        tester,
        fetch: fetcher({1: () => exce}),
        installed: Future.value(libraryWith(janeMods)),
        hideInstalled: true,
        onHide: (hide) => written = hide,
      );
      await tester.tap(find.byKey(const ValueKey('cast_character:jane')));
      await tester.pumpAndSettle();

      expect(countLine(tester), '0 mods for Jane Doe');
      expect(find.text('You have every one of these installed.'), findsOneWidget);
      expect(find.text('Show all 21'), findsOneWidget, reason: 'what pressing it shows, with Hide installed on');

      await tester.tap(find.text('Show installed'));
      await tester.pumpAndSettle();
      expect(written, isFalse);
      expect(cards(tester).map((c) => c.mod.idRow), janeMods);
    });
  });

  testWidgets('the content filter drops hidden records before anything is counted', (tester) async {
    // Exce's listing is all `hide` but two Bangboo skins, which is real: the filter is the common case here.
    await pumpCreator(tester, fetch: fetcher({1: () => exce}), filter: ContentFilterMode.hide);
    expect(find.text('2 mods for Zenless Zone Zero. None of them are in your library.'), findsOneWidget);
    expect(find.byKey(const ValueKey('cast_character:jane')), findsNothing);
    expect(countLine(tester), 'All 2 mods');
  });

  group('loading', () {
    List<GbMod> mods(int page) => [
      for (var i = 0; i < kCreatorPageSize; i++)
        GbMod(idRow: page * 1000 + i, name: 'Mod $page.$i', visibility: GbVisibility.show),
    ];

    test('fetches every page in turn, and stops at the twentieth with more left', () async {
      final asked = <(GbModSort, int)>[];
      final container = ProviderContainer(
        overrides: [
          creatorPageFetcherProvider.overrideWithValue(
            fetcher({
              for (var p = 1; p <= 30; p++) p: () => GbPage(records: mods(p), recordCount: 1500, perPage: 50),
            }, asked),
          ),
        ],
      );
      addTearDown(container.dispose);
      const listing = CreatorListing(2307694, GbModSort.newest);
      final subscription = container.listen(creatorFeedProvider(listing), (_, _) {});
      addTearDown(subscription.close);

      final first = await container.read(creatorFeedProvider(listing).future);
      expect(first.records, hasLength(50), reason: 'the page answers with page 1, before the rest');
      for (var i = 0; i < 100 && container.read(creatorFeedProvider(listing)).requireValue.pages.length < 20; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final feed = container.read(creatorFeedProvider(listing)).requireValue;
      expect(asked.map((a) => a.$2), [for (var p = 1; p <= 20; p++) p]);
      expect(feed.records, hasLength(1000));
      expect(isCreatorFeedCapped(feed), isTrue);
      expect(feed.loadingMore, isFalse);
    });

    test('stops at the record count, so a member with 60 mods costs two requests', () async {
      final asked = <(GbModSort, int)>[];
      final container = ProviderContainer(
        overrides: [
          creatorPageFetcherProvider.overrideWithValue(
            fetcher({
              1: () => GbPage(records: mods(1), recordCount: 60, perPage: 50),
              2: () => GbPage(records: mods(2).take(10).toList(), recordCount: 60, perPage: 50, isComplete: true),
            }, asked),
          ),
        ],
      );
      addTearDown(container.dispose);
      const listing = CreatorListing(1, GbModSort.newest);
      final subscription = container.listen(creatorFeedProvider(listing), (_, _) {});
      addTearDown(subscription.close);
      await container.read(creatorFeedProvider(listing).future);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final feed = container.read(creatorFeedProvider(listing)).requireValue;
      expect(asked, [(GbModSort.newest, 1), (GbModSort.newest, 2)]);
      expect(feed.records, hasLength(60));
      expect(isCreatorFeedCapped(feed), isFalse);
    });

    testWidgets('fills the header as later pages land, and says when it stopped at the first 1000', (tester) async {
      final second = Completer<GbPage<GbMod>>();
      await pumpCreator(
        tester,
        fetch: fetcher({
          1: () => GbPage(records: mods(1), recordCount: 1500, perPage: 50),
          2: () => second.future,
          for (var p = 3; p <= 20; p++) p: () => GbPage(records: mods(p), recordCount: 1500, perPage: 50),
        }),
        settle: false,
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('50 mods for Zenless Zone Zero. None of them are in your library.'), findsOneWidget);
      await toEnd(tester);
      expect(find.text('Loading more'), findsOneWidget);

      second.complete(GbPage(records: mods(2), recordCount: 1500, perPage: 50));
      for (var i = 0; i < 40; i++) {
        await tester.pump();
      }
      expect(
        find.text('1000 mods for Zenless Zone Zero. None of them are in your library.', skipOffstage: false),
        findsOneWidget,
      );
      await toEnd(tester);
      expect(find.byKey(const ValueKey('creator_capped')), findsOneWidget);
      expect(find.text('Showing the first 1000 mods.'), findsOneWidget);
    });

    testWidgets('a failed first page shows the failure, and Try again loads it', (tester) async {
      var calls = 0;
      await pumpCreator(
        tester,
        fetch: fetcher({1: () => calls++ == 0 ? throw const GbNetworkException('offline') : exce}),
      );
      expect(find.text("Couldn't reach GameBanana."), findsOneWidget);
      expect(find.byType(GbModCard), findsNothing);

      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(countLine(tester), 'All 24 mods');
    });

    testWidgets('a failed later page keeps the mods, and Try again goes on from it', (tester) async {
      var calls = 0;
      await pumpCreator(
        tester,
        fetch: fetcher({
          1: () => GbPage(records: mods(1), recordCount: 60, perPage: 50),
          2: () => calls++ == 0
              ? throw const GbNetworkException('offline')
              : GbPage(records: mods(2).take(10).toList(), recordCount: 60, perPage: 50, isComplete: true),
        }),
      );
      expect(countLine(tester), 'All 50 mods');
      await toEnd(tester);
      expect(find.text("Couldn't load more"), findsOneWidget);

      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(countLine(tester), 'All 60 mods');
    });

    testWidgets('the header, the tiles, the counts and the tile that is on stay while a new sort loads', (tester) async {
      final notJane = [
        for (final mod in exce.records)
          if (!janeMods.contains(mod.idRow)) mod,
      ];
      final jane = [
        for (final id in janeMods.reversed) exce.records.firstWhere((mod) => mod.idRow == id),
      ];
      final second = Completer<GbPage<GbMod>>();
      await pumpCreator(
        tester,
        fetch: (listing, page) async => switch ((listing.sort, page)) {
          (GbModSort.newest, 1) => exce,
          // Most liked: a first page with none of the tile's mods, the rest after it.
          (GbModSort.mostLiked, 1) => GbPage(records: notJane.take(10).toList(), recordCount: 24, perPage: 10),
          (GbModSort.mostLiked, 2) => second.future,
          final asked => throw StateError('$asked was not expected'),
        },
      );
      await tester.tap(find.byKey(const ValueKey('cast_character:jane')));
      await tester.pumpAndSettle();
      expect(countLine(tester), '3 mods for Jane Doe');

      await tester.tap(find.text('Newest'));
      await pumpFor(tester);
      await tester.tap(find.text('Most liked').last);
      await pumpFor(tester);

      expect(countLine(tester), '3 mods for Jane Doe', reason: "the new order's first page holds none of them");
      expect(find.text('Show all 24'), findsOneWidget);
      expect(find.text('24 mods for Zenless Zone Zero. None of them are in your library.'), findsOneWidget);
      expect(
        find.descendant(of: find.byKey(const ValueKey('cast_character:jane')), matching: find.text('3 mods')),
        findsOneWidget,
      );

      second.complete(GbPage(records: [...notJane.skip(10), ...jane], recordCount: 24, perPage: 14, isComplete: true));
      await tester.pumpAndSettle();
      expect(countLine(tester), '3 mods for Jane Doe');
      expect(cards(tester).map((c) => c.mod.idRow), janeMods.reversed, reason: 'in the new order');
    });

    testWidgets('a sort of its own fetches again, and leaves the saved sort alone', (tester) async {
      final asked = <(GbModSort, int)>[];
      final container = await pumpCreator(tester, fetch: fetcher({1: () => exce}, asked));

      await tester.tap(find.text('Newest'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Most liked').last);
      await tester.pumpAndSettle();

      expect(asked, [(GbModSort.newest, 1), (GbModSort.mostLiked, 1)]);
      expect(container.read(marketplaceSortProvider), GbModSort.newest);
      expect(container.read(marketplaceQueryProvider).sort, GbModSort.newest);
    });
  });
}
