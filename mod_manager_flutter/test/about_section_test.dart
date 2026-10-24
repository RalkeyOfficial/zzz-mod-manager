import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/core/button_working.dart';
import 'package:mod_manager_flutter/core/constants.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/screens/components/settings/about_section.dart';
import 'package:mod_manager_flutter/screens/components/zenith_controls.dart' show DottedGround;
import 'package:mod_manager_flutter/screens/components/zenith_switch.dart';
import 'package:mod_manager_flutter/services/app_update_service.dart';
import 'package:mod_manager_flutter/services/http/http_transport.dart';
import 'package:mod_manager_flutter/services/platform_service.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

import 'support/all_mods_harness.dart' show loadTableFonts;
import 'support/fake_http_transport.dart';
import 'support/localized_harness.dart';

/// A platform that opens nothing and records what it was asked to.
class _FakePlatform implements PlatformService {
  _FakePlatform({this.opens = true});

  final bool opens;
  final urls = <String>[];
  final folders = <String>[];

  @override
  String get platformName => 'Linux';

  @override
  String? get homeDirectoryPath => '/home/al';

  @override
  String getAppDataPath() => '/home/al/.local/share/zzz-mod-manager';

  @override
  Future<bool> openUrlInBrowser(String url) async {
    urls.add(url);
    return opens;
  }

