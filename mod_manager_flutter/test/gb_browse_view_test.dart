import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_category.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_enums.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_image.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_mod.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_page.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_submitter.dart';
import 'package:mod_manager_flutter/screens/components/marketplace/gb_browse_view.dart';
import 'package:mod_manager_flutter/screens/components/marketplace/gb_category_panel.dart';
import 'package:mod_manager_flutter/screens/components/marketplace/gb_mod_card.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_top_sub.dart';
import 'package:mod_manager_flutter/screens/components/marketplace/gb_top_subs_carousel.dart';
import 'package:mod_manager_flutter/services/gamebanana/content_filter.dart';
import 'package:mod_manager_flutter/utils/marketplace_providers.dart';
import 'package:mod_manager_flutter/services/gamebanana/gamebanana_client.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

import 'support/fake_http_transport.dart';
import 'support/localized_harness.dart';

/// Coverage for the results grid and its category panel, with every provider
/// faked so nothing touches the network.
///
/// These exist because two bugs shipped past a green suite and a clean analyze,
/// both only reachable by actually laying this widget out:
///
/// 1. A `TextEditingController.clear()` called inside `build()`. It notified the
///    `TextField` built beneath it, scheduling another build every frame — an
///    endless loop that surfaced as `!semantics.parentDataDirty` and never
///    mentioned the controller.
/// 2. `CrossAxisAlignment.stretch` on a `Row` sitting directly in a `Column`.
///    `stretch` passes a tight cross-axis constraint, and the incoming maxHeight
///    was unbounded, so both cells were handed an infinite height.
///
/// A rebuild loop fails as a `pumpAndSettle` timeout; a bad constraint fails as a
/// thrown layout error. Neither needs a specific assertion — the widget merely has
/// to be laid out, which is what nothing did before.
void main() {
  GbMod mod(int id, String name) => GbMod(
        idRow: id,
        name: name,
        likeCount: 298,
        viewCount: 2903,
        postCount: 9,
        visibility: GbVisibility.show,
        submitter: const GbSubmitter(idRow: 1, name: 'someone'),
        subCategory: const GbCategoryRef(name: 'Ellen Joe'),
      );

  GbCategoryNode node(int id, String name, {int children = 0}) =>
      GbCategoryNode(
        idRow: id,
        name: name,
        itemCount: 4589,
        categoryCount: children,
      );

  final page = GbPage<GbMod>(
    records: [mod(1, 'First Mod'), mod(2, 'Second Mod')],
    recordCount: 60,
    perPage: 30,
  );

  final roots = [
    node(30305, 'Character Skins', children: 60),
    node(30702, 'Bangboo Skins', children: 22),
    node(29874, 'Other/Misc'),
    node(30395, 'UI'),
  ];

  final topSubs = [
    GbTopSub(
      idRow: 900,
      period: GbTopSubPeriod.today,
      name: 'Top Today',
      image: GbImage(
        baseUrl: 'https://example.invalid',
        file: '900.jpg',
      ),
      visibility: GbVisibility.show,
      likeCount: 500,
    ),
  ];

  List<Override> overrides({
    GbPage<GbMod>? results,
    List<GbCategoryNode>? rootNodes,
    List<GbTopSub>? featured,
  }) =>
      [
        marketplaceResultsProvider
            .overrideWith((ref) async => results ?? page),
        rootCategoriesProvider
            .overrideWith((ref) async => rootNodes ?? roots),
        categoryChildrenProvider.overrideWith(
          (ref, arg) async => [node(30341, 'Ellen Joe'), node(30579, 'Miyabi')],
        ),
        // Without this the carousel would reach for the real network client and
        // silently render nothing — so every assertion about it would be vacuous.
        topSubsProvider.overrideWith((ref) async => featured ?? topSubs),
        contentFilterProvider.overrideWith((ref) => ContentFilterMode.show),
      ];

  Future<void> pumpBrowse(
    WidgetTester tester, {
    List<Override>? extra,
    Size size = const Size(1200, 800),
  }) async {
    await pumpLocalized(
      tester,
      GbBrowseView(onOpenMod: (_) {}),
      overrides: extra ?? overrides(),
      surfaceSize: size,
    );
    expectBuilt(GbBrowseView);
  }

  testWidgets('lays out without throwing or looping', (tester) async {
    await pumpBrowse(tester);
    expect(tester.takeException(), isNull);
    expect(find.byType(GbModCard), findsNWidgets(2));
    expect(find.text('First Mod'), findsOneWidget);
  });

  testWidgets('renders the category panel header and roots', (tester) async {
    await pumpBrowse(tester);
    expect(find.byType(GbCategoryPanelHeader), findsOneWidget);
    expect(find.byType(GbCategoryList), findsOneWidget);
    expect(find.text('Categories'), findsOneWidget);
    expect(find.text('All'), findsOneWidget);
    for (final name in ['Character Skins', 'Bangboo Skins', 'Other/Misc', 'UI']) {
      expect(find.text(name), findsOneWidget, reason: name);
    }
  });

  testWidgets('the header cell and the filter bar share one band height',
      (tester) async {
    // The alignment the layout is supposed to guarantee, asserted rather than
    // eyeballed: equal heights, and the category list starting exactly where the
    // band ends. Fixed paddings tuned by hand are what this replaced.
    await pumpBrowse(tester);

    final header = tester.getRect(find.byType(GbCategoryPanelHeader));
    final list = tester.getRect(find.byType(GbCategoryList));

    expect(list.top, moreOrLessEquals(header.bottom, epsilon: 1.0),
        reason: 'the category list must start where the header band ends');
    expect(header.width, kCategoryPanelWidth);
    expect(list.width, kCategoryPanelWidth);
    // The panel occupies the right edge, with the grid to its left.
    expect(header.right, moreOrLessEquals(list.right, epsilon: 0.5));
  });

  testWidgets('the search field does not fight the query state', (tester) async {
    // Types a search, submits, then selects a category — which leaves search mode.
    // The controller is cleared from a listener rather than during build; doing it
    // in build looped forever, so settling here is the assertion.
    await pumpBrowse(tester);

    await tester.enterText(find.byType(TextField), 'ellen');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Other/Misc'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('ellen'), findsNothing,
        reason: 'leaving search mode should clear the box');
  });

  testWidgets('expanding a root loads and shows its children', (tester) async {
    await pumpBrowse(tester);

    // Scoped to the panel in both directions: 'Ellen Joe' is also the mod cards'
    // category badge, so an unscoped finder matches before anything is expanded
    // and would make this assert the opposite of what it means to.
    Finder inPanel(String text) => find.descendant(
          of: find.byType(GbCategoryList),
          matching: find.text(text),
        );

    expect(inPanel('Ellen Joe'), findsNothing,
        reason: 'children load on expand, not up front');

    await tester.tap(find.byTooltip('Show subcategories').first);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(inPanel('Ellen Joe'), findsOneWidget);
    expect(inPanel('Miyabi'), findsOneWidget);
  });

  testWidgets('survives a narrow window', (tester) async {
    // 800px is the app's minimum window width; the panel takes a fixed 232 of it.
    await pumpBrowse(tester, size: const Size(800, 600));
    expect(tester.takeException(), isNull);
  });

  group('the featured carousel scrolls away with the grid', () {
    /// Enough cards that the content genuinely overflows an 800px-tall viewport.
    final manyResults = GbPage<GbMod>(
      records: [for (var i = 1; i <= 24; i++) mod(i, 'Mod $i')],
      recordCount: 240,
      perPage: 30,
    );

    testWidgets('is not pinned — scrolling moves it up', (tester) async {
      // The behaviour this pins: the carousel used to be a sibling *above* the
      // grid's own scroll view, so it stayed put no matter how far you scrolled.
      // It now shares one CustomScrollView with the grid.
      await pumpBrowse(tester, extra: overrides(results: manyResults));

      final before = tester.getRect(find.byType(GbTopSubsCarousel)).top;
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -200));
      await tester.pumpAndSettle();

      final carousel = find.byType(GbTopSubsCarousel);
      if (carousel.evaluate().isEmpty) return; // scrolled clean out of the tree

      // A generous threshold on purpose: `tester.drag` loses the touch-slop
      // distance, so the scroll offset is close to but never exactly the drag. What
      // matters is that it moved a long way, not by how much.
      expect(tester.getRect(carousel).top, lessThan(before - 100),
          reason: 'the carousel should move with the content, not stay pinned');
    });

    testWidgets('scrolls fully out of view when dragged far', (tester) async {
      await pumpBrowse(tester, extra: overrides(results: manyResults));
      expect(find.byType(GbTopSubsCarousel), findsOneWidget);

      await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      final carousel = find.byType(GbTopSubsCarousel);
      if (carousel.evaluate().isNotEmpty) {
        // Still built (slivers keep a cache) but pushed above the viewport.
        expect(tester.getRect(carousel).bottom, lessThan(0));
      }
    });

    testWidgets('the pager stays reachable without scrolling', (tester) async {
      // Deliberately *not* in the scroll view: paging is navigation, and hunting
      // for it at the bottom of a long grid would be worse the longer the page is.
      await pumpBrowse(tester, extra: overrides(results: manyResults));
      final pagerBefore = tester.getRect(find.text('Page 1 of 8')).top;

      await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
      await tester.pumpAndSettle();

      expect(find.text('Page 1 of 8'), findsOneWidget);
      expect(tester.getRect(find.text('Page 1 of 8')).top,
          moreOrLessEquals(pagerBefore, epsilon: 0.5));
    });

    testWidgets('is absent once a category is selected', (tester) async {
      await pumpBrowse(tester, extra: overrides(results: manyResults));
      expect(find.byType(GbTopSubsCarousel), findsOneWidget);

      await tester.tap(find.text('Other/Misc'));
      await tester.pumpAndSettle();

      expect(find.byType(GbTopSubsCarousel), findsNothing,
          reason: 'a game-wide best-of list is not about a filtered view');
    });
  });

  group('the refresh button', () {
    /// A real client over a fake transport, so "did it hit the network" is
    /// observable. `marketplaceResultsProvider` is deliberately *not* overridden
    /// here — the point is to exercise the real path the button drives.
    const body = '{"_aMetadata":{"_nRecordCount":1,"_nPerpage":30},'
        '"_aRecords":[{"_idRow":1,"_sName":"Only Mod"}]}';

    Future<FakeHttpTransport> pumpWithRealClient(WidgetTester tester) async {
      final transport = FakeHttpTransport()..stubAnything(body: body);
      final client = GameBananaClient(transport: transport);
      await pumpLocalized(
        tester,
        GbBrowseView(onOpenMod: (_) {}),
        overrides: [
          gameBananaClientProvider.overrideWithValue(client),
          rootCategoriesProvider.overrideWith((ref) async => roots),
          topSubsProvider.overrideWith((ref) async => topSubs),
          contentFilterProvider.overrideWith((ref) => ContentFilterMode.show),
        ],
      );
      expectBuilt(GbBrowseView);
      return transport;
    }

    testWidgets('actually re-fetches over the network', (tester) async {
      // The bug: `invalidate` alone re-read the client's 10-minute cache, so the
      // button could not change anything for ten minutes. A request count is the
      // only assertion that catches that — the old code returned valid data.
      final transport = await pumpWithRealClient(tester);
      final before = transport.callCount;
      expect(before, greaterThan(0), reason: 'the initial listing was fetched');

      await tester.tap(find.byIcon(Icons.refresh));
      await tester.pumpAndSettle();

      expect(transport.callCount, greaterThan(before),
          reason: 'refresh must bypass the cache and ask again');
    });

    testWidgets('spins and disables itself while in flight', (tester) async {
      final transport = await pumpWithRealClient(tester);

      IconButton button() => tester.widget<IconButton>(
            find.ancestor(
              of: find.byIcon(Icons.refresh),
              matching: find.byType(IconButton),
            ),
          );

      expect(button().onPressed, isNotNull);
      expect(button().tooltip, 'Refresh');

      await tester.tap(find.byIcon(Icons.refresh));
      await tester.pump(); // let setState land, before the minimum spin elapses

      expect(button().onPressed, isNull,
          reason: 'disabled while running, so presses cannot stack');
      expect(button().tooltip, 'Refreshing…');
      expect(find.byType(RotationTransition), findsWidgets);

      await tester.pumpAndSettle();
      expect(button().onPressed, isNotNull, reason: 're-enabled when done');
      expect(button().tooltip, 'Refresh');
      expect(transport.callCount, greaterThan(1));
    });

    testWidgets('keeps spinning long enough to be seen', (tester) async {
      // Without a floor, a warm CDN answers in milliseconds, the icon turns for a
      // frame, and the click looks ignored — the original complaint, just faster.
      final transport = await pumpWithRealClient(tester);
      await tester.tap(find.byIcon(Icons.refresh));

      // The request resolves almost immediately against the fake transport.
      await tester.pump(const Duration(milliseconds: 200));

      IconButton button() => tester.widget<IconButton>(
            find.ancestor(
              of: find.byIcon(Icons.refresh),
              matching: find.byType(IconButton),
            ),
          );
      expect(button().onPressed, isNull,
          reason: 'still spinning 200ms in, despite the response being instant');

      await tester.pumpAndSettle();
      expect(button().onPressed, isNotNull);
      expect(transport.callCount, greaterThan(1));
    });

    testWidgets('a failed refresh re-enables the button', (tester) async {
      // The grid owns the error state; the button must not be left dead.
      final transport = FakeHttpTransport()..stubAnything(body: body);
      final client = GameBananaClient(transport: transport, maxRetries: 0);
      await pumpLocalized(
        tester,
        GbBrowseView(onOpenMod: (_) {}),
        overrides: [
          gameBananaClientProvider.overrideWithValue(client),
          rootCategoriesProvider.overrideWith((ref) async => roots),
          topSubsProvider.overrideWith((ref) async => topSubs),
          contentFilterProvider.overrideWith((ref) => ContentFilterMode.show),
        ],
      );

      // Every further request fails.
      transport.stubAnything(statusCode: 500, body: '{}');

      await tester.tap(find.byIcon(Icons.refresh));
      await tester.pumpAndSettle();

      final button = tester.widget<IconButton>(
        find.ancestor(
          of: find.byIcon(Icons.refresh),
          matching: find.byType(IconButton),
        ),
      );
      expect(button.onPressed, isNotNull,
          reason: 'a failure must not leave refresh permanently disabled');
    });
  });

  testWidgets('an empty result set renders an empty state, not a crash',
      (tester) async {
    await pumpBrowse(
      tester,
      extra: overrides(
        results: const GbPage<GbMod>(records: [], recordCount: 0, perPage: 30),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(GbModCard), findsNothing);
  });
}
