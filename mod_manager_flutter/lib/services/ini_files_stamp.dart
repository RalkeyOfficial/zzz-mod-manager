import 'dart:io';

import 'package:path/path.dart' as p;

import 'ini_parser_service.dart';
import 'log/logger.dart';

final Logger _log = Logger('ini');

/// One `.ini` file as the stamp sees it.
typedef IniFileStat = ({String relative, int size, DateTime modified, DateTime changed});

/// The `.ini` files ZZMI loads from one mod folder, as they are on disk: each
/// one's path inside the folder, size, modification time and status-change
/// time, in [IniParserService.findIniFiles] order.
///
/// Two stamps are compared only for equality, never for which is newer: a
/// Restore or an archive extraction puts back old modification times.
class IniFilesStamp {
  IniFilesStamp._(this._modPath, this.readAt, this.paths, this.files);

  final String _modPath;

  /// When the folder was read, taken before the listing.
  final DateTime readAt;

  /// The full path of each file in [files], in the same order, so the files can be parsed without listing the
  /// folder again.
  final List<String> paths;

  final List<IniFileStat> files;

  /// How close to [readAt] a modification time must be for the file to count
  /// as possibly still changing. FAT and exFAT keep modification times to 2
  /// seconds, so a same-size edit inside that window can leave every field of
  /// the stamp as it was.
  static const settleWindow = Duration(seconds: 2);

  /// Reads the stamp of [modPath], or null when the folder is missing or a
  /// file in it cannot be listed or read, as on an unmounted drive. A folder
  /// that can't be read logs a warning the first time only.
  static Future<IniFilesStamp?> take(String modPath) async {
    final readAt = DateTime.now();
    try {
      return await _stat(modPath, readAt, await IniParserService.listLoadedIniFiles(modPath));
    } on PathNotFoundException {
      return null;
    } on FileSystemException catch (error) {
      _warnUnreadable(modPath, error);
      return null;
    }
  }

  /// Folders already warned about this session. A stamp is taken on every
  /// return to the window, and a folder that can't be read stays so.
  static final Set<String> _warned = {};

  static void _warnUnreadable(String folder, FileSystemException error) {
    if (!_warned.add(folder)) return;
    _log.warning('could not read the .ini files of a folder', error: error, fields: {'folder': folder});
  }

  /// The stamp of the same files, read again without listing the folder. A file
  /// added since is not in it; the next [take] finds it.
  Future<IniFilesStamp?> restat() async {
    final readAt = DateTime.now();
    try {
      return await _stat(_modPath, readAt, paths);
    } on FileSystemException catch (error) {
      _warnUnreadable(_modPath, error);
      return null;
    }
  }

  /// Null when one of [paths] is gone.
  static Future<IniFilesStamp?> _stat(String modPath, DateTime readAt, List<String> paths) async {
    final files = <IniFileStat>[];
    for (final file in paths) {
      final stat = await File(file).stat();
      if (stat.type == FileSystemEntityType.notFound) return null;
      files.add((
        relative: p.split(p.relative(file, from: modPath)).join('/'),
        size: stat.size,
        modified: stat.modified,
        changed: stat.changed,
      ));
    }
    return IniFilesStamp._(modPath, readAt, paths, files);
  }

  /// Whether no file was modified within [settleWindow] of [readAt]. A stamp
  /// that is not settled cannot vouch for what was parsed under it.
  bool get settled => files.every(
        (file) => readAt.difference(file.modified).abs() >= settleWindow,
      );

  /// Whether [other] describes the same files, ignoring when each was read.
  bool matches(IniFilesStamp other) {
    if (files.length != other.files.length) return false;
    for (var i = 0; i < files.length; i++) {
      if (files[i] != other.files[i]) return false;
    }
    return true;
  }
}
