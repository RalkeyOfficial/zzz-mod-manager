/// Which shader files a mod's enable copies in and its disable removes.
///
/// Pure: the service gathers what is on disk and applies the answer, so every rule
/// here is testable without a ZZMI folder (`docs/shader-fixes.md` §3–5).
library;

/// One file in a shader folder the app keeps track of, and everyone holding it.
///
/// A file is deleted only once its last mod holder lets go and it is not
/// [external]: several mods can ship the same bytes under one name, and a file
/// that was already there before any mod needed it is the user's.
class ShaderEntry {
  const ShaderEntry({
    required this.folder,
    required this.path,
    required this.md5,
    required this.holders,
    this.external = false,
  });

  /// The absolute shader folder the file is in. Kept because the links folder
  /// can be repointed at another ZZMI install, and a file there with the same
  /// name is not one this app knows.
  final String folder;

  /// Relative to [folder], `/`-separated, as written.
  final String path;

  /// md5 of the bytes the holders need, so a disable deletes only what they put there.
  final String md5;

  /// Each holding mod's uid, which survives a rename, to its folder name when it
  /// took hold, for messages only.
  final Map<String, String> holders;

  /// The file was already there, byte for byte, when a mod first needed it. The
  /// app never deletes it.
  final bool external;

  ShaderEntry copyWith({String? md5, Map<String, String>? holders, bool? external}) => ShaderEntry(
        folder: folder,
        path: path,
        md5: md5 ?? this.md5,
        holders: holders ?? this.holders,
        external: external ?? this.external,
      );

  Map<String, dynamic> toJson() => {
        'folder': folder,
        'path': path,
        'md5': md5,
        'holders': [
          for (final holder in holders.entries) {'uid': holder.key, 'mod': holder.value},
        ],
        'external': external,
      };

  static ShaderEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    final folder = json['folder'];
    final path = json['path'];
    final md5 = json['md5'];
    final holders = json['holders'];
    if (folder is! String || path is! String || md5 is! String || holders is! List) return null;
    return ShaderEntry(
      folder: folder,
      path: path,
      md5: md5,
      holders: {
        for (final holder in holders)
          if (holder is Map && holder['uid'] is String)
            holder['uid'] as String: holder['mod'] is String ? holder['mod'] as String : '',
      },
      external: json['external'] == true,
    );
  }
}

/// Every file the app keeps track of, keyed by shader folder and case-insensitive path.
///
/// The path ignores case because ZZMI runs on Windows, or under Wine, where
/// `ABC-ps_replace.txt` and `abc-ps_replace.txt` are one file.
class ShaderFixesRecord {
  ShaderFixesRecord([Iterable<ShaderEntry> entries = const []])
      : _byKey = {for (final entry in entries) _keyFor(entry.folder, entry.path): entry};

  final Map<String, ShaderEntry> _byKey;

