import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;

import '../../l10n/app_localizations.dart';
import '../../models/character_info.dart';
import '../../models/gamebanana/gamebanana.dart';
import '../../models/mod_download.dart';
import '../../services/api_service.dart';
import '../../services/archive_service.dart';
import '../../services/download/download_job.dart';
import '../../services/download/download_queue.dart';
import '../../services/log/confirmations.dart';
import '../../services/update_apply/update_applier.dart';
import '../../services/update_apply/update_prepare.dart';
import '../../services/update_apply/update_write.dart';
import '../../services/update_apply/update_write_route.dart';
import '../../utils/marketplace_providers.dart';
import '../../utils/notification_actions.dart';
import '../../utils/notifications.dart';
import '../../utils/state_providers.dart';
import '../components/extract_failure_message.dart';
import 'archive_password_dialog.dart';
import 'download_with_progress.dart';
import 'import_selection_dialog.dart';
import 'progress_modal.dart';
import 'update_confirm_dialog.dart';
import 'update_flow_outcome.dart';
import 'update_progress_dialog.dart';
import 'update_result_dialog.dart';

export 'update_flow_outcome.dart';

/// Downloading a newer file and writing it over an installed mod, end to end.
///
/// The orchestration lives at the widget layer because it is a conversation: download, then show what is about to happen, then write only if the user agrees.
/// The work between the questions is not here: `prepareUpdate` unpacks and previews and says what has to be answered, and `writeUpdate` writes.
/// Both live in `services/update_apply/`, which knows nothing about dialogs, so this function is the windows and the order they come in.
///
/// The order is the safety argument, and each step exists to make the next one refusable:
///
/// 1. **Download to `<appData>/downloads`.** Cancellable; nothing local has changed yet.
/// 2. **Extract to a temp directory and sanity-check it** (`prepareUpdate`). A failed or half-finished extraction never touches the installed mod.
/// 3. **Preview** (`prepareUpdate`). Patch shape, the old files going, and whether the archive's layout still matches how this mod was installed: every question that can only be asked before the copy.
/// 4. **Ask.** Including the one thing the user must be told rather than discover: keybinds they rebound inside the folder will be reverted by a shipped `.ini`, and the snapshot is the way back.
/// 5. **Apply**, then record what the folder now is (`writeUpdate`).
///
/// **It writes one of the folder's two halves.** A mixed folder holds a base mod
/// and a patch over it, and the rule is the same whichever of them is the
/// folder's own recorded identity: *base first, then patch*. So a write that
/// replaces the **base** takes the patch out, writes the base, and places the
/// patch back on top ([patchFiles]); a write that replaces the **patch** is a
/// placement onto the base's layout and goes through
/// `UpdateApplier.applyPatchInto` instead of this.
///
/// Says how it ended ([UpdateFlowOutcome]); `changed` is true when the mod folder may differ, so the caller rescans.
Future<UpdateFlowOutcome> applyUpdateFlow(
  BuildContext context,
  WidgetRef ref, {
  required ModInfo mod,
  required int remoteModId,
  required GbFile file,

  /// The folder's recorded patch files (`ingest.patch_files`), when this write
  /// replaces the **base** of a folder that also holds a patch. They are set
  /// aside, the base is written, and they are placed back onto its layout.
  ///
  /// Empty means nothing is known to be the patch — either an ordinary
  /// single-download mod, or a mixed folder from before the record existed. The
  /// second is an ordinary overwrite of whatever is in there, and the **caller**
  /// is the one that has to have said so.
  Iterable<String> patchFiles = const <String>[],

  /// Whose store of displaced originals to rebuild as that patch goes back —
  /// see `UpdateWriteRoute.patchModId`. Null leaves any store alone.
  int? patchModId,

  /// True when [remoteModId] is a **companion** of this folder — the mod its
  /// patch applies to — rather than the folder's own identity. Decides which
  /// record the installed file is written against; writing a companion's file
  /// id onto the primary would claim this folder is that other mod.
  bool asCompanion = false,

  /// Whether to ask before writing. False only where the user has just answered
  /// the same question in a modal, which is the one case where confirming again
  /// is asking twice rather than asking.
  bool confirm = true,

  /// This folder holds a patch that **cannot be put back**, because nothing
  /// records which files are its. Stated on the confirmation, where it is the
  /// one loss not already paid for by a rule.
  bool flattensPatch = false,

  /// **Every file the check found newer than what this mod holds**, so a
  /// sibling's own recorded file can be placed against [file].
  ///
  /// Without it the group can only ask "is it on this exact file?", which reads
  /// a member that has since been updated *past* this one as needing it — and
  /// writes it back a version. See `sibling_group.dart`. Empty is safe and
  /// degrades to that older question, so the callers with no check in hand
  /// (a repair, a patch install) lose nothing they had.
  List<GbFile> published = const <GbFile>[],

  /// Whether this is a **repair** — the version already installed, written over
  /// the folder again ([reinstallFlow]).
  ///
  /// Wording only: the operation is identical, and the two screens have to say
  /// which one the user asked for. "Update Ellen?" in front of a reinstall
  /// reads as an offer of something newer.
  bool reinstall = false,

  /// Asks only when the preview has something to say that the caller's own question did not: a layout that cannot be
  /// reconciled, a patch-shaped download, folders the write leaves out, or a patch that cannot be put back. Otherwise
  /// the caller's question is the confirmation. Set by [reinstallFlow], whose dialog states the standard facts.
  bool confirmOnlyIfNeeded = false,
}) async {
  final loc = context.loc;
  final notify = context.notify;
  // **The app's container, not this screen's `ref`.** A group write copies
  // several folders in turn, so the user can be on another tab by the time it
  // lands — and what reached the disk has to reach the library and the update
  // marks whether or not anyone was still watching. `ref` dies with the widget;
  // this does not.
  final container = ProviderScope.containerOf(context, listen: false);

  // `mod` is captured before every await, so its character is safe to read on
  // any path below — including the catch blocks.
  void fail(String title, String body, {List<NotificationAction> actions = const []}) =>
      notify.error(title, body: body, characterId: mod.characterId, actions: actions);

  final config = await ApiService.getConfig();
  final modsPath = config['mods_path'] ?? '';
  if (modsPath.isEmpty) {
    fail(
      loc.t('marketplace.install_missing_path_title'),
      loc.t('marketplace.install_missing_path_body'),
      actions: [openSettingsAction(loc, container)],
    );
    return UpdateFlowOutcome.failed;
  }
  final modFolder = Directory(path.join(modsPath, mod.id));
  if (!await modFolder.exists()) {
    fail(
      loc.t('mods.update_apply.mod_missing_title'),
      loc.t('mods.update_apply.mod_missing', params: {'mod': mod.name}),
    );
    return UpdateFlowOutcome.failed;
  }

  // Over the flow's own window, so it asks only while that window's context lives.
  Future<PasswordAnswer?> askPassword({required bool failed}) async =>
      context.mounted ? showArchivePasswordDialog(context, modName: mod.name, failed: failed) : null;

  if (!context.mounted) return UpdateFlowOutcome.notStarted;
  final navigator = Navigator.of(context, rootNavigator: true);
  // **One window from the press to the question.** The download's modal stays
  // up through the unpacking and the two folder walks below, because closing it
  // there is the same signal the user gets when a job has finished — and on a
  // big archive the silence that follows is long enough to read as one.
  final hold = ProgressHold();
  DownloadStop? stopped;
  final download = await downloadFileWithProgress(
    context,
    ref,
    file,
    characterId: mod.characterId,
    subject: mod.name,
    hold: hold,
    onStopped: (reason) => stopped = reason,
  );
  if (download == null) {
    hold.dispose();
    return outcomeOfStoppedDownload(stopped);
  }

  // **Ended on every path**, in the `finally`: the download stays on the panel
  // until the update ends, as written, failed, or off the list when declined.
  final queue = container.read(downloadQueueProvider.notifier);
  UpdateEnd end = const UpdateDeclined();
  var archiveConsumed = false;
  var openModPage = false;
  Directory? extractRoot;
  // The wait for a write into one folder, which has no modal of its own.
  NotificationHandle? writing;
  try {
    hold.say(loc.t('marketplace.preparing_unpacking'));
    void onUnpacked(UpdateUnpacked unpacked) {
      archiveConsumed = true;
      extractRoot = unpacked.root;
    }

    // A repair (the user asked about one folder) and a companion write (a patch layer is not a folder this archive produced) do not look for the archive's other mods.
    final request = UpdateRequest(
      mod: mod,
      modsPath: modsPath,
      remoteModId: remoteModId,
      file: file,
      patchFiles: patchFiles.toList(),
      patchModId: patchModId,
      asCompanion: asCompanion,
      flattensPatch: flattensPatch,
      published: published,
      reinstall: reinstall,
      previewSiblings: confirm && !reinstall && !asCompanion,
    );
    var prepared = await _prepareAsking(
      container,
      request,
      download: download,
      modName: mod.name,
      ask: askPassword,
      openModPage: () => openModPage = true,
      queue: queue,
      onUnpacked: onUnpacked,
      onPreviewing: () => hold.say(loc.t('marketplace.preparing_comparing')),
    );
    if (prepared == null) {
      // Declined at the password: the archive has nothing left to be used for.
      await deleteConsumedArchive(download.file);
      return UpdateFlowOutcome.declined;
    }

    // **Asked once, whether or not [confirm] is set**: a skipped confirmation covers a question the user already answered,
    // and which folder is the mod is not one anybody has asked. The answer is recorded after the write, so the next update replays it.
    if (prepared case UpdateAsks(question: final FoldersQuestion question)) {
      final FoldersQuestion(:problem, :choices) = question;
      hold.release();
      queue.updateStep(download.seq, UpdateStep.confirming);
      if (!context.mounted) return UpdateFlowOutcome.notStarted;
      final picked = await pickUpdateFolders(
        context,
        mod: mod,
        choices: [for (final choice in choices) ImportFolderChoice(path: choice.path, name: choice.name)],
        modsPath: request.modsPath,
        // The name asked for, as the run's window has it: the file on disk can carry a suffix a name collision added.
        archiveName: file.file ?? download.result.requestedName ?? path.basename(download.file.path),
        heldFileDate: container.read(modUpdateChecksProvider)[mod.id]?.installedFile?.dateAdded,
        reinstall: reinstall,
      );
      final chosen = picked?.folders;
      logConfirmation('update.layout',
          accepted: chosen != null,
          subject: mod.id,
          fields: {
            'problem': problem.name,
            if (chosen != null) 'folders': [for (final folder in chosen) path.basename(folder)],
          });
      if (chosen == null) return UpdateFlowOutcome.declined;
      prepared = await prepareUpdate(
        container,
        request,
        archive: download.file,
        archiveMd5: download.md5,
        foldersAnswer: question.answer(chosen),
      );
    }

    final PreparedFolders ready;
    switch (prepared) {
      case final PreparedFolders folders:
        ready = folders;
      case UpdateUnpackFailed(:final extraction):
        // The archive is kept on purpose: the user can still extract it by hand,
        // and saying where it is turns a dead end into a workaround.
        final lines = extractFailureMessage(
          loc,
          archivePath: download.file.path,
          reason: extraction.failure ?? ExtractFailure.other,
          requiredBytes: extraction.requiredBytes,
          availableBytes: extraction.availableBytes,
          notify: notify,
        );
        fail(lines.title, lines.body, actions: lines.actions);
        end = UpdateFailed(lines.title);
        return UpdateFlowOutcome.failed;
      case UpdateNothingToInstall():
        fail(
          loc.t('marketplace.install_empty_title'),
          loc.t('marketplace.install_empty_body'),
        );
        end = UpdateFailed(loc.t('marketplace.install_empty_title'));
        return UpdateFlowOutcome.failed;
      // The password and the folders question are answered above.
      case UpdateAsks():
        throw StateError('a base update asked a question after the password and the folders were answered');
      case PreparedPatch():
        throw StateError('a base update was prepared as a patch placement');
    }
    final preview = ready.primary.preview;
    final primary = ready.primary;
    final group = ready.group;

    // The question this write asks, if any: a reinstall's own dialog has already said the standard facts.
    final ask = confirm && (!confirmOnlyIfNeeded || confirmationHasNews(preview, flattensPatch: flattensPatch));

    // **Down immediately before the question**, so the two never overlap and
    // there is no gap between them either.
    hold.release();
    if (ask) queue.updateStep(download.seq, UpdateStep.confirming);

    if (!context.mounted) return UpdateFlowOutcome.notStarted;
    final choice = ask
        ? await showUpdateConfirmDialog(
            context,
            mod: mod,
            file: file,
            preview: preview,
            flattensPatch: flattensPatch,
            reinstall: reinstall,
            siblings: group.targets,
            // Carries the primary's own refusal when the group contested its
            // folder — the dialog reads the row's state off this list, so there
            // is no second field to forget.
            refused: group.refused,
            otherFolders: group.otherFolders,
          )
        : const UpdateConfirmChoice();
    if (ask) {
      // **What the consent covered, keyed on what was accepted rather than on
      // how many.** Unticking the mod the dialog was opened on is coherent, and
      // a log naming only that mod would describe a folder nothing wrote.
      final accepted = choice?.accepted ?? const <String>{};
      final also = accepted.where((id) => id != mod.id).toList();
      logConfirmation('update.apply',
          accepted: choice != null,
          subject: mod.id,
          fields: {
            'from': mod.origin?.base?.version,
            'to': file.version ?? file.description,
            'file_id': file.idRow,
            'flattens_patch': flattensPatch,
            if (reinstall) 'reinstall': true,
            if (also.isNotEmpty) 'also': also,
            if (accepted.isNotEmpty && !accepted.contains(mod.id))
              'subject_skipped': true,
          });
    }
    if (choice == null) return UpdateFlowOutcome.declined;

    // Empty when the confirmation was skipped, which is the one path that has
    // no group: `installNamedBase` answered this question in its own prompt.
    final chosen = choice.accepted.isEmpty
        ? [primary]
        : [
            for (final target in [primary, ...group.targets])
              if (choice.accepted.contains(target.mod.id)) target,
          ];
    if (chosen.isEmpty) return UpdateFlowOutcome.declined;
    queue.updateStep(download.seq, UpdateStep.writing);

    // **The modal is optional and the write is not.** The user has consented,
    // so the copy happens whether or not there is still a context to draw
    // progress on — a dead context costs the progress bar and nothing else.
    final progress = _GroupProgress(chosen.length);
    if (chosen.length > 1 && context.mounted) progress.attach(context);
    // A card for one folder, raised through the captured center so it ends whether or not the context lasts.
    if (chosen.length == 1) {
      final only = chosen.single.mod;
      writing = notify.working(
        loc.t(switch (()) {
          _ when reinstall => 'mods.reinstall.writing_title',
          // The base a dropped patch named, written under it: nothing is being updated.
          _ when asCompanion && !confirm => 'mods.update_apply.writing_base_title',
          _ => 'mods.update_apply.writing_title',
        }),
        body: only.name,
        characterId: only.characterId,
      );
    }

    // The container rather than `ref`: a `WidgetRef` throws once its widget is disposed, and a throw between the copy and the record would leave a folder holding new files under a record naming the old version.
    final report = await writeUpdate(
      container,
      ready,
      targets: chosen,
      onFolder: (folder, index, _) => progress.step(folder.name, index),
      onWritesDone: progress.close,
    );
    final applied = report.applied;
    final outcome = report.outcome;
    end = outcome.changed
        ? UpdateWritten(
            switch (()) {
              _ when reinstall => JobOutcome.reinstalled,
              _ when asCompanion && !confirm => JobOutcome.baseInstalled,
              _ => JobOutcome.updated,
            },
            mods: [for (final a in applied) if (a.result.success) a.mod.id],
          )
        : UpdateFailed(loc.t('mods.update_apply.failed_title'));

    // **One folder reports its failure as a notification, several report it in
    // the dialog.** With one mod the split is not the information and the
    // dialog would only repeat what the notification says; with several, which
    // ones landed *is* the report, and three notifications would bury it.
    if (outcome.soleFailure case final only?) {
      // **The folder that was written, not the one the dialog was opened on.**
      // With the primary unticked the sole attempt is a sibling, and naming the
      // wrong mod sends the user to restore something never touched.
      final lines = updateFailureMessage(loc, only.result, only.mod);
      end = UpdateFailed(lines.title);
      final card = writing;
      writing = null;
      // The card is on screen already, so it becomes the error whether or not this context lasted.
      if (card != null) {
        card.update(
            kind: NotificationKind.error, title: lines.title, body: lines.body, characterId: only.mod.characterId);
      } else if (context.mounted) {
        notify.error(lines.title, body: lines.body, characterId: only.mod.characterId);
      }
      // A failed *copy* still moved files, and so did a write that got as far as its snapshot. Anything else left
      // the folder alone.
      final moved = context.mounted
          ? only.result.failure == UpdateApplyFailure.copy
          : only.result.snapshot != null;
      return moved ? UpdateFlowOutcome.failedAfterChange : UpdateFlowOutcome.failed;
    }

    writing?.dismiss();
    writing = null;
    // The row is Finished as the result opens, rather than when it is closed.
    queue.endUpdate(download.seq, end);
    final result = outcomeOfGroupWrite(applied);
    if (!context.mounted) return result;
    await showUpdateResultDialog(
      context,
      mod: applied.first.mod,
      file: file,
      result: applied.first.result,
      reinstall: reinstall,
      others: applied.skip(1).toList(),
    );
    return result;
  } catch (e) {
    final title = loc.t('mods.update_apply.failed_title');
    end = UpdateFailed(title);
    final body = '$e';
    final actions = [copyDetailsAction(loc, notify, title: title, body: body)];
    final card = writing;
    writing = null;
    if (card != null) {
      card.update(kind: NotificationKind.error, title: title, body: body, actions: actions);
    } else if (context.mounted) {
      fail(title, body, actions: actions);
    }
    return UpdateFlowOutcome.failed;
  } finally {
    writing?.dismiss();
    // Belt and braces: every path above releases it, and a throw between the
    // download and the question would otherwise leave the modal up for good.
    hold.dispose();
    queue.endUpdate(download.seq, end);
    // After the modal's own close, so the windows it closes are the ones left over the pages.
    if (openModPage) _openInBrowse(navigator, container, remoteModId);
    await deleteExtraction(extractRoot);
    if (archiveConsumed) await deleteConsumedArchive(download.file);
  }
}

