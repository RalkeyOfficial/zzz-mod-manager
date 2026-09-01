import 'dart:io';
import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as path;
import 'package:win32/win32.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:pasteboard/pasteboard.dart';
import '../utils/process_probe.dart';
import 'log/logger.dart';
import 'log/system_report.dart';
import 'platform_service.dart';

/// Windows-специфічна реалізація PlatformService
/// The same two tags the Linux implementation uses, and the same event names
/// under them — so a Windows bug report and a Linux one are filtered the same
/// way, and only the `kind`/`tool` fields differ.
final Logger _log = Logger('platform');
final Logger _files = Logger('fileops');

class WindowsPlatformService implements PlatformService {
  
  /// **F10 goes to the game's window or nowhere.** There is no fallback to the
  /// foreground window: the app the user just clicked in *is* the mod manager,
  /// so a foreground press reloads nothing and cannot report a failure.
  ///
  /// **Not verified on Windows.** The reasoning below comes from how 3DMigoto
  /// reads its hotkeys, and matches the Linux behaviour that is verified; the
  /// win32 path itself has not been exercised on a Windows machine.
  @override
  Future<F10Result> sendF10ToGame() async {
    _log.debug('sending F10', fields: {'display': getDisplayServerType()});

    try {
      // Знаходимо вікно гри через FindWindow
      final windowNames = [
        'Zenless Zone Zero',
        'ZenlessZoneZero',
        'Zenless',
        'ZZZ'
      ];

      int hwnd = 0;
      for (final name in windowNames) {
        final namePtr = name.toNativeUtf16();
        try {
          hwnd = FindWindow(nullptr, namePtr);
          if (hwnd != 0) {
            _log.debug('found the game window',
                fields: {'match': name, 'window': hwnd});
            break;
          }
        } finally {
          calloc.free(namePtr);
        }
      }

      if (hwnd == 0) {
        // Not a warning: the ordinary reason for this is that the game is
        // closed.
        _log.info('no game window');
        return const F10Result.gameNotFound();
      }

      // Перевіряємо чи вікно видиме
      final isVisible = IsWindowVisible(hwnd);
      if (isVisible == FALSE) {
        _log.warning('F10 not sent', fields: {
          'reason': 'the game window is not visible',
          'window': hwnd,
        });
        return const F10Result.sendFailed('win32');
      }

      SetForegroundWindow(hwnd);
      await Future.delayed(const Duration(milliseconds: 100));

      // The activation is confirmed rather than assumed: Windows refuses
      // `SetForegroundWindow` from a process that does not currently own the
      // foreground, and says so only through this read.
      if (GetForegroundWindow() != hwnd) {
        _log.warning('F10 not sent', fields: {
          'reason': 'could not focus the game',
          'window': hwnd,
        });
        return const F10Result.sendFailed('win32');
      }

      if (!_pressF10()) {
        _log.warning('F10 not sent',
            fields: {'reason': 'SendInput rejected the key', 'window': hwnd});
        return const F10Result.sendFailed('win32');
      }

      _log.info('F10 sent', fields: {'tool': 'win32', 'window': hwnd});
      return const F10Result.sent('win32');
    } catch (error, stack) {
      _log.warning('F10 not sent',
          error: error, stack: stack, fields: {'tool': 'win32'});
      return const F10Result.sendFailed('win32');
    }
  }
  
