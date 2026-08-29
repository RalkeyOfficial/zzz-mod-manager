import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_enums.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_image.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_page.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_submitter.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_top_sub.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/screens/components/marketplace/gb_top_subs_carousel.dart';
import 'package:mod_manager_flutter/services/gamebanana/content_filter.dart';
import 'package:mod_manager_flutter/services/installed_mods_index.dart';
import 'package:mod_manager_flutter/utils/marketplace_providers.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

import 'support/fixtures.dart';
import 'support/localized_harness.dart';

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
  }) async {
    await pumpLocalized(
      tester,
      // Auto-advance off by default: it would walk the carousel forward while
      // `pumpAndSettle` settles, so "the first card is showing" would be racing a
      // timer. The auto-advance group below opts back in explicitly.
      GbTopSubsCarousel(
        onOpenMod: onOpenMod ?? (_) {},
        autoAdvanceInterval: autoAdvance,
      ),
      overrides: [
        topSubsProvider.overrideWith((ref) async => subs ?? captured),
        contentFilterProvider.overrideWith((ref) => filter),
        installedModsIndexProvider.overrideWith((ref) async => installed),
      ],
    );
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

    testWidgets('the ends disable rather than wrap', (tester) async {
      // Clamped on purpose: a disabled arrow says "this is the end", where looping
      // silently back to the start reads as a glitch.
      await pump(
        tester,
        filter: ContentFilterMode.show,
        subs: [
          sub(1, GbTopSubPeriod.today, name: 'First'),
          sub(2, GbTopSubPeriod.week, name: 'Second'),
        ],
      );

      IconButton button(IconData icon) => tester.widget<IconButton>(
            find.ancestor(
              of: find.byIcon(icon),
              matching: find.byType(IconButton),
            ),
          );

      expect(button(Icons.chevron_left).onPressed, isNull,
          reason: 'no previous on the first card');
      expect(button(Icons.chevron_right).onPressed, isNotNull);

      await tester.tap(find.byTooltip('Next'));
      await tester.pumpAndSettle();

      expect(button(Icons.chevron_left).onPressed, isNotNull);
      expect(button(Icons.chevron_right).onPressed, isNull,
          reason: 'no next on the last card');
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

  testWidgets('tapping the card opens that mod id', (tester) async {
    int? opened;
    await pump(
      tester,
      subs: [sub(4242, GbTopSubPeriod.today, name: 'Target')],
      filter: ContentFilterMode.show,
      onOpenMod: (id) => opened = id,
    );
    await tester.tap(find.text('Target'));
    await tester.pumpAndSettle();
    expect(opened, 4242,
        reason: 'a top-sub id is a normal mod id and opens the detail view');
  });

  group('"in your library" badge', () {
    InstalledModsIndex libraryWith(int modId, String folder) =>
        InstalledModsIndex.fromMods([
          ModInfo(
            id: folder,
            name: folder,
            characterId: 'unknown',
            isActive: false,
            origin: ModOrigin(
              provenance: OriginProvenance.importedFolder,
              source: 'gamebanana',
              modId: modId,
              modIdConfidence: OriginConfidence.inferred,
            ),
          ),
        ]);

    testWidgets('marks a featured mod already in the library', (tester) async {
      await pump(
        tester,
        subs: [sub(4242, GbTopSubPeriod.today, name: 'Target')],
        filter: ContentFilterMode.show,
        installed: libraryWith(4242, 'Target Folder'),
      );

      expect(find.text('In library'), findsOneWidget);
    });

    testWidgets('says nothing about a mod the library does not have',
        (tester) async {
      await pump(
        tester,
        subs: [sub(4242, GbTopSubPeriod.today, name: 'Target')],
        filter: ContentFilterMode.show,
        installed: libraryWith(999, 'Something Else'),
      );

      expect(find.text('In library'), findsNothing);
    });

    testWidgets('is still shown on a card that is blurred', (tester) async {
      // Owning a mod is not adult content, so the badge is not gated on the
      // card having been revealed. That it also *paints over* the scrim is a
      // matter of Stack order and is not asserted here: unlike the grid card,
      // both orders behave identically under a tap, so the only test available
      // would be one about traversal order — brittle, and the consequence of
      // getting it wrong is a dimmed pill rather than a wrong answer.
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
          reason: 'the card is meant to still be blurred here');
      expect(find.text('In library'), findsOneWidget);
    });

    testWidgets('sits beside the period badge, not in a corner of its own',
        (tester) async {
      await pump(
        tester,
        subs: [sub(4242, GbTopSubPeriod.today, name: 'Target')],
        filter: ContentFilterMode.show,
        installed: libraryWith(4242, 'Target Folder'),
      );

      final period = tester.getRect(find.text('Best of today'));
      final badge = tester.getRect(find.text('In library'));

      expect(badge.left, greaterThan(period.right),
          reason: 'the badge should follow the period badge, not overlap it');
      expect(
        badge.center.dy,
        moreOrLessEquals(period.center.dy, epsilon: 1.0),
        reason: 'the two pills should share a baseline',
      );
      // Left-hand cluster, so it stays clear of the position counter.
      final counter = tester.getRect(find.text('1 / 1'));
      expect(badge.right, lessThan(counter.left));
    });

    testWidgets('does not carve a dead zone out of the card', (tester) async {
      // The badge is an overlay above the card's tap layer rather than inside
      // it, so anything up there that absorbs a hit steals it — which is the
      // bug the title and the period badge already had to be `IgnorePointer`ed
      // to fix.
      int? opened;
      await pump(
        tester,
        subs: [sub(4242, GbTopSubPeriod.today, name: 'Target')],
        filter: ContentFilterMode.show,
        onOpenMod: (id) => opened = id,
        installed: libraryWith(4242, 'Target Folder'),
      );

      // `tapAt` the badge's position rather than `tap` on the badge: the point
      // is that a click *there* reaches the card underneath, and `tap` would
      // warn that the widget it found never received the hit — which is the
      // pass condition, not a problem.
      await tester.tapAt(tester.getCenter(find.text('In library')));
      await tester.pumpAndSettle();

      expect(opened, 4242, reason: 'the badge swallowed the click');
    });
  });
}
