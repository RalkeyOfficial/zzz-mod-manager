import 'dart:io';
import 'dart:math';

import '../models/mod_metadata.dart';
import 'log/logger.dart';
import 'mod_metadata_service.dart';

/// **A mod folder's identity, for the things that have to outlive its name.**
///
/// Reads the uid out of the folder's own sidecar, or writes one in the first
/// time it is asked. Nothing else assigns one, and nothing ever changes one.
///
/// ## Why the folder name cannot be the identity
///
/// It already is, for per-install state: `config.json` keys `active_mods`,
/// `favorite_mods` and `mod_character_tags` by folder name, and `renameMod`
/// migrates all three. That works because a rename *through the app* is an
/// event the app can see.
///
/// **A rename in a file manager is not.** No hook runs, nothing migrates, and
/// anything filed under the old name is stranded silently. For a favourite star
/// that costs a star; for saved versions it costs gigabytes that no screen can
/// reach and that retention will never prune, because it protects each
/// name-group's newest entry forever. So saved versions key by this instead,
/// and a rename becomes a non-event in the app and outside it alike.
///
/// ## What it is
///
/// 32 hex characters from `Random.secure()`. **Opaque and never parsed** — its
/// only job is to be the same string tomorrow. Deliberately not derived from
/// the folder name, the install date or the origin block: a derived id changes
/// when the thing it derives from changes, which is the entire failure being
/// fixed.
///
/// ## Assigned on first need, never backfilled
///
/// A mod gets a uid the first time something has to remember it — today, the
/// first snapshot taken of it. There is no scan-time pass that stamps the
/// library, which would be a write into every mod folder for data most of them
/// have no use for yet, and a write against read-only folders that would fail
/// and be logged for no benefit.
///
/// **A mod with no uid has no saved versions**, and that is an identity rather
/// than an approximation: nothing could have filed anything under a uid it
/// never had.
///
/// ## What it does not fix
///
/// **A duplicated folder carries a duplicated uid.** Copying a mod folder in a
/// file manager is a thing people do, and both copies then claim one history —
/// where an update to either prunes the other's. Nothing here detects that; the
/// scan is where it would have to, and it is filed rather than built.
///
/// **A deleted sidecar orphans the history it named.** The mod gets a fresh uid
/// on its next snapshot and the old group becomes unclaimable. That is the
/// user's own doing, but it is silent, which is why unclaimed groups are
/// reported rather than left to accumulate.
class ModUid {
  ModUid({ModMetadataService? sidecars})
      : _sidecars = sidecars ?? ModMetadataService();

  final ModMetadataService _sidecars;

  static final Random _random = Random.secure();
  static final Logger _log = Logger('metadata');

  /// This folder's uid, **assigning one if it has none**.
  ///
  /// Null only when the sidecar could not be written, which is a folder that
  /// cannot be modified at all — so the operation that asked for the uid was
  /// about to fail anyway. Callers treat it the way they treat a snapshot that
  /// could not be taken: stop, rather than proceed unrecorded.
  Future<String?> ensure(Directory modFolder) async {
    final existing = await read(modFolder);
    if (existing != null) return existing;

    final metadata = await _sidecars.read(modFolder.path);
    final uid = newUid();
    final written = await _sidecars.write(
      modFolder.path,
      (metadata ?? const ModMetadata()).copyWith(uid: uid),
    );
    if (!written) {
      _log.warning('could not give a mod an identity',
          fields: {'mod': modFolder.path});
      return null;
    }
    return uid;
  }

  /// This folder's uid, or null when it has never needed one.
  Future<String?> read(Directory modFolder) async {
    final uid = (await _sidecars.read(modFolder.path))?.uid;
    return (uid != null && uid.isNotEmpty) ? uid : null;
  }

  /// A fresh identity. Hex so it is safe as a directory name on both platforms
  /// without escaping.
  static String newUid() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
