import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_category.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_enums.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_mod.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_submitter.dart';
import 'package:mod_manager_flutter/screens/components/marketplace/gb_mod_card.dart';
import 'package:mod_manager_flutter/screens/components/marketplace/gb_thumbnail.dart';
import 'package:mod_manager_flutter/services/gamebanana/content_filter.dart';

import 'support/localized_harness.dart';

/// Layout regression tests for the results-grid card.
///
/// A card's width is **not** fixed: the grid reflows at a 300px max cross-axis
/// extent down to an 800px minimum window, and the app has its own zoom scale. So
/// the card has to survive a range of widths, not just the one it was eyeballed at.
///
/// These exist because the stats row shipped overflowing by 2.2px at a 275px card
/// (a trailing separator after the last stat, and no way to shrink). It rendered
/// fine and the app stayed usable, so only the debug assertion caught it — which is
/// exactly the class of bug a test should own rather than a person.
void main() {
  /// Worst case on purpose: all three counters present and wide.
  GbMod mod({
    int? likes = 298000,
    int? views = 1250000,
    int? posts = 4096,
    String name = 'Remielle Black & White - OG Variety Pack',
    String? category = 'Alexandrina Sebastiane',
    GbVisibility visibility = GbVisibility.show,
    DateTime? added,
    DateTime? updated,
    bool withDates = true,
    // An explicit flag, because `updated: null` cannot express "no update date"
    // against a `??` default — it just gets the default, which quietly made this
    // helper unable to set up the very case it was asked to.
    bool neverUpdated = false,
  }) {
    return GbMod(
      idRow: 1,
      name: name,
      likeCount: likes,
      viewCount: views,
      postCount: posts,
      visibility: visibility,
      submitter: const GbSubmitter(idRow: 2, name: 'Outbreaksurvivler'),
      subCategory: category == null ? null : GbCategoryRef(name: category),
      // Relative to the real clock, since the card reads DateTime.now(). Ages are
      // chosen far from a bucket boundary so these can't flake as time passes.
      dateAdded: withDates
          ? (added ?? DateTime.now().subtract(const Duration(days: 800)))
          : null,
      dateUpdated: (!withDates || neverUpdated)
          ? null
          : (updated ?? DateTime.now().subtract(const Duration(days: 3))),
    );
  }

  /// Every tooltip message currently in the tree.
  ///
  /// `find.byTooltip` matches literally, and the update tooltip carries today's
  /// date — so it is checked by prefix instead.
  Iterable<String> tooltipMessages(WidgetTester tester) => tester
      .widgetList<Tooltip>(find.byType(Tooltip))
      .map((t) => t.message)
      .whereType<String>();

  /// The grid's `mainAxisExtent`. Kept in sync with `gb_browse_view.dart`.
  const gridTileHeight = 240.0;

  Future<void> pumpCard(
    WidgetTester tester, {
    required double width,
    required GbMod card,
    double height = gridTileHeight,
    ContentTreatment treatment = ContentTreatment.show,
    List<String> installedAs = const <String>[],
    VoidCallback? onOpen,
  }) async {
    await pumpLocalized(
      tester,
      Center(
        // Mirrors the real grid geometry: `maxCrossAxisExtent` varies the width
        // while `mainAxisExtent` fixes the height, so height is deliberately
        // *not* derived from width here either.
        child: SizedBox(
          width: width,
          height: height,
          child: GbModCard(
            mod: card,
            treatment: treatment,
            onOpen: onOpen ?? () {},
            installedAs: installedAs,
          ),
        ),
      ),
    );
    expectBuilt(GbModCard);
  }

  group('does not overflow at any card width the grid can produce', () {
    // The grid produces roughly 150–300px tiles depending on window width and
    // sidebar state. 275px is where the reported horizontal overflow occurred (a
    // 127.3px stats slot); 140–160px is where the *vertical* overflow used to
    // start, and is kept in the range as the regression guard for it.
    for (final width in <double>[140, 160, 180, 200, 233, 260, 275, 300, 320]) {
      testWidgets('${width.toInt()}px', (tester) async {
        await pumpCard(tester, width: width, card: mod());
        expect(tester.takeException(), isNull,
            reason: 'card overflowed at ${width}px');
      });
    }
  });

  testWidgets('survives a shorter tile than the grid asks for', (tester) async {
    // Not a width the grid produces — this stands in for the text block growing
    // (a larger OS text scale), which squeezes the card the same way. The cover
    // should absorb it rather than the layout breaking.
    await pumpCard(tester, width: 245, height: 170, card: mod());
    expect(tester.takeException(), isNull);
  });

  testWidgets('does not overflow with a blurred cover and reveal overlay',
      (tester) async {
    await pumpCard(
      tester,
      width: 275,
      card: mod(visibility: GbVisibility.warn),
      treatment: ContentTreatment.blur,
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Click to reveal'), findsOneWidget);
  });

  testWidgets('does not overflow when a counter is absent', (tester) async {
    // Nullable counters are the point of the model: null means "not in this
    // response". Fewer stats must not change the layout's validity.
    await pumpCard(tester, width: 275, card: mod(views: null, posts: null));
    expect(tester.takeException(), isNull);
  });

  testWidgets('does not overflow with no stats and no category at all',
      (tester) async {
    await pumpCard(
      tester,
      width: 275,
      card: mod(likes: null, views: null, posts: null, category: null),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders compact counts rather than raw digits', (tester) async {
    // The compacting is what keeps the row near-fitting in the first place; if it
    // regressed to raw integers the FittedBox would silently shrink everything.
    await pumpCard(tester, width: 300, card: mod());
    expect(find.text('298.0k'), findsOneWidget);
    // 1_250_000 rounds up at one decimal — asserted rather than assumed, since
    // "1.2M" is the intuitive guess and the wrong one.
    expect(find.text('1.3M'), findsOneWidget);
    expect(find.text('4.1k'), findsOneWidget);
    expect(find.text('298000'), findsNothing);
  });

  testWidgets('shows the specific category, not a raw id', (tester) async {
    await pumpCard(tester, width: 300, card: mod());
    expect(find.text('Alexandrina Sebastiane'), findsOneWidget);
  });

  group('the status slot', () {
    testWidgets('is absent for a mod the library does not have',
        (tester) async {
      // The default, and the state every card is in while the library snapshot is
      // still loading. Silence is the only safe answer there.
      await pumpCard(tester, width: 300, card: mod());
      expect(find.text('In library'), findsNothing);
    });

    testWidgets('names the folders it matched', (tester) async {
      // Plural because it genuinely is: one GameBanana page routinely becomes two
      // folders (two variants installed side by side), so the tooltip lists them
      // instead of implying there is one. They are in the tooltip rather than
      // inline because the strip has room for two or three words at the narrow end
      // of the grid.
      await pumpCard(
        tester,
        width: 300,
        card: mod(),
        installedAs: const ['Shortcake-JuFufu', 'Shortcake-JuFufu (NSFW)'],
      );
      expect(find.text('In library'), findsOneWidget);
      expect(
        find.byTooltip(
          'In your library as Shortcake-JuFufu, Shortcake-JuFufu (NSFW)',
        ),
        findsOneWidget,
      );
    });

    testWidgets('sits inside the cover, opposite the obsolete badge',
        (tester) async {
      // Where it is *is* the design: over the artwork so it reads on a blurred
      // card, and top-right so it can coexist with `obsolete` on the left rather
      // than the two fighting for one corner.
      await pumpCard(
        tester,
        width: 300,
        card: mod(),
        installedAs: const ['Ellen'],
      );

      final cover = tester.getRect(find.byType(GbThumbnail));
      final pill = tester.getRect(find.byTooltip('In your library as Ellen'));

      expect(pill.right, lessThanOrEqualTo(cover.right));
      expect(pill.top, greaterThanOrEqualTo(cover.top));
      expect(pill.center.dx, greaterThan(cover.center.dx),
          reason: 'top-right, clear of the obsolete badge on the left');
    });

    testWidgets('survives the narrowest tile the grid produces',
        (tester) async {
      // A layout claim either way, and this card has overflowed before.
      await pumpCard(
        tester,
        width: 140,
        card: mod(),
        installedAs: const ['Ellen'],
      );
      expect(tester.takeException(), isNull);
      expect(find.text('In library'), findsOneWidget);
    });

    testWidgets('paints over the reveal overlay rather than under it',
        (tester) async {
      // Whether you already own a mod is not adult content, so it must be readable
      // before the blur is lifted. Driven rather than merely found: the reveal
      // overlay fills the cover, so if the badge were behind it, a tap on the badge
      // would land on the overlay and lift the blur. Being on top means the card
      // stays blurred and the tap falls through to "open this mod" instead.
      var opened = 0;
      await pumpCard(
        tester,
        width: 275,
        card: mod(visibility: GbVisibility.warn),
        treatment: ContentTreatment.blur,
        installedAs: const ['Ellen'],
        onOpen: () => opened++,
      );
      expect(find.text('Click to reveal'), findsOneWidget);
      expect(find.text('In library'), findsOneWidget);

      await tester.tap(find.byTooltip('In your library as Ellen'));
      await tester.pumpAndSettle();

      expect(find.text('Click to reveal'), findsOneWidget,
          reason: 'tapping the badge must not lift the blur');
      expect(opened, 1, reason: 'the tap should reach the card itself');
    });
  });

  group('release and update ages', () {
    testWidgets('shows both, compactly', (tester) async {
      await pumpCard(tester, width: 300, card: mod());
      // 800 days -> "2y" released, 3 days -> "3d" updated.
      expect(find.text('2y'), findsOneWidget);
      expect(find.text('3d'), findsOneWidget);
    });

    testWidgets('each carries the absolute date in a tooltip', (tester) async {
      // A relative age alone loses information; the exact date stays reachable.
      // A fixed date so the expected string is exact. The card renders it in local
      // time, so compare against the same conversion rather than hardcoding a day
      // that shifts with the machine's timezone.
      final added = DateTime.utc(2024, 7, 14, 12);
      final local = added.toLocal();
      final expected = '${local.year}-'
          '${local.month.toString().padLeft(2, '0')}-'
          '${local.day.toString().padLeft(2, '0')}';

      await pumpCard(tester, width: 300, card: mod(added: added));

      expect(find.byTooltip('First released $expected'), findsOneWidget);
      expect(tooltipMessages(tester).any((m) => m.startsWith('Last updated ')),
          isTrue);
    });

    testWidgets('a never-updated mod shows only the release age',
        (tester) async {
      // `_tsDateUpdated` is null when a mod was never updated — a zero timestamp
      // means "never", not 1970.
      await pumpCard(
        tester,
        width: 300,
        card: mod(
          added: DateTime.now().subtract(const Duration(days: 800)),
          neverUpdated: true,
        ),
      );
      expect(find.text('2y'), findsOneWidget);
      final tooltips = tooltipMessages(tester);
      expect(tooltips.any((m) => m.startsWith('First released ')), isTrue);
      expect(tooltips.any((m) => m.startsWith('Last updated ')), isFalse);
    });

    testWidgets('an update date that merely echoes the release is not repeated',
        (tester) async {
      // Some records report the two as identical; showing the same figure twice
      // reads as a rendering bug.
      final same = DateTime.now().subtract(const Duration(days: 400));
      await pumpCard(
        tester,
        width: 300,
        card: mod(added: same, updated: same),
      );
      expect(find.text('1y'), findsOneWidget);
    });

    testWidgets('a mod with no dates at all renders nothing extra',
        (tester) async {
      await pumpCard(tester, width: 300, card: mod(withDates: false));
      expect(tester.takeException(), isNull);
      expect(find.byIcon(Icons.schedule), findsNothing);
      expect(find.byIcon(Icons.autorenew), findsNothing);
    });

    testWidgets('the extra line does not overflow any card width',
        (tester) async {
      // The dates add a fourth line to the text block, which eats into the cover's
      // share of a fixed-height tile. This is the assertion that the block still
      // fits.
      for (final width in <double>[140, 180, 233, 275, 320]) {
        await pumpCard(tester, width: width, card: mod());
        expect(tester.takeException(), isNull, reason: 'at ${width}px');
      }
    });
  });

  group('the category badge sits at the bottom-right', () {
    /// The card's inner content edge: 300px wide less the 10px right padding.
    const contentRight = 300.0 - 10.0;

    testWidgets('a short label is flush right, not mid-card', (tester) async {
      // The regression this pins: with a loose `Flexible`, the badge sized to its
      // own text and the slack fell to its right, parking a short badge against the
      // middle of the card instead of its edge.
      await pumpCard(tester, width: 300, card: mod(category: 'UI'));

      final badge = tester.getRect(find.text('UI'));
      final card = tester.getRect(find.byType(GbModCard));

      expect(badge.right, moreOrLessEquals(card.left + contentRight, epsilon: 8),
          reason: 'badge should hug the right content edge');
      // Well past halfway is the cheap check that it is not in the middle.
      expect(badge.left, greaterThan(card.left + card.width * 0.6));
    });

    testWidgets('a long label still ends at the right edge', (tester) async {
      await pumpCard(tester, width: 300, card: mod());
      final badge = tester.getRect(find.text('Alexandrina Sebastiane'));
      final card = tester.getRect(find.byType(GbModCard));
      expect(badge.right, lessThanOrEqualTo(card.left + contentRight + 1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('stats stay on the left', (tester) async {
      await pumpCard(tester, width: 300, card: mod(category: 'UI'));
      final stats = tester.getRect(find.text('298.0k'));
      final card = tester.getRect(find.byType(GbModCard));
      expect(stats.left, lessThan(card.left + card.width * 0.3));
    });
  });
}
