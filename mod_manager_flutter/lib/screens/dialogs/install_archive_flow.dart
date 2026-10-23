import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;

import '../../l10n/app_localizations.dart';
import '../../models/character_info.dart';
import '../../models/gamebanana/gamebanana.dart';
import '../../models/install_result.dart';
import '../../models/mod_origin_seed.dart';
import '../../models/origin_enums.dart';
import '../../services/api_service.dart';
import '../../services/archive_service.dart';
import '../../services/download/download_job.dart';
import '../../services/download/download_queue.dart';
import '../../services/gamebanana/remote_mod_metadata.dart';
import '../../services/import_result.dart';
import '../../services/log/confirmations.dart';
import '../../services/log/logger.dart';
import '../../services/mod_manager_service.dart';
import '../../services/patch_scan.dart';
import '../../services/update_apply/mod_activation_port.dart';
import '../../services/update_apply/update_applier.dart';
import '../../utils/gamebanana_url.dart';
import '../../utils/notification_actions.dart';
import '../../utils/notifications.dart';
import '../../utils/state_providers.dart';
import '../../utils/zzz_characters.dart';
import '../components/extract_failure_message.dart';
import '../components/import_failure_message.dart';
import 'archive_password_dialog.dart';
import 'duplicate_archive_dialog.dart';
import 'import_selection_dialog.dart';
import 'patch_install_flow.dart';
import 'patch_install_prompt.dart';

final Logger _files = Logger('fileops');

/// What an install keeps between its runs in the install slot: what the unpack produced and the answers so far.
///
/// Held on the waiting job ([DownloadJob.prepared]) so the answer and the finish need not unpack again: extraction is
/// the slow step and scales with the archive (`docs/downloads.md` §10).
class PreparedInstall {
  const PreparedInstall({
    this.folders = const <String>[],
    this.archiveMd5,
    this.shaderSources = const <String, String>{},
    this.duplicateAnswered = false,
    this.installedAs = const <String>[],
    this.plan,
    this.scan,
    this.destinations,
  });

  /// The unpacked folders in their `zzz_archive_extract_*` directory. Empty while the archive waits for its password.
  final List<String> folders;

  final String? archiveMd5;
  final Map<String, String> shaderSources;

  /// The already-installed question is settled: nothing matched, or the user chose Install anyway.
  final bool duplicateAnswered;

  /// The library mods the identical archive was installed as.
  final List<String> installedAs;

  /// Which folders to install and how; set once one folder came out, or the user picked.
  final ImportPlan? plan;

  /// Both patch rules about [plan]'s mods, taken with that plan.
  final PlannedPatchScan? scan;

  /// Where each patch goes; empty when nothing looked like a patch. Set once settled.
  final Map<String, PatchDestination>? destinations;

  bool get unpacked => folders.isNotEmpty;

  PreparedInstall copyWith({
    bool? duplicateAnswered,
    List<String>? installedAs,
    ImportPlan? plan,
    PlannedPatchScan? scan,
    Map<String, PatchDestination>? destinations,
  }) =>
      PreparedInstall(
        folders: folders,
        archiveMd5: archiveMd5,
        shaderSources: shaderSources,
        duplicateAnswered: duplicateAnswered ?? this.duplicateAnswered,
        installedAs: installedAs ?? this.installedAs,
        plan: plan ?? this.plan,
        scan: scan ?? this.scan,
        destinations: destinations ?? this.destinations,
      );
}

/// What one run of the install in the slot came to.
sealed class InstallStep {
  const InstallStep();
}

/// The install stopped at [wait], keeping [prepared], and frees the slot.
class InstallWaits extends InstallStep {
  const InstallWaits(this.wait, this.prepared);

  final InstallWait wait;
  final PreparedInstall prepared;
}

/// The install ended with [result].
class InstallEnds extends InstallStep {
  const InstallEnds(this.result);

  final InstallResult result;
}

/// Runs a downloaded job's install in the slot. The real one is [runArchiveInstall]; a test substitutes its own so
/// the host's sequencing can be exercised without 7z, a mods folder or the network.
typedef ArchiveInstaller = Future<InstallStep> Function(BuildContext context, WidgetRef ref, DownloadJob job);

/// What answering a waiting job's question came to.
sealed class InstallAnswer {
  const InstallAnswer();
}

