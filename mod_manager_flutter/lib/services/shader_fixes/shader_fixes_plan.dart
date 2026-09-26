/// Which shader files a mod's enable copies in and its disable removes.
///
/// Pure: the service gathers what is on disk and applies the answer, so every rule
/// here is testable without a ZZMI folder (`docs/shader-fixes.md` §3–4).
library;

/// One file the app placed in a shader folder, and who it belongs to.
class ShaderPlacement {
  const ShaderPlacement({
    required this.folder,
    required this.path,
    required this.uid,
    required this.mod,
    required this.md5,
  });

  /// The absolute shader folder it was placed in. Kept because the links folder
  /// can be repointed at another ZZMI install, and a file there with the same
  /// name is not one this app placed.
  final String folder;

  /// Relative to [folder], `/`-separated, as written.
  final String path;

  /// The owning mod's uid, which survives a rename.
  final String uid;

  /// The owning mod's folder name when the file was placed, for messages only.
  final String mod;

  /// md5 of the bytes copied, so a disable deletes only what it put there.
  final String md5;

  Map<String, dynamic> toJson() =>
      {'folder': folder, 'path': path, 'uid': uid, 'mod': mod, 'md5': md5};

  static ShaderPlacement? fromJson(Object? json) {
    if (json is! Map) return null;
    final folder = json['folder'];
    final path = json['path'];
    final uid = json['uid'];
    final mod = json['mod'];
    final md5 = json['md5'];
    if (folder is! String || path is! String || uid is! String || md5 is! String) return null;
    return ShaderPlacement(
      folder: folder,
      path: path,
      uid: uid,
      mod: mod is String ? mod : '',
      md5: md5,
    );
  }
}

/// Every file the app has placed, keyed by shader folder and case-insensitive path.
///
/// The path ignores case because ZZMI runs on Windows, or under Wine, where
/// `ABC-ps_replace.txt` and `abc-ps_replace.txt` are one file.
class ShaderFixesRecord {
  ShaderFixesRecord([Iterable<ShaderPlacement> placements = const []])
      : _byKey = {for (final placement in placements) _keyFor(placement.folder, placement.path): placement};

  final Map<String, ShaderPlacement> _byKey;

  /// A path as compared: `/`-separated and lower-case.
  static String keyOf(String relative) => relative.replaceAll(r'\', '/').toLowerCase();

  static String _keyFor(String folder, String relative) => '$folder\u0000${keyOf(relative)}';

  Iterable<ShaderPlacement> get placements => _byKey.values;

  ShaderPlacement? at(String folder, String relative) => _byKey[_keyFor(folder, relative)];

  Iterable<ShaderPlacement> ownedBy(String uid) =>
      _byKey.values.where((placement) => placement.uid == uid);

  /// This record with [removed] dropped and [added] written over what was there.
  ShaderFixesRecord apply({
    Iterable<ShaderPlacement> removed = const [],
    Iterable<ShaderPlacement> added = const [],
  }) {
    final next = Map<String, ShaderPlacement>.of(_byKey);
    for (final placement in removed) {
      next.remove(_keyFor(placement.folder, placement.path));
    }
    for (final placement in added) {
      next[_keyFor(placement.folder, placement.path)] = placement;
    }
    return ShaderFixesRecord(next.values);
  }

  Map<String, dynamic> toJson() => {
        'version': 1,
        'files': [for (final placement in _byKey.values) placement.toJson()],
      };

  /// Reads what [toJson] wrote. Anything unreadable reads as empty rather than
  /// failing: the cost is that files placed before are treated as not placed by
  /// the app, which blocks a conflicting enable instead of overwriting it.
  static ShaderFixesRecord fromJson(Object? json) {
    if (json is! Map || json['files'] is! List) return ShaderFixesRecord();
    return ShaderFixesRecord([
      for (final entry in json['files'] as List)
        if (ShaderPlacement.fromJson(entry) case final placement?) placement,
    ]);
  }
}

/// A file a mod ships in its `ShaderFixes/` folder.
class ShaderSource {
  const ShaderSource(this.path, this.md5);

