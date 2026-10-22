import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/gamebanana/gamebanana.dart';
import 'package:mod_manager_flutter/screens/components/marketplace/gb_browse_view.dart';
import 'package:mod_manager_flutter/screens/components/marketplace/gb_detail_view.dart';
import 'package:mod_manager_flutter/screens/components/marketplace/gb_mod_card.dart';
import 'package:mod_manager_flutter/screens/components/marketplace/gb_thumbnail.dart';
import 'package:mod_manager_flutter/screens/marketplace_screen.dart';
import 'package:mod_manager_flutter/services/download/download_job.dart';
import 'package:mod_manager_flutter/services/download/download_queue.dart';
import 'package:mod_manager_flutter/services/download/download_request.dart';
import 'package:mod_manager_flutter/services/gamebanana/content_filter.dart';
import 'package:mod_manager_flutter/services/installed_mods_index.dart';
import 'package:mod_manager_flutter/utils/marketplace_providers.dart';
import 'package:mod_manager_flutter/utils/notifications.dart';
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

  List<Override> overrides({
    int? openMod,
    GbPage<GbMod>? results,
    bool realIndex = false,
    Map<int, GbMod> enrichment = const {},
    List<GbFile> profileFiles = const [],
  }) =>
      [
        marketplacePageFetcherProvider.overrideWithValue(
          (query, number, {refresh = false}) async => number == 1
              ? (results ?? page)
              : const GbPage<GbMod>(records: [], recordCount: 0, isComplete: true),
        ),
        modEnrichmentProvider.overrideWith((ref, key) async => enrichment),
        rootCategoriesProvider.overrideWith(
          (ref) async => [
            const GbCategoryNode(idRow: 30305, name: 'Character Skins'),
          ],
        ),
        categoryChildrenProvider
            .overrideWith((ref, arg) async => <GbCategoryNode>[]),
        topSubsProvider.overrideWith((ref) async => <GbTopSub>[]),
        modUpdatesProvider.overrideWith((ref, modId) async => <GbUpdate>[]),
        contentFilterProvider.overrideWith((ref) => ContentFilterMode.show),
        // The whole family, so a test may open whichever card happens to be on
        // screen rather than having to predict which one the grid put there.
        modProfileProvider.overrideWith(
          (ref, modId) async => GbMod(
            idRow: modId,
            name: modId == 1 ? 'First Mod' : 'Mod $modId',
            visibility: GbVisibility.show,
            files: profileFiles,
          ),
        ),
        // The library snapshot.
        // Overridden because the real one reaches `ApiService`, which needs a `SharedPreferences` binding this test has no business providing.
        // With [realIndex] the test overrides the library under it instead.
        if (!realIndex)
          installedModsIndexProvider
              .overrideWith((ref) async => InstalledModsIndex.empty),
        if (openMod != null)
          marketplaceRoutesProvider.overrideWith((ref) => MarketplaceRoutesController([MarketplaceModRoute(openMod)])),
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
    /// class — so this cannot accidentally read the wrong scrollable. The first
    /// one under it is its own; the search field and the carousel have theirs.
    double gridOffset(WidgetTester tester) => tester
        .state<ScrollableState>(
          find.descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable),
          ).first,
        )
        .position
        .pixels;

    /// The cover of the first card fully on screen below the pinned filter bar —
    /// which card that is depends on how far the grid was dragged, so it is
    /// found rather than named. The cover is what opens the mod.
    Finder onscreenCover(WidgetTester tester) {
      final cards = find.byType(GbModCard);
      final viewport = tester.getRect(find.byType(CustomScrollView));
      final barBottom = tester.getRect(find.text('Hide installed')).bottom + 20;
      for (var i = 0; i < cards.evaluate().length; i++) {
        final rect = tester.getRect(cards.at(i));
        if (rect.top >= barBottom && rect.bottom <= viewport.bottom) {
          return find.descendant(of: cards.at(i), matching: find.byType(GbThumbnail));
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

      await tester.tap(onscreenCover(tester));
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

      await tester.tap(onscreenCover(tester));
      await tester.pumpAndSettle();
      final first = tester.state(find.byType(GbDetailView));

      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.byType(GbDetailView), findsNothing,
          reason: 'the detail view is gone from the tree, not merely hidden');

      await tester.tap(onscreenCover(tester));
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

  testWidgets('opens from a page that watches the library without throwing',
      (tester) async {
    // The Library page stays mounted while it fades out, and it watches `libraryProvider`.
    // The real `installedModsIndexProvider` is kept here, as in the app:
    // the browse view's first build reads the library through it, so a refresh started inside that build pass marks the fading page dirty mid-build.
    // The tests above override the index and cannot see it.
    var libraryBuilds = 0;
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
              : const _LibraryPage(key: ValueKey('mods')),
        ),
      ),
      overrides: [
        ...overrides(realIndex: true),
        libraryProvider.overrideWith(
          () => _CountedLibrary(() => libraryBuilds++),
        ),
      ],
    );
    expectBuilt(_LibraryPage);
    final buildsBeforeOpen = libraryBuilds;

    showMarketplace.value = true;
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expectBuilt(MarketplaceScreen);
    expect(libraryBuilds, greaterThan(buildsBeforeOpen),
        reason: 'opening the marketplace still re-reads the library');
  });

  group('a download press', () {
    const mod = GbMod(idRow: 1, name: 'First Mod', visibility: GbVisibility.show);
    const file = GbFile(idRow: 42, file: 'first.zip');

    /// Queues [file] as an install from the mod page with [queue] as the download queue, and hands back the card it
    /// raised.
    Future<(AppNotification, ProviderContainer)> press(WidgetTester tester, _StubQueue queue) async {
      await pumpLocalized(
        tester,
        const MarketplaceScreen(),
        overrides: [...overrides(openMod: 1), downloadQueueProvider.overrideWith(() => queue)],
      );
      tester
          .widget<GbDetailView>(find.byType(GbDetailView))
          .onQueue(mod, [file], characterId: null, intent: DownloadIntent.install);
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(tester.element(find.byType(MarketplaceScreen)));
      return (container.read(notificationsProvider).single, container);
    }

    void expectOpensDownloads(AppNotification card, ProviderContainer container) {
      final action = card.actions.single;
      expect(action.label, 'Open Downloads');
      final before = container.read(downloadsPanelRequestProvider);
      action.onPressed();
      expect(container.read(downloadsPanelRequestProvider), before + 1);
    }

    testWidgets('of a file already downloading says so, with Open Downloads', (tester) async {
      final (card, container) = await press(tester, _StubQueue(initial: [_job(file, DownloadJobState.running)]));
      expect(card.title, 'Already downloading');
      expectOpensDownloads(card, container);
      await tester.pump(const Duration(seconds: 6));
    });

    testWidgets('that fails to queue says so, with Open Downloads for its failed row', (tester) async {
      final (card, container) = await press(tester, _StubQueue(enqueued: DownloadJobState.failed));
      expect(card.title, 'Download failed');
      expectOpensDownloads(card, container);
    });
  });

  group("the mod page's Install", () {
    const files = [
      GbFile(idRow: 11, file: 'first.zip'),
      GbFile(idRow: 12, file: 'second.zip'),
      GbFile(idRow: 13, file: 'third.zip'),
    ];

    /// The mod page of an Ellen Joe skin with [files], over [queue], with Turn on after installing at [turnOn].
    Future<void> pumpPage(WidgetTester tester, _StubQueue queue, {bool turnOn = false}) async {
      await pumpLocalized(
        tester,
        const MarketplaceScreen(),
        surfaceSize: const Size(1400, 1400),
        overrides: [
          ...overrides(openMod: 1),
          modProfileProvider.overrideWith(
            (ref, id) async => const GbMod(
              idRow: 1,
              name: 'First Mod',
              visibility: GbVisibility.show,
              category: GbCategoryRef(idRow: 30306, name: 'Ellen Joe'),
              superCategory: GbCategoryRef(idRow: 30305, name: 'Character Skins'),
              files: files,
            ),
          ),
          marketplaceTurnOnAfterInstallProvider.overrideWith((ref) => turnOn),
          downloadQueueProvider.overrideWith(() => queue),
        ],
      );
    }

    testWidgets('queues one job per picked file, in list order, with the character and Turn on', (tester) async {
      final queue = _StubQueue();
      await pumpPage(tester, queue, turnOn: true);

      // Picked out of order: the jobs follow the list.
      await tester.tap(find.byKey(const ValueKey('file_13')));
      await tester.tap(find.byKey(const ValueKey('file_11')));
      await tester.pump();
      await tester.tap(find.text('Install 2 files'));
      await tester.pumpAndSettle();

      expect(queue.calls.map((c) => c.$1.idRow), [11, 13]);
      expect(queue.calls.map((c) => c.$3), everyElement(DownloadIntent.install));
      expect(queue.carried, everyElement((characterId: 'ellen', turnOn: true)));
    });

    testWidgets('Download without installing queues the picks as archives, which turn nothing on', (tester) async {
      final queue = _StubQueue();
      await pumpPage(tester, queue, turnOn: true);

      await tester.tap(find.byKey(const ValueKey('file_12')));
      await tester.pump();
      await tester.tap(find.text('Download without installing'));
      await tester.pumpAndSettle();

      expect(queue.calls.single.$1.idRow, 12);
      expect(queue.calls.single.$3, DownloadIntent.keepArchive);
      expect(queue.carried.single.turnOn, isFalse);
      expect(find.text('Download only'), findsNothing, reason: 'no question about it');
    });
  });

  group("a card's Install", () {
    const file = GbFile(idRow: 1858310, file: 'only.zip');
    final oneFile = {1: const GbMod(idRow: 1, downloadCount: 0, files: [file])};

    testWidgets('queues the one file as an install with the mod page, without asking', (tester) async {
      final queue = _StubQueue();
      await pumpLocalized(
        tester,
        const MarketplaceScreen(),
        overrides: [
          ...overrides(enrichment: oneFile, profileFiles: const [file]),
          downloadQueueProvider.overrideWith(() => queue),
        ],
      );

      await tester.tap(find.text('Install'));
      await tester.pumpAndSettle();

      final (queuedFile, mod, intent) = queue.calls.single;
      expect(queuedFile.idRow, 1858310);
      expect(intent, DownloadIntent.install);
      expect(queue.carried.single, (characterId: 'unknown', turnOn: false),
          reason: 'a page whose category maps to no character installs under Unassigned, never a folder-name guess');
      expect(mod?.name, 'First Mod', reason: 'the mod page travels with the job, for the autofill');
      expect(find.byType(GbDetailView), findsNothing, reason: 'the grid stays where it was');
    });

    testWidgets("carries the GameBanana category's character and Turn on after installing", (tester) async {
      final queue = _StubQueue();
      await pumpLocalized(
        tester,
        const MarketplaceScreen(),
        overrides: [
          ...overrides(enrichment: oneFile),
          modProfileProvider.overrideWith(
            (ref, id) async => const GbMod(
              idRow: 1,
              name: 'First Mod',
              category: GbCategoryRef(idRow: 30306, name: 'Ellen Joe'),
              files: [file],
            ),
          ),
          marketplaceTurnOnAfterInstallProvider.overrideWith((ref) => true),
          downloadQueueProvider.overrideWith(() => queue),
        ],
      );

      await tester.tap(find.text('Install'));
      await tester.pumpAndSettle();

      expect(queue.carried.single, (characterId: 'ellen', turnOn: true));
    });

    testWidgets('opens the mod page when its page cannot be fetched', (tester) async {
      final queue = _StubQueue();
      await pumpLocalized(
        tester,
        const MarketplaceScreen(),
        overrides: [
          ...overrides(enrichment: oneFile),
          downloadQueueProvider.overrideWith(() => queue),
          modProfileProvider.overrideWith((ref, id) async => throw const GbNetworkException('offline')),
        ],
      );

      await tester.tap(find.text('Install'));
      await tester.pumpAndSettle();

      expect(queue.calls, isEmpty);
      expect(find.byType(GbDetailView), findsOneWidget);
    });

    testWidgets('opens the mod page on any failure, not only a GameBanana one, and stops showing Queued', (
      tester,
    ) async {
      final queue = _StubQueue();
      await pumpLocalized(
        tester,
        const MarketplaceScreen(),
        overrides: [
          ...overrides(enrichment: oneFile),
          downloadQueueProvider.overrideWith(() => queue),
          modProfileProvider.overrideWith((ref, id) async => throw StateError('a parse bug')),
        ],
      );

      await tester.tap(find.text('Install'));
      await tester.pumpAndSettle();

      expect(queue.calls, isEmpty);
      expect(find.byType(GbDetailView), findsOneWidget);
      final container = ProviderScope.containerOf(tester.element(find.byType(MarketplaceScreen)));
      expect(container.read(marketplacePendingInstallsProvider), isEmpty);
    });

    group('checks the fetched mod page names the same one current file', () {
      for (final (label, files) in [
        ('a second current file', const [file, GbFile(idRow: 1858311, file: 'other.zip')]),
        ('a different file', const [GbFile(idRow: 1858311, file: 'other.zip')]),
        ('no current file', const [GbFile(idRow: 1858310, file: 'only.zip', isArchived: true)]),
      ]) {
        testWidgets('and opens the mod page on $label', (tester) async {
          final queue = _StubQueue();
          await pumpLocalized(
            tester,
            const MarketplaceScreen(),
            overrides: [
              ...overrides(enrichment: oneFile, profileFiles: files),
              downloadQueueProvider.overrideWith(() => queue),
            ],
          );

          await tester.tap(find.text('Install'));
          await tester.pumpAndSettle();

          expect(queue.calls, isEmpty);
          expect(find.byType(GbDetailView), findsOneWidget);
        });
      }
    });

    group('outlives the page', () {
      /// The marketplace under the same keyed switch `main.dart` performs, with the mod page held by [profile].
      Future<(ValueNotifier<bool>, ProviderContainer)> pumpSwitchable(
        WidgetTester tester,
        Completer<GbMod> profile,
        _StubQueue queue,
      ) async {
        final showMarketplace = ValueNotifier<bool>(true);
        addTearDown(showMarketplace.dispose);
        await pumpLocalized(
          tester,
          ValueListenableBuilder<bool>(
            valueListenable: showMarketplace,
            builder: (_, marketplace, _) => AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              child: marketplace
                  ? const MarketplaceScreen(key: ValueKey('marketplace'))
                  : const SizedBox(key: ValueKey('mods')),
            ),
          ),
          overrides: [
            ...overrides(enrichment: oneFile),
            downloadQueueProvider.overrideWith(() => queue),
            modProfileProvider.overrideWith((ref, id) => profile.future),
          ],
        );
        final container = ProviderScope.containerOf(tester.element(find.byType(MarketplaceScreen)));
        await tester.tap(find.text('Install'));
        await tester.pump();
        expect(container.read(marketplacePendingInstallsProvider), {1}, reason: 'the card shows Queued meanwhile');
        return (showMarketplace, container);
      }

      testWidgets('a press queues its file after a switch to another page', (tester) async {
        final profile = Completer<GbMod>();
        final queue = _StubQueue();
        final (showMarketplace, container) = await pumpSwitchable(tester, profile, queue);

        showMarketplace.value = false;
        await tester.pumpAndSettle();
        expect(find.byType(MarketplaceScreen), findsNothing);

        profile.complete(const GbMod(idRow: 1, name: 'First Mod', files: [file]));
        await tester.pumpAndSettle();

        final (queuedFile, mod, intent) = queue.calls.single;
        expect(queuedFile.idRow, 1858310);
        expect(mod?.name, 'First Mod');
        expect(intent, DownloadIntent.install);
        expect(container.read(marketplacePendingInstallsProvider), isEmpty);
        expect(container.read(marketplaceOpenModProvider), isNull);
      });

      testWidgets('a failed fetch after the page is gone opens nothing', (tester) async {
        final profile = Completer<GbMod>();
        final queue = _StubQueue();
        final (showMarketplace, container) = await pumpSwitchable(tester, profile, queue);

        showMarketplace.value = false;
        await tester.pumpAndSettle();
        profile.completeError(const GbNetworkException('offline'));
        await tester.pumpAndSettle();

        expect(queue.calls, isEmpty);
        expect(container.read(marketplaceOpenModProvider), isNull, reason: 'Browse is not on screen');
        expect(container.read(marketplacePendingInstallsProvider), isEmpty);
        expect(container.read(notificationsProvider), isEmpty);
      });

      testWidgets("a failed fetch leaves another mod's page that was opened meanwhile", (tester) async {
        final profile = Completer<GbMod>();
        final queue = _StubQueue();
        final (_, container) = await pumpSwitchable(tester, profile, queue);

        container.read(marketplaceOpenModProvider.notifier).state = 2;
        await tester.pump();
        profile.completeError(const GbNetworkException('offline'));
        await tester.pumpAndSettle();

        expect(queue.calls, isEmpty);
        expect(container.read(marketplaceOpenModProvider), 2);
      });
    });
  });
}

