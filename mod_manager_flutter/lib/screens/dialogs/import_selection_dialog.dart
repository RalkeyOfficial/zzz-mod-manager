import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import '../../l10n/app_localizations.dart';
import '../../models/character_info.dart';
import '../../services/archive_service.dart';
import '../../services/shader_fixes/shader_fixes_service.dart';
import '../../services/update_apply/update_layout.dart';

/// One extracted/dropped top-level folder offered for import.
class ImportFolderChoice {
  /// Absolute path of the extracted/dropped folder.
  final String path;

  /// Display name and (for separate installs) the resulting mod name.
  final String name;

  /// Whether the folder contains a `.ini` (recursively) — i.e. looks like a
  /// real mod rather than auxiliary content (previews/images).
  final bool looksLikeMod;

  const ImportFolderChoice({
    required this.path,
    required this.name,
    required this.looksLikeMod,
  });
}

/// The user's choice from [showImportSelectionDialog].
class ImportSelection {
  /// When true, [folders] are installed as subfolders of one mod ([combinedName]);
  /// otherwise each folder is installed as its own mod.
  final bool combine;

  /// Selected folder paths (a subset of the offered choices).
  final List<String> folders;

  /// Name of the combined mod (only meaningful when [combine] is true).
  final String combinedName;

  const ImportSelection({
    required this.combine,
    required this.folders,
    required this.combinedName,
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

/// The single entry point both the mods-screen import (drag/drop + button) and
/// the marketplace auto-install use to decide how a set of extracted/dropped
/// folders becomes mods. For one folder it installs as-is with no prompt; for
/// several it opens [showImportSelectionDialog] so the user picks which to
/// install and whether to combine. Returns null if the user cancelled — the
/// caller is responsible for cleaning up any extracted temp dirs.
///
/// Keeping this in one place is deliberate: the multi-folder branch was once
/// added to the mods screen but forgotten in the marketplace, so both paths now
/// share this resolver rather than each hand-rolling the choice building.
Future<ImportPlan?> resolveImportSelection(
  BuildContext context,
  List<String> folderPaths, {
  required String defaultCombinedName,
}) async {
  if (folderPaths.length <= 1) {
    // Return a copy, never the caller's own list: both call sites do
    // `folderPaths..clear()..addAll(plan.folders)`, so aliasing the argument
    // would clear the list and then add nothing back, silently dropping the
    // single folder and reporting a false "already exists / error".
    return ImportPlan(
      folders: List<String>.from(folderPaths),
      combine: false,
      combinedName: '',
    );
  }

  final choices = <ImportFolderChoice>[];
  for (final folder in folderPaths) {
    choices.add(
      ImportFolderChoice(
        path: folder,
        name: path.basename(folder),
        looksLikeMod: await ArchiveService.containsIniFile(folder) ||
            await ShaderFixesService.shaderPartOf(folder) != null,
      ),
    );
  }

  if (!context.mounted) return null;
  final selection = await showImportSelectionDialog(
    context,
    choices,
    defaultCombinedName: defaultCombinedName,
  );
  if (selection == null || selection.folders.isEmpty) return null;

  return ImportPlan(
    folders: selection.folders,
    combine: selection.combine,
    combinedName: selection.combinedName,
  );
}

/// Asks which of an update archive's folders are [mod], for an update whose layout the app has no usable record of.
///
/// The import's picker without the separate-or-combined choice: an update always lands in the one folder it is for.
/// Pre-ticked are the folders named like the mod's own folder or its recorded folders, since an archive holding several mods
/// holds a `.ini` in each of them; only when nothing matches does the `.ini` rule decide.
/// Returns the chosen folder paths, or null when cancelled.
Future<List<String>?> pickUpdateFolders(
  BuildContext context, {
  required ModInfo mod,
  required List<ImportFolderChoice> choices,
  required UpdateLayoutProblem problem,
  bool reinstall = false,
}) async {
  final known = {
    mod.id.toLowerCase(),
    for (final folder in mod.origin?.ingest?.folders ?? const <String>[])
      folder.toLowerCase(),
  };
  final named = {
    for (final choice in choices)
      if (known.contains(choice.name.toLowerCase())) choice.path,
  };

  final loc = context.loc;
  final selection = await showImportSelectionDialog(
    context,
    choices,
    defaultCombinedName: mod.name,
    singleMod: true,
    preselected: named.isEmpty ? null : named,
    title: loc.t('mods.update_apply.pick_title', params: {'mod': mod.name}),
    intro: loc.t(problem == UpdateLayoutProblem.layoutChanged
        ? 'mods.update_apply.pick_intro_changed'
        : 'mods.update_apply.pick_intro_unknown'),
    confirmLabel: loc.t(
      reinstall ? 'mods.reinstall.confirm' : 'mods.update_apply.pick_confirm',
    ),
  );
  if (selection == null || selection.folders.isEmpty) return null;
  return selection.folders;
}

/// Lets the user pick which of several extracted/dropped folders to install and
/// whether they become separate mods or one combined mod. Folders containing a
/// `.ini` are pre-checked; folders without one (likely previews/images) are
/// shown unchecked and labelled. Returns the selection, or null if cancelled.
///
/// With [singleMod] the separate-or-combined choice and the name field are left out,
/// and [title], [intro] and [confirmLabel] say what the one mod is.
/// [preselected] replaces the `.ini` pre-check with the caller's own set of paths.
Future<ImportSelection?> showImportSelectionDialog(
  BuildContext context,
  List<ImportFolderChoice> choices, {
  required String defaultCombinedName,
  bool singleMod = false,
  Set<String>? preselected,
  String? title,
  String? intro,
  String? confirmLabel,
}) {
  final loc = context.loc;

  // Pre-check the folders that look like mods; if none do, pre-check them all so
  // the user isn't faced with an empty selection.
  final modLike = choices.where((c) => c.looksLikeMod).map((c) => c.path);
  final selected = <String>{
    ...(preselected ?? (modLike.isEmpty ? choices.map((c) => c.path) : modLike)),
  };
  final nameController = TextEditingController(text: defaultCombinedName);
  var combine = false;

  return showDialog<ImportSelection>(
    context: context,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (dialogContext, setLocal) {
          final canConfirm = selected.isNotEmpty &&
              (!combine || nameController.text.trim().isNotEmpty);

          void confirm() {
            Navigator.pop(
              dialogContext,
              ImportSelection(
                combine: combine,
                folders: choices
                    .where((c) => selected.contains(c.path))
                    .map((c) => c.path)
                    .toList(),
                combinedName: nameController.text.trim(),
              ),
            );
          }

          return AlertDialog(
            title: Row(
              children: [
                const Icon(Icons.folder_open, size: 24),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title ?? loc.t('mods.dialog.import_select_title'),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
              ],
            ),
            content: SizedBox(
              width: 440,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(intro ?? loc.t('mods.dialog.import_select_message')),
                  const SizedBox(height: 8),
                  if (!singleMod) ...[
                    RadioListTile<bool>(
                      value: false,
                      groupValue: combine,
                      onChanged: (v) => setLocal(() => combine = false),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(loc.t('mods.dialog.import_select_separate')),
                    ),
                    RadioListTile<bool>(
                      value: true,
                      groupValue: combine,
                      onChanged: (v) => setLocal(() => combine = true),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(loc.t('mods.dialog.import_select_combine')),
                    ),
                  ],
                  if (combine) ...[
                    const SizedBox(height: 4),
                    TextField(
                      controller: nameController,
                      onChanged: (_) => setLocal(() {}),
                      decoration: InputDecoration(
                        labelText: loc.t('mods.dialog.import_select_name'),
                        isDense: true,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  ],
                  const Divider(height: 20),
                  Flexible(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 260),
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          for (final choice in choices)
                            CheckboxListTile(
                              value: selected.contains(choice.path),
                              onChanged: (v) => setLocal(() {
                                if (v == true) {
                                  selected.add(choice.path);
                                } else {
                                  selected.remove(choice.path);
                                }
                              }),
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: Text(choice.name),
                              subtitle: Text(
                                choice.looksLikeMod
                                    ? loc.t('mods.dialog.import_select_mod')
                                    : loc.t('mods.dialog.import_select_aux'),
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(
                                  color: choice.looksLikeMod
                                      ? Colors.green
                                      : Colors.grey,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, null),
                child: Text(loc.t('mods.dialog.cancel')),
              ),
              FilledButton(
                onPressed: canConfirm ? confirm : null,
                child: Text(
                  confirmLabel ??
                      (combine
                          ? loc.t('mods.dialog.import_select_confirm_one')
                          : loc.t(
                              'mods.dialog.import_select_confirm',
                              params: {'count': selected.length.toString()},
                            )),
                ),
              ),
            ],
          );
        },
      );
    },
  );
}
