import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_category.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_enums.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_mod.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_submitter.dart';
import 'package:mod_manager_flutter/screens/components/marketplace/gb_mod_card.dart';
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
    );
  }

  /// The grid's `mainAxisExtent`. Kept in sync with `gb_browse_view.dart`.
  const gridTileHeight = 240.0;

  Future<void> pumpCard(
    WidgetTester tester, {
    required double width,
    required GbMod card,
    double height = gridTileHeight,
    ContentTreatment treatment = ContentTreatment.show,
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
            onOpen: () {},
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
}
