import 'dart:io';
import 'package:archive/archive.dart';
import 'package:path/path.dart' as path;

import 'archive_hash.dart';

class ArchiveExtractionResult {
  final bool success;
  final String? error;
  final List<String>? extractedFolders;

  /// md5 of the archive these folders came out of, when it could be computed.
  ///
  /// Carried here because this is the last moment it exists: the archive is
  /// deleted once extracted, and a zip cannot be reproduced byte-for-byte from
  /// its extracted contents. Recording it lets us later say *which* published
  /// file a local install came from — including for archives the user supplied
  /// by hand, which is otherwise unknowable.
  ///
  /// A **matching key only**, never an integrity or authenticity claim; see
  /// `services/archive_hash.dart`.
  final String? archiveMd5;

  const ArchiveExtractionResult({
    required this.success,
    this.error,
    this.extractedFolders,
    this.archiveMd5,
  });

  factory ArchiveExtractionResult.successResult(
    List<String> folders, {
    String? archiveMd5,
  }) =>
      ArchiveExtractionResult(
        success: true,
        extractedFolders: folders,
        archiveMd5: archiveMd5,
      );

  /// Deliberately carries no md5: a failed extraction installs nothing, so
  /// there is no sidecar for a hash to be attached to.
  factory ArchiveExtractionResult.failure(String error) =>
      ArchiveExtractionResult(
        success: false,
        error: error,
      );
}

class ArchiveService {
  static bool isArchiveFile(String filePath) {
    final extension = path.extension(filePath).toLowerCase();
    return extension == '.zip' || extension == '.rar' || extension == '.7z';
  }

