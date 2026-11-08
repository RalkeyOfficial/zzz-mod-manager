import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/core/palette.dart';
import 'package:mod_manager_flutter/screens/components/settings/appearance_section.dart';
import 'package:mod_manager_flutter/screens/components/settings/auto_tag_section.dart';
import 'package:mod_manager_flutter/screens/components/settings/gamebanana_section.dart';
import 'package:mod_manager_flutter/screens/components/settings/mods_section.dart';
import 'package:mod_manager_flutter/screens/components/zenith_controls.dart';
import 'package:mod_manager_flutter/screens/components/zenith_switch.dart';
import 'package:mod_manager_flutter/services/gamebanana/content_filter.dart';
import 'package:mod_manager_flutter/utils/notifications.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

import 'support/all_mods_harness.dart' show loadTableFonts;
import 'support/localized_harness.dart';

/// The preference sections of the Settings page, from the side that writes.
///
/// Each goes through an injected writer rather than `ApiService`, which lazily builds a `ConfigService` against the
/// developer's **real** `<appData>/config.json`: a test that merely pressed a control would rewrite their settings.
Future<Map<String, String>> _tagsNothing() async => const {};

void main() {
  late ProviderContainer container;

  setUp(() {
    container = ProviderContainer();
    addTearDown(container.dispose);
  });

  group('appearance', () {
    testWidgets('offers three themes, and starts on the desktop', (tester) async {
      await pumpLocalized(tester, AppearanceSection(writer: (_) async {}), container: container);
      expectBuilt(AppearanceSection);

      for (final label in ['Dark', 'Light', 'System']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      final segments = tester.widget<ZenithSegments<ThemeMode>>(find.byType(ZenithSegments<ThemeMode>));
      expect(segments.value, ThemeMode.system, reason: 'nobody has chosen yet, so the desktop decides');
    });

    testWidgets('picking one writes through, and the provider moves so the app repaints', (tester) async {
      ThemeMode? written;
      await pumpLocalized(tester, AppearanceSection(writer: (mode) async => written = mode), container: container);

      await tester.tap(find.text('Light'));
      await tester.pumpAndSettle();

      expect(container.read(themeModeProvider), ThemeMode.light);
      expect(container.read(isDarkModeProvider), isFalse);
      expect(written, ThemeMode.light);
    });

    testWidgets('picking an accent writes through', (tester) async {
      AccentChoice? written;
      await pumpLocalized(
        tester,
        AppearanceSection(writer: (_) async {}, accentWriter: (accent) async => written = accent),
        container: container,
      );
      expect(container.read(accentProvider), AccentChoice.violet);

      await tester.tap(find.bySemanticsLabel('Teal'));
      await tester.pumpAndSettle();

      expect(container.read(accentProvider), AccentChoice.teal);
      expect(written, AccentChoice.teal);
    });

    testWidgets('changing the language moves the locale and writes it', (tester) async {
      String? written;
      await pumpLocalized(
        tester,
        AppearanceSection(languageWriter: (code) async => written = code),
        container: container,
      );
      expect(find.text('English'), findsOneWidget);

      await tester.tap(find.text('English'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Українська'));
      await tester.pumpAndSettle();

      expect(container.read(localeProvider), const Locale('uk'));
      expect(written, 'uk');
    });

    testWidgets('a language that could not be saved says so', (tester) async {
      await pumpLocalized(
        tester,
        AppearanceSection(languageWriter: (_) async => throw Exception('disk full')),
        container: container,
      );

      await tester.tap(find.text('English'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Українська'));
      await tester.pumpAndSettle();

      expect(find.text("Couldn't change the language"), findsOneWidget);
    });
  });

  group('mods', () {
    ModsSettingsWriters writers({
      void Function(bool)? oneAtATime,
      void Function(int)? snapshots,
      void Function(bool)? updateCheck,
      void Function(bool)? remind,
    }) => ModsSettingsWriters(
      oneAtATimeDefault: (value) async => oneAtATime?.call(value),
      snapshotsToKeep: (value) async => snapshots?.call(value),
      updateCheckOnLaunch: (value) async => updateCheck?.call(value),
      remindF10: (value) async => remind?.call(value),
    );

    testWidgets('names every setting', (tester) async {
      await pumpLocalized(tester, ModsSection(writers: writers(), autoTagRunner: _tagsNothing), container: container);
      expectBuilt(ModsSection);

      for (final label in [
        'One active mod per character',
        'Snapshots to keep',
        'Check for mod updates',
        'Remind me to press F10',
        'Automatic tagging',
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(find.text('Only mods installed from GameBanana can be checked.'), findsOneWidget);
    });

    testWidgets('starts on the defaults: one active on, three snapshots, check by press, reminder on', (tester) async {
      await pumpLocalized(tester, ModsSection(writers: writers(), autoTagRunner: _tagsNothing), container: container);

      final switches = tester.widgetList<ZenithSwitch>(find.byType(ZenithSwitch)).toList();
      expect(switches.map((s) => s.value), [true, true]);
      expect(container.read(snapshotsToKeepProvider), 3);
      expect(find.text('3'), findsOneWidget);
      expect(find.text('Only when I press Check'), findsOneWidget, reason: 'no launch contacts the network unasked');
    });

    testWidgets('One active mod per character writes through and moves the provider', (tester) async {
      bool? written;
      await pumpLocalized(
        tester,
        ModsSection(writers: writers(oneAtATime: (v) => written = v), autoTagRunner: _tagsNothing),
        container: container,
      );

      await tester.tap(find.byType(ZenithSwitch).first);
      await tester.pumpAndSettle();

      expect(container.read(oneAtATimeDefaultProvider), isFalse);
      expect(written, isFalse);
    });

    testWidgets('the snapshot count steps by one, and stops at both ends', (tester) async {
      final written = <int>[];
      await pumpLocalized(
        tester,
        ModsSection(writers: writers(snapshots: written.add), autoTagRunner: _tagsNothing),
        container: container,
      );

      await tester.tap(find.byTooltip('Keep more'));
      await tester.pumpAndSettle();
      expect(container.read(snapshotsToKeepProvider), 4);

      container.read(snapshotsToKeepProvider.notifier).state = 1;
      await tester.pumpAndSettle();
      expect(tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.remove_rounded)).onPressed, isNull);

      container.read(snapshotsToKeepProvider.notifier).state = 10;
      await tester.pumpAndSettle();
      expect(tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.add_rounded)).onPressed, isNull);
      expect(written, [4]);
    });

    testWidgets('lowering the count says older saved versions will go, and raising it says nothing', (tester) async {
      await pumpLocalized(tester, ModsSection(writers: writers(), autoTagRunner: _tagsNothing), container: container);

      await tester.tap(find.byTooltip('Keep more'));
      await tester.pumpAndSettle();
      expect(container.read(notificationsProvider), isEmpty);

      await tester.tap(find.byTooltip('Keep fewer'));
      await tester.pumpAndSettle();
      expect(find.text('Older saved versions will be cleared'), findsOneWidget);
      expect(find.textContaining('cut down to 3 saved versions'), findsOneWidget);
    });

    testWidgets('the note names the count in the singular at one', (tester) async {
      container.read(snapshotsToKeepProvider.notifier).state = 2;
      await pumpLocalized(tester, ModsSection(writers: writers(), autoTagRunner: _tagsNothing), container: container);

      await tester.tap(find.byTooltip('Keep fewer'));
      await tester.pumpAndSettle();

      expect(find.textContaining('cut down to 1 saved version.'), findsOneWidget);
    });

    testWidgets('the note is in Ukrainian, with the form the count asks for', (tester) async {
      container.read(snapshotsToKeepProvider.notifier).state = 3;
      await pumpLocalized(
        tester,
        ModsSection(writers: writers(), autoTagRunner: _tagsNothing),
        container: container,
        locale: const Locale('uk'),
      );

      await tester.tap(find.byTooltip('Зберігати менше'));
      await tester.pumpAndSettle();

      expect(find.text('Старіші збережені версії буде очищено'), findsOneWidget);
      expect(find.textContaining('залишиться 2 збережені версії'), findsOneWidget);
    });

    testWidgets('the update check is chosen from a menu, and writes through', (tester) async {
      bool? written;
      await pumpLocalized(
        tester,
        ModsSection(writers: writers(updateCheck: (v) => written = v), autoTagRunner: _tagsNothing),
        container: container,
      );

      await tester.tap(find.text('Only when I press Check'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('When the app starts').last);
      await tester.pumpAndSettle();

      expect(container.read(updateCheckOnLaunchProvider), isTrue);
      expect(written, isTrue);
    });

    testWidgets('the F10 reminder writes through', (tester) async {
      bool? written;
      await pumpLocalized(
        tester,
        ModsSection(writers: writers(remind: (v) => written = v), autoTagRunner: _tagsNothing),
        container: container,
      );

      await tester.tap(find.byType(ZenithSwitch).last);
      await tester.pumpAndSettle();

      expect(container.read(remindF10Provider), isFalse);
      expect(written, isFalse);
    });
  });

  group('automatic tagging', () {
    testWidgets('a pass that tagged nothing says so', (tester) async {
      await pumpLocalized(tester, AutoTagRow(runner: _tagsNothing), container: container);

      await tester.tap(find.text('Detect tags for all mods'));
      await tester.pumpAndSettle();

      expect(find.text('Nothing to tag'), findsOneWidget);
    });

    testWidgets('a pass that tagged mods lists them by character', (tester) async {
      await pumpLocalized(
        tester,
        AutoTagRow(runner: () async => const {'Ellen_Summer': 'ellen', 'Miyabi_Kimono': 'miyabi'}),
        container: container,
      );

      await tester.tap(find.text('Detect tags for all mods'));
      await tester.pumpAndSettle();

      expect(find.text('Automatically assigned 2 tags'), findsOneWidget);
      expect(find.textContaining('Ellen_Summer → Ellen'), findsOneWidget);
      expect(find.textContaining('Miyabi_Kimono → Miyabi'), findsOneWidget);
    });

    testWidgets('names three and counts the rest', (tester) async {
      await pumpLocalized(
        tester,
        AutoTagRow(
          runner: () async => const {
            'Ellen_A': 'ellen',
            'Ellen_B': 'ellen',
            'Ellen_C': 'ellen',
            'Ellen_D': 'ellen',
            'Ellen_E': 'ellen',
          },
        ),
        container: container,
      );

      await tester.tap(find.text('Detect tags for all mods'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Ellen_C'), findsOneWidget);
      expect(find.textContaining('Ellen_D'), findsNothing);
      expect(find.textContaining('and 2 more'), findsOneWidget);
    });

    testWidgets('runs the pass once while it is going', (tester) async {
      final pass = Completer<Map<String, String>>();
      var runs = 0;
      await pumpLocalized(
        tester,
        AutoTagRow(runner: () {
          runs++;
          return pass.future;
        }),
        container: container,
        settle: false,
      );

      await tester.tap(find.text('Detect tags for all mods'));
      await tester.pump();
      await tester.tap(find.text('Detect tags for all mods'), warnIfMissed: false);
      await tester.pump();

      expect(runs, 1);
      pass.complete(const {});
      await tester.pumpAndSettle();
    });

    testWidgets('a pass that failed offers Copy details, which copies its title and error', (tester) async {
      String? copied;
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await pumpLocalized(tester, AutoTagRow(runner: () async => throw Exception('read-only')), container: container);

      await tester.tap(find.text('Detect tags for all mods'));
      await tester.pumpAndSettle();
      expect(find.text('Auto-tagging failed'), findsOneWidget);
      await tester.tap(find.text('Copy details'));
      await tester.pumpAndSettle();

      expect(copied, 'Auto-tagging failed\nException: read-only');
      await tester.pump(const Duration(seconds: 6));
    });
  });

  group('mature content', () {
    testWidgets('offers every mode as a choice and shows the current one', (tester) async {
      await pumpLocalized(tester, GameBananaSection(writer: (_) async {}), container: container);
      expectBuilt(GameBananaSection);

      expect(find.text('Mature content'), findsOneWidget, reason: 'the row is named like the Browse control');
      for (final label in ['Blur', 'Show without blur', 'Hide entirely']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      final segments = tester.widget<ZenithSegments<ContentFilterMode>>(
        find.byType(ZenithSegments<ContentFilterMode>),
      );
      expect(segments.value, ContentFilterMode.blur);
    });

    testWidgets('changing it writes through and moves the shared provider', (tester) async {
      ContentFilterMode? written;
      await pumpLocalized(
        tester,
        GameBananaSection(writer: (value) async => written = value),
        container: container,
      );

      await tester.tap(find.text('Hide entirely'));
      await tester.pumpAndSettle();

      expect(container.read(contentFilterProvider), ContentFilterMode.hide);
      expect(written, ContentFilterMode.hide);
    });
  });

  testWidgets('the Ukrainian Mature content row fits at every width, stacking when its control needs the room', (
    tester,
  ) async {
    // The real fonts: the test font draws every glyph a full em wide, which no row is laid out for. The segmented
    // control is about 580px in Ukrainian, so the row has to stack at widths where an English one sits side by side.
    await loadTableFonts(tester);
    for (final width in [480.0, 624.0, 650.0, 700.0, 850.0, 900.0, 1100.0]) {
      await pumpLocalized(
        tester,
        SingleChildScrollView(child: GameBananaSection(writer: (_) async {})),
        container: container,
        locale: const Locale('uk'),
        surfaceSize: Size(width, 800),
      );
      expect(tester.takeException(), isNull, reason: 'overflow at $width px');
      final text = tester.getRect(find.text('Контент для дорослих'));
      final control = tester.getRect(find.byType(ZenithSegments<ContentFilterMode>));
      expect(text.overlaps(control), isFalse, reason: 'the label sits over the control at $width px');
      expect(text.width, greaterThan(100), reason: 'the label is squeezed to a sliver at $width px');
    }
  });

  testWidgets('every section survives a minimum-width window', (tester) async {
    // The two overflow bugs this app has had were a row with a fixed-size control and text beside it, at 480px.
    await pumpLocalized(
      tester,
      SingleChildScrollView(
        child: Column(
          spacing: 16,
          children: [
            AppearanceSection(writer: (_) async {}),
            ModsSection(writers: const ModsSettingsWriters(), autoTagRunner: _tagsNothing),
            GameBananaSection(writer: (_) async {}),
          ],
        ),
      ),
      container: container,
      surfaceSize: const Size(480, 800),
    );
    expectBuilt(AppearanceSection);
    expectBuilt(ModsSection);
    expectBuilt(GameBananaSection);
    expect(tester.takeException(), isNull);
  });
}