  @override
  Future<bool> createModLink(String sourcePath, String linkPath) async {
    try {
      // Спочатку видаляємо якщо вже існує
      if (await Directory(linkPath).exists() || await File(linkPath).exists()) {
        await removeModLink(linkPath);
      }

      // Спроба 1: Звичайний symbolic link (потребує Developer Mode або прав адміна)
      try {
        final link = Link(linkPath);
        await link.create(sourcePath, recursive: false);
        _files.info('link created', fields: {
          'kind': 'symlink',
          'link': linkPath,
          'target': sourcePath,
        });
        return true;
      } catch (error) {
        // Expected without Developer Mode or admin rights, and the reason the
        // junction below exists — a warning rather than an error, because the
        // operation has not failed yet.
        _files.warning('symlink refused, falling back to a junction',
            error: error, fields: {'link': linkPath});
      }

      // Спроба 2: Directory Junction (не потребує прав адміна)
      final result = await Process.run(
        'cmd',
        ['/c', 'mklink', '/J', linkPath, sourcePath],
        runInShell: true,
      );

      if (result.exitCode == 0) {
        _files.info('link created', fields: {
          'kind': 'junction',
          'link': linkPath,
          'target': sourcePath,
        });
        return true;
      } else {
        _files.error('link failed', fields: {
          'kind': 'junction',
          'link': linkPath,
          'exit': result.exitCode,
          'stderr': result.stderr.toString().trim(),
        });
        return false;
      }
    } catch (error, stack) {
      _files.error('link failed', error: error, stack: stack, fields: {
        'link': linkPath,
        'target': sourcePath,
      });
      return false;
    }
  }
  
  @override
  Future<bool> removeModLink(String linkPath) async {
    try {
      // Перевіряємо чи це link/junction
      final isLink = await isModLink(linkPath);
      if (!isLink) {
        // Можливо це звичайна директорія, видаляємо її
        final dir = Directory(linkPath);
        if (await dir.exists()) {
          // Non-recursive on purpose: this succeeds only for an empty
          // directory, so a real mod folder mistaken for a link is refused by
          // the filesystem rather than deleted.
          await dir.delete(recursive: false);
          _files.info('empty directory removed', fields: {'path': linkPath});
          return true;
        }
        return false;
      }

      // Для junction/symlink використовуємо Link
      final link = Link(linkPath);
      if (await link.exists()) {
        await link.delete();
        _files.info('link removed', fields: {'link': linkPath});
        return true;
      }

      return false;
    } catch (error, stack) {
      _files.error('link removal failed',
          error: error, stack: stack, fields: {'link': linkPath});
      return false;
    }
  }
  
  @override
  Future<bool> isModLink(String linkPath) async {
    try {
      // Перевіряємо через FileSystemEntity.isLink
      final isLink = await FileSystemEntity.isLink(linkPath);
      if (isLink) return true;
      
      // Додатково перевіряємо через Windows API для junction
      return await _isJunction(linkPath);
    } catch (e) {
      return false;
    }
  }
  
  @override
  String getAppDataPath() {
    final appData = Platform.environment['APPDATA'];
    if (appData == null) {
      // Fallback на USERPROFILE\AppData\Roaming
      final userProfile = Platform.environment['USERPROFILE'];
      if (userProfile == null) {
        throw Exception('APPDATA and USERPROFILE environment variables not found');
      }
      return path.join(userProfile, 'AppData', 'Roaming', 'zzz-mod-manager');
    }
    
    return path.join(appData, 'zzz-mod-manager');
  }
  
  /// Records the request; the instructions themselves belong on screen.
  ///
  /// See the Linux implementation for the reasoning — twenty lines of setup
  /// help written to a console a packaged app does not have helped nobody.
  @override
  void showSetupInstructions() {
    _log.info('setup instructions requested', fields: {
      'display': getDisplayServerType(),
    });
  }

  @override
  Future<bool> checkDependencies() async {
    // На Windows всі необхідні API вже є в системі
    try {
      final hwnd = GetForegroundWindow();
      if (hwnd != 0) {
        _log.debug('dependency present', fields: {'tool': 'win32'});
        return true;
      }
    } catch (error, stack) {
      _log.error('the Windows API is not answering',
          error: error, stack: stack);
      return false;
    }

    // No foreground window is not a missing dependency — nothing was focused.
    _log.debug('dependency present',
        fields: {'tool': 'win32', 'foreground': 'none'});
    return true;
  }
  
