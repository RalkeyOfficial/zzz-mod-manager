import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';
import 'dart:io';
import 'core/app_theme.dart';
import 'core/constants.dart';
import 'core/font_licenses.dart';
import 'screens/mods_screen.dart';
import 'screens/components/download_queue_host.dart';
import 'screens/components/launch_update_check_host.dart';
import 'screens/components/library_actions_host.dart';
import 'screens/components/shader_fixes_notices.dart';
import 'screens/components/notification_overlay.dart';
import 'screens/settings_screen.dart';
import 'screens/shell/app_sidebar.dart';
import 'screens/shell/status_bar.dart';
import 'screens/shell/title_bar.dart';
import 'screens/storage_screen.dart';
import 'screens/welcome_screen.dart';
import 'screens/marketplace_screen.dart';
import 'utils/state_providers.dart';
import 'services/api_service.dart';
import 'services/download/download_queue.dart';
import 'services/log/log_setup.dart';
import 'services/log/logger.dart';
import 'services/log/system_probe.dart';
import 'l10n/app_localizations.dart';

void main() async {
  // **Logging first, before the binding and before window_manager.** Nothing
  // here needs Flutter — the app-data path is environment-based and the file
  // opens lazily — and everything after this line can fail. A
  // `windowManager.ensureInitialized()` that throws on a broken display is
  // otherwise a completely silent death.
  final fileLogging = readFileLoggingFromDisk();
  Log.install(buildProductionRouter(fileLogging: fileLogging));

  // The binding must be initialised in the **same zone** that guards `runApp`,
  // or the framework reports a zone mismatch and errors bypass the handler —
  // which is why everything below sits inside, rather than only `runApp`.
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    // After `ensureInitialized`, not before: the binding installs its own
    // `FlutterError.onError` in its constructor.
    installErrorHandlers();
    logStartupHeader(fileLogging: fileLogging);

    await _startUp();

    // Unawaited, and after the UI is on its way up: this spawns processes to
    // ask what is installed, and the first frame must not wait on a
    // diagnostic. See `system_probe.dart`.
    unawaited(logSystemReport());
  }, (error, stack) {
    Log.of('zone').critical('unhandled error', error: error, stack: stack);
  });
}

Future<void> _startUp() async {
  // No webview platform to register any more: the marketplace is a native
  // GameBanana browser on both platforms, which is what removed the last
  // Windows-only initialisation step here.
  await windowManager.ensureInitialized();

  WindowOptions windowOptions = WindowOptions(
    size: Size(
      AppConstants.defaultWindowWidth.toDouble(),
      AppConstants.defaultWindowHeight.toDouble(),
    ),
    minimumSize: Size(
      AppConstants.minWindowWidth.toDouble(),
      AppConstants.minWindowHeight.toDouble(),
    ),
    center: true,
    backgroundColor: Colors.transparent,
    skipTaskbar: false,
    // The app draws its own title bar (`ZenithTitleBar`). On Linux this hides
    // the runner's header bar and keeps the GTK frame that resizes the window;
    // on Windows it drops the caption and keeps the border. See
    // `docs/desktop-integration.md` §4.
    titleBarStyle: TitleBarStyle.hidden,
  );

  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });

  registerFontLicenses();
  runApp(const ProviderScope(child: MyApp()));
}

class MyApp extends ConsumerStatefulWidget {
  const MyApp({super.key});

  @override
  ConsumerState<MyApp> createState() => _MyAppState();
}

