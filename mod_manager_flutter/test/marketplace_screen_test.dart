import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_category.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_enums.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_mod.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_page.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_top_sub.dart';
import 'package:mod_manager_flutter/screens/components/marketplace/gb_browse_view.dart';
import 'package:mod_manager_flutter/screens/components/marketplace/gb_detail_view.dart';
import 'package:mod_manager_flutter/screens/components/marketplace/gb_mod_card.dart';
import 'package:mod_manager_flutter/screens/marketplace_screen.dart';
import 'package:mod_manager_flutter/services/gamebanana/content_filter.dart';
import 'package:mod_manager_flutter/services/installed_mods_index.dart';
import 'package:mod_manager_flutter/utils/marketplace_providers.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

import 'support/localized_harness.dart';

/// The marketplace *screen* — the shell that owns which of the two views is
/// showing, and the lifecycle work around them.
///
/// This file exists because nothing mounted this widget, and a one-line addition
/// to its `initState` shipped an exception that made the whole tab unusable while
/// the suite stayed green and `analyze` stayed clean. The views underneath were
/// each covered; the shell holding them was not. Mounting it is most of the test.
void main() {
  final page = GbPage<GbMod>(
    records: [
      const GbMod(idRow: 1, name: 'First Mod', visibility: GbVisibility.show),
    ],
    recordCount: 1,
    perPage: 30,
  );

  /// Enough cards that the grid genuinely overflows the viewport, so there is a
  /// scroll offset to lose in the first place.
  final longPage = GbPage<GbMod>(
    records: [
      for (var i = 1; i <= 40; i++)
        GbMod(idRow: i, name: 'Mod $i', visibility: GbVisibility.show),
    ],
    recordCount: 400,
    perPage: 30,
  );

  List<Override> overrides({int? openMod, GbPage<GbMod>? results}) => [
        marketplaceResultsProvider.overrideWith((ref) async => results ?? page),
        rootCategoriesProvider.overrideWith(
          (ref) async => [
            const GbCategoryNode(idRow: 30305, name: 'Character Skins'),
          ],
        ),
        categoryChildrenProvider
            .overrideWith((ref, arg) async => <GbCategoryNode>[]),
        topSubsProvider.overrideWith((ref) async => <GbTopSub>[]),
        contentFilterProvider.overrideWith((ref) => ContentFilterMode.show),
        // The whole family, so a test may open whichever card happens to be on
        // screen rather than having to predict which one the grid put there.
        modProfileProvider.overrideWith(
          (ref, modId) async => GbMod(
            idRow: modId,
            name: modId == 1 ? 'First Mod' : 'Mod $modId',
            visibility: GbVisibility.show,
            files: const <Never>[],
          ),
        ),
        // The library snapshot. Overridden because the real one reaches
        // `ApiService`, which needs a `SharedPreferences` binding this test has
        // no business providing.
        installedModsIndexProvider
            .overrideWith((ref) async => InstalledModsIndex.empty),
        if (openMod != null)
          marketplaceOpenModProvider.overrideWith((ref) => openMod),
      ];

  testWidgets('mounts on the results grid without throwing', (tester) async {
    // The regression guard. The screen refreshes its library snapshot when it
    // opens, and `WidgetRef.invalidate` cannot be called from `initState` — it
    // resolves its container through an inherited-widget lookup, which is exactly
    // what `initState` forbids. That threw on every mount and took the tab with
    // it. Nothing here needs a clever assertion: the widget merely has to mount.
    await pumpLocalized(tester, const MarketplaceScreen(),
        overrides: overrides());
    expectBuilt(MarketplaceScreen);
    expect(tester.takeException(), isNull);
    expect(find.byType(GbBrowseView), findsOneWidget);
  });

  testWidgets('mounts straight onto a mod detail view without throwing',
      (tester) async {
    // The other branch of the same `build`, reached when a mod was left open.
    await pumpLocalized(tester, const MarketplaceScreen(),
        overrides: overrides(openMod: 1));
    expectBuilt(MarketplaceScreen);
    expect(tester.takeException(), isNull);
    expect(find.byType(GbDetailView), findsOneWidget);
  });

  group('the grid keeps its place while a mod is open', () {
    /// The vertical offset of the results grid. `CustomScrollView` is unique to
    /// the browse view — the detail view is a `ListView`, which is a different
    /// class — so this cannot accidentally read the wrong scrollable.
    double gridOffset(WidgetTester tester) => tester
        .state<ScrollableState>(
          find.descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable),
          ),
        )
        .position
        .pixels;

    /// The first card fully inside the viewport — which card that is depends on
    /// how far the grid was dragged, so it is found rather than named.
    Finder onscreenCard(WidgetTester tester) {
      final cards = find.byType(GbModCard);
      final viewport = tester.getRect(find.byType(CustomScrollView));
      for (var i = 0; i < cards.evaluate().length; i++) {
        final rect = tester.getRect(cards.at(i));
        if (rect.top >= viewport.top && rect.bottom <= viewport.bottom) {
          return cards.at(i);
        }
      }
      fail('no mod card is fully on screen — nothing to tap');
    }

    testWidgets('opening a mod and pressing back returns to the same offset',
        (tester) async {
      // The complaint this is for: paging deep into the results, opening a mod,
      // and being dropped back at the very top of the grid. The views used to be
      // swapped by a conditional, which disposed the browse view — and with it
      // the scroll position — every time a mod was opened.
      await pumpLocalized(tester, const MarketplaceScreen(),
          overrides: overrides(results: longPage));

      await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
      await tester.pumpAndSettle();
      final scrolled = gridOffset(tester);
      expect(scrolled, greaterThan(100),
          reason: 'the drag has to actually move the grid for this to test anything');

      await tester.tap(onscreenCard(tester));
      await tester.pumpAndSettle();
      expect(find.byType(GbDetailView), findsOneWidget);

      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();

      expect(find.byType(GbDetailView), findsNothing);
      expect(gridOffset(tester), moreOrLessEquals(scrolled, epsilon: 0.5));
    });

    testWidgets('the detail view still starts fresh for each mod',
        (tester) async {
      // The other half of the same decision: the *grid* is kept alive, the
      // detail view is not. Its per-mod state (gallery index, reveal, archived
      // files) must reset, so nothing may persist across a close.
      await pumpLocalized(tester, const MarketplaceScreen(),
          overrides: overrides(results: longPage));

      await tester.tap(onscreenCard(tester));
      await tester.pumpAndSettle();
      final first = tester.state(find.byType(GbDetailView));

      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.byType(GbDetailView), findsNothing,
          reason: 'the detail view is gone from the tree, not merely hidden');

      await tester.tap(onscreenCard(tester));
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(GbDetailView)), isNot(same(first)));
    });
  });

  testWidgets('survives being closed and re-opened', (tester) async {
    // How the user actually hit it: the tabs are keyed children of an
    // `AnimatedSwitcher` with no keep-alive, so leaving the marketplace disposes
    // this screen and coming back mounts a brand-new one — which is the event the
    // snapshot refresh hangs off. So the lifecycle is driven here rather than
    // assumed, with the same keyed swap `main.dart` performs.
    // The switch is driven through a notifier rather than by re-pumping a fresh
    // tree, so the one `ProviderScope` and the harness's preloaded localizations
    // survive the swap. Re-pumping would replace both, which tests the harness
    // instead of the screen — and `AppLocalizations.of` asserts rather than
    // degrading, so a hand-rolled tree fails on the strings before it ever
    // reaches the lifecycle.
    final showMarketplace = ValueNotifier<bool>(false);
    addTearDown(showMarketplace.dispose);

    await pumpLocalized(
      tester,
      ValueListenableBuilder<bool>(
        valueListenable: showMarketplace,
        builder: (_, marketplace, __) => AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: marketplace
              ? const MarketplaceScreen(key: ValueKey('marketplace'))
              : const SizedBox(key: ValueKey('mods')),
        ),
      ),
      overrides: overrides(),
    );

    for (final open in [true, false, true]) {
      showMarketplace.value = open;
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        find.byType(MarketplaceScreen),
        open ? findsOneWidget : findsNothing,
        reason: 'marketplace open=$open',
      );
    }
  });
}