  /// Relative to the mod's `ShaderFixes/`, `/`-separated.
  final String path;
  final String md5;
}

/// A target that is taken, and by whom: a mod's name, or null for a file the app
/// did not place.
class ShaderConflict {
  const ShaderConflict(this.path, this.owner);
  final String path;
  final String? owner;
}

sealed class ShaderPlacementPlan {
  const ShaderPlacementPlan();
}

/// Copy every source in and record it.
class ShaderCopyPlan extends ShaderPlacementPlan {
  const ShaderCopyPlan(this.sources);
  final List<ShaderSource> sources;
}

/// Copy nothing: at least one target belongs to someone else.
class ShaderRefusedPlan extends ShaderPlacementPlan {
  const ShaderRefusedPlan(this.conflicts);
  final List<ShaderConflict> conflicts;
}

/// Plans enabling the mod [uid], whose `ShaderFixes/` holds [sources], into [folder].
///
/// [existing] is every file already in [folder], as [ShaderFixesRecord.keyOf] keys.
/// A target is free when nothing is there, or when this mod placed it in this
/// folder. A record naming another mod for a file that is gone is stale and does
/// not block. All or nothing: one taken target refuses the whole enable, since
/// half a shader fix is a broken one.
ShaderPlacementPlan planShaderPlacement({
  required String uid,
  required String folder,
  required List<ShaderSource> sources,
  required Set<String> existing,
  required ShaderFixesRecord record,
}) {
  final conflicts = <ShaderConflict>[];
  for (final source in sources) {
    if (!existing.contains(ShaderFixesRecord.keyOf(source.path))) continue;
    final owner = record.at(folder, source.path);
    if (owner != null && owner.uid == uid) continue;
    conflicts.add(ShaderConflict(source.path, owner?.mod));
  }
  if (conflicts.isNotEmpty) return ShaderRefusedPlan(conflicts);
  return ShaderCopyPlan(sources);
}

/// What disabling a mod removes from one shader folder.
class ShaderRemovalPlan {
  const ShaderRemovalPlan({
    required this.delete,
    required this.changed,
    required this.forget,
  });

  /// Files to delete, relative to the folder, as keyed by [ShaderFixesRecord.keyOf].
  final List<String> delete;

  /// Files this mod placed that have been changed since, left on disk.
  final List<String> changed;

  /// Record entries to drop: everything this mod owned in the folder.
  final List<ShaderPlacement> forget;
}

final RegExp _shaderSource = RegExp(r'^((?:.*/)?[0-9a-f]{16}-(vs|ps|cs|gs|hs|ds)(_replace)?)\.txt$', caseSensitive: false);

/// Plans disabling the mod [uid] in [folder].
///
/// [onDisk] maps each file in the folder, as a [ShaderFixesRecord.keyOf] key, to
/// its md5, or null when it could not be read. A placed file is deleted only while
/// its md5 still matches, so an edit the user made survives; a file already gone
/// is simply forgotten.
///
/// The `.bin` beside a deleted shader source goes too, whatever its bytes, unless
/// another mod owns it: ZZMI writes that cache itself when `cache_shaders` is on,
/// and it loads a `.bin` with no `.txt` beside it, so leaving one keeps the shader
/// applied after the mod is off.
ShaderRemovalPlan planShaderRemoval({
  required String uid,
  required String folder,
  required ShaderFixesRecord record,
  required Map<String, String?> onDisk,
}) {
  final owned = record.ownedBy(uid).where((placement) => placement.folder == folder).toList();
  final delete = <String>[];
  final changed = <String>[];
  for (final placement in owned) {
    final key = ShaderFixesRecord.keyOf(placement.path);
    if (!onDisk.containsKey(key)) continue;
    if (onDisk[key] == placement.md5) {
      delete.add(key);
    } else {
      changed.add(key);
    }
  }

  for (final source in List.of(delete)) {
    final bin = cacheBinFor(source);
    if (bin == null || !onDisk.containsKey(bin)) continue;
    final owner = record.at(folder, bin);
    if (owner != null && owner.uid != uid) continue;
    changed.remove(bin);
    if (!delete.contains(bin)) delete.add(bin);
  }

  return ShaderRemovalPlan(delete: delete, changed: changed, forget: owned);
}

/// The key of the `.bin` a shader source's cache would be written to, or null for
/// anything that is not a shader source.
String? cacheBinFor(String relative) {
  final match = _shaderSource.firstMatch(ShaderFixesRecord.keyOf(relative));
  return match == null ? null : '${match.group(1)}.bin';
}
