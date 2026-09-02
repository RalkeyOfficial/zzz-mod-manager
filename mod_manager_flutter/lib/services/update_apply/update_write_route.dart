/// **Which write installs an update into this folder.**
///
/// A mod folder is a stack of downloads, and a layer's **position** decides how
/// it is written:
///
/// ```
///   the bottom layer updated → write it by layout, then the layers above back on top
///   any layer above it      → place it over what is below, by basename
/// ```
///
/// **Layout belongs to the bottom.** It decides where files live, and everything
/// above is placed onto it. Replaying the folder's recorded layout for a *patch*
/// archive writes its files beside the ones they should replace — the `.ini` goes
/// on loading the base's, nothing errors, and the update appears to have done
/// nothing at all.
///
/// **The index is the answer**, and `indexOf` is the whole decision. A role held
/// *relative* to a companion record is the rejected alternative: the two shapes
/// a mixed folder comes in put the same download in different records depending
/// on install order, so the same folder answers differently depending on which
/// half arrived first. The stack has no such ambiguity.
///
/// Pure, so the decision can be tested without a download, a folder or a dialog.
library;

import '../../models/mod_origin.dart';

enum UpdateWriteKind {
  /// The bottom layer. Written by layout, with everything above it set aside and
  /// placed back.
  base,

  /// A layer above the bottom. Placed over what the folder already holds.
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
    this.patchModId,
    this.flattensPatch = false,
  });

  static const UpdateWriteRoute refused =
      UpdateWriteRoute(kind: UpdateWriteKind.none);

  final UpdateWriteKind kind;

  /// Whether the file belongs to a layer **above the bottom** rather than to
  /// what the folder is.
  ///
  /// Decides which layer the installed file id is recorded against; stamping a
  /// patch's file id onto the bottom claims the folder is that other mod.
  final bool asCompanion;

  /// The files to set aside and place back, for a [kind] of
  /// [UpdateWriteKind.base] — every layer above the one being written.
  final List<String> patchFiles;

  /// **Whose displaced originals to rebuild** as those files go back.
  ///
  /// A base update changes which of the mod's files the patch sits on top of, so
  /// the store keyed by this id has to be rebuilt — it held the old version's
  /// files, and taking the patch out afterwards must give back the mod that is
  /// in the folder now.
  ///
  /// The **topmost** layer's id, and null when there is none or it has no id.
  /// One store, because that is the layer whose files are on top of everything.
  final int? patchModId;

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

/// The route for a verdict about the layer naming [subjectModId], against the
/// folder described by [origin].
///
/// Refused for a mod this folder does not record: writing it would overwrite one
/// mod with another.
UpdateWriteRoute updateWriteRoute({
  required ModOrigin? origin,
  required int? subjectModId,
}) {
  if (origin == null || subjectModId == null) return UpdateWriteRoute.refused;
  final index = origin.indexOf(subjectModId);
  if (index < 0) return UpdateWriteRoute.refused;

  if (index > 0) {
    // A layer above the bottom is placed onto what is below it. Nothing is set
    // aside: the layers under it stay where they are, and any layer *above* it
    // is a shape this app does not produce — a folder holds a mod and at most
    // the patches over it, and an update to a middle layer would need the ones
    // on top lifted first. Recorded here rather than in the applier because
    // this is where the stack is in hand.
    return const UpdateWriteRoute(
      kind: UpdateWriteKind.patch,
      asCompanion: true,
    );
  }

  // The bottom layer. Everything above it comes off, the layout is replayed,
  // and they go back on — see `UpdateApplier.applyBaseThenPatch`.
  final patchFiles = origin.ingest?.patchFiles ?? const <String>[];
  final top = origin.patches.isEmpty ? null : origin.patches.last;
  return UpdateWriteRoute(
    kind: UpdateWriteKind.base,
    patchFiles: patchFiles,
    patchModId: top?.modId,
    // **A patch is recorded and its files are not.** The recorded list is what
    // the aside reads, so an empty one over a folder that holds a patch means
    // the write cannot put it back.
    flattensPatch: patchFiles.isEmpty && top != null,
  );
}