  @override
  Future<bool> openFolderInFileManager(String folderPath) async {
    folders.add(folderPath);
    return opens;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Library extends LibraryNotifier {
  _Library(this.mods);

  final List<ModInfo> mods;

  @override
  FutureOr<List<ModInfo>> build() => mods;
}

void main() {
  final latest = File('test/fixtures/github/latest_release.json').readAsStringSync();
  final releasePage = 'https://github.com/RalkeyOfficial/zzz-mod-manager/releases/tag/v2.2.2';

  late FakeHttpTransport transport;
  late _FakePlatform platform;
  late ProviderContainer container;

  setUp(() {
    transport = FakeHttpTransport()..stub(AppUpdateService.latestReleaseUrl, body: latest);
    platform = _FakePlatform();
  });

  Future<void> pumpAbout(
    WidgetTester tester, {
    String current = '2.2.2',
    DateTime Function()? now,
    _FakePlatform? fake,
    Size surfaceSize = const Size(1200, 1600),
    LogSettingWriter? writer,
    DiagnosticsBuilder? diagnostics,
    ClipboardWriter? clipboard,
    int mods = 3,
    bool zzmi = true,
    Locale locale = const Locale('en'),
    Brightness brightness = Brightness.dark,
  }) async {
    container = ProviderContainer(
      overrides: [
        appUpdateServiceProvider.overrideWithValue(
          AppUpdateService(transport: transport, currentVersion: current, now: now),
        ),
        libraryProvider.overrideWith(
          () => _Library([for (var i = 0; i < mods; i++) ModInfo(id: 'm$i', name: 'm$i', characterId: 'ellen', isActive: false)]),
        ),
        zzmiFoundProvider.overrideWith((ref) async => zzmi),
      ],
    );
    addTearDown(container.dispose);
    await pumpLocalized(
      tester,
      SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: AboutSection(
          platform: fake ?? platform,
          writer: writer ?? (_) async {},
          buildDiagnostics: diagnostics,
          writeClipboard: clipboard,
        ),
      ),
      container: container,
      surfaceSize: surfaceSize,
      locale: locale,
      brightness: brightness,
    );
  }

  Future<void> pressCheck(WidgetTester tester, {String label = 'Check for updates'}) async {
    await tester.tap(find.text(label));
    await tester.pump();
    await tester.pumpAndSettle(const Duration(seconds: 1));
  }

  group('the hero', () {
    testWidgets('names the app, its version and its platform', (tester) async {
      await pumpAbout(tester);

      expect(find.text('ZENITH'), findsOneWidget);
      expect(find.text('Mod manager for Zenless Zone Zero'), findsOneWidget);
      expect(find.text('Version ${AppConstants.appVersion} · Linux'), findsOneWidget);
    });

    testWidgets("draws the detailed logo, as the canvas's hero does, not the title bar's mark", (tester) async {
      await pumpAbout(tester);

      final images = tester.widgetList<Image>(find.byType(Image)).map((i) => (i.image as AssetImage).assetName);
      expect(images, contains('assets/brand/logo-detailed.png'));
      expect(images, isNot(contains('assets/brand/logo-mark-on-dark.png')));
    });

    testWidgets('makes no request until Check for updates is pressed', (tester) async {
      await pumpAbout(tester);

      expect(transport.callCount, 0);
      expect(find.textContaining('checked'), findsNothing);
      expect(find.textContaining("Couldn't check"), findsNothing);
    });

    testWidgets('says it is on the latest version, and when it checked', (tester) async {
      await pumpAbout(tester, now: () => DateTime.now().subtract(const Duration(minutes: 10)));

      await pressCheck(tester);

      expect(transport.callCount, 1);
      expect(find.text("You're on the latest version · checked 10 minutes ago"), findsOneWidget);
    });

    testWidgets('names a newer version, and Release notes opens that release', (tester) async {
      await pumpAbout(tester, current: '2.2.1');

      await pressCheck(tester);
      await tester.tap(find.text('Release notes'));
      await tester.pump();

      expect(find.text('Version 2.2.2 is available · checked just now'), findsOneWidget);
      expect(platform.urls, [releasePage]);
    });

    testWidgets('Release notes opens the list of releases before anything was checked', (tester) async {
      await pumpAbout(tester);

      await tester.tap(find.text('Release notes'));
      await tester.pump();

      expect(platform.urls, ['${AppConstants.repositoryUrl}/releases']);
      expect(transport.callCount, 0);
    });

    testWidgets('a check that fails says why in one line, never the exception', (tester) async {
      transport = FakeHttpTransport()..enqueueError(AppUpdateService.latestReleaseUrl, const SocketException('Failed host lookup'));
      await pumpAbout(tester);

      await pressCheck(tester);

      expect(find.text("Couldn't check: no connection to GitHub"), findsOneWidget);
      expect(find.textContaining('SocketException'), findsNothing);
      expect(find.textContaining('Failed host lookup'), findsNothing);
    });

    testWidgets('a pre-release build is not told it is on the latest version', (tester) async {
      await pumpAbout(tester, current: '3.0.0-beta.1');

      await pressCheck(tester);

      expect(
        find.text('Nothing newer than this pre-release is published as a stable release · checked just now'),
        findsOneWidget,
      );
      expect(find.textContaining('latest version'), findsNothing);
    });

    testWidgets('a later failed check replaces an earlier answer, and Release notes goes back to the list', (tester) async {
      transport = FakeHttpTransport()
        ..enqueue(AppUpdateService.latestReleaseUrl, body: latest)
        ..enqueueError(AppUpdateService.latestReleaseUrl, const SocketException('Failed host lookup'));
      await pumpAbout(tester, current: '2.2.1');

      await pressCheck(tester);
      expect(find.text('Version 2.2.2 is available · checked just now'), findsOneWidget);

      await pressCheck(tester);
      expect(find.text('Version 2.2.2 is available · checked just now'), findsNothing);
      expect(find.text("Couldn't check: no connection to GitHub"), findsOneWidget);

      await tester.tap(find.text('Release notes'));
      await tester.pump();
      expect(platform.urls, ['${AppConstants.repositoryUrl}/releases']);
    });

    testWidgets('keeps the answer for the session', (tester) async {
      await pumpAbout(tester);
      await pressCheck(tester);
      expect(container.read(appUpdateResultProvider)?.outcome, AppUpdateOutcome.upToDate);

      // The page is left and opened again over the same container, as the sidebar does.
      await pumpLocalized(
        tester,
        SingleChildScrollView(child: AboutSection(platform: platform, writer: (_) async {})),
        container: container,
        surfaceSize: const Size(1200, 1600),
      );

      expect(find.textContaining("You're on the latest version"), findsOneWidget);
      expect(transport.callCount, 1, reason: 'coming back is not a press');
    });

    testWidgets('the check button shows it is working while the request is out', (tester) async {
      final pending = Completer<void>();
      transport = _SlowTransport(pending.future, latest);
      await pumpAbout(tester);

      await tester.tap(find.text('Check for updates'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(ZenithSpinner), findsOneWidget);

      pending.complete();
      await tester.pumpAndSettle(const Duration(seconds: 1));
      expect(find.byType(ZenithSpinner), findsNothing);
    });
  });

  group('the links', () {
    testWidgets('Source code opens the repository, Report a problem a new issue, License the repository', (tester) async {
      await pumpAbout(tester);

      for (final title in ['Source code', 'Report a problem', 'License']) {
        await tester.tap(find.text(title));
        await tester.pump();
      }

      expect(platform.urls, [
        AppConstants.repositoryUrl,
        '${AppConstants.repositoryUrl}/issues/new',
        AppConstants.repositoryUrl,
      ]);
      expect(find.text('MIT'), findsOneWidget);
    });

    testWidgets('a link that does not open says so, with the address', (tester) async {
      final stuck = _FakePlatform(opens: false);
      await pumpAbout(tester, fake: stuck);

      await tester.tap(find.text('Source code'));
      await tester.pumpAndSettle();

      expect(find.text("Couldn't open the link"), findsOneWidget);
      expect(find.text(AppConstants.repositoryUrl), findsOneWidget);
    });

    testWidgets('stack when the page is narrow, and sit in a row when it is wide', (tester) async {
      await pumpAbout(tester, surfaceSize: const Size(420, 1800));
      final narrow = [for (final t in ['Source code', 'Report a problem', 'License']) tester.getTopLeft(find.text(t))];
      expect(narrow[0].dx, narrow[1].dx);
      expect(narrow[1].dx, narrow[2].dx);
      expect(narrow[0].dy, lessThan(narrow[1].dy));
      expect(tester.takeException(), isNull);

      await pumpAbout(tester, surfaceSize: const Size(1200, 1600));
      final wide = [for (final t in ['Source code', 'Report a problem', 'License']) tester.getTopLeft(find.text(t))];
      expect(wide[0].dy, wide[1].dy);
      expect(wide[0].dx, lessThan(wide[1].dx));
    });
  });

  group('for bug reports', () {
    testWidgets('App data shows its path from home, and Open opens it', (tester) async {
      await pumpAbout(tester);

      expect(find.text('~/.local/share/zzz-mod-manager'), findsOneWidget);

      await tester.tap(find.text('Open'));
      await tester.pump();

      expect(platform.folders, ['/home/al/.local/share/zzz-mod-manager']);
    });

    testWidgets('a folder that does not open says so, and which', (tester) async {
      await pumpAbout(tester, fake: _FakePlatform(opens: false));

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(find.text("Couldn't open the folder"), findsOneWidget);
      expect(
        find.text("~/.local/share/zzz-mod-manager — the folder is gone, or the file manager didn't start."),
        findsOneWidget,
      );
      expect(find.textContaining('nothing has been written'), findsNothing);
    });

    testWidgets('Logs says how many runs are kept, and opens the folder rather than a file', (tester) async {
      await pumpAbout(tester);

      expect(find.text('The last 7 runs are kept. Attach the newest file to a bug report.'), findsOneWidget);

      await tester.tap(find.text('Open log folder'));
      await tester.pump();

      expect(platform.folders.single, endsWith('logs'));
    });

    testWidgets('a log folder that does not open says which folder, and the two likely reasons', (tester) async {
      await pumpAbout(tester, fake: _FakePlatform(opens: false));

      await tester.tap(find.text('Open log folder'));
      await tester.pumpAndSettle();

      expect(find.text("Couldn't open the folder"), findsOneWidget);
      expect(
        find.textContaining("logs — nothing has been written there yet, or the file manager didn't start."),
        findsOneWidget,
      );
    });

    testWidgets('the log switch says what is in the file, is on to begin with, and writes the setting', (tester) async {
      bool? written;
      await pumpAbout(tester, writer: (value) async => written = value);

      expect(find.text('Write a log file'), findsOneWidget);
      expect(find.textContaining('username is removed'), findsOneWidget);
      expect(tester.widget<ZenithSwitch>(find.byType(ZenithSwitch)).value, isTrue);

      await tester.tap(find.byType(ZenithSwitch));
      await tester.pumpAndSettle();

      expect(container.read(fileLoggingProvider), isFalse);
      expect(written, isFalse);
    });

    testWidgets('System info summarises the version, platform, ZZMI and the mods', (tester) async {
      await pumpAbout(tester, mods: 61);

      expect(find.text('${AppConstants.appVersion} · Linux · ZZMI found · 61 mods'), findsOneWidget);
    });

    testWidgets('System info says when ZZMI is missing, and counts one mod in the singular', (tester) async {
      await pumpAbout(tester, mods: 1, zzmi: false);

      expect(find.text('${AppConstants.appVersion} · Linux · ZZMI not found · 1 mod'), findsOneWidget);
    });

    testWidgets('Copy puts the full diagnostics on the clipboard and says so', (tester) async {
      String? copied;
      await pumpAbout(tester, diagnostics: () => 'the diagnostics', clipboard: (text) async => copied = text);

      await tester.tap(find.text('Copy'));
      await tester.pumpAndSettle();

      expect(copied, 'the diagnostics');
      expect(find.text('Copied'), findsOneWidget);
    });
  });

  testWidgets('ends with who made it and whose it is not', (tester) async {
    await pumpAbout(tester);

    expect(
      find.text(
        'Made by RalkeyOfficial. Not affiliated with HoYoverse or GameBanana. '
        'Zenless Zone Zero and its characters belong to HoYoverse; mods belong to their authors.',
      ),
      findsOneWidget,
    );
  });

  for (final width in [1200.0, 480.0]) {
    testWidgets('lays out in the Settings page\'s unbounded-height scroll view at ${width.toInt()}px', (tester) async {
      container = ProviderContainer(overrides: [libraryProvider.overrideWith(() => _Library(const []))]);
      addTearDown(container.dispose);
      await pumpLocalized(
        tester,
        SingleChildScrollView(
          child: Align(
            alignment: Alignment.topLeft,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 860),
              child: Padding(padding: const EdgeInsets.all(32), child: AboutSection(platform: platform)),
            ),
          ),
        ),
        container: container,
        surfaceSize: Size(width, 900),
      );

      expectBuilt(AboutSection);
      expect(tester.takeException(), isNull);
      expect(find.text('Source code'), findsOneWidget);
    });
  }

