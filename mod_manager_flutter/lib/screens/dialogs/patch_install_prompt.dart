import 'package:flutter/material.dart';

import '../../models/character_info.dart';
import '../../models/gamebanana/gamebanana.dart';
import '../../models/mod_download.dart';
import '../../services/patch_destination_ranking.dart';
import 'patch_modal.dart';

/// Which rule found a patch, and so what the prompt may say about it.
///
/// The two are different evidence and the wording has to be: one download asks
/// for content it did not bring, the other brought content nothing can load.
enum PatchKind { references, assets }

/// One mod an install is about to create that looks like a patch, or the download of an update that does.
class PatchInstallSubject {
  const PatchInstallSubject({
    required this.modName,
    required this.patchModId,
    this.patchFileId,
    required this.kind,
    this.destinations = const <DestinationRank>[],
    this.missingFiles = const <String>[],
  });

  /// The name the mod will have, which is what the prompt calls it.
  final String modName;

  /// The patch's **own** remote identity. **Null for a folder dragged off a
  /// disk**, which has no mod page at all.
  ///
  /// Not refused as an answer: a patch whose file comes from its base's own
  /// page names that page as its base like any other. Only its file is
  /// ([patchFileId]).
  final int? patchModId;

  /// The patch's own file, which is the one answer refused: as the base it
  /// names, the file picker greys it with "Already in this folder" under it,
  /// and a library mod whose base is this exact file cannot be picked.
  final int? patchFileId;

  final PatchKind kind;

  /// Every library folder, ordered by how well it answers for this patch.
  ///
  /// Empty when there was nothing to rank on, or when a combined install means
  /// no library destination is offered at all. Ordering is the whole of what it
  /// does: nothing is filtered out of it and nothing in it is selected — see
  /// `patch_destination_ranking.dart` for the measurement that settles that.
  final List<DestinationRank> destinations;

  /// For a patch by its `.ini`, the files that `.ini` asks for and the download does not carry;
  /// for a patch of game files alone, those files. Lower-cased basenames, sorted; empty when not read.
  final List<String> missingFiles;
}

/// Where one patch's files go.
///
/// A sealed pair rather than a nullable folder id, because the two are different
/// operations rather than one with an option: [InstallAsNewMod] copies into a
/// folder that does not exist yet, while [InstallIntoMod] writes over a live one
/// and must take a snapshot first.
sealed class PatchDestination {
  const PatchDestination();
}

/// A folder of its own, the one destination that cannot destroy anything.
///
/// [base] is what the user said it patches, when they said. It is recorded as a
/// layer **underneath** the patch on the new folder: a statement about what that
/// folder is *going* to hold, since the patch alone does nothing until the mod
/// it patches is in there with it.
class InstallAsNewMod extends PatchDestination {
  const InstallAsNewMod({this.base, this.baseName, this.baseFile});

  final ModDownload? base;

  /// The base mod page's own name, for the row to say.
  final String? baseName;

  /// The file of the base mod the install should **fetch and write into this
  /// folder first**, when the user picked one.
  ///
  /// Null means they could not say which file, so there is nothing to fetch:
  /// the answer is recorded and the folder stays as it is.
  final GbFile? baseFile;
}

/// Into a library mod's folder, which ends up holding both downloads.
///
/// That folder keeps its own identity: its `origin` is still the base mod,
/// because that is still what it mostly is.
/// The patch is recorded on it as a layer on top at `exact`, the one path to `exact` for a layer nobody identified by hand, since we downloaded those bytes ourselves.
class InstallIntoMod extends PatchDestination {
  const InstallIntoMod({required this.modId, required this.modName, this.characterId});

  /// The library folder id, which is what the write path acts on.
  final String modId;

  final String modName;

  /// The mod's character, whose portrait leads what the install says about it.
  final String? characterId;
}

/// Asks where a patch goes and what it patches, **at the moment the install finds one**, in the patch window's install context.
///
/// Returns a destination per mod name, **null when the user declined the install or closed the window**.
Future<Map<String, PatchDestination>?> showPatchInstallPrompt(
  BuildContext context, {
  required List<PatchInstallSubject> subjects,
  required List<ModInfo> library,
  bool combined = false,
}) async =>
    (await askPatchInstall(context, subjects: subjects, library: library, combined: combined))?.destinations;

/// What the patch prompt was answered with: the destinations, or Don't install.
class PatchPromptAnswer {
  const PatchPromptAnswer(this.destinations);

  const PatchPromptAnswer.declined() : destinations = null;

  /// Per planned mod name; null for Don't install.
  final Map<String, PatchDestination>? destinations;

  bool get declined => destinations == null;
}

/// The patch prompt, telling Don't install apart from a window closed without an answer (null), which leaves a waiting download waiting.
///
/// **Nothing here is answered for the user.** The destinations are ordered by what the patch's own files and its author's requirement point at,
/// and that is where it stops: nothing is preselected, nothing is hidden, and the confirm button stays disabled until a folder is actually chosen (`docs/patch-destinations.md`).
/// [source], [characterId] and [patchAuthor] are what the window's header and hints say about the download.
Future<PatchPromptAnswer?> askPatchInstall(
  BuildContext context, {
  required List<PatchInstallSubject> subjects,
  required List<ModInfo> library,
  bool combined = false,
  PatchSource? source,
  String? characterId,
  String? patchAuthor,
}) =>
    showInstallPatchModal(
      context,
      PatchInstallContext(
        subjects: subjects,
        library: library,
        combined: combined,
        source: source,
        characterId: characterId,
        patchAuthor: patchAuthor,
      ),
    );
