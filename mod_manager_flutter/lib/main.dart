import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_staggered_animations/flutter_staggered_animations.dart';
import 'package:window_manager/window_manager.dart';
import 'dart:io';
import 'core/constants.dart';
import 'screens/mods_screen.dart';
import 'screens/components/download_queue_host.dart';
import 'screens/components/downloads_button.dart';
import 'screens/components/launch_update_check_host.dart';
import 'screens/components/notification_overlay.dart';
import 'screens/components/sidebar_nav_item.dart';
import 'screens/settings_screen.dart';
import 'screens/welcome_screen.dart';
import 'screens/marketplace_screen.dart';
import 'utils/state_providers.dart';
import 'services/api_service.dart';
import 'services/download/download_queue.dart';
import 'l10n/app_localizations.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

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
    titleBarStyle: TitleBarStyle.hidden,
  );

  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });

  runApp(const ProviderScope(child: MyApp()));
}

class MyApp extends ConsumerStatefulWidget {
  const MyApp({super.key});

  @override
  ConsumerState<MyApp> createState() => _MyAppState();
}

class _MyAppState extends ConsumerState<MyApp> {
  bool _isFirstRun = true;
  bool _isLoading = true;
  bool _hasCheckedFirstRun = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_hasCheckedFirstRun) {
      _hasCheckedFirstRun = true;
      _checkFirstRun();
    }
  }

  Future<void> _checkFirstRun() async {
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
      // Notifications are hosted **above the navigator**, so they are visible
      // over a modal dialog. A large share of them are raised from one (rename,
      // delete, keybinds, the whole update flow), and the `ScaffoldMessenger`
      // bars they replaced were drawn inside the `Scaffold` — behind the
      // barrier, where the user never saw them.
      builder: (context, child) => NotificationHost(child: child!),
      home: _isLoading
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : (_isFirstRun
                ? WelcomeScreen(onComplete: _onWelcomeComplete)
                : const MainScreen()),
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0EA5E9),
          brightness: isDarkMode ? Brightness.dark : Brightness.light,
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: isDarkMode
            ? const Color(0xFF0F0F0F)
            : const Color(0xFFF5F5F5),
        cardColor: isDarkMode ? const Color(0xFF1A1A1A) : Colors.white,
        // Покращена кольорова схема
        primarySwatch: MaterialColor(0xFF0EA5E9, <int, Color>{
          50: const Color(0xFFE0F7FA),
          100: const Color(0xFFB3ECF2),
          200: const Color(0xFF80E0EA),
          300: const Color(0xFF4DD4E2),
          400: const Color(0xFF26C9DA),
          500: const Color(0xFF0EA5E9),
          600: const Color(0xFF0C94D1),
          700: const Color(0xFF0A82B9),
          800: const Color(0xFF0870A1),
          900: const Color(0xFF064E89),
        }),
        // Покращені кольори для темної теми
        brightness: isDarkMode ? Brightness.dark : Brightness.light,
        // Покращені кольори для карток
        cardTheme: CardThemeData(
          elevation: isDarkMode ? 8 : 4,
          shadowColor: isDarkMode
              ? Colors.black.withValues(alpha: 0.3)
              : Colors.black.withValues(alpha: 0.1),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        // Покращені кольори для кнопок
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            elevation: 4,
            shadowColor: const Color(0xFF0EA5E9).withValues(alpha: 0.3),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
        // Покращені кольори для полів вводу
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(
              color: isDarkMode
                  ? Colors.white.withValues(alpha: 0.1)
                  : Colors.black.withValues(alpha: 0.1),
            ),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(
              color: isDarkMode
                  ? Colors.white.withValues(alpha: 0.1)
                  : Colors.black.withValues(alpha: 0.1),
            ),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFF0EA5E9), width: 2),
          ),
        ),
      ),
    );
  }
}

class MainScreen extends ConsumerStatefulWidget {
  const MainScreen({super.key});

  @override
  ConsumerState<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends ConsumerState<MainScreen>
    with TickerProviderStateMixin, WindowListener {
  late AnimationController _logoAnimationController;
  late AnimationController _sidebarAnimationController;
  late Animation<double> _logoScaleAnimation;
  late Animation<double> _logoRotationAnimation;
  late Animation<double> _sidebarSlideAnimation;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);

