import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/services/platform_service.dart';
import 'package:mod_manager_flutter/screens/components/settings/launch_section.dart';
import 'package:mod_manager_flutter/screens/shell/app_sidebar.dart';
import 'package:mod_manager_flutter/screens/shell/launch_game.dart';
import 'package:mod_manager_flutter/screens/shell/status_bar.dart';
import 'package:mod_manager_flutter/utils/notifications.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

import 'support/library_override.dart';
import 'support/localized_harness.dart';

/// The sidebar, the status bar and Launch game, from the side the user sees.
void main() {
  final mods = [
    ModInfo(id: 'a', name: 'Winter Maid', characterId: 'ellen', isActive: true),
    ModInfo(id: 'b', name: 'Beach Day', characterId: 'ellen', isActive: true),
    ModInfo(id: 'c', name: 'Clean HUD', characterId: 'cat_ui', isActive: false),
  ];

  ProviderContainer containerWith({bool zzmiFound = false, String zzmiPath = ''}) {
    final container = ProviderContainer(
      overrides: [
        libraryOf(mods),
        zzmiFoundProvider.overrideWith((ref) async => zzmiFound),
      ],
    );
    container.read(zzmiPathProvider.notifier).state = zzmiPath;
    addTearDown(container.dispose);
    return container;
  }

  Future<void> pumpSidebar(WidgetTester tester, ProviderContainer container) async {
    await pumpLocalized(
      tester,
      const Align(alignment: Alignment.topLeft, child: SizedBox(height: 760, child: AppSidebar())),
      container: container,
    );
    expectBuilt(AppSidebar);
  }

  group('sidebar', () {
    testWidgets('counts the characters that have a mod', (tester) async {
      await pumpSidebar(tester, containerWith());
      // Ellen, once for her two mods. The UI category is not a character.
      expect(find.text('1'), findsOneWidget);
    });

    testWidgets('Updates shows every mod, filtered to the ones with an update', (tester) async {
      final container = containerWith();
      container.read(selectedCharacterIndexProvider.notifier).state = 4;
      container.read(destinationProvider.notifier).state = AppDestination.settings;
      await pumpSidebar(tester, container);

      await tester.tap(find.text('Updates'));
      await tester.pump();

      expect(container.read(destinationProvider), AppDestination.characters);
      expect(container.read(selectedCharacterIndexProvider), 0);
      expect(container.read(modUpdatesOnlyProvider), isTrue);

      // Characters is a way back out of that filter.
      await tester.tap(find.text('Characters'));
      await tester.pump();
      expect(container.read(modUpdatesOnlyProvider), isFalse);
    });

    testWidgets('Browse and Settings switch the page', (tester) async {
      final container = containerWith();
      await pumpSidebar(tester, container);

      await tester.tap(find.text('Browse'));
      await tester.pump();
      expect(container.read(destinationProvider), AppDestination.browse);

      await tester.tap(find.text('Settings'));
      await tester.pump();
      expect(container.read(destinationProvider), AppDestination.settings);
    });

    testWidgets('scrolls rather than overflowing in a window shorter than it', (tester) async {
      // The minimum window leaves the sidebar about 430px, less than its rows and the ZZMI card need.
      await pumpLocalized(
        tester,
        const Align(alignment: Alignment.topLeft, child: SizedBox(height: 360, child: AppSidebar())),
        container: containerWith(zzmiFound: true, zzmiPath: '/games/ZZMI'),
      );
      expectBuilt(AppSidebar);
      expect(tester.takeException(), isNull);

      await tester.drag(find.text('Browse'), const Offset(0, -400));
      await tester.pump();
      expect(find.text('Settings').hitTestable(), findsOneWidget);
    });

    testWidgets('says when ZZMI is not where Settings points', (tester) async {
      await pumpSidebar(tester, containerWith());

      expect(find.text('ZZMI not found'), findsOneWidget);
      expect(find.text('Set the ZZMI folder in Settings.'), findsOneWidget);
    });

    testWidgets('with ZZMI found, counts the active mods and reminds about F10', (tester) async {
      await pumpSidebar(tester, containerWith(zzmiFound: true, zzmiPath: '/games/ZZMI'));

      expect(find.text('ZZMI connected'), findsOneWidget);
      expect(find.textContaining('2 mods active', findRichText: true), findsOneWidget);
      expect(find.text('F10'), findsOneWidget);
    });
  });

  testWidgets('the status bar names the ZZMI folder and the links in it', (tester) async {
    await pumpLocalized(
      tester,
      const Align(alignment: Alignment.bottomCenter, child: AppStatusBar()),
      container: containerWith(zzmiPath: '/games/ZZMI'),
    );
    expectBuilt(AppStatusBar);

    expect(find.text('ZZMI · /games/ZZMI'), findsOneWidget);
    expect(find.text('2 links active'), findsOneWidget);
  });

  group('Launch game', () {
    Future<List<String>> launch(WidgetTester tester, LaunchOutcome outcome) async {
      final container = containerWith();
      container.read(launchTargetProvider.notifier).state = '/games/XXMI Launcher.exe';
      late WidgetRef ref;
      late BuildContext context;
      await pumpLocalized(
        tester,
        Consumer(
          builder: (c, r, _) {
            ref = r;
            context = c;
            return const SizedBox();
          },
        ),
        container: container,
      );
      await launchGame(context, ref, platform: _FakePlatform(outcome));
      return [for (final n in container.read(notificationsProvider)) n.title];
    }

    testWidgets('a game that starts is its own feedback', (tester) async {
      expect(await launch(tester, LaunchOutcome.started), isEmpty);
    });

    testWidgets('a file this platform cannot start says what to choose instead', (tester) async {
      expect(await launch(tester, LaunchOutcome.unsupported), ["Can't start this file"]);
    });

    testWidgets('a launcher that is gone says so', (tester) async {
      expect(await launch(tester, LaunchOutcome.notFound), ['The game launcher is gone']);
    });
  });

  testWidgets('Settings shows the chosen launch target and changes it', (tester) async {
    final container = containerWith();
    var asked = 0;
    await pumpLocalized(
      tester,
      LaunchSettingsSection(
        chooser: (_) async {
          asked++;
          container.read(launchTargetProvider.notifier).state = '/games/xxmi.desktop';
          return '/games/xxmi.desktop';
        },
      ),
      container: container,
    );
    expectBuilt(LaunchSettingsSection);
    expect(find.textContaining('What the Launch game button starts'), findsOneWidget);

    await tester.tap(find.text('Choose…'));
    await tester.pump();

    expect(asked, 1);
    expect(find.text('/games/xxmi.desktop'), findsOneWidget);
  });
}

class _FakePlatform implements PlatformService {
  _FakePlatform(this.outcome);

  final LaunchOutcome outcome;

  @override
  Future<LaunchOutcome> launchGame(String target) async => outcome;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
