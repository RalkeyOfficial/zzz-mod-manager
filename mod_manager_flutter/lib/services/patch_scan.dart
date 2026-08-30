import 'dart:io';

import 'package:path/path.dart' as path;

import 'folder_contents.dart';
import 'patch_detection.dart';

/// The I/O side of `patch_detection.dart` — walk some folders, ask the pure
/// rule about each.
///
/// Separate from the rule itself so that file can stay a comparison of two sets
/// and be tested against fixture strings. Separate from `folder_contents.dart`
/// too, which owns *what is in a folder* rather than *what that means*.
///
/// Used at install, where it answers the question a user otherwise discovers by
/// launching the game and seeing nothing: **is this a patch expecting a mod that
/// isn't here?** It is the same call the update path makes about an incoming
/// download, and it has to be, or the two would disagree about the same folder.
Future<List<String>> modsThatLookLikePatches(
  String modsPath,
  Iterable<String> modNames,
) async {
  final patches = <String>[];
  for (final name in modNames) {
    final contents = await readFolderContents(
      Directory(path.join(modsPath, name)),
    );
    if (!contents.hasIni) continue;
    final assessment = assessPatchShape(
      references: contents.references,
      files: contents.files,
      directories: contents.directories,
      hasIni: true,
    );
    if (assessment.looksLikePatch) patches.add(name);
  }
  return patches;
}

/// What each of [modNames] replaces, for mods that ship **no `.ini`**.
///
/// The other half of patch detection. `modsThatLookLikePatches` asks what a
/// download's `.ini` files reference; a patch replacing one texture has no
/// `.ini`, so that question has no answer and this one asks a different one:
/// does this download bring anything the library does not already have?
///
/// Only worth calling for mods that have no `.ini` at all — the ones that
/// otherwise get the "may be incomplete" warning, which is right for a broken
/// download and wrong for a patch.
///
/// **Walks the whole library**, which is why it is called only for that narrow
/// case. The walk is the same one the scan-time backfill does, measured at
/// **0.51 ms per mod** (36 ms for 71 mods across 3722 files) — nothing beside an
/// operation that has just unpacked an archive.
///
/// Returns mod name -> what it patches, and omits any mod that patches nothing.
Future<Map<String, AssetPatchAssessment>> assetPatchesAmong(
  String modsPath,
  Iterable<String> modNames,
) async {
  final candidates = modNames.toList();
  if (candidates.isEmpty) return const <String, AssetPatchAssessment>{};

  final library = <String, Set<String>>{};
  final root = Directory(modsPath);
  if (!await root.exists()) return const <String, AssetPatchAssessment>{};
  await for (final entity in root.list(followLinks: false)) {
    if (entity is! Directory) continue;
    final name = path.basename(entity.path);
    library[name] = (await readFolderContents(entity)).files;
  }

  final found = <String, AssetPatchAssessment>{};
  for (final name in candidates) {
    final contents = library[name];
    if (contents == null) continue;
    final assessment = assessAssetPatch(
      files: contents,
      // Known by construction: the caller passes only mods with no `.ini`. Read
      // from the walk anyway rather than trusted, so the two cannot drift.
      hasIni: contents.any((f) => f.endsWith('.ini')),
      library: library,
      // Itself. The check runs after the copy, so without this every one of
      // these mods matches itself perfectly and reports itself as its own patch.
      exclude: {name},
    );
    if (assessment.looksLikePatch) found[name] = assessment;
  }
  return found;
}

/// One mod an import is **about to** create, and the folders it will be made of.
///
/// [sources] maps each source folder's absolute path to the subfolder it lands
/// in inside the mod: empty for a `separate` install, where the folder *is* the
/// mod, and the folder's own basename for a `combined` one — the same name
/// `importCombinedMod` creates.
class PlannedMod {
  const PlannedMod({required this.name, required this.sources});

  /// The name the mod will have, which is what any warning must call it.
  final String name;

  final Map<String, String> sources;
}

/// [modsThatLookLikePatches], asked **before** the copy about folders still in
/// a temp directory.
///
/// Moving the question earlier is what lets the install offer a destination
/// instead of warning after the fact. What moving it costs is the scoping that
/// the post-import scan got for free, and that scoping is the whole of this
/// function:
///
/// - **The subject is a mod, not a folder.** The rule is "the download brought
///   no content at all", and for a combined install the download is the mod the
///   several folders become. Judged one folder at a time, an ordinary mod that
///   ships its textures in one folder and an `.ini` in another reports the
///   second as a patch — and the user is asked where to apply a mod that needs
///   applying nowhere.
/// - **The union is taken under the subfolder each source lands in.**
///   References resolve relative to their own `.ini`
///   (`ini_resources.dart`), so after the combine `Patch/patch.ini` asks for
///   `Patch/body.dds` — which is not what `Extras/body.dds` is. A raw union
///   compares basenames, calls the reference satisfied and loses the patch.
///
/// Both are exactly what `readFolderContents` on the *installed* folder would
/// produce, which is the property that keeps this answer and the post-import
/// one from disagreeing about the same mod.
Future<Set<String>> plannedPatchShapedMods(Iterable<PlannedMod> planned) async {
  final patches = <String>{};
  for (final mod in planned) {
    var contents = FolderContents.empty;
    for (final entry in mod.sources.entries) {
      final walked = await readFolderContents(Directory(entry.key));
      contents = contents.merge(walked.underPrefix(entry.value));
    }
    if (!contents.hasIni) continue;
    final assessment = assessPatchShape(
      references: contents.references,
      files: contents.files,
      directories: contents.directories,
      hasIni: true,
    );
    if (assessment.looksLikePatch) patches.add(mod.name);
  }
  return patches;
}