/// Answered: the job goes back in line with [prepared], or with [password] for the unpack still to run.
class AnswerGiven extends InstallAnswer {
  const AnswerGiven({this.prepared, this.password});

  final PreparedInstall? prepared;
  final String? password;
}

/// A dialog closed without an answer: the job still waits, at [wait], keeping any answers given before it in
/// [prepared].
class AnswerKept extends InstallAnswer {
  const AnswerKept(this.wait, {this.prepared});

  final InstallWait wait;
  final PreparedInstall? prepared;
}

/// Don't install.
class AnswerDeclined extends InstallAnswer {
  const AnswerDeclined();
}

/// Open mod page: the job still waits, and the mod's page opens in Browse.
class AnswerOpenModPage extends InstallAnswer {
  const AnswerOpenModPage();
}

/// Answers a waiting job's question. The real one is [answerInstallQuestion]; a test substitutes its own.
typedef InstallQuestionAsker = Future<InstallAnswer> Function(BuildContext context, WidgetRef ref, DownloadJob job);

/// Turning a downloaded GameBanana archive into a mod folder: the prepare and the finish, the two parts that run in
/// the install slot (`docs/downloads.md` §10).
///
/// **It never opens a window.** It unpacks behind the download's Working card and, where it needs the user, returns
/// [InstallWaits] with the first question that needs asking, in order: the password (before the unpack), already
/// installed, several folders, a patch. Only [answerInstallQuestion], pressed from the panel, asks.
///
/// A job that has waited carries what this kept ([DownloadJob.prepared]), and the run picks up at the first question
/// still open. With none, it finishes.
///
/// **The caller must supply a long-lived context.** Every `loc.t` needs one, and the finish can open the update
/// flow's window for a patch's named base. `DownloadQueueHost` is the caller in production, mounted above the tab
/// switcher for exactly that reason.
///
/// **Only the download is shared with the update path.** This imports the archive as a *new* mod folder while
/// `applyUpdateFlow` overwrites an existing one; folding the two together is what would produce a shared "install"
/// that quietly does the wrong one.
Future<InstallStep> runArchiveInstall(BuildContext context, WidgetRef ref, DownloadJob job) async {
  final loc = context.loc;
  final container = ProviderScope.containerOf(context, listen: false);
  final archiveFile = job.archive!;

  var prepared = job.prepared as PreparedInstall? ?? const PreparedInstall();

  if (!prepared.unpacked) {
    final modsPath = (await ApiService.getConfig())['mods_path'] ?? '';
    // Before the unpack, so the archive is kept for the user to retry from.
    if (modsPath.isEmpty) {
      return InstallEnds(InstallResult.error(
        loc.t('marketplace.install_missing_path_title'),
        loc.t('marketplace.install_missing_path_body'),
        actions: [openSettingsAction(loc, container)],
      ));
    }

    // A locked archive given no password is refused by the unpack's own listing, before anything is written.
    final extraction = await ArchiveService.extractArchive(
      archiveFile: archiveFile,
      knownMd5: job.result?.md5,
      // What the download asked to be called, which is not always what it ended up called: a name already taken in
      // the downloads folder becomes `mod (2).rar`, and for an archive with no folder inside it that would become
      // the mod's name.
      nameHint: job.result?.requestedName,
      password: job.password,
    );
    container.read(downloadQueueProvider.notifier).dropPassword(job.seq);

    switch (extraction.failure) {
      case ExtractFailure.wrongPassword:
        return InstallWaits(const InstallWait(InstallQuestion.password, passwordFailed: true), prepared);
      case ExtractFailure.passwordRequired:
        return InstallWaits(const InstallWait(InstallQuestion.password), prepared);
      default:
        break;
    }

    if (!extraction.success) {
      // Keep the archive: the user can still extract it by hand, and telling them where it is turns a dead end
      // into a workaround.
      final lines = extractFailureMessage(
        loc,
        archivePath: archiveFile.path,
        reason: extraction.failure ?? ExtractFailure.other,
        requiredBytes: extraction.requiredBytes,
        availableBytes: extraction.availableBytes,
        notify: container.read(notificationsProvider.notifier),
      );
      return InstallEnds(InstallResult.error(lines.title, lines.body, actions: lines.actions));
    }
    // Unpacked, so the archive is spent: the job holds the folders from here.
    await _safeDeleteArchive(archiveFile);

    final folders = extraction.extractedFolders ?? const <String>[];
    if (folders.isEmpty) {
      return InstallEnds(InstallResult.warning(
        loc.t('marketplace.install_empty_title'),
        loc.t('marketplace.install_empty_body'),
      ));
    }
    prepared = PreparedInstall(
      folders: folders,
      archiveMd5: extraction.archiveMd5 ?? job.result?.md5,
      shaderSources: extraction.shaderSources,
    );
  }

  try {
    // Each question's test, without asking it.
    if (!prepared.duplicateAnswered) {
      final installedAs = await installsOfArchiveNow(ref, prepared.archiveMd5);
      if (installedAs.isNotEmpty) {
        return InstallWaits(
          InstallWait(InstallQuestion.alreadyInstalled, installedAs: installedAs),
          prepared.copyWith(installedAs: installedAs),
        );
      }
      prepared = prepared.copyWith(duplicateAnswered: true);
    }

    if (prepared.plan == null) {
      if (prepared.folders.length > 1) {
        return InstallWaits(
          InstallWait(InstallQuestion.severalFolders, folderCount: prepared.folders.length),
          prepared,
        );
      }
      prepared = prepared.copyWith(plan: _singlePlan(prepared.folders));
    }

    if (prepared.destinations == null) {
      final plan = prepared.plan!;
      final scan = prepared.scan ?? await scanPlannedMods(plannedMods(plan, plan.folders));
      if (scan.patchShaped.isNotEmpty) {
        return InstallWaits(const InstallWait(InstallQuestion.patch), prepared.copyWith(scan: scan));
      }
      prepared = prepared.copyWith(scan: scan, destinations: const <String, PatchDestination>{});
    }
  } catch (_) {
    await ArchiveService.deleteExtraction(prepared.folders);
    rethrow;
  }

  if (!context.mounted) {
    await ArchiveService.deleteExtraction(prepared.folders);
    return InstallEnds(InstallResult.cancelled());
  }
  container.read(downloadQueueProvider.notifier).installStage(job.seq, InstallStage.installing);
  return InstallEnds(await _finish(context, ref, job, prepared));
}

