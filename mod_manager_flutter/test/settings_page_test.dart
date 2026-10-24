import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/screens/components/settings/about_section.dart';
import 'package:mod_manager_flutter/screens/components/settings/folders_section.dart';
import 'package:mod_manager_flutter/screens/components/settings/launch_section.dart';
import 'package:mod_manager_flutter/screens/components/settings/mods_section.dart';
import 'package:mod_manager_flutter/screens/components/settings/storage_section.dart';
import 'package:mod_manager_flutter/screens/settings_screen.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

import 'support/all_mods_harness.dart' show loadTableFonts;
import 'support/localized_harness.dart';

/// The Settings page: the list of sections, and how it moves between them.
void main() {
  late ProviderContainer container;

  Future<void> pumpPage(
    WidgetTester tester, {
    SettingsSection section = SettingsSection.folders,
    Size size = const Size(1200, 500),
  }) async {
    // The test font draws every glyph a full em wide, which no row of the page is laid out for.
    await loadTableFonts(tester);
    container = ProviderContainer(
      overrides: [
        xxmiLauncherProvider.overrideWith((ref) async => null),
        winePrefixLayoutProvider.overrideWith((ref) async => WinePrefixLayout.compatData),
        wineRunnersProvider.overrideWith((ref) async => const []),
        umuRunProvider.overrideWith((ref) async => null),
        libraryFreeSpaceProvider.overrideWith((ref) async => null),
      ],
    );
    addTearDown(container.dispose);
    container.read(settingsSectionProvider.notifier).state = section;
    await pumpLocalized(tester, const SettingsScreen(), container: container, surfaceSize: size);
    expectBuilt(SettingsScreen);
  }

  /// The page's own scroll view, not the row of sections that scrolls sideways when the window is narrow.
  final pageScroll = find.byWidgetPredicate((w) => w is Scrollable && w.axis == Axis.vertical);

  double scrolled(WidgetTester tester) => tester.state<ScrollableState>(pageScroll.first).position.pixels;

  testWidgets('lists every section beside the page, and starts on Game & folders', (tester) async {
    await pumpPage(tester);

    for (final label in ['Game & folders', 'Launching', 'Mods', 'GameBanana', 'Storage', 'Appearance', 'About']) {
      expect(find.text(label), findsWidgets, reason: label);
    }
    expect(find.text('Settings'), findsOneWidget);
    expect(find.byType(FoldersSection), findsOneWidget);
    expect(scrolled(tester), 0);
  });

  testWidgets('pressing a section scrolls the page to it', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.text('Mods').first);
    await tester.pumpAndSettle();

    expect(container.read(settingsSectionProvider), SettingsSection.mods);
    expect(scrolled(tester), greaterThan(0));
    expect(find.byType(ModsSection), findsOneWidget);
  });

  testWidgets('a section asked for before the page opens is scrolled to when it does', (tester) async {
    await pumpPage(tester, section: SettingsSection.launching);
    await tester.pumpAndSettle();

    expect(scrolled(tester), greaterThan(0));
    expect(container.read(settingsSectionProvider), SettingsSection.launching);
  });

  testWidgets('the list follows the page as it scrolls', (tester) async {
    await pumpPage(tester);

    tester.state<ScrollableState>(pageScroll.first).position.jumpTo(100000);
    await tester.pumpAndSettle();

    expect(container.read(settingsSectionProvider), SettingsSection.appearance, reason: 'the end of the page');

    tester.state<ScrollableState>(pageScroll.first).position.jumpTo(0);
    await tester.pumpAndSettle();

    expect(container.read(settingsSectionProvider), SettingsSection.folders);
  });

  ScrollPosition position(WidgetTester tester) => tester.state<ScrollableState>(pageScroll.first).position;

  testWidgets('a section scrolled into by hand can be pressed again, after Storage too', (tester) async {
    await pumpPage(tester);

    position(tester).jumpTo(100000);
    await tester.pumpAndSettle();
    expect(container.read(settingsSectionProvider), SettingsSection.appearance);

    await tester.tap(find.text('Storage').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Appearance').first);
    await tester.pumpAndSettle();

    expect(find.byType(FoldersSection), findsOneWidget);
    expect(scrolled(tester), greaterThan(0), reason: 'the page scrolls to Appearance rather than staying at the top');
    expect(container.read(settingsSectionProvider), SettingsSection.appearance);
  });

  testWidgets('pressing the section the page last scrolled into scrolls back to it', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.text('Mods').first);
    await tester.pumpAndSettle();
    final atMods = scrolled(tester);

    await tester.tap(find.text('Launching').first);
    await tester.pumpAndSettle();
    expect(scrolled(tester), lessThan(atMods));

    await tester.tap(find.text('Mods').first);
    await tester.pumpAndSettle();
    expect(scrolled(tester), closeTo(atMods, 1));
  });

  testWidgets('pressing the section in view scrolls to its top again', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.text('Mods').first);
    await tester.pumpAndSettle();
    final atMods = scrolled(tester);

    position(tester).jumpTo(atMods + 120);
    await tester.pumpAndSettle();
    expect(container.read(settingsSectionProvider), SettingsSection.mods);

    await tester.tap(find.text('Mods').first);
    await tester.pumpAndSettle();
    expect(scrolled(tester), closeTo(atMods, 1));
  });

  testWidgets('two quick presses end on the second section, with the list following only it', (tester) async {
    await pumpPage(tester);
    final seen = <SettingsSection>[];
    container.listen(settingsSectionProvider, (_, next) => seen.add(next));

    await tester.tap(find.text('Mods').first);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('Appearance').first);
    await tester.pumpAndSettle();

    expect(seen, [SettingsSection.mods, SettingsSection.appearance]);
    expect(container.read(settingsSectionProvider), SettingsSection.appearance);
  });

  testWidgets('resizing across the narrow breakpoint keeps the page where it was', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.text('Mods').first);
    await tester.pumpAndSettle();
    final before = scrolled(tester);
    expect(before, greaterThan(0));

    await tester.binding.setSurfaceSize(const Size(700, 500));
    await tester.pumpAndSettle();

    expect(scrolled(tester), closeTo(before, 1));
    expect(container.read(settingsSectionProvider), SettingsSection.mods);
  });

  testWidgets('Storage and About replace the page, and any other section brings it back', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.text('Storage').first);
    await tester.pumpAndSettle();
    expect(find.byType(StorageSection), findsOneWidget);
    expect(find.byType(FoldersSection), findsNothing);

    await tester.tap(find.text('About').first);
    await tester.pumpAndSettle();
    expect(find.byType(AboutSection), findsOneWidget);
    expect(find.byType(StorageSection), findsNothing);

    await tester.tap(find.text('Mods').first);
    await tester.pumpAndSettle();
    expect(find.byType(FoldersSection), findsOneWidget);
    expect(find.byType(AboutSection), findsNothing);
    expect(scrolled(tester), greaterThan(0), reason: 'the page scrolls to the section asked for');
  });

  testWidgets("the page ends with the Zenith card, drawn with the app icon as the canvas's is", (tester) async {
    await pumpPage(tester);

    final images = tester.widgetList<Image>(find.byType(Image)).map((i) => (i.image as AssetImage).assetName);
    expect(images, contains('assets/brand/logo-app-icon.png'));
    expect(images, isNot(contains('assets/brand/logo-mark-on-dark.png')));
    expect(find.text('Source code'), findsOneWidget);
    expect(find.text('Report a problem'), findsOneWidget);
  });

  testWidgets('a narrow window puts the list above the page without overflowing', (tester) async {
    await pumpPage(tester, size: const Size(600, 700));

    expect(find.text('Game & folders'), findsWidgets);
    expect(tester.takeException(), isNull);

    // The row of sections scrolls sideways, and Appearance is past the edge at this width.
    await tester.ensureVisible(find.text('Appearance').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Appearance').first);
    await tester.pumpAndSettle();
    expect(container.read(settingsSectionProvider), SettingsSection.appearance);
    expect(tester.takeException(), isNull);
  });
}
