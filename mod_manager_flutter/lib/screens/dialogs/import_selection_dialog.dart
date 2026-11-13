import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;

import '../../models/character_info.dart';
import '../../services/archive_folder_summary.dart';
import 'folders_modal.dart';

/// One extracted/dropped top-level folder offered for import.
class ImportFolderChoice {
  /// Absolute path of the extracted/dropped folder.
  final String path;

  /// Display name and (for separate installs) the resulting mod name.
  final String name;

  /// The folder of another name that import moved this folder's shader files
  /// out of, into its `ShaderFixes/`; null when it did not.
  final String? shaderSource;

  const ImportFolderChoice({
    required this.path,
    required this.name,
    this.shaderSource,
  });
}

/// A resolved import plan: which folders to install and how.
class ImportPlan {
  /// Folders to install (a single folder, or the user's selected subset).
  final List<String> folders;

  /// When true, [folders] become subfolders of one mod named [combinedName];
  /// otherwise each folder is installed as its own mod.
  final bool combine;

  /// Name of the combined mod (only meaningful when [combine] is true).
  final String combinedName;

  const ImportPlan({
    required this.folders,
    required this.combine,
    required this.combinedName,
  });
}

/// What an install's folders question came to: a plan, or Don't install.
class ImportAnswer {
  const ImportAnswer(ImportPlan this.plan);

  const ImportAnswer.declined() : plan = null;

  /// Null for Don't install.
  final ImportPlan? plan;

  bool get declined => plan == null;
}

/// The single entry point both the mods-screen import (drag/drop + button) and the marketplace auto-install use to decide how a set of extracted/dropped folders becomes mods.
/// For one folder it installs as-is with no prompt; for several it opens the folders window in its install context, where the user ticks which to install and whether they are one mod or each its own.
/// Returns null when the window was closed without an answer, and a declined answer for Don't install;
/// the caller is responsible for cleaning up any extracted temp dirs.
///
/// [shaderSources] is the extraction's `ArchiveExtractionResult.shaderSources`, shown under each folder it names.
/// [archiveName] and [characterId] are for the window's header.
///
/// Keeping this in one place is deliberate: the multi-folder branch was once
/// added to the mods screen but forgotten in the marketplace, so both paths now
/// share this resolver rather than each hand-rolling the choice building.
Future<ImportAnswer?> resolveImportSelection(
  BuildContext context,
  List<String> folderPaths, {
  required String defaultCombinedName,
  Map<String, String> shaderSources = const {},
  String? archiveName,
  String? characterId,
}) async {
  if (folderPaths.length <= 1) {
    // Return a copy, never the caller's own list: both call sites do
    // `folderPaths..clear()..addAll(plan.folders)`, so aliasing the argument
    // would clear the list and then add nothing back, silently dropping the
    // single folder and reporting a false "already exists / error".
    return ImportAnswer(ImportPlan(
      folders: List<String>.from(folderPaths),
      combine: false,
      combinedName: '',
    ));
  }

  final choices = folderChoicesOf(folderPaths, shaderSources: shaderSources);
  final summaries = await summariseFolders(folderPaths);

  if (!context.mounted) return null;
  final pick = await showFoldersModal(
    context,
    question: FoldersInstall(
      archiveName: archiveName,
      defaultCombinedName: defaultCombinedName,
      characterId: characterId,
    ),
    choices: choices,
    summaries: {for (final summary in summaries) summary.path: summary},
  );
  if (pick == null) return null;
  if (pick.declined) return const ImportAnswer.declined();
  if (pick.folders.isEmpty) return null;

  return ImportAnswer(ImportPlan(
    folders: pick.folders,
    combine: pick.combine,
    combinedName: pick.combinedName,
  ));
}

/// [folderPaths] as the folders window offers them, in the order given.
List<ImportFolderChoice> folderChoicesOf(
  List<String> folderPaths, {
  Map<String, String> shaderSources = const {},
}) =>
    [
      for (final folder in folderPaths)
        ImportFolderChoice(path: folder, name: path.basename(folder), shaderSource: shaderSources[folder]),
    ];

/// What the folders question of an update came to: the folders ticked, Skip this update ([skipped]), or nothing for a window closed without an answer.
class UpdateFolderPick {
  const UpdateFolderPick(List<String> this.folders);

  const UpdateFolderPick.skipped() : folders = null;

  final List<String>? folders;

  bool get skipped => folders == null;
}

/// Asks which of an update archive's folders are [mod], for an update whose layout the app has no usable record of (the folders window in its update context).
///
/// An update always lands in the one folder it is for, so there is no separate-or-combined choice and nothing to name.
/// Nothing is ticked: a folder named like the mod's own, or like one its record names, or like the file, says so as a hint, and a guess never ticks.
/// [modsPath] is the library folder, for what the mod holds now; [archiveName] is the update's file name, and [heldFileDate] the upload date of the file the mod holds.
/// Null when the window was closed without an answer.
Future<UpdateFolderPick?> pickUpdateFolders(
  BuildContext context, {
  required ModInfo mod,
  required List<ImportFolderChoice> choices,
  String? modsPath,
  String? archiveName,
  DateTime? heldFileDate,
  bool reinstall = false,
}) async {
  final current = modsPath == null ? null : path.join(modsPath, mod.id);
  final summaries = await summariseFolders([?current, for (final choice in choices) choice.path]);
  if (!context.mounted) return null;
  final pick = await showFoldersModal(
    context,
    question: FoldersUpdate(
      archiveName: archiveName,
      mod: mod,
      current: current == null ? null : summaries.first,
      heldFileDate: heldFileDate,
      reinstall: reinstall,
    ),
    choices: choices,
    summaries: {for (final summary in summaries.skip(current == null ? 0 : 1)) summary.path: summary},
  );
  if (pick == null) return null;
  if (pick.declined) return const UpdateFolderPick.skipped();
  if (pick.folders.isEmpty) return null;
  return UpdateFolderPick(pick.folders);
}
