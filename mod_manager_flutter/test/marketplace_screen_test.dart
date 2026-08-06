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

  List<Override> overrides({int? openMod}) => [
        marketplaceResultsProvider.overrideWith((ref) async => page),
        rootCategoriesProvider.overrideWith(
          (ref) async => [
            const GbCategoryNode(idRow: 30305, name: 'Character Skins'),
          ],
        ),
        categoryChildrenProvider
            .overrideWith((ref, arg) async => <GbCategoryNode>[]),
        topSubsProvider.overrideWith((ref) async => <GbTopSub>[]),
        contentFilterProvider.overrideWith((ref) => ContentFilterMode.show),
        modProfileProvider(1).overrideWith(
          (ref) async => const GbMod(
            idRow: 1,
            name: 'First Mod',
            visibility: GbVisibility.show,
            files: <Never>[],
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
