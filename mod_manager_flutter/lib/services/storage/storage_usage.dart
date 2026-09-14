/// What the Storage page reports, and the arithmetic behind it.
///
/// Pure — no `dart:io`, no widgets. The page's every derived number is a
/// function in here, so the parts that decide what the user reads are tested
/// without a filesystem.
library;

/// The six things the app stores, which are also the donut's slices.
///
/// **They are disjoint, and that is load-bearing.** [mods] is the library
/// *minus* the sidecars and [sidecars] is the sidecars, because they live
/// inside the same folders: counting the library whole and the sidecars again
/// makes the slices sum past the total, and a chart whose parts exceed its
/// whole is not reporting, it is lying.
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

/// What one row in a category's drill-down is.
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

/// One row of a category's drill-down.
class StorageItem {
  const StorageItem({
    required this.id,
    required this.label,
    required this.path,
    required this.bytes,
    required this.kind,
    this.fileCount = 0,
    this.modified,
    this.detailKey,
  });

  final String id;
  final String label;
  final String path;
  final int bytes;
  final StorageItemKind kind;
  final int fileCount;
  final DateTime? modified;

  /// A localization **key** for a second line where the row needs one, such as
  /// why a snapshot was taken. A key rather than a string because the scanner
  /// is a service and has no business holding an `AppLocalizations`; dates come
  /// through [modified] and are formatted by the row.
  final String? detailKey;
}

/// One slice, and everything its drill-down shows.
class StorageCategory {
  const StorageCategory({
    required this.id,
    required this.read,
    required this.bytes,
    this.fileCount = 0,
    this.unreadableCount = 0,
    this.items = const <StorageItem>[],
    this.tailBytes = 0,
    this.tailCount = 0,
    this.rootPath,
  });

  /// Nothing configured — the library, before a folder is chosen.
  const StorageCategory.notConfigured(this.id)
      : read = StorageRead.notConfigured,
        bytes = 0,
        fileCount = 0,
        unreadableCount = 0,
        items = const <StorageItem>[],
        tailBytes = 0,
        tailCount = 0,
        rootPath = null;

  /// Configured and not there.
  const StorageCategory.absent(this.id, this.rootPath)
      : read = StorageRead.absent,
        bytes = 0,
        fileCount = 0,
        unreadableCount = 0,
        items = const <StorageItem>[],
        tailBytes = 0,
        tailCount = 0;

  final StorageCategoryId id;
  final StorageRead read;

  /// Apparent bytes — the sum of file lengths. With [read] `partial` this is a
  /// floor, and the UI says "at least".
  final int bytes;

  final int fileCount;
  final int unreadableCount;

  /// The biggest items, largest first, capped by [foldTail].
  final List<StorageItem> items;

  /// Everything below the cap, folded into one row so the drill-down still adds
  /// up to [bytes].
  final int tailBytes;
  final int tailCount;

  final String? rootPath;

  /// Whether this category contributes a slice. A category nobody has
  /// configured is not a zero-sized slice, it is absent from the chart.
  bool get hasMeasurement =>
      read == StorageRead.ok || read == StorageRead.partial;

  /// Whether the number shown should be read as "at least".
  bool get isFloor => read == StorageRead.partial;
}

/// Free space on one volume.
///
/// A list rather than a number because the library commonly lives on a
/// different disk than app data, so there is no single answer — and Dart cannot
/// portably compare two paths' devices, so the page labels the lines by what
/// they hold rather than pretending to identify the volume.
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

/// The whole page's arithmetic over however many categories have landed.
class StorageTotals {
  const StorageTotals({
    required this.bytes,
    required this.measured,
    required this.expected,
    required this.anyFloor,
  });

  /// Sums only what has arrived, so a page mid-scan shows a growing real number
  /// rather than nothing.
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
/// Zero when there is nothing to divide — a donut of a zero-byte library is
/// drawn empty rather than by dividing by zero.
double shareOf(int bytes, int total) {
  if (total <= 0 || bytes <= 0) return 0;
  return bytes / total;
}

/// Sweep angles for a donut, in radians, guaranteeing every non-zero slice is
/// actually visible.
///
/// **A 12 MB category beside a 3.1 GB one is a slice about a hundredth of a
/// degree wide** — it renders as nothing, and a chart that silently omits a
/// category is worse than one that is slightly out of proportion. So each
/// non-zero slice gets at least [minSweep], and the overshoot is taken back
/// from the slices that can afford it, in proportion to their size. The exact
/// figures are in the legend either way.
List<double> donutSweeps(
  List<int> byteValues, {
  double minSweep = 0.035,
  double fullCircle = 6.283185307179586,
}) {
  final total = byteValues.fold<int>(0, (sum, value) => sum + (value > 0 ? value : 0));
  if (total <= 0) return List<double>.filled(byteValues.length, 0);

  final sweeps = <double>[
    for (final value in byteValues)
      value <= 0 ? 0.0 : (value / total) * fullCircle,
  ];

  final needsLift = <int>[];
  var owed = 0.0;
  for (var i = 0; i < sweeps.length; i++) {
    if (sweeps[i] > 0 && sweeps[i] < minSweep) {
      owed += minSweep - sweeps[i];
      needsLift.add(i);
    }
  }
  if (needsLift.isEmpty) return sweeps;

  // Only slices that stay visible after giving can give.
  final donors = <int>[
    for (var i = 0; i < sweeps.length; i++)
      if (sweeps[i] > minSweep) i,
  ];
  final donatable =
      donors.fold<double>(0, (sum, i) => sum + (sweeps[i] - minSweep));
  if (donatable <= 0) {
    // Everything is tiny: an even split says "several categories, all small",
    // which is the honest reading.
    final even = fullCircle / (needsLift.length + donors.length);
    return [
      for (final sweep in sweeps) sweep <= 0 ? 0.0 : even,
    ];
  }

  final scale = (owed > donatable ? donatable : owed) / donatable;
  for (final i in donors) {
    sweeps[i] -= (sweeps[i] - minSweep) * scale;
  }
  for (final i in needsLift) {
    sweeps[i] = minSweep;
  }
  return sweeps;
}

/// The biggest [cap] items, with the rest folded into a tail.
///
/// A library of 300 mods must not render 300 rows: the question the drill-down
/// answers is "what is big", and the tail exists so the visible rows still add
/// up to the category total rather than quietly losing the remainder.
({List<StorageItem> items, int tailBytes, int tailCount}) foldTail(
  List<StorageItem> items, {
  int cap = 20,
}) {
  final sorted = [...items]..sort((a, b) => b.bytes.compareTo(a.bytes));
  if (sorted.length <= cap) {
    return (items: sorted, tailBytes: 0, tailCount: 0);
  }
  final head = sorted.take(cap).toList();
  final tail = sorted.skip(cap);
  return (
    items: head,
    tailBytes: tail.fold<int>(0, (sum, item) => sum + item.bytes),
    tailCount: tail.length,
  );
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