    _logoAnimationController = AnimationController(
      duration: const Duration(milliseconds: 2000),
      vsync: this,
    );
    _sidebarAnimationController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );

    _logoScaleAnimation = Tween<double>(begin: 0.8, end: 1.0).animate(
      CurvedAnimation(
        parent: _logoAnimationController,
        curve: Curves.elasticOut,
      ),
    );

    _logoRotationAnimation = Tween<double>(begin: 0.0, end: 0.1).animate(
      CurvedAnimation(
        parent: _logoAnimationController,
        curve: Curves.easeInOut,
      ),
    );

    _sidebarSlideAnimation = Tween<double>(begin: -1.0, end: 0.0).animate(
      CurvedAnimation(
        parent: _sidebarAnimationController,
        curve: Curves.easeOutCubic,
      ),
    );

    _logoAnimationController.forward();
    _sidebarAnimationController.forward();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _logoAnimationController.dispose();
    _sidebarAnimationController.dispose();
    super.dispose();
  }

  @override
  void onWindowClose() async {
    // Швидко закриваємо без очікування
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
    final currentTab = ref.watch(tabIndexProvider);
    final isDarkMode = ref.watch(isDarkModeProvider);
    final isSidebarCollapsed = ref.watch(sidebarCollapsedProvider);
    final loc = context.loc;

    // `DownloadQueueHost` wraps the whole screen, and **below** the `Navigator`
    // rather than beside it like `NotificationHost`: it finishes a background
    // download by installing it, which can raise a dialog, and `showDialog`
    // needs a `Navigator` ancestor. Here rather than inside a tab because the
    // tabs are disposed as the user moves between them — see the host itself.
    // `LaunchUpdateCheckHost` wraps the screen for the same reason, and needs
    // it more: nobody pressed anything to start its pass, so there is no screen
    // it belongs to. It raises no dialog, so its position relative to the
    // `Navigator` does not matter.
    return DownloadQueueHost(
      child: LaunchUpdateCheckHost(
        child: Scaffold(
      body: Column(
        children: [
          // Custom title bar
          _buildCustomTitleBar(context, isDarkMode),
          // Main content
          Expanded(
            child: Row(
              children: [
                // Sidebar
                SlideTransition(
                  position:
                      Tween<Offset>(
                        begin: const Offset(-1, 0),
                        end: Offset.zero,
                      ).animate(
                        CurvedAnimation(
                          parent: _sidebarAnimationController,
                          curve: Curves.easeOutCubic,
                        ),
                      ),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeInOut,
                    width: isSidebarCollapsed ? 80 : 220,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: isDarkMode
                            ? [const Color(0xFF1A1A1A), const Color(0xFF0F0F0F)]
                            : [Colors.white, const Color(0xFFFAFAFA)],
                      ),
                      border: Border(
                        right: BorderSide(
                          color: isDarkMode
                              ? Colors.white.withValues(alpha: 0.05)
                              : Colors.black.withValues(alpha: 0.03),
                          width: 1,
                        ),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: isDarkMode
                              ? Colors.black.withValues(alpha: 0.3)
                              : Colors.black.withValues(alpha: 0.05),
                          blurRadius: 15,
                          offset: const Offset(2, 0),
                        ),
                      ],
                    ),
                    // Scrollable so the sidebar can't overflow on a very short
                    // window (e.g. the brief first frame before the window is
                    // sized); the footer still pins to the bottom at normal
                    // heights via the min-height + IntrinsicHeight pairing.
                    child: LayoutBuilder(
                      builder: (context, constraints) => SingleChildScrollView(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            minHeight: constraints.maxHeight,
                          ),
                          child: IntrinsicHeight(
                            child: Column(
                              children: [
                        const SizedBox(height: 24),
                        // Toggle button
                        Align(
                          alignment: isSidebarCollapsed
                              ? Alignment.center
                              : Alignment.centerRight,
                          child: Padding(
                            padding: EdgeInsets.only(
                              right: isSidebarCollapsed ? 0 : 16,
                            ),
                            child: IconButton(
                              icon: Icon(
                                isSidebarCollapsed
                                    ? Icons.menu
                                    : Icons.menu_open,
                                color: Colors.grey[600],
                              ),
                              onPressed: () {
                                ref
                                        .read(sidebarCollapsedProvider.notifier)
                                        .state =
                                    !isSidebarCollapsed;
                              },
                              tooltip: isSidebarCollapsed
                                  ? loc.t('navigation.expand')
                                  : loc.t('navigation.collapse'),
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        // Logo/Title with gradient
                        if (!isSidebarCollapsed) ...[
                          AnimatedBuilder(
                            animation: _logoScaleAnimation,
                            builder: (context, child) {
                              return Transform.scale(
                                scale: _logoScaleAnimation.value,
                                child: Transform.rotate(
                                  angle: _logoRotationAnimation.value,
                                  child: Container(
                                    padding: const EdgeInsets.all(16),
                                    decoration: BoxDecoration(
                                      gradient: const LinearGradient(
                                        colors: [
                                          Color(0xFF0EA5E9),
                                          Color(0xFF06B6D4),
                                        ],
                                      ),
                                      borderRadius: BorderRadius.circular(16),
                                      boxShadow: [
                                        BoxShadow(
                                          color: const Color(
                                            0xFF0EA5E9,
                                          ).withValues(alpha: 0.3),
                                          blurRadius: 15,
                                          spreadRadius: 2,
                                        ),
                                      ],
                                    ),
                                    child: const Icon(
                                      Icons.games,
                                      color: Colors.white,
                                      size: 32,
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                          const SizedBox(height: 16),
                          ShaderMask(
                            shaderCallback: (bounds) => const LinearGradient(
                              colors: [Color(0xFF0EA5E9), Color(0xFF06B6D4)],
                            ).createShader(bounds),
                            child: const Text(
                              'ZZZ',
                              style: TextStyle(
                                fontSize: 28,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -1,
                                color: Colors.white,
                              ),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            loc.t('app.brand_subtitle'),
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey[500],
                              fontWeight: FontWeight.w500,
                              letterSpacing: 1,
                            ),
                          ),
                          const SizedBox(height: 40),
                        ] else ...[
                          const SizedBox(height: 20),
                        ],
                        // Navigation
                        AnimationLimiter(
                          child: Column(
                            children: AnimationConfiguration.toStaggeredList(
                              duration: const Duration(milliseconds: 375),
                              childAnimationBuilder: (widget) => SlideAnimation(
                                horizontalOffset: 50.0,
                                child: FadeInAnimation(child: widget),
                              ),
                              children: [
                                SidebarNavItem(
                                  icon: Icons.dashboard_rounded,
                                  label: loc.t('navigation.mods'),
                                  isActive: currentTab == 0,
                                  collapsed: isSidebarCollapsed,
                                  onTap: () => ref
                                      .read(tabIndexProvider.notifier)
                                      .state = 0,
                                ),
                                const SizedBox(height: 8),
                                SidebarNavItem(
                                  icon: Icons.store_mall_directory_rounded,
                                  label: loc.t('navigation.marketplace'),
                                  isActive: currentTab == 1,
                                  collapsed: isSidebarCollapsed,
                                  onTap: () => ref
                                      .read(tabIndexProvider.notifier)
                                      .state = 1,
                                ),
                                const SizedBox(height: 8),
                                SidebarNavItem(
                                  icon: Icons.settings_rounded,
                                  label: loc.t('navigation.settings'),
                                  isActive: currentTab == 2,
                                  collapsed: isSidebarCollapsed,
                                  onTap: () => ref
                                      .read(tabIndexProvider.notifier)
                                      .state = 2,
                                ),
                              ],
                            ),
                          ),
                        ),
                        const Spacer(),
                        // Footer with version badge
                        if (!isSidebarCollapsed)
                          Padding(
                            padding: const EdgeInsets.all(20),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: isDarkMode
                                    ? Colors.white.withValues(alpha: 0.05)
                                    : Colors.black.withValues(alpha: 0.03),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: isDarkMode
                                      ? Colors.white.withValues(alpha: 0.1)
                                      : Colors.black.withValues(alpha: 0.05),
                                ),
                              ),
                              child: Text(
                                'v${AppConstants.appVersion}',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.grey[500],
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ),
                      ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                // Content
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 300),
                    transitionBuilder:
                        (Widget child, Animation<double> animation) {
                          return SlideTransition(
                            position:
                                Tween<Offset>(
                                  begin: const Offset(1.0, 0.0),
                                  end: Offset.zero,
                                ).animate(
                                  CurvedAnimation(
                                    parent: animation,
                                    curve: Curves.easeInOut,
                                  ),
                                ),
                            child: child,
                          );
                        },
                    child: switch (currentTab) {
                      0 => const ModsScreen(key: ValueKey('mods')),
                      1 => const MarketplaceScreen(
                        key: ValueKey('marketplace'),
                      ),
                      _ => const SettingsScreen(key: ValueKey('settings')),
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      ),
      ),
    );
  }

  Widget _buildCustomTitleBar(BuildContext context, bool isDarkMode) {
    return DragToMoveArea(
      child: Container(
        height: 45,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isDarkMode
                ? [
                    const Color(0xFF1A1A1A).withValues(alpha: 0.95),
                    const Color(0xFF0F0F0F).withValues(alpha: 0.95),
                  ]
                : [
                    Colors.white.withValues(alpha: 0.95),
                    const Color(0xFFF5F5F5).withValues(alpha: 0.95),
                  ],
          ),
          border: Border(
            bottom: BorderSide(
              color: isDarkMode
                  ? Colors.white.withValues(alpha: 0.05)
                  : Colors.black.withValues(alpha: 0.03),
              width: 1,
            ),
          ),
          boxShadow: [
            BoxShadow(
              color: isDarkMode
                  ? Colors.black.withValues(alpha: 0.3)
                  : Colors.black.withValues(alpha: 0.05),
              blurRadius: 10,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            // Left group (icon + title) fills the bar so the window controls
            // pin to the far right; the title still shrinks/ellipsizes when
            // there isn't room.
            Expanded(
              child: Row(
                children: [
            const SizedBox(width: 20),
            // App icon/logo with gradient
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF0EA5E9), Color(0xFF06B6D4)],
                ),
                borderRadius: BorderRadius.circular(6),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF0EA5E9).withValues(alpha: 0.3),
                    blurRadius: 8,
                    spreadRadius: 1,
                  ),
                ],
              ),
              child: const Icon(Icons.style, color: Colors.white, size: 14),
            ),
            const SizedBox(width: 12),
            // App title with gradient text. Flexible + ellipsis so a very
            // narrow title bar (e.g. the brief first frame before the window is
            // sized) shrinks the title instead of overflowing the Row.
            Flexible(
              child: ShaderMask(
                shaderCallback: (bounds) => const LinearGradient(
                  colors: [Color(0xFF0EA5E9), Color(0xFF06B6D4)],
                ).createShader(bounds),
                child: Text(
                  context.loc.t('app.title'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
            ),
                ],
              ),
            ),
            // Downloads. Between the title and the window controls, and absent
            // until there is a transfer to report — see `DownloadsButton`.
            const DownloadsButton(),
            // Window controls
            _buildWindowButton(
              icon: Icons.remove,
              onPressed: () async {
                await windowManager.minimize();
              },
              isDarkMode: isDarkMode,
            ),
            _buildWindowButton(
              icon: Icons.crop_square,
              onPressed: () async {
                bool isMaximized = await windowManager.isMaximized();
                if (isMaximized) {
                  await windowManager.unmaximize();
                } else {
                  await windowManager.maximize();
                }
              },
              isDarkMode: isDarkMode,
            ),
            _buildWindowButton(
              icon: Icons.close,
              onPressed: () async {
                await windowManager.close();
              },
              isDarkMode: isDarkMode,
              isClose: true,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWindowButton({
    required IconData icon,
    required VoidCallback onPressed,
    required bool isDarkMode,
    bool isClose = false,
  }) {
    return SizedBox(
      width: 46,
      height: 40,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          hoverColor: isClose
              ? Colors.red.withValues(alpha: 0.8)
              : (isDarkMode
                    ? Colors.white.withValues(alpha: 0.1)
                    : Colors.black.withValues(alpha: 0.05)),
          child: Icon(
            icon,
            size: 16,
            color: isDarkMode
                ? Colors.white.withValues(alpha: 0.7)
                : Colors.black.withValues(alpha: 0.7),
          ),
        ),
      ),
    );
  }
}
