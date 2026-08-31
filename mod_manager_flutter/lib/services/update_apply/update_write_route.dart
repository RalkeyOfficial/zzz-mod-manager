/// **Which write installs an update into this folder.**
///
/// A mod folder can hold two downloads — a base mod and a patch over it — and
/// the two are written differently. One rule decides which, and it is not "which
/// record did the finding come from":
///
/// ```
///   the BASE  updated → write it by layout, then the patch back on top
///   the PATCH updated → place it over the base, by basename
/// ```
///
/// **Layout belongs to the base.** It decides where files live, and the patch is
/// placed onto it. Replaying the folder's recorded layout for a *patch* archive
/// writes its files beside the ones they should replace — the `.ini` goes on
/// loading the base's, nothing errors, and the update appears to have done
/// nothing at all.
///
/// The role is what is read because the two shapes a mixed folder comes in put
/// the same download in different records: a patch installed as its own mod and
/// then told what it patches has the patch as its **primary** and the base as a
/// companion, while a patch installed *into* a mod is the reverse.
///
/// Pure, so the decision can be tested without a download, a folder or a dialog.
library;

import '../../models/mod_companion.dart';
import '../../models/mod_origin.dart';

enum UpdateWriteKind {
  /// The base mod. Written by layout, with the patch set aside and placed back.
  base,

  /// The patch. Placed over what the folder already holds.
  patch,

  /// Nothing here can be written: the verdict is about a mod this folder does
  /// not claim to hold, and writing it would overwrite one mod with another.
  none,
}

class UpdateWriteRoute {
  const UpdateWriteRoute({
    required this.kind,
    this.asCompanion = false,
    this.patchFiles = const <String>[],
    this.flattensPatch = false,
  });

  static const UpdateWriteRoute refused =
      UpdateWriteRoute(kind: UpdateWriteKind.none);

  final UpdateWriteKind kind;

  /// Whether the file belongs to a **companion** identity rather than the
  /// folder's own. Decides which record the installed file is written against;
  /// stamping a companion's file id onto the primary claims the folder is that
  /// other mod.
  final bool asCompanion;

  /// The recorded patch files to set aside and place back, for a [kind] of
  /// [UpdateWriteKind.base].
  final List<String> patchFiles;

  /// **The patch in this folder cannot be put back**, because nothing records
  /// which files are its — a folder merged by hand, or installed before that
  /// record existed.
  ///
  /// The write is still offered: the base update is usually what the user wants
  /// and the snapshot makes it reversible. But it must not happen without that
  /// sentence on screen, because the loss is otherwise invisible — the folder
  /// looks complete either way.
  final bool flattensPatch;
}

/// The route for a verdict about [subjectModId] — null when the verdict is about
/// the folder's own identity — against the folder described by [origin].
UpdateWriteRoute updateWriteRoute({
  required ModOrigin? origin,
  required int? subjectModId,
}) {
  final patchFiles = origin?.ingest?.patchFiles ?? const <String>[];

  if (subjectModId == null) {
    // The folder's own identity. Which half that is depends on what else is
    // recorded in there: a `base` companion means the primary is the patch.
    final isPatch = origin?.companionOfRole(CompanionRole.base) != null;
    if (isPatch) return const UpdateWriteRoute(kind: UpdateWriteKind.patch);
    return UpdateWriteRoute(
      kind: UpdateWriteKind.base,
      patchFiles: patchFiles,
      flattensPatch: patchFiles.isEmpty &&
          origin?.companionOfRole(CompanionRole.patch) != null,
    );
  }

  for (final companion in origin?.companions ?? const <ModCompanion>[]) {
    if (companion.modId != subjectModId) continue;
    return switch (companion.role) {
      CompanionRole.patch => const UpdateWriteRoute(
          kind: UpdateWriteKind.patch,
          asCompanion: true,
        ),
      CompanionRole.base => UpdateWriteRoute(
          kind: UpdateWriteKind.base,
          asCompanion: true,
          patchFiles: patchFiles,
          flattensPatch: patchFiles.isEmpty,
        ),
    };
  }

  return UpdateWriteRoute.refused;
}
