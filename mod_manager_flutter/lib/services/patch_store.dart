import 'dart:io';

import 'package:path/path.dart' as path;

import '../core/constants.dart';
import 'log/logger.dart';

/// **The mod's own files that a patch wrote over**, kept so the patch can be
/// taken back out.
///
/// One directory per patch inside the mod folder:
///
/// ```
/// <mod>/.zzz-mod-manager/replaced/<patch mod id>/Textures/Body.dds.orig
/// ```
///
/// ## Why it is in the mod folder
///
/// **The filesystem is the bookkeeping.** Rename the mod, move the library to
/// another drive, delete the folder, zip it and send it — every one of those is
/// handled by the operation that already handles the folder, with nothing to
/// hook and nothing to reconcile.
///
/// The alternative was `<appData>`, keyed by folder name beside the snapshots,
/// and that shape **already leaks**: `renameMod` and `deleteMod` do not touch
/// `<appData>/backups/`, and `planRetention` protects the newest snapshot of
/// each mod *name* unconditionally — so a stranded group is both unreachable
/// from "Restore a previous version…" and permanently exempt from pruning. A
/// second store keyed the same way would inherit that on day one.
///
/// It also lands on the right side of the sidecar's own split rule
/// (`docs/metadata-schema.md` §1): which files this patch displaced is intrinsic
/// to the folder, not to this installation.
///
/// ## Why every stored file is suffixed
///
/// `docs/applying-updates.md` §5 refuses to put a **snapshot** inside a mod
/// folder, and it is right to: a verbatim copy holds a loadable `ellen.ini`, the
/// active symlink makes it reachable, and the loader then reads the old version's
/// hotkeys alongside the new one's. A patch replacing the base's `.ini` is the
/// common case, so this store would hold exactly that file.
///
/// So **nothing in here is named like something the loader looks for.**
/// [_suffix] goes on every stored file, which takes it out of any `*.ini` glob,
/// and the real path lives in the sidecar's registry rather than on disk. An
/// asset that no `.ini` references is inert on its own.
///
/// **Not verified against ZZMI.** It is a claim about someone else's loader, and
/// the check is one launch of the game with a patched mod active.
class PatchStore {
  const PatchStore();

  static final Logger _log = Logger('patch.store');

  /// Kept short and unmistakable. Not `.bak`, which users and backup tools both
  /// already mean something by.
  static const String _suffix = '.orig';

  static const String _dirName = 'replaced';

  /// Where one patch's displaced files live.
  ///
  /// Keyed by the patch's **mod id**, so two patches in one folder never read
  /// each other's originals — the same reason their registries are per
  /// companion rather than one list on the folder.
  static Directory directoryFor(Directory modFolder, int patchModId) =>
      Directory(path.join(
        modFolder.path,
        AppConstants.modMetadataDirName,
        _dirName,
        '$patchModId',
      ));

  /// Every store in this folder, by the patch mod id that owns it.
  ///
  /// Used to spot one nothing accounts for: `_copyDirectory` carries
  /// `.zzz-mod-manager/` wholesale on ingest while the inbound `origin` block is
  /// dropped, so a re-imported folder arrives holding bytes with no registry to
  /// explain them.
  static Future<Set<int>> idsIn(Directory modFolder) async {
    final root = Directory(path.join(
      modFolder.path,
      AppConstants.modMetadataDirName,
      _dirName,
    ));
    if (!await root.exists()) return const <int>{};
    final ids = <int>{};
    try {
      await for (final entity in root.list(followLinks: false)) {
        if (entity is! Directory) continue;
        final id = int.tryParse(path.basename(entity.path));
        if (id != null) ids.add(id);
      }
    } catch (e) {
      _log.warning('could not list the displaced files', error: e);
    }
    return ids;
  }

