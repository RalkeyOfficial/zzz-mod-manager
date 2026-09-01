import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:url_launcher/url_launcher.dart';
import '../utils/process_probe.dart';
import 'log/logger.dart';
import 'log/system_report.dart';
import 'platform_service.dart';

final Logger _log = Logger('platform');
final Logger _files = Logger('fileops');

/// Linux-специфічна реалізація PlatformService
class LinuxPlatformService implements PlatformService {
  @override
  Future<bool> createModLink(String sourcePath, String linkPath) async {
    try {
      // На Linux використовуємо звичайні symbolic links
      final link = Link(linkPath);
      
      // Видаляємо якщо вже існує
      if (await link.exists() || await FileSystemEntity.isLink(linkPath)) {
        await removeModLink(linkPath);
      }
      
      await link.create(sourcePath, recursive: false);
      _files.info('link created', fields: {
        'kind': 'symlink',
        'link': linkPath,
        'target': sourcePath,
      });
      return true;
    } catch (error, stack) {
      _files.error('link failed', error: error, stack: stack, fields: {
        'kind': 'symlink',
        'link': linkPath,
        'target': sourcePath,
      });
      return false;
    }
  }
  
  @override
  Future<bool> removeModLink(String linkPath) async {
    try {
      final isLink = await FileSystemEntity.isLink(linkPath);
      if (!isLink) {
        // Refused rather than failed: deleting a real folder because it was
        // mistaken for a link is the one outcome this app must never have.
        _files.warning('not a link, left alone', fields: {'path': linkPath});
        return false;
      }

      await Link(linkPath).delete();
      _files.info('link removed', fields: {'link': linkPath});
      return true;
    } catch (error, stack) {
      _files.error('link removal failed',
          error: error, stack: stack, fields: {'link': linkPath});
      return false;
    }
  }
  
  @override
  Future<bool> isModLink(String linkPath) async {
    try {
      return await FileSystemEntity.isLink(linkPath);
    } catch (e) {
      return false;
    }
  }
  
  @override
  String getAppDataPath() {
    final homeDir = Platform.environment['HOME'];
    if (homeDir == null) {
      throw Exception('HOME environment variable not found');
    }
    
    // Використовуємо XDG Base Directory Specification
    final xdgDataHome = Platform.environment['XDG_DATA_HOME'] ?? 
                        path.join(homeDir, '.local', 'share');
    
    return path.join(xdgDataHome, 'zzz-mod-manager');
  }
  
