/// Which library folder a patch most likely goes into — as an **order**, never
/// as an answer.
///
/// The destination picker offers the whole library. A patch names the files it
/// replaces, so a folder holding those names is a candidate, and putting those
/// folders first is the difference between recognising a mod and reading 71
/// folder names. What this must never become is a decision: see
/// [rankDestinations].
///
/// ## Two signals, and one that turned out to be redundant
///
/// - **The filename fingerprint** — what [destinationFingerprint] extracts.
///   Measured over a real 71-folder library
///   (`test/patch_destination_corpus_test.dart`): the right folder is alone at
///   the top for 91% of `.ini` patches and 82% of asset patches, and within the
///   first three for every `.ini` patch measured.
/// - **The author's own requirement** — a mod page may declare what it needs,
///   and for a patch that is often the mod being patched. Precision is high and
///   coverage is not: 9% of patch-sized ZZZ mods link a mod page at all, and two
///   of six such links named a shared prerequisite rather than a base mod. So it
///   leads the order and says whose claim it is; it decides nothing.
/// - **The character is deliberately absent.** It reads like an independent
///   signal and is not: in every measured case the folders tied at the top
///   already shared the subject's character, so filtering on it removes nothing
///   the fingerprint kept. It has value only where the fingerprint is empty,
///   which is [DestinationRank.hasSignal] being false everywhere — and there the
///   list is already in its plain order.
///
/// The full measurement lives in `docs/patch-destinations.md`.
///
/// Pure: sets of names in, an order out. The walk that produces the library's
/// names is the caller's.
library;

import 'folder_contents.dart';
import 'ini_resources.dart';
import 'patch_detection.dart';

/// One library folder's standing as a destination for one patch.
class DestinationRank {
  const DestinationRank({
    required this.modId,
    required this.matched,
    required this.fingerprint,
    this.requiredByAuthor = false,
  });

  final String modId;

  /// How many of the patch's names this folder holds.
  final int matched;

  /// How many names the patch had to offer, so [matched] can be read as a
  /// proportion by a caller that wants to phrase one.
  final int fingerprint;

  /// The patch's own mod page lists this folder's mod as required.
  final bool requiredByAuthor;

  double get share => fingerprint == 0 ? 0 : matched / fingerprint;

  /// Anything at all points at this folder.
  ///
  /// What a caller shows a reason for. False for every folder when the patch
  /// gave nothing to go on, which is a real and ordinary state — a patch of one
  /// oddly-named file — and the reason nothing here is phrased as a conclusion.
  bool get hasSignal => requiredByAuthor || matched > 0;
}

/// The names a patch replaces, lower-cased and without their paths.
///
/// **Basenames, because the patch author does not know the layout.** They ship
/// the file bare and expect it dropped in; the folder it lands in may keep that
/// name three directories down. Same rule, and the same reason, as
/// `patch_placement.dart`.
///
/// The two patch kinds answer differently, matching the two rules in
/// `patch_detection.dart`:
///
/// - an **`.ini` patch** ships no content, so what it names is what its `.ini`
///   files *reference*. Includes are dropped: one `.ini` including another is
///   the patch's own structure, not a file it expects to find in the folder.
/// - an **asset patch** ships no `.ini`, so what it names is the assets it
///   carries — game assets only, by [isGameAsset], or a screenshot beside them
///   would be matched against every folder holding a `preview.png`.
Set<String> destinationFingerprint(FolderContents patch) {
  if (patch.hasIni) {
    return {
      for (final reference in patch.references.references)
        if (reference.kind == IniReferenceKind.resource)
          _basename(reference.path),
    };
  }
  return {
    for (final file in patch.files)
      if (isGameAsset(file)) _basename(file),
  };
}

/// Orders [libraryFiles] by how well each folder answers for [fingerprint].
///
/// [libraryFiles] maps a mod id to that folder's file paths, in the order the
/// caller means to display them. [requiredMods] are the ids the patch's own mod
/// page declared as required.
///
/// **Every folder comes back.** Ranking is the whole of what this does — no
/// threshold, no filter, no cut-off — for a reason the same measurement
/// produced: with the patch's real target *not* installed, a wrong folder still
/// scores a perfect 100% in 3 of 67 `.ini` cases and 12 of 68 asset cases.
/// Finding a patch before the mod it patches is an ordinary way round, so a top
/// score is not evidence the right answer is in the list at all. A signal that
/// cannot tell "this is it" from "this is the closest thing you happen to own"
/// may order the list and must not shorten it, preselect in it, or claim
/// anything.
///
/// Equal standing keeps the caller's order, so a library with nothing to rank on
/// is returned exactly as it came in rather than shuffled.
List<DestinationRank> rankDestinations({
  required Set<String> fingerprint,
  required Map<String, Set<String>> libraryFiles,
  Set<String> requiredMods = const <String>{},
}) {
  final ranks = <DestinationRank>[];
  for (final entry in libraryFiles.entries) {
    final names = {for (final path in entry.value) _basename(path)};
    var matched = 0;
    for (final name in fingerprint) {
      if (names.contains(name)) matched++;
    }
    ranks.add(DestinationRank(
      modId: entry.key,
      matched: matched,
      fingerprint: fingerprint.length,
      requiredByAuthor: requiredMods.contains(entry.key),
    ));
  }

  // Indexed rather than sorted in place: `List.sort` is not stable, and equal
  // standing keeping the caller's order is a promise this makes.
  final indexed = [
    for (var i = 0; i < ranks.length; i++) (index: i, rank: ranks[i]),
  ]..sort((a, b) {
      if (a.rank.requiredByAuthor != b.rank.requiredByAuthor) {
        return a.rank.requiredByAuthor ? -1 : 1;
      }
      // The fingerprint is one set for the whole call, so comparing counts is
      // comparing shares — without going near floating point.
      if (a.rank.matched != b.rank.matched) {
        return b.rank.matched.compareTo(a.rank.matched);
      }
      return a.index.compareTo(b.index);
    });

  return [for (final entry in indexed) entry.rank];
}

String _basename(String path) {
  final cut = path.lastIndexOf('/');
  final name = cut < 0 ? path : path.substring(cut + 1);
  return name.toLowerCase();
}