  /// Copies what is at [relativePath] in [modFolder] into [patchModId]'s store,
  /// **before** the patch overwrites it. True when there is now an original to
  /// go back to.
  ///
  /// **The first displacement wins, and that is load-bearing.** Updating a patch
  /// overwrites the *previous patch's* files, not the mod's — so a second keep
  /// at the same path would replace the base's original with a patch file, and
  /// removing the patch would then restore the patch. Only the first write to a
  /// path ever saw what the mod itself had there, so an original already on hand
  /// is left untouched and this reports success.
  ///
  /// A path the patch's new version reaches for the first time is still kept, so
  /// a version that displaces more of the mod than the last one did stays
  /// reversible.
  ///
  /// False for a path nothing occupied, which is not a failure: the patch is
  /// adding a file, and an [InstalledFileRole.added] entry needs no original.
  ///
  /// **A store that cannot be written does not stop the install.** The patch
  /// still applies and the snapshot the caller took is still the way back; what
  /// is lost is the cheap, permanent route, and the removal reports the file as
  /// unrecoverable rather than deleting it as if it were the patch's own.
  Future<bool> keep({
    required Directory modFolder,
    required int patchModId,
    required String relativePath,
  }) async {
    final live = File(path.joinAll([modFolder.path, ...relativePath.split('/')]));
    if (!await live.exists()) return false;
    if (await holds(
      modFolder: modFolder,
      patchModId: patchModId,
      relativePath: relativePath,
    )) {
      return true;
    }
    try {
      final target = _fileFor(modFolder, patchModId, relativePath);
      await target.parent.create(recursive: true);
      await live.copy(target.path);
      return true;
    } catch (e) {
      _log.warning('could not keep a displaced file',
          error: e, fields: {'file': relativePath, 'patch': patchModId});
      return false;
    }
  }

  /// Whether an original is on hand for [relativePath].
  Future<bool> holds({
    required Directory modFolder,
    required int patchModId,
    required String relativePath,
  }) =>
      _fileFor(modFolder, patchModId, relativePath).exists();

  /// Puts the original back where it came from. True when it landed.
  ///
  /// The stored copy is left alone: the caller drops the whole store once the
  /// removal has finished, and a restore that failed part-way must not have
  /// eaten the thing it was restoring.
  Future<bool> restore({
    required Directory modFolder,
    required int patchModId,
    required String relativePath,
  }) async {
    final stored = _fileFor(modFolder, patchModId, relativePath);
    if (!await stored.exists()) return false;
    try {
      final live =
          File(path.joinAll([modFolder.path, ...relativePath.split('/')]));
      await live.parent.create(recursive: true);
      await stored.copy(live.path);
      return true;
    } catch (e) {
      _log.warning('could not restore a displaced file',
          error: e, fields: {'file': relativePath, 'patch': patchModId});
      return false;
    }
  }

  /// Removes **every** store in a folder the app has just taken in.
  ///
  /// The one piece of reconciliation in-folder storage still needs, and it needs
  /// only this one. `copyDirectory` carries `.zzz-mod-manager/` wholesale on
  /// ingest — that is deliberate, so a shared folder arrives with its
  /// description and gallery — while the inbound `origin` block is always
  /// dropped (`docs/metadata-schema.md` §2). So an imported folder can hold
  /// displaced originals with **nothing left that says which patch they belong
  /// to or which files they are**, and unexplained bytes in a mod folder are
  /// dead weight forever.
  ///
  /// Unconditional rather than checked against the block, because an ingest has
  /// no block to check: the fresh one is written afterwards and names no
  /// companions. Anything the app itself puts here is written after this runs.
  Future<void> discardAll(Directory modFolder) async {
    for (final id in await idsIn(modFolder)) {
      await discard(modFolder: modFolder, patchModId: id);
    }
  }

  /// Removes one patch's store. Called once its files are back in place, and on
  /// ingest for a store no registry accounts for.
  Future<void> discard({
    required Directory modFolder,
    required int patchModId,
  }) async {
    final dir = directoryFor(modFolder, patchModId);
    if (!await dir.exists()) return;
    try {
      await dir.delete(recursive: true);
    } catch (e) {
      _log.warning('could not remove a patch store',
          error: e, fields: {'patch': patchModId});
    }
  }

  static File _fileFor(
    Directory modFolder,
    int patchModId,
    String relativePath,
  ) =>
      File(path.joinAll([
        directoryFor(modFolder, patchModId).path,
        ...relativePath.split('/'),
      ]) +
          _suffix);
}
