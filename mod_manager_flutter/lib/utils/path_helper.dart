import 'dart:io';
import 'package:path/path.dart' as path;

/// Helper class to get correct paths for assets depending on the environment
class PathHelper {
  static String? _modImagesPath;
  static String? _appDataPath;

  /// Get the path for application data directory
  /// Platform-aware: uses APPDATA on Windows, XDG on Linux
  static String getAppDataPath() {
    if (_appDataPath != null) {
      return _appDataPath!;
    }

    if (Platform.isWindows) {
      // Windows: %APPDATA%\zzz-mod-manager
      final appData = Platform.environment['APPDATA'];
      if (appData != null) {
        _appDataPath = path.join(appData, 'zzz-mod-manager');
      } else {
        // Fallback на USERPROFILE\AppData\Roaming
        final userProfile = Platform.environment['USERPROFILE'];
        if (userProfile != null) {
          _appDataPath = path.join(userProfile, 'AppData', 'Roaming', 'zzz-mod-manager');
        } else {
          throw Exception('Cannot find Windows user directory');
        }
      }
    } else {
      // Linux: ~/.local/share/zzz-mod-manager
      final homeDir = Platform.environment['HOME'];
      if (homeDir != null) {
        final xdgDataHome = Platform.environment['XDG_DATA_HOME'] ?? 
                            path.join(homeDir, '.local', 'share');
        _appDataPath = path.join(xdgDataHome, 'zzz-mod-manager');
      } else {
        throw Exception('Cannot find Linux home directory');
      }
    }

    return _appDataPath!;
  }

  /// **Legacy**, and read by exactly one thing: the migration that pulls a
  /// pre-sidecar image into the mod folder it belongs to
  /// (`ModMetadataRepository.loadOrMigrate`). Never written to.
  ///
  ///   Windows: `%APPDATA%\zzz-mod-manager\mod_images`
  ///   Linux:   `~/.local/share/zzz-mod-manager/mod_images`
  ///
  /// The directory empties itself as mods migrate — the source is deleted once
  /// the sidecar naming the copy is written, and `sweepLegacyImages` clears
  /// what no mod can reach. Nothing recreates it.
  static String getModImagesPath() {
    if (_modImagesPath != null) {
      return _modImagesPath!;
    }

    try {
      _modImagesPath = path.join(getAppDataPath(), 'mod_images');
    } catch (e) {
      // Fallback for development (relative to current directory)
      final possiblePaths = [
        path.join(Directory.current.path, '..', 'assets', 'mod_images'),
        path.join(Directory.current.path, 'assets', 'mod_images'),
        path.join(Directory.current.path, '..', '..', 'assets', 'mod_images'),
      ];

      for (final possiblePath in possiblePaths) {
        final dir = Directory(possiblePath);
        if (dir.existsSync()) {
          _modImagesPath = possiblePath;
          return _modImagesPath!;
        }
      }
      
      // Last resort fallback
      _modImagesPath = path.join(Directory.current.path, '..', 'assets', 'mod_images');
    }

    return _modImagesPath!;
  }

  /// Where downloaded mod archives land.
  ///
  ///   Windows: `%APPDATA%\zzz-mod-manager\downloads`
  ///   Linux:   `~/.local/share/zzz-mod-manager/downloads`
  ///
  /// Every incoming archive goes here regardless of how it arrived, and is
  /// deleted once it has been extracted successfully — the archive is a
  /// throwaway intermediate, not something the user is meant to manage. Not
  /// user-configurable; add a config key only if it's actually asked for.
  static String getDownloadsPath() => path.join(getAppDataPath(), 'downloads');

  /// Where this run's log file is written, alongside the last six.
  ///
  ///   Windows: `%APPDATA%\zzz-mod-manager\logs`
  ///   Linux:   `~/.local/share/zzz-mod-manager/logs`
  ///
  /// A directory of its own rather than a single file beside `config.json`,
  /// because the user is invited to open it: "the log from the run where it
  /// broke" has to be one file they can pick out and attach, and the folder is
  /// what the Settings button opens.
  static String getLogsPath() => path.join(getAppDataPath(), 'logs');

  /// Ensure the downloads directory exists.
  static Future<void> ensureDownloadsDirectoryExists() async {
    final dir = Directory(getDownloadsPath());
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
  }

  /// Reset cached paths (useful for testing)
  static void resetCache() {
    _modImagesPath = null;
    _appDataPath = null;
  }
}
