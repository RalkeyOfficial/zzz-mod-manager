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
