import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/screens/components/sidebar_nav_item.dart';

import 'support/localized_harness.dart';

void main() {
  Future<void> pumpItem(
    WidgetTester tester, {
    int? count,
    bool hot = false,
    bool selected = false,
    VoidCallback? onTap,
  }) async {
    await pumpLocalized(
      tester,
      Center(
        child: SizedBox(
          width: 196,
          child: SidebarNavItem(
            icon: Icons.grid_view_rounded,
            label: 'Characters',
            count: count,
            hot: hot,
            selected: selected,
            onTap: onTap ?? () {},
          ),
        ),
      ),
    );
    expectBuilt(SidebarNavItem);
  }

  testWidgets('shows its label and count, and no count when there is none', (tester) async {
    await pumpItem(tester, count: 48);
    expect(find.text('Characters'), findsOneWidget);
    expect(find.text('48'), findsOneWidget);

    await pumpItem(tester);
    expect(find.text('48'), findsNothing);
  });

  testWidgets('a press reaches its handler', (tester) async {
    var pressed = 0;
    await pumpItem(tester, onTap: () => pressed++);

    await tester.tap(find.text('Characters'));
    expect(pressed, 1);
  });

  testWidgets('the current row says so to a screen reader', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpItem(tester, selected: true);

    expect(
      tester.getSemantics(find.byType(SidebarNavItem)),
      matchesSemantics(
        label: 'Characters',
        isButton: true,
        isSelected: true,
        hasSelectedState: true,
        hasTapAction: true,
      ),
    );
    handle.dispose();
  });

  testWidgets('a long label truncates rather than overflowing the sidebar', (tester) async {
    await pumpLocalized(
      tester,
      Center(
        child: SizedBox(
          width: 196,
          child: SidebarNavItem(
            icon: Icons.grid_view_rounded,
            label: 'A label far longer than the sidebar has room for',
            count: 3,
            hot: true,
            onTap: () {},
          ),
        ),
      ),
    );
    expectBuilt(SidebarNavItem);
    expect(tester.takeException(), isNull);
  });
}