  @override
  Future<List<String>> findGameProcesses() async {
    try {
      final result = await Process.run('ps', ['aux']);
      final processes = <String>[];
      
      if (result.exitCode == 0) {
        final lines = result.stdout.toString().split('\n');
        for (final line in lines) {
          if (line.toLowerCase().contains('zenless') || 
              line.toLowerCase().contains('zzz') ||
              line.contains('ZenlessZoneZero.exe')) {
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
    final sessionType = Platform.environment['XDG_SESSION_TYPE'];
    final waylandDisplay = Platform.environment['WAYLAND_DISPLAY'];
    final display = Platform.environment['DISPLAY'];
    
    if (sessionType == 'wayland' || waylandDisplay != null) {
      return 'wayland';
    } else if (display != null) {
      return 'x11';
    }
    
    return 'unknown';
  }
  
  @override
  Future<bool> openUrlInBrowser(String url) async {
    try {
      final uri = Uri.parse(url);
      final canOpen = await canLaunchUrl(uri);
      
      if (canOpen) {
        final result = await launchUrl(
          uri,
          mode: LaunchMode.externalApplication,
        );
        if (result) {
          _log.debug('browser opened', fields: {'via': 'url_launcher'});
          return true;
        }
      }

      final xdgResult = await Process.run('xdg-open', [url]);
      if (xdgResult.exitCode == 0) {
        _log.debug('browser opened', fields: {'via': 'xdg-open'});
        return true;
      }

      _log.warning('could not open browser', fields: {
        'url': url,
        'xdg_exit': xdgResult.exitCode,
      });
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
      final homeDir = Platform.environment['HOME'];
      if (homeDir == null) return null;
      
      final xdgDownloadDir = Platform.environment['XDG_DOWNLOAD_DIR'];
      if (xdgDownloadDir != null && xdgDownloadDir.isNotEmpty) {
        return xdgDownloadDir;
      }
      
      final downloadsDir = path.join(homeDir, 'Downloads');
      if (Directory(downloadsDir).existsSync()) {
        return downloadsDir;
      }
      
      final ukDownloadsDir = path.join(homeDir, 'Завантаження');
      if (Directory(ukDownloadsDir).existsSync()) {
        return ukDownloadsDir;
      }
      
      return downloadsDir;
    } catch (error, stack) {
      _log.warning('could not resolve the Downloads folder',
          error: error, stack: stack);
      return null;
    }
  }

  @override
  Future<bool> openFolderInFileManager(String folderPath) async {
    try {
      final result = await Process.run('xdg-open', [folderPath]);
      if (result.exitCode == 0) {
        _log.debug('folder opened', fields: {'path': folderPath});
        return true;
      }
      _log.warning('could not open folder', fields: {
        'path': folderPath,
        'exit': result.exitCode,
      });
      return false;
    } catch (error, stack) {
      _log.warning('could not open folder',
          error: error, stack: stack, fields: {'path': folderPath});
      return false;
    }
  }

  /// Channel backed by the GTK clipboard reader in the Linux runner
  /// (`linux/runner/my_application.cc`).
  static const MethodChannel _clipboardChannel =
      MethodChannel('mod_manager/clipboard');

  /// `7zzs` is 7-Zip's **statically linked** Linux build and what the portable
  /// tarball ships — the target distro's libstdc++ is unknown, and a dynamic
  /// binary is what breaks on the older ones a portable build exists to serve.
  /// `7zz` is the same thing dynamically linked. `7za` is deliberately absent:
  /// it is the reduced-format build and cannot read RAR.
  @override
  List<String> get bundledSevenZipNames => const ['7zzs', '7zz'];

  /// Distro from `/etc/os-release`, display server from the environment, and a
  /// version out of each tool that will give one.
  ///
  /// The kernel costs nothing: `Platform.operatingSystemVersion` on Linux is
  /// already the full `uname` string, so no process is spawned for it.
  @override
  Future<SystemReport> describeSystem({
    ProcessProbe probe = const ProcessProbe(),
  }) async {
    String? distro;
    String? distroId;
    try {
      final release = File('/etc/os-release');
      if (await release.exists()) {
        final fields = parseOsRelease(await release.readAsString());
        distro = fields['PRETTY_NAME'] ?? fields['NAME'];
        distroId = fields['ID'];
      }
    } catch (_) {
      // A distro that does not ship the file, or one we cannot read. The rest
      // of the header is still worth having.
    }

    return SystemReport(
      os: OsDescription(
        name: Platform.operatingSystem,
        version: Platform.operatingSystemVersion,
        distro: distro,
        distroId: distroId,
        displayServer: getDisplayServerType(),
        desktop: Platform.environment['XDG_CURRENT_DESKTOP'],
      ),
      tools: [
        await _describeTool('7-zip', const ['7z', '7za', '7zr'], probe,
            versionArguments: const []),
        // 7-Zip alone: it is the only external tool the app runs. `xdotool`,
        // `ydotool` and `wmctrl` were probed for years for a mod-reload feature
        // that no longer exists, which put `missing` warnings in every log that
        // read like a cause and were not one.
      ],
    );
  }

  /// Looks for each of [commands] on `PATH`, then asks the first one it finds
  /// for a version.
  ///
  /// `7z` with no arguments prints its banner and **exits non-zero** on some
  /// builds, so the exit code is ignored and only the output is read — the
  /// question here is "what version", and a tool that answered it has answered
  /// it whatever it then returned.
  Future<ToolStatus> _describeTool(
    String name,
    List<String> commands,
    ProcessProbe probe, {
    List<String> versionArguments = const ['--version'],
  }) async {
    for (final command in commands) {
      final located = await probe.run('which', [command]);
      final path = located?.stdout.trim();
      if (located == null || located.exitCode != 0 || path == null || path.isEmpty) {
        continue;
      }
      final version = await probe.run(path, versionArguments);
      return ToolStatus(
        name: name,
        state: ToolState.present,
        path: path.split('\n').first.trim(),
        version: version == null ? null : parseVersionToken(version.output),
        note: 'system',
      );
    }
    return ToolStatus.missing(name);
  }

  /// `USER`, falling back to `LOGNAME` — the second is what a login shell sets
  /// and the first is what most desktop sessions set; a container or a systemd
  /// unit may set neither, hence nullable.
  @override
  String? get osUserName =>
      Platform.environment['USER'] ?? Platform.environment['LOGNAME'];

  @override
  String? get homeDirectoryPath => Platform.environment['HOME'];

  @override
  Future<String?> getClipboardHtml() async {
    // Read the clipboard's text/html target straight from the GTK clipboard
    // (the same way native apps do) — no external CLI tool required.
    try {
      final html =
          await _clipboardChannel.invokeMethod<String>('getClipboardHtml');
      if (html != null && html.trim().isNotEmpty) return html;
    } catch (error) {
      // Paste-as-markdown falls back to plain text; not worth a stack.
      _log.debug('no HTML on the clipboard', fields: {'reason': '$error'});
    }
    return null;
  }

}