/// Downloading a newer file of the **patch** in a mixed folder and placing it
/// over the base that is in there with it.
///
/// The other half of [applyUpdateFlow], and a separate function because the copy
/// is a different one: **layout belongs to the base, and the patch is placed.**
/// The two downloads are by different authors and nothing makes their layouts
/// agree, so replaying the folder's recorded layout for a patch archive writes
/// its files *beside* the ones they should replace — where the `.ini` still loads
/// the base's, nothing errors, and the update appears to have done nothing.
///
/// Everything else is the same and shared: the cancellable download, the
/// snapshot, and the record written against whichever identity this was.
Future<UpdateFlowOutcome> applyPatchUpdateFlow(
  BuildContext context,
  WidgetRef ref, {
  required ModInfo mod,
  required int remoteModId,
  required GbFile file,
  bool asCompanion = false,

  /// Every file the check listed beside [file], so a pick below the newest
  /// records the ones above it as passed over. Same field as [applyUpdateFlow]'s.
  List<GbFile> published = const <GbFile>[],
}) async {
  final loc = context.loc;
  final notify = context.notify;
  final container = ProviderScope.containerOf(context, listen: false);
  void fail(String title, String body, {List<NotificationAction> actions = const []}) =>
      notify.error(title, body: body, characterId: mod.characterId, actions: actions);

  final config = await ApiService.getConfig();
  final modsPath = config['mods_path'] ?? '';
  final modFolder = Directory(path.join(modsPath, mod.id));
  if (modsPath.isEmpty || !await modFolder.exists()) {
    fail(
      loc.t('mods.update_apply.mod_missing_title'),
      loc.t('mods.update_apply.mod_missing', params: {'mod': mod.name}),
    );
    return UpdateFlowOutcome.failed;
  }

  Future<PasswordAnswer?> askPassword({required bool failed}) async =>
      context.mounted ? showArchivePasswordDialog(context, modName: mod.name, failed: failed) : null;

  if (!context.mounted) return UpdateFlowOutcome.notStarted;
  final navigator = Navigator.of(context, rootNavigator: true);
  // **The whole wait, because this path asks nothing but an archive's password.** A patch placement has
  // no confirmation between the download and the write, so the modal carries
  // on through the unpacking *and* the copy, and comes down on the result.
  final hold = ProgressHold();
  DownloadStop? stopped;
  final download = await downloadFileWithProgress(
    context,
    ref,
    file,
    characterId: mod.characterId,
    subject: mod.name,
    hold: hold,
    onStopped: (reason) => stopped = reason,
  );
  if (download == null) {
    hold.dispose();
    return outcomeOfStoppedDownload(stopped);
  }

  // Ended on every path, in the `finally`, as [applyUpdateFlow]'s is.
  final queue = container.read(downloadQueueProvider.notifier);
  UpdateEnd end = const UpdateDeclined();
  var archiveConsumed = false;
  var openModPage = false;
  Directory? extractRoot;
  try {
    hold.say(loc.t('marketplace.preparing_unpacking'));
    final request = UpdateRequest(
      mod: mod,
      modsPath: modsPath,
      remoteModId: remoteModId,
      file: file,
      asCompanion: asCompanion,
      published: published,
      placeAsPatch: true,
    );
    final prepared = await _prepareAsking(
      container,
      request,
      download: download,
      modName: mod.name,
      ask: askPassword,
      openModPage: () => openModPage = true,
      queue: queue,
      onUnpacked: (unpacked) {
        archiveConsumed = true;
        extractRoot = unpacked.root;
      },
      onPreviewing: () => hold.say(loc.t('marketplace.preparing_comparing')),
    );
    if (prepared == null) {
      await deleteConsumedArchive(download.file);
      return UpdateFlowOutcome.declined;
    }
    final PreparedPatch ready;
    switch (prepared) {
      case final PreparedPatch patch:
        ready = patch;
      case UpdateUnpackFailed(:final extraction):
        final lines = extractFailureMessage(
          loc,
          archivePath: download.file.path,
          reason: extraction.failure ?? ExtractFailure.other,
          requiredBytes: extraction.requiredBytes,
          availableBytes: extraction.availableBytes,
          notify: notify,
        );
        fail(lines.title, lines.body, actions: lines.actions);
        end = UpdateFailed(lines.title);
        return UpdateFlowOutcome.failed;
      case UpdateNothingToInstall():
        fail(
          loc.t('marketplace.install_empty_title'),
          loc.t('marketplace.install_empty_body'),
        );
        end = UpdateFailed(loc.t('marketplace.install_empty_title'));
        return UpdateFlowOutcome.failed;
      // The password is answered above, and a patch is placed rather than written by layout, which is what asks the folders question.
      case UpdateAsks():
        throw StateError('a patch placement asked a question after the password was answered');
      case PreparedFolders():
        throw StateError('a patch placement was prepared as a base update');
    }

    hold.say(loc.t('marketplace.preparing_writing'));
    queue.updateStep(download.seq, UpdateStep.writing);
    final report = await writeUpdate(container, ready, targets: const [], onWritesDone: hold.release);
    final applied = report.applied.single;
    final result = applied.result;

    if (!result.success) {
      final lines = updateFailureMessage(loc, result, mod);
      end = UpdateFailed(lines.title);
      if (!context.mounted) {
        return result.snapshot != null ? UpdateFlowOutcome.failedAfterChange : UpdateFlowOutcome.failed;
      }
      fail(lines.title, lines.body);
      return result.failure == UpdateApplyFailure.copy ? UpdateFlowOutcome.failedAfterChange : UpdateFlowOutcome.failed;
    }
    end = UpdateWritten(JobOutcome.updated, mods: [mod.id]);

    queue.endUpdate(download.seq, end);
    if (!context.mounted) return UpdateFlowOutcome.written;
    await showUpdateResultDialog(
      context,
      mod: mod,
      file: file,
      result: result,
    );
    return UpdateFlowOutcome.written;
  } catch (e) {
    final title = loc.t('mods.update_apply.failed_title');
    end = UpdateFailed(title);
    if (context.mounted) {
      fail(title, '$e', actions: [copyDetailsAction(loc, notify, title: title, body: '$e')]);
    }
    return UpdateFlowOutcome.failed;
  } finally {
    hold.dispose();
    queue.endUpdate(download.seq, end);
    if (openModPage) _openInBrowse(navigator, container, remoteModId);
    await deleteExtraction(extractRoot);
    if (archiveConsumed) await deleteConsumedArchive(download.file);
  }
}