  /// A path as compared: `/`-separated and lower-case.
  static String keyOf(String relative) => relative.replaceAll(r'\', '/').toLowerCase();

  static String _keyFor(String folder, String relative) => '$folder\u0000${keyOf(relative)}';

  Iterable<ShaderEntry> get entries => _byKey.values;

  ShaderEntry? at(String folder, String relative) => _byKey[_keyFor(folder, relative)];

  Iterable<ShaderEntry> heldBy(String uid) =>
      _byKey.values.where((entry) => entry.holders.containsKey(uid));

  /// This record with [removed] dropped and [added] written over what was there.
  ShaderFixesRecord apply({
    Iterable<ShaderEntry> removed = const [],
    Iterable<ShaderEntry> added = const [],
  }) {
    final next = Map<String, ShaderEntry>.of(_byKey);
    for (final entry in removed) {
      next.remove(_keyFor(entry.folder, entry.path));
    }
    for (final entry in added) {
      next[_keyFor(entry.folder, entry.path)] = entry;
    }
    return ShaderFixesRecord(next.values);
  }

  Map<String, dynamic> toJson() => {
        'version': 1,
        'files': [for (final entry in _byKey.values) entry.toJson()],
      };

  /// Reads what [toJson] wrote. Anything unreadable reads as empty rather than
  /// failing: the cost is that files placed before are treated as unknown, which
  /// blocks a conflicting enable instead of overwriting it, and an identical one
  /// is adopted as [ShaderEntry.external] and left in place.
  static ShaderFixesRecord fromJson(Object? json) {
    if (json is! Map || json['files'] is! List) return ShaderFixesRecord();
    return ShaderFixesRecord([
      for (final entry in json['files'] as List)
        if (ShaderEntry.fromJson(entry) case final parsed?) parsed,
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

/// A target that holds different bytes, and whose they are: a mod's name, or
/// null for a file no mod the app knows placed.
class ShaderConflict {
  const ShaderConflict(this.path, this.owner);
  final String path;
  final String? owner;
}

sealed class ShaderPlacementPlan {
  const ShaderPlacementPlan();
}

/// One source to copy in, and the entry to record once it has landed.
class ShaderCopy {
  const ShaderCopy(this.source, this.entry);
  final ShaderSource source;
  final ShaderEntry entry;
}

/// Copy [copy] in, and record [held] as they are: files already there with the
/// right bytes, now held by this mod too.
class ShaderCopyPlan extends ShaderPlacementPlan {
  const ShaderCopyPlan({required this.copy, required this.held, required this.adopted});
  final List<ShaderCopy> copy;
  final List<ShaderEntry> held;

  /// How many of [held] were not known to the app before, and stay when the mod is off.
  final int adopted;
}

/// Copy nothing: at least one target holds different bytes.
class ShaderRefusedPlan extends ShaderPlacementPlan {
  const ShaderRefusedPlan(this.conflicts);
  final List<ShaderConflict> conflicts;
}

/// Plans enabling the mod [uid], named [mod], whose `ShaderFixes/` holds
/// [sources], into [folder].
///
/// [onDisk] maps each target already in [folder], as a [ShaderFixesRecord.keyOf]
/// key, to its md5, or null when it could not be read. A target is free when
/// nothing is there; a file gone from under a record that needed the same bytes
/// keeps that record's holders, since copying it back restores their shader too.
/// One already holding the source's bytes is held rather than copied: joined when
/// the app knows it, adopted as external when it does not. A known file the user
/// has replaced since counts as unknown, so it becomes external too.
/// One holding different bytes is overwritten only when it is this mod's own
/// earlier version, untouched since. All or nothing: any other target refuses the
/// whole enable, since half a shader fix is a broken one.
ShaderPlacementPlan planShaderPlacement({
  required String uid,
  required String mod,
  required String folder,
  required List<ShaderSource> sources,
  required Map<String, String?> onDisk,
  required ShaderFixesRecord record,
}) {
  final conflicts = <ShaderConflict>[];
  final copy = <ShaderCopy>[];
  final held = <ShaderEntry>[];
  var adopted = 0;
  for (final source in sources) {
    final key = ShaderFixesRecord.keyOf(source.path);
    final entry = record.at(folder, source.path);
    if (!onDisk.containsKey(key)) {
      final stillNeeded = entry != null && entry.md5 == source.md5 ? entry.holders : const <String, String>{};
      copy.add(ShaderCopy(
        source,
        ShaderEntry(folder: folder, path: source.path, md5: source.md5, holders: {...stillNeeded, uid: mod}),
      ));
      continue;
    }
    final actual = onDisk[key];
    if (actual == source.md5) {
      if (entry == null) {
        adopted++;
        held.add(ShaderEntry(
          folder: folder,
          path: source.path,
          md5: source.md5,
          holders: {uid: mod},
          external: true,
        ));
      } else {
        held.add(entry.copyWith(
          md5: source.md5,
          holders: {...entry.holders, uid: mod},
          external: entry.external || entry.md5 != actual,
        ));
      }
      continue;
    }
    final ownOlderVersion = entry != null &&
        !entry.external &&
        entry.holders.length == 1 &&
        entry.holders.containsKey(uid) &&
        actual == entry.md5;
    if (ownOlderVersion) {
      copy.add(ShaderCopy(
        source,
        ShaderEntry(folder: folder, path: source.path, md5: source.md5, holders: {uid: mod}),
      ));
      continue;
    }
    final owner = entry?.holders.entries.where((holder) => holder.key != uid).firstOrNull?.value;
    conflicts.add(ShaderConflict(source.path, owner));
  }
  if (conflicts.isNotEmpty) return ShaderRefusedPlan(conflicts);
  return ShaderCopyPlan(copy: copy, held: held, adopted: adopted);
}

/// What disabling a mod removes from one shader folder.
class ShaderRemovalPlan {
  const ShaderRemovalPlan({
    required this.delete,
    required this.changed,
    required this.update,
    required this.forget,
    required this.forgetOnDelete,
  });

  /// Files to delete, relative to the folder, as keyed by [ShaderFixesRecord.keyOf].
  final List<String> delete;

  /// Files this mod placed that have been changed since, left on disk.
  final List<String> changed;

  /// Entries still held by someone else, rewritten without this mod.
  final List<ShaderEntry> update;

  /// Entries to drop whatever happens: files kept for their external owner,
  /// changed since, or already gone.
  final List<ShaderEntry> forget;

  /// Entries to drop only once their file in [delete] is actually gone, so a
  /// delete that fails is retried by the next disable.
  final Map<String, ShaderEntry> forgetOnDelete;
}

final RegExp _shaderSource = RegExp(r'^((?:.*/)?[0-9a-f]{16}-(vs|ps|cs|gs|hs|ds)(_replace)?)\.txt$', caseSensitive: false);

/// Plans disabling the mod [uid] in [folder].
///
/// [onDisk] maps each file in the folder, as a [ShaderFixesRecord.keyOf] key, to
/// its md5, or null when it could not be read. A file another mod still holds, or
/// one that was already there, stays. Otherwise it is deleted only while its md5
/// still matches, so an edit the user made survives; a file already gone is
/// simply forgotten.
///
/// The `.bin` beside a deleted shader source goes too, whatever its bytes, unless
/// someone else holds it: ZZMI writes that cache itself when `cache_shaders` is on,
/// and it loads a `.bin` with no `.txt` beside it, so leaving one keeps the shader
/// applied after the mod is off.
ShaderRemovalPlan planShaderRemoval({
  required String uid,
  required String folder,
  required ShaderFixesRecord record,
  required Map<String, String?> onDisk,
}) {
  final held = record.heldBy(uid).where((entry) => entry.folder == folder).toList();
  final delete = <String>[];
  final changed = <String>[];
  final update = <ShaderEntry>[];
  final forget = <ShaderEntry>[];
  final forgetOnDelete = <String, ShaderEntry>{};
  for (final entry in held) {
    final others = Map<String, String>.of(entry.holders)..remove(uid);
    if (others.isNotEmpty) {
      update.add(entry.copyWith(holders: others));
      continue;
    }
    final key = ShaderFixesRecord.keyOf(entry.path);
    if (entry.external || !onDisk.containsKey(key)) {
      forget.add(entry);
    } else if (onDisk[key] == entry.md5) {
      delete.add(key);
      forgetOnDelete[key] = entry;
    } else {
      changed.add(key);
      forget.add(entry);
    }
  }

  for (final source in List.of(delete)) {
    final bin = cacheBinFor(source);
    if (bin == null || !onDisk.containsKey(bin) || delete.contains(bin)) continue;
    final entry = record.at(folder, bin);
    if (entry != null && (entry.external || entry.holders.keys.any((holder) => holder != uid))) continue;
    delete.add(bin);
    if (changed.remove(bin)) {
      forget.remove(entry);
      forgetOnDelete[bin] = entry!;
    }
  }

  return ShaderRemovalPlan(
    delete: delete,
    changed: changed,
    update: update,
    forget: forget,
    forgetOnDelete: forgetOnDelete,
  );
}

/// The key of the `.bin` a shader source's cache would be written to, or null for
/// anything that is not a shader source.
String? cacheBinFor(String relative) {
  final match = _shaderSource.firstMatch(ShaderFixesRecord.keyOf(relative));
  return match == null ? null : '${match.group(1)}.bin';
}
