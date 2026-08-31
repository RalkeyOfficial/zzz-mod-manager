import 'dart:io';

import 'package:path/path.dart' as path;

import '../core/constants.dart';
import 'ini_resources.dart';

/// One walk of a mod-shaped folder, in the spelling the pure units compare in.
///
/// The three decision units that read a folder — patch detection, the
/// stale-`.ini` rule and the update layout — are all pure and take sets of
/// normalised relative paths. This is the single place that produces them, so
/// there is one definition of "what is in this folder" rather than three
/// slightly different walks.
///
/// **`.zzz-mod-manager/` is excluded throughout.** It is ours, not the mod's; a
/// sidecar image counted as a shipped resource would make a patch look complete,
/// and a sidecar carried into a snapshot comparison would make every folder look
/// changed.
class FolderContents {
  const FolderContents({
    this.files = const <String>{},
    this.directories = const <String>{},
    this.iniPaths = const <String>{},
    this.iniContents = const <String, String>{},
    this.actualPaths = const <String, String>{},
  });

  static const FolderContents empty = FolderContents();

  /// Every file, relative to the folder root, `/`-separated and lower-cased.
  final Set<String> files;

  /// Every directory, same spelling.
  final Set<String> directories;

  /// The subset of [files] ending in `.ini`.
  final Set<String> iniPaths;

  /// Each `.ini`'s text, keyed the same way. Read eagerly because they are
  /// kilobytes and every caller needs all of them.
  final Map<String, String> iniContents;

  /// Normalised path → **the path as it is actually spelled on disk**.
  ///
  /// Every other set here is lower-cased, because 3DMigoto is case-insensitive
  /// and comparison has to be. That spelling is correct for comparing and
  /// **wrong for everything else**: a lower-cased path handed to `File` does not
  /// open `Ellen.ini` on Linux, and shown to a user it names a file they do not
  /// have.
  ///
  /// This is not theoretical. Mod authors ship `Ellen.ini`, `Miyabi.ini`,
  /// `MasterNico.ini`; all-lower-case is the rare spelling. Deleting a stale
  /// `.ini` through the normalised path silently deleted nothing — `exists()`
  /// answered false, the loop reported nothing removed, and the user was left
  /// with the two live `.ini` files the whole rule exists to prevent.
  ///
  /// So: **compare with the key, touch the filesystem with the value.**
  final Map<String, String> actualPaths;

  /// The on-disk spelling of [normalised], or [normalised] itself when the walk
  /// never saw it — a caller asking about a path from the *other* side of a
  /// comparison, where falling back is better than throwing.
  String onDisk(String normalised) => actualPaths[normalised] ?? normalised;

  bool get hasIni => iniPaths.isNotEmpty;

  /// The references those `.ini` files declare — computed once here so callers
  /// don't each re-parse.
  IniReferences get references => collectIniReferences(iniContents);

  /// Every path prefixed with [prefix], for a combined install whose folders
  /// live in subdirectories of the mod folder.
  ///
  /// The two spellings are prefixed differently on purpose: the comparison keys
  /// take the normalised prefix, while [actualPaths] takes [prefix] verbatim —
  /// it is the subfolder name the *install* created, and that is the name on
  /// disk.
  FolderContents underPrefix(String prefix) {
    if (prefix.isEmpty) return this;
    final key = normalizeIniPath(prefix);
    String at(String value) => '$key/$value';
    return FolderContents(
      files: {for (final file in files) at(file)},
      directories: {key, for (final dir in directories) at(dir)},
      iniPaths: {for (final ini in iniPaths) at(ini)},
      iniContents: {
        for (final entry in iniContents.entries) at(entry.key): entry.value,
      },
      actualPaths: {
        for (final entry in actualPaths.entries)
          at(entry.key): '$prefix/${entry.value}',
      },
    );
  }

  /// This walk **with [paths] discounted**, as though those files were not in
  /// the folder.
  ///
  /// For judging one download in a folder that holds two: the patch's files
  /// belong to neither side of an update to the base — they are going back on
  /// top afterwards — and left in, they make the base's update look like it is
  /// leaving `.ini` files behind that are not its own.
  ///
  /// Takes either spelling. A caller holds the on-disk one, because that is what
  /// a record stores and what opens a file.
  FolderContents without(Iterable<String> paths) {
    if (paths.isEmpty) return this;
    final drop = {for (final path in paths) normalizeIniPath(path)};
    bool keep(String key) => !drop.contains(key);
    return FolderContents(
      files: {for (final file in files) if (keep(file)) file},
      directories: directories,
      iniPaths: {for (final ini in iniPaths) if (keep(ini)) ini},
      iniContents: {
        for (final entry in iniContents.entries)
          if (keep(entry.key)) entry.key: entry.value,
      },
      actualPaths: {
        for (final entry in actualPaths.entries)
          if (keep(entry.key)) entry.key: entry.value,
      },
    );
  }

  /// Merges two walks — the several folders one combined install laid down.
  FolderContents merge(FolderContents other) => FolderContents(
        files: {...files, ...other.files},
        directories: {...directories, ...other.directories},
        iniPaths: {...iniPaths, ...other.iniPaths},
        iniContents: {...iniContents, ...other.iniContents},
        actualPaths: {...actualPaths, ...other.actualPaths},
      );
}

/// Skip an `.ini` larger than this rather than reading it.
///
/// Mod `.ini` files are a few kilobytes. Something a thousand times that is not
/// one, and reading it would only add unresolvable noise to the reference set —
/// the safe direction, since an unread `.ini` contributes no *missing* files
/// either.
const int _maxIniBytes = 2 * 1024 * 1024;

/// Walks [directory], returning nothing rather than throwing on any failure —
/// an unreadable folder must not take down the update flow that called it.
Future<FolderContents> readFolderContents(Directory directory) async {
  try {
    if (!await directory.exists()) return FolderContents.empty;

    final files = <String>{};
    final directories = <String>{};
    final iniPaths = <String>{};
    final iniContents = <String, String>{};
    final actualPaths = <String, String>{};

    await for (final entity
        in directory.list(recursive: true, followLinks: false)) {
      // Captured before normalising: this is the only moment the real spelling
      // is in hand, and `File` needs it. See [FolderContents.actualPaths].
      final onDisk =
          path.relative(entity.path, from: directory.path).replaceAll(r'\', '/');
      final relative = normalizeIniPath(onDisk);
      if (relative == '.' || relative.isEmpty) continue;
      if (_isOurs(relative)) continue;
      actualPaths[relative] = onDisk;

      if (entity is Directory) {
        directories.add(relative);
      } else if (entity is File) {
        files.add(relative);
        if (!relative.endsWith('.ini')) continue;
        iniPaths.add(relative);
        try {
          if (await entity.length() > _maxIniBytes) continue;
          iniContents[relative] = await entity.readAsString();
        } catch (_) {
          // Unreadable or not text — recorded as a file, contributing no
          // references. Silence here is the safe direction.
        }
      }
    }

    return FolderContents(
      files: files,
      directories: directories,
      iniPaths: iniPaths,
      iniContents: iniContents,
      actualPaths: actualPaths,
    );
  } catch (_) {
    return FolderContents.empty;
  }
}

final String _metadataDir = AppConstants.modMetadataDirName.toLowerCase();

bool _isOurs(String relative) =>
    relative == _metadataDir || relative.startsWith('$_metadataDir/');
