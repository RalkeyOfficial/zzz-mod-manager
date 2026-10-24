/// Everything Settings' Storage section reads.
///
/// Here rather than in `utils/state_providers.dart` for the reason the download
/// layer keeps its own: this is one feature's state, and the registry would
/// have to import the whole storage service graph to hold it.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/character_info.dart';
import '../../utils/state_providers.dart';
import '../archive_activity.dart';
import '../download/download_job.dart';
import '../download/download_queue.dart';
import '../log/logger.dart';
import '../platform_service_factory.dart';
import 'reclaim_plan.dart';
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
/// **A family rather than one provider for the lot**, for three reasons that all matter in this section:
/// a category that fails greys one row instead of blanking the section;
/// the cheap ones land in milliseconds so the section is never empty behind the library walk;
/// and the reclaim can invalidate the keys it touched without discarding a multi-second walk of a library nothing changed.
///
/// **Not `autoDispose`** — deliberately, and it is what makes the Storage section work at all.
/// Pages are keyed `AnimatedSwitcher` children with no keep-alive, so the section's `State` is disposed the moment the user switches away.
/// A container-owned provider is not: a walk started here runs to completion and the answer is waiting on the way back.
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

/// Frees what is safe to free among the stores an action names, and publishes what it came to.
///
/// A notifier rather than an `await` in the button's handler, for the same reason the scan is a provider:
/// the section's `State` dies on a page switch, and a user who presses this and immediately goes to look at their mods should not lose the report.
/// The sweep raises no dialog of its own, so it needs no `Navigator` and therefore no host above the switcher — only somewhere to put the answer that outlives the screen.
final reclaimControllerProvider =
    AsyncNotifierProvider<ReclaimController, ReclaimOutcome?>(
        ReclaimController.new);

class ReclaimController extends AsyncNotifier<ReclaimOutcome?> {
  // Synchronous, so the state is data from the first read: a press that came while an async build was still loading would be taken for a press while a sweep runs.
  @override
  ReclaimOutcome? build() => null;

  /// Sweeps [targets] and returns what it came to, or null when another sweep is still running.
  Future<ReclaimOutcome?> run(Set<ReclaimTarget> targets) async {
    // A second press while the first is still deleting would plan against an inventory the first is in the middle of removing.
    if (state.isLoading) return null;
    state = const AsyncValue<ReclaimOutcome?>.loading();

    final service = ReclaimService(
      ref.read(storageRootsProvider),
      downloadsBusy: () =>
          ref.read(downloadQueueProvider).any((job) => !job.state.isTerminal),
      // A download installing holds its folders past the unpack, while the import copies from them, and an update holds its own while it asks and writes.
      installBusy: () =>
          ArchiveActivity.isBusy ||
          ref.read(downloadQueueProvider).any(
              (job) => job.state == DownloadJobState.installing || job.state == DownloadJobState.updating),
      downloadWaiting: () => ref.read(downloadQueueProvider).any((job) => job.state == DownloadJobState.waiting),
      modNames: () async => (await _readLibrary())?.map((mod) => mod.id).toSet(),
      claimedSnapshotUids: () async => (await _readLibrary())?.map((mod) => mod.uid).nonNulls.toSet(),
      freeSpace: PlatformServiceFactory.getInstance().freeSpaceBytes,
    );

    state = await AsyncValue.guard(() async {
      final outcome = await service.run(targets);
      // Only what the sweep can touch. The library walk is untouched by it, and re-running one would throw away seconds of work for nothing.
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
    return state.requireValue;
  }

  /// The library's mods, or null when it could not be read.
  ///
  /// Null, never an empty list: "I could not read the library" is what stops the legacy-image and saved-versions sweeps,
  /// and an empty list would tell them every image is unreachable and every group unclaimed.
  /// The scan answers an empty list rather than an error with no ZZMI folder set, so that case is null here too.
  /// A library folder that is unset, missing, unreadable or holding a dead link is refused by [ReclaimService], which knows the roots.
  /// The library is walked again first: the cached list may be an empty one from when its drive was away.
  Future<List<ModInfo>?> _readLibrary() async {
    if (ref.read(zzmiPathProvider).isEmpty) return null;
    try {
      await ref.read(libraryProvider.notifier).rescan();
      return await ref.read(libraryProvider.future);
    } catch (_) {
      return null;
    }
  }
}

/// The categories a scan can re-read in milliseconds.
///
/// Refreshed on every visit to the section.
/// The library walk is not: bouncing off the section must not re-walk gigabytes, so it stays cached behind an explicit Rescan and the section says when the library has changed under it.
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
