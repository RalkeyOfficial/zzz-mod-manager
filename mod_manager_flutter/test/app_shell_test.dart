import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/services/platform_service.dart';
import 'package:mod_manager_flutter/services/update_check.dart';
import 'package:mod_manager_flutter/screens/components/settings/launch_section.dart';
import 'package:mod_manager_flutter/screens/components/sidebar_nav_item.dart';
import 'package:mod_manager_flutter/screens/components/zenith_switch.dart';
import 'package:mod_manager_flutter/screens/shell/app_sidebar.dart';
import 'package:mod_manager_flutter/screens/shell/launch_game.dart';
import 'package:mod_manager_flutter/screens/shell/status_bar.dart';
import 'package:mod_manager_flutter/utils/detached_starter.dart';
import 'package:mod_manager_flutter/utils/home_relative.dart';
import 'package:mod_manager_flutter/utils/notifications.dart';
import 'package:mod_manager_flutter/utils/process_probe.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';
import 'package:mod_manager_flutter/utils/zzz_characters.dart';
import 'package:path/path.dart' as p;

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
    testWidgets("Characters returns to a mod's page from elsewhere, and closes it from the Library", (tester) async {
      final container = containerWith();
      container.read(openModPageProvider.notifier).state = const ModPageRequest('a');
      container.read(destinationProvider.notifier).state = AppDestination.settings;
      await pumpSidebar(tester, container);

      await tester.tap(find.text('Characters'));
      await tester.pump();
      expect(container.read(openModPageProvider)?.modId, 'a', reason: 'coming back shows the same mod');

      await tester.tap(find.text('Characters'));
      await tester.pump();
      expect(container.read(openModPageProvider), isNull, reason: 'pressed on the Library, it goes back');
    });

    testWidgets("Updates closes a mod's page when pressed on the Library, as Characters does", (tester) async {
      final container = containerWith();
      container.read(openModPageProvider.notifier).state = const ModPageRequest('a');
      container.read(destinationProvider.notifier).state = AppDestination.settings;
      await pumpSidebar(tester, container);

      await tester.tap(find.text('Updates'));
      await tester.pump();
      expect(container.read(destinationProvider), AppDestination.updates);
      expect(container.read(openModPageProvider)?.modId, 'a', reason: 'coming back shows the same mod');

      await tester.tap(find.text('Updates'));
      await tester.pump();
      expect(container.read(openModPageProvider), isNull, reason: 'pressed on the Library, it goes back');
    });

    testWidgets('counts every agent, whether or not it has a mod', (tester) async {
      await pumpSidebar(tester, containerWith());
      // The roster, as the character list shows it. The UI category is not a character.
      expect(find.text('${zzzCharactersData.length}'), findsOneWidget);
    });

    testWidgets('with Hide empty on, counts the agents that have a mod', (tester) async {
      final container = containerWith();
      container.read(hideEmptyCharactersProvider.notifier).state = true;
      await pumpSidebar(tester, container);

      expect(find.descendant(of: find.byType(SidebarNavItem).first, matching: find.text('1')), findsOneWidget);
    });

    testWidgets('with Hide empty on, counts every agent until the first scan returns', (tester) async {
      final container = ProviderContainer(overrides: [libraryProvider.overrideWith(_NeverScanned.new)]);
      addTearDown(container.dispose);
      container.read(hideEmptyCharactersProvider.notifier).state = true;
      await pumpSidebar(tester, container);

      expect(find.text('${zzzCharactersData.length}'), findsOneWidget);
    });

    testWidgets('Updates opens its own page, and leaves the table and the character view alone', (tester) async {
      final container = containerWith();
      container.read(selectedCharacterIdProvider.notifier).state = 'cat_ui';
      container.read(characterPickedByUserProvider.notifier).state = true;
      container.read(destinationProvider.notifier).state = AppDestination.settings;
      container.read(modUpdateChecksProvider.notifier).state = {
        'b': const UpdateCheck(outcome: UpdateOutcome.updateAvailable),
      };
      container.read(allModsFilterProvider.notifier).state = AllModsFilter.favorites;
      container.read(allModsSearchProvider.notifier).state = 'ellen';
      await pumpSidebar(tester, container);
      expect(tester.widget<SidebarNavItem>(find.widgetWithText(SidebarNavItem, 'Updates')).count, 1);

      await tester.tap(find.text('Updates'));
      await tester.pump();

      expect(container.read(destinationProvider), AppDestination.updates);
      expect(container.read(allModsFilterProvider), AllModsFilter.favorites);
      expect(container.read(allModsSearchProvider), 'ellen');
      expect(container.read(selectedCharacterIdProvider), 'cat_ui');
      expect(container.read(characterPickedByUserProvider), isTrue, reason: 'still the row the user clicked');
      expect(container.read(characterListFilterProvider), CharacterListFilter.all);
      expect(container.read(modGridFilterProvider), ModGridFilter.all);
    });

    testWidgets('one Library row is selected: Characters, All mods or Updates', (tester) async {
      final container = containerWith();
      await pumpSidebar(tester, container);
      List<String> selected() => [
            for (final item in tester.widgetList<SidebarNavItem>(find.byType(SidebarNavItem)))
              if (item.selected) item.label,
          ];
      expect(selected(), ['Characters']);

      await tester.tap(find.text('Updates'));
      await tester.pump();
      expect(selected(), ['Updates']);

      await tester.tap(find.text('All mods'));
      await tester.pump();
      expect(selected(), ['All mods']);

      // The table's Updates chip is a filter of the table, not the Updates page.
      container.read(allModsFilterProvider.notifier).state = AllModsFilter.updates;
      await tester.pump();
      expect(selected(), ['All mods']);

      await tester.tap(find.text('Characters'));
      await tester.pump();
      expect(selected(), ['Characters']);
    });

    testWidgets('All mods counts the mods in the library', (tester) async {
      await pumpSidebar(tester, containerWith());
      expect(
        tester.widget<SidebarNavItem>(find.widgetWithText(SidebarNavItem, 'All mods')).count,
        mods.length,
      );
    });

    testWidgets("All mods closes a mod's page when pressed on the Library", (tester) async {
      final container = containerWith();
      container.read(openModPageProvider.notifier).state = const ModPageRequest('a');
      container.read(destinationProvider.notifier).state = AppDestination.characters;
      await pumpSidebar(tester, container);

      await tester.tap(find.text('All mods'));
      await tester.pump();
      expect(container.read(destinationProvider), AppDestination.allMods);
      expect(container.read(openModPageProvider), isNull);
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

  test('a shown path is shortened only when it is inside the home folder', () {
    String short(String path, {String? home = '/home/al'}) => homeRelative(path, home: home, style: p.posix);
    expect(short('/home/al/Games/ZZMI'), '~/Games/ZZMI');
    expect(short('/home/al'), '~');
    expect(short('/home/alice/ZZMI'), '/home/alice/ZZMI');
    expect(short('/games/ZZMI'), '/games/ZZMI');
    expect(short('/home/al/ZZMI', home: null), '/home/al/ZZMI');
    expect(homeRelative(r'c:\users\AL\Games\ZZMI', home: r'C:\Users\al', style: p.windows), r'~\Games\ZZMI');
  });

  group('Launch game', () {
    const beside = '/games/XXMI Launcher/Resources/Bin/XXMI Launcher.exe';

    late ProviderContainer container;
    late _FakePlatform platform;
    late List<(LaunchSetting, String?)> writes;
    late int asked;

    ProviderContainer launchContainer({String? launcherBeside = beside}) {
      final container = ProviderContainer(
        overrides: [libraryOf(mods), xxmiLauncherProvider.overrideWith((ref) async => launcherBeside)],
      );
      addTearDown(container.dispose);
      return container;
    }

    Future<List<String>> launch(
      WidgetTester tester, {
      LaunchResult result = const LaunchResult(LaunchOutcome.started),
      String? launcherBeside = beside,
      String? picked,
      String target = '',
      String? arguments,
      bool umu = false,
    }) async {
      container = launchContainer(launcherBeside: launcherBeside);
      container.read(launchTargetProvider.notifier).state = target;
      container.read(wineUseUmuProvider.notifier).state = umu;
      if (arguments != null) container.read(launchArgumentsProvider.notifier).state = arguments;
      platform = _FakePlatform(result);
      writes = [];
      asked = 0;
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
      await launchGame(
        context,
        ref,
        platform: platform,
        picker: (_, _) async {
          asked++;
          return picked;
        },
        writer: (setting, value) async => writes.add((setting, value)),
      );
      return [for (final n in container.read(notificationsProvider)) n.title];
    }

    testWidgets('starts the XXMI Launcher beside ZZMI with the default arguments, and says nothing', (tester) async {
      expect(await launch(tester), isEmpty);
      expect(platform.requests.single.executable, beside);
      expect(platform.requests.single.arguments, '--nogui --xxmi ZZMI');
      expect(asked, 0);
    });

    testWidgets('a chosen file wins over the launcher beside ZZMI', (tester) async {
      await launch(tester, target: '/games/start.sh', arguments: '-x');
      expect(platform.requests.single.executable, '/games/start.sh');
      expect(platform.requests.single.arguments, '-x');
    });

    testWidgets('with no launcher anywhere, it asks for one, saves it and starts it', (tester) async {
      await launch(tester, launcherBeside: null, picked: '/games/XXMI Launcher.exe');
      expect(asked, 1);
      expect(writes, [(LaunchSetting.target, '/games/XXMI Launcher.exe')]);
      expect(platform.requests.single.executable, '/games/XXMI Launcher.exe');
    });

    testWidgets('a cancelled picker starts nothing and says nothing', (tester) async {
      expect(await launch(tester, launcherBeside: null), isEmpty);
      expect(asked, 1);
      expect(writes, isEmpty);
      expect(platform.requests, isEmpty);
    });

    testWidgets('a file this platform cannot start says what to choose instead', (tester) async {
      expect(await launch(tester, result: const LaunchResult(LaunchOutcome.unsupported)), ["Can't start this file"]);
    });

    testWidgets('a launcher that is gone says so', (tester) async {
      expect(await launch(tester, result: const LaunchResult(LaunchOutcome.notFound)), ['The game launcher is gone']);
    });

    testWidgets('a missing Wine or Proton names the program it tried', (tester) async {
      final titles = await launch(tester, result: const LaunchResult(LaunchOutcome.runnerMissing, program: 'umu-run'));
      expect(titles, ["Couldn't run Wine or Proton"]);
      expect(container.read(notificationsProvider).single.body, 'umu-run');
    });

    testWidgets('Proton started directly with no prefix says where to choose one', (tester) async {
      expect(await launch(tester, result: const LaunchResult(LaunchOutcome.prefixRequired)), ['Proton needs a Wine prefix']);
    });

    testWidgets("a container that can't look up names warns, and the warning stays until closed", (tester) async {
      final result = LaunchResult(LaunchOutcome.started, containerDns: Future.value(false));
      expect(await launch(tester, result: result), ["DNS doesn't work inside umu-launcher"]);

      final warning = container.read(notificationsProvider).single;
      expect(warning.severity, NotificationSeverity.warning);
      expect(warning.body, contains('turn off umu-launcher in Settings'));
      expect(warning.duration, isNull);
    });

    testWidgets('a lookup that works, or one with no verdict, says nothing', (tester) async {
      for (final verdict in [true, null]) {
        final result = LaunchResult(LaunchOutcome.started, containerDns: Future.value(verdict));
        expect(await launch(tester, result: result), isEmpty, reason: '$verdict');
      }
    });

    testWidgets('the umu-launcher setting reaches the launch', (tester) async {
      await launch(tester, umu: true);
      expect(platform.requests.single.useUmu, isTrue);
    });
  });

  group('Settings › Launch game with', () {
    const dwproton = WineRunner(
      path: '/home/al/.local/share/Steam/compatibilitytools.d/dwproton-11.0-5/proton',
      name: 'dwproton-11.0-5',
      kind: WineRunnerKind.proton,
      source: WineRunnerSource.steam,
    );
    const runners = [
      WineRunner(
        path: '/home/al/.local/share/Steam/compatibilitytools.d/GE-Proton10-34/proton',
        name: 'GE-Proton10-34',
        kind: WineRunnerKind.proton,
        source: WineRunnerSource.steam,
      ),
      dwproton,
    ];

    late ProviderContainer container;
    late List<(LaunchSetting, String?)> writes;
    late List<bool> umuWrites;

    Future<void> pumpSection(
      WidgetTester tester, {
      bool throughWine = true,
      String? launcherBeside = '/home/al/XXMI Launcher/Resources/Bin/XXMI Launcher.exe',
      WinePrefixLayout prefixLayout = WinePrefixLayout.compatData,
      String? picked,
      String runner = '',
      String prefix = '',
      bool useUmu = true,
    }) async {
      container = ProviderContainer(
        overrides: [
          xxmiLauncherProvider.overrideWith((ref) async => launcherBeside),
          winePrefixLayoutProvider.overrideWith((ref) async => prefixLayout),
          wineRunnersProvider.overrideWith((ref) async => runners),
        ],
      );
      addTearDown(container.dispose);
      container.read(wineRunnerProvider.notifier).state = runner;
      container.read(winePrefixProvider.notifier).state = prefix;
      container.read(wineUseUmuProvider.notifier).state = useUmu;
      writes = [];
      umuWrites = [];
      // The writer stands in for ApiService: it records and updates the providers, without touching config.json.
      Future<void> write(LaunchSetting setting, String? value) async {
        writes.add((setting, value));
        switch (setting) {
          case LaunchSetting.target:
            container.read(launchTargetProvider.notifier).state = value ?? '';
          case LaunchSetting.arguments:
            container.read(launchArgumentsProvider.notifier).state = value ?? '--nogui --xxmi ZZMI';
          case LaunchSetting.runner:
            container.read(wineRunnerProvider.notifier).state = value ?? '';
          case LaunchSetting.prefix:
            container.read(winePrefixProvider.notifier).state = value ?? '';
        }
      }

      await pumpLocalized(
        tester,
        SingleChildScrollView(
          child: LaunchSettingsSection(
            platform: _FakePlatform(const LaunchResult(LaunchOutcome.started), throughWine: throughWine),
            picker: (_, _) async => picked,
            writer: write,
            umuWriter: (value) async => umuWrites.add(value),
          ),
        ),
        container: container,
      );
      expectBuilt(LaunchSettingsSection);
      await tester.pump();
    }

    testWidgets('shows the launcher beside ZZMI until another is chosen, and Reset goes back', (tester) async {
      await pumpSection(tester, picked: '/games/start.sh');
      expect(find.text('~/XXMI Launcher/Resources/Bin/XXMI Launcher.exe'), findsOneWidget);
      expect(find.text('Reset'), findsNothing);

      await tester.tap(find.text('Change…').first);
      await tester.pump();
      expect(writes, [(LaunchSetting.target, '/games/start.sh')]);
      expect(find.text('/games/start.sh'), findsOneWidget);

      await tester.tap(find.text('Reset'));
      await tester.pump();
      expect(writes.last, (LaunchSetting.target, null));
      expect(find.text('~/XXMI Launcher/Resources/Bin/XXMI Launcher.exe'), findsOneWidget);
    });

    testWidgets('with no launcher beside ZZMI, it says to choose one', (tester) async {
      await pumpSection(tester, launcherBeside: null);
      expect(find.text('No XXMI Launcher beside the ZZMI folder. Choose it.'), findsOneWidget);
    });

    testWidgets('the arguments take effect as typed, save on Enter, and Reset brings back the default', (tester) async {
      await pumpSection(tester);
      // The arguments row comes before Wine or Proton, whose menu has a text field of its own.
      final field = find.byType(TextField).first;
      expect(tester.widget<TextField>(field).controller!.text, '--nogui --xxmi ZZMI');

      await tester.enterText(field, '--xxmi ZZMI');
      expect(container.read(launchArgumentsProvider), '--xxmi ZZMI');
      expect(writes, isEmpty);

      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(writes, [(LaunchSetting.arguments, '--xxmi ZZMI')]);

      await tester.tap(find.text('Reset'));
      await tester.pump();
      expect(writes.last, (LaunchSetting.arguments, null));
      expect(tester.widget<TextField>(field).controller!.text, '--nogui --xxmi ZZMI');
    });

    testWidgets('Wine or Proton and the prefix are not shown where the launcher runs natively', (tester) async {
      await pumpSection(tester, throughWine: false);
      expect(find.text('Wine or Proton'), findsNothing);
      expect(find.text('Wine prefix'), findsNothing);
    });

    testWidgets('where it runs under Wine, both start at their defaults', (tester) async {
      await pumpSection(tester);
      expect(find.text('Wine or Proton'), findsOneWidget);
      expect(find.text('System Wine (wine)'), findsWidgets);
      expect(find.text("The runner's default prefix"), findsOneWidget);
      // The umu-launcher switch is about Proton only.
      expect(find.text('Run Proton through umu-launcher'), findsNothing);
    });

    testWidgets('Wine or Proton lists the builds by name, and picking one saves its path', (tester) async {
      await pumpSection(tester);
      await tester.tap(find.byType(DropdownMenu<String>));
      await tester.pumpAndSettle();
      expect(find.text('GE-Proton10-34'), findsWidgets);
      expect(find.text('Other file…'), findsWidgets);

      await tester.tap(find.text('dwproton-11.0-5').last);
      await tester.pumpAndSettle();
      expect(writes, [(LaunchSetting.runner, dwproton.path)]);
      expect(find.text('~/.local/share/Steam/compatibilitytools.d/dwproton-11.0-5/proton'), findsOneWidget);
    });

    testWidgets('Other file… asks for a file, and a chosen file the scan missed is still listed', (tester) async {
      await pumpSection(tester, picked: '/opt/My-Proton/proton');
      await tester.tap(find.byType(DropdownMenu<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Other file…').last);
      await tester.pumpAndSettle();
      expect(writes, [(LaunchSetting.runner, '/opt/My-Proton/proton')]);

      await tester.tap(find.byType(DropdownMenu<String>));
      await tester.pumpAndSettle();
      expect(find.text('My-Proton'), findsWidgets);
      expect(find.text('Chosen file'), findsWidgets);
    });

    testWidgets('a prefix without drive_c is shown with a warning', (tester) async {
      await pumpSection(tester, prefixLayout: WinePrefixLayout.missing, prefix: '/home/al/Prefixes/empty');
      expect(find.text('~/Prefixes/empty'), findsOneWidget);
      expect(find.text("This folder doesn't look like a Wine prefix: it has no drive_c."), findsOneWidget);
    });

    testWidgets('for a Proton runner, the umu-launcher switch starts on and saves when turned off', (tester) async {
      final fresh = ProviderContainer();
      addTearDown(fresh.dispose);
      expect(fresh.read(wineUseUmuProvider), isTrue, reason: 'umu-launcher is on by default');

      await pumpSection(tester, runner: dwproton.path, prefix: '/home/al/Games/Heroic/Prefixes/HoyoPlay');
      expect(tester.widget<ZenithSwitch>(find.byType(ZenithSwitch)).value, isTrue);

      await tester.tap(find.byType(ZenithSwitch));
      await tester.pump();
      expect(umuWrites, [false]);
      expect(container.read(wineUseUmuProvider), isFalse);
    });

    testWidgets('Proton through umu-launcher needs no prefix', (tester) async {
      await pumpSection(tester, runner: dwproton.path);
      expect(find.text("The runner's default prefix"), findsOneWidget);
    });

    testWidgets('Proton started directly asks for a prefix', (tester) async {
      await pumpSection(tester, runner: dwproton.path, useUmu: false);
      expect(find.text("Proton started directly has no prefix of its own. Choose the game's."), findsOneWidget);
    });

    testWidgets('Proton started directly warns about a prefix it would make a new one inside', (tester) async {
      await pumpSection(
        tester,
        runner: dwproton.path,
        prefix: '/home/al/Prefixes/lutris',
        prefixLayout: WinePrefixLayout.plain,
        useUmu: false,
      );
      expect(find.textContaining('This prefix has no pfx folder'), findsOneWidget);
    });

    const steamPrefix = '/home/al/.local/share/Steam/steamapps/compatdata/1234';
    const protonOnlyWarning =
        'This is a Proton prefix folder, with the prefix in its pfx folder. For Wine, choose that pfx folder.';

    testWidgets('Wine warns about a Proton prefix folder, whose prefix is in its pfx folder', (tester) async {
      await pumpSection(tester, prefix: steamPrefix, prefixLayout: WinePrefixLayout.protonOnly);
      expect(find.text(protonOnlyWarning), findsOneWidget);
    });

    testWidgets('Proton takes a Proton prefix folder without a warning', (tester) async {
      await pumpSection(tester, runner: dwproton.path, prefix: steamPrefix, prefixLayout: WinePrefixLayout.protonOnly);
      expect(find.text(protonOnlyWarning), findsNothing);
    });

    testWidgets('picking the stored file again through Other file… shows its name, not Other file…', (tester) async {
      await pumpSection(tester, runner: '/opt/My-Proton/proton', picked: '/opt/My-Proton/proton');
      await tester.tap(find.byType(DropdownMenu<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Other file…').last);
      await tester.pumpAndSettle();
      final menuField = find.descendant(of: find.byType(DropdownMenu<String>), matching: find.byType(TextField));
      expect(tester.widget<TextField>(menuField).controller!.text, 'My-Proton');
    });

    testWidgets('the default typed back is saved as no value, so it keeps following the default', (tester) async {
      await pumpSection(tester);
      final field = find.byType(TextField).first;
      await tester.enterText(field, '--xxmi ZZMI');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      await tester.enterText(field, '--nogui --xxmi ZZMI');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(writes, [(LaunchSetting.arguments, '--xxmi ZZMI'), (LaunchSetting.arguments, null)]);
      expect(find.text('Reset'), findsNothing);
    });
  });
}

class _FakePlatform implements PlatformService {
  _FakePlatform(this.result, {this.throughWine = true});

  final LaunchResult result;
  final bool throughWine;
  final requests = <LaunchRequest>[];

  @override
  Future<LaunchResult> launchGame(
    LaunchRequest request, {
    DetachedStarter starter = const DetachedStarter(),
    ProcessProbe probe = const ProcessProbe(),
  }) async {
    requests.add(request);
    return result;
  }

  @override
  bool get launchesThroughWine => throughWine;

  @override
  String? get homeDirectoryPath => '/home/al';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A library whose first scan is still running.
class _NeverScanned extends LibraryNotifier {
  @override
  Future<List<ModInfo>> build() => Completer<List<ModInfo>>().future;
}
