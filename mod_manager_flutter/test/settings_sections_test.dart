import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/screens/components/settings/diagnostics_section.dart';
import 'package:mod_manager_flutter/screens/components/settings/marketplace_section.dart';
import 'package:mod_manager_flutter/screens/components/settings/updates_section.dart';
import 'package:mod_manager_flutter/services/gamebanana/content_filter.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

import 'support/localized_harness.dart';

/// The two settings the Settings tab gained, from the side that writes.
///
/// Both go through an injected writer rather than `ApiService`, which lazily
/// builds a `ConfigService` against the developer's **real**
/// `<appData>/config.json` — a test that merely mounted these would rewrite
/// their library paths. The seam is what makes the tab testable at all; it had
/// no widget tests before these.
Future<void> _noopBool(bool _) async {}
Future<void> _noopMode(ContentFilterMode _) async {}

void main() {
  late ProviderContainer container;

  setUp(() {
    container = ProviderContainer();
    addTearDown(container.dispose);
  });

  group('updates', () {
    testWidgets('says what it does, and says it does not install anything',
        (tester) async {
      // The wording is the safety property here. A switch a user could read as
      // consenting to automatic installs would promise something this app
      // deliberately does not do.
      await pumpLocalized(
        tester,
        UpdatesSettingsSection(writer: (_) async {}),
        container: container,
      );
      expectBuilt(UpdatesSettingsSection);

      expect(
        find.text('Check for updates when the app starts'),
        findsOneWidget,
      );
      expect(
        find.textContaining('updates are always applied by you'),
        findsOneWidget,
      );
    });

    testWidgets('starts off, and turning it on writes through', (tester) async {
      bool? written;
      await pumpLocalized(
        tester,
        UpdatesSettingsSection(writer: (value) async => written = value),
        container: container,
      );

      expect(
        tester.widget<Switch>(find.byType(Switch)).value,
        isFalse,
        reason: 'no launch contacts the network unless the user asked',
      );

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      // Both halves: the provider so the check reads it this session, and the
      // write so it survives a restart. Either one alone is a setting that
      // looks like it worked.
      expect(container.read(updateCheckOnLaunchProvider), isTrue);
      expect(written, isTrue);
    });

    testWidgets('reflects a value hydrated from config', (tester) async {
      container.read(updateCheckOnLaunchProvider.notifier).state = true;
      await pumpLocalized(
        tester,
        UpdatesSettingsSection(writer: (_) async {}),
        container: container,
      );

      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    });
  });

  testWidgets('both rows survive a minimum-width window', (tester) async {
    // The two overflow bugs this app has had were both a row with a fixed-size
    // control and text beside it, found at 480px. A description makes that
    // shape more likely, not less, so it is pinned rather than eyeballed.
    await pumpLocalized(
      tester,
      const Column(
        children: [
          UpdatesSettingsSection(writer: _noopBool),
          SizedBox(height: 16),
          MarketplaceSettingsSection(writer: _noopMode),
        ],
      ),
      container: container,
      surfaceSize: const Size(480, 800),
    );
    expectBuilt(UpdatesSettingsSection);
    expectBuilt(MarketplaceSettingsSection);
    expect(tester.takeException(), isNull);
  });

  group('marketplace content filter', () {
    testWidgets('shows the current value by name', (tester) async {
      // A settings list has to name the current value without being hovered,
      // which is what the toolbar's icon menu cannot do.
      await pumpLocalized(
        tester,
        MarketplaceSettingsSection(writer: (_) async {}),
        container: container,
      );
      expectBuilt(MarketplaceSettingsSection);

      expect(find.text('Adult content'), findsOneWidget);
      expect(find.text('Blur'), findsOneWidget);
    });

    testWidgets('changing it writes through and moves the shared provider',
        (tester) async {
      // The toolbar control and this one write the same key and read the same
      // provider, so they cannot disagree — this pins the second half of that.
      ContentFilterMode? written;
      await pumpLocalized(
        tester,
        MarketplaceSettingsSection(writer: (value) async => written = value),
        container: container,
      );

      await tester.tap(find.byType(DropdownButton<ContentFilterMode>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Hide entirely').last);
      await tester.pumpAndSettle();

      expect(container.read(contentFilterProvider), ContentFilterMode.hide);
      expect(written, ContentFilterMode.hide);
    });

    testWidgets('offers every mode', (tester) async {
      await pumpLocalized(
        tester,
        MarketplaceSettingsSection(writer: (_) async {}),
        container: container,
      );

      await tester.tap(find.byType(DropdownButton<ContentFilterMode>));
      await tester.pumpAndSettle();

      for (final label in const [
        'Blur',
        'Show without blur',
        'Hide entirely',
      ]) {
        expect(find.text(label), findsWidgets, reason: '$label is missing');
      }
    });
  });

  group('diagnostics', () {
    testWidgets('says what goes in the file, since you may send it to somebody',
        (tester) async {
      // The wording is the load-bearing part, as with the updates switch. A
      // control that produces a document about the user has to say what the
      // document contains — and, just as importantly, what it does not.
      await pumpLocalized(
        tester,
        DiagnosticsSettingsSection(writer: _noopBool),
        container: container,
      );
      expectBuilt(DiagnosticsSettingsSection);

      expect(find.text('Write a log file'), findsOneWidget);
      expect(find.textContaining('username is removed'), findsOneWidget);
      expect(find.textContaining('last seven runs'), findsOneWidget);
    });

    testWidgets('is on to begin with', (tester) async {
      await pumpLocalized(
        tester,
        DiagnosticsSettingsSection(writer: _noopBool),
        container: container,
      );

      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    });

    testWidgets('turning it off moves the switch and writes the setting',
        (tester) async {
      bool? written;
      await pumpLocalized(
        tester,
        DiagnosticsSettingsSection(writer: (value) async => written = value),
        container: container,
      );

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      expect(container.read(fileLoggingProvider), isFalse);
      expect(written, isFalse);
    });

    testWidgets('opens the folder rather than the file', (tester) async {
      // The user is being sent to pick the run that broke out of the last
      // seven, which means seeing all of them.
      String? opened;
      await pumpLocalized(
        tester,
        DiagnosticsSettingsSection(
          writer: _noopBool,
          openFolder: (path) async {
            opened = path;
            return true;
          },
        ),
        container: container,
      );

      await tester.tap(find.text('Open folder'));
      await tester.pumpAndSettle();

      expect(opened, isNotNull);
      expect(opened, endsWith('logs'));
    });

    testWidgets('a folder that will not open says so', (tester) async {
      await pumpLocalized(
        tester,
        DiagnosticsSettingsSection(
          writer: _noopBool,
          openFolder: (_) async => false,
        ),
        container: container,
      );

      await tester.tap(find.text('Open folder'));
      await tester.pumpAndSettle();

      expect(find.text("Couldn't open the log folder"), findsOneWidget);
    });

    testWidgets('copying puts the diagnostics on the clipboard and says so',
        (tester) async {
      String? copied;
      await pumpLocalized(
        tester,
        DiagnosticsSettingsSection(
          writer: _noopBool,
          buildDiagnostics: () => 'the diagnostics',
          writeClipboard: (text) async => copied = text,
        ),
        container: container,
      );

      await tester.tap(find.text('Copy'));
      await tester.pumpAndSettle();

      expect(copied, 'the diagnostics');
      // This one *does* report success: the clipboard gives no other sign that
      // anything happened, unlike a file manager opening.
      expect(find.text('Copied'), findsOneWidget);
    });
  });
}
