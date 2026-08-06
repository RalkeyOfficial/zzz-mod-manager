import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;

import '../core/constants.dart';
import '../l10n/app_localizations.dart';
import '../models/gamebanana/gamebanana.dart';
import '../models/install_result.dart';
import '../models/mod_origin_seed.dart';
import '../models/origin_enums.dart';
import '../services/api_service.dart';
import '../services/archive_service.dart';
import '../services/download/download_exceptions.dart';
import '../services/download/download_progress.dart';
import '../services/download/download_request.dart';
import '../services/mod_manager_service.dart';
import '../services/platform_service_factory.dart';
import '../utils/marketplace_providers.dart';
import '../utils/state_providers.dart';
import 'components/install_result_snackbars.dart';
import 'components/marketplace/gb_browse_view.dart';
import 'components/marketplace/gb_detail_view.dart';
import 'dialogs/download_progress_dialog.dart';
import 'dialogs/duplicate_archive_dialog.dart';
import 'dialogs/import_selection_dialog.dart';

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
    return openModId == null
        ? GbBrowseView(
            onOpenMod: (modId) =>
                ref.read(marketplaceOpenModProvider.notifier).state = modId,
          )
        : GbDetailView(
            modId: openModId,
            onBack: () =>
                ref.read(marketplaceOpenModProvider.notifier).state = null,
            onDownload: _handleDownload,
            onOpenInBrowser: _openInBrowser,
          );
  }

  Future<void> _openInBrowser(String url) async {
    // Through the platform service, never a `Platform.isX` branch here.
    final opened =
        await PlatformServiceFactory.getInstance().openUrlInBrowser(url);
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Theme.of(context).colorScheme.error,
          content: Text(loc.t('marketplace.error_opening')),
        ),
      );
    }
  }

  /// Downloads one file of one mod, then offers to install it.
  ///
  /// This is where remote identity finally reaches the origin block. The webview
  /// era could only ever intercept a CDN url, so every origin block it wrote had
  /// both confidences at `unknown`; here the mod id, file id, version and
  /// variant label are all known before a single byte is fetched, so the block
  /// lands at `exact` — the one tier that may drive an unattended update later.
  Future<void> _handleDownload(GbMod mod, GbFile file) async {
    final url = Uri.tryParse(
      file.downloadUrl ?? 'https://gamebanana.com/dl/${file.idRow}',
    );
    if (url == null) return;

    final choice = await _askDownloadChoice(file);
    if (choice == _DownloadChoice.cancel || !mounted) return;

    final scaffoldMessenger = ScaffoldMessenger.of(context);
    final errorColor = Theme.of(context).colorScheme.error;

    final handle = ref.read(downloadServiceProvider).start(
          DownloadRequest(
            url: url,
            suggestedFilename: file.file,
            fileId: file.idRow,
            // `_nFilesize` is exactly the eventual Content-Length, so it is a
            // reliable progress denominator from the first frame.
            expectedSize: file.filesize,
            expectedMd5: file.md5Checksum,
          ),
        );

    final progressNotifier = ValueNotifier<DownloadProgress>(
      const DownloadProgress(state: DownloadState.connecting),
    );
    final progressSub =
        handle.progress.listen((p) => progressNotifier.value = p);

    var dialogClosed = false;
    void closeDialog() {
      if (dialogClosed) return;
      dialogClosed = true;
      Navigator.of(context, rootNavigator: true).pop();
    }

    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => DownloadProgressDialog(
          progress: progressNotifier,
          onCancel: () => unawaited(handle.cancel(deletePartial: true)),
        ),
      ),
    );

    try {
      final result = await handle.done;
      closeDialog();
      if (!mounted) return;

      if (choice == _DownloadChoice.downloadOnly) {
        scaffoldMessenger.showSnackBar(
          SnackBar(
            content: Text(loc.t('marketplace.download_saved',
                params: {'path': result.file.path})),
          ),
        );
        return;
      }

      final installResult = await _installArchive(
        result.file,
        knownMd5: result.md5,
        mod: mod,
        file: file,
      );
      if (!mounted) return;
      showInstallResult(context, installResult);
      // The library just changed, and the badges on the grid behind this dialog
      // are rendered from that snapshot. Invalidate rather than patch: the mod
      // folder's final name is decided by the import (dedup, the combined-name
      // dialog), so re-reading is the only way to be right about it.
      ref.invalidate(installedModsIndexProvider);
    } on DownloadCancelledException {
      closeDialog();
      if (!mounted) return;
      scaffoldMessenger.showSnackBar(
        SnackBar(content: Text(loc.t('marketplace.download_cancelled'))),
      );
    } catch (e) {
      closeDialog();
      if (!mounted) return;
      final message = e is DownloadStalledException
          ? loc.t('marketplace.download_stalled')
          : loc.t('marketplace.download_failed', params: {'message': '$e'});
      scaffoldMessenger.showSnackBar(
        SnackBar(backgroundColor: errorColor, content: Text(message)),
      );
    } finally {
      closeDialog();
      await progressSub.cancel();
      progressNotifier.dispose();
    }
  }

  /// The origin seed for a file we picked ourselves off a mod page.
  ///
  /// Both confidences are `exact` and that is the honest tier, not an optimistic
  /// one: the user chose this row of this mod's file list and we fetched exactly
  /// that file id. Nothing here is inferred.
  ///
  /// `version` and `versionLabel` map onto the two GameBanana strings that must
  /// never be conflated — `_sVersion` is a per-file version, `_sDescription` is
  /// the author's variant label ("white hair ver"). They are recorded separately
  /// because collapsing them would make two variants of one release look like
  /// two releases.
  ModOriginSeed _seedFor(GbMod mod, GbFile file, {String? archiveMd5}) {
    return ModOriginSeed(
      provenance: OriginProvenance.downloaded,
      archiveMd5: archiveMd5,
      source: AppConstants.gameBananaSourceName,
      modId: mod.idRow,
      modIdConfidence: OriginConfidence.exact,
      fileId: file.idRow,
      version: file.version,
      versionLabel: file.description,
      versionConfidence: OriginConfidence.exact,
    );
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

  Future<InstallResult> _installArchive(
    File archiveFile, {
    String? knownMd5,
    required GbMod mod,
    required GbFile file,
  }) async {
    // Only set once the archive has been unpacked and is genuinely spent. The
    // archive is a throwaway intermediate, but throwing it away *before* it has
    // been extracted would leave the user with nothing to retry from.
    var archiveConsumed = false;

    try {
      final config = await ApiService.getConfig();
      final modsPath = config['mods_path'] ?? '';

      // Inside the try, deliberately: as an early return above it, this skipped
      // the cleanup in `finally` entirely and leaked the archive.
      if (modsPath.isEmpty) {
        return InstallResult.error(loc.t('marketplace.install_missing_path'));
      }

      final extractionResult = await ArchiveService.extractArchive(
        archiveFile: archiveFile,
        knownMd5: knownMd5,
      );

      if (!extractionResult.success) {
        // Keep the archive: the user can still extract it by hand, and telling
        // them where it is turns a dead end into a workaround.
        final reason =
            extractionResult.error ?? loc.t('marketplace.install_unsupported');
        final kept = loc.t(
          'marketplace.archive_kept',
          params: {'path': archiveFile.path},
        );
        return InstallResult.error('$reason\n$kept');
      }
      archiveConsumed = true;

      final directoriesToImport = List<String>.from(
        extractionResult.extractedFolders ?? const <String>[],
      );

      if (directoriesToImport.isEmpty) {
        return InstallResult.warning(loc.t('marketplace.install_empty'));
      }

      // The character is often in the archive name rather than the inner folder
      // (or vice versa), so pass the archive base name as an extra detection hint.
      final archiveBaseName = path.basenameWithoutExtension(archiveFile.path);

      final archiveMd5 = extractionResult.archiveMd5 ?? knownMd5;
      if (!mounted) return InstallResult.cancelled();
      if (!await confirmArchiveNotDuplicate(context, ref, archiveMd5)) {
        await _cleanupExtractedFolders(directoriesToImport);
        return InstallResult.cancelled();
      }

      // When an archive expands to more than one top-level folder (e.g. a mod
      // folder next to a `previews` folder), let the user choose which folders
      // to install and whether they become separate mods or one combined mod.
      // Shared with the drag/drop and upload-button flow via resolveImportSelection.
      if (!mounted) return InstallResult.cancelled();
      final plan = await resolveImportSelection(
        context,
        directoriesToImport,
        defaultCombinedName: archiveBaseName,
      );
      if (plan == null) {
        // Cancelled — drop the extracted temp folders (the archive itself is
        // cleaned up by the caller's `finally`).
        await _cleanupExtractedFolders(directoriesToImport);
        return InstallResult.cancelled();
      }
      directoriesToImport
        ..clear()
        ..addAll(plan.folders);

      // Built here rather than at the call site because the archive hash is only
      // known once extraction has run. Every folder came out of this one
      // archive, so one seed covers all of them; `archiveMd5` is null-or-exact
      // and a null merely costs the fast path at resolution time.
      final effectiveSeed = _seedFor(mod, file, archiveMd5: archiveMd5);

      final ModManagerService modManager =
          await ApiService.getModManagerService();
      final (importedMods, autoTags) = plan.combine
          ? await modManager.importCombinedMod(
              directoriesToImport,
              plan.combinedName,
              detectionHint: archiveBaseName,
              origin: effectiveSeed,
            )
          : await modManager.importMods(
              directoriesToImport,
              detectionHints: {
                for (final dir in directoriesToImport) dir: archiveBaseName,
              },
              originSeeds: {
                for (final dir in directoriesToImport) dir: effectiveSeed,
              },
            );

      if (importedMods.isEmpty) {
        return InstallResult.warning(loc.t('marketplace.install_duplicate'));
      }

      final tagSummary = autoTags.entries
          .map((entry) => '${entry.key} → ${entry.value}')
          .join(', ');

      // Safety net: warn about any imported mod that has no .ini at all — a
      // strong sign the mod is incomplete (e.g. a broken multi-folder archive).
      final noIni = await ArchiveService.modsWithoutIni(modsPath, importedMods);

      // Drained, so it is reported exactly once: nothing re-attempts an origin
      // write, because it happens at ingest and never during a scan.
      final originFailures = modManager.takeOriginWriteFailures();

      final messages = <String>[
        if (tagSummary.isNotEmpty)
          loc.t('marketplace.install_tags', params: {'tags': tagSummary}),
        if (noIni.isNotEmpty)
          loc.t('mods.snackbar.import_no_ini', params: {'mods': noIni.join(', ')}),
        if (originFailures.isNotEmpty)
          loc.t('mods.snackbar.origin_write_failed',
              params: {'mods': originFailures.join(', ')}),
      ];
      final message = messages.isEmpty ? null : messages.join('\n');

      return InstallResult.success(importedMods, message: message);
    } finally {
      if (archiveConsumed && await archiveFile.exists()) {
        await _safeDeleteArchive(archiveFile);
      }
    }
  }

  /// Deletes the temp extract dirs (`zzz_archive_extract_*`) that hold the given
  /// extracted folders. Called when the user cancels the import selection dialog.
  Future<void> _cleanupExtractedFolders(List<String> folderPaths) async {
    for (final folderPath in folderPaths) {
      try {
        final dir = Directory(folderPath);
        if (!await dir.exists()) continue;
        final parentDir = dir.parent;
        if (parentDir.path.contains('zzz_archive_extract_')) {
          await parentDir.delete(recursive: true);
        }
      } catch (e) {
        print('Marketplace: temp cleanup error $folderPath: $e');
      }
    }
  }

  /// Deletes a consumed archive — **the file, never a directory.**
  ///
  /// This used to delete `archiveFile.parent` recursively whenever the archive
  /// wasn't in the system Downloads folder, which was survivable only because
  /// every download got its own throwaway temp directory. Now that archives
  /// share `<appData>/downloads`, that same line would wipe every other archive
  /// and every in-flight partial download the first time it ran. One rule, no
  /// special cases: remove the file we just consumed and nothing else.
  Future<void> _safeDeleteArchive(File archiveFile) async {
    try {
      await archiveFile.delete();
    } catch (e) {
      print('Marketplace: could not delete archive ${archiveFile.path}: $e');
    }
  }
}

enum _DownloadChoice { cancel, downloadOnly, downloadAndInstall }
