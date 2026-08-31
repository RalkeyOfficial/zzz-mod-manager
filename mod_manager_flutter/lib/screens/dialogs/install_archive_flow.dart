import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;

import '../../l10n/app_localizations.dart';
import '../../models/gamebanana/gamebanana.dart';
import '../../models/install_result.dart';
import '../../models/mod_companion.dart';
import '../../models/mod_ingest.dart';
import '../../models/mod_origin.dart';
import '../../models/mod_origin_seed.dart';
import '../../models/origin_enums.dart';
import '../../services/api_service.dart';
import '../../services/archive_service.dart';
import '../../services/folder_contents.dart';
import '../../services/gamebanana/remote_mod_metadata.dart';
import '../../services/mod_manager_service.dart';
import '../../services/patch_detection.dart';
import '../../services/patch_placement.dart';
import '../../services/patch_scan.dart';
import '../../services/update_apply/mod_activation_port.dart';
import '../../services/update_apply/update_applier.dart';
import '../../utils/gamebanana_url.dart';
import '../../utils/notifications.dart';
import '../../utils/state_providers.dart';
import '../components/extract_failure_message.dart';
import 'duplicate_archive_dialog.dart';
import 'import_selection_dialog.dart';
import 'patch_install_prompt.dart';

/// The mods [plan] is about to create, in the shape the copy will create them.
///
/// A `separate` install makes one mod per folder, named after it; a `combined`
/// one makes a single mod whose subfolders are named after each source — the
/// same names `importMods` and `importCombinedMod` produce, which is what keeps
/// a pre-import answer and a post-import one about the same folder in agreement.
List<PlannedMod> _plannedMods(ImportPlan plan, List<String> folders) =>
    plan.combine
        ? [
            PlannedMod(
              name: plan.combinedName,
              sources: {
                for (final dir in folders) dir: path.basename(dir),
              },
            ),
          ]
        : [
            for (final dir in folders)
              PlannedMod(name: path.basename(dir), sources: {dir: ''}),
          ];

/// One patch write the install has worked out and not yet performed.
class _PlannedPatchWrite {
  const _PlannedPatchWrite({
    required this.into,
    required this.source,
    required this.incoming,
    required this.existing,
    required this.placement,
  });

  final InstallIntoMod into;
  final Directory source;
  final FolderContents incoming;
  final FolderContents existing;
  final PatchPlacement placement;
}

/// Why a patch could not be written into the mod that was chosen for it.
///
/// Two causes, told apart because they call for different things from the user.
enum _PatchRefusal {
  /// Nothing in the patch matches anything in the target — almost certainly the
  /// wrong mod. A snapshot is not a reason to find out the expensive way.
  wrongMod,

  /// The target holds its own files **twice** (`sfw/body.dds` beside
  /// `nsfw/body.dds`). No install path creates that shape: the import picker
  /// settles separate-or-combined before anything is copied. So it was
  /// assembled by hand outside that flow, and a patch written blind into a
  /// folder that is already wrong makes it worse rather than better — the
  /// folder is what needs sorting out, not this install.
  brokenMod,

  /// The chosen folder is not there any more.
  goneMod,
}