/// Writes a patch layer's update, for [applyModUpdate]. The seam is the update dialog's gateway, which a test replaces.
typedef PatchUpdateApplier =
    Future<UpdateFlowOutcome> Function(
      BuildContext context,
      WidgetRef ref, {
      required ModInfo mod,
      required int remoteModId,
      required GbFile file,
      required bool asCompanion,
      required List<GbFile> published,
    });

/// Installs [file], a newer file of the layer [subject] names, over [mod]'s folder: the one entry every surface that
/// updates a mod goes through.
///
/// **Base by layout, patch by placement**, and the folder decides which this is rather than the caller
/// (`update_write_route.dart`). A patch write clears the folder's session verdict itself, since the verdict names
/// layers; a base write clears the marks it settled inside [applyUpdateFlow]. [published] is every file the check
/// found newer, so a pick below the newest records the rest as passed over.
///
/// [UpdateFlowOutcome.notStarted] when the folder's record names nothing this file could be written against.
Future<UpdateFlowOutcome> applyModUpdate(
  BuildContext context,
  WidgetRef ref, {
  required ModInfo mod,
  required DownloadKey? subject,
  required GbFile file,
  required List<GbFile> published,
  PatchUpdateApplier patchFlow = applyPatchUpdateFlow,
}) async {
  // The identity this file belongs to, which is the folder's own only when the verdict is about it. A companion's
  // file recorded against the primary would claim this folder is that other mod.
  final modId = subject?.modId ?? mod.origin?.base?.modId;
  if (modId == null) return UpdateFlowOutcome.notStarted;
  final route = updateWriteRoute(origin: mod.origin, subject: subject);
  if (route.kind == UpdateWriteKind.none) return UpdateFlowOutcome.notStarted;

  final container = ProviderScope.containerOf(context, listen: false);
  if (route.kind != UpdateWriteKind.patch) {
    return applyUpdateFlow(
      context,
      ref,
      mod: mod,
      remoteModId: modId,
      file: file,
      patchFiles: route.patchFiles,
      patchModId: route.patchModId,
      asCompanion: route.asCompanion,
      flattensPatch: route.flattensPatch,
      published: published,
    );
  }
  final outcome = await patchFlow(
    context,
    ref,
    mod: mod,
    remoteModId: modId,
    file: file,
    asCompanion: route.asCompanion,
    published: published,
  );
  // Through the app's container: the window may have been closed while the write ran.
  if (outcome.changed) forgetUpdateCheck(container, mod.id);
  return outcome;
}

