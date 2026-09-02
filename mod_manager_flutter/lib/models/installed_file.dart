/// **One file an install wrote into a mod folder**, and whether something was
/// already there.
///
/// A mod folder is frequently more than one download, and until this exists
/// nothing can say which files came from which. That is what makes a patch
/// removable, a base rebuildable, and a file the new version stopped shipping
/// nameable — all three are the same question asked of a different download.
///
/// It cannot be worked out later. A folder assembled from two downloads is
/// byte-for-byte indistinguishable from one that came out of a single archive,
/// which is the same reason `ModIngest.patchShaped` has to be captured at
/// install. So the record is written by the copy that laid the files down, and a
/// folder installed before it existed simply has none — see
/// `docs/applying-updates.md` §6.
library;

/// Whether this file went into empty space, or over something.
///
/// The distinction is what an uninstall acts on: an [added] file is the
/// download's alone and goes when the download does, while a [replaced] one has
/// a predecessor that has to come back.
enum InstalledFileRole {
  /// Nothing was at this path. Deleting it removes only what this download
  /// brought.
  added('added'),

  /// Something was here and was overwritten. Whoever wrote it is responsible for
  /// having kept the original.
  replaced('replaced');

  const InstalledFileRole(this.wire);

  final String wire;

  /// **An unrecognised value parses to [replaced], and that is the opposite of
  /// this codebase's usual "never upward" rule for the same reason it exists.**
  ///
  /// Every other lenient parse resolves an unknown to the weakest claim, because
  /// the risk there is acting on a permission we do not have. Here the weaker
  /// answer is the dangerous one: [added] licenses a **delete**, so reading a
  /// role we do not understand as [added] would remove a file that may be the
  /// mod's own. [replaced] licenses a restore, and a restore with no stored
  /// original is reported and skipped.
  ///
  /// Leaving a file behind is recoverable. Deleting the mod's own file is not.
  static InstalledFileRole parse(Object? raw) =>
      raw == InstalledFileRole.added.wire
          ? InstalledFileRole.added
          : InstalledFileRole.replaced;
}

class InstalledFile {
  const InstalledFile({
    required this.path,
    this.bytes = 0,
    this.role = InstalledFileRole.added,
  });

  /// Relative to the mod folder root, `/`-separated, in **the spelling it has on
  /// disk**.
  ///
  /// Not the normalised comparison key the rest of the update machinery uses. A
  /// lower-cased path opens nothing on Linux — it deletes nothing and leaves a
  /// second copy behind — and shown to a user it names a file they do not have.
  /// Normalise at the point of comparison instead.
  final String path;

  /// Size when it was written. Zero when it could not be read, which is not the
  /// same as an empty file and is why nothing treats this as authoritative: it
  /// is here so a folder's downloads can be weighed, never so a file can be
  /// verified.
  final int bytes;

  final InstalledFileRole role;

  Map<String, Object?> toJson() => {
        'path': path,
        'role': role.wire,
        if (bytes > 0) 'bytes': bytes,
      };

  /// Null when there is no usable path, so a malformed entry is dropped rather
  /// than becoming one that names the empty string — which, as a `delete`
  /// target, would resolve to the mod folder itself.
  static InstalledFile? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final path = raw['path'];
    if (path is! String || path.isEmpty) return null;
    final bytes = raw['bytes'];
    return InstalledFile(
      path: path,
      bytes: bytes is int && bytes > 0 ? bytes : 0,
      role: InstalledFileRole.parse(raw['role']),
    );
  }

  static List<InstalledFile> parseList(Object? raw) => raw is List
      ? <InstalledFile>[
          for (final entry in raw)
            if (fromJson(entry) case final file?) file,
        ]
      : const <InstalledFile>[];

  @override
  bool operator ==(Object other) =>
      other is InstalledFile &&
      other.path == path &&
      other.bytes == bytes &&
      other.role == role;

  @override
  int get hashCode => Object.hash(path, bytes, role);

  @override
  String toString() => 'InstalledFile($path, ${role.wire}, $bytes)';
}

/// [files] with every path moved under [prefix].
///
/// A combined install and an update both copy each source folder into a
/// *subfolder* of the mod, so what the copy reports is relative to that
/// subfolder and has to be lifted to the mod root before it is recorded — the
/// same lift `FolderContents.underPrefix` performs, and for the same reason:
/// every rule downstream compares like with like.
List<InstalledFile> installedFilesUnderPrefix(
  List<InstalledFile> files,
  String prefix,
) {
  if (prefix.isEmpty) return files;
  return [
    for (final file in files)
      InstalledFile(
        path: '$prefix/${file.path}',
        bytes: file.bytes,
        role: file.role,
      ),
  ];
}