  for (final brightness in Brightness.values) {
    testWidgets('the hero and the link cards show their border in the ${brightness.name} theme', (tester) async {
      await pumpAbout(tester, brightness: brightness);

      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byType(RepaintBoundary).first);
      final image = (await tester.runAsync(() => boundary.toImage()))!;
      final bytes = (await tester.runAsync(() => image.toByteData()))!;
      int pixel(int x, int y) => bytes.getUint32((y * image.width + x) * 4);

      // The hero's border is the 1px ring just outside its ground, which must be inset by it, not painted over it.
      final ground = tester.getRect(find.byType(DottedGround));
      final heroY = ground.center.dy.floor();
      final outside = pixel(ground.left.floor() - 6, heroY);
      final border = pixel(ground.left.floor() - 1, heroY);
      final inside = pixel(ground.left.floor() + 4, heroY);
      expect(border, isNot(outside), reason: 'the hero border is drawn');
      expect(border, isNot(inside), reason: 'the hero border is not covered by its ground');

      // A link card draws its border inside its own rect.
      final card = tester.getRect(find.ancestor(of: find.text('Source code'), matching: find.byType(Material)).first);
      final cardY = card.center.dy.floor();
      expect(pixel(card.left.floor(), cardY), isNot(pixel(card.left.floor() + 6, cardY)));
      expect(pixel(card.left.floor(), cardY), isNot(pixel(card.left.floor() - 6, cardY)));
    });
  }

  testWidgets('draws the same detailed logo in the paper theme', (tester) async {
    await pumpAbout(tester, brightness: Brightness.light);

    final images = tester.widgetList<Image>(find.byType(Image)).map((i) => (i.image as AssetImage).assetName);
    expect(images, contains('assets/brand/logo-detailed.png'));
    expect(images, isNot(contains('assets/brand/logo-mark-on-light.png')));
  });

  for (final brightness in Brightness.values) {
    for (final width in [480.0, 1200.0]) {
      testWidgets('reads in Ukrainian in the ${brightness.name} theme at ${width.toInt()}px without overflow', (tester) async {
        await loadTableFonts(tester);
        await pumpAbout(
          tester,
          current: '3.0.0-beta.1',
          locale: const Locale('uk'),
          brightness: brightness,
          surfaceSize: Size(width, 1600),
        );
        await pressCheck(tester, label: 'Перевірити оновлення');

        expect(find.text('Перевірити оновлення'), findsOneWidget);
        expect(find.textContaining('Новішого стабільного випуску'), findsOneWidget);
        expect(find.text('Відкрити теку журналів'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('fits a 420px-wide page without overflowing', (tester) async {
    await pumpAbout(tester, surfaceSize: const Size(420, 1800));
    await pressCheck(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('Release notes'), findsOneWidget);
  });
}

/// Holds the answer back until [release] completes.
class _SlowTransport extends FakeHttpTransport {
  _SlowTransport(this.release, String body) {
    stub(AppUpdateService.latestReleaseUrl, body: body);
  }

  final Future<void> release;

  @override
  Future<HttpResponse> get(Uri url, {Map<String, String> headers = const {}, Duration timeout = const Duration(seconds: 30)}) async {
    await release;
    return super.get(url, headers: headers, timeout: timeout);
  }
}
