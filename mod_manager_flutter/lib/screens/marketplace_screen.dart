import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../models/gamebanana/gamebanana.dart';
import '../services/download/download_job.dart';
import '../services/platform_service_factory.dart';
import '../utils/marketplace_providers.dart';
import '../utils/notifications.dart';
import '../utils/state_providers.dart';
import 'components/marketplace/gb_browse_view.dart';
import 'components/marketplace/gb_creator_view.dart';
import 'components/marketplace/gb_detail_view.dart';
import 'components/marketplace/marketplace_install_flow.dart';

/// The marketplace: a **native** GameBanana browser, identical on Linux and
/// Windows.
///
/// Native rather than a webview or a watcher on the system Downloads folder,
/// because only a download the app makes itself knows the mod id, file id and
/// version before the first byte, and knows for certain when it has finished.
/// `docs/marketplace.md` §1 has the alternatives and why each loses.
///
/// The results grid, with a stack of pages over it: a mod's page, and a creator's page, reached from the author's
/// name on a mod page. Everything else GameBanana hosts, comments and threads, is reached through a page's "Open on
/// GameBanana" rather than rendered here.
class MarketplaceScreen extends ConsumerStatefulWidget {
  const MarketplaceScreen({super.key});

  @override
  ConsumerState<MarketplaceScreen> createState() => _MarketplaceScreenState();
}

class _MarketplaceScreenState extends ConsumerState<MarketplaceScreen> {
  AppLocalizations get loc => context.loc;

  /// Whether this screen has taken its library snapshot yet. One per `State`,
  /// which is one per marketplace open — the tabs are keyed children of an
  /// `AnimatedSwitcher` with no keep-alive, so a new `State` *is* the event.
  bool _librarySnapshotTaken = false;

  @override
  void initState() {
    super.initState();
    // A late handler sees only a key nothing focused has taken, so a dialog, a menu or a text field keeps its own
    // Escape and Alt+Left: a field takes Escape to hide its toolbar and Alt+Left to move to the line's start, and
    // Browse's menus and the character popover take focus when they open, so their Escape closes them.
    // It also sees a key pressed while nothing on the page has focus, which a `Focus` around the page would miss.
    FocusManager.instance.addLateKeyEventHandler(_onUnclaimedKey);
  }

  @override
  void dispose() {
    FocusManager.instance.removeLateKeyEventHandler(_onUnclaimedKey);
    super.dispose();
  }

