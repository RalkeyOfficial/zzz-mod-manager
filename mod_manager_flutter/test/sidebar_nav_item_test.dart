import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/screens/components/sidebar_nav_item.dart';

import 'support/localized_harness.dart';

/// The sidebar's tab rows, and specifically that they survive the width they
/// are given *while it is changing*.
///
/// The sidebar animates between 80 and 220 over 300ms while the collapsed flag
/// flips in one frame, so every width in between is a real layout that has to
/// work. Laying out from the flag instead threw `RenderFlex overflowed by 28
/// pixels` on every open, and at the first frame the icon alone did not fit.
void main() {
  /// The sidebar's two resting widths, handed to the row whole — it subtracts
  /// its own 16-a-side padding itself.
  const shut = SidebarNavItem.collapsedWidth; // 80
  const open = SidebarNavItem.expandedWidth; // 220

  /// Mounts the row inside the ancestors it actually has.
  ///
  /// **The `IntrinsicHeight` is not scenery.** The sidebar is wrapped in one,
  /// and a first attempt at this fix used a `LayoutBuilder` to read the live
  /// width — which `IntrinsicHeight` cannot ask for a dimension, so it threw on
  /// every frame and the app never finished rendering. This test passed anyway,
  /// because it mounted the row bare. A harness that omits an ancestor is a
  /// harness that cannot see the bugs that ancestor causes.
  Future<void> pumpAt(
    WidgetTester tester,
    double width, {
    String label = 'Marketplace',
    bool? collapsed,
  }) async {
    await tester.pumpWidget(const SizedBox());
    await pumpLocalized(
      tester,
      Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: width,
          child: IntrinsicHeight(
            child: Column(
              children: [
                SidebarNavItem(
                  icon: Icons.store_mall_directory_rounded,
                  label: label,
                  isActive: false,
                  // The flag flips a frame before the width finishes moving, so
                  // the interesting case is "expanded content, collapsed width".
                  collapsed: collapsed ?? width <= SidebarNavItem.collapsedWidth,
                  onTap: () {},
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('no width the animation passes through overflows',
      (tester) async {
    // The reported bug is *expanding*: the flag says "open" a frame before the
    // width agrees, so every one of these widths is laid out with the expanded
    // content. Both resting points were always fine — it is everything in
    // between that broke, which is exactly what an animation visits.
    for (var width = shut; width <= open; width += 4) {
      await pumpAt(tester, width, collapsed: false);
      expect(
        tester.takeException(),
        isNull,
        reason: 'overflowed while expanding, at a sidebar width of $width',
      );
    }
  });

  testWidgets('nor does collapsing, where the flag leads the other way',
      (tester) async {
    for (var width = open; width >= shut; width -= 4) {
      await pumpAt(tester, width, collapsed: true);
      expect(
        tester.takeException(),
        isNull,
        reason: 'overflowed while collapsing, at a sidebar width of $width',
      );
    }
  });

  testWidgets('the label is shown when open and hidden when shut',
      (tester) async {
    await pumpAt(tester, shut);
    expect(find.text('Marketplace'), findsNothing);

    await pumpAt(tester, open);
    expect(find.text('Marketplace'), findsOneWidget);
  });

  testWidgets('the tooltip carries the label exactly when the row cannot',
      (tester) async {
    // Keyed on the same value as the label, so a row can never be both
    // unlabelled and untooltipped.
    String tooltip() => tester.widget<Tooltip>(find.byType(Tooltip)).message!;

    await pumpAt(tester, shut);
    expect(tooltip(), 'Marketplace');

    await pumpAt(tester, open);
    expect(tooltip(), isEmpty);
  });

  testWidgets('a label too long for the sidebar ellipsises', (tester) async {
    // A translation or a longer tab name must degrade, not overflow.
    await pumpAt(
      tester,
      open,
      label: 'Marketplace and everything else besides, at length',
    );
    expect(tester.takeException(), isNull);

    final text = tester.widget<Text>(find.textContaining('Marketplace'));
    expect(text.overflow, TextOverflow.ellipsis);
    expect(text.maxLines, 1);
  });

  testWidgets('the icon fits the narrowest row, which everything rests on',
      (tester) async {
    // The invariant: at the collapsed width the content box is
    // 80 - 32 (outer) - 24 (inner) = 24, and the icon is 22. Widen the padding
    // and this stops being true — which is precisely what the old code did on
    // the first frame of an expand, and no amount of shrinking the label would
    // have saved it.
    await pumpAt(tester, shut, collapsed: false);
    final row = tester.getSize(find.byType(Row).first);
    expect(row.width, greaterThanOrEqualTo(22));
    expect(tester.takeException(), isNull);
  });

  testWidgets('survives a 2x OS text scale at every width', (tester) async {
    // The label doubles in width while the icon and the padding do not, so this
    // is where a version without the ellipsis would break first.
    for (final width in [shut, 150.0, open]) {
      await tester.pumpWidget(const SizedBox());
      await pumpLocalized(
        tester,
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: SidebarNavItem(
                icon: Icons.settings_rounded,
                label: 'Settings',
                isActive: true,
                collapsed: false,
                onTap: () {},
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull, reason: 'at width $width');
    }
  });
}
