import 'dart:io';
import 'package:path/path.dart' as path;
import '../models/character_info.dart';
import '../models/mod_metadata.dart';
import '../utils/path_helper.dart';
import '../utils/zzz_characters.dart';
import 'mod_metadata_service.dart';

/// The slice of `ConfigService` this repository needs: the legacy per-mod
/// character tag mirror in `config.json`.
///
/// Declared as a role rather than taking the whole `ConfigService` because that
/// class writes to the real `<appData>/config.json` on construction and on
/// every setter. A test that passed the real thing would overwrite the
/// developer's own library paths, active mods and favourites.
abstract class ModCharacterTagStore {
  Map<String, String> get modCharacterTags;
  Future<bool> setModCharacterTag(String modId, String characterId);
  Future<bool> removeModCharacterTag(String modId);
}

/// Metadata persistence for a mod library: the policy layer between the raw
/// sidecar I/O of [ModMetadataService] and the rest of [ModManagerService].
///
/// The split is by *responsibility*, not size:
///
/// - [ModMetadataService] knows where a sidecar lives and how to read/write it.
///   It has no opinions and no other collaborators.
/// - **This class** owns the rules — legacy migration, what "no character"
///   means on disk, which image paths are storable, and (soon) the origin block
///   and its offline backfill.
/// - `ModManagerService` assembles a `ModInfo` from this plus link state and
///   config, and does everything else about mods.
///
/// Everything it depends on is injected, so the rules are testable without a
/// configured library: pass a temp dir through [modsPath] and the whole class
/// works against real files with no app state. That matters because the pieces
/// most likely to be quietly wrong — the `source_url` → `mod_id` parse, the
/// confidence tiers — land in [loadOrMigrate], and they need tests that don't
/// require a running app.
class ModMetadataRepository {
  final ModCharacterTagStore _tagStore;
  final ModMetadataService _service;
  final String? Function() _modsPath;
  final String Function() _legacyImagesPath;

  ModMetadataRepository(
    this._tagStore, {
    required String? Function() modsPath,
    ModMetadataService? service,
    String Function()? legacyImagesPath,
  })  : _modsPath = modsPath,
        _service = service ?? ModMetadataService(),
        _legacyImagesPath = legacyImagesPath ?? PathHelper.getModImagesPath;

  /// The raw sidecar I/O layer. Exposed because the edit dialog imports gallery
  /// images directly through it.
  ModMetadataService get service => _service;

  /// Reads a mod's sidecar, or null when it has none / can't be parsed.
  Future<ModMetadata?> read(String modFolder) => _service.read(modFolder);

  /// Absolute path of a mod folder, or null when no library is configured.
  String? _folderOf(String modName) {
    final root = _modsPath();
    return root == null ? null : path.join(root, modName);
  }

  /// Loads a mod's metadata sidecar. If none exists yet, migrates legacy
  /// storage (character tag from config.json, pasted image from the app-data
  /// `mod_images/` dir) into the mod folder and writes the sidecar once.
  /// Best-effort: if the folder can't be written, returns the resolved values
  /// in memory so the app still works.
  Future<ModMetadata> loadOrMigrate(String modName, String modFolder) async {
    final existing = await _service.read(modFolder);
    if (existing != null) return existing;

    // No sidecar yet — gather legacy data to migrate. config.json may hold the
    // runtime "unknown" placeholder; that means "untagged", so it migrates to
    // absence rather than being copied onto disk as a real character.
    final legacyChar = storedCharacterId(_tagStore.modCharacterTags[modName]);
    String? migratedImageRel;
    try {
      final legacyImage = File(path.join(_legacyImagesPath(), '$modName.png'));
      if (await legacyImage.exists()) {
        migratedImageRel = await _service.importImageFile(modFolder, legacyImage.path);
      }
    } catch (e) {
      // Ignore: app-data image is optional.
    }

    final metadata = ModMetadata(
      characterId: legacyChar,
      images: migratedImageRel != null ? [migratedImageRel] : const [],
    );

    // Only persist when there is something to preserve, so we don't litter
    // every mod folder with empty sidecars.
    if (!metadata.isEmpty) {
      await _service.write(modFolder, metadata);
    }
    return metadata;
  }

  /// Persists editable metadata for a mod into its in-folder sidecar. Image
  /// paths on [mod] that live inside the mod folder are stored relative; paths
  /// outside it are ignored (use [ModMetadataService.importImageFile] first).
  Future<bool> save(ModInfo mod) async {
    try {
      final modFolder = _folderOf(mod.id);
      if (modFolder == null) return false;

      final relImages = <String>[];
      for (final abs in mod.images) {
        final rel = path.relative(abs, from: modFolder);
        if (!rel.startsWith('..') && !path.isAbsolute(rel)) relImages.add(rel);
      }

      // Replace the user-editable fields wholesale so emptied fields (e.g. a
      // cleared URL) are actually removed, rather than copyWith keeping the old
      // value. ModInfo carries every user-editable field, so this is a full
      // save — while replaceUserFields carries the machine-owned ones
      // (schema_version) and any unknown keys over from the copy on disk.
      final existing = await _service.read(modFolder);
      String? orNull(String? v) => (v == null || v.isEmpty) ? null : v;
      final metadata = (existing ?? const ModMetadata()).replaceUserFields(
        description: orNull(mod.description),
        sourceUrl: orNull(mod.sourceUrl),
        tags: mod.tags,
        characterId: mod.characterId, // normalised by replaceUserFields
        images: relImages,
      );
      return await _service.write(modFolder, metadata);
    } catch (e) {
      print('ModMetadataRepository: failed to save metadata for ${mod.id}: $e');
      return false;
    }
  }

  /// Sets a mod's character assignment in the in-folder sidecar (rename-safe),
  /// and mirrors it into config.json for backward compatibility.
  Future<bool> setCharacter(String modName, String characterId) async {
    try {
      // "No character" is absence, never the placeholder — the edit dialog
      // hands us that verbatim for untagged mods. replaceUserFields normalises
      // the sidecar side; config.json needs it done explicitly.
      final canonical = storedCharacterId(characterId);

      // Keep the legacy config copy in sync so older code paths still work.
      if (canonical == null) {
        await _tagStore.removeModCharacterTag(modName);
      } else {
        await _tagStore.setModCharacterTag(modName, canonical);
      }

      final modFolder = _folderOf(modName);
      if (modFolder == null) return false;
      final existing = await _service.read(modFolder) ?? const ModMetadata();

      // copyWith can't express clearing — copyWith(characterId: null) is a
      // no-op — so go through replaceUserFields, which can actually clear.
      return await _service.write(
        modFolder,
        existing.replaceUserFields(
          description: existing.description,
          sourceUrl: existing.sourceUrl,
          tags: existing.tags,
          characterId: canonical,
          images: existing.images,
        ),
      );
    } catch (e) {
      print('ModMetadataRepository: failed to set character for $modName: $e');
      return false;
    }
  }
}