  /// Goes back one page for Escape, Alt+Left or the mouse's back button, if a page is open over the grid, Browse is
  /// the page shown and no dialog, panel or menu is over it. Returns whether it went back.
  bool _goBack() {
    if (!mounted || ref.read(destinationProvider) != AppDestination.browse) return false;
    // A dialog or the Downloads panel is a route over this one.
    if (!(ModalRoute.isCurrentOf(context) ?? true)) return false;
    // An open menu holds focus (`_EscapableMenuAnchor`) and takes Escape itself; Alt+Left and the back button wait
    // for it to close, which a click outside it does.
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused != null && (MenuController.maybeOf(focused)?.isOpen ?? false)) return false;
    if (ref.read(marketplaceRoutesProvider).isEmpty) return false;
    ref.read(marketplaceRoutesProvider.notifier).back();
    return true;
  }

  KeyEventResult _onUnclaimedKey(KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    final isBack = switch (event.logicalKey) {
      LogicalKeyboardKey.escape => !keyboard.isAltPressed && !keyboard.isControlPressed && !keyboard.isMetaPressed,
      LogicalKeyboardKey.arrowLeft =>
        keyboard.isAltPressed && !keyboard.isControlPressed && !keyboard.isMetaPressed && !keyboard.isShiftPressed,
      _ => false,
    };
    if (!isBack) return KeyEventResult.ignored;
    return _goBack() ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  void _onPointerDown(PointerDownEvent event) {
    if (event.buttons & kBackMouseButton != 0) _goBack();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_librarySnapshotTaken) return;
    _librarySnapshotTaken = true;

    // Re-read the library every time this screen opens, so the "in library"
    // badges describe the library as it is rather than as the app last saw it —
    // a mod added or deleted outside the app, or by a flow that finished after
    // the last scan, is otherwise invisible here. One scan, single-digit
    // milliseconds; see `libraryProvider`.
    //
    // **After the frame, not during it.**
    // The Library page fading out under the `AnimatedSwitcher` still watches `libraryProvider`,
    // and this screen's first build reads it through `installedModsIndexProvider`;
    // an invalidate here makes that read rebuild the library mid-build and mark the Library dirty, which throws.
    // The scan is async either way, so the badges show the cached library until the scan ends.
    //
    // `WidgetRef.invalidate` is the one member of `ref` that resolves its container with `listen: true`,
    // which `initState` forbids, so it never runs there directly.
    // The flag keeps it to once — this also fires on a theme or locale change.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.invalidate(libraryProvider);
    });
  }

  @override
  Widget build(BuildContext context) {
    final routes = ref.watch(marketplaceRoutesProvider);

    // No rounded top corners and no clip: on a full-bleed grid a radius only cuts
    // the corners off the layout.
    //
    // **An `IndexedStack`, not a conditional.** Swapping the pages out of the
    // tree would dispose the browse view, and with it the scroll position and the
    // loaded pages of a grid the user may have scrolled deep into, so opening a mod
    // and pressing back would land them at the top. Keeping it mounted keeps the
    // real scroll offset rather than a remembered number, which is the only version
    // of this that survives the grid being a different height than when it was left
    // (a content-filter change, a library badge appearing).
    //
    // Every page in the stack stays mounted the same way, keyed by what it shows, so going back finds a page as it
    // was left: a creator's page keeps its loaded mods, its tile and its scroll, a mod's page its picture and its
    // picked files. A page gone back past is disposed, and a mod opened again starts afresh.
    final navigator = ref.read(marketplaceRoutesProvider.notifier);
    final stack = IndexedStack(
      index: routes.length,
      sizing: StackFit.expand,
      children: [
        // `IndexedStack` already keeps its hidden children out of focus through `Visibility`;
        // this states it explicitly for the grid and every page but the top one.
        ExcludeFocus(
          excluding: routes.isNotEmpty,
          child: GbBrowseView(onOpenMod: navigator.openFromGrid, onInstallFile: _installFile),
        ),
        for (var depth = 0; depth < routes.length; depth++)
          KeyedSubtree(
            key: ValueKey(routes[depth]),
            child: ExcludeFocus(
              excluding: depth != routes.length - 1,
              child: _page(routes[depth], depth == 0 ? null : routes[depth - 1]),
            ),
          ),
      ],
    );
    // Translucent, so the back button goes back over a page's empty space as well as over its content.
    return Listener(behavior: HitTestBehavior.translucent, onPointerDown: _onPointerDown, child: stack);
  }

  /// The page for [route], with [below] the page it was opened from, or null for the grid.
  Widget _page(MarketplaceRoute route, MarketplaceRoute? below) {
    final navigator = ref.read(marketplaceRoutesProvider.notifier);
    final parent = below == null ? null : (label: _crumbLabel(below), onTap: navigator.back);
    return switch (route) {
      MarketplaceModRoute(:final modId) => GbDetailView(
        modId: modId,
        onBack: navigator.back,
        onBrowse: navigator.toGrid,
        parent: parent,
        onOpenCreator: (member) => navigator.open(MarketplaceCreatorRoute(member)),
        onQueue: _queueFiles,
        onOpenInBrowser: _openInBrowser,
      ),
      MarketplaceCreatorRoute(:final member) => GbCreatorView(
        member: member,
        onBack: navigator.back,
        onBrowse: navigator.toGrid,
        parent: parent,
        onOpenMod: (modId) => navigator.open(MarketplaceModRoute(modId)),
        onInstallFile: _installFile,
        onOpenInBrowser: _openInBrowser,
      ),
    };
  }

  /// What the crumb for [route] says: the mod's name, or the member's.
  String _crumbLabel(MarketplaceRoute route) => switch (route) {
    MarketplaceModRoute(:final modId) => ref.watch(modProfileProvider(modId)).valueOrNull?.name ?? '#$modId',
    MarketplaceCreatorRoute(:final member) => member.name ?? '#${member.idRow}',
  };

  Future<void> _openInBrowser(String url) async {
    // Through the platform service, never a `Platform.isX` branch here.
    final opened =
        await PlatformServiceFactory.getInstance().openUrlInBrowser(url);
    if (!opened && mounted) {
      context.notify.error(
        loc.t('marketplace.error_opening_title'),
        body: loc.t('marketplace.error_opening_body'),
      );
    }
  }

  /// The mod page's Install and Download without installing: hands each picked file to the queue as its own job, in
  /// the list's order ([enqueueMarketplaceFile]), with the character the page shows and, for an install, the Turn on
  /// after installing setting.
  ///
  /// **It does not wait, and it does not own what happens next.** The transfer
  /// runs in the background so the user can keep browsing: archives reach
  /// 1.24 GB and a degraded CDN node stretches one to twenty-five minutes, which
  /// is a long time to hold the whole app behind a modal barrier. The install
  /// that follows belongs to `DownloadQueueHost`, mounted above the tabs,
  /// because this screen is *disposed* the moment the user switches to another
  /// one and an install owned by it would die there.
  ///
  /// What this method still owns is the one thing it must: the mod page, which
  /// only exists here. It travels with the job.
  void _queueFiles(
    GbMod mod,
    List<GbFile> files, {
    required String? characterId,
    required DownloadIntent intent,
  }) {
    final container = ProviderScope.containerOf(context, listen: false);
    final turnOn = ref.read(marketplaceTurnOnAfterInstallProvider);
    for (final file in files) {
      enqueueMarketplaceFile(container, loc, mod, file, intent, characterId: characterId, turnOn: turnOn);
    }
  }

  /// A card's or the carousel's Install. The flow runs on the app's container, so a page switch while the mod page
  /// is fetched doesn't lose the press.
  void _installFile(int modId, GbFile file) => installSoleFile(
    ProviderScope.containerOf(context, listen: false),
    loc,
    modId: modId,
    file: file,
    screenMounted: () => mounted,
  );
}
