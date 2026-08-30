import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;

import '../../l10n/app_localizations.dart';
import '../../models/gamebanana/gamebanana.dart';
import '../../models/install_result.dart';
import '../../models/mod_ingest.dart';
import '../../models/mod_origin_seed.dart';
import '../../models/origin_enums.dart';
import '../../services/api_service.dart';
import '../../services/archive_service.dart';
import '../../services/gamebanana/remote_mod_metadata.dart';
import '../../services/mod_manager_service.dart';
import '../../services/patch_scan.dart';
import '../../utils/gamebanana_url.dart';
import '../../utils/notifications.dart';
import '../components/extract_failure_message.dart';
import 'duplicate_archive_dialog.dart';
import 'import_selection_dialog.dart';

/// Turning a downloaded GameBanana archive into a mod folder, end to end.
///
/// **The caller must supply a long-lived context.** The two dialogs below and
/// every `loc.t` need one, and this runs unattended minutes after the user
/// pressed Download — so a context belonging to a tab would be disposed by the
/// time it got here. `DownloadQueueHost` is the caller in production, and it is
/// mounted above the tab switcher for exactly that reason.
///
/// **Only the download is shared with the update path.** This imports the
/// archive as a *new* mod folder while `applyUpdateFlow` overwrites an existing
/// one; folding the two together is what would produce a shared "install" that
/// quietly does the wrong one.
Future<InstallResult> installArchiveFlow(
  BuildContext context,
  WidgetRef ref, {
  required File archiveFile,
  required GbMod mod,
  required GbFile file,
  String? knownMd5,
}) async {
  final loc = context.loc;

  // Only set once the archive has been unpacked and is genuinely spent. The
  // archive is a throwaway intermediate, but throwing it away *before* it has
  // been extracted would leave the user with nothing to retry from.
  var archiveConsumed = false;

  try {
    final config = await ApiService.getConfig();
    final modsPath = config['mods_path'] ?? '';

    // Inside the try, deliberately: as an early return above it, this skipped
    // the cleanup in `finally` entirely and leaked the archive.
    if (modsPath.isEmpty) {
      return InstallResult.error(
        loc.t('marketplace.install_missing_path_title'),
        loc.t('marketplace.install_missing_path_body'),
      );
    }

    final extractionResult = await ArchiveService.extractArchive(
      archiveFile: archiveFile,
      knownMd5: knownMd5,
    );

    if (!extractionResult.success) {
      // Keep the archive: the user can still extract it by hand, and telling
      // them where it is turns a dead end into a workaround.
      final lines = extractFailureMessage(
        loc,
        archivePath: archiveFile.path,
        reason: extractionResult.failure ?? ExtractFailure.other,
      );
      return InstallResult.error(lines.title, lines.body);
    }
    archiveConsumed = true;

    final directoriesToImport = List<String>.from(
      extractionResult.extractedFolders ?? const <String>[],
    );

    if (directoriesToImport.isEmpty) {
      return InstallResult.warning(
        loc.t('marketplace.install_empty_title'),
        loc.t('marketplace.install_empty_body'),
      );
    }

    // The character is often in the archive name rather than the inner folder
    // (or vice versa), so pass the archive base name as an extra detection hint.
    final archiveBaseName = path.basenameWithoutExtension(archiveFile.path);

    final archiveMd5 = extractionResult.archiveMd5 ?? knownMd5;
    if (!context.mounted) return InstallResult.cancelled();
    if (!await confirmArchiveNotDuplicate(context, ref, archiveMd5)) {
      await _cleanupExtractedFolders(directoriesToImport);
      return InstallResult.cancelled();
    }

    // When an archive expands to more than one top-level folder (e.g. a mod
    // folder next to a `previews` folder), let the user choose which folders
    // to install and whether they become separate mods or one combined mod.
    // Shared with the drag/drop and upload-button flow via resolveImportSelection.
    if (!context.mounted) return InstallResult.cancelled();
    final plan = await resolveImportSelection(
      context,
      directoriesToImport,
      defaultCombinedName: archiveBaseName,
    );
    if (plan == null) {
      // Cancelled — drop the extracted temp folders (the archive itself is
      // cleaned up by the `finally` below).
      await _cleanupExtractedFolders(directoriesToImport);
      return InstallResult.cancelled();
    }
    directoriesToImport
      ..clear()
      ..addAll(plan.folders);

    // Built here rather than at the call site because the archive hash is only
    // known once extraction has run. Every folder came out of this one
    // archive, so one seed covers all of them; `archiveMd5` is null-or-exact
    // and a null merely costs the fast path at resolution time.
    final effectiveSeed = _seedFor(mod, file, archiveMd5: archiveMd5);

    // Read once, and *before* the import rather than only after it. The
    // character it carries comes from the mod's own category upstream, which
    // is a fact rather than a reading of a file name — so the import is told
    // it instead of guessing. It has to be passed in rather than left to the
    // autofill below, because that fills absence only, and name detection
    // would already have filled the slot with its guess. The two disagree in
    // exactly the case that matters: a Zhao skin named "Zhao Nicole" reads as
    // Nicole, since the longest matching term wins.
    final remote = RemoteModMetadata.fromMod(mod);

    final ModManagerService modManager = await ApiService.getModManagerService();
    // The auto-tag map the import returns is deliberately dropped here: on
    // this path the character came from the mod page in the first place, and
    // "Zhao Nicole → zhao" is the app narrating its own bookkeeping back at
    // someone who just wanted the mod installed.
    final (importedMods, _) = plan.combine
        ? await modManager.importCombinedMod(
            directoriesToImport,
            plan.combinedName,
            detectionHint: archiveBaseName,
            origin: effectiveSeed,
            knownCharacter: remote.characterId,
          )
        : await modManager.importMods(
            directoriesToImport,
            detectionHints: {
              for (final dir in directoriesToImport) dir: archiveBaseName,
            },
            originSeeds: {
              for (final dir in directoriesToImport) dir: effectiveSeed,
            },
            knownCharacters: {
              for (final dir in directoriesToImport)
                if (remote.characterId case final id?) dir: id,
            },
          );

    if (importedMods.isEmpty) {
      return InstallResult.warning(
        loc.t('marketplace.install_duplicate_title'),
        loc.t('marketplace.install_duplicate_body'),
      );
    }

    // The mod page we downloaded from knows everything a fresh install
    // otherwise lacks — description, gallery, tags, and which character it is
    // filed under. Fill only what is still blank (an archive can arrive
    // carrying the author's own sidecar, and that text is better than ours).
    // After the import, deliberately: the folders have to exist, and the
    // character has already been settled above.
    //
    // Its result is not reported. Filling in a description and a gallery is
    // what an install is *for* — the user sees it on the card a second later —
    // so "Filled in from the mod page: description, preview images, tags" is
    // the app describing its own routine work at the one moment the user is
    // waiting to be told one thing: that the mod arrived.
    await modManager.applyRemoteMetadata(importedMods, remote);

    // Safety net: warn about any imported mod that has no .ini at all — a
    // strong sign the mod is incomplete (e.g. a broken multi-folder archive).
    final noIni = await ArchiveService.modsWithoutIni(modsPath, importedMods);

    // And the neighbouring case: an .ini that opens files this download does
    // not contain is a *patch*, and needs the mod it patches installed into
    // the same folder. Said now rather than left for the user to discover by
    // launching the game and seeing nothing change.
    final patches = await modsThatLookLikePatches(
      modsPath,
      importedMods.where((name) => !noIni.contains(name)),
    );

    // The other half, and the one the `.ini` rule cannot reach: a download of
    // bare assets replacing files a mod in the library already has. It has no
    // `.ini`, so there are no references to compare and no threshold that would
    // help — the signal is that it brought nothing new. Asked only of the mods
    // that were about to be called incomplete, which is where it belongs and
    // what keeps the library walk off every other install.
    final assetPatches = await assetPatchesAmong(modsPath, noIni);
    final incomplete = [
      for (final name in noIni)
        if (!assetPatches.containsKey(name)) name,
    ];

    // Written down, not just said. This is the only moment a patch folder is
    // legible: the user is about to drag the base mod's files in around it,
    // and once they do every reference resolves and the folder is
    // indistinguishable from an ordinary one. Without the flag the check goes
    // on asking the patch's page forever and calling the answer "up to date".
    //
    // A second write rather than part of the ingest seed, because the seed is
    // built before the folders exist and this can only be assessed after.
    for (final name in [...patches, ...assetPatches.keys]) {
      await modManager.updateModOrigin(name, (current) {
        if (current == null) return null;
        final ingest = current.ingest ?? const ModIngest();
        return current.copyWith(
          ingest: ModIngest(
            mode: ingest.mode,
            folders: ingest.folders,
            siblingGroup: ingest.siblingGroup,
            patchShaped: true,
          ),
        );
      });
    }

    // Drained, so it is reported at most once: nothing re-attempts an origin
    // write, because it happens at ingest and never during a scan. Drained
    // *before* the mounted check below on purpose — if this context is gone the
    // message is lost, which is better than leaving the names queued for the
    // next install to blame on the wrong archive.
    final originFailures = modManager.takeOriginWriteFailures();

    // Every `loc.t` below reads an inherited widget, and the autofill above is
    // the first await here that can run for *seconds* — up to one 20s image
    // timeout on a degraded CDN node.
    //
    // Under `DownloadQueueHost` this is effectively unreachable, which is the
    // gain: the context lives as long as the app, where the marketplace
    // screen's was disposed by a tab switch and silently dropped these
    // warnings. It stays because this takes a context from its caller and the
    // app can still be shutting down. Success, not `cancelled()` — the mod is
    // installed and its metadata is filled; the only thing lost is the sentence
    // describing it.
    if (!context.mounted) {
      return InstallResult.success(
        importedMods,
        characterId: remote.characterId,
      );
    }

    // **Only what the user has to act on.** Everything that merely describes
    // what the install did — the character it was filed under, the fields it
    // copied off the mod page — is gone: it is either visible on the card or
    // not worth a sentence. What is left is three things the user cannot find
    // out any other way, each of which changes what they do next. Each is its
    // own warning beside the success rather than more body text under it, so
    // a mod that arrived broken doesn't read like a mod that arrived.
    final warnings = <NotificationLines>[
      if (incomplete.isNotEmpty)
        NotificationLines(
          loc.t('mods.snackbar.import_no_ini_title'),
          loc.t('mods.snackbar.import_no_ini_body',
              params: {'mods': incomplete.join(', ')}),
        ),
      if (patches.isNotEmpty)
        NotificationLines(
          loc.t('mods.snackbar.import_patch_title'),
          loc.t('mods.snackbar.import_patch_body',
              params: {'mods': patches.join(', ')}),
          // The one install warning that must not time out: the mod does not
          // work until the user acts, and this card is raised beside the
          // success line they were actually waiting for.
          pinned: true,
        ),
      // Named separately from the `.ini` case because this one can say *what*
      // it patches — the collision is what identified it — and that is the
      // whole of what the user needs in order to act.
      for (final entry in assetPatches.entries)
        NotificationLines(
          loc.t('mods.snackbar.import_asset_patch_title'),
          loc.t('mods.snackbar.import_asset_patch_body', params: {
            'mod': entry.key,
            'targets': entry.value.targets.join(', '),
          }),
          pinned: true,
        ),
      if (originFailures.isNotEmpty)
        NotificationLines(
          loc.t('mods.snackbar.origin_write_failed_title'),
          loc.t('mods.snackbar.origin_write_failed_body',
              params: {'mods': originFailures.join(', ')}),
        ),
    ];

    return InstallResult.success(
      importedMods,
      warnings: warnings,
      characterId: remote.characterId,
    );
  } finally {
    if (archiveConsumed && await archiveFile.exists()) {
      await _safeDeleteArchive(archiveFile);
    }
  }
}

