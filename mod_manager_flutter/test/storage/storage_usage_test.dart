import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/services/storage/storage_usage.dart';

StorageItem item(String id, int bytes) => StorageItem(
      id: id,
      label: id,
      path: '/tmp/$id',
      bytes: bytes,
      kind: StorageItemKind.modFolder,
    );

StorageCategory measured(StorageCategoryId id, int bytes,
        {StorageRead read = StorageRead.ok}) =>
    StorageCategory(id: id, read: read, bytes: bytes);

void main() {
  group('foldTail', () {
    test('sorts biggest first and keeps everything under the cap', () {
      final folded = foldTail([item('a', 10), item('b', 90), item('c', 50)]);

      expect(folded.items.map((i) => i.id), ['b', 'c', 'a']);
      expect(folded.tailCount, 0);
      expect(folded.tailBytes, 0);
    });

    test('the tail holds the remainder, so the rows still add up', () {
      final items = [for (var i = 0; i < 25; i++) item('m$i', i + 1)];

      final folded = foldTail(items, cap: 20);

      expect(folded.items.length, 20);
      expect(folded.tailCount, 5);
      // 1..25 sums to 325; the five smallest are 1..5.
      expect(folded.tailBytes, 15);
      expect(
        folded.items.fold<int>(0, (sum, i) => sum + i.bytes) + folded.tailBytes,
        325,
      );
    });

    test('an item named to keep stays in the rows however small, in size order', () {
      final items = [for (var i = 0; i < 25; i++) item('m$i', i + 1)];

      final folded = foldTail(items, cap: 20, keep: (i) => i.id == 'm0' || i.id == 'm2');

      expect(folded.items.length, 22);
      expect(folded.items.map((i) => i.id).toList().sublist(20), ['m2', 'm0'], reason: 'largest first, kept ones included');
      expect(folded.tailCount, 3);
      expect(folded.tailBytes, 2 + 4 + 5);
    });
  });

  group('meterWidths', () {
    double used(List<double> widths, {double gap = 2}) =>
        widths.fold<double>(0, (sum, w) => sum + w) + gap * (widths.where((w) => w > 0).length - 1);

    test('nothing to draw is no segments rather than a division by zero', () {
      expect(meterWidths([0, 0, 0], 400), [0, 0, 0]);
    });

    test('proportional when every segment is already visible', () {
      final widths = meterWidths([50, 50], 402);

      expect(widths[0], closeTo(200, 0.0001));
      expect(widths[1], closeTo(200, 0.0001));
    });

    test('a segment too small to see is lifted to the floor', () {
      // 12 MB beside 7.9 GB is a hair wide, and a category the meter silently omits is worse than one slightly out of proportion.
      final widths = meterWidths([7900 * 1024 * 1024, 12 * 1024 * 1024], 600);

      expect(widths[1], 4);
      expect(used(widths), closeTo(600, 0.0001));
    });

    test('a category with no bytes gets no width and no gap', () {
      final widths = meterWidths([100, 0, 100], 402);

      expect(widths[1], 0);
      expect(widths[0], closeTo(200, 0.0001));
    });

    test('the bar is still whole after several are lifted', () {
      final widths = meterWidths([900000, 3, 4, 5, 6], 500);

      expect(widths.skip(1), everyElement(4));
      expect(used(widths), closeTo(500, 0.0001));
    });
  });

  group('percentLabel', () {
    test('rounds to a whole percent', () {
      expect(percentLabel(25, 100), '25%');
    });

    test('says under one percent rather than zero for something that is there', () {
      expect(percentLabel(3, 1000), '<1%');
    });

    test('is zero for nothing, and for no total', () {
      expect(percentLabel(0, 100), '0%');
      expect(percentLabel(5, 0), '0%');
    });
  });

  group('largestMods', () {
    StorageItem folder(String id, int bytes, {bool linked = false}) => StorageItem(
          id: id,
          label: id,
          path: '/lib/$id',
          bytes: bytes,
          kind: linked ? StorageItemKind.linked : StorageItemKind.modFolder,
        );

    StorageItem group(String uid, int bytes, int count) => StorageItem(
          id: uid,
          label: uid,
          path: '/backups/$uid',
          bytes: bytes,
          fileCount: count,
          kind: StorageItemKind.snapshotGroup,
        );

    String? uidOf(String folder) => {'Ellen': 'u-ellen', 'Nicole': 'u-nicole', 'Linked': 'u-linked'}[folder];

    test('ranks the installed files plus the saved versions', () {
      final ranked = largestMods(
        [folder('Ellen', 100), folder('Nicole', 150)],
        [group('u-ellen', 80, 2)],
        uidOf,
      );

      expect(ranked.map((m) => m.item.id), ['Ellen', 'Nicole']);
      expect(ranked.first.totalBytes, 180);
      expect(ranked.first.savedCount, 2);
    });

    test('keeps the five largest', () {
      final ranked = largestMods([for (var i = 1; i <= 8; i++) folder('m$i', i * 10)], const [], uidOf);

      expect(ranked.map((m) => m.item.id), ['m8', 'm7', 'm6', 'm5', 'm4']);
    });

    test('a mod with no uid has no saved versions', () {
      final ranked = largestMods([folder('Stray', 10)], [group('u-ellen', 80, 2)], uidOf);

      expect(ranked.single.savedBytes, 0);
      expect(ranked.single.savedCount, 0);
    });

    test('a mod that takes nothing is not listed', () {
      expect(largestMods([folder('Empty', 0)], const [], uidOf), isEmpty);
    });

    test('a link is marked as one, and ranks on its saved versions alone', () {
      final ranked = largestMods(
        [folder('Linked', 0, linked: true), folder('Ellen', 50)],
        [group('u-linked', 70, 1)],
        uidOf,
      );

      expect(ranked.first.item.id, 'Linked');
      expect(ranked.first.isLinked, isTrue);
    });
  });

  group('StorageTotals', () {
    test('sums only what has landed, and says how much has', () {
      final totals = StorageTotals.from([
        measured(StorageCategoryId.mods, 100),
        null,
        measured(StorageCategoryId.logs, 5),
      ]);

      expect(totals.bytes, 105);
      expect(totals.measured, 2);
      expect(totals.expected, 3);
      expect(totals.isComplete, isFalse);
    });

    test('an unconfigured category contributes nothing but is not missing', () {
      final totals = StorageTotals.from([
        measured(StorageCategoryId.mods, 100),
        const StorageCategory.notConfigured(StorageCategoryId.sidecars),
      ]);

      expect(totals.bytes, 100);
      expect(totals.isComplete, isTrue);
    });

    test('one partial category makes the whole total a floor', () {
      final totals = StorageTotals.from([
        measured(StorageCategoryId.mods, 100, read: StorageRead.partial),
        measured(StorageCategoryId.logs, 5),
      ]);

      expect(totals.anyFloor, isTrue);
    });
  });

  group('collapseVolumes', () {
    test('two probes answering the same are one line', () {
      final volumes = collapseVolumes(const [
        VolumeFreeSpace(label: 'app_data', probedPath: '/a', freeBytes: 500),
        VolumeFreeSpace(label: 'mods_library', probedPath: '/b', freeBytes: 500),
      ]);

      expect(volumes.length, 1);
      expect(volumes.single.label, 'app_data');
    });

    test('different disks stay two lines', () {
      final volumes = collapseVolumes(const [
        VolumeFreeSpace(label: 'app_data', probedPath: '/a', freeBytes: 500),
        VolumeFreeSpace(label: 'mods_library', probedPath: '/b', freeBytes: 900),
      ]);

      expect(volumes.length, 2);
    });

    test('two unknowns are kept apart — neither is evidence of the other', () {
      final volumes = collapseVolumes(const [
        VolumeFreeSpace(label: 'app_data', probedPath: '/a', freeBytes: null),
        VolumeFreeSpace(label: 'mods_library', probedPath: '/b', freeBytes: null),
      ]);

      expect(volumes.length, 2);
    });
  });

  group('shareOf', () {
    test('is zero rather than infinite when there is nothing to divide', () {
      expect(shareOf(10, 0), 0);
      expect(shareOf(0, 100), 0);
    });

    test('is the fraction otherwise', () {
      expect(shareOf(25, 100), closeTo(0.25, 0.0001));
    });
  });
}