/// Open mod page in an update's password dialog, once the update has ended: every window over the pages closes, the
/// one the update was started from and the Downloads panel included, and the mod's page opens in Browse.
void _openInBrowse(NavigatorState navigator, ProviderContainer container, int modId) {
  container.read(downloadsPanelCloseRequestProvider.notifier).state++;
  if (navigator.mounted) navigator.popUntil((route) => route.isFirst);
  container.read(marketplaceOpenModProvider.notifier).state = modId;
  container.read(destinationProvider.notifier).state = AppDestination.browse;
}

/// Prepares an update, asking for the archive's password when it has one: over the flow's own window, since an update is a conversation the user is in, and again after a password that did not open it.
/// The unpack's own listing is what says it has one, before anything is written.
/// Null when the user declined, which is also what Open mod page is, told to [openModPage]: the update ends and the mod's page opens in Browse.
/// Any other question is the caller's.
Future<UpdatePrepareResult?> _prepareAsking(
  ProviderContainer container,
  UpdateRequest request, {
  required ForegroundDownload download,
  required String modName,
  required Future<PasswordAnswer?> Function({required bool failed}) ask,
  required void Function() openModPage,
  required DownloadQueue queue,
  required void Function(UpdateUnpacked unpacked) onUnpacked,
  required void Function() onPreviewing,
}) async {
  String? password;
  while (true) {
    queue.updateStep(download.seq, UpdateStep.unpacking);
    final prepared = await prepareUpdate(
      container,
      request,
      archive: download.file,
      archiveMd5: download.md5,
      password: password,
      onUnpacked: onUnpacked,
      onPreviewing: onPreviewing,
    );
    if (prepared is! UpdateAsks || prepared.question is! PasswordQuestion) return prepared;
    queue.updateStep(download.seq, UpdateStep.confirming);
    final answer = await ask(failed: (prepared.question as PasswordQuestion).failed);
    if (answer is PasswordOpenModPage) openModPage();
    if (answer is! PasswordGiven) {
      logConfirmation('update.password', accepted: false, subject: modName, dismissed: answer == null);
      return null;
    }
    password = answer.password;
  }
}