/// Works out where a patch's files would land, or **why they cannot**.
///
/// The caller turns a refusal into an ordinary new-mod install and says which
/// one it was, so the download is never lost to it.
Future<({_PlannedPatchWrite? write, _PatchRefusal? refusal})> _planPatchWrite({
  required Directory source,
  required String modsPath,
  required InstallIntoMod into,
}) async {
  final target = Directory(path.join(modsPath, into.modId));
  if (!await target.exists()) {
    return (write: null, refusal: _PatchRefusal.goneMod);
  }

  final incoming = await readFolderContents(source);
  final existing = await readFolderContents(target);
  final placement = resolvePatchPlacement(
    incoming: incoming.files,
    target: existing.files,
  );
  if (placement.needsChoice) {
    return (write: null, refusal: _PatchRefusal.brokenMod);
  }
  if (placement.matchedNothing) {
    return (write: null, refusal: _PatchRefusal.wrongMod);
  }

  return (
    write: _PlannedPatchWrite(
      into: into,
      source: source,
      incoming: incoming,
      existing: existing,
      placement: placement,
    ),
    refusal: null,
  );
}

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

    // **Both patch rules, before the copy.** The answer exists as soon as the
    // archive is unpacked, and asking here is what will let the install ask
    // where a patch belongs rather than warn about it afterwards.
    //
    // It has to be scoped by the picker above, which is what decides where one
    // resulting mod ends and the next begins — judged folder by folder, an
    // ordinary combined mod reads as a patch. `scanPlannedMods` owns that.
    final scan = await scanPlannedMods(_plannedMods(plan, directoriesToImport));

    // Asked here rather than left to a warning the user has to go and act on:
    // finding the folder again among the rest of the library was the whole of
    // the cost, and nothing about the answer is easier to give later.
    var destinations = const <String, PatchDestination>{};
    if (scan.patchShaped.isNotEmpty) {
      if (!context.mounted) return InstallResult.cancelled();
      final answered = await showPatchInstallPrompt(
        context,
        subjects: [
          for (final name in scan.patchShaped)
            PatchInstallSubject(
              modName: name,
              patchModId: mod.idRow,
              kind: scan.assetPatches.containsKey(name)
                  ? PatchKind.assets
                  : PatchKind.references,
            ),
        ],
        library: ref.read(modsProvider),
        combined: plan.combine,
      );
      // Null is "don't install it", which only this prompt can offer: it is the
      // last point before the copy, and a patch with nothing to patch is a
      // folder the user may well not want.
      if (answered == null) {
        await _cleanupExtractedFolders(directoriesToImport);
        return InstallResult.cancelled();
      }
      destinations = answered;
    }

    // **The folders going into an existing mod are not imported at all.** No
    // new mod folder exists at the end of that branch — the library mod the
    // user picked is the one that ends up holding both downloads — so they are
    // taken out of the import and written afterwards, by the update machinery
    // rather than by `importMods`.
    final sourceOfPlanned = <String, String>{
      for (final dir in directoriesToImport) path.basename(dir): dir,
    };

    // Resolved **before** the folder is taken out of the import, so a target
    // the placement cannot settle still has a way back: the download becomes an
    // ordinary new mod rather than being lost.
    final planned = <String, _PlannedPatchWrite>{};
    final refused = <_PatchRefusal, List<String>>{};
    for (final entry in destinations.entries) {
      if (entry.value is! InstallIntoMod) continue;
      final into = entry.value as InstallIntoMod;
      final source = sourceOfPlanned[entry.key];
      if (source == null) continue;

      final outcome = await _planPatchWrite(
        source: Directory(source),
        modsPath: modsPath,
        into: into,
      );
      if (outcome.write case final write?) {
        planned[entry.key] = write;
      } else {
        refused
            .putIfAbsent(outcome.refusal!, () => <String>[])
            .add(into.modName);
      }
    }
    directoriesToImport.removeWhere(
      (dir) => planned.containsKey(path.basename(dir)),
    );

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

    if (importedMods.isEmpty && planned.isEmpty) {
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

    // ---- the patches going into an existing mod -----------------------------
    //
    // Update-shaped, not install-shaped: deactivate → snapshot → place →
    // reactivate, because this writes over a folder the user is already using
    // and the snapshot is the only way back.
    final patchedInto = <String, InstallIntoMod>{};
    final patchFailures = <String>[];
    if (planned.isNotEmpty) {
      final applier = UpdateApplier(
        snapshots: ref.read(snapshotServiceProvider),
        activation: ModManagerActivationPort(modManager),
      );
      for (final entry in planned.entries) {
        final write = entry.value;
        final result = await applier.applyPatchInto(
          modName: write.into.modId,
          modFolder: Directory(path.join(modsPath, write.into.modId)),
          source: write.source,
          incoming: write.incoming,
          existing: write.existing,
          placement: write.placement,
        );
        if (!result.success) {
          patchFailures.add(write.into.modName);
          continue;
        }
        patchedInto[entry.key] = write.into;

        // **On the target, and at `exact`.** The folder is still the base mod —
        // that is what its `origin` says and what it mostly is — and the patch
        // is the second thing in it. This is the one path to `exact` on a
        // companion: every other route is the user telling us about bytes they
        // moved in themselves.
        await modManager.updateModOrigin(write.into.modId, (current) {
          final base = current ??
              const ModOrigin(provenance: OriginProvenance.importedFolder);
          return base.copyWith(companions: [
            for (final companion in base.companions)
              if (companion.modId != mod.idRow) companion,
            ModCompanion(
              role: CompanionRole.patch,
              modId: mod.idRow,
              modIdConfidence: OriginConfidence.exact,
              fileId: file.idRow,
              version: file.version,
              versionLabel: file.description,
              versionConfidence: OriginConfidence.exact,
              archiveMd5: archiveMd5,
            ),
          ]);
        });
      }
    }

    // The scan ran against what the install *planned*, and a folder that
    // already existed was skipped rather than replaced — so nothing may be
    // said about a mod that is not actually here. The post-import scan got
    // this for free by only ever seeing installed folders.
    final patches = scan.iniPatches.where(importedMods.contains).toList();
    final incomplete = scan.incomplete.where(importedMods.contains).toList();
    final assetPatches = <String, AssetPatchAssessment>{
      for (final entry in scan.assetPatches.entries)
        if (importedMods.contains(entry.key)) entry.key: entry.value,
    };
    // What the user said each new folder patches, when they said. Only branch A
    // has one — branch B's answer is the destination itself.
    final namedBases = <String, ModCompanion>{
      for (final entry in destinations.entries)
        if (entry.value case InstallAsNewMod(base: final base?))
          entry.key: base,
    };
    List<String> unanswered(List<String> names) =>
        [for (final name in names) if (!namedBases.containsKey(name)) name];

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
        final base = namedBases[name];
        return current.copyWith(
          ingest: ModIngest(
            mode: ingest.mode,
            folders: ingest.folders,
            siblingGroup: ingest.siblingGroup,
            patchShaped: true,
          ),
          // Only ever added, never cleared: an unanswered prompt is the user
          // not saying, which is not the same as them saying there is nothing.
          companions: base == null
              ? current.companions
              : [
                  for (final companion in current.companions)
                    if (companion.role != CompanionRole.base) companion,
                  base,
                ],
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
      // **A change the user cannot see reports its success.** The patch went
      // into somebody else's folder, so there is no new card to look at — and
      // the one thing they need to know is that a copy was saved first.
      for (final into in patchedInto.values)
        NotificationLines(
          loc.t('mods.snackbar.patch_applied_title'),
          loc.t('mods.snackbar.patch_applied_body',
              params: {'mod': into.modName}),
        ),
      if (patchFailures.isNotEmpty)
        NotificationLines(
          loc.t('mods.snackbar.patch_write_failed_title'),
          loc.t('mods.snackbar.patch_write_failed_body',
              params: {'mods': patchFailures.join(', ')}),
          pinned: true,
        ),
      // Each refusal names its own cause, because they ask different things of
      // the user: one is "you picked the wrong mod", the other is "that mod's
      // folder needs sorting out". Both explain a folder the user did not ask
      // for — the download became an ordinary new mod rather than being lost.
      if (refused[_PatchRefusal.wrongMod] case final mods?)
        NotificationLines(
          loc.t('mods.snackbar.patch_wrong_mod_title'),
          loc.t('mods.snackbar.patch_wrong_mod_body',
              params: {'mods': mods.join(', ')}),
          pinned: true,
        ),
      if (refused[_PatchRefusal.brokenMod] case final mods?)
        NotificationLines(
          loc.t('mods.snackbar.patch_broken_mod_title'),
          loc.t('mods.snackbar.patch_broken_mod_body',
              params: {'mods': mods.join(', ')}),
          pinned: true,
        ),
      if (refused[_PatchRefusal.goneMod] case final mods?)
        NotificationLines(
          loc.t('mods.snackbar.patch_gone_mod_title'),
          loc.t('mods.snackbar.patch_gone_mod_body',
              params: {'mods': mods.join(', ')}),
        ),
      if (incomplete.isNotEmpty)
        NotificationLines(
          loc.t('mods.snackbar.import_no_ini_title'),
          loc.t('mods.snackbar.import_no_ini_body',
              params: {'mods': incomplete.join(', ')}),
        ),
      // **Only the ones nobody answered for.** A patch whose base mod the user
      // just named in a modal has been told about already, and its card carries
      // the mark; a pinned card repeating it is nagging.
      if (unanswered(patches) case final named when named.isNotEmpty)
        NotificationLines(
          loc.t('mods.snackbar.import_patch_title'),
          loc.t('mods.snackbar.import_patch_body',
              params: {'mods': named.join(', ')}),
          // The one install warning that must not time out: the mod does not
          // work until the user acts, and this card is raised beside the
          // success line they were actually waiting for.
          pinned: true,
        ),
      // Named separately from the `.ini` case because the evidence is
      // different: this download brought content nothing can load, rather than
      // asking for content it did not bring.
      for (final name in assetPatches.keys)
        if (!namedBases.containsKey(name))
          NotificationLines(
            loc.t('mods.snackbar.import_asset_patch_title'),
            loc.t('mods.snackbar.import_asset_patch_body',
                params: {'mod': name}),
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
