import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as path;
import '../core/constants.dart';
import '../models/mod_metadata.dart';
import 'log/logger.dart';

final Logger _log = Logger('metadata');

/// Reads and writes the per-mod metadata sidecar stored inside each mod folder
/// at `<mod>/.zzz-mod-manager/metadata.json`. All paths are based off the mod
/// folder so the metadata (and its images) travel with the mod.
class ModMetadataService {
  /// `<mod>/.zzz-mod-manager`
  String metadataDir(String modFolderPath) =>
      path.join(modFolderPath, AppConstants.modMetadataDirName);

  /// `<mod>/.zzz-mod-manager/metadata.json`
  String metadataFile(String modFolderPath) =>
      path.join(metadataDir(modFolderPath), AppConstants.modMetadataFileName);

  /// `<mod>/.zzz-mod-manager/images`
  String imagesDir(String modFolderPath) =>
      path.join(metadataDir(modFolderPath), AppConstants.modMetadataImagesDirName);

  /// Reads the sidecar. Returns null if it doesn't exist or can't be parsed.
  Future<ModMetadata?> read(String modFolderPath) async {
    try {
      final file = File(metadataFile(modFolderPath));
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return null;
      return ModMetadata.fromJson(decoded);
    } catch (e) {
      // Recoverable: the mod still works, it just loses its description and
      // tags until the sidecar is rewritten.
      _log.warning('could not read a sidecar',
          error: e, fields: {'mod': modFolderPath});
      return null;
    }
  }

  /// Writes the sidecar (creating the `.zzz-mod-manager` dir if needed).
  /// Best-effort: returns false instead of throwing (e.g. read-only folder).
  Future<bool> write(String modFolderPath, ModMetadata metadata) async {
    try {
      // Never recreate a mod folder that no longer exists — e.g. it was renamed
      // out from under a still-open edit dialog. `create(recursive: true)` below
      // would otherwise materialize the vanished folder holding only this
      // sidecar (the "ghost folder" bug).
      if (!await Directory(modFolderPath).exists()) return false;
      final dir = Directory(metadataDir(modFolderPath));
      if (!await dir.exists()) await dir.create(recursive: true);
      final file = File(metadataFile(modFolderPath));
      final json = const JsonEncoder.withIndent('  ').convert(metadata.toJson());
      await file.writeAsString(json);
      return true;
    } catch (e) {
      // An edit the user made is now lost, which is an error rather than a
      // warning however quietly it returns false.
      _log.error('could not write a sidecar',
          error: e, fields: {'mod': modFolderPath});
      return false;
    }
  }

  /// Copies/writes [bytes] into the mod's images dir under the next free
  /// `NN.<ext>` name and returns the path **relative to the mod folder root**
  /// (suitable for storing in [ModMetadata.images]). Returns null on failure.
  Future<String?> addImageBytes(
    String modFolderPath,
    List<int> bytes, {
    String extension = 'png',
  }) async {
    try {
      // Don't recreate a vanished mod folder (see write()).
      if (!await Directory(modFolderPath).exists()) return null;
      final dir = Directory(imagesDir(modFolderPath));
      if (!await dir.exists()) await dir.create(recursive: true);

      final fileName = '${_nextImageIndex(dir).toString().padLeft(2, '0')}.$extension';
      final dest = File(path.join(dir.path, fileName));
      await dest.writeAsBytes(bytes);
      return path.relative(dest.path, from: modFolderPath);
    } catch (e) {
      _log.error('could not save an image',
          error: e, fields: {'mod': modFolderPath});
      return null;
    }
  }

  /// Copies an existing image file into the mod's images dir, returning the
  /// path relative to the mod folder root. Returns null on failure.
  Future<String?> importImageFile(String modFolderPath, String sourcePath) async {
    try {
      // Don't recreate a vanished mod folder (see write()).
      if (!await Directory(modFolderPath).exists()) return null;
      final source = File(sourcePath);
      if (!await source.exists()) return null;
      final bytes = await source.readAsBytes();
      var ext = path.extension(sourcePath).replaceFirst('.', '').toLowerCase();
      if (ext.isEmpty) ext = 'png';
      return addImageBytes(modFolderPath, bytes, extension: ext);
    } catch (e) {
      _log.error('could not import an image',
          error: e, fields: {'mod': modFolderPath});
      return null;
    }
  }

  int _nextImageIndex(Directory imagesDir) {
    var max = 0;
    for (final entity in imagesDir.listSync()) {
      if (entity is File) {
        final base = path.basenameWithoutExtension(entity.path);
        final n = int.tryParse(base);
        if (n != null && n > max) max = n;
      }
    }
    return max + 1;
  }
}