/// The progress modal for a group write, and nothing at all for a single one.
///
/// Separated from the write so the write never depends on a live context: the
/// user has already consented by the time this exists, and a context that died
/// in between must cost the progress bar rather than the copy.
class _GroupProgress {
  _GroupProgress(this.total);

  final int total;
  final ValueNotifier<GroupWriteProgress> _value =
      ValueNotifier(const GroupWriteProgress(modName: '', index: 1, total: 1));
  NavigatorState? _navigator;

  /// Puts the modal up. Called only where the context is known to be mounted,
  /// and only for more than one folder: a single write takes a second and has
  /// nothing to report, where several take that long each and a blank screen
  /// reads as the app having forgotten the request.
  void attach(BuildContext context) {
    _navigator = Navigator.of(context, rootNavigator: true);
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => UpdateProgressDialog(progress: _value),
    ));
  }

  void step(String modName, int index) {
    _value.value =
        GroupWriteProgress(modName: modName, index: index, total: total);
  }

  void close() {
    _navigator?.pop();
    _navigator = null;
    _value.dispose();
  }
}

/// What a write that did not land says, by how it failed: the snapshot, a mod gone, the copy, or a layout that could
/// not be settled.
NotificationLines updateFailureMessage(
  AppLocalizations loc,
  UpdateApplyResult result,
  ModInfo mod,
) =>
    switch (result.failure) {
      UpdateApplyFailure.snapshot => NotificationLines(
          loc.t('mods.update_apply.snapshot_failed_title'),
          loc.t('mods.update_apply.snapshot_failed', params: {'mod': mod.name}),
          kind: NotificationKind.error,
        ),
      UpdateApplyFailure.modMissing => NotificationLines(
          loc.t('mods.update_apply.mod_missing_title'),
          loc.t('mods.update_apply.mod_missing', params: {'mod': mod.name}),
          kind: NotificationKind.error,
        ),
      UpdateApplyFailure.copy => NotificationLines(
          loc.t('mods.update_apply.copy_failed_title'),
          loc.t(
            'mods.update_apply.copy_failed',
            params: {'mod': mod.name, 'message': result.error ?? ''},
          ),
          kind: NotificationKind.error,
        ),
      _ => NotificationLines(
          loc.t('mods.update_apply.layout_failed_title'),
          loc.t('mods.update_apply.layout_failed', params: {'mod': mod.name}),
          kind: NotificationKind.error,
        ),
    };
