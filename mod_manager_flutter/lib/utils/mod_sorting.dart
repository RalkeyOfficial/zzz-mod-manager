import '../models/character_info.dart';

/// Ordering the library by when each mod arrived, newest first.
///
/// Pure, and separate from the provider that calls it, because the interesting
/// part is what happens to mods that have no date — which is most of a library
/// that has never had a `source_url` pasted into it.
///
/// **Undated mods go last, in the order they came in.** Two reasons. "Recently
/// added" is a claim, and a mod we cannot date must not be presented as recent;
/// and putting them last means the existing arbitrary-but-stable scan order
/// still describes them, rather than being replaced by a different arbitrary
/// order. That is also why this partitions rather than handing `List.sort` a
/// comparator that returns 0 — **Dart's sort is not stable**, so equal elements
/// are free to be reordered on every scan, and the undated majority would
/// shuffle under the user for no reason.
///
/// A **proxy** date ([ModOrigin.installedAtIsProxy]) sorts alongside a real
/// one. It is the oldest file mtime in the mod folder and can read years early
/// for a hand-copied library, but it is the best answer available and treating
/// it as no answer would put most of a legacy library in the undated tail —
/// which is the state the backfill exists to get out of.
List<ModInfo> sortedByInstallDate(List<ModInfo> mods) {
  final dated = <ModInfo>[];
  final undated = <ModInfo>[];

  for (final mod in mods) {
    if (mod.origin?.installedAt == null) {
      undated.add(mod);
    } else {
      dated.add(mod);
    }
  }

  dated.sort((a, b) {
    final byDate =
        b.origin!.installedAt!.compareTo(a.origin!.installedAt!);
    if (byDate != 0) return byDate;
    // Ties are not hypothetical: one archive can install as several mods, and
    // the backfill's proxy gives every folder of a hand-copied set the same
    // mtime to the second. Without a tiebreak the unstable sort would reorder
    // them between scans.
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });

  return [...dated, ...undated];
}
