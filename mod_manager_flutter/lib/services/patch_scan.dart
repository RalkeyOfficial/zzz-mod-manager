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

/// Which of [modNames] are patches shipping **no `.ini`**.
///
/// The other half of patch detection. `modsThatLookLikePatches` asks what a
/// download's `.ini` files reference; a patch replacing one texture has no
/// `.ini`, so that question has no answer and this one asks whether the folder
/// carries assets that only an `.ini` could load.
///
/// Only worth calling for mods that have no `.ini` at all — the ones that
/// otherwise get the "may be incomplete" warning, which is right for a broken
/// download and wrong for a patch.
///
/// Reads only the folders named. The rule is intrinsic, so there is no library
/// to walk and no ordering in which the answer changes.
Future<Map<String, AssetPatchAssessment>> assetPatchesAmong(
  String modsPath,
  Iterable<String> modNames,
) async {
  final found = <String, AssetPatchAssessment>{};
  for (final name in modNames) {
    final contents = await readFolderContents(
      Directory(path.join(modsPath, name)),
    );
    final assessment = assessAssetPatch(
      files: contents.files,
      // Known by construction: the caller passes only mods with no `.ini`. Read
      // from the folder anyway rather than trusted, so the two cannot drift.
      hasIni: contents.hasIni,
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

/// What a scan of the mods an import is **about to create** concluded.
///
/// The three outcomes **partition**: a mod is patch-shaped by one rule or the
/// other, or plainly incomplete, or none of them. Two answers about one mod
/// would have the install say two different things about it — which is what the
/// asset rule was added to stop, a patch being called incomplete.
class PlannedPatchScan {
  const PlannedPatchScan({
    this.iniPatches = const <String>{},
    this.assetPatches = const <String, AssetPatchAssessment>{},
    this.incomplete = const <String>{},
  });

  static const PlannedPatchScan empty = PlannedPatchScan();

  /// Mods whose `.ini` files ask for content the download does not carry.
  final Set<String> iniPatches;

  /// Mods that ship no `.ini` and bring nothing the library lacks, each with
  /// the library folders holding every file it brings.
  final Map<String, AssetPatchAssessment> assetPatches;

  /// Mods that ship no `.ini` and replace nothing either — the broken download
  /// the "may be incomplete" warning exists for.
  final Set<String> incomplete;

  /// Every mod this scan calls a patch, whichever rule found it.
  Set<String> get patchShaped => {...iniPatches, ...assetPatches.keys};
}

/// Both patch rules, asked **before** the copy about folders still in a temp
/// directory.
///
/// Moving the question earlier is what lets the install ask where a patch
/// belongs instead of warning after the fact. What it costs is the scoping the
/// post-import scan got for free, and that scoping is most of this function:
///
/// - **The subject is a mod, not a folder.** The rule is "the download brought
///   no content at all", and for a combined install the download is the mod the
///   several folders become. Judged one folder at a time, an ordinary mod that
///   ships its textures in one folder and an `.ini` in another reports the
///   second as a patch — and the user is asked where to apply a mod that needs
///   applying nowhere.
/// - **The union is taken under the subfolder each source lands in.**
///   References resolve relative to their own `.ini` (`ini_resources.dart`), so
///   after the combine `Patch/patch.ini` asks for `Patch/body.dds` — which is
///   not what `Extras/body.dds` is. A raw union compares basenames, calls the
///   reference satisfied and loses the patch.
///
/// Both are exactly what `readFolderContents` on the *installed* folder would
/// produce, which is the property that keeps this answer and the post-import
/// one from disagreeing about the same mod.
///
/// Nothing outside [planned] is read: both rules are judgements about the
/// download itself.
Future<PlannedPatchScan> scanPlannedMods(Iterable<PlannedMod> planned) async {
  final contents = <String, FolderContents>{};
  for (final mod in planned) {
    var merged = FolderContents.empty;
    for (final entry in mod.sources.entries) {
      final walked = await readFolderContents(Directory(entry.key));
      merged = merged.merge(walked.underPrefix(entry.value));
    }
    contents[mod.name] = merged;
  }

  final iniPatches = <String>{};
  final noIni = <String>[];
  for (final entry in contents.entries) {
    if (!entry.value.hasIni) {
      noIni.add(entry.key);
      continue;
    }
    final assessment = assessPatchShape(
      references: entry.value.references,
      files: entry.value.files,
      directories: entry.value.directories,
      hasIni: true,
    );
    if (assessment.looksLikePatch) iniPatches.add(entry.key);
  }

  final assetPatches = <String, AssetPatchAssessment>{};
  final incomplete = <String>{};
  for (final name in noIni) {
    final assessment =
        assessAssetPatch(files: contents[name]!.files, hasIni: false);
    if (assessment.looksLikePatch) {
      assetPatches[name] = assessment;
    } else {
      incomplete.add(name);
    }
  }

  return PlannedPatchScan(
    iniPatches: iniPatches,
    assetPatches: assetPatches,
    incomplete: incomplete,
  );
}
