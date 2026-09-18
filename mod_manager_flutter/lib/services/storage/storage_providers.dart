/// Everything the Storage page reads.
///
/// Here rather than in `utils/state_providers.dart` for the reason the download
/// layer keeps its own: this is one feature's state, and the registry would
/// have to import the whole storage service graph to hold it.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../utils/state_providers.dart';
import '../archive_activity.dart';
import '../download/download_queue.dart';
import '../log/logger.dart';
import '../platform_service_factory.dart';
import 'reclaim_service.dart';
import 'storage_roots.dart';
import 'storage_scanner.dart';
import 'storage_usage.dart';

/// Where the app keeps things, rebuilt when the library is repointed.
///
/// Watching `modsPathProvider` is the one automatic chain worth having here:
/// changing the folder in Settings rebuilds the roots, which rebuilds the
/// scanner, which invalidates every category. Nothing else needs wiring.
final storageRootsProvider = Provider<StorageRoots>((ref) {
  return StorageRoots.forApp(
    modsPath: ref.watch(modsPathProvider),
    currentLogFile: Log.filePath,
  );
});

final storageScannerProvider = Provider<StorageScanner>((ref) {
  return StorageScanner(
    ref.watch(storageRootsProvider),
    snapshots: ref.read(snapshotServiceProvider),
    platform: PlatformServiceFactory.getInstance(),
  );
});

/// One category, measured.
///
/// **A family rather than one provider for the lot**, for three reasons that
/// all matter on this page: a category that fails greys one legend row instead
/// of blanking the screen; the cheap five land in milliseconds so the page is
/// never empty behind the library walk; and the reclaim can invalidate the
/// three keys it touched without discarding a multi-second walk of a library
/// nothing changed.
///
/// **Not `autoDispose`** — deliberately, and it is what makes the Storage tab
/// work at all. Tabs are keyed `AnimatedSwitcher` children with no keep-alive,
/// so the screen's `State` is disposed the moment the user switches away. A
/// container-owned provider is not: a walk started here runs to completion and
/// the answer is waiting on the way back.
final storageCategoryProvider =
    FutureProvider.family<StorageCategory, StorageCategoryId>((ref, id) async {
  final scanner = ref.watch(storageScannerProvider);
  return switch (id) {
    StorageCategoryId.mods => scanner.mods(),
    StorageCategoryId.sidecars => scanner.sidecars(),
    StorageCategoryId.savedVersions => scanner.savedVersions(),
    StorageCategoryId.downloads => scanner.downloads(),
    StorageCategoryId.logs => scanner.logs(),
    StorageCategoryId.leftovers => scanner.leftovers(),
  };
});

/// Free space where the app writes — one line per volume, so a library on a
/// second disk is not reported against the wrong one.
final storageFreeSpaceProvider = FutureProvider<List<VolumeFreeSpace>>((ref) {
  return ref.watch(storageScannerProvider).volumes();
});

/// The total, over however many categories have answered so far.
final storageTotalsProvider = Provider<StorageTotals>((ref) {
  return StorageTotals.from([
    for (final id in StorageCategoryId.values)
      ref.watch(storageCategoryProvider(id)).valueOrNull,
  ]);
});

/// Frees what is safe to free, and publishes what it came to.
///
/// A notifier rather than an `await` in the button's handler, for the same
/// reason the scan is a provider: the tab's `State` dies on a tab switch, and a
/// user who presses this and immediately goes to look at their mods should not
/// lose the report. The sweep raises no dialog of its own, so it needs no
/// `Navigator` and therefore no host above the switcher — only somewhere to put
/// the answer that outlives the screen.
final reclaimControllerProvider =
    AsyncNotifierProvider<ReclaimController, ReclaimOutcome?>(
        ReclaimController.new);

class ReclaimController extends AsyncNotifier<ReclaimOutcome?> {
  @override
  Future<ReclaimOutcome?> build() async => null;

  Future<void> run() async {
    // A second press while the first is still deleting would plan against an
    // inventory the first is in the middle of removing.
    if (state.isLoading) return;
    state = const AsyncValue<ReclaimOutcome?>.loading();

    final service = ReclaimService(
      ref.read(storageRootsProvider),
      downloadsBusy: () =>
          ref.read(downloadQueueProvider).any((job) => !job.state.isTerminal),
      installBusy: () => ArchiveActivity.isBusy,
      modNames: () async {
        try {
          final mods = await ref.read(libraryProvider.future);
          return mods.map((mod) => mod.id).toSet();
        } catch (_) {
          // Null, never an empty set: "I could not read the library" is what
          // stops the legacy-image sweep, and an empty set would tell it that
          // every image is unreachable.
          return null;
        }
      },
      claimedSnapshotUids: () async {
        try {
          final mods = await ref.read(libraryProvider.future);
          return mods.map((mod) => mod.uid).nonNulls.toSet();
        } catch (_) {
          return null;
        }
      },
      freeSpace: PlatformServiceFactory.getInstance().freeSpaceBytes,
    );

    state = await AsyncValue.guard(() async {
      final outcome = await service.run();
      // Only what the sweep can touch. The library walk is untouched by it, and
      // re-running one would throw away seconds of work for nothing.
      for (final id in const [
        StorageCategoryId.savedVersions,
        StorageCategoryId.downloads,
        StorageCategoryId.logs,
        StorageCategoryId.leftovers,
      ]) {
        ref.invalidate(storageCategoryProvider(id));
      }
      ref.invalidate(storageFreeSpaceProvider);
      return outcome;
    });
  }
}

/// The categories a scan can re-read in milliseconds.
///
/// Refreshed on every visit to the tab. The library walk is not: bouncing off
/// the tab must not re-walk gigabytes, so it stays cached behind an explicit
/// Rescan and the page says when the library has changed under it.
const List<StorageCategoryId> cheapStorageCategories = <StorageCategoryId>[
  StorageCategoryId.savedVersions,
  StorageCategoryId.downloads,
  StorageCategoryId.logs,
  StorageCategoryId.leftovers,
];

/// The two that walk the library.
const List<StorageCategoryId> libraryStorageCategories = <StorageCategoryId>[
  StorageCategoryId.mods,
  StorageCategoryId.sidecars,
];