/// Answers a waiting job's question from [context], the host's, which outlives the panel.
///
/// Answering runs the questions after it in the same sitting, since the user is now at the screen: Install anyway is
/// followed by the folder picker when several folders came out, and a folder pick by the patch scan of that
/// selection and, when it finds a patch, the prompt. A dialog closed without an answer keeps the job waiting at that
/// question with the answers before it; only Don't install, in the password dialog or the patch prompt, ends it.
///
/// For [InstallQuestion.alreadyInstalled] this is the row's Install anyway, so it needs no dialog of its own.
Future<InstallAnswer> answerInstallQuestion(
  BuildContext context,
  WidgetRef ref,
  DownloadJob job, {
  Future<PatchPromptAnswer?> Function(
    BuildContext context, {
    required List<PatchInstallSubject> subjects,
    required List<ModInfo> library,
    bool combined,
  })? prompt,
}) async {
  final wait = job.wait!;
  var prepared = job.prepared as PreparedInstall? ?? const PreparedInstall();

  if (wait.question == InstallQuestion.password) {
    final answer = await showArchivePasswordDialog(
      context,
      modName: job.subject,
      failed: wait.passwordFailed,
      offerModPage: job.mod != null,
    );
    return switch (answer) {
      null => AnswerKept(wait, prepared: prepared),
      PasswordDeclined() => const AnswerDeclined(),
      PasswordOpenModPage() => const AnswerOpenModPage(),
      PasswordGiven(:final password) => AnswerGiven(prepared: prepared, password: password),
    };
  }

  if (wait.question == InstallQuestion.alreadyInstalled) {
    logConfirmation('install.duplicate', accepted: true, subject: job.subject, fields: {'installed_as': wait.installedAs});
    prepared = prepared.copyWith(duplicateAnswered: true);
  }

  if (prepared.plan == null) {
    if (prepared.folders.length > 1) {
      if (!context.mounted) return AnswerKept(wait, prepared: prepared);
      final plan = await resolveImportSelection(
        context,
        prepared.folders,
        // From the name the download **asked for**: a collision suffix has no business in the folder picker.
        defaultCombinedName: path.basenameWithoutExtension(job.result?.requestedName ?? job.archive?.path ?? job.subject),
        shaderSources: prepared.shaderSources,
      );
      if (plan == null) {
        return AnswerKept(
          InstallWait(InstallQuestion.severalFolders, folderCount: prepared.folders.length),
          prepared: prepared,
        );
      }
      prepared = prepared.copyWith(plan: plan);
    } else {
      prepared = prepared.copyWith(plan: _singlePlan(prepared.folders));
    }
  }

  if (prepared.destinations == null) {
    final plan = prepared.plan!;
    final scan = prepared.scan ?? await scanPlannedMods(plannedMods(plan, plan.folders));
    prepared = prepared.copyWith(scan: scan);
    if (scan.patchShaped.isEmpty) {
      prepared = prepared.copyWith(destinations: const <String, PatchDestination>{});
    } else {
      final modsPath = (await ApiService.getConfig())['mods_path'] ?? '';
      final question = await preparePatchQuestion(
        scan: scan,
        combined: plan.combine,
        modsPath: modsPath,
        patchModId: job.mod?.idRow,
        patchFileId: job.file.idRow,
        // What the author says this needs. For a patch that is sometimes the mod being patched, and where the
        // library holds it, it leads the destinations with the author's own words on it.
        patchRequirements: job.mod?.requirements ?? const <GbRequirement>[],
      );
      const patchWait = InstallWait(InstallQuestion.patch);
      if (!context.mounted) return AnswerKept(patchWait, prepared: prepared);
      final answer = await (prompt ?? askPatchInstall)(
        context,
        subjects: question.subjects,
        library: question.library,
        combined: question.combined,
      );
      if (answer == null) return AnswerKept(patchWait, prepared: prepared);
      logPatchAnswer(question, answer.destinations);
      if (answer.declined) return const AnswerDeclined();
      prepared = prepared.copyWith(destinations: answer.destinations);
    }
  }

  return AnswerGiven(prepared: prepared);
}

