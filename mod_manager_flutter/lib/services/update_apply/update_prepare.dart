/// Everything an update can find out before it writes anything, with no window in sight.
///
/// [prepareUpdate] unpacks the downloaded archive, previews what it would do to the mod's folder, and says what only the user can answer.
/// It never asks: a question comes back as a value, the caller gets the answer however it likes, and calls again with it.
/// The modal flows (`applyUpdateFlow`, `applyPatchUpdateFlow`) are one such caller.
///
/// Nothing here writes to a mod folder: the unpack goes to a temp directory, the previews only read, and a question leaves the mod as it was.
/// `update_write.dart` is the half that writes.
///
/// A caller owns what an unpack leaves behind ([UpdateUnpacked]) and ends it with [deleteExtraction] and [deleteConsumedArchive] on every path, as the flows do in a `finally`.
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;

import '../../models/character_info.dart';
import '../../models/gamebanana/gamebanana.dart';
import '../../models/mod_ingest.dart';
import '../../utils/state_providers.dart';
import '../api_service.dart';
import '../archive_service.dart';
import '../backup/snapshot_service.dart';
import '../folder_contents.dart';
import '../log/logger.dart';
import '../mod_manager_service.dart';
import '../patch_detection.dart';
import '../patch_placement.dart';
import '../shader_fixes/shader_fixes_service.dart';
import 'mod_activation_port.dart';
import 'sibling_group.dart';
import 'update_applier.dart';
import 'update_layout.dart';
import 'update_target.dart';

final Logger _log = Logger('update');
final Logger _fileopsLog = Logger('fileops');

/// What one update is about: the mod, the file written over it, and how that write is shaped.
class UpdateRequest {
  const UpdateRequest({
    required this.mod,
    required this.modsPath,
    required this.remoteModId,
    required this.file,
    this.patchFiles = const <String>[],
    this.patchModId,
    this.asCompanion = false,
    this.flattensPatch = false,
    this.published = const <GbFile>[],
    this.reinstall = false,
    this.previewSiblings = false,
    this.placeAsPatch = false,
  });

  final ModInfo mod;

  /// The library folder the mod's own folder is in.
  final String modsPath;

  /// The mod page the file belongs to: the folder's own identity when this writes its base, a companion's otherwise.
  final int remoteModId;

  final GbFile file;

  /// The folder's recorded patch files, set aside and placed back when this replaces the base (`UpdateWriteRoute.patchFiles`).
  final List<String> patchFiles;

  /// Whose store of displaced originals to rebuild as the patch goes back (`UpdateWriteRoute.patchModId`).
  final int? patchModId;

  /// Whether [remoteModId] is a companion of the folder rather than its own identity, which decides the record the installed file is written against.
  final bool asCompanion;

  /// The folder holds a patch that cannot be put back, because nothing records which files are its.
  final bool flattensPatch;

  /// Every file the check found newer than what the mod holds, so a sibling's own recorded file can be placed against [file] and a pick below the newest records the rest as passed over.
  final List<GbFile> published;

  /// A repair: the version already installed, written again.
  final bool reinstall;

  /// Whether to look for the archive's other mods, which a repair, a companion write and a write that does not ask leave out.
  final bool previewSiblings;

  /// Whether the file is a patch layer, placed over the base by basename, rather than a base written by layout.
  final bool placeAsPatch;

  Directory get modFolder => Directory(path.join(modsPath, mod.id));
}

/// A decision the preparation cannot make.
///
/// [PasswordQuestion] and [FoldersQuestion] stop the preparation, since nothing more can be found out without the answer.
/// The other three are found together once the preview exists, and are what a confirmation states ([UpdatePrepared.questions]).
sealed class UpdateQuestion {
  const UpdateQuestion();
}

/// The archive is locked. [failed] says a password was given and did not open it.
final class PasswordQuestion extends UpdateQuestion {
  const PasswordQuestion({required this.failed});

  final bool failed;
}

