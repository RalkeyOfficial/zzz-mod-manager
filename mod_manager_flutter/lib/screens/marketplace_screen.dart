import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path/path.dart' as path;

import '../l10n/app_localizations.dart';
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
import '../utils/state_providers.dart';
import 'components/install_result_snackbars.dart';
import 'dialogs/download_progress_dialog.dart';
import 'dialogs/import_selection_dialog.dart';

enum _MarketplaceDownloadChoice { cancel, downloadOnly, downloadAndInstall }

class MarketplaceScreen extends ConsumerStatefulWidget {
  const MarketplaceScreen({super.key});

  @override
  ConsumerState<MarketplaceScreen> createState() => _MarketplaceScreenState();
}

class _MarketplaceScreenState extends ConsumerState<MarketplaceScreen> {
  static final WebUri _homeUri = WebUri('https://gamebanana.com/games/19567');

  InAppWebViewController? _inAppWebViewController;
  final TextEditingController _searchController = TextEditingController();
  bool _isLoading = true;
  double _progress = 0;
  
  StreamSubscription<FileSystemEvent>? _downloadsWatcher;
  final Set<String> _processedFiles = {};
  bool _isWatchingDownloads = false;

  bool get _isWindows => !kIsWeb && Platform.isWindows;
  bool get _isLinux => !kIsWeb && Platform.isLinux;
  bool get _isDesktop => _isWindows || _isLinux;

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _stopDownloadsWatcher();
    super.dispose();
  }
  
  void _stopDownloadsWatcher() {
    _downloadsWatcher?.cancel();
    _downloadsWatcher = null;
    _isWatchingDownloads = false;
  }

  AppLocalizations get loc => context.loc;
  bool get _isWebViewSupported => _isWindows;

  @override
  Widget build(BuildContext context) {
    final isDarkMode = ref.watch(isDarkModeProvider);
    final isSupported = _isWebViewSupported;

    return Column(
      children: [
        _buildToolbar(isDarkMode, isSupported),
        if (_isLoading && isSupported) _buildProgressBar(),
        Expanded(
          child: ClipRRect(
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(16),
              topRight: Radius.circular(16),
            ),
            child: isSupported
                ? _buildWebView(isDarkMode)
                : _buildUnsupportedView(isDarkMode),
          ),
        ),
      ],
    );
  }

  Widget _buildToolbar(bool isDarkMode, bool isEnabled) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: isDarkMode ? const Color(0xFF1A1A1A) : Colors.white,
        boxShadow: [
          BoxShadow(
            color: isDarkMode
                ? Colors.black.withOpacity(0.4)
                : Colors.black.withOpacity(0.08),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          _buildIconButton(
            icon: Icons.arrow_back,
            tooltip: loc.t('marketplace.back'),
            enabled: isEnabled,
            onPressed: () {
              _handleBackNavigation();
            },
          ),
          const SizedBox(width: 8),
          _buildIconButton(
            icon: Icons.arrow_forward,
            tooltip: loc.t('marketplace.forward'),
            enabled: isEnabled,
            onPressed: () {
              _handleForwardNavigation();
            },
          ),
          const SizedBox(width: 8),
          _buildIconButton(
            icon: Icons.refresh,
            tooltip: loc.t('marketplace.reload'),
            enabled: isEnabled,
            onPressed: () {
              _handleReload();
            },
          ),
          const SizedBox(width: 8),
          _buildIconButton(
            icon: Icons.home,
            tooltip: loc.t('marketplace.home'),
            enabled: isEnabled,
            onPressed: () {
              _handleHomeNavigation();
            },
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: isDarkMode
                    ? Colors.white.withOpacity(0.05)
                    : Colors.black.withOpacity(0.03),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isDarkMode
                      ? Colors.white.withOpacity(0.08)
                      : Colors.black.withOpacity(0.08),
                ),
              ),
              child: Row(
                children: [
                  const SizedBox(width: 12),
                  const Icon(Icons.search, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      enabled: isEnabled,
                      decoration: InputDecoration(
                        hintText: loc.t('marketplace.search_hint'),
                        border: InputBorder.none,
                      ),
                      onSubmitted: _performSearch,
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: isEnabled
                        ? () => _performSearch(_searchController.text)
                        : null,
                    child: Text(loc.t('marketplace.search')),
                  ),
                  const SizedBox(width: 8),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildIconButton({
    required IconData icon,
    required VoidCallback onPressed,
    required String tooltip,
    bool enabled = true,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: enabled ? onPressed : null,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: Colors.transparent,
          ),
          child: Icon(icon, size: 20, color: enabled ? null : Colors.grey),
        ),
      ),
    );
  }

  Widget _buildUnsupportedView(bool isDarkMode) {
    if (_isLinux) {
      return _buildLinuxMarketplaceView(isDarkMode);
    }
    
    final url = _homeUri.toString();
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.open_in_browser,
                size: 48,
                color: isDarkMode ? Colors.white54 : Colors.black45,
              ),
              const SizedBox(height: 16),
              Text(
                loc.t('marketplace.unsupported_title'),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              Text(
                loc.t('marketplace.unsupported_body', params: {'url': url}),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: isDarkMode ? Colors.white70 : Colors.black54,
                ),
              ),
              const SizedBox(height: 20),
              OutlinedButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: url));
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(loc.t('marketplace.copy_success'))),
                  );
                },
                icon: const Icon(Icons.copy_all_rounded),
                label: Text(loc.t('marketplace.copy_link')),
              ),
            ],
          ),
        ),
      ),
    );
  }
  
  Widget _buildLinuxMarketplaceView(bool isDarkMode) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 500),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.public,
                size: 64,
                color: isDarkMode ? Colors.blue.shade300 : Colors.blue.shade700,
              ),
              const SizedBox(height: 24),
              Text(
                loc.t('marketplace.linux_title'),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                loc.t('marketplace.linux_body'),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: isDarkMode ? Colors.white70 : Colors.black87,
                ),
              ),
              const SizedBox(height: 32),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  FilledButton.icon(
                    onPressed: _openBrowserAndStartWatching,
                    icon: const Icon(Icons.open_in_browser, size: 24),
                    label: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                      child: Text(
                        loc.t('marketplace.open_marketplace'),
                        style: const TextStyle(fontSize: 16),
                      ),
                    ),
                  ),
                  if (_isWatchingDownloads) ...[
                    const SizedBox(width: 12),
                    IconButton.filled(
                      onPressed: () {
                        setState(() {
                          _stopDownloadsWatcher();
                        });
                      },
                      icon: const Icon(Icons.stop),
                      tooltip: loc.t('marketplace.stop_watching'),
                      style: IconButton.styleFrom(
                        backgroundColor: isDarkMode 
                            ? Colors.red.shade700 
                            : Colors.red.shade600,
                      ),
                    ),
                  ],
                  if (!_isWatchingDownloads) ...[
                    const SizedBox(width: 12),
                    IconButton.filled(
                      onPressed: _startDownloadsWatcher,
                      icon: const Icon(Icons.play_arrow),
                      tooltip: loc.t('marketplace.start_watching'),
                      style: IconButton.styleFrom(
                        backgroundColor: isDarkMode 
                            ? Colors.green.shade700 
                            : Colors.green.shade600,
                      ),
                    ),
                  ],
                ],
              ),
              if (_isWatchingDownloads) ...[
                const SizedBox(height: 24),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: isDarkMode 
                        ? Colors.green.shade900.withOpacity(0.3) 
                        : Colors.green.shade50,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isDarkMode 
                          ? Colors.green.shade700 
                          : Colors.green.shade300,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.downloading,
                        color: isDarkMode 
                            ? Colors.green.shade300 
                            : Colors.green.shade700,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          loc.t('marketplace.watching_downloads'),
                          style: TextStyle(
                            color: isDarkMode 
                                ? Colors.green.shade200 
                                : Colors.green.shade900,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
  
  Future<void> _openBrowserAndStartWatching() async {
    final platformService = PlatformServiceFactory.getInstance();
    final url = _homeUri.toString();
    
    final opened = await platformService.openUrlInBrowser(url);
    
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Theme.of(context).colorScheme.error,
          content: Text(loc.t('marketplace.error_opening')),
        ),
      );
      return;
    }
    
    _startDownloadsWatcher();
  }
  
  void _startDownloadsWatcher() {
    if (_isWatchingDownloads) return;
    
    final platformService = PlatformServiceFactory.getInstance();
    final downloadsPath = platformService.getSystemDownloadsPath();
    
    if (downloadsPath == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not find Downloads directory'),
          ),
        );
      }
      return;
    }
    
    final downloadsDir = Directory(downloadsPath);
    if (!downloadsDir.existsSync()) {
      downloadsDir.createSync(recursive: true);
    }
    
    setState(() {
      _isWatchingDownloads = true;
    });
    
    _downloadsWatcher = downloadsDir.watch(events: FileSystemEvent.create).listen(
      (event) {
        if (event is FileSystemCreateEvent) {
          _handleNewDownload(event.path);
        }
      },
    );
    
    print('LinuxMarketplace: Watching $downloadsPath for new downloads');
  }
  
  Future<void> _handleNewDownload(String filePath) async {
    if (_processedFiles.contains(filePath)) return;
    
    final extension = path.extension(filePath).toLowerCase();
    if (extension != '.zip' && extension != '.rar' && extension != '.7z') {
      return;
    }
    
    _processedFiles.add(filePath);
    
    print('LinuxMarketplace: Виявлено новий файл: $filePath');
    
    await Future.delayed(const Duration(milliseconds: 500));
    
    final file = File(filePath);
    if (!await file.exists()) {
      print('LinuxMarketplace: Файл не існує: $filePath');
      return;
    }
    
    print('LinuxMarketplace: Очікування завершення завантаження...');
    if (!await _waitForFileToBeReady(file)) {
      print('LinuxMarketplace: Файл не готовий після очікування');
      return;
    }
    
    print('LinuxMarketplace: Файл готовий: ${file.lengthSync()} bytes');
    
    if (!mounted) return;
    
    final choice = await _showDownloadChoiceDialog(
      context,
      suggestedName: path.basename(filePath),
      url: filePath,
    );
    
    if (choice != _MarketplaceDownloadChoice.cancel && mounted) {
      if (choice == _MarketplaceDownloadChoice.downloadAndInstall) {
        await _installArchiveFromPath(filePath);
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                loc.t('marketplace.download_saved', params: {'path': filePath}),
              ),
            ),
          );
        }
      }
    }
  }
  
  Future<bool> _waitForFileToBeReady(File file) async {
    const maxAttempts = 120;
    int previousSize = -1;
    int stableCount = 0;
    
    for (int i = 0; i < maxAttempts; i++) {
      await Future.delayed(const Duration(milliseconds: 1000));
      
      if (!await file.exists()) {
        print('LinuxMarketplace: Файл зник, спроба $i/$maxAttempts');
        return false;
      }
      
      try {
        final currentSize = await file.length();
        print('LinuxMarketplace: Перевірка розміру: $currentSize bytes (спроба ${i+1}/$maxAttempts)');
        
        if (currentSize == previousSize && currentSize > 0) {
          stableCount++;
          print('LinuxMarketplace: Розмір стабільний ($stableCount/3)');
          
          if (stableCount >= 3) {
            print('LinuxMarketplace: Файл готовий! Розмір: $currentSize bytes');
            return true;
          }
        } else {
          stableCount = 0;
        }
        
        previousSize = currentSize;
      } catch (e) {
        print('LinuxMarketplace: Помилка перевірки розміру файлу: $e');
        await Future.delayed(const Duration(milliseconds: 1000));
      }
    }
    
    print('LinuxMarketplace: Таймаут очікування (120 секунд)');
    return false;
  }
  
  Future<void> _installArchiveFromPath(String filePath) async {
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    
    try {
      final file = File(filePath);
      // `imported_archive`, never `downloaded`: the user's own browser fetched
      // this file and we merely noticed it appear in their Downloads folder.
      // "Arrived via the marketplace screen" is not evidence that we fetched
      // it, and claiming otherwise would assert provenance we didn't earn.
      final installResult = await _installArchive(
        file,
        provenance: OriginProvenance.importedArchive,
      );
      
      if (!mounted) return;
      
      showInstallResult(context, installResult);
    } catch (e) {
      if (!mounted) return;
      scaffoldMessenger.showSnackBar(
        SnackBar(
          backgroundColor: Theme.of(context).colorScheme.error,
          content: Text(
            loc.t('marketplace.download_failed', params: {'message': '$e'}),
          ),
        ),
      );
    }
  }

  Widget _buildProgressBar() {
    return LinearProgressIndicator(
      value: _progress > 0 && _progress < 1 ? _progress : null,
    );
  }

  Widget _buildWebView(bool isDarkMode) {
    if (_isDesktop) {
      return _buildDesktopWebView(isDarkMode);
    }
    return _buildUnsupportedView(isDarkMode);
  }

  Widget _buildDesktopWebView(bool isDarkMode) {
    return InAppWebView(
      initialUrlRequest: URLRequest(url: _homeUri),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        transparentBackground: true,
        useShouldOverrideUrlLoading: true,
        incognito: false,
        allowsInlineMediaPlayback: true,
        supportZoom: true,
        clearCache: false,
        disableContextMenu: false,
        allowsBackForwardNavigationGestures: true,
        mediaPlaybackRequiresUserGesture: false,
        useOnDownloadStart: true,
        isFraudulentWebsiteWarningEnabled: true,
      ),
      onWebViewCreated: (controller) => _inAppWebViewController = controller,
      shouldOverrideUrlLoading: (controller, action) async {
        final url = action.request.url?.toString() ?? '';
        final uri = Uri.tryParse(url);
        
        if (uri != null) {
          final extension = path.extension(uri.path).toLowerCase();
          if (extension == '.zip' || extension == '.rar' || extension == '.7z') {
            final suggestedName = path.basename(uri.path);
            final choice = await _showDownloadChoiceDialog(
              context,
              suggestedName: suggestedName,
              url: url,
            );
            if (choice != _MarketplaceDownloadChoice.cancel && mounted) {
              await _handleDownload(
                uri: uri,
                suggestedName: suggestedName,
                autoInstall: choice == _MarketplaceDownloadChoice.downloadAndInstall,
              );
            }
            return NavigationActionPolicy.CANCEL;
          }
        }
        
        return NavigationActionPolicy.ALLOW;
      },
      onLoadStart: (controller, url) {
        if (url != null) {
          setState(() {
            _progress = 0;
            _isLoading = true;
          });
        }
      },
      onLoadStop: (controller, url) async {
        if (!mounted) return;
        setState(() {
          _isLoading = false;
          _progress = 0;
        });
      },
      onProgressChanged: (controller, progress) {
        if (!mounted) return;
        setState(() {
          _progress = progress / 100;
          _isLoading = progress < 100;
        });
      },
      onDownloadStartRequest: (controller, request) async {
        final webUri = request.url;
        final uri = Uri.parse(webUri.toString());

        final choice = await _showDownloadChoiceDialog(
          context,
          suggestedName: request.suggestedFilename,
          url: webUri.toString(),
        );
        if (choice == _MarketplaceDownloadChoice.cancel || !mounted) return;

        await _handleDownload(
          uri: uri,
          suggestedName: request.suggestedFilename,
          autoInstall: choice == _MarketplaceDownloadChoice.downloadAndInstall,
        );
      },
    );
  }

  Future<void> _loadUri(WebUri uri) async {
    if (_isDesktop) {
      await _inAppWebViewController?.loadUrl(urlRequest: URLRequest(url: uri));
    }
  }

  Future<void> _handleBackNavigation() async {
    if (_isDesktop) {
      if (await _inAppWebViewController?.canGoBack() ?? false) {
        await _inAppWebViewController?.goBack();
      }
    }
  }

  Future<void> _handleForwardNavigation() async {
    if (_isDesktop) {
      if (await _inAppWebViewController?.canGoForward() ?? false) {
        await _inAppWebViewController?.goForward();
      }
    }
  }

  Future<void> _handleReload() async {
    if (_isDesktop) {
      await _inAppWebViewController?.reload();
    }
  }

  Future<void> _handleHomeNavigation() async {
    await _loadUri(_homeUri);
  }

  void _performSearch(String query) {
    if (!_isWebViewSupported) {
      return;
    }
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      _loadUri(_homeUri);
      return;
    }

    final searchUri = WebUri(
      'https://gamebanana.com/search?_type=Mods&game=19567&query=${Uri.encodeComponent(trimmed)}',
    );
    _loadUri(searchUri);
  }

  Future<_MarketplaceDownloadChoice> _showDownloadChoiceDialog(
    BuildContext context, {
    required String url,
    String? suggestedName,
  }) async {
    final filename = suggestedName ?? path.basename(Uri.parse(url).path);
    return await showDialog<_MarketplaceDownloadChoice>(
          context: context,
          builder: (context) {
            return AlertDialog(
              title: Text(loc.t('marketplace.download_title')),
              content: Text(
                loc.t(
                  'marketplace.download_message',
                  params: {
                    'filename': filename.isEmpty
                        ? loc.t('marketplace.unknown_file')
                        : filename,
                  },
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () =>
                      Navigator.pop(context, _MarketplaceDownloadChoice.cancel),
                  child: Text(loc.t('marketplace.download_cancel')),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(
                    context,
                    _MarketplaceDownloadChoice.downloadOnly,
                  ),
                  child: Text(loc.t('marketplace.download_only')),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(
                    context,
                    _MarketplaceDownloadChoice.downloadAndInstall,
                  ),
                  child: Text(loc.t('marketplace.download_install')),
                ),
              ],
            );
          },
        ) ??
        _MarketplaceDownloadChoice.cancel;
  }

  Future<void> _handleDownload({
    required Uri uri,
    String? suggestedName,
    required bool autoInstall,
  }) async {
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    final errorColor = Theme.of(context).colorScheme.error;

    final handle = ref.read(downloadServiceProvider).start(
          DownloadRequest(url: uri, suggestedFilename: suggestedName),
        );

    final progressNotifier = ValueNotifier<DownloadProgress>(
      const DownloadProgress(state: DownloadState.connecting),
    );
    final progressSub = handle.progress.listen((p) => progressNotifier.value = p);

    // One guarded close for every exit path. Previously the dialog future was
    // never awaited before the download began, and three separate places popped
    // the root navigator — so a fast failure could pop a route that wasn't ours.
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
          onCancel: () {
            // An explicit cancel means "and don't leave junk behind" — keeping
            // several hundred MB of partial would be surprising here.
            unawaited(handle.cancel(deletePartial: true));
          },
        ),
      ),
    );

    try {
      final result = await handle.done;
      closeDialog();
      if (!mounted) return;

      if (!autoInstall) {
        // Nothing to move: the archive already downloaded straight into
        // <appData>/downloads.
        scaffoldMessenger.showSnackBar(
          SnackBar(
            content: Text(
              loc.t('marketplace.download_saved',
                  params: {'path': result.file.path}),
            ),
          ),
        );
        return;
      }

      final installResult = await _installArchive(
        result.file,
        knownMd5: result.md5,
        provenance: OriginProvenance.downloaded,
      );
      if (!mounted) return;
      showInstallResult(context, installResult);
    } on DownloadCancelledException {
      // Not an error — the user asked for this. Say so quietly and move on.
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

  Future<InstallResult> _installArchive(
    File archiveFile, {
    String? knownMd5,
    required OriginProvenance provenance,
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
      final combine = plan.combine;
      final combinedName = plan.combinedName;

      // Every folder here came out of the same archive, so one seed covers all
      // of them. `archiveMd5` is null when hashing failed — null-or-exact, and
      // a miss simply costs us the fast path later.
      final seed = ModOriginSeed(
        provenance: provenance,
        archiveMd5: extractionResult.archiveMd5,
      );

      final ModManagerService modManager =
          await ApiService.getModManagerService();
      final (importedMods, autoTags) = combine
          ? await modManager.importCombinedMod(
              directoriesToImport,
              combinedName,
              detectionHint: archiveBaseName,
              origin: seed,
            )
          : await modManager.importMods(
              directoriesToImport,
              detectionHints: {
                for (final dir in directoriesToImport) dir: archiveBaseName,
              },
              originSeeds: {
                for (final dir in directoriesToImport) dir: seed,
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