DownloadJob _job(GbFile file, DownloadJobState state) => DownloadJob(
      seq: 1,
      request: DownloadRequest(url: Uri()),
      intent: DownloadIntent.install,
      subject: 'First Mod',
      file: file,
      state: state,
    );

/// A queue that starts nothing: [initial] is what it already holds, and an enqueue hands back a job in [enqueued].
class _StubQueue extends DownloadQueue {
  _StubQueue({this.initial = const [], this.enqueued = DownloadJobState.running});

  final List<DownloadJob> initial;
  final DownloadJobState enqueued;

  /// Every enqueue, as the file, the mod page and the intent it was given.
  final List<(GbFile, GbMod?, DownloadIntent)> calls = [];

  /// What each enqueue in [calls] carried for the install: its character and whether it turns the mod on.
  final List<({String? characterId, bool turnOn})> carried = [];

  @override
  List<DownloadJob> build() {
    super.build();
    return initial;
  }

  @override
  DownloadJob enqueue({
    required GbFile file,
    required String subject,
    required DownloadIntent intent,
    GbMod? mod,
    String? characterId,
    bool turnOn = false,
  }) {
    calls.add((file, mod, intent));
    carried.add((characterId: characterId, turnOn: turnOn));
    return _job(file, enqueued);
  }
}

/// Stands in for the Library page, which watches the library directly.
class _LibraryPage extends ConsumerWidget {
  const _LibraryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final library = ref.watch(libraryProvider);
    return Text('${library.valueOrNull?.length}');
  }
}

/// An empty library that answers asynchronously, as a scan does, and reports each build.
class _CountedLibrary extends LibraryNotifier {
  _CountedLibrary(this._onBuild);

  final void Function() _onBuild;

  @override
  Future<List<ModInfo>> build() async {
    _onBuild();
    return const <ModInfo>[];
  }
}
