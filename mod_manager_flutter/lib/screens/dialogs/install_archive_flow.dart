import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;

import '../../l10n/app_localizations.dart';
import '../../models/gamebanana/gamebanana.dart';
import '../../models/install_result.dart';
import '../../models/mod_origin_seed.dart';
import '../../models/origin_enums.dart';
import '../../services/api_service.dart';
import '../../services/archive_service.dart';
import '../../services/gamebanana/remote_mod_metadata.dart';
import '../../services/log/logger.dart';
import '../../services/mod_manager_service.dart';
import '../../services/update_apply/mod_activation_port.dart';
import '../../services/update_apply/update_applier.dart';
import '../../utils/gamebanana_url.dart';
import '../../utils/notifications.dart';
import '../../utils/state_providers.dart';
import '../components/extract_failure_message.dart';
import 'duplicate_archive_dialog.dart';
import 'import_selection_dialog.dart';
import 'patch_install_flow.dart';

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

  /// The name the download asked for, when it was one. The downloads directory
  /// never overwrites, so the file on disk can be `mod (2).rar` — and for an
  /// archive with no folder inside it the filename becomes the **mod's** name,
  /// plus the default name in the folder picker. Our own bookkeeping must not
  /// rename the user's mod.
  String? requestedName,
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
      nameHint: requestedName,
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
    // From the name the download **asked for**: it is also the default name in
    // the folder picker, and a collision suffix has no business in either.
    final archiveBaseName =
        path.basenameWithoutExtension(requestedName ?? archiveFile.path);

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

    // **The patch question, before the copy.** The answer exists as soon as the
    // archive is unpacked, and asking here is what lets the install offer a
    // destination rather than warn about a folder the user then has to go and
    // find again. Shared with the drag/drop import.
    //
    // The library it offers is read inside, at the moment the prompt opens: the
    // widget tree's copy is as old as the last visit to the Mods tab, and this
    // runs unattended minutes later.
    if (!context.mounted) return InstallResult.cancelled();
    final decision = await decidePatchInstall(
      context,
      plan: plan,
      folders: directoriesToImport,
      modsPath: modsPath,
      patchModId: mod.idRow,
      // What the author says this needs. For a patch that is sometimes the mod
      // being patched, and where the library holds it, it leads the
      // destinations with the author's own words on it.
      patchRequirements: mod.requirements,
    );
    // Null is "don't install it", which only that prompt can offer: it is the
    // last point before the copy, and a patch with nothing to patch is a folder
    // the user may well not want.
    if (decision == null) {
      await _cleanupExtractedFolders(directoriesToImport);
      return InstallResult.cancelled();
    }

    // **The folders going into an existing mod are not imported at all.** No
    // new mod folder exists at the end of that branch — the library mod the
    // user picked is the one that ends up holding both downloads — so they are
    // taken out of the import and written afterwards, by the update machinery
    // rather than by `importMods`.
    directoriesToImport.removeWhere(decision.excludes);

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
    final (importedMods, _) = directoriesToImport.isEmpty
        // Everything went into an existing mod. Calling `importMods` with
        // nothing would answer "no mods imported", which the guard below reads
        // as a duplicate — a failure report for an install that is going fine.
        ? (<String>[], <String, String>{})
        : plan.combine
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

    if (importedMods.isEmpty && decision.writes.isEmpty) {
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

    // ---- everything the patch answers imply, now the folders exist ---------
    //
    // Shared with the drag/drop import: the writes into an existing mod are
    // update-shaped (deactivate → snapshot → place → reactivate, because this
    // overwrites a folder the user is already using), and the new folders are
    // marked as patch-shaped, which is the record that outlives the warning.
    final patchLines = await applyPatchInstall(
      loc,
      decision: decision,
      importedMods: importedMods,
      modsPath: modsPath,
      applier: UpdateApplier(
        snapshots: ref.read(snapshotServiceProvider),
        activation: ModManagerActivationPort(modManager),
      ),
      amend: modManager.updateModOrigin,
      // Naming what a patch patches is an instruction to install that mod into
      // the folder, not just a note about it.
      installBase: (modName, base, baseFile) => installNamedBase(
        context,
        ref,
        modName: modName,
        modsPath: modsPath,
        base: base,
        file: baseFile,
        characterId: remote.characterId,
      ),
      // This download came off a mod page, so the patch has an identity to
      // record against the mod it went into.
      patch: PatchIdentity(
        modId: mod.idRow,
        fileId: file.idRow,
        version: file.version,
        versionLabel: file.description,
        archiveMd5: archiveMd5,
      ),
    );

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
    // not worth a sentence. What is left is what they cannot find out any other
    // way, each of which changes what they do next. Each is its own warning
    // beside the success rather than more body text under it, so a mod that
    // arrived broken doesn't read like a mod that arrived.
    final warnings = <NotificationLines>[
      ...patchLines,
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
      // Scratch we own, not the user's data: debug is the right level.
      Logger('fileops').debug('temp cleanup failed',
          fields: {'path': folderPath, 'reason': '$e'});
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
    // Left behind, it becomes `mod (2).rar` on the next download — the launch
    // sweep is what cleans up after this.
    Logger('fileops').warning('could not delete a consumed archive',
        error: e, fields: {'archive': archiveFile.path});
  }
}
