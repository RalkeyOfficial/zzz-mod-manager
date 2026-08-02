import 'dart:io';
import 'package:path/path.dart' as path;
import '../models/character_info.dart';
import '../models/mod_metadata.dart';
import '../models/mod_origin.dart';
import '../utils/path_helper.dart';
import '../utils/zzz_characters.dart';
import 'mod_metadata_service.dart';
import 'origin_backfill.dart';

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
///   means on disk, which image paths are storable, recording the origin block
///   and backfilling it offline.
/// - `ModManagerService` assembles a `ModInfo` from this plus link state and
///   config, and does everything else about mods.
///
/// Everything it depends on is injected, so the rules are testable without a
/// configured library: pass a temp dir through [modsPath] and the whole class
/// works against real files with no app state. That matters because the pieces
/// most likely to be quietly wrong — the `source_url` → `mod_id` parse, the
/// confidence tiers — reach disk through [loadOrMigrate], and they need tests
/// that don't require a running app. The decisions themselves live one level
/// further out still, in [OriginBackfill], which needs no filesystem at all.
class ModMetadataRepository {
  final ModCharacterTagStore _tagStore;
  final ModMetadataService _service;
  final String? Function() _modsPath;
  final String Function() _legacyImagesPath;
  final OriginBackfill _backfill;

  /// Mod folders whose backfill write failed this session — a read-only folder,
  /// or an odd network share. Without it the folder walk repeats on every
  /// single scan to re-attempt a write that keeps failing, which is the one
  /// case where the backfill stops being a once-per-mod cost.
  ///
  /// Deliberately not persisted: it is a fact about this run, not about the
  /// mod. Surfacing it to the user is still open — see "a failed origin write
  /// is a state, not a shrug" in the plan.
  final Set<String> _unwritableBackfills = {};

  ModMetadataRepository(
    this._tagStore, {
    required String? Function() modsPath,
    ModMetadataService? service,
    String Function()? legacyImagesPath,
    OriginBackfill? backfill,
  })  : _modsPath = modsPath,
        _service = service ?? ModMetadataService(),
        _legacyImagesPath = legacyImagesPath ?? PathHelper.getModImagesPath,
        _backfill = backfill ?? const OriginBackfill();

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

  /// Loads a mod's metadata sidecar, bringing it up to date on the way past.
  ///
  /// Two independent pieces of catch-up work hang off this, and they are
  /// **siblings on opposite branches** rather than one pipeline:
  ///
  /// - A mod that *has* a sidecar may still predate the origin block, but it
  ///   does carry a `source_url` — so it goes to [OriginBackfill].
  /// - A mod that has *no* sidecar has no `source_url` either (the field only
  ///   exists in the file that's missing), so there is nothing to backfill; what
  ///   it may have is pre-sidecar storage — a character tag in config.json, an
  ///   image in the app-data `mod_images/` dir — which the legacy migration
  ///   below pulls into the mod folder and writes once.
  ///
  /// Reading that as one migration chained after another is the trap: the
  /// backfill would sit on a branch where `source_url` is null by construction
  /// and never fire at all.
  ///
  /// Best-effort on both paths: if the folder can't be written, the resolved
  /// values still come back in memory so the app works against a read-only
  /// library.
  Future<ModMetadata> loadOrMigrate(String modName, String modFolder) async {
    final existing = await _service.read(modFolder);
    if (existing != null) return _backfillOrigin(modFolder, existing);

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

  /// Derives an origin block for an already-sidecar'd mod that predates one,
  /// and persists it. Returns the metadata to use either way.
  ///
  /// Writes **only** when something was actually derived, which is what keeps
  /// this off the hot path: an untracked mod costs one string parse per scan
  /// and no I/O, and a mod that has been backfilled once no longer qualifies,
  /// so the folder walk never runs for it again.
  Future<ModMetadata> _backfillOrigin(
    String modFolder,
    ModMetadata existing,
  ) async {
    try {
      if (_unwritableBackfills.contains(modFolder)) return existing;

      final modId = OriginBackfill.recoverableModId(existing);
      if (modId == null) return existing;

      final installedAt = await _backfill.probeInstallDate(modFolder);

      // Re-read before writing, and re-check the decision against what came
      // back. The probe above walks the whole mod folder, and that await is a
      // window the rest of the app runs inside: a scan is kicked off after
      // every toggle and rename, so the user confirming the edit dialog can
      // land a `save()` mid-walk. Writing back the copy read *before* the walk
      // would then quietly revert their description and tags — the one class of
      // damage this file exists to prevent. Contributing only the machine-owned
      // key to whatever is on disk now costs one extra read, once per mod.
      final fresh = await _service.read(modFolder) ?? existing;
      if (OriginBackfill.recoverableModId(fresh) != modId) return fresh;

      final updated = fresh.withOrigin(
        OriginBackfill.merge(
          existing: fresh.origin,
          modId: modId,
          installedAt: installedAt,
        ),
      );

      // Best-effort, like the legacy migration: an unwritable folder still
      // yields the derived identity in memory. But remember the failure, or
      // every subsequent scan re-walks the entire mod tree to re-attempt a
      // write that cannot succeed. Session-scoped on purpose — a folder that
      // becomes writable should be retried, just not on every rescan.
      if (!await _service.write(modFolder, updated)) {
        _unwritableBackfills.add(modFolder);
      }
      return updated;
    } catch (e) {
      print('ModMetadataRepository: origin backfill failed in $modFolder: $e');
      return existing;
    }
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
      // (schema_version, origin) and any unknown keys over from the copy on
      // disk.
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

  /// Records where a freshly-ingested mod came from.
  ///
  /// **Replaces any origin block that arrived inside the copied folder, by
  /// construction.** `_copyDirectory` copies a source folder's
  /// `.zzz-mod-manager/` wholesale, so a mod folder passed around on Discord
  /// arrives carrying *someone else's* origin block — a claim about a remote
  /// file that we never made, sitting on the one field that gates unattended
  /// updates. Because this method never reads or merges the inbound block, and
  /// [ModMetadata.withOrigin] replaces the field outright, there is no branch
  /// where a stranger's block can survive — and so no heuristic to get wrong.
  ///
  /// The user-facing fields (description, tags, images) are deliberately kept:
  /// those travelling with a shared folder is the entire point of a sidecar.
  ///
  /// Returns false when the mod folder is missing or unwritable. Callers should
  /// surface that once rather than silently retrying: nothing re-attempts *this*
  /// write, and the scan-time backfill is no substitute for it — that path only
  /// ever recovers identity from a `source_url`, so a mod whose origin failed to
  /// persist here loses its provenance, ingest shape and archive hash for good.
  Future<bool> recordOrigin(String modName, ModOrigin origin) async {
    try {
      final modFolder = _folderOf(modName);
      if (modFolder == null) return false;
      final existing = await _service.read(modFolder) ?? const ModMetadata();
      return await _service.write(modFolder, existing.withOrigin(origin));
    } catch (e) {
      print('ModMetadataRepository: failed to record origin for $modName: $e');
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
