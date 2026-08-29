import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_enums.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_exceptions.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_mod.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_page.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_top_sub.dart';
import 'package:mod_manager_flutter/screens/components/marketplace/gb_browse_view.dart';
import 'package:mod_manager_flutter/screens/components/marketplace/gb_detail_view.dart';
import 'package:mod_manager_flutter/screens/components/marketplace/gb_state_view.dart';
import 'package:mod_manager_flutter/services/gamebanana/content_filter.dart';
import 'package:mod_manager_flutter/services/installed_mods_index.dart';
import 'package:mod_manager_flutter/utils/marketplace_providers.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

import 'support/localized_harness.dart';

/// What the two browser screens say when they have nothing to show.
///
/// The four failure kinds and the retry rule are pinned in
/// `gb_failure_test.dart`; this file is about what reaches the screen. Two of
/// these assertions are the ones the code was actually getting wrong: the grid
/// printed `GbException.message` — server English the model marks "not for
/// display" — and the detail header read *Loading…* over a failed load.
void main() {
  /// A message no localized string could ever contain, so finding it on screen
  /// can only mean the wire text leaked through.
  const wireText = 'Server asked us to back off (HTTP 429)';

  GbMod adultMod(int id) => GbMod(
        idRow: id,
        name: 'Flagged Mod $id',
        visibility: GbVisibility.hide,
      );

  Future<void> pumpBrowse(
    WidgetTester tester, {
    required Object? error,
    GbPage<GbMod>? page,
    ContentFilterMode filter = ContentFilterMode.show,
    ContentFilterMode? Function()? writerSpy,
    ProviderContainer? container,
    List<Override> extra = const [],
  }) async {
    await pumpLocalized(
      tester,
      GbBrowseView(
        onOpenMod: (_) {},
        contentFilterWriter: (mode) async => writerSpy?.call(),
      ),
      container: container,
      overrides: container != null
          ? null
          : [
              marketplaceResultsProvider.overrideWith(
                (ref) async => error != null ? throw error : page!,
              ),
              // The panel and the carousel load independently; left alone they
              // reach for the real client.
              rootCategoriesProvider.overrideWith((ref) async => []),
              topSubsProvider.overrideWith((ref) async => <GbTopSub>[]),
              contentFilterProvider.overrideWith((ref) => filter),
              installedModsIndexProvider
                  .overrideWith((ref) async => InstalledModsIndex.empty),
              ...extra,
            ],
    );
    expectBuilt(GbBrowseView);
  }

  group('a failed listing', () {
    testWidgets('says it could not reach GameBanana when offline',
        (tester) async {
      await pumpBrowse(
        tester,
        error: const GbNetworkException('SocketException: failed host lookup'),
      );

      expect(find.text("Couldn't reach GameBanana."), findsOneWidget);
      expect(find.text('Check your connection, then try again.'), findsOneWidget);
      expect(find.byIcon(Icons.wifi_off), findsOneWidget);
    });

    testWidgets('tells a back-off apart from a bug', (tester) async {
      await pumpBrowse(tester, error: const GbRateLimitException(wireText));

      expect(find.text('GameBanana asked us to slow down.'), findsOneWidget);
      expect(
        find.text('Something went wrong loading this.'),
        findsNothing,
        reason: 'a rate limit was reported as a generic failure',
      );
    });

    testWidgets('never renders the message from the wire', (tester) async {
      // `gb_exceptions.dart` states the rule: these carry codes, never
      // user-facing prose, because the API's own messages are server English
      // and cannot be localized. The grid used to print exactly this line.
      await pumpBrowse(tester, error: const GbRateLimitException(wireText));

      expect(find.textContaining('HTTP 429'), findsNothing);
      expect(find.textContaining('back off'), findsNothing);
    });

    testWidgets('retry re-runs the request', (tester) async {
      var attempts = 0;
      final container = ProviderContainer(overrides: [
        marketplaceResultsProvider.overrideWith((ref) async {
          attempts++;
          throw const GbNetworkException('offline');
        }),
        rootCategoriesProvider.overrideWith((ref) async => []),
        topSubsProvider.overrideWith((ref) async => <GbTopSub>[]),
        contentFilterProvider.overrideWith((ref) => ContentFilterMode.show),
        installedModsIndexProvider
            .overrideWith((ref) async => InstalledModsIndex.empty),
      ]);
      addTearDown(container.dispose);

      await pumpBrowse(tester, error: null, container: container);
      expect(attempts, 1);

      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();

      expect(attempts, 2, reason: 'the retry button did not re-issue anything');
    });
  });

  group('a mod that is gone', () {
    Future<void> pumpDetail(WidgetTester tester, Object error) async {
      await pumpLocalized(
        tester,
        GbDetailView(
          modId: 999999999,
          onBack: () {},
          onDownload: (_, __) {},
          onOpenInBrowser: (_) {},
        ),
        overrides: [
          modProfileProvider(999999999).overrideWith((ref) async => throw error),
          contentFilterProvider.overrideWith((ref) => ContentFilterMode.show),
          installedModsIndexProvider
              .overrideWith((ref) async => InstalledModsIndex.empty),
        ],
      );
      expectBuilt(GbDetailView);
    }

    testWidgets('offers no retry at all', (tester) async {
      await pumpDetail(
        tester,
        const GbApiException('gone', code: 'NO_SUCH_RECORD', statusCode: 404),
      );

      expect(find.text('This mod is no longer on GameBanana.'), findsOneWidget);
      expect(
        find.text('Try again'),
        findsNothing,
        reason: 'a button whose every press is guaranteed to fail was offered',
      );
    });

    testWidgets('every recoverable failure still offers one', (tester) async {
      await pumpDetail(tester, const GbNetworkException('offline'));
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('the header falls back to the id, never to "Loading…"',
        (tester) async {
      await pumpDetail(
        tester,
        const GbApiException('gone', code: null, statusCode: 404),
      );

      expect(
        find.text('Loading…'),
        findsNothing,
        reason: 'the title claimed to be loading over a message saying it failed',
      );
      expect(find.text('#999999999'), findsOneWidget);
    });
  });

  group('nothing to show', () {
    testWidgets('a fruitless search offers to clear itself', (tester) async {
      final container = ProviderContainer(overrides: [
        marketplaceResultsProvider.overrideWith(
          (ref) async => const GbPage<GbMod>(records: [], recordCount: 0),
        ),
        rootCategoriesProvider.overrideWith((ref) async => []),
        topSubsProvider.overrideWith((ref) async => <GbTopSub>[]),
        contentFilterProvider.overrideWith((ref) => ContentFilterMode.show),
        installedModsIndexProvider
            .overrideWith((ref) async => InstalledModsIndex.empty),
      ]);
      addTearDown(container.dispose);
      container.read(marketplaceQueryProvider.notifier).state =
          const MarketplaceQuery(mode: MarketplaceMode.search, text: 'zzzzqqq');

      await pumpBrowse(tester, error: null, container: container);

      expect(find.text('No mods found.'), findsOneWidget);
      await tester.tap(find.text('Clear search'));
      await tester.pumpAndSettle();

      expect(
        container.read(marketplaceQueryProvider).mode,
        MarketplaceMode.browse,
      );
      expect(container.read(marketplaceQueryProvider).text, isEmpty);
    });

    testWidgets('an empty page past the first offers a way back',
        (tester) async {
      final container = ProviderContainer(overrides: [
        marketplaceResultsProvider.overrideWith(
          (ref) async => const GbPage<GbMod>(records: [], recordCount: 0),
        ),
        rootCategoriesProvider.overrideWith((ref) async => []),
        topSubsProvider.overrideWith((ref) async => <GbTopSub>[]),
        contentFilterProvider.overrideWith((ref) => ContentFilterMode.show),
        installedModsIndexProvider
            .overrideWith((ref) async => InstalledModsIndex.empty),
      ]);
      addTearDown(container.dispose);
      container.read(marketplaceQueryProvider.notifier).state =
          const MarketplaceQuery(page: 7);

      await pumpBrowse(tester, error: null, container: container);

      await tester.tap(find.text('Back to page 1'));
      await tester.pumpAndSettle();

      expect(container.read(marketplaceQueryProvider).page, 1);
    });

    testWidgets('page 1 of an ordinary browse offers nothing, and says so',
        (tester) async {
      // The other half of §1's decision: only the *filtered* empty state is
      // actionable. Inventing a button here would send the user pressing
      // something that cannot help.
      await pumpBrowse(
        tester,
        error: null,
        page: const GbPage<GbMod>(records: [], recordCount: 0),
      );

      expect(find.text('No mods found.'), findsOneWidget);
      expect(find.text('Clear search'), findsNothing);
      expect(find.text('Back to page 1'), findsNothing);
    });
  });

  group('everything hidden by the content filter', () {
    testWidgets('is a different state from an empty result', (tester) async {
      await pumpBrowse(
        tester,
        error: null,
        filter: ContentFilterMode.hide,
        page: GbPage<GbMod>(
          records: [adultMod(1), adultMod(2)],
          recordCount: 2,
        ),
      );

      expect(
        find.text('Every result on this page is hidden by your '
            'adult-content filter.'),
        findsOneWidget,
      );
      expect(find.text('No mods found.'), findsNothing);
    });

    testWidgets('degrades hide to blur — never to show', (tester) async {
      ContentFilterMode? written;
      final container = ProviderContainer(overrides: [
        marketplaceResultsProvider.overrideWith(
          (ref) async =>
              GbPage<GbMod>(records: [adultMod(1)], recordCount: 1),
        ),
        rootCategoriesProvider.overrideWith((ref) async => []),
        topSubsProvider.overrideWith((ref) async => <GbTopSub>[]),
        contentFilterProvider.overrideWith((ref) => ContentFilterMode.hide),
        installedModsIndexProvider
            .overrideWith((ref) async => InstalledModsIndex.empty),
      ]);
      addTearDown(container.dispose);

      await pumpLocalized(
        tester,
        GbBrowseView(
          onOpenMod: (_) {},
          // The seam exists because the real writer builds a `ConfigService`
          // against the developer's own `<appData>/config.json` — a test that
          // pressed this button without one would rewrite their settings.
          contentFilterWriter: (mode) async => written = mode,
        ),
        container: container,
      );
      expectBuilt(GbBrowseView);

      await tester.tap(find.text('Blur them instead'));
      await tester.pumpAndSettle();

      expect(written, ContentFilterMode.blur, reason: 'not persisted as blur');
      expect(
        container.read(contentFilterProvider),
        ContentFilterMode.blur,
        reason: 'the grid would not re-filter until the next fetch',
      );
    });
  });

  testWidgets('the shared state view renders without an action', (tester) async {
    // The presentational half on its own: a state with nothing to do says
    // nothing rather than padding itself with a disabled button.
    await pumpLocalized(
      tester,
      const GbStateView(icon: Icons.search_off, title: 'Nothing here'),
    );
    expectBuilt(GbStateView);

    expect(find.text('Nothing here'), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
  });
}