  /// Whether [folderPath] contains a `.ini` file at any depth — the strongest
  /// signal that a folder is an actual mod rather than auxiliary content (a
  /// `previews`/images folder). Stops at the first match. Best-effort: any
  /// error is treated as "no .ini".
  static Future<bool> containsIniFile(String folderPath) async {
    try {
      final dir = Directory(folderPath);
      if (!await dir.exists()) return false;
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is File &&
            path.extension(entity.path).toLowerCase() == '.ini') {
          return true;
        }
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Returns the subset of [modNames] whose folder under [modsPath] contains no
  /// `.ini` anywhere — a strong sign the mod is incomplete (e.g. a broken
  /// multi-folder archive). Used by both import paths for a post-install warning.
  static Future<List<String>> modsWithoutIni(
    String modsPath,
    List<String> modNames,
  ) async {
    final missing = <String>[];
    for (final name in modNames) {
      if (!await containsIniFile(path.join(modsPath, name))) {
        missing.add(name);
      }
    }
    return missing;
  }

  /// Extracts [archiveFile] and reports the top-level folders to import.
  ///
  /// Also fingerprints the archive — see [ArchiveExtractionResult.archiveMd5].
  /// The hash is taken **here**, at the one point both format branches meet
  /// with the file still in hand: `_extractZip` already holds the whole archive
  /// in memory and would be the tempting place, but `_extractWith7Zip` shells
  /// out and rar/7z bytes never enter Dart, so hashing there would silently
  /// cover zips only.
  ///
  /// Pass [knownMd5] when the bytes were already hashed as they streamed past
  /// (the download path), to avoid re-reading a file that can reach 1.24 GB. It
  /// is trusted verbatim and never verified: there is nothing here to verify it
  /// against, and re-reading to "check" would defeat the point of passing it.
  static Future<ArchiveExtractionResult> extractArchive({
    required File archiveFile,
    Directory? destinationDir,
    String? knownMd5,
  }) async {
    try {
      print('ArchiveService: Розархівування ${archiveFile.path}');

      final tempExtractDir = destinationDir ??
          await Directory.systemTemp.createTemp('zzz_archive_extract_');

      final extension = path.extension(archiveFile.path).toLowerCase();
      bool isExtracted = false;
      String? extractionError;

      if (extension == '.zip') {
        print('ArchiveService: ZIP архів');
        isExtracted = await _extractZip(archiveFile, tempExtractDir);
      } else if (extension == '.rar' || extension == '.7z') {
        print('ArchiveService: RAR/7Z архів');
        final result = await _extractWith7Zip(archiveFile, tempExtractDir);
        isExtracted = result.success;
        extractionError = result.error;
      }

      if (!isExtracted) {
        final error = extractionError ?? 'Формат архіву не підтримується';
        print('ArchiveService: Помилка: $error');
        return ArchiveExtractionResult.failure(error);
      }

      // After the success check, so a failed extraction (e.g. no 7-Zip
      // installed) doesn't pay for a full read of a very large archive.
      // Extraction only reads the file, so it is still intact and hashable.
      final md5 = knownMd5 ?? await md5OfFile(archiveFile);

      final directories = await _prepareDirectoriesForImport(
        tempExtractDir,
        archiveFile,
      );

      if (directories.isEmpty) {
        print('ArchiveService: Архів порожній');
        return ArchiveExtractionResult.failure('Архів не містить папок модів');
      }

      print('ArchiveService: Знайдено ${directories.length} папок');
      return ArchiveExtractionResult.successResult(directories, archiveMd5: md5);
    } catch (e) {
      print('ArchiveService: Виняток: $e');
      return ArchiveExtractionResult.failure('Помилка розархівування: $e');
    }
  }

  static Future<bool> _extractZip(File archiveFile, Directory destination) async {
    try {
      print('ArchiveService: Читання ZIP файлу...');
      final bytes = await archiveFile.readAsBytes();
      print('ArchiveService: Прочитано ${bytes.length} bytes');

      print('ArchiveService: Декодування ZIP...');
      final archive = ZipDecoder().decodeBytes(bytes, verify: true);
      print('ArchiveService: ZIP містить ${archive.length} файлів');

      int extracted = 0;
      for (final file in archive) {
        final sanitizedPath = _sanitizeArchivePath(destination.path, file.name);
        if (sanitizedPath == null) {
          print('ArchiveService: Пропущено небезпечний шлях: ${file.name}');
          continue;
        }

        if (file.isFile) {
          final outFile = File(sanitizedPath);
          await outFile.create(recursive: true);
          await outFile.writeAsBytes(file.content as List<int>);
          extracted++;
        } else {
          final dir = Directory(sanitizedPath);
          if (!await dir.exists()) {
            await dir.create(recursive: true);
          }
        }
      }

      print('ArchiveService: ZIP успішно розархівовано, файлів: $extracted');
      return true;
    } catch (e) {
      print('ArchiveService: Помилка розархівування ZIP: $e');
      return false;
    }
  }

  static Future<_7ZipResult> _extractWith7Zip(
    File archiveFile,
    Directory destination,
  ) async {
    final sevenZipPath = await _locate7Zip();
    if (sevenZipPath == null) {
      return _7ZipResult(
        false,
        '7-Zip не знайдено. Встановіть 7-Zip для розпаковки RAR/7z.',
      );
    }

    print('ArchiveService: Використання 7-Zip: $sevenZipPath');

    final result = await Process.run(sevenZipPath, [
      'x',
      archiveFile.path,
      '-o${destination.path}',
      '-y',
    ]);

    if (result.exitCode != 0) {
      final errorOutput = result.stderr.toString().trim();
      print('ArchiveService: 7-Zip помилка: $errorOutput');
      return _7ZipResult(
        false,
        errorOutput.isNotEmpty ? errorOutput : 'Не вдалося розпакувати архів',
      );
    }

    print('ArchiveService: 7-Zip успішно розпакував');
    return const _7ZipResult(true);
  }

  static Future<String?> _locate7Zip() async {
    if (Platform.isWindows) {
      final whereResult = await Process.run('where', ['7z']);
      if (whereResult.exitCode == 0) {
        final lines = whereResult.stdout
            .toString()
            .split(RegExp(r'[\r\n]+'))
            .where((line) => line.trim().isNotEmpty);
        if (lines.isNotEmpty) {
          return lines.first.trim();
        }
      }

      final candidates = [
        path.join(
          Platform.environment['ProgramFiles'] ?? '',
          '7-Zip',
          '7z.exe',
        ),
        path.join(
          Platform.environment['ProgramFiles(x86)'] ?? '',
          '7-Zip',
          '7z.exe',
        ),
      ];

      for (final candidate in candidates) {
        if (candidate.trim().isEmpty) continue;
        final file = File(candidate);
        if (await file.exists()) {
          return file.path;
        }
      }
      return null;
    }

    if (Platform.isLinux || Platform.isMacOS) {
      final commands = ['7z', '7za', '7zr'];
      for (final command in commands) {
        try {
          final whichResult = await Process.run('which', [command]);
          if (whichResult.exitCode == 0) {
            final pathResult = whichResult.stdout
                .toString()
                .split(RegExp(r'[\r\n]+'))
                .firstWhere((line) => line.trim().isNotEmpty, orElse: () => '')
                .trim();
            if (pathResult.isNotEmpty) {
              return pathResult;
            }
          }
        } catch (_) {
          continue;
        }
      }
    }

    return null;
  }

  static Future<List<String>> _prepareDirectoriesForImport(
    Directory extractDir,
    File archiveFile,
  ) async {
    final entries = extractDir.listSync();
    final directories = <String>[];

    if (entries.isEmpty) {
      return directories;
    }

    final dirEntries = entries.whereType<Directory>().toList();

    // A `.ini` sitting directly at the archive root means the whole root IS one
    // mod (the sibling folders are that mod's resource folders — res/, buffer/,
    // textures/ — referenced by the .ini). Without this, an archive laid out as
    // `res/  buffer/  textures/  name.ini` would be treated as several unrelated
    // folders and the root .ini silently dropped.
    final hasRootIni = entries.whereType<File>().any(
      (f) => path.extension(f.path).toLowerCase() == '.ini',
    );

    // Wrap the whole root into a single mod folder when it is one mod: either a
    // .ini lives at the root (folders beside it are its resources), or there are
    // no subfolders at all (a flat pile of files). This keeps everything —
    // especially the root .ini — instead of returning bare subfolders.
    if (hasRootIni || dirEntries.isEmpty) {
      final baseName = path.basenameWithoutExtension(archiveFile.path);
      final wrapperDir = Directory(path.join(extractDir.path, baseName));
      await wrapperDir.create(recursive: true);

      for (final entity in entries) {
        // Guard the rare archive-name == folder-name collision: never move the
        // wrapper into itself; the other siblings just move into it.
        if (path.equals(entity.path, wrapperDir.path)) continue;
        final targetPath = path.join(
          wrapperDir.path,
          path.basename(entity.path),
        );
        if (entity is File) {
          await entity.copy(targetPath);
          await entity.delete();
        } else if (entity is Directory) {
          await Directory(entity.path).rename(targetPath);
        }
      }
      directories.add(wrapperDir.path);
      return directories;
    }

    // Otherwise the root is a container of independent mod folders.
    for (final dir in dirEntries) {
      directories.add(dir.path);
    }

    return directories;
  }

  static String? _sanitizeArchivePath(String base, String relativePath) {
    final normalized = path.normalize(relativePath);
    if (normalized.contains('..')) {
      return null;
    }
    final fullPath = path.join(base, normalized);
    if (!path.isWithin(base, fullPath)) {
      return null;
    }
    return fullPath;
  }
}

class _7ZipResult {
  final bool success;
  final String? error;

  const _7ZipResult(this.success, [this.error]);
}
