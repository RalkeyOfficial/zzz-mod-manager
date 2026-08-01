import 'origin_enums.dart';

/// How one archive became this mod folder.
///
/// One archive does **not** map to one mod: the import dialog lets the user
/// install several top-level folders as separate mods, or merge them into one.
/// Without recording which happened, an update can't reproduce the install, and
/// several sidecars end up claiming the same remote file with nothing tying
/// them together.
class ModIngest {
  const ModIngest({
    this.mode = IngestMode.separate,
    this.folders = const [],
    this.siblingGroup,
  });

  final IngestMode mode;

  /// The top-level folder **basenames** taken from the archive for this mod —
  /// one entry in [IngestMode.separate], several in [IngestMode.combined].
  ///
  /// Basenames, never absolute paths: the sources lived in a
  /// `zzz_archive_extract_*` temp directory that no longer exists, so a full
  /// path would be meaningless afterwards and would leak the user's filesystem
  /// layout into a file meant to be shareable.
  ///
  /// Even in `separate` mode this is not redundant with the mod's folder name:
  /// the sidecar survives the user renaming the mod, and an update needs the
  /// *archive-relative* name to map re-downloaded contents back.
  final List<String> folders;

  /// Shared id when one archive produced several sibling mods; null otherwise.
  ///
  /// Null for a group of one on purpose — a "group" of one is noise, and it
  /// invites code to treat "has a group" as "is part of a group".
  ///
  /// Note it does **not** list the siblings. A sidecar must not describe another
  /// mod's folder: that would start lying the moment a sibling is renamed or
  /// deleted. The group is reconstructed by scanning the library for a matching
  /// id, which is the only view that stays honest — and which is exactly what a
  /// partly-deleted group needs in order to be recognised as broken rather than
  /// updatable.
  final String? siblingGroup;

  bool get isEmpty =>
      folders.isEmpty && siblingGroup == null && mode == IngestMode.separate;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'mode': mode.wire,
        if (folders.isNotEmpty) 'folders': folders,
        if (siblingGroup != null) 'sibling_group': siblingGroup,
      };

  /// Never throws; anything unusable degrades to a safe default.
  static ModIngest? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final folders = raw['folders'];
    return ModIngest(
      mode: IngestMode.parse(raw['mode']),
      folders: folders is List
          ? <String>[
              for (final entry in folders)
                if (entry is String && entry.isNotEmpty) entry,
            ]
          : const [],
      siblingGroup:
          raw['sibling_group'] is String ? raw['sibling_group'] as String : null,
    );
  }
}
