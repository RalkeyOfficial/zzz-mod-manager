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
    this.patchShaped = false,
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

  /// This download is a **patch**, expecting a mod already in the folder —
  /// either because its `.ini` files reference content it does not carry, or
  /// because it carries assets and no `.ini` that could load them.
  ///
  /// Recorded because it is knowable **only at install**. A patch folder is
  /// legible exactly once: before the user drags the base mod's files in
  /// around it. Afterwards every reference resolves and the folder is
  /// byte-for-byte indistinguishable from an ordinary one-download mod, so no
  /// later scan can recover this. See `docs/applying-updates.md` §1.
  ///
  /// What it is *for* is stopping a lie rather than enabling a feature: the
  /// origin block names the **patch's** page, so a check against it reports
  /// "up to date" while the mod the folder actually contains goes versions
  /// ahead. Knowing the folder is two things is enough to refuse that claim.
  /// It is not enough to *watch* the other one — that needs a second identity
  /// only the user can supply.
  final bool patchShaped;

  bool get isEmpty =>
      folders.isEmpty &&
      siblingGroup == null &&
      mode == IngestMode.separate &&
      !patchShaped;

  /// Amends one field, keeping the rest.
  ///
  /// The alternative — rebuilding the object at each call site — drops any
  /// field the caller forgot, and the fields here describe an install that
  /// cannot be observed a second time. Clearing [siblingGroup] is deliberately
  /// not offered: null means "keep", and nothing has cause to unset a group.
  ModIngest copyWith({
    IngestMode? mode,
    List<String>? folders,
    String? siblingGroup,
    bool? patchShaped,
  }) =>
      ModIngest(
        mode: mode ?? this.mode,
        folders: folders ?? this.folders,
        siblingGroup: siblingGroup ?? this.siblingGroup,
        patchShaped: patchShaped ?? this.patchShaped,
      );

  /// Value equality, so [ModOrigin] can have it — see the note there.
  @override
  bool operator ==(Object other) =>
      other is ModIngest &&
      other.mode == mode &&
      other.siblingGroup == siblingGroup &&
      other.patchShaped == patchShaped &&
      _sameFolders(other.folders);

  bool _sameFolders(List<String> other) {
    if (other.length != folders.length) return false;
    for (var i = 0; i < folders.length; i++) {
      if (other[i] != folders[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode =>
      Object.hash(mode, siblingGroup, patchShaped, Object.hashAll(folders));

  Map<String, dynamic> toJson() => <String, dynamic>{
        'mode': mode.wire,
        if (folders.isNotEmpty) 'folders': folders,
        if (siblingGroup != null) 'sibling_group': siblingGroup,
        if (patchShaped) 'patch_shaped': true,
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
      patchShaped: raw['patch_shaped'] == true,
    );
  }
}