class _MyAppState extends ConsumerState<MyApp> with WidgetsBindingObserver {
  bool _isFirstRun = true;
  bool _isLoading = true;
  bool _hasCheckedFirstRun = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// The desktop switched between light and dark.
  ///
  /// Only a `system` theme choice acts on it, and `isDarkModeProvider` is where
  /// that is decided — this reports the desktop's answer and nothing else. The
  /// whole app follows one observer, so a screen never has to hold a
  /// `MediaQuery` to stay in step.
  @override
  void didChangePlatformBrightness() {
    super.didChangePlatformBrightness();
    ref.read(platformBrightnessProvider.notifier).state =
        WidgetsBinding.instance.platformDispatcher.platformBrightness;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_hasCheckedFirstRun) {
      _hasCheckedFirstRun = true;
      _checkFirstRun();
    }
  }

  Future<void> _checkFirstRun() async {
    try {
      await _initialise();
    } catch (error, stack) {
      // Previously this left the spinner turning forever with nothing said
      // anywhere. It still leaves the spinner — recovering is a different
      // question — but the reason is now in the file.
      Log.of('app').critical('startup failed', error: error, stack: stack);
    }
  }

  Future<void> _initialise() async {
    await ApiService.initialize(container: ProviderScope.containerOf(context));
    // At launch, where nothing is queued yet, so every completed archive still
    // sitting in the downloads folder is one whose install never ran. Left
    // there, the next download of the same file promotes to `mod (2).rar` — and
    // that name becomes the mod's. Not awaited: it is housekeeping, and the
    // first run screen must not wait on a directory listing.
    ref.read(downloadServiceProvider).sweepCompletedDownloads();
    final isFirstRun = await ApiService.isFirstRun();
    if (mounted) {
      setState(() {
        _isFirstRun = isFirstRun;
        _isLoading = false;
      });
    }
  }

  void _onWelcomeComplete() async {
    await ApiService.completeFirstRun();
    setState(() {
      _isFirstRun = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDarkMode = ref.watch(isDarkModeProvider);
    final accent = ref.watch(accentProvider);
    final locale = ref.watch(localeProvider);

    return MaterialApp(
      locale: locale,
      supportedLocales: const [Locale('en'), Locale('uk')],
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      onGenerateTitle: (context) => context.loc.t('app.title'),
      // The title bar sits above every page, the first-run screen and the
      // loading spinner included, since nothing else can move the window.
      //
      // Notifications are hosted **above the navigator**, so they are visible
      // over a modal dialog. A large share of them are raised from one (rename,
      // delete, keybinds, the whole update flow), and the `ScaffoldMessenger`
      // bars they replaced were drawn inside the `Scaffold` — behind the
      // barrier, where the user never saw them.
      builder: (context, child) => Column(
        children: [
          const ZenithTitleBar(),
          Expanded(child: NotificationHost(child: child!)),
        ],
      ),
      home: _isLoading
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : (_isFirstRun
                ? WelcomeScreen(onComplete: _onWelcomeComplete)
                : const MainScreen()),
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(
        brightness: isDarkMode ? Brightness.dark : Brightness.light,
        accent: accent,
      ),
    );
  }
}

/// The app once it is set up: the sidebar, the page it picked, and the status bar.
class MainScreen extends ConsumerStatefulWidget {
  const MainScreen({super.key});

  @override
  ConsumerState<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends ConsumerState<MainScreen> with WindowListener {
  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowClose() async {
    // The buffered tail of the log, on its way to disk before the process
    // goes. Without this every clean exit loses its last seconds, which is
    // the half of a session most worth reading. Bounded, because a hung
    // volume must not be able to stop the window closing.
    await Log.shutdown().timeout(
      const Duration(milliseconds: 250),
      onTimeout: () {},
    );
    await windowManager.destroy();
    exit(0);
  }

  @override
  void onWindowEvent(String eventName) {
    if (eventName == 'close') {
      onWindowClose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final destination = ref.watch(destinationProvider);

    // `DownloadQueueHost` wraps the whole screen, and **below** the `Navigator`
    // rather than beside it like `NotificationHost`: it finishes a background
    // download by installing it, which can raise a dialog, and `showDialog`
    // needs a `Navigator` ancestor. Here rather than inside a page because the
    // pages are disposed as the user moves between them — see the host itself.
    // `LaunchUpdateCheckHost` wraps the screen for the same reason, and needs
    // it more: nobody pressed anything to start its pass, so there is no screen
    // it belongs to. It raises no dialog, so its position relative to the
    // `Navigator` does not matter. `LibraryActionsHost` runs the update check
    // the user starts from the Library, which outlives the page it was pressed
    // on and can end in a dialog. `ShaderRestartNoticeHost` is here because
    // placed shader files change from updates and deletes as well as toggles.
    return DownloadQueueHost(
      child: LaunchUpdateCheckHost(
        child: LibraryActionsHost(
          child: ShaderRestartNoticeHost(
            child: Scaffold(
              body: Column(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        const AppSidebar(),
                        Expanded(
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 180),
                            child: switch (destination) {
                              AppDestination.characters => const ModsScreen(key: ValueKey('mods')),
                              AppDestination.browse => const MarketplaceScreen(key: ValueKey('marketplace')),
                              AppDestination.storage => const StorageScreen(key: ValueKey('storage')),
                              AppDestination.settings => const SettingsScreen(key: ValueKey('settings')),
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                  const AppStatusBar(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