/// Which of the archive's folders is this mod: nothing is recorded about how it was installed and the archive has more than one ([UpdateLayoutProblem.layoutUnknown]), or something is recorded and the archive no longer matches it ([UpdateLayoutProblem.layoutChanged]).
///
/// [unpacked] is the unpack the question was found in, which the answer ([FoldersAnswer]) hands back so the archive is not unpacked twice.
final class FoldersQuestion extends UpdateQuestion {
  const FoldersQuestion({required this.problem, required this.choices, required this.unpacked});

  final UpdateLayoutProblem problem;
  final List<UpdateFolderChoice> choices;
  final UpdateUnpacked unpacked;

  /// The answer that picks [folders], the paths of some of [choices].
  FoldersAnswer answer(List<String> folders) => FoldersAnswer(unpacked: unpacked, folders: folders);
}

/// The folders the user picked at a [FoldersQuestion], with the unpack they are in.
class FoldersAnswer {
  const FoldersAnswer({required this.unpacked, required this.folders});

  final UpdateUnpacked unpacked;
  final List<String> folders;
}

/// The download is shaped like a patch: it expects files it does not carry, so the folder it goes into holds more than one download and only part of it would be replaced.
final class PatchShapedQuestion extends UpdateQuestion {
  const PatchShapedQuestion(this.assessment);

  final PatchAssessment assessment;
}

/// Folders of the archive that the write leaves out.
final class UnusedFoldersQuestion extends UpdateQuestion {
  const UnusedFoldersQuestion(this.folders);

  final List<String> folders;
}

/// The mod's folder holds a patch and nothing records which files are its, so the write takes it with the old version.
final class UnrecordedPatchQuestion extends UpdateQuestion {
  const UnrecordedPatchQuestion();
}

/// One folder of the archive, offered to a [FoldersQuestion]'s answer.
class UpdateFolderChoice {
  const UpdateFolderChoice({required this.path, required this.name, required this.looksLikeMod});

  /// Absolute path of the unpacked folder.
  final String path;

  final String name;

  /// Whether the folder holds a `.ini`, or shader files an import would turn into a mod: the hint that it is not just previews.
  final bool looksLikeMod;
}

/// What an unpack left behind, which the caller owns until it deletes it.
class UpdateUnpacked {
  const UpdateUnpacked({required this.root, required this.folders, required this.archiveMd5});

  /// The directory the unpack made, the whole of which is deleted when done with: a `Mods/<mod>` layout is a level deeper than any of [folders].
  final Directory? root;

  /// The archive's top-level folders.
  final List<String> folders;

  /// Of the archive, when it could be computed: a matching key and never an integrity claim.
  final String? archiveMd5;
}

/// How a preparation ended.
sealed class UpdatePrepareResult {
  const UpdatePrepareResult();
}

/// Something has to be answered before the preparation can go on.
final class UpdateAsks extends UpdatePrepareResult {
  const UpdateAsks(this.question);

  final UpdateQuestion question;
}

/// The archive could not be unpacked. It is left where it is, so the user can still unpack it by hand.
final class UpdateUnpackFailed extends UpdatePrepareResult {
  const UpdateUnpackFailed(this.extraction);

  final ArchiveExtractionResult extraction;
}

/// The archive expanded to no folders, so there is nothing to write. The unpack is the caller's to delete.
final class UpdateNothingToInstall extends UpdatePrepareResult {
  const UpdateNothingToInstall(this.unpacked);

  final UpdateUnpacked unpacked;
}

/// The preview is done and nothing is left to ask.
/// A write of it can still fail, as it can for any update.
sealed class UpdatePrepared extends UpdatePrepareResult {
  const UpdatePrepared({
    required this.request,
    required this.unpacked,
    this.questions = const <UpdateQuestion>[],
  });

  final UpdateRequest request;
  final UpdateUnpacked unpacked;

