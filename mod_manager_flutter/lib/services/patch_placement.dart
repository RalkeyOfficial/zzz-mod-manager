/// Where each file of a patch lands inside the mod it is being installed into.
///
/// The rule is one sentence — **a file goes where the target already keeps that
/// name** — and it needs its own unit because getting it wrong is *silent*.
/// Written at the root when the base mod keeps its textures in a subfolder, the
/// file lands beside the mod rather than over it: every reference in the `.ini`
/// still resolves to the original, the folder gains a file nothing reads, and
/// nothing changes in the game with no error anywhere.
///
/// **Matched on the file name, never the path.** The patch author has no idea
/// what layout the folder ended up with — they ship the file bare and expect it
/// dropped in. This is the same reasoning that was once applied to patch
/// *detection*, where it was wrong: there it made the verdict depend on install
/// order and on filename luck. Here the target is already chosen by the user, so
/// a name collision is the **answer** rather than a guess.
///
/// Pure, and defined over `FolderContents` spelling — relative to the mod folder
/// root, `/`-separated, lower-cased. That spelling is also why matching is
/// case-insensitive without this file doing anything about it; the caller maps
/// back to real on-disk names through `FolderContents.actualPaths`.
///
/// It needs **no recorded `ingest`**, which is what lets it work on the existing
/// library — most of which predates any of this and has none.
library;

/// One incoming file whose destination the folder cannot settle on its own.
class PatchPlacementChoice {
  const PatchPlacementChoice({
    required this.incoming,
    required this.candidates,
  });

  final String incoming;

  /// Every target path holding this file's name, sorted so what the user reads
  /// does not depend on the order the filesystem enumerated the folder in.
  final List<String> candidates;
}

/// Where a patch's files land, and what could not be decided without asking.
class PatchPlacement {
  const PatchPlacement({
    this.mapping = const <String, String>{},
    this.choices = const <PatchPlacementChoice>[],
    this.unmatched = const <String>[],
  });

  /// No patch to place — for a folder that is one download after all.
  static const PatchPlacement nothing = PatchPlacement();

  /// Incoming path -> where it lands in the target.
  ///
  /// Covers every incoming file **except** those still in [choices], and is
  /// injective: two incoming files never land on one path, or one would
  /// silently overwrite the other.
  final Map<String, String> mapping;

  /// Files the target holds under more than one path.
  ///
  /// **Nothing is written while any of these stand**, and the caller refuses
  /// rather than asking. A mod folder holding two copies of its own files —
  /// `sfw/body.dds` beside `nsfw/body.dds` — is not a shape any install
  /// produces: the import picker makes that choice separate-or-combined before
  /// anything is copied. Reaching it means the folder was assembled by hand
  /// outside that flow, and writing a patch blind into a folder that is already
  /// wrong makes it worse rather than better.
  final List<PatchPlacementChoice> choices;

  /// Settled files the target had no counterpart for, sorted.
  ///
  /// They keep their own relative path — nothing in the target says otherwise,
  /// so the author's own structure is the only information there is. Reported
  /// because a patch adding a file is legitimate but is the one thing the user
  /// cannot verify by looking.
  final List<String> unmatched;

  bool get needsChoice => choices.isNotEmpty;

  /// Every incoming file is new to the target — **the wrong-destination
  /// signal.**
  ///
  /// Said before the write rather than discovered after it. A snapshot makes a
  /// wrong answer survivable; it is not a reason to find out the expensive way.
  bool get matchedNothing =>
      choices.isEmpty && unmatched.isNotEmpty && unmatched.length == mapping.length;
}

/// Resolves [incoming] against [target].
///
/// One shot, and there is deliberately no way to answer a
/// [PatchPlacement.choices] and try again: the only thing that produces one is a
/// mod folder holding two copies of its own files, which no install path can
/// create. That is refused, not negotiated.
PatchPlacement resolvePatchPlacement({
  required Set<String> incoming,
  required Set<String> target,
}) {
  final byName = <String, List<String>>{};
  for (final path in target) {
    byName.putIfAbsent(_basename(path), () => <String>[]).add(path);
  }

  final mapping = <String, String>{};
  final pending = <PatchPlacementChoice>[];
  final unmatched = <String>[];

  for (final path in incoming) {
    final candidates = byName[_basename(path)] ?? const <String>[];

    if (candidates.isEmpty) {
      // Nothing to replace: it keeps its own place, and is named.
      mapping[path] = path;
      unmatched.add(path);
      continue;
    }
    if (candidates.length == 1) {
      mapping[path] = candidates.single;
      continue;
    }

    pending.add(PatchPlacementChoice(
      incoming: path,
      candidates: [...candidates]..sort(),
    ));
  }

  unmatched.sort();
  pending.sort((a, b) => a.incoming.compareTo(b.incoming));
  return PatchPlacement(
    mapping: mapping,
    choices: pending,
    unmatched: unmatched,
  );
}

String _basename(String path) {
  final cut = path.lastIndexOf('/');
  return cut < 0 ? path : path.substring(cut + 1);
}
