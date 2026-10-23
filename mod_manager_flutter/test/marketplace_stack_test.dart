import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/core/button_feedback.dart';
import 'package:mod_manager_flutter/core/palette.dart';
import 'package:mod_manager_flutter/models/gamebanana/gamebanana.dart';
import 'package:mod_manager_flutter/screens/components/marketplace/gb_browse_view.dart';
import 'package:mod_manager_flutter/screens/components/marketplace/gb_creator_view.dart';
import 'package:mod_manager_flutter/screens/components/marketplace/gb_detail_view.dart';
import 'package:mod_manager_flutter/screens/components/marketplace/gb_mod_card.dart';
import 'package:mod_manager_flutter/screens/components/page_crumbs.dart';
import 'package:mod_manager_flutter/screens/components/zenith_controls.dart';
import 'package:mod_manager_flutter/screens/marketplace_screen.dart';
import 'package:mod_manager_flutter/services/gamebanana/content_filter.dart';
import 'package:mod_manager_flutter/services/installed_mods_index.dart';
import 'package:mod_manager_flutter/utils/marketplace_providers.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

import 'support/fixtures.dart';
import 'support/localized_harness.dart';

/// Browse's pages over the grid: a mod's page, the author's page it links to, a mod from there, and back down the
/// stack one page at a time.
void main() {
  final exce = parseEnvelope(loadGbFixture('mod_index_submitter_2307694'), GbMod.fromJson);
  const member = GbSubmitter(idRow: 2307694, name: 'Exce', profileUrl: 'https://gamebanana.com/members/2307694');
  const first = GbMod(
    idRow: 1,
    name: 'Nocturne of Light',
    visibility: GbVisibility.show,
    submitter: member,
    category: GbCategoryRef(idRow: 30306, name: 'Ellen Joe'),
    superCategory: GbCategoryRef(idRow: 30305, name: 'Character Skins'),
  );

  /// The screen as Browse, the page the sidebar shows, with [around] putting other widgets beside it.
  Future<ProviderContainer> pumpScreen(WidgetTester tester, {Widget Function(Widget screen)? around}) async {
    final container = ProviderContainer(
      overrides: [
        marketplacePageFetcherProvider.overrideWithValue(
          (query, page, {refresh = false}) async =>
              const GbPage<GbMod>(records: [first], recordCount: 1, isComplete: true),
        ),
        creatorPageFetcherProvider.overrideWithValue((listing, page) async => exce),
        modEnrichmentProvider.overrideWith((ref, key) async => const {}),
        rootCategoriesProvider.overrideWith((ref) async => <GbCategoryNode>[]),
        categoryChildrenProvider.overrideWith((ref, arg) async => <GbCategoryNode>[]),
        topSubsProvider.overrideWith((ref) async => <GbTopSub>[]),
        modUpdatesProvider.overrideWith((ref, modId) async => <GbUpdate>[]),
        contentFilterProvider.overrideWith((ref) => ContentFilterMode.show),
        modProfileProvider.overrideWith(
          (ref, id) async =>
              id == 1 ? first : GbMod(idRow: id, name: 'Mod $id', visibility: GbVisibility.show, submitter: member),
        ),
        installedModsIndexProvider.overrideWith((ref) async => InstalledModsIndex.empty),
      ],
    );
    addTearDown(container.dispose);
    container.read(destinationProvider.notifier).state = AppDestination.browse;
    const screen = MarketplaceScreen();
    await pumpLocalized(
      tester,
      around?.call(screen) ?? screen,
      container: container,
      surfaceSize: const Size(1400, 1000),
    );
    expectBuilt(MarketplaceScreen);
    return container;
  }

  /// The page on top: the last of its kind, since the pages under it stay mounted.
  Finder top(Type page) => find.byType(page).last;

  /// The crumbs of the page on top as they are drawn, slashes included: "Browse / Ellen Joe / Nocturne of Light".
  String crumbs(WidgetTester tester, Type page) {
    final strip = find.descendant(of: top(page), matching: find.byType(PageCrumbs));
    // Everything the strip renders but the trailing button.
    final button = find.descendant(of: strip, matching: find.byType(TextButton));
    final inButton = tester.widgetList<Text>(find.descendant(of: button, matching: find.byType(Text))).toSet();
    return [
      for (final text in tester.widgetList<Text>(find.descendant(of: strip, matching: find.byType(Text))))
        if (!inButton.contains(text)) text.data,
    ].join(' ');
  }

  Future<void> back(WidgetTester tester, Type page) async {
    await tester.tap(find.descendant(of: top(page), matching: find.byTooltip('Back')));
    await tester.pumpAndSettle();
  }

  testWidgets('the author link opens their page, and back walks down the stack one page at a time', (tester) async {
    final container = await pumpScreen(tester);
    List<MarketplaceRoute> routes() => container.read(marketplaceRoutesProvider);

    // Grid → mod.
    await tester.tap(find.descendant(of: find.byType(GbModCard), matching: find.byType(ZenithLink)));
    await tester.pumpAndSettle();
    expect(routes(), [const MarketplaceModRoute(1)]);
    expect(crumbs(tester, GbDetailView), 'Browse / Ellen Joe / Nocturne of Light');

    // Mod → creator, through the author's name.
    final author = find.descendant(of: top(GbDetailView), matching: find.widgetWithText(ZenithLink, 'Exce'));
    expect(author, findsOneWidget);
    await tester.tap(author);
    await tester.pumpAndSettle();
    expect(routes(), [const MarketplaceModRoute(1), const MarketplaceCreatorRoute(member)]);
    expect(crumbs(tester, GbCreatorView), 'Browse / Nocturne of Light / Exce');
    expect(find.text('24 mods for Zenless Zone Zero. None of them are in your library.'), findsOneWidget);

    // A tile on, then creator → mod.
    await tester.tap(find.byKey(const ValueKey('cast_character:jane')));
    await tester.pumpAndSettle();
    final card = find.descendant(of: top(GbCreatorView), matching: find.byType(GbModCard)).first;
    final opened = tester.widget<GbModCard>(card).mod.idRow;
    await tester.tap(find.descendant(of: card, matching: find.byType(ZenithLink)));
    await tester.pumpAndSettle();
    expect(routes().last, MarketplaceModRoute(opened));
    expect(routes(), hasLength(3));
    expect(crumbs(tester, GbDetailView), 'Browse / Exce / Mod $opened');

    // Back → the creator's page as it was left, its tile still on.
    await back(tester, GbDetailView);
    expect(routes(), [const MarketplaceModRoute(1), const MarketplaceCreatorRoute(member)]);
    expect(tester.widget<Text>(find.byKey(const ValueKey('creator_count'))).data, '3 mods for Jane Doe');

    // Back → the first mod, and the creator's page is gone.
    await back(tester, GbCreatorView);
    expect(routes(), [const MarketplaceModRoute(1)]);
    expect(find.byType(GbCreatorView), findsNothing);
    expect(find.byType(GbDetailView), findsOneWidget);

    // Back → the grid.
    await back(tester, GbDetailView);
    expect(routes(), isEmpty);
    expect(find.byType(GbDetailView), findsNothing);
    expect(find.byType(GbBrowseView), findsOneWidget);
  });

  testWidgets("the Browse crumb goes straight back to the grid, and the creator's crumb to its page", (tester) async {
    final container = await pumpScreen(tester);
    final navigator = container.read(marketplaceRoutesProvider.notifier);
    navigator.openFromGrid(1);
    navigator.open(const MarketplaceCreatorRoute(member));
    navigator.open(const MarketplaceModRoute(715093));
    await tester.pumpAndSettle();

    await tester.tap(find.descendant(of: top(GbDetailView), matching: find.widgetWithText(ZenithLink, 'Exce')).first);
    await tester.pumpAndSettle();
    expect(
      container.read(marketplaceRoutesProvider).last,
      const MarketplaceCreatorRoute(member),
      reason: "the creator's page is the one under, so its crumb goes back to it rather than opening it again",
    );
    expect(container.read(marketplaceRoutesProvider), hasLength(2));

    await tester.tap(find.descendant(of: top(GbCreatorView), matching: find.widgetWithText(ZenithLink, 'Browse')));
    await tester.pumpAndSettle();
    expect(container.read(marketplaceRoutesProvider), isEmpty);
    expect(find.byType(GbCreatorView), findsNothing);
  });

  group('back from the keyboard and the mouse', () {
    /// A mod's page with the creator's page over it, so each back has a page to leave and one to land on.
    Future<ProviderContainer> twoPages(WidgetTester tester, {Widget Function(Widget screen)? around}) async {
      final container = await pumpScreen(tester, around: around);
      container.read(marketplaceRoutesProvider.notifier)
        ..openFromGrid(1)
        ..open(const MarketplaceCreatorRoute(member));
      await tester.pumpAndSettle();
      return container;
    }

    Future<void> altLeft(WidgetTester tester) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();
    }

    Future<void> escape(WidgetTester tester) async {
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
    }

    Future<void> mouseBack(WidgetTester tester) async {
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse, buttons: kBackMouseButton);
      await gesture.down(tester.getCenter(find.byType(MarketplaceScreen)));
      await gesture.up();
      await tester.pumpAndSettle();
    }

    final inputs = <String, Future<void> Function(WidgetTester)>{
      'Escape': escape,
      'Alt+Left': altLeft,
      'the mouse back button': mouseBack,
    };

    for (final MapEntry(key: name, value: press) in inputs.entries) {
      testWidgets('$name goes back one page at a time, and does nothing on the grid', (tester) async {
        final container = await twoPages(tester);
        List<MarketplaceRoute> routes() => container.read(marketplaceRoutesProvider);

        await press(tester);
        expect(routes(), [const MarketplaceModRoute(1)]);
        expect(find.byType(GbCreatorView), findsNothing);
        expect(find.byType(GbDetailView), findsOneWidget);

        await press(tester);
        expect(routes(), isEmpty);
        expect(find.byType(GbDetailView), findsNothing);

        await press(tester);
        expect(routes(), isEmpty);
        expect(find.byType(GbBrowseView), findsOneWidget);
      });

      testWidgets('$name does nothing while Browse is not the page shown', (tester) async {
        final container = await twoPages(tester);
        container.read(destinationProvider.notifier).state = AppDestination.settings;
        await press(tester);
        expect(container.read(marketplaceRoutesProvider), hasLength(2));
      });
    }

    testWidgets('a dialog over Browse keeps Escape and Alt+Left, and its barrier the mouse back button', (
      tester,
    ) async {
      final container = await twoPages(tester);
      showDialog<void>(
        context: tester.element(top(GbCreatorView)),
        builder: (_) => const AlertDialog(content: Text('A dialog')),
      );
      await tester.pumpAndSettle();

      await altLeft(tester);
      await mouseBack(tester);
      expect(find.text('A dialog'), findsOneWidget);
      expect(container.read(marketplaceRoutesProvider), hasLength(2));

      await escape(tester);
      expect(find.text('A dialog'), findsNothing, reason: 'Escape closes the dialog');
      expect(container.read(marketplaceRoutesProvider), hasLength(2), reason: '…and only the dialog');
    });

    group('a menu opened by a click', () {
      Future<void> clickOpen(WidgetTester tester, Finder button, String header) async {
        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(find.text(header), findsOneWidget, reason: 'the menu is open');
      }

      Finder sortButton(Type page) => find.descendant(
        of: find.descendant(of: top(page), matching: find.byType(GbSortMenu)),
        matching: find.byType(OutlinedButton),
      );

      testWidgets("on a creator's page, Escape closes the Sort menu and the page stays", (tester) async {
        final container = await twoPages(tester);
        await clickOpen(tester, sortButton(GbCreatorView), 'SORT BY');

        await escape(tester);
        expect(find.text('SORT BY'), findsNothing);
        expect(container.read(marketplaceRoutesProvider), hasLength(2));

        // Closed, the next Escape is a back again.
        await escape(tester);
        expect(container.read(marketplaceRoutesProvider), [const MarketplaceModRoute(1)]);
      });

      testWidgets('opened from the keyboard, focus and its ring stay on the button, and Escape closes the menu', (
        tester,
      ) async {
        final container = await twoPages(tester);
        final button = sortButton(GbCreatorView);
        final buttonFocus = Focus.of(tester.element(find.descendant(of: button, matching: find.byType(Row)).first));
        buttonFocus.requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(find.text('SORT BY'), findsOneWidget, reason: 'Enter opens the menu');

        final accent = ZenithPalette.of(tester.element(button)).accent;
        void expectRingOnButton(String reason) {
          expect(FocusManager.instance.primaryFocus, buttonFocus, reason: reason);
          final ring = find.descendant(of: find.byType(ButtonFocusRing), matching: find.byType(CustomPaint));
          expect(ring, findsOneWidget, reason: reason);
          // The ring paints over the whole overlay, moved to the button's place.
          final at = tester.getTopLeft(button);
          expect(
            tester.renderObject(ring),
            paints
              ..transform(matrix4: equals(Matrix4.translationValues(at.dx, at.dy, 0).storage))
              ..drrect(color: accent),
            reason: reason,
          );
        }

        expectRingOnButton('the menu is open');
        await escape(tester);
        expect(find.text('SORT BY'), findsNothing);
        expect(container.read(marketplaceRoutesProvider), hasLength(2));
        expectRingOnButton('Escape closed the menu');
      });

      testWidgets("on a creator's page, Alt+Left and the back button don't go back while the menu is open", (
        tester,
      ) async {
        final container = await twoPages(tester);
        await clickOpen(tester, sortButton(GbCreatorView), 'SORT BY');

        await altLeft(tester);
        expect(find.text('SORT BY'), findsOneWidget);
        expect(container.read(marketplaceRoutesProvider), hasLength(2));

        // Pressed outside the menu, the back button closes it as any click outside does, and goes nowhere.
        await mouseBack(tester);
        expect(find.text('SORT BY'), findsNothing);
        expect(container.read(marketplaceRoutesProvider), hasLength(2));
      });

      testWidgets("on the grid, Escape closes the Sort and Mature content menus", (tester) async {
        final container = await pumpScreen(tester);
        await clickOpen(tester, sortButton(GbBrowseView), 'SORT BY');
        await escape(tester);
        expect(find.text('SORT BY'), findsNothing);

        await clickOpen(
          tester,
          find.ancestor(of: find.byIcon(Icons.visibility_outlined), matching: find.byType(OutlinedButton)),
          'MATURE CONTENT',
        );
        await escape(tester);
        expect(find.text('MATURE CONTENT'), findsNothing);
        expect(container.read(marketplaceRoutesProvider), isEmpty);
        expect(find.byType(GbBrowseView), findsOneWidget);
      });
    });

    testWidgets('a focused text field keeps Escape and Alt+Left', (tester) async {
      final container = await twoPages(
        tester,
        around: (screen) => Column(
          children: [
            const TextField(key: ValueKey('field')),
            Expanded(child: screen),
          ],
        ),
      );
      await tester.tap(find.byKey(const ValueKey('field')));
      await tester.pump();

      await escape(tester);
      await altLeft(tester);
      expect(container.read(marketplaceRoutesProvider), hasLength(2));
    }, variant: TargetPlatformVariant(const {TargetPlatform.linux, TargetPlatform.windows}));
  });

  group('the stack', () {
    test('opening a page already in it goes back to it rather than opening it twice', () {
      final navigator = MarketplaceRoutesController();
      navigator.openFromGrid(1);
      navigator.open(const MarketplaceCreatorRoute(member));
      navigator.open(const MarketplaceModRoute(2));
      navigator.open(const MarketplaceCreatorRoute(GbSubmitter(idRow: 2307694, name: 'renamed')));
      expect(navigator.state, [const MarketplaceModRoute(1), const MarketplaceCreatorRoute(member)]);
      navigator.open(const MarketplaceModRoute(1));
      expect(navigator.state, [const MarketplaceModRoute(1)]);
    });

    test("a mod opened from outside Browse is the only page, and reads back as the mod on top", () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final navigator = container.read(marketplaceRoutesProvider.notifier);
      navigator.openFromGrid(1);
      navigator.open(const MarketplaceCreatorRoute(member));
      expect(container.read(marketplaceOpenModProvider), isNull, reason: "a creator's page is on top");

      container.read(marketplaceOpenModProvider.notifier).state = 7;
      expect(container.read(marketplaceRoutesProvider), [const MarketplaceModRoute(7)]);
      expect(container.read(marketplaceOpenModProvider), 7);

      container.read(marketplaceOpenModProvider.notifier).state = null;
      expect(container.read(marketplaceRoutesProvider), isEmpty);
    });
  });
}