  /// What a confirmation has to state about the mod the update is for, in the order it states it: empty for a plain update.
  /// The siblings' own findings are on their targets ([UpdateSiblings.targets]), since which of them are written is the caller's choice.
  final List<UpdateQuestion> questions;
}

/// A base written by layout, into the mod's folder and any of the archive's other mods.
final class PreparedFolders extends UpdatePrepared {
  const PreparedFolders({
    required super.request,
    required super.unpacked,
    required super.questions,
    required this.services,
    required this.primary,
    required this.group,
    required this.picked,
  });

  /// What the write goes through, taken once when the update was prepared.
  final UpdateServices services;

  /// The mod the update is for, previewed.
  /// It carries the group's refusal when the group contested its folder, so a refused primary does not read as writable.
  final UpdateTarget primary;

  /// The archive's other mods, previewed against the same unpack.
  final UpdateSiblings group;

  /// The layout the user picked at a [FoldersQuestion], which [primary]'s preview was made with.
  /// The write records the preview's layout, so the next update replays it.
  final ModIngest? picked;
}

/// A patch layer, placed over the base that is in the folder with it.
/// A placement that still needs a choice (`placement.needsChoice`) always fails at the write with a layout failure.
final class PreparedPatch extends UpdatePrepared {
  const PreparedPatch({
    required super.request,
    required super.unpacked,
    required this.source,
    required this.incoming,
    required this.existing,
    required this.placement,
  }) : super(questions: const <UpdateQuestion>[]);

  /// One folder's contents, never the folder itself: an extraction wrapper invented for a rootless archive must not end up nested inside the target.
  final Directory source;

  final FolderContents incoming;
  final FolderContents existing;
  final PatchPlacement placement;
}

/// The archive's other mods, previewed and split into offered and refused.
class UpdateSiblings {
  const UpdateSiblings({
    this.targets = const <UpdateTarget>[],
    this.refused = const <SiblingRefused>[],
    this.otherFolders = const <String>[],
  });

  final List<UpdateTarget> targets;

  /// Includes the primary when the group contested its folder, which is the only channel a confirmation has for it: a second field for the same fact is one a caller can forget, and forgetting it writes a folder the group refused.
  final List<SiblingRefused> refused;

  final List<String> otherFolders;
}

/// What the preview found that a confirmation has to say, in the order it says it: a patch-shaped download, folders the write leaves out, and a patch that cannot be put back.
List<UpdateQuestion> confirmationQuestions(UpdatePreview preview, {required bool flattensPatch}) => [
      if (preview.incomingIsPatch) PatchShapedQuestion(preview.patch),
      if (preview.layout.unused.isNotEmpty) UnusedFoldersQuestion(preview.layout.unused),
      if (flattensPatch) const UnrecordedPatchQuestion(),
    ];

/// What an update reads and writes through, taken from the app's own container so a write that outlives its window still knows a mod was turned off meanwhile.
typedef UpdateServices = ({ModManagerService mods, SnapshotService snapshots, UpdateApplier applier});

Future<UpdateServices> updateServicesFor(ProviderContainer container) async {
  final mods = await container.read(modManagerServiceProvider.future);
  // Read before anything is written: retention is a disk operation and has to run even if the widget that started the update has gone by then.
  final snapshots = container.read(snapshotServiceProvider);
  bool leftOff(String modName) => leftOffAfterWrite(container, modName);
  final applier = UpdateApplier(
    snapshots: snapshots,
    activation: ModManagerActivationPort(mods, leaveOff: leftOff),
    staysOff: leftOff,
  );
  return (mods: mods, snapshots: snapshots, applier: applier);
}