ImportPlan _singlePlan(List<String> folders) =>
    ImportPlan(folders: List<String>.from(folders), combine: false, combinedName: '');

/// The finish, in the slot: the patch writes planned from the kept answers, the import, the metadata, the patch
/// writes, the named base's download and the result. Deletes the unpacked folders once it has read them.
Future<InstallResult> _finish(BuildContext context, WidgetRef ref, DownloadJob job, PreparedInstall prepared) async {
  final loc = context.loc;
  final container = ProviderScope.containerOf(context, listen: false);
  final mod = job.mod!;
  final file = job.file;
  final plan = prepared.plan!;
  final archiveMd5 = prepared.archiveMd5;

  try {
    // Read again rather than taken from the prepare: the folder can change between the two.
    final modsPath = (await ApiService.getConfig())['mods_path'] ?? '';
    if (modsPath.isEmpty) {
      return InstallResult.error(
        loc.t('marketplace.install_missing_path_title'),
        loc.t('marketplace.install_missing_path_body'),
        actions: [openSettingsAction(loc, container)],
      );
    }

    // The character is often in the archive name rather than the inner folder (or vice versa), so pass the archive
    // base name as an extra detection hint. From the name the download **asked for**.
    final archiveBaseName =
        path.basenameWithoutExtension(job.result?.requestedName ?? job.archive?.path ?? job.subject);

    // **Here rather than at the answer**, because the mod a patch goes into can change between the two; a folder
    // gone by then is the `goneMod` refusal.
    final destinations = prepared.destinations ?? const <String, PatchDestination>{};
    final scan = prepared.scan ?? await scanPlannedMods(plannedMods(plan, plan.folders));
    final decision = destinations.isEmpty
        ? PatchInstallDecision(scan: scan)
        : await resolvePatchDestinations(
            scan: scan,
            destinations: destinations,
            folders: plan.folders,
            modsPath: modsPath,
          );

    // **The folders going into an existing mod are not imported at all.** No new mod folder exists at the end of
    // that branch — the library mod the user picked is the one that ends up holding both downloads — so they are
    // taken out of the import and written afterwards, by the update machinery rather than by `importMods`.
    final directoriesToImport = [...plan.folders]..removeWhere(decision.excludes);

    // Every folder came out of this one archive, so one seed covers all of them; `archiveMd5` is null-or-exact and a
    // null merely costs the fast path at resolution time.
    final effectiveSeed = _seedFor(mod, file, archiveMd5: archiveMd5);

    // The character is told to the import rather than left to the autofill below, because that fills absence only,
    // and name detection would already have filled the slot with its guess. The two disagree in exactly the case
    // that matters: a Zhao skin named "Zhao Nicole" reads as Nicole, since the longest matching term wins. Unassigned
    // is told too, for a page that names no character, so the mod is filed there rather than under a guess.
    final character = job.characterId;
    final page = RemoteModMetadata.fromMod(mod);
    final remote = RemoteModMetadata(
      description: page.description,
      tags: page.tags,
      // Unassigned is stored as absence, so the autofill never writes the placeholder.
      characterId: storedCharacterId(character),
      imageUrls: page.imageUrls,
    );

    // A later file of the same mod page goes in beside an earlier one's folder of the same name rather than being
    // skipped: the picked variants of one mod often share an inner folder name.
    final installedFromPage = _installedFromPage(container, job);
    final reserved = <String>{};
    Future<String> nameFor(String name) async {
      if (!installedFromPage.contains(name) || await _isFree(modsPath, name)) return name;
      final distinct = await _distinctName(modsPath, name, file, reserved);
      reserved.add(distinct);
      return distinct;
    }

    final targetNames = <String, String>{};
    if (!plan.combine) {
      for (final dir in directoriesToImport) {
        final name = await nameFor(path.basename(dir));
        if (name != path.basename(dir)) targetNames[dir] = name;
      }
    }

    final ModManagerService modManager = await ref.read(modManagerServiceProvider.future);
    // The auto-tag map the import returns is deliberately dropped here: the character is the mod page's, or
    // Unassigned when the page names none, so nothing was detected for it to report.
    final importResult = directoriesToImport.isEmpty
        // Everything went into an existing mod. Calling `importMods` with nothing would answer "no mods imported",
        // which the guard below reads as a duplicate — a failure report for an install that is going fine.
        ? const ImportResult.nothing()
        : plan.combine
            ? await modManager.importCombinedMod(
                directoriesToImport,
                await nameFor(plan.combinedName),
                detectionHint: archiveBaseName,
                origin: effectiveSeed,
                knownCharacter: character,
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
                    if (character != null) dir: character,
                },
                targetNames: targetNames,
              );

    final importedMods = importResult.imported;

    // A refusal is reported as itself: "you already have this mod" is the one thing that is certainly untrue when
    // the volume was full or the copy threw.
    if (importResult.failure case final failure?) {
      final lines = importFailureMessage(
        loc,
        failure,
        requiredBytes: importResult.requiredBytes,
        availableBytes: importResult.availableBytes,
        container: container,
      );
      return InstallResult.error(lines.title, lines.body, actions: lines.actions);
    }

    if (importedMods.isEmpty && decision.writes.isEmpty) {
      return InstallResult.note(
        loc.t('marketplace.install_duplicate_title'),
        loc.t('marketplace.install_duplicate_body'),
      );
    }

    // The mod page we downloaded from knows everything a fresh install otherwise lacks — description, gallery,
    // tags. Fill only what is still blank (an archive can arrive carrying the author's own sidecar, and that text is
    // better than ours). After the import, deliberately: the folders have to exist.
    //
    // Its result is not reported: filling in a description and a gallery is what an install is *for*.
    await modManager.applyRemoteMetadata(importedMods, remote);
    // The page is in hand, so the card and the details panel can name its file and author now rather than after a
    // check.
    keepModPages(ref, {mod.idRow: mod});

    // Shared with the drag/drop import: the writes into an existing mod are update-shaped (deactivate → snapshot →
    // place → reactivate, because this overwrites a folder the user is already using), and the new folders are
    // marked as patch-shaped, which is the record that outlives the warning.
    final patchLines = await applyPatchInstall(
      loc,
      decision: decision,
      importedMods: importedMods,
      modsPath: modsPath,
      applier: UpdateApplier(
        snapshots: ref.read(snapshotServiceProvider),
        activation: ModManagerActivationPort(modManager, leaveOff: (m) => leftOffAfterWrite(container, m)),
      ),
      amend: modManager.updateModOrigin,
      onPatched: modManager.invalidateKeybinds,
      onPatchedInto: (modId) => forgetUpdateCheck(container, modId),
      whileWriting: (modId, write) => whileWritingMod(container, modId, write),
      // Naming what a patch patches is an instruction to install that mod into the folder, not just a note about
      // it. Its download keeps its window, since the user asked for it in the answer a moment before.
      installBase: (modName, base, baseFile) => installNamedBase(
        context,
        ref,
        modName: modName,
        modsPath: modsPath,
        base: base,
        file: baseFile,
        characterId: remote.characterId,
      ),
      // This download came off a mod page, so the patch has an identity to record against the mod it went into.
      patch: PatchIdentity(
        modId: mod.idRow,
        name: mod.name,
        fileId: file.idRow,
        version: file.version,
        versionLabel: file.description,
        archiveMd5: archiveMd5,
      ),
    );

    // Drained, so it is reported at most once: nothing re-attempts an origin write, because it happens at ingest and
    // never during a scan. Drained *before* the mounted check below on purpose — if this context is gone the message
    // is lost, which is better than leaving the names queued for the next install to blame on the wrong archive.
    final originFailures = modManager.takeOriginWriteFailures();

    // Every `loc.t` below reads an inherited widget, and the autofill above can run for seconds. Under
    // `DownloadQueueHost` the context lives as long as the app; the check stays because the app can be shutting
    // down. Success, not `cancelled()` — the mod is installed and its metadata is filled; the only thing lost is
    // the sentence describing it.
    if (!context.mounted) {
      return InstallResult.success(importedMods, characterId: remote.characterId);
    }

    // **Only what the user has to act on**, each its own warning beside the success.
    final warnings = <NotificationLines>[
      ...patchLines,
      if (originFailures.isNotEmpty)
        NotificationLines(
          loc.t('mods.snackbar.origin_write_failed_title'),
          loc.t('mods.snackbar.origin_write_failed_body', params: {'mods': originFailures.join(', ')}),
        ),
    ];

    return InstallResult.success(importedMods, warnings: warnings, characterId: remote.characterId);
  } finally {
    // The import and the patch writes have read them.
    await ArchiveService.deleteExtraction(prepared.folders);
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
    name: mod.name,
    fileId: file.idRow,
    version: file.version,
    versionLabel: file.description,
    versionConfidence: OriginConfidence.exact,
  );
}

