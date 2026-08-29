import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../models/gamebanana/gamebanana.dart';
import '../services/download/download_job.dart';
import '../services/download/download_queue.dart';
import '../services/download/queue_policy.dart';
import '../services/gamebanana/remote_mod_metadata.dart';
import '../services/platform_service_factory.dart';
import '../utils/marketplace_providers.dart';
import '../utils/notifications.dart';
import '../utils/state_providers.dart';
import 'components/marketplace/gb_browse_view.dart';
import 'components/marketplace/gb_detail_view.dart';

/// The marketplace: a **native** GameBanana browser, identical on Linux and
/// Windows.
///
/// It replaced an asymmetric pair of implementations — an embedded
/// `flutter_inappwebview` on Windows, and on Linux an "open your real browser"
/// button plus a watcher on the system Downloads folder that tried to guess when
/// a file had finished arriving. That split is gone, and with it three problems
/// it could not solve:
///
/// - the watcher could only ever see *a file appearing*, so a mod installed that
///   way had no remote identity at all — no mod id, no file id, no version;
/// - "finished downloading" was inferred by polling for a stable file size,
///   which is a guess about someone else's browser;
/// - anything the user downloaded for unrelated reasons was a false positive.
///
/// Two screens only, per the plan: a results grid and a mod detail view.
/// Everything else GameBanana hosts — comments, threads, member pages — is
/// reached through the "open in browser" escape hatch rather than rendered here.
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
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_librarySnapshotTaken) return;
    _librarySnapshotTaken = true;

    // Re-snapshot the library every time this screen opens. `ModsScreen` is
    // disposed while this one is up and nothing else keeps the snapshot current,
    // so a mod imported or deleted over there would otherwise leave the "in
    // library" badges describing a library that no longer exists. One scan,
    // single-digit milliseconds; see `installedModsIndexProvider`.
    //
    // **Here and not in `initState`.** `WidgetRef.invalidate` is the one member of
    // `ref` that resolves its container with `listen: true`, which registers an
    // inherited-widget dependency — and doing that during `initState` throws.
    // (`read`, `refresh` and `listenManual` use `listen: false` specifically so
    // they *can* be called there; `invalidate` does not.) `didChangeDependencies`
    // runs after `initState` and before the first build, so the snapshot is still
    // refreshed before anything watches it. The flag is what keeps it to once —
    // this also fires on a theme or locale change.
    ref.invalidate(installedModsIndexProvider);
  }

  @override
  Widget build(BuildContext context) {
    final openModId = ref.watch(marketplaceOpenModProvider);

    // No ClipRRect / rounded top corners here. The rounding was inherited from the
    // webview era, where it softened the edge of an embedded web page; on a
    // full-bleed grid it just cuts the corners off the layout. With no radius there
    // is nothing to clip either, so the wrapper goes entirely rather than becoming
    // a no-op clip.
    //
    // **An `IndexedStack`, not a conditional.** Swapping the two views out of the
    // tree disposes the browse view, and with it the scroll position of a grid the
    // user may have paged deep into — so opening a mod and pressing back landed
    // them at the top of the results every time. Keeping it mounted keeps the real
    // scroll offset rather than a remembered number, which is the only version of
    // this that survives the grid being a different height than when it was left
    // (a content-filter change, a library badge appearing).
    //
    // The detail slot is the one that stays empty while unused: a `GbDetailView`
    // holds per-mod view state (gallery index, reveal, archived files expanded),
    // and *that* must reset between mods rather than persist.
    return IndexedStack(
      index: openModId == null ? 0 : 1,
      // The children are laid out against the same constraints either way, which
      // is what the conditional above did.
      sizing: StackFit.expand,
      children: [
        // `IndexedStack` hides a child from painting, hit-testing and semantics,
        // but **not** from focus traversal — so without this, tabbing from the
        // detail view walks into the search box of a grid that isn't on screen.
        ExcludeFocus(
          excluding: openModId != null,
          child: GbBrowseView(
            onOpenMod: (modId) =>
                ref.read(marketplaceOpenModProvider.notifier).state = modId,
          ),
        ),
        if (openModId == null)
          const SizedBox.shrink()
        else
          GbDetailView(
            // Keyed so re-opening a *different* mod builds a fresh state rather
            // than reusing the previous one's gallery index.
            key: ValueKey(openModId),
            modId: openModId,
            onBack: () =>
                ref.read(marketplaceOpenModProvider.notifier).state = null,
            onDownload: _handleDownload,
            onOpenInBrowser: _openInBrowser,
          ),
      ],
    );
  }

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

  /// Hands one file of one mod to the download queue.
  ///
  /// This is where remote identity reaches the origin block: the mod id, file
  /// id, version and variant label are all known here, before a single byte is
  /// fetched, so the block lands at `exact` — the one tier that may drive an
  /// unattended update later. See `docs/origin-tracking.md` §2.
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
  void _handleDownload(GbMod mod, GbFile file) async {
    final choice = await _askDownloadChoice(file);
    if (choice == _DownloadChoice.cancel || !mounted) return;

    // The mod page's own filing, so the notification below can lead with the
    // character rather than a generic glyph. Pure and offline.
    final characterId = RemoteModMetadata.fromMod(mod).characterId;
    final subject = mod.name ?? file.file ?? loc.t('marketplace.unknown_file');

    // Asked *before* enqueuing rather than inferred from what comes back: a
    // freshly admitted job is started the same turn, so "did it come back
    // queued?" answers a question about the concurrency cap, not about whether
    // this file was already being fetched.
    final duplicate =
        activeJobForFile(ref.read(downloadQueueProvider), file.idRow) != null;

    final job = ref.read(downloadQueueProvider.notifier).enqueue(
          file: file,
          subject: subject,
          characterId: characterId,
          mod: mod,
          intent: choice == _DownloadChoice.downloadOnly
              ? DownloadIntent.keepArchive
              : DownloadIntent.install,
        );

    if (!mounted) return;
    if (job.state == DownloadJobState.failed) {
      // The one way enqueuing fails outright: a file whose download url will not
      // parse. It is already a failed row in the panel; this is what the user
      // standing at the button sees.
      context.notify.error(
        loc.t('marketplace.download_failed_title'),
        body: subject,
        characterId: characterId,
      );
      return;
    }
    // A successful enqueue says nothing here. `DownloadQueueHost` raises a
    // pinned progress notification the same turn, and that card *is* the
    // acknowledgement — a second "download started" beside it would be the app
    // saying the same thing twice.
    //
    // The exception is a press that changes nothing. The card is already up and
    // its count does not move, so without this the button reads as broken.
    if (duplicate) {
      context.notify.info(
        loc.t('marketplace.download_already_queued_title'),
        body: subject,
        characterId: characterId,
      );
    }
  }

  Future<_DownloadChoice> _askDownloadChoice(GbFile file) async {
    final filename = file.file ?? loc.t('marketplace.unknown_file');
    return await showDialog<_DownloadChoice>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(loc.t('marketplace.download_title')),
            content: Text(
              loc.t('marketplace.download_message',
                  params: {'filename': filename}),
            ),
            actions: [
              TextButton(
                onPressed: () =>
                    Navigator.pop(context, _DownloadChoice.cancel),
                child: Text(loc.t('marketplace.download_cancel')),
              ),
              TextButton(
                onPressed: () =>
                    Navigator.pop(context, _DownloadChoice.downloadOnly),
                child: Text(loc.t('marketplace.download_only')),
              ),
              FilledButton(
                onPressed: () =>
                    Navigator.pop(context, _DownloadChoice.downloadAndInstall),
                child: Text(loc.t('marketplace.download_install')),
              ),
            ],
          ),
        ) ??
        _DownloadChoice.cancel;
  }
}

enum _DownloadChoice { cancel, downloadOnly, downloadAndInstall }
