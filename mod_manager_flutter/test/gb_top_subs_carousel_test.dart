import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/core/palette.dart';
import 'package:mod_manager_flutter/models/gamebanana/gamebanana.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/screens/components/marketplace/gb_top_subs_carousel.dart';
import 'package:mod_manager_flutter/services/gamebanana/content_filter.dart';
import 'package:mod_manager_flutter/services/installed_mods_index.dart';
import 'package:mod_manager_flutter/utils/marketplace_providers.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

import 'support/fixtures.dart';
import 'support/library_override.dart';
import 'support/localized_harness.dart';
import 'support/origin_shorthand.dart';

/// The "best of" carousel — **one card at a time**, stepped with arrows.
///
/// That distinction is what these tests pin down: an earlier version rendered all
/// 21 entries side by side in a scrolling strip, which is not a carousel. So the
/// assertions are deliberately about *one* visible card and about the arrows
/// changing which one it is.
void main() {
  final captured =
      parseBareList(loadGbFixture('topsubs_19567'), GbTopSub.fromJson);

  GbTopSub sub(
    int id,
    GbTopSubPeriod period, {
    GbVisibility visibility = GbVisibility.show,
    String? name,
  }) =>
      GbTopSub(
        idRow: id,
        period: period,
        name: name ?? 'Mod $id',
        image: GbImage(
          baseUrl: 'https://example.invalid',
          file: '$id-800.jpg',
          variants: {220: '$id-220.jpg'},
        ),
        visibility: visibility,
        likeCount: 1234,
        submitter: const GbSubmitter(idRow: 9, name: 'author'),
      );

  Future<void> pump(
    WidgetTester tester, {
    List<GbTopSub>? subs,
    ContentFilterMode filter = ContentFilterMode.blur,
    void Function(int)? onOpenMod,
    Duration? autoAdvance,
    // Overridden rather than left to load, always. Unoverridden it reaches for
    // `ApiService`, which needs a real `SharedPreferences` and so resolves to an
    // error — silently, as an unread `AsyncValue`. Every "no badge" assertion
    // below would then pass for the wrong reason.
    InstalledModsIndex installed = InstalledModsIndex.empty,
    Map<int, GbMod> enrichment = const {},
    void Function(int, GbFile)? onInstallFile,
    List<Override> extra = const [],
    double? width,
  }) async {
    // Auto-advance off by default: it would walk the carousel forward while
    // `pumpAndSettle` settles, so "the first card is showing" would be racing a
    // timer. The auto-advance group below opts back in explicitly.
    final carousel = GbTopSubsCarousel(
      onOpenMod: onOpenMod ?? (_) {},
      onInstallFile: onInstallFile,
      autoAdvanceInterval: autoAdvance,
    );
    await pumpLocalized(
      tester,
      width == null
          ? carousel
          : Align(
              alignment: Alignment.topLeft,
              child: SizedBox(width: width, child: carousel),
            ),
      overrides: [
        topSubsProvider.overrideWith((ref) async => subs ?? captured),
        contentFilterProvider.overrideWith((ref) => filter),
        installedModsIndexProvider.overrideWith((ref) async => installed),
        modEnrichmentProvider.overrideWith((ref, key) async => enrichment),
        ...extra,
      ],
    );
    expectBuilt(GbTopSubsCarousel);
  }

  group('one card at a time', () {
    testWidgets('shows the first period only, not all seven', (tester) async {
      await pump(tester, filter: ContentFilterMode.show);
      expect(tester.takeException(), isNull);

      expect(find.text('Best of today'), findsOneWidget);
      // The whole point of the rebuild: the other windows are not on screen.
      for (final label in [
        'Best of this week',
        'Best of this month',
        'Best of all time',
      ]) {
        expect(find.text(label), findsNothing, reason: label);
      }
    });

    testWidgets('shows a position counter over the total', (tester) async {
      await pump(tester, filter: ContentFilterMode.show);
      expect(find.text('1 / 21'), findsOneWidget);
    });
  });

  group('arrows', () {
    testWidgets('next advances one card', (tester) async {
      await pump(
        tester,
        filter: ContentFilterMode.show,
        subs: [
          sub(1, GbTopSubPeriod.today, name: 'First'),
          sub(2, GbTopSubPeriod.week, name: 'Second'),
        ],
      );
      expect(find.text('First'), findsOneWidget);

      await tester.tap(find.byTooltip('Next'));
      await tester.pumpAndSettle();

      expect(find.text('Second'), findsOneWidget);
      expect(find.text('Best of this week'), findsOneWidget);
      expect(find.text('2 / 2'), findsOneWidget);
    });

    testWidgets('previous goes back', (tester) async {
      await pump(
        tester,
        filter: ContentFilterMode.show,
        subs: [
          sub(1, GbTopSubPeriod.today, name: 'First'),
          sub(2, GbTopSubPeriod.week, name: 'Second'),
        ],
      );
      await tester.tap(find.byTooltip('Next'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Previous'));
      await tester.pumpAndSettle();

      expect(find.text('First'), findsOneWidget);
      expect(find.text('1 / 2'), findsOneWidget);
    });

    testWidgets('wrap around at both ends', (tester) async {
      await pump(
        tester,
        filter: ContentFilterMode.show,
        subs: [
          sub(1, GbTopSubPeriod.today, name: 'First'),
          sub(2, GbTopSubPeriod.week, name: 'Second'),
          sub(3, GbTopSubPeriod.month, name: 'Third'),
        ],
      );

      await tester.tap(find.byTooltip('Previous'));
      await tester.pumpAndSettle();
      expect(find.text('Third'), findsOneWidget, reason: 'previous from the first slide is the last');
      expect(find.text('3 / 3'), findsOneWidget);

      await tester.tap(find.byTooltip('Next'));
      await tester.pumpAndSettle();
      expect(find.text('First'), findsOneWidget, reason: 'next from the last slide is the first');
    });

    testWidgets('are 36px, at the edges', (tester) async {
      await pump(
        tester,
        filter: ContentFilterMode.show,
        subs: [sub(1, GbTopSubPeriod.today), sub(2, GbTopSubPeriod.week)],
      );
      final slide = tester.getRect(find.byType(PageView));
      final previous = tester.getRect(find.byTooltip('Previous'));
      expect(previous.size, const Size(36, 36));
      expect(previous.left - slide.left, moreOrLessEquals(14, epsilon: 1.5));
      expect(slide.right - tester.getRect(find.byTooltip('Next')).right, moreOrLessEquals(14, epsilon: 1.5));
    });

    testWidgets('steps through every captured entry without error',
        (tester) async {
      await pump(tester, filter: ContentFilterMode.show);
      for (var i = 1; i < captured.length; i++) {
        await tester.tap(find.byTooltip('Next'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'at card ${i + 1}');
      }
      expect(find.text('21 / 21'), findsOneWidget);
      expect(find.text('Best of all time'), findsOneWidget);
    });
  });

  group('auto-advance', () {
    List<GbTopSub> three() => [
          sub(1, GbTopSubPeriod.today, name: 'First'),
          sub(2, GbTopSubPeriod.week, name: 'Second'),
          sub(3, GbTopSubPeriod.month, name: 'Third'),
        ];

    /// Long enough that `pumpAndSettle` during setup can't reach it, short enough
    /// to step through in a test.
    const interval = Duration(seconds: 3);

    testWidgets('advances on its own after the interval', (tester) async {
      await pump(
        tester,
        filter: ContentFilterMode.show,
        subs: three(),
        autoAdvance: interval,
      );
      expect(find.text('First'), findsOneWidget);

      await tester.pump(interval);
      await tester.pumpAndSettle();
      expect(find.text('Second'), findsOneWidget);

      await tester.pump(interval);
      await tester.pumpAndSettle();
      expect(find.text('Third'), findsOneWidget);
    });

    testWidgets('wraps at the end, unlike the arrows', (tester) async {
      // The arrows clamp so a disabled arrow can mark the end of the list. An
      // auto-advance that clamped would stop dead at the last card, which is not
      // "auto" — so the two navigations differ on purpose.
      await pump(
        tester,
        filter: ContentFilterMode.show,
        subs: three(),
        autoAdvance: interval,
      );

      for (var i = 0; i < 3; i++) {
        await tester.pump(interval);
        await tester.pumpAndSettle();
      }
      expect(find.text('First'), findsOneWidget,
          reason: 'three advances from card 1 of 3 lands back on card 1');
    });

    testWidgets('does not advance while the pointer is over it', (tester) async {
      await pump(
        tester,
        filter: ContentFilterMode.show,
        subs: three(),
        autoAdvance: interval,
      );

      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(
        pointer.hover(tester.getCenter(find.byType(PageView))),
      );
      await tester.pumpAndSettle();

      // Well past two intervals: without the pause this would be two cards on.
      await tester.pump(interval * 3);
      await tester.pumpAndSettle();
      expect(find.text('First'), findsOneWidget,
          reason: 'hovering must hold the current card');
    });

    testWidgets('resumes once the pointer leaves', (tester) async {
      await pump(
        tester,
        filter: ContentFilterMode.show,
        subs: three(),
        autoAdvance: interval,
      );

      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(
        pointer.hover(tester.getCenter(find.byType(PageView))),
      );
      await tester.pump(interval * 2);
      expect(find.text('First'), findsOneWidget);

      // Below the carousel, which sits in the top 250px of the surface — (5, 5)
      // looks "far away" but is still inside it, so onExit would never fire.
      final below = tester.getRect(find.byType(PageView)).bottom + 200;
      await tester.sendEventToBinding(pointer.hover(Offset(600, below)));
      await tester.pumpAndSettle();

      await tester.pump(interval);
      await tester.pumpAndSettle();
      expect(find.text('Second'), findsOneWidget,
          reason: 'the rotation should pick back up after the cursor leaves');
    });

    testWidgets('holds while the mod detail view is open', (tester) async {
      // The browse view stays mounted under the detail view, so the carousel is
      // still ticking behind an overlay unless it is told to stop.
      final container = ProviderContainer(
        overrides: [
          topSubsProvider.overrideWith((ref) async => three()),
          contentFilterProvider.overrideWith((ref) => ContentFilterMode.show),
          installedModsIndexProvider.overrideWith((ref) async => InstalledModsIndex.empty),
          modEnrichmentProvider.overrideWith((ref, key) async => const {}),
        ],
      );
      addTearDown(container.dispose);

      await pumpLocalized(
        tester,
        GbTopSubsCarousel(onOpenMod: (_) {}, autoAdvanceInterval: interval),
        container: container,
      );
      expect(find.text('First'), findsOneWidget);

      container.read(marketplaceOpenModProvider.notifier).state = 42;
      await tester.pumpAndSettle();

      await tester.pump(interval * 3);
      await tester.pumpAndSettle();
      expect(find.text('First'), findsOneWidget,
          reason: 'the detail view must hold the current card');

      // Back to the grid: the card they left is the card they return to, and the
      // rotation picks up from there.
      container.read(marketplaceOpenModProvider.notifier).state = null;
      await tester.pumpAndSettle();
      expect(find.text('First'), findsOneWidget);

      await tester.pump(interval);
      await tester.pumpAndSettle();
      expect(find.text('Second'), findsOneWidget);
    });

    testWidgets('a manual step resets the dwell', (tester) async {
      // Otherwise a card chosen with the arrow could slide away a moment later,
      // having inherited the tail of the previous interval.
      await pump(
        tester,
        filter: ContentFilterMode.show,
        subs: three(),
        autoAdvance: interval,
      );

      await tester.pump(interval - const Duration(milliseconds: 500));
      await tester.tap(find.byTooltip('Next'));
      await tester.pumpAndSettle();
      expect(find.text('Second'), findsOneWidget);

      // The old interval's remainder must not fire.
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      expect(find.text('Second'), findsOneWidget,
          reason: 'the dwell restarted, so it is too early to advance');

      await tester.pump(interval);
      await tester.pumpAndSettle();
      expect(find.text('Third'), findsOneWidget);
    });

    testWidgets('a single card never advances', (tester) async {
      await pump(
        tester,
        filter: ContentFilterMode.show,
        subs: [sub(1, GbTopSubPeriod.today, name: 'Only')],
        autoAdvance: interval,
      );
      await tester.pump(interval * 3);
      await tester.pumpAndSettle();
      expect(find.text('Only'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a collapsed carousel does not tick into a dead controller',
        (tester) async {
      // With everything filtered out the PageView is gone, leaving the controller
      // attached to nothing while the timer keeps firing. Without the `hasClients`
      // guard this throws.
      await pump(
        tester,
        subs: [sub(1, GbTopSubPeriod.today, visibility: GbVisibility.hide)],
        filter: ContentFilterMode.hide,
        autoAdvance: interval,
      );
      await tester.pump(interval * 3);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('content filter', () {
    testWidgets('collapses entirely when everything is hidden', (tester) async {
      await pump(
        tester,
        subs: [
          sub(1, GbTopSubPeriod.today, visibility: GbVisibility.hide),
          sub(2, GbTopSubPeriod.week, visibility: GbVisibility.warn),
        ],
        filter: ContentFilterMode.hide,
      );
      expect(tester.takeException(), isNull);
      expect(find.textContaining('Best of'), findsNothing);
      expect(find.byType(PageView), findsNothing);
    });

    testWidgets('drops hidden entries and renumbers the rest', (tester) async {
      await pump(
        tester,
        subs: [
          sub(1, GbTopSubPeriod.today, visibility: GbVisibility.hide),
          sub(2, GbTopSubPeriod.week, visibility: GbVisibility.show),
        ],
        filter: ContentFilterMode.hide,
      );
      expect(find.text('Best of this week'), findsOneWidget);
      expect(find.text('1 / 1'), findsOneWidget);
    });

    testWidgets('a blurred card reveals on tap without opening the mod',
        (tester) async {
      int? opened;
      await pump(
        tester,
        subs: [sub(7, GbTopSubPeriod.today, visibility: GbVisibility.hide)],
        onOpenMod: (id) => opened = id,
      );
      expect(tester.takeException(), isNull);

      await tester.tap(find.byIcon(Icons.visibility_off_outlined));
      await tester.pumpAndSettle();

      expect(opened, isNull, reason: 'revealing is not opening');
      expect(find.byIcon(Icons.visibility_off_outlined), findsNothing);
    });
  });

  group('absent states', () {
    testWidgets('renders nothing on error rather than an error box',
        (tester) async {
      // A decorative strip must not report a problem the user did not ask about;
      // the grid below owns the loading and error states.
      await pumpLocalized(
        tester,
        GbTopSubsCarousel(onOpenMod: (_) {}, autoAdvanceInterval: null),
        overrides: [
          topSubsProvider.overrideWith((ref) => Future.error('boom')),
          contentFilterProvider.overrideWith((ref) => ContentFilterMode.blur),
        ],
      );
      expect(find.textContaining('Best of'), findsNothing);
      expect(find.textContaining('boom'), findsNothing);
    });

    testWidgets('an empty response collapses', (tester) async {
      await pump(tester, subs: const []);
      expect(find.textContaining('Best of'), findsNothing);
    });
  });

  group('opening the mod', () {
    testWidgets('View mod opens that mod id', (tester) async {
      int? opened;
      await pump(
        tester,
        subs: [sub(4242, GbTopSubPeriod.today, name: 'Target')],
        filter: ContentFilterMode.show,
        onOpenMod: (id) => opened = id,
      );
      await tester.tap(find.text('View mod'));
      await tester.pumpAndSettle();
      expect(opened, 4242, reason: 'a top-sub id is a normal mod id and opens the detail view');
    });

    testWidgets('so does the cover outside the box', (tester) async {
      int? opened;
      await pump(
        tester,
        subs: [sub(4242, GbTopSubPeriod.today, name: 'Target')],
        filter: ContentFilterMode.show,
        onOpenMod: (id) => opened = id,
      );
      final slide = tester.getRect(find.byType(PageView));
      await tester.tapAt(slide.topCenter + const Offset(0, 30));
      await tester.pumpAndSettle();
      expect(opened, 4242);
    });
  });

  group('the info box', () {
    testWidgets('is drawn as designed: 460 at most, on the dark ground', (tester) async {
      await pump(tester, subs: [sub(1, GbTopSubPeriod.today, name: 'Target')], filter: ContentFilterMode.show);
      final title = tester.widget<Text>(find.text('Target'));
      expect(title.style?.fontFamily, 'Unbounded');
      final box = find.ancestor(of: find.text('Target'), matching: find.byType(Container)).first;
      expect(tester.getSize(box).width, lessThanOrEqualTo(460));
      final ground = (tester.widget<Container>(box).decoration! as BoxDecoration).color!;
      expect(ground.a, moreOrLessEquals(0.86, epsilon: 0.01));
      expect(tester.getSize(find.byType(PageView)).height, moreOrLessEquals(278, epsilon: 0.5));
    });

    final root = GbTopSub(
      idRow: 533785,
      period: GbTopSubPeriod.today,
      name: 'Target',
      visibility: GbVisibility.show,
      likeCount: 1234,
      rootCategory: const GbCategoryRef(name: 'Character Skins'),
    );

    testWidgets('names the root until the enrichment answers, and leaves downloads out', (tester) async {
      await pump(tester, subs: [root], filter: ContentFilterMode.show);
      expect(find.text('Character Skins'), findsOneWidget);
      expect(find.byIcon(Icons.download_rounded), findsNothing);
    });

    testWidgets('then names the character, with downloads', (tester) async {
      final enriched = enrichmentByMod(parseBareList(loadGbFixture('mod_multi_enrich_p1'), GbMod.fromJson));
      await pump(tester, subs: [root], filter: ContentFilterMode.show, enrichment: enriched);
      expect(find.text('Ellen Joe'), findsOneWidget);
      expect(find.text('Character Skins'), findsNothing);
      expect(find.text('151.1k'), findsOneWidget);
    });

    testWidgets('Install queues the one current file, as a card does', (tester) async {
      final enriched = enrichmentByMod(parseBareList(loadGbFixture('mod_multi_enrich_newest'), GbMod.fromJson));
      (int, GbFile)? queued;
      await pump(
        tester,
        subs: [sub(730505, GbTopSubPeriod.today, name: 'Target')],
        filter: ContentFilterMode.show,
        enrichment: enriched,
        onInstallFile: (id, file) => queued = (id, file),
      );
      await tester.tap(find.text('Install'));
      await tester.pumpAndSettle();
      expect(queued?.$1, 730505);
      expect(queued?.$2.idRow, 1858310);
    });

    testWidgets('Install opens the mod page when there are several files', (tester) async {
      final enriched = enrichmentByMod(parseBareList(loadGbFixture('mod_multi_enrich_p1'), GbMod.fromJson));
      int? opened;
      await pump(
        tester,
        subs: [sub(541825, GbTopSubPeriod.today, name: 'Target')],
        filter: ContentFilterMode.show,
        enrichment: enriched,
        onOpenMod: (id) => opened = id,
        onInstallFile: (_, _) => fail('a file is never picked for the user'),
      );
      await tester.tap(find.text('Install'));
      await tester.pumpAndSettle();
      expect(opened, 541825);
    });
  });

  group('the position pill', () {
    testWidgets("dots the current period's entries, the current one wide in the accent", (tester) async {
      await pump(
        tester,
        filter: ContentFilterMode.show,
        subs: [
          sub(1, GbTopSubPeriod.today),
          sub(2, GbTopSubPeriod.today),
          sub(3, GbTopSubPeriod.today),
          sub(4, GbTopSubPeriod.week),
        ],
      );
      Size dot(int i) => tester.getSize(find.byKey(ValueKey('carousel-dot-$i')));
      expect(dot(0), const Size(22, 8));
      expect(dot(1), const Size(8, 8));
      expect(dot(2), const Size(8, 8));
      expect(find.byKey(const ValueKey('carousel-dot-3')), findsNothing, reason: 'another period');
      final fill = tester.widget<AnimatedContainer>(
        find.descendant(of: find.byKey(const ValueKey('carousel-dot-0')), matching: find.byType(AnimatedContainer)),
      );
      expect((fill.decoration! as BoxDecoration).color, ZenithPalette.dark(AccentChoice.violet).accent);

      await tester.tap(find.byKey(const ValueKey('carousel-dot-2')));
      await tester.pumpAndSettle();
      expect(find.text('3 / 4'), findsOneWidget);
      expect(dot(2), const Size(22, 8));
    });
  });

  group('a mod in the library', () {
    InstalledModsIndex libraryWith(int modId, String folder) =>
        InstalledModsIndex.fromMods([
          ModInfo(
            id: folder,
            name: folder,
            characterId: 'unknown',
            isActive: false,
            origin: originFixture(
              provenance: OriginProvenance.importedFolder,
              source: 'gamebanana',
              modId: modId,
              modIdConfidence: OriginConfidence.inferred,
            ),
          ),
        ]);

    testWidgets('offers In library in place of Install', (tester) async {
      await pump(
        tester,
        subs: [sub(4242, GbTopSubPeriod.today, name: 'Target')],
        filter: ContentFilterMode.show,
        installed: libraryWith(4242, 'Target Folder'),
      );

      expect(find.widgetWithText(OutlinedButton, 'In library'), findsOneWidget);
      expect(find.text('Install'), findsNothing);
    });

    testWidgets('a mod the library does not have offers Install, filled', (tester) async {
      await pump(
        tester,
        subs: [sub(4242, GbTopSubPeriod.today, name: 'Target')],
        filter: ContentFilterMode.show,
        installed: libraryWith(999, 'Something Else'),
      );

      expect(find.text('In library'), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Install'), findsOneWidget);
    });

    testWidgets('In library shows the mod in the Characters view', (tester) async {
      final container = ProviderContainer(
        overrides: [
          topSubsProvider.overrideWith((ref) async => [sub(4242, GbTopSubPeriod.today, name: 'Target')]),
          contentFilterProvider.overrideWith((ref) => ContentFilterMode.show),
          installedModsIndexProvider.overrideWith((ref) async => libraryWith(4242, 'Target Folder')),
          modEnrichmentProvider.overrideWith((ref, key) async => const {}),
          libraryOf([ModInfo(id: 'Target Folder', name: 'Target Folder', characterId: 'ellen', isActive: false)]),
        ],
      );
      addTearDown(container.dispose);
      await pumpLocalized(
        tester,
        GbTopSubsCarousel(onOpenMod: (_) {}, autoAdvanceInterval: null),
        container: container,
      );

      await tester.tap(find.text('In library'));
      await tester.pumpAndSettle();

      expect(container.read(destinationProvider), AppDestination.characters);
      expect(container.read(selectedModIdProvider), 'Target Folder');
    });

    testWidgets('is still said on a slide that is blurred', (tester) async {
      // Owning a mod is not adult content, so the box is not gated on the
      // slide having been revealed.
      await pump(
        tester,
        subs: [
          sub(4242, GbTopSubPeriod.today,
              name: 'Target', visibility: GbVisibility.warn),
        ],
        filter: ContentFilterMode.blur,
        installed: libraryWith(4242, 'Target Folder'),
      );

      expect(find.text('Click to reveal'), findsOneWidget,
          reason: 'the slide is meant to still be blurred here');
      expect(find.text('In library'), findsOneWidget);
    });
  });

  group('nothing on the slide covers the info box', () {
    // Long enough to wrap to two lines in the box at every width, which is what makes the box tall.
    const longName = 'Victorian Ballgown with Lace Gloves and a Parasol Variant Pack';
    Rect boxOf(WidgetTester tester, String name) =>
        tester.getRect(find.ancestor(of: find.text(name), matching: find.byType(Container)).first);

    for (final width in <double>[560, 646, 800, 1000, 1200]) {
      testWidgets('the position pill, ${width.toInt()}px', (tester) async {
        await pump(tester, filter: ContentFilterMode.show, width: width);
        final name = captured.first.name!;
        final pill = tester.getRect(find.ancestor(of: find.text('1 / 21'), matching: find.byType(Container)).first);
        expect(boxOf(tester, name).overlaps(pill), isFalse);
        expect(tester.takeException(), isNull);
      });

      testWidgets('the reveal label, ${width.toInt()}px', (tester) async {
        await pump(
          tester,
          subs: [sub(1, GbTopSubPeriod.today, name: longName, visibility: GbVisibility.warn)],
          width: width,
        );
        final box = boxOf(tester, longName);
        for (final label in ['Mature content', 'Click to reveal']) {
          final rect = tester.getRect(find.text(label));
          expect(rect.height, greaterThan(0));
          expect(rect.overlaps(box), isFalse, reason: '"$label" is behind the info box');
        }
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('the keyboard', () {
    /// Tabs until [isTarget] holds for the focused node, and fails if it never does.
    Future<void> tabTo(WidgetTester tester, bool Function(Semantics semantics) isTarget) async {
      for (var i = 0; i < 20; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();
        final semantics = FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<Semantics>();
        if (semantics != null && isTarget(semantics)) return;
      }
      fail('Tab never reached it');
    }

    testWidgets('reaches the reveal, and Enter reveals', (tester) async {
      int? opened;
      await pump(
        tester,
        subs: [sub(7, GbTopSubPeriod.today, visibility: GbVisibility.warn)],
        onOpenMod: (id) => opened = id,
      );
      await tabTo(tester, (s) => s.properties.hint == 'Click to reveal');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('Click to reveal'), findsNothing);
      expect(opened, isNull, reason: 'revealing is not opening');
    });

    testWidgets('the dots are buttons named for their slide, and Space goes to one', (tester) async {
      final handle = tester.ensureSemantics();
      await pump(
        tester,
        filter: ContentFilterMode.show,
        subs: [
          sub(1, GbTopSubPeriod.today, name: 'First'),
          sub(2, GbTopSubPeriod.today, name: 'Second'),
        ],
      );
      expect(
        tester.getSemantics(find.byKey(const ValueKey('carousel-dot-1'))),
        isSemantics(label: 'Second', isButton: true, isSelected: false),
      );
      expect(
        tester.getSemantics(find.byKey(const ValueKey('carousel-dot-0'))),
        isSemantics(label: 'First', isButton: true, isSelected: true),
      );

      await tabTo(tester, (s) => s.properties.label == 'Second');
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(find.text('2 / 2'), findsOneWidget);
      handle.dispose();
    });
  });

  testWidgets('an arrow fills under the pointer, as any button does', (tester) async {
    await pump(
      tester,
      filter: ContentFilterMode.show,
      subs: [sub(1, GbTopSubPeriod.today), sub(2, GbTopSubPeriod.week)],
    );
    Color? fill() => tester
        .widget<Material>(find.descendant(of: find.byTooltip('Next'), matching: find.byType(Material)).first)
        .color;
    final idle = fill();

    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(tester.getCenter(find.byTooltip('Next'))));
    await tester.pumpAndSettle();
    expect(fill(), ZenithPalette.dark(AccentChoice.violet).hover);
    expect(fill(), isNot(idle));
  });
}
