import 'dart:math' as math;

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
  });

  group('donutSweeps', () {
    const fullCircle = 2 * math.pi;

    test('nothing to draw is no slices rather than a division by zero', () {
      expect(donutSweeps([0, 0, 0]), [0, 0, 0]);
    });

    test('proportional when every slice is already visible', () {
      final sweeps = donutSweeps([50, 50]);

      expect(sweeps[0], closeTo(math.pi, 0.0001));
      expect(sweeps[1], closeTo(math.pi, 0.0001));
    });

    test('a slice too small to see is lifted to the floor', () {
      // 12 MB beside 3.1 GB is about a hundredth of a degree: invisible, and a
      // category the chart silently omits is worse than one slightly out of
      // proportion.
      final sweeps = donutSweeps([3100 * 1024 * 1024, 12 * 1024 * 1024]);

      expect(sweeps[1], greaterThanOrEqualTo(0.035));
      expect(sweeps.reduce((a, b) => a + b), closeTo(fullCircle, 0.0001));
    });

    test('a zero category still gets no slice at all', () {
      final sweeps = donutSweeps([100, 0, 5]);

      expect(sweeps[1], 0);
      expect(sweeps[0], greaterThan(0));
      expect(sweeps[2], greaterThan(0));
    });

    test('the circle is still whole after lifting', () {
      final sweeps = donutSweeps([900000, 3, 4, 5, 6]);

      expect(sweeps.reduce((a, b) => a + b), closeTo(fullCircle, 0.0001));
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