  @override
  Future<List<String>> findGameProcesses() async {
    try {
      // Використовуємо tasklist для пошуку процесів
      final result = await Process.run('tasklist', ['/FI', 'IMAGENAME eq ZenlessZoneZero.exe']);
      final processes = <String>[];
      
      if (result.exitCode == 0) {
        final lines = result.stdout.toString().split('\n');
        for (final line in lines) {
          if (line.toLowerCase().contains('zenless') || 
              line.toLowerCase().contains('zzz')) {
            processes.add(line.trim());
          }
        }
      }
      
      _log.debug('game processes', fields: {'found': processes.length});
      return processes;
    } catch (error, stack) {
      _log.warning('could not list processes', error: error, stack: stack);
      return [];
    }
  }
  
  @override
  String getDisplayServerType() {
    // Windows завжди використовує DWM (Desktop Window Manager)
    return 'windows-dwm';
  }
  
  @override
  Future<bool> openUrlInBrowser(String url) async {
    try {
      final uri = Uri.parse(url);
      final result = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (result) {
        _log.debug('browser opened', fields: {'via': 'url_launcher'});
        return true;
      }

      _log.warning('could not open browser', fields: {'url': url});
      return false;
    } catch (error, stack) {
      _log.warning('could not open browser',
          error: error, stack: stack, fields: {'url': url});
      return false;
    }
  }
  
  @override
  String? getSystemDownloadsPath() {
    try {
      final userProfile = Platform.environment['USERPROFILE'];
      if (userProfile == null) return null;
      
      return path.join(userProfile, 'Downloads');
    } catch (error, stack) {
      _log.warning('could not resolve the Downloads folder',
          error: error, stack: stack);
      return null;
    }
  }

  @override
  Future<bool> openFolderInFileManager(String folderPath) async {
    try {
      // explorer.exe returns a non-zero exit code even on success, so treat a
      // clean launch as success rather than checking the exit code.
      await Process.start('explorer', [folderPath]);
      _log.debug('folder opened', fields: {'path': folderPath});
      return true;
    } catch (error, stack) {
      _log.warning('could not open folder',
          error: error, stack: stack, fields: {'path': folderPath});
      return false;
    }
  }

  /// **`7z.exe`, which needs `7z.dll` beside it** — deliberately not `7za.exe`.
  /// 7-Zip's own readme calls that one "reduced formats support", and the
  /// formats it drops include RAR, which is the whole reason for bundling
  /// anything. `7zz.exe` is the newer single-file equivalent if it ever ships.
  @override
  List<String> get bundledSevenZipNames => const ['7z.exe', '7zz.exe'];

  /// Windows has no distro and no display server, and its F10 path is win32
  /// rather than an external tool — so the X11/Wayland helpers are reported
  /// **not applicable** rather than missing. A Windows log that said
  /// `xdotool: missing` would send every reader down a dead end.
  @override
  Future<SystemReport> describeSystem({
    ProcessProbe probe = const ProcessProbe(),
  }) async {
    return SystemReport(
      os: OsDescription(
        name: Platform.operatingSystem,
        // Already the build string on Windows; no `wmic`, no `systeminfo`.
        version: Platform.operatingSystemVersion,
        displayServer: getDisplayServerType(),
      ),
      tools: [
        await _describeSevenZip(probe),
        const ToolStatus.notApplicable('xdotool', note: 'win32 sends F10'),
        const ToolStatus.notApplicable('ydotool', note: 'win32 sends F10'),
      ],
    );
  }

  /// `where 7z` first, then the install locations the extractor already knows
  /// about, so the header agrees with what an extraction would actually use.
  Future<ToolStatus> _describeSevenZip(ProcessProbe probe) async {
    String? found;
    final located = await probe.run('where', ['7z']);
    if (located != null && located.exitCode == 0) {
      final first = located.stdout
          .split(RegExp(r'[\r\n]+'))
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty);
      if (first.isNotEmpty) found = first.first;
    }

    found ??= await _firstExisting([
      for (final root in [
        Platform.environment['ProgramFiles'],
        Platform.environment['ProgramFiles(x86)'],
      ])
        if (root != null && root.isNotEmpty) '$root\\7-Zip\\7z.exe',
    ]);