/// Unpacks [archive], previews it against the mod's folder and finds what has to be answered.
///
/// A question comes back and the call is made again with the answer.
/// A [PasswordQuestion] is answered by calling again with [password], which unpacks again.
/// A [FoldersQuestion] is answered with [foldersAnswer], which carries the unpack it was found in, so nothing is unpacked twice.
///
/// [onUnpacked] is called once the archive is unpacked and before anything is read from it, so a caller that owns the cleanup holds the unpack even if a later step throws.
/// [onPreviewing] is called when the unpack has been checked and the folders are about to be read, which a call that answers a [FoldersQuestion] does not repeat.
///
/// Nothing is written to a mod folder, and a question leaves the mod untouched.
Future<UpdatePrepareResult> prepareUpdate(
  ProviderContainer container,
  UpdateRequest request, {
  required File archive,
  String? archiveMd5,
  String? password,
  FoldersAnswer? foldersAnswer,
  void Function(UpdateUnpacked unpacked)? onUnpacked,
  void Function()? onPreviewing,
}) async {
  var unpack = foldersAnswer?.unpacked;
  if (unpack == null) {
    final extraction = await ArchiveService.extractArchive(
      archiveFile: archive,
      knownMd5: archiveMd5,
      password: password,
    );
    switch (extraction.failure) {
      case ExtractFailure.wrongPassword:
        return const UpdateAsks(PasswordQuestion(failed: true));
      case ExtractFailure.passwordRequired when password == null:
        return const UpdateAsks(PasswordQuestion(failed: false));
      default:
    }
    if (!extraction.success) return UpdateUnpackFailed(extraction);

    unpack = UpdateUnpacked(
      // The directory the unpack made, never one guessed from a folder: a `Mods/<mod>` layout is a level deeper.
      root: switch (extraction.extractionRoot) { final root? => Directory(root), null => null },
      folders: extraction.extractedFolders ?? const <String>[],
      archiveMd5: extraction.archiveMd5 ?? archiveMd5,
    );
    onUnpacked?.call(unpack);
  }

  final folders = unpack.folders;
  if (folders.isEmpty) return UpdateNothingToInstall(unpack);

  if (request.placeAsPatch) {
    if (foldersAnswer == null) onPreviewing?.call();
    return _preparePatch(request, unpack);
  }

  final services = await updateServicesFor(container);
  if (foldersAnswer == null) onPreviewing?.call();
  final applier = services.applier;
  Future<UpdatePreview> previewWith(ModIngest? ingest) => applier.preview(
        modFolder: request.modFolder,
        incomingFolders: folders,
        ingest: ingest,
      );

  // Asked once, whatever else the caller skips: which folder is the mod is a question nobody has asked, and the answer is recorded after the write so the next update replays it.
  ModIngest? picked;
  UpdatePreview preview;
  if (foldersAnswer != null) {
    picked = ingestFromPick([for (final folder in foldersAnswer.folders) path.basename(folder)]);
    preview = await previewWith(picked);
  } else {
    preview = await previewWith(request.mod.origin?.ingest);
    final problem = preview.layout.problem;
    if (problem == UpdateLayoutProblem.layoutUnknown || problem == UpdateLayoutProblem.layoutChanged) {
      final choices = [
        for (final folder in folders)
          UpdateFolderChoice(
            path: folder,
            name: path.basename(folder),
            looksLikeMod: await ArchiveService.containsIniFile(folder) ||
                await ShaderFixesService.shaderPartOf(folder) != null,
          ),
      ];
      return UpdateAsks(FoldersQuestion(problem: problem!, choices: choices, unpacked: unpack));
    }
  }

  final group = request.previewSiblings
      ? await _previewSiblings(applier: applier, request: request, primaryIngest: picked, folders: folders)
      : const UpdateSiblings();

  final primary = UpdateTarget(
    mod: request.mod,
    preview: preview,
    patchFiles: request.patchFiles,
    patchModId: request.patchModId,
    flattensPatch: request.flattensPatch,
    refusal: [for (final refused in group.refused) if (refused.mod.id == request.mod.id) refused.reason].firstOrNull,
  );

  return PreparedFolders(
    request: request,
    unpacked: unpack,
    services: services,
    questions: confirmationQuestions(preview, flattensPatch: request.flattensPatch),
    primary: primary,
    group: group,
    picked: picked,
  );
}