/// The mod folders other downloads of [job]'s mod page installed this session, by the rows still in the queue.
Set<String> _installedFromPage(ProviderContainer container, DownloadJob job) => {
      for (final other in container.read(downloadQueueProvider))
        if (other.seq != job.seq && other.mod?.idRow == job.mod?.idRow && other.outcome == JobOutcome.installed)
          ...other.installed,
    };

/// Whether nothing in the library, a link included, has the name [name].
Future<bool> _isFree(String modsPath, String name) async =>
    await FileSystemEntity.type(path.join(modsPath, name), followLinks: false) == FileSystemEntityType.notFound;

/// A free mod folder name for [name] from [file]: its variant label in brackets, `Ellen (white hair ver)`, then a
/// number after that. Never one of [reserved].
Future<String> _distinctName(String modsPath, String name, GbFile file, Set<String> reserved) async {
  final label = _variantLabel(file);
  final base = label == null ? name : '$name ($label)';
  Future<bool> free(String candidate) async => !reserved.contains(candidate) && await _isFree(modsPath, candidate);
  if (label != null && await free(base)) return base;
  for (var n = 2;; n++) {
    final candidate = '$base ($n)';
    if (await free(candidate)) return candidate;
  }
}

/// The file's variant label (`_sDescription`), else its file name, made fit for a folder name. Null when neither
/// leaves anything.
String? _variantLabel(GbFile file) {
  final description = file.description?.trim() ?? '';
  final raw = description.isNotEmpty ? description : path.basenameWithoutExtension(file.file ?? '');
  var label = raw
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (label.length > 40) label = label.substring(0, 40);
  // Windows refuses a folder name ending in a dot or a space.
  label = label.replaceAll(RegExp(r'[. ]+$'), '');
  return label.isEmpty ? null : label;
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
    _files.warning('could not delete a consumed archive', error: e, fields: {'archive': archiveFile.path});
  }
}
