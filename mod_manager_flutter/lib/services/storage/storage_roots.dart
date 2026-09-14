import 'dart:io';

import 'package:path/path.dart' as path;

import '../../utils/path_helper.dart';

/// Every place this app puts bytes, in one object.
///
/// A value object rather than a set of static calls so a test can point the
/// whole scan at a temp directory. That is not a nicety: the reclaim below
/// **deletes** what these name, and a test that picked up the real roots would
/// sweep the developer's own downloads and `/tmp`.
///
/// The app-data children come from [PathHelper], which already owns each of
/// these names and is what every other consumer asks. Restating `'downloads'`
/// or `'backups'` here would be a second authority on a path, which is the way
/// two of them eventually disagree.
class StorageRoots {
  const StorageRoots({
    required this.appData,
    required this.downloads,
    required this.logs,
    required this.legacyImages,
    required this.backups,
    required this.temp,
    this.modsLibrary,
    this.currentLogFile,
  });

  /// The real ones. [modsPath] and [gameModsPath] come from config and are
  /// routinely empty — an unconfigured library is a normal state, not an error.
  factory StorageRoots.forApp({
    String? modsPath,
    String? currentLogFile,
    Directory? temp,
  }) {
    final appData = PathHelper.getAppDataPath();
    return StorageRoots(
      appData: Directory(appData),
      downloads: Directory(PathHelper.getDownloadsPath()),
      logs: Directory(PathHelper.getLogsPath()),
      legacyImages: Directory(path.join(appData, 'mod_images')),
      backups: Directory(path.join(appData, 'backups')),
      temp: temp ?? Directory.systemTemp,
      modsLibrary: _orNull(modsPath),
      currentLogFile: currentLogFile,
    );
  }

  final Directory appData;
  final Directory downloads;
  final Directory logs;

  /// `<appData>/mod_images`, written by no version since 2.0.0 and read only by
  /// the sidecar migration.
  final Directory legacyImages;

  final Directory backups;

  /// Where archive extraction unpacks. On most Linux desktops this is tmpfs,
  /// so what leaks here costs RAM rather than disk — which the page has to say
  /// rather than fold into a disk figure.
  final Directory temp;

  /// Null when no library is configured. Distinct from a configured path that
  /// does not exist, which the scanner reports differently.
  final Directory? modsLibrary;

  /// This run's log file, which the reclaim must never delete.
  final String? currentLogFile;

  static Directory? _orNull(String? value) =>
      (value == null || value.trim().isEmpty) ? null : Directory(value);
}