    if (found == null) return const ToolStatus.missing('7-zip');

    // No arguments: `7z` prints its banner and may exit non-zero doing it.
    final version = await probe.run(found, const []);
    return ToolStatus(
      name: '7-zip',
      state: ToolState.present,
      path: found,
      version: version == null ? null : parseVersionToken(version.output),
      note: 'system',
    );
  }

  Future<String?> _firstExisting(List<String> candidates) async {
    for (final candidate in candidates) {
      try {
        if (await File(candidate).exists()) return candidate;
      } catch (_) {
        // An unreadable drive is not a reason to fail a header.
      }
    }
    return null;
  }

  @override
  String? get osUserName => Platform.environment['USERNAME'];

  /// `USERPROFILE` — `C:\Users\<name>`, the prefix of both the library paths a
  /// user picks and `%APPDATA%`, which is why censoring it covers nearly every
  /// path that reaches a log line.
  @override
  String? get homeDirectoryPath => Platform.environment['USERPROFILE'];

  @override
  Future<String?> getClipboardHtml() async {
    try {
      final raw = await Pasteboard.html;
      if (raw == null || raw.isEmpty) return null;
      return _extractCfHtmlFragment(raw);
    } catch (error) {
      // Paste-as-markdown falls back to plain text; not worth a stack.
      _log.debug('no HTML on the clipboard', fields: {'reason': '$error'});
      return null;
    }
  }

  /// The Windows "HTML Format" clipboard payload wraps the markup in a header
  /// (Version/StartHTML/StartFragment/…). Return just the fragment markup so
  /// the HTML→markdown converter doesn't choke on the header lines.
  String? _extractCfHtmlFragment(String cfHtml) {
    const startMarker = '<!--StartFragment-->';
    const endMarker = '<!--EndFragment-->';
    final start = cfHtml.indexOf(startMarker);
    final end = cfHtml.indexOf(endMarker);
    if (start != -1 && end != -1 && end > start) {
      final frag = cfHtml.substring(start + startMarker.length, end).trim();
      if (frag.isNotEmpty) return frag;
    }
    // No fragment markers — drop the header by starting at the first tag.
    final firstTag = cfHtml.indexOf('<');
    if (firstTag != -1) {
      final body = cfHtml.substring(firstTag).trim();
      if (body.isNotEmpty) return body;
    }
    return null;
  }

  // ===== Приватні методи =====
  
  /// Presses and releases F10 as though it came from the keyboard.
  ///
  /// **`SendInput`, deliberately not `PostMessage`.** 3DMigoto polls
  /// `GetAsyncKeyState` from its present hook to read hotkeys, and that reports
  /// the *keyboard state* — which a posted `WM_KEYDOWN` never touches. A posted
  /// message is delivered to the window's queue, returns success, and reloads
  /// nothing. `SendInput` goes through the same path a real key does, which is
  /// why the window has to be in the foreground first.
  bool _pressF10() {
    final inputs = calloc<INPUT>(2);
    try {
      inputs[0].type = INPUT_KEYBOARD;
      inputs[0].ki.wVk = VK_F10;
      inputs[1].type = INPUT_KEYBOARD;
      inputs[1].ki.wVk = VK_F10;
      inputs[1].ki.dwFlags = KEYEVENTF_KEYUP;

      final accepted = SendInput(2, inputs, sizeOf<INPUT>());
      return accepted == 2;
    } finally {
      calloc.free(inputs);
    }
  }


  Future<bool> _isJunction(String dirPath) async {
    try {
      // Використовуємо cmd для перевірки junction
      final result = await Process.run(
        'cmd',
        ['/c', 'dir', '/AL', dirPath],
        runInShell: true,
      );
      
      // Якщо це junction, у виводі буде "<JUNCTION>"
      return result.stdout.toString().contains('JUNCTION');
    } catch (e) {
      return false;
    }
  }
}
