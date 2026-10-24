/// What Settings' Storage section reports, and the arithmetic behind it.
///
/// Pure — no `dart:io`, no widgets.
/// The section's every derived number is a function in here, so the parts that decide what the user reads are tested without a filesystem.
library;

/// The six things the app stores, which are also the meter's segments.
///
/// **They are disjoint, and that is load-bearing.**
/// [mods] is the library *minus* the sidecars and [sidecars] is the sidecars, because they live inside the same folders: counting the library whole and the sidecars again makes the segments sum past the total, and a chart whose parts exceed its whole is not reporting, it is lying.
enum StorageCategoryId { mods, savedVersions, downloads, sidecars, logs, leftovers }

/// Whether a category's number is a fact.
///
/// The reason this exists rather than a nullable int: **zero and "could not
/// look" must never render alike.** `0 B` next to Mods reads as "you have no
/// mods", which is a different and much more alarming statement than "no
/// folder is set".
enum StorageRead {
  /// Measured, whole.
  ok,

  /// Measured, but something was skipped. The byte count is a floor.
  partial,

  /// Configured, exists, and could not be read at all.
  unreadable,

  /// Configured, and not there.
  absent,

  /// No path configured. Only reachable for the library.
  notConfigured,
}

/// What one item of a category is.
enum StorageItemKind {
  modFolder,
  snapshotGroup,
  snapshot,
  archive,
  partialDownload,
  file,
  directory,

  /// A link. Holds no bytes of its own, and is shown saying so rather than as
  /// `0 B`, which would read as an empty mod.
  linked,
}

/// One item of a category: a mod folder, a group of saved versions, a file.
class StorageItem {
  const StorageItem({
    required this.id,
    required this.label,
    required this.path,
    required this.bytes,
    required this.kind,
    this.fileCount = 0,
    this.modified,
  });

  final String id;
  final String label;
  final String path;
  final int bytes;
  final StorageItemKind kind;
  final int fileCount;
  final DateTime? modified;
}

/// One category, and everything it holds.
class StorageCategory {
  const StorageCategory({
    required this.id,
    required this.read,
    required this.bytes,
    this.fileCount = 0,
    this.unreadableCount = 0,
    this.items = const <StorageItem>[],
    this.rootPath,
  });

  /// Nothing configured — the library, before a folder is chosen.
  const StorageCategory.notConfigured(this.id)
      : read = StorageRead.notConfigured,
        bytes = 0,
        fileCount = 0,
        unreadableCount = 0,
        items = const <StorageItem>[],
        rootPath = null;

  /// Configured and not there.
  const StorageCategory.absent(this.id, this.rootPath)
      : read = StorageRead.absent,
        bytes = 0,
        fileCount = 0,
        unreadableCount = 0,
        items = const <StorageItem>[];

  final StorageCategoryId id;
  final StorageRead read;

  /// Apparent bytes — the sum of file lengths. With [read] `partial` this is a
  /// floor, and the UI says "at least".
  final int bytes;

  final int fileCount;
  final int unreadableCount;

  /// Every item, largest first.
  final List<StorageItem> items;

  final String? rootPath;

  /// Whether this category contributes a segment.
  /// A category nobody has configured is not a zero-sized segment, it is absent from the meter.
  bool get hasMeasurement =>
      read == StorageRead.ok || read == StorageRead.partial;

  /// Whether the number shown should be read as "at least".
  bool get isFloor => read == StorageRead.partial;
}

/// Free space on one volume.
///
/// A list rather than a number because the library commonly lives on a different disk than app data, so there is no single answer — and Dart cannot portably compare two paths' devices, so the section labels the lines by what they hold rather than pretending to identify the volume.
class VolumeFreeSpace {
  const VolumeFreeSpace({
    required this.label,
    required this.probedPath,
    required this.freeBytes,
  });

  /// `app_data`, `mods_library` or `temp` — a key the UI localizes.
  final String label;

  final String probedPath;

  /// Null when the probe could not answer: a disconnected mapped drive, a
  /// `df` that said nothing usable. Rendered as "unknown", never as zero.
  final int? freeBytes;
}

/// The whole section's arithmetic over however many categories have landed.
class StorageTotals {
  const StorageTotals({
    required this.bytes,
    required this.measured,
    required this.expected,
    required this.anyFloor,
  });

  /// Sums only what has arrived, so a section mid-scan shows a growing real number rather than nothing.
  factory StorageTotals.from(Iterable<StorageCategory?> categories) {
    var bytes = 0;
    var measured = 0;
    var expected = 0;
    var anyFloor = false;
    for (final category in categories) {
      expected++;
      if (category == null) continue;
      measured++;
      if (!category.hasMeasurement) continue;
      bytes += category.bytes;
      anyFloor = anyFloor || category.isFloor;
    }
    return StorageTotals(
      bytes: bytes,
      measured: measured,
      expected: expected,
      anyFloor: anyFloor,
    );
  }

  final int bytes;

  /// How many categories have answered, for a "still measuring" hint.
  final int measured;
  final int expected;

  /// True when any contributing category was only partly readable, which makes
  /// the total a floor too.
  final bool anyFloor;

  bool get isComplete => measured == expected;
}

/// Each category's share of [total], as a fraction.
///
/// Zero when there is nothing to divide — an empty meter is drawn empty rather than by dividing by zero.
double shareOf(int bytes, int total) {
  if (total <= 0 || bytes <= 0) return 0;
  return bytes / total;
}