Future<PreparedPatch> _preparePatch(UpdateRequest request, UpdateUnpacked unpacked) async {
  final source = Directory(unpacked.folders.first);
  final incoming = await readFolderContents(source);
  final existing = await readFolderContents(request.modFolder);
  final placement = resolvePatchPlacement(
    incoming: incoming.files,
    target: existing.files,
  );
  return PreparedPatch(
    request: request,
    unpacked: unpacked,
    source: source,
    incoming: incoming,
    existing: existing,
    placement: placement,
  );
}

/// Finds the mods this archive also installed, and previews the write into each.
///
/// The library is read here, when the question is asked, rather than off `libraryProvider`: a group member that landed since the last scan would otherwise be skipped silently (`test/modal_freshness_test.dart`).
/// A mod with no group reads nothing, which is every mod in a backfilled library.
Future<UpdateSiblings> _previewSiblings({
  required UpdateApplier applier,
  required UpdateRequest request,

  /// The layout the user picked at a stop, so the group sees what the primary is really written with.
  required ModIngest? primaryIngest,
  required List<String> folders,
}) async {
  final mod = request.mod;
  if (mod.origin?.ingest?.siblingGroup == null) return const UpdateSiblings();

  final List<ModInfo> library;
  try {
    library = await ApiService.getMods();
  } catch (e) {
    // The group is an addition to a write that works without it, so a failed scan costs the user the offer and nothing else.
    _log.warning('could not read the library for a sibling group', error: e, fields: {'mod': mod.id});
    return const UpdateSiblings();
  }

  final plan = planSiblingUpdates(
    primary: mod,
    primaryIngest: primaryIngest,
    library: library,
    subjectModId: request.remoteModId,
    target: request.file,
    published: request.published,
    incomingFolders: [for (final folder in folders) path.basename(folder)],
  );

  final targets = <UpdateTarget>[];
  for (final sibling in plan.targets) {
    final folder = Directory(path.join(request.modsPath, sibling.mod.id));
    // Gone between the scan and here, or renamed mid-flow: dropped rather than refused, since there is no folder left to name a reason about.
    if (!await folder.exists()) continue;
    targets.add(UpdateTarget(
      mod: sibling.mod,
      preview: await applier.preview(
        modFolder: folder,
        incomingFolders: folders,
        ingest: sibling.mod.origin?.ingest,
      ),
      patchFiles: sibling.route.patchFiles,
      patchModId: sibling.route.patchModId,
      flattensPatch: sibling.route.flattensPatch,
      caution: sibling.caution,
    ));
  }

  return UpdateSiblings(
    targets: targets,
    refused: [
      // The primary first when it is the refused one, since it is the mod the user was asking about.
      if (plan.primaryRefused case final reason?) SiblingRefused(mod: mod, reason: reason),
      ...plan.refused,
    ],
    otherFolders: plan.otherFolders,
  );
}

/// Deletes the directory an unpack made, and only one an unpack made.
Future<void> deleteExtraction(Directory? root) async {
  if (root == null) return;
  try {
    if (!root.path.contains('zzz_archive_extract_')) return;
    if (await root.exists()) await root.delete(recursive: true);
  } catch (e) {
    _fileopsLog.debug('temp cleanup failed', fields: {'path': root.path, 'reason': '$e'});
  }
}

/// Deletes the file just consumed and nothing else, never its directory: archives share `<appData>/downloads`, so a parent delete would take every other archive and in-flight partial with it.
/// A declined update deletes it too, so backing out costs a full re-download; the alternative is keeping every declined archive, which reach 1.24 GB, in a folder the user does not manage.
Future<void> deleteConsumedArchive(File archive) async {
  try {
    if (await archive.exists()) await archive.delete();
  } catch (e) {
    _fileopsLog.warning('could not delete a consumed archive', error: e, fields: {'archive': archive.path});
  }
}