/// The origin seed for a file we picked ourselves off a mod page.
///
/// Both confidences are `exact` and that is the honest tier, not an optimistic
/// one: the user chose this row of this mod's file list and we fetched exactly
/// that file id. Nothing here is inferred.
///
/// `version` and `versionLabel` map onto the two GameBanana strings that must
/// never be conflated — `_sVersion` is a per-file version, `_sDescription` is
/// the author's variant label ("white hair ver"). They are recorded separately
/// because collapsing them would make two variants of one release look like two
/// releases.
ModOriginSeed _seedFor(GbMod mod, GbFile file, {String? archiveMd5}) {
  return ModOriginSeed(
    provenance: OriginProvenance.downloaded,
    archiveMd5: archiveMd5,
    source: gameBananaSource,
    modId: mod.idRow,
    modIdConfidence: OriginConfidence.exact,
    fileId: file.idRow,
    version: file.version,
    versionLabel: file.description,
    versionConfidence: OriginConfidence.exact,
  );
}

/// Deletes the temp extract dirs (`zzz_archive_extract_*`) that hold the given
/// extracted folders. Called when the user cancels the import selection dialog.
Future<void> _cleanupExtractedFolders(List<String> folderPaths) async {
  for (final folderPath in folderPaths) {
    try {
      final dir = Directory(folderPath);
      if (!await dir.exists()) continue;
      final parentDir = dir.parent;
      if (parentDir.path.contains('zzz_archive_extract_')) {
        await parentDir.delete(recursive: true);
      }
    } catch (e) {
      print('installArchiveFlow: temp cleanup error $folderPath: $e');
    }
  }
}

/// Deletes a consumed archive — **the file, never a directory.**
///
/// `<appData>/downloads` is shared: it holds every other archive and every
/// in-flight partial, and with a queue there are routinely several of both.
/// Removing the parent would take all of them. One rule, no special cases:
/// remove the file we just consumed and nothing else.
Future<void> _safeDeleteArchive(File archiveFile) async {
  try {
    await archiveFile.delete();
  } catch (e) {
    print('installArchiveFlow: could not delete archive '
        '${archiveFile.path}: $e');
  }
}
