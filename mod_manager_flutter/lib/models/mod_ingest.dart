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
    this.patchFiles = const [],
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

  /// **Which files in this folder came from a patch**, in the spelling they
  /// have on disk.
  ///
  /// **Derived, and kept only for compatibility.** The authority is each
  /// download's own `files` list (`ModDownload.files`), and this is the union of
  /// the ones above the bottom of the stack — see `derivedPatchFiles`. It stays
  /// a plain `string[]` permanently because [_paths] filters this key to
  /// strings: an already-released build reading per-download objects here would
  /// see *no* patch files and flatten the patch away on the next base update.
  ///
  /// The one thing that makes a mixed folder rebuildable. Writing a newer *base*
  /// into it means taking the patch out, writing the base, and placing the patch
  /// back on top — and none of that is possible without knowing which files are
  /// the patch's. It cannot be worked out later: a mixed folder is
  /// indistinguishable from an ordinary one, which is the same reason
  /// [patchShaped] has to be recorded at install.
  ///
  /// **Recorded rather than re-downloaded** because a patch's mod page can be
  /// private, trashed or withheld by the time the base updates, and a rebuild
  /// that needs a page which no longer exists is a rebuild in name only. It also
  /// makes the rebuild offline and free.
  ///
  /// **On-disk spelling, not the normalised comparison key.** These paths open
  /// files; a lower-cased one deletes nothing on Linux and leaves a second copy
  /// behind. Normalise at the point of comparison instead.
  ///
  /// It records what the app wrote, so the user deleting one of these files is an
  /// edit rather than damage: a path that is gone is reported and skipped, never
  /// restored.
  final List<String> patchFiles;

  bool get isEmpty =>
      folders.isEmpty &&
      siblingGroup == null &&
      mode == IngestMode.separate &&
      !patchShaped &&
      patchFiles.isEmpty;

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
    List<String>? patchFiles,
  }) =>
      ModIngest(
        mode: mode ?? this.mode,
        folders: folders ?? this.folders,
        siblingGroup: siblingGroup ?? this.siblingGroup,
        patchShaped: patchShaped ?? this.patchShaped,
        patchFiles: patchFiles ?? this.patchFiles,
      );

  /// Value equality, so [ModOrigin] can have it — see the note there.
  @override
  bool operator ==(Object other) =>
      other is ModIngest &&
      other.mode == mode &&
      other.siblingGroup == siblingGroup &&
      other.patchShaped == patchShaped &&
      _same(other.folders, folders) &&
      _same(other.patchFiles, patchFiles);

  static bool _same(List<Object> a, List<Object> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(mode, siblingGroup, patchShaped,
      Object.hashAll(folders), Object.hashAll(patchFiles));

  Map<String, dynamic> toJson() => <String, dynamic>{
        'mode': mode.wire,
        if (folders.isNotEmpty) 'folders': folders,
        if (siblingGroup != null) 'sibling_group': siblingGroup,
        if (patchShaped) 'patch_shaped': true,
        if (patchFiles.isNotEmpty) 'patch_files': patchFiles,
      };

  /// Never throws; anything unusable degrades to a safe default.
  static ModIngest? fromJson(Object? raw) {
    if (raw is! Map) return null;
    return ModIngest(
      mode: IngestMode.parse(raw['mode']),
      folders: _paths(raw['folders']),
      siblingGroup:
          raw['sibling_group'] is String ? raw['sibling_group'] as String : null,
      patchShaped: raw['patch_shaped'] == true,
      patchFiles: _paths(raw['patch_files']),
    );
  }

  static List<String> _paths(Object? raw) => raw is List
      ? <String>[
          for (final entry in raw)
            if (entry is String && entry.isNotEmpty) entry,
        ]
      : const <String>[];
}