/// A share as a whole percentage, or `<1%` for a share that is not nothing but rounds to it.
///
/// A category of a few megabytes beside gigabytes would otherwise read `0%`, which says it is empty.
String percentLabel(int bytes, int total) {
  final share = shareOf(bytes, total);
  if (share <= 0) return '0%';
  final percent = (share * 100).round();
  return percent < 1 ? '<1%' : '$percent%';
}

/// The widths of the meter's segments across [available] pixels, one per entry of [byteValues], with [gap] between them.
///
/// **A 12 MB category beside a 7.9 GB one is a hair wide** — it would draw as nothing, and a meter that silently omits a category is worse than one slightly out of proportion.
/// So each category with bytes gets at least [minWidth], and the rest share what is left in proportion.
/// A category with no bytes gets no width. The exact figures are in the rows either way.
List<double> meterWidths(
  List<int> byteValues,
  double available, {
  double gap = 2,
  double minWidth = 4,
}) {
  final shown = [for (var i = 0; i < byteValues.length; i++) if (byteValues[i] > 0) i];
  if (shown.isEmpty || available <= 0) return List<double>.filled(byteValues.length, 0);

  final room = available - gap * (shown.length - 1);
  final widths = List<double>.filled(byteValues.length, 0);
  var fixed = <int>{};
  // A segment lifted to the minimum takes room from the others, which can push one of them under it in turn.
  while (true) {
    final left = room - fixed.length * minWidth;
    final flexTotal = shown.where((i) => !fixed.contains(i)).fold<int>(0, (sum, i) => sum + byteValues[i]);
    final lifted = {
      for (final i in shown)
        if (!fixed.contains(i) && flexTotal > 0 && left * byteValues[i] / flexTotal < minWidth) i,
    };
    if (lifted.isEmpty) {
      for (final i in shown) {
        widths[i] = fixed.contains(i) ? minWidth : (flexTotal > 0 ? left * byteValues[i] / flexTotal : 0);
      }
      return widths;
    }
    fixed = {...fixed, ...lifted};
    if (fixed.length == shown.length) {
      for (final i in shown) {
        widths[i] = room / shown.length;
      }
      return widths;
    }
  }
}

/// One entry of the Largest mods list.
class LargestMod {
  const LargestMod({
    required this.item,
    required this.savedBytes,
    required this.savedCount,
  });

  /// The mod's folder as the Mods category measured it, which is a link when the folder lives elsewhere.
  final StorageItem item;

  /// What its saved versions take, and how many there are.
  final int savedBytes;
  final int savedCount;

  bool get isLinked => item.kind == StorageItemKind.linked;

  /// The installed files plus the saved versions. A link has no installed files of its own.
  int get totalBytes => item.bytes + savedBytes;
}

/// The [count] mods that take the most, installed files plus saved versions, largest first.
///
/// [mods] is the Mods category's items and [savedGroups] the Saved versions category's, one per mod keyed by its uid;
/// [uidOf] says which uid a mod folder carries, or null for a folder with none, which has no saved versions.
/// A mod that takes nothing at all is not listed.
List<LargestMod> largestMods(
  List<StorageItem> mods,
  List<StorageItem> savedGroups,
  String? Function(String folder) uidOf, {
  int count = 5,
}) {
  final groups = {for (final group in savedGroups) group.id: group};
  final ranked = [
    for (final mod in mods)
      LargestMod(
        item: mod,
        savedBytes: groups[uidOf(mod.id)]?.bytes ?? 0,
        savedCount: groups[uidOf(mod.id)]?.fileCount ?? 0,
      ),
  ].where((mod) => mod.totalBytes > 0).toList()
    ..sort((a, b) {
      final bySize = b.totalBytes.compareTo(a.totalBytes);
      return bySize != 0 ? bySize : a.item.label.toLowerCase().compareTo(b.item.label.toLowerCase());
    });
  return ranked.take(count).toList();
}

/// The biggest [cap] items largest first, and every item [keep] names, with the rest folded into a tail.
///
/// The tail exists so the visible rows still add up to the category total rather than quietly losing the remainder.
({List<StorageItem> items, int tailBytes, int tailCount}) foldTail(
  List<StorageItem> items, {
  int cap = 20,
  bool Function(StorageItem item)? keep,
}) {
  final sorted = [...items]..sort((a, b) => b.bytes.compareTo(a.bytes));
  final head = <StorageItem>[];
  var tailBytes = 0;
  var tailCount = 0;
  for (final (i, item) in sorted.indexed) {
    if (i < cap || (keep?.call(item) ?? false)) {
      head.add(item);
    } else {
      tailBytes += item.bytes;
      tailCount++;
    }
  }
  return (items: head, tailBytes: tailBytes, tailCount: tailCount);
}

/// Collapses volume lines that are telling the user the same thing twice.
///
/// Two probes on one disk answer identically, and "412 GB free" twice reads as
/// two disks with a coincidence. Identity cannot be tested portably from Dart —
/// `parseDfAvailableBytes` keeps only the byte count — so equal free space on
/// the same answer is the available approximation, and it errs towards showing
/// one line rather than inventing a distinction.
List<VolumeFreeSpace> collapseVolumes(List<VolumeFreeSpace> volumes) {
  final kept = <VolumeFreeSpace>[];
  for (final volume in volumes) {
    final duplicate = kept.any((other) =>
        other.freeBytes != null && other.freeBytes == volume.freeBytes);
    if (!duplicate) kept.add(volume);
  }
  return kept;
}
