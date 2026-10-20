import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import '../core/constants.dart';
import '../core/palette.dart';
import '../models/character_info.dart';
import '../services/api_service.dart';
import '../services/bulk_assume_current.dart';
import '../services/bulk_resolution.dart';
import '../models/gamebanana/gb_enums.dart';
import '../models/gamebanana/gb_mod.dart';
import '../services/gamebanana/content_filter.dart';
import '../services/gamebanana/gamebanana_client.dart';
import '../services/backup/snapshot_service.dart';
import '../services/bulk_update_check.dart';
import '../services/download_names.dart';
import '../services/installed_mods_index.dart';
import '../models/mod_origin.dart';
import '../services/log/logger.dart';
import '../services/mod_manager_service.dart';
import '../services/mod_metadata_service.dart';
import '../services/origin_status.dart';
import '../services/origin_write.dart';
import '../services/platform_service.dart';
import '../services/platform_service_factory.dart';
import '../services/shader_fixes/zzmi_layout.dart';
import '../services/storage/storage_scanner.dart';
import '../services/update_check.dart';
import 'categories.dart';
import 'directory_size.dart';
import 'mod_sorting.dart';
import 'zzz_characters.dart';

final Logger _log = Logger('origin');

// The marketplace's own browsing state (query, results, categories, open mod)
// lives in `marketplace_providers.dart` — one screen's session rather than
// app-wide state, and keeping it there is what stops this registry sprawling.
//
// The notification stack lives in `notifications.dart` for the same reason: it
// is one subsystem with its own vocabulary (kinds, repeats, handles), and
// call sites reach it through `context.notify` rather than through a provider.

/// The library's service: scanning, linking, importing, and the sidecar writes.
///
/// **Every widget reaches it through this**, never through
/// `ApiService.getModManagerService`. The facade only builds the instance; a
/// test hands a widget a library of its own by overriding this one provider
/// (`TempLibrary.overrides`), and there is nothing else to substitute.
final modManagerServiceProvider = FutureProvider<ModManagerService>((ref) async {
  return await ApiService.getModManagerService();
});

/// The production [OriginWriter], for the dialogs that take one as a seam.
///
/// Takes the service's future rather than a `ref`, and resolves it when the
/// writer is called: a `WidgetRef` throws once its widget is gone, and a bulk
/// write can outlive the tab that started it.
OriginWriter originWriterFor(Future<ModManagerService> service) =>
    (modId, update) async => (await service).updateModOrigin(modId, update);

/// The production [OriginReader], built the same way as [originWriterFor].
OriginReader originReaderFor(Future<ModManagerService> service) =>
    (modName) async => (await service).readModOrigin(modName);

/// The GameBanana API client (browse / search / mod detail).
///
/// Deliberately **not** hung off `ApiService`, despite that being the usual
/// entry point for screens: `ApiService` is a static facade over singletons,
/// and a static singleton cannot take an injected HTTP transport — which is the
/// whole point of the seam that lets this layer be tested offline. A provider
/// gives the same single shared instance with a real disposal hook.
///
/// Screens should read this rather than constructing a client, so the response
/// cache is shared across the results grid and the detail view.
final gameBananaClientProvider = Provider<GameBananaClient>((ref) {
  final client = GameBananaClient();
  ref.onDispose(client.close);
  return client;
});

// `downloadQueueProvider` and `downloadServiceProvider` live in
// `services/download/download_queue.dart`, for the same reason the notification
// stack lives in `notifications.dart`. The Storage tab's providers live in
// `services/storage/storage_providers.dart` on the same terms — they are one
// feature's state, and holding them here would pull the whole storage service
// graph into this file's imports.

/// The library: every mod, once each, flat.
///
/// **The root everything else about the library derives from, and it belongs to
/// no screen.** The pages are keyed children of an `AnimatedSwitcher` with no
/// keep-alive, so the Library page's `State` is *disposed* the moment the user
/// looks at the marketplace. A library owned by that page would be as old as
/// the last visit to it for as long as the user is anywhere else — and the mods
/// missing from it would be exactly the ones just installed, which is when a
/// question about the library is most likely to be asked.
///
/// So the scan lives here. Anything that needs the library reads this: cached
/// while it is good, awaited when it is cold, and refreshed by whoever changes
/// the folder. One scan, the in-game keys check included, is **7 ms warm, 14 ms
/// cold** over a mirror of a real 23-mod library and **26 ms warm, 54 ms cold**
/// over a made-up one of 100 mods, so a refresh is not something to design
/// around.
///
/// The Library's character list is derived from this ([libraryGroupCountsProvider],
/// [currentCharacterSkinsProvider]), so it follows a change made on any page.
final libraryProvider =
    AsyncNotifierProvider<LibraryNotifier, List<ModInfo>>(LibraryNotifier.new);

/// Reads the library from disk, and holds what it read.
class LibraryNotifier extends AsyncNotifier<List<ModInfo>> {
  /// The scan currently walking the folder, if any.
  ///
  /// **One walk at a time, whoever asked for it.** The first read of this
  /// provider starts a scan, and at launch that read comes from above the pages
  /// — the bulk update check's plan reads the library — while the Library page
  /// mounts a moment later and asks for one of its own. Two walks of the same
  /// folder at the same moment produce one answer between them, and the second
  /// publish tears the grid down to rebuild it identically.
  Future<List<ModInfo>>? _inFlight;

  /// Bumped by every edit ([put]) and every build.
  ///
  /// A rename or a delete knows exactly what it did, and a build follows an invalidate, made after a change to the
  /// folder. A walk that was already running when either happened is the **older** answer, whichever finishes last.
  int _generation = 0;

  @override
  FutureOr<List<ModInfo>> build() => _walkUntilCurrent(++_generation);

  /// Walks the folder until a walk ends with no edit or build having come in since [generation], and answers with
  /// that walk. A walk something came in during is walked again, failed or not: what came in is newer than what it
  /// read, but may not be all that changed. Ends once the edits stop, one walk after the last.
  Future<List<ModInfo>> _walkUntilCurrent(int generation) async {
    while (true) {
      try {
        final scanned = await _track(_scan());
        if (_generation == generation) return scanned;
      } catch (_) {
        if (_generation == generation) rethrow;
      }
      generation = _generation;
    }
  }

  /// Marks [scan] as the walk in progress, and unmarks it when it ends.
  Future<List<ModInfo>> _track(Future<List<ModInfo>> scan) {
    _inFlight = scan;
    unawaited(scan.then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
      if (identical(_inFlight, scan)) _inFlight = null;
    }));
    return scan;
  }

  /// Reads the library again.
  ///
  /// **Keeps the list it already has when the scan finds it unchanged**, so the
  /// grid is not torn down and rebuilt by a rescan that changed one mod or
  /// nothing at all. The comparison is [ModInfo]'s own value equality, so a
  /// field is covered by being a field: a hand-written field list misses one,
  /// and the symptom is a card showing an old answer with nothing thrown.
  /// **A scan already in progress is joined** rather than walked beside, and
  /// once it is published this call walks once more, since that scan may have
  /// read the folder before the caller's change. It returns once the answer is
  /// *published*, because the caller's next act is to read the library.
  Future<void> rescan() async {
    try {
      await _rescan();
    } finally {
      ref.read(libraryScansProvider.notifier).state++;
    }
  }

  Future<void> _rescan() async {
    final running = _inFlight;
    if (running != null) {
      await running.then<void>((_) {}, onError: (Object _) {});
      await future.then<void>((_) {}, onError: (Object _) {});
      // The walk joined may have read the folder before the caller's change, so a walk that starts after it follows:
      // one another caller already started, or this one's own. A walk that finds nothing changed publishes nothing.
      final later = _inFlight;
      if (later != null) {
        await later.then<void>((_) {}, onError: (Object _) {});
        await future.then<void>((_) {}, onError: (Object _) {});
        return;
      }
    }
    await _walk();
  }

  /// Reads the folder as it is once the edits made meanwhile stop, and publishes it when it differs.
  Future<void> _walk() async {
    try {
      final scanned = await _walkUntilCurrent(_generation);
      final current = state.valueOrNull;
      if (current == null || !listEquals(current, scanned)) {
        state = AsyncValue.data(scanned);
      }
    } catch (e, stack) {
      state = AsyncValue.error(e, stack);
    }
  }

  /// Replaces the library with a list built in memory.
  ///
  /// For a change whose effect on the library is already known — a rename, an
  /// edit, a favourite, a delete — where a rescan would walk every folder to
  /// learn what the caller just did.
  void put(List<ModInfo> mods) {
    _generation++;
    state = AsyncValue.data(mods);
  }

  Future<List<ModInfo>> _scan() async {
    final scanned = await ApiService.getMods();
    final configService = await ApiService.getConfigService();
    final favourites = configService.favoriteMods.toSet();

    // The character is what the service resolved (in-folder metadata, then the
    // legacy config tag), never a guess from the name: "Zhao Nicole" reads as
    // Nicole, and a mod the user filed under Unassigned must stay there. An
    // import detects and saves a character once, where the user sees it.
    final mods = [
      for (final mod in scanned) mod.copyWith(isFavorite: favourites.contains(mod.id)),
    ];

    await configService.cleanupInvalidTags([for (final mod in mods) mod.id]);

    final modManagerService = await ref.read(modManagerServiceProvider.future);
    return modManagerService.enrichModsWithKeybinds(mods);
  }
}

/// Bumped when a [LibraryNotifier.rescan] ends, whether or not it changed the library.
final libraryScansProvider = StateProvider<int>((ref) => 0);

/// What the local library already has, keyed by remote identity.
///
/// Derived from [libraryProvider], so a mod installed from the marketplace is
/// badged as installed on the surface the user is looking at rather than after
/// their next visit to the Library — the one moment they cannot see the badge.
/// Building the index over an already-scanned list is **under 1 ms**.
///
/// Read it as `valueOrNull ?? InstalledModsIndex.empty`: while it loads, "nothing
/// is known to be installed" renders no badge, which is the right way to be wrong.
final installedModsIndexProvider =
    FutureProvider<InstalledModsIndex>((ref) async {
  return InstalledModsIndex.fromMods(await ref.watch(libraryProvider.future));
});

/// The pages the sidebar switches between. [characters], [allMods] and [updates] are the Library's three views, one
/// page that stays mounted between them.
enum AppDestination { characters, allMods, updates, browse, storage, settings }

/// The page the main area shows. Its pages are keyed `AnimatedSwitcher` children
/// with no keep-alive, so the page left behind is disposed.
final destinationProvider = StateProvider<AppDestination>((ref) => AppDestination.characters);

/// Whether [destination] is one of the Library's views.
bool isLibraryView(AppDestination destination) =>
    destination == AppDestination.characters ||
    destination == AppDestination.allMods ||
    destination == AppDestination.updates;

/// Whether the Updates page's Can't be checked section is folded, for the session.
final updatesCantCheckHiddenProvider = StateProvider<bool>((ref) => false);

/// The mods the Updates page's last "Mark all as current" wrote, for its Undo, until the app closes. Null when there
/// is none to show, or it was undone.
final lastMarkingProvider = StateProvider<List<MarkedAsCurrent>?>((ref) => null);

/// Opens the All mods table on [filter] alone: no search, no folded group and no mod's page left from before, so it
/// shows every mod the filter keeps.
void openAllModsFiltered(WidgetRef ref, AllModsFilter filter) {
  ref.read(allModsFilterProvider.notifier).state = filter;
  ref.read(allModsSearchProvider.notifier).state = '';
  ref.read(allModsCollapsedProvider.notifier).state = const {};
  ref.read(openModPageProvider.notifier).state = null;
  ref.read(destinationProvider.notifier).state = AppDestination.allMods;
}

/// Opens the Library's Characters view on [modId]: its character's row, with its details panel open. Returns false,
/// and goes nowhere, when the library has no such mod, or could not be read.
///
/// Decided on a finished read: while a scan runs, such as the one an install starts, the list in hand predates the
/// mod, so this waits for the scan rather than calling the mod gone. Takes a container rather than a ref, since a
/// notification's action outlives the widget that raised it.
Future<bool> showModInCharacters(ProviderContainer container, String modId) async {
  final library = container.read(libraryProvider);
  final List<ModInfo> mods;
  try {
    mods = library.isLoading ? await container.read(libraryProvider.future) : library.requireValue;
  } catch (_) {
    return false;
  }
  final mod = mods.where((m) => m.id == modId).firstOrNull;
  if (mod == null) return false;
  container.read(openModPageProvider.notifier).state = null;
  container.read(selectedCharacterIdProvider.notifier).state = libraryGroupOf(mod.characterId);
  container.read(selectedModIdProvider.notifier).state = modId;
  container.read(destinationProvider.notifier).state = AppDestination.characters;
  return true;
}

/// Every mod in the library, once each — as far as a synchronous reader is
/// concerned.
///
/// The library itself is [libraryProvider]; this is the plain-list view of it
/// for the widgets and derived providers that cannot await, and it is **empty
/// while the first scan is still running**. Anything that must not mistake "not
/// read yet" for "nothing installed" — a modal deciding what to offer, most
/// obviously — awaits `libraryProvider.future` instead.
///
/// Anything asking a question about the whole library wants this rather than
/// [currentCharacterSkinsProvider], which is one tab's worth.
final modsProvider = Provider<List<ModInfo>>((ref) {
  return ref.watch(libraryProvider).valueOrNull ?? const <ModInfo>[];
});

/// How many mods one row of the Library's character list holds, how many are on, and how many the last check
/// flagged.
@immutable
class LibraryGroupCounts {
  const LibraryGroupCounts({this.mods = 0, this.active = 0, this.updates = 0});

  final int mods;
  final int active;
  final int updates;

  static const LibraryGroupCounts empty = LibraryGroupCounts();
}

/// Every row of the character list's counts, keyed by [libraryGroupOf]. A row with no mods is absent.
final libraryGroupCountsProvider = Provider<Map<String, LibraryGroupCounts>>((ref) {
  final checks = ref.watch(modUpdateChecksProvider);
  final counts = <String, ({int mods, int active, int updates})>{};
  for (final mod in ref.watch(modsProvider)) {
    final group = libraryGroupOf(mod.characterId);
    final c = counts[group] ?? (mods: 0, active: 0, updates: 0);
    counts[group] = (
      mods: c.mods + 1,
      active: c.active + (mod.isActive ? 1 : 0),
      updates: c.updates + ((checks[mod.id]?.hasUpdate ?? false) ? 1 : 0),
    );
  }
  return {
    for (final e in counts.entries)
      e.key: LibraryGroupCounts(mods: e.value.mods, active: e.value.active, updates: e.value.updates),
  };
});

/// The row of the character list the user picked, or null before they have picked one.
final selectedCharacterIdProvider = StateProvider<String?>((ref) => null);

/// Whether [selectedCharacterIdProvider] holds the user's own click on a row, rather than the page the app shows
/// before one. A drop or paste is filed under a character only when it does (`docs/library-screen.md` §3).
final characterPickedByUserProvider = StateProvider<bool>((ref) => false);

/// The character list row on screen: the one picked, or else the first agent with a mod, the first category with
/// one, Unassigned if it has one, and the first agent when the library is empty.
///
/// Held by id and above the page, so it survives a page switch and a group gaining or losing its last mod.
final currentCharacterIdProvider = Provider<String>((ref) {
  final picked = ref.watch(selectedCharacterIdProvider);
  if (picked != null) return picked;
  final counts = ref.watch(libraryGroupCountsProvider);
  return libraryGroupIds.firstWhere((id) => counts.containsKey(id), orElse: () => zzzCharacterIds.first);
});

/// The mods filed under the character list row on screen.
final currentCharacterSkinsProvider = Provider<List<ModInfo>>((ref) {
  final current = ref.watch(currentCharacterIdProvider);
  return [
    for (final mod in ref.watch(modsProvider))
      if (libraryGroupOf(mod.characterId) == current) mod,
  ];
});

/// How much a mod's own files take, its sidecar left out as the Storage page leaves it out of Mods
/// (`docs/disk-usage.md`). Null while there is no library to look in.
///
/// Measured on demand for the mods on screen, off the UI isolate, and again when the mod changes; a walk is
/// about half a millisecond per mod. Apparent size, like every other number the app shows.
final modSizeProvider = FutureProvider.autoDispose.family<DirSize?, String>((ref, modId) async {
  // Watched so an update or a restore, which reach the library as a changed mod, measure it again.
  ref.watch(modsProvider.select((mods) => mods.where((m) => m.id == modId).firstOrNull));
  final library = ref.watch(modsPathProvider);
  if (library.isEmpty) return null;
  final folder = p.join(library, modId);
  return measureDirectory(folder, excludePaths: {p.join(folder, AppConstants.modMetadataDirName)});
});

/// Every mod's own files in bytes, by folder id, from one walk of the library (`docs/library-screen.md` §16).
///
/// For the All mods table, which shows every mod's size and their total at once: one walk off the UI isolate
/// rather than an isolate per mod. Walked again when a mod is added, removed or its origin changes, as an update or
/// a restore changes it; a toggle or a favourite changes neither, so it walks nothing.
final librarySizesProvider = FutureProvider<Map<String, int>>((ref) async {
  ref.watch(modsProvider.select((mods) => Object.hashAll([for (final m in mods) Object.hash(m.id, m.origin)])));
  final library = ref.watch(modsPathProvider);
  if (library.isEmpty) return const {};
  final sizes = await Isolate.run(() => measureLibrarySync(library));
  return {for (final size in sizes) if (!size.isLink) size.name: size.ownBytes};
});

/// The links in ZZMI's mods folder whose target folder is missing and whose name is no mod in the library: the All
/// mods table's Folder missing rows (`docs/library-screen.md` §16).
///
/// Read again after every scan, a scan that finds the library unchanged too: a drive coming back or going away changes
/// only the links. Never written: such a link is not removed or offered for removal, since it works again once its
/// folder is back.
final deadModLinksProvider = FutureProvider<List<DeadModLink>>((ref) async {
  ref.watch(libraryScansProvider);
  final folder = ref.watch(linksFolderProvider);
  final library = ref.watch(libraryProvider);
  if (folder == null || !library.hasValue) return const [];
  final names = {for (final mod in library.value!) mod.id};
  final dead = await PlatformServiceFactory.getInstance().listDeadModLinks(folder);
  return [for (final link in dead) if (!names.contains(link.name)) link];
});

/// What the All mods table shows. One at a time, like the chips that set it.
enum AllModsFilter { all, active, off, updates, folderMissing, favorites, needsAttention }

final allModsFilterProvider = StateProvider<AllModsFilter>((ref) => AllModsFilter.all);

/// The All mods table's search text.
final allModsSearchProvider = StateProvider<String>((ref) => '');

/// The All mods table's sortable columns.
enum AllModsColumn { name, character, status, updates, size, added }

/// The column the All mods table is sorted by, and which way.
@immutable
class AllModsSort {
  const AllModsSort(this.column, {required this.descending});

  /// The order with no column picked: newest added first, as the character view's default sort.
  static const AllModsSort byDefault = AllModsSort(AllModsColumn.added, descending: true);

  final AllModsColumn column;
  final bool descending;

  /// Which way [column] runs when first picked: names A to Z, Active before Off, updates by need (Newer file first),
  /// numbers and dates largest and newest first.
  static bool startsDescending(AllModsColumn column) =>
      !{AllModsColumn.name, AllModsColumn.character, AllModsColumn.status, AllModsColumn.updates}.contains(column);

  /// What pressing [column]'s heading does to [current]: picks it in its natural direction, then reverses it, then
  /// clears the sort.
  static AllModsSort? next(AllModsSort? current, AllModsColumn column) {
    final natural = startsDescending(column);
    if (current == null || current.column != column) return AllModsSort(column, descending: natural);
    if (current.descending == natural) return AllModsSort(column, descending: !natural);
    return null;
  }

  @override
  bool operator ==(Object other) => other is AllModsSort && other.column == column && other.descending == descending;

  @override
  int get hashCode => Object.hash(column, descending);
}

/// The column the user sorted the All mods table by, or null for its default order, [AllModsSort.byDefault].
final allModsSortProvider = StateProvider<AllModsSort?>((ref) => null);

/// How the All mods table groups its rows. By status is the Status column's sort.
enum AllModsGrouping { none, character }

final allModsGroupingProvider = StateProvider<AllModsGrouping>((ref) => AllModsGrouping.none);

/// The All mods table's folded groups, as `<grouping>/<group id>`, for the session. A folded group's rows count as
/// not shown, so the bulk actions leave them alone.
final allModsCollapsedProvider = StateProvider<Set<String>>((ref) => const {});

/// The mods ticked in the All mods table, by folder id. The bulk actions take only the ones the table is showing.
final allModsSelectionProvider = StateProvider<Set<String>>((ref) => const {});

/// Whether one of the selection bar's actions is running. The mods' switches and the bar are greyed out while it is
/// set. Here rather than on the page, which is disposed on a switch to the character view while the action runs on.
final allModsBulkRunningProvider = StateProvider<bool>((ref) => false);

/// The mod switch presses not yet done, which run one at a time in the order pressed. While any are, the selection
/// bar is greyed out; the switches stay live, so the one pressed keeps keyboard focus.
final libraryTogglesProvider = NotifierProvider<LibraryToggles, int>(LibraryToggles.new);

/// Runs switch presses in turn: under One at a time, two running together could leave two of a character's mods on.
/// The state is how many are waiting or running.
///
/// A press on a mod whose folder is being written ([modWritesInProgressProvider]) waits for that write, outside the
/// queue, so presses on other mods go ahead.
class LibraryToggles extends Notifier<int> {
  /// The last turn's end, or null when none is waiting or running.
  Future<void>? _last;

  @override
  int build() => 0;

  /// Runs [toggle], a press on [modId], once no write holds that mod and every press before it is done.
  Future<void> run(String modId, Future<void> Function() toggle) {
    state++;
    return _whenFree(modId, toggle).whenComplete(() => state--);
  }

  Future<void> _whenFree(String modId, Future<void> Function() toggle) async {
    while (true) {
      await _untilWritten(modId);
      // A write may have started while this press waited for its turn; it then waits for that one too.
      final ran = await _turn(() async {
        if (ref.read(modWritesInProgressProvider).contains(modId)) return false;
        await toggle();
        return true;
      });
      if (ran) return;
    }
  }

  Future<void> _untilWritten(String modId) {
    if (!ref.read(modWritesInProgressProvider).contains(modId)) return Future.value();
    final free = Completer<void>();
    late final ProviderSubscription<Set<String>> watching;
    watching = ref.listen(modWritesInProgressProvider, (_, writing) {
      if (writing.contains(modId) || free.isCompleted) return;
      free.complete();
      watching.close();
    });
    return free.future;
  }

  Future<T> _turn<T>(Future<T> Function() body) {
    final previous = _last;
    final done = previous == null ? Future.sync(body) : previous.then((_) => body());
    final settled = _last = done.then((_) {}, onError: (_) {});
    settled.then((_) {
      if (identical(_last, settled)) _last = null;
    });
    return done;
  }
}

/// When the last check of the whole library finished this session, or null before one has.
final libraryCheckedAtProvider = StateProvider<DateTime?>((ref) => null);

/// Which rows the character list shows.
enum CharacterListFilter { all, active, updates }

final characterListFilterProvider = StateProvider<CharacterListFilter>((ref) => CharacterListFilter.all);

/// Whether the character list hides the rows with no mods. Hydrated from `config.json` in `ApiService.initialize`,
/// written through `ApiService.setHideEmptyCharacters`.
final hideEmptyCharactersProvider = StateProvider<bool>((ref) => false);

/// Which of the character's mods the grid shows. One at a time, like the chips that set it.
///
/// [needsAttention] has no chip of its own unless something needs attention.
enum ModGridFilter { all, active, updates, favorites, needsAttention }

final modGridFilterProvider = StateProvider<ModGridFilter>((ref) => ModGridFilter.all);

/// The mod the details panel shows, by folder id. Null closes the panel.
final selectedModIdProvider = StateProvider<String?>((ref) => null);

/// The tabs of a mod's page in the Library.
enum ModPageTab { overview, keys, history, note }

/// The mod whose page the Library shows in place of the character view, and the tab it opened on.
///
/// State rather than a route, as the marketplace's open mod is: the Library is one of the shell's pages, and a page
/// left for another is disposed while this survives, so coming back shows the same mod.
@immutable
class ModPageRequest {
  const ModPageRequest(this.modId, {this.tab = ModPageTab.overview, String? pageKey}) : pageKey = pageKey ?? modId;

  final String modId;
  final ModPageTab tab;

  /// What the page is keyed by for as long as it is open, fixed when it opens: the folder's uid, or its id when it
  /// has none yet. A rename carries it over, and a uid the first snapshot assigns later doesn't change it, so neither
  /// sends the page back to its first tab or fetches again.
  final String pageKey;
}

/// Null shows the character view.
final openModPageProvider = StateProvider<ModPageRequest?>((ref) => null);

/// The user's note on each mod, by folder id. Hydrated in `ApiService.initialize`, written through
/// `ApiService.setModNote` (`docs/library-screen.md` §11).
final modNotesProvider = StateProvider<Map<String, String>>((ref) => const {});

/// Whether turning one of a group's mods on turns the others off, for the groups the user has switched. Hydrated in
/// `ApiService.initialize`, written through `ApiService.setOneAtATime`. Read through [isOneAtATime].
final oneAtATimeProvider = StateProvider<Map<String, bool>>((ref) => const {});

/// Whether [groupId] has a One at a time switch at all: unassigned mods belong to no one character, so there are no
/// "others" to turn off (`docs/library-screen.md` §10).
bool hasOneAtATime(String groupId) => groupId != unknownCharacterId;

/// The switch's state for [groupId]: the user's choice, or the default, on for agents and off for categories.
bool isOneAtATime(Map<String, bool> choices, String groupId) {
  if (!hasOneAtATime(groupId)) return false;
  return choices[groupId] ?? !isBuiltInCategory(groupId);
}

/// The mods turning [mod] on turns off: with its group's One at a time on, every other mod of the group that is on.
/// Empty when [mod] is on already, since the press turns it off.
///
/// A mod of the group in [beingWritten] is included even when the library reads it off: its write turned it off and
/// would turn it back on when it ends, so it must be marked to stay off (`turnOffDuringWrite`).
Set<String> modsToSwitchOff(
  List<ModInfo> library,
  ModInfo mod,
  Map<String, bool> oneAtATime, {
  Set<String> beingWritten = const {},
}) {
  final group = libraryGroupOf(mod.characterId);
  if (mod.isActive || !isOneAtATime(oneAtATime, group)) return const {};
  return {
    for (final other in library)
      if ((other.isActive || beingWritten.contains(other.id)) &&
          other.id != mod.id &&
          libraryGroupOf(other.characterId) == group)
        other.id,
  };
}

/// The user's theme choice: light, dark, or whatever the desktop is set to.
///
/// Hydrated from `config.json`'s `theme` key in `ApiService.initialize` and
/// written through `ApiService.setThemeMode`, like the preferences below.
/// **Defaults to [ThemeMode.system]**, so until somebody says otherwise the app
/// is the colour the rest of their desktop already is.
final themeModeProvider = StateProvider<ThemeMode>((ref) => ThemeMode.system);

/// The accent colour: what marks a mod as on, the primary button, links.
///
/// Hydrated from `config.json`'s `accent` key in `ApiService.initialize` and written through `ApiService.setAccent`.
final accentProvider = StateProvider<AccentChoice>((ref) => AccentChoice.violet);

/// What the desktop itself is set to, kept current by `MyApp`'s observer.
///
/// Only [ThemeMode.system] consults it. A provider rather than a direct
/// `PlatformDispatcher` read at each call site so a test can state the
/// desktop's answer, and so one observer serves the whole app.
final platformBrightnessProvider = StateProvider<Brightness>(
  (ref) => PlatformDispatcher.instance.platformBrightness,
);

/// Whether the app draws dark **right now** — the choice resolved against the
/// desktop.
///
/// The single answer to that question: every screen that paints its own colours
/// reads this, and `MaterialApp`'s `ThemeData` is built from it as well, so the
/// hand-rolled palettes and the Material one cannot disagree.
final isDarkModeProvider = Provider<bool>((ref) {
  return switch (ref.watch(themeModeProvider)) {
    ThemeMode.light => false,
    ThemeMode.dark => true,
    ThemeMode.system =>
      ref.watch(platformBrightnessProvider) == Brightness.dark,
  };
});

// Settings providers
final modsPathProvider = StateProvider<String>((ref) => '');

/// The configured ZZMI folder, the one holding `d3dx.ini`. Hydrated in `ApiService.initialize` and updated when
/// Settings saves the paths.
final zzmiPathProvider = StateProvider<String>((ref) => '');

/// ZZMI's folder of links, `Mods` under [zzmiPathProvider] in whatever case it is spelled on disk. Null with no ZZMI
/// folder set.
final linksFolderProvider = Provider<String?>((ref) {
  final zzmi = ref.watch(zzmiPathProvider);
  return zzmi.isEmpty ? null : linksFolderIn(zzmi);
});

/// Whether [zzmiPathProvider] names a ZZMI install: it holds `d3dx.ini`.
final zzmiFoundProvider = FutureProvider<bool>((ref) async {
  final path = ref.watch(zzmiPathProvider);
  if (path.isEmpty) return false;
  return File(p.join(path, 'd3dx.ini')).exists();
});

/// The file the sidebar's Launch game button starts when one is chosen; empty means the XXMI Launcher beside the
/// ZZMI folder ([xxmiLauncherProvider]). See `docs/launch-game.md`.
final launchTargetProvider = StateProvider<String>((ref) => '');

/// The XXMI Launcher beside the configured ZZMI folder, or null when there is none there.
final xxmiLauncherProvider = FutureProvider<String?>((ref) async {
  final zzmi = ref.watch(zzmiPathProvider);
  if (zzmi.isEmpty) return null;
  final exe = xxmiLauncherBeside(zzmi);
  return await File(exe).exists() ? exe : null;
});

/// What Launch game passes the launcher, as typed.
final launchArgumentsProvider = StateProvider<String>((ref) => AppConstants.defaultLaunchArguments);

/// Linux only: the Wine or Proton that runs the launcher, empty for `wine` from PATH.
final wineRunnerProvider = StateProvider<String>((ref) => '');

/// Linux only: whether a Proton runner starts through umu-launcher rather than directly. On by default.
final wineUseUmuProvider = StateProvider<bool>((ref) => true);

/// The Wine and Proton builds on this machine, for Settings › Wine or Proton. Looked for again each time Settings
/// opens, so a build installed meanwhile shows up.
final wineRunnersProvider = FutureProvider.autoDispose<List<WineRunner>>(
  (ref) => PlatformServiceFactory.getInstance().findWineRunners(),
);

/// Linux only: the Wine prefix the launcher runs in, empty for the runner's own default.
final winePrefixProvider = StateProvider<String>((ref) => '');

/// How the folder in [winePrefixProvider] is laid out, for the warnings under it in Settings.
enum WinePrefixLayout {
  /// No prefix chosen: the runner's own default.
  unset,

  /// `drive_c` both at the top and under `pfx`, because `pfx` links back to the folder, as umu makes it in every
  /// prefix it runs in, Heroic's for Proton games included. Every runner finds the same prefix here.
  compatData,

  /// `drive_c` only under a real `pfx/`, as Steam makes it, and Heroic with UMU off. Proton finds the prefix there,
  /// but plain Wine would build a new prefix at the top of the folder.
  protonOnly,

  /// `drive_c` and no `pfx`, as plain Wine and Lutris make it, and Heroic for a Wine game. Proton started directly
  /// would build a new prefix in a `pfx/` inside it.
  plain,

  /// Neither: not a prefix.
  missing,
}

/// Checked again each time Settings opens, so a folder a runner has filled since loses its warning.
final winePrefixLayoutProvider = FutureProvider.autoDispose<WinePrefixLayout>((ref) async {
  final prefix = ref.watch(winePrefixProvider);
  if (prefix.isEmpty) return WinePrefixLayout.unset;
  final top = await Directory(p.join(prefix, 'drive_c')).exists();
  if (await Directory(p.join(prefix, 'pfx', 'drive_c')).exists()) {
    return top ? WinePrefixLayout.compatData : WinePrefixLayout.protonOnly;
  }
  return top ? WinePrefixLayout.plain : WinePrefixLayout.missing;
});
final autoRefreshProvider = StateProvider<bool>((ref) => false);

/// How the marketplace presents mods GameBanana flags as adult.
///
/// App-wide (hence here rather than in `marketplace_providers.dart`) and
/// hydrated from `config.json` in `ApiService.initialize`. Defaults to
/// [ContentFilterMode.blur], which honours GameBanana's own `_sInitialVisibility`
/// hint — the API filters nothing itself, so this is the only filter there is.
final contentFilterProvider =
    StateProvider<ContentFilterMode>((ref) => ContentFilterMode.blur);

/// The marketplace browse sort the user last chose.
///
/// Here rather than in `marketplace_providers.dart` for the same reason as the
/// content filter: it is a **persisted preference**, hydrated from `config.json` in
/// `ApiService.initialize`, not part of a browsing session. `MarketplaceQuery` reads
/// it for its starting sort, so the two are distinct on purpose — this is "what the
/// user prefers", the query's `sort` is "what is applied right now".
final marketplaceSortProvider =
    StateProvider<GbModSort>((ref) => kDefaultMarketplaceSort);

/// Whether the whole-library update check runs on its own at startup.
///
/// Hydrated from `config.json` in `ApiService.initialize` and written through
/// `ApiService.setUpdateCheckOnLaunch`, like the two preferences above.
/// **Defaults to false**: the standing rule is that a check never runs without an
/// explicit press, and this is the one opt-in out of it.
///
/// It governs *checking*. Applying an update is never automated — see
/// `docs/applying-updates.md` §7.
final updateCheckOnLaunchProvider = StateProvider<bool>((ref) => false);

/// Whether each run writes a log file.
///
/// **Defaults to true**, unlike the setting above, and for the opposite reason:
/// a log reaches nothing and costs kilobytes, and is worthless if it happened to
/// be switched off on the run that broke. This provider is only what the
/// *Settings switch* reads — the actual sink is decided in `main()` by reading
/// `config.json` directly, long before `SharedPreferences` exists.
final fileLoggingProvider = StateProvider<bool>((ref) => true);

/// The sort a fresh install starts on: newest submissions first.
///
/// Worth knowing what this trades away — `Generic_Newest` orders by
/// `_tsDateAdded`, so a mod published long ago and updated an hour ago sorts to its
/// *original* date and sinks far down the list. "Recently updated"
/// (`GbModSort.latestModified`) is the sort for that, and GameBanana's own site
/// surfaces updates too, so the two views differ. This only decides the *first*
/// run, since the choice is persisted from then on.
const GbModSort kDefaultMarketplaceSort = GbModSort.newest;

// Locale provider for localization
final localeProvider = StateProvider<Locale>((ref) => const Locale('en'));

/// Sort options for the mods list.
enum ModSort { added, nameAsc, nameDesc }

final modSortProvider = StateProvider<ModSort>((ref) => ModSort.added);

/// How many mods in the current view would survive the needs-attention filter.
///
/// Shown on its chip so pressing it is a decision rather than a guess, and the
/// chip hides at zero. Counted over the same list [visibleModsProvider] starts
/// from, so it can't claim mods the view doesn't contain.
final modsNeedingAttentionCountProvider = Provider<int>((ref) {
  return ref
      .watch(currentCharacterSkinsProvider)
      .where(modInfoNeedsAttention)
      .length;
});

/// The current view's mods after the grid's filter and sort.
final visibleModsProvider = Provider<List<ModInfo>>((ref) {
  final sort = ref.watch(modSortProvider);

  Iterable<ModInfo> result = ref.watch(currentCharacterSkinsProvider);

  switch (ref.watch(modGridFilterProvider)) {
    case ModGridFilter.all:
      break;
    case ModGridFilter.active:
      result = result.where((m) => m.isActive);
    case ModGridFilter.updates:
      // Ignored updates fall out here without a second rule: `hasUpdate` is
      // already false once a dismissal covers the finding.
      final checks = ref.watch(modUpdateChecksProvider);
      result = result.where((m) => checks[m.id]?.hasUpdate ?? false);
    case ModGridFilter.favorites:
      result = result.where((m) => m.isFavorite);
    case ModGridFilter.needsAttention:
      result = result.where(modInfoNeedsAttention);
  }

  var list = result.toList();
  switch (sort) {
    case ModSort.added:
      list = sortedByInstallDate(list);
      break;
    case ModSort.nameAsc:
      list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      break;
    case ModSort.nameDesc:
      list.sort((a, b) => b.name.toLowerCase().compareTo(a.name.toLowerCase()));
      break;
  }
  return list;
});

/// Whether an update check the user started, of the whole library or of the ticked mods, is running. Read by every
/// control that would start another, since two passes would race their results into one map. Set by
/// `LibraryActionsHost`.
final libraryCheckRunningProvider = StateProvider<bool>((ref) => false);

/// The mods the running check has reached so far, by folder id: their pages are in hand and their verdicts are on
/// the way. Empty while no check runs. The Updates page's coverage strip fills from it.
final libraryCheckProgressProvider = StateProvider<Set<String>>((ref) => const {});

// ── Update checks ───────────────────────────────────────────────────────────

/// What the last update check concluded, per mod folder id.
///
/// **Session-scoped, and deliberately not persisted.** No check ever runs
/// without an explicit press — no network on launch — so a verdict restored
/// from disk would be an assertion about a mod page nobody has looked at since,
/// on a screen whose whole job is to say what is true now. Emptying on restart
/// costs one press and cannot be stale.
///
/// Keyed by folder id, which is also the rename key: renaming a mod orphans its
/// verdict until the next check. That is the correct way round — the alternative
/// is a verdict following a folder whose identity the rename may have been part
/// of changing.
final modUpdateChecksProvider =
    StateProvider<Map<String, UpdateCheck>>((ref) => const {});

/// The mod pages the whole-library checks fetched, by remote mod id. A check of ticked mods only refreshes the ones
/// here; the rest of what it fetches goes to [fetchedModPagesProvider].
///
/// Session-scoped for exactly the reasons [modUpdateChecksProvider] is, and
/// kept for one reason: **the resolution screen has to be re-openable.** Built
/// only from the outcome of a press, it could be shown once and never again.
/// Holding the records makes reopening free, and a screen opened with none
/// simply runs the check it would have run anyway.
///
/// Never persisted, so a record can only ever be as old as the current session
/// — a resolution question asked against a mod page nobody has looked at since
/// last week is the same mistake as a restored verdict.
final modUpdateRecordsProvider =
    StateProvider<Map<int, GbMod>>((ref) => const {});

/// Mod pages fetched this session **outside a whole-library check**: by an install, by a check of ticked mods, and
/// by the dialogs that look a mod up.
///
/// Kept apart from [modUpdateRecordsProvider] because a record there also means "the check reached this mod", which
/// the resolution screen counts on: a page an install fetched would have it report every other mod as unreached.
final fetchedModPagesProvider = StateProvider<Map<int, GbMod>>((ref) => const {});

/// Every mod page in hand this session, for the surfaces that only display one: the card's file line and the
/// details panel. A mod installed a moment ago names its file, author and upload date without a check.
final knownModPagesProvider = Provider<Map<int, GbMod>>((ref) {
  return {...ref.watch(fetchedModPagesProvider), ...ref.watch(modUpdateRecordsProvider)};
});

/// Keeps [pages] in [fetchedModPagesProvider] for this session.
///
/// A page the whole-library check already holds is refreshed there too: the check's records win over fetched pages
/// on display, so a newer page fetched since would otherwise show the older one's file and date. No record is added
/// for a page the check didn't hold, since a record means the check reached that mod.
/// In both maps a held page is kept over an older one: the whole check bypasses the response cache and a mod's page
/// does not, so a page fetched later can still be the older read.
void keepModPages(WidgetRef ref, Map<int, GbMod> pages) {
  if (pages.isEmpty) return;
  bool notOlder(Map<int, GbMod> held, MapEntry<int, GbMod> page) {
    final kept = held[page.key];
    return kept == null || !_olderModPage(page.value, kept);
  }
  final fetched = ref.read(fetchedModPagesProvider.notifier);
  fetched.state = {
    ...fetched.state,
    for (final e in pages.entries)
      if (notOlder(fetched.state, e)) e.key: e.value,
  };
  final records = ref.read(modUpdateRecordsProvider.notifier);
  final held = {
    for (final e in pages.entries)
      if (records.state.containsKey(e.key) && notOlder(records.state, e)) e.key: e.value,
  };
  if (held.isNotEmpty) records.state = {...records.state, ...held};
}

/// Whether [page] is an older read of a mod page than [than]: its newest file or its last update is earlier. A date
/// either one lacks decides nothing.
bool _olderModPage(GbMod page, GbMod than) {
  bool earlier(DateTime? a, DateTime? b) => a != null && b != null && a.isBefore(b);
  return earlier(_newestFileDate(page), _newestFileDate(than)) || earlier(page.dateUpdated, than.dateUpdated);
}

DateTime? _newestFileDate(GbMod page) {
  DateTime? newest;
  for (final file in page.files ?? const []) {
    final added = file.dateAdded;
    if (added != null && (newest == null || added.isAfter(newest))) newest = added;
  }
  return newest;
}

/// Takes back the ignored update on [mod]'s download from mod page [subject], and rescans. Returns false when the
/// sidecar could not be written.
///
/// The session's verdict is re-folded too (`refoldDismissal`, as the update dialog's undo does): the badge reads it,
/// and a rescan alone leaves it saying "ignored" until the next check. A single verdict about another page is left
/// alone. [writer] is the caller's seam, the library service's write by default.
Future<bool> stopIgnoringUpdate(
  ProviderContainer container, {
  required ModInfo mod,
  required int subject,
  OriginWriter? writer,
}) async {
  final write = writer ?? originWriterFor(container.read(modManagerServiceProvider.future));
  final result = await whileWritingMod(
    container,
    mod.id,
    () => write(mod.id, (origin) => origin?.withDismissal(subject: subject, until: null)),
  );
  if (!result.ok) return false;
  final checks = container.read(modUpdateChecksProvider.notifier);
  if (checks.state[mod.id] case final check? when check.layers.length > 1 || check.subjectModId == subject) {
    checks.state = {...checks.state, mod.id: refoldDismissal(check, subject, false)};
  }
  await container.read(libraryProvider.notifier).rescan();
  return true;
}

/// Ignores the update [check] found on [mod], as the update dialog's Ignore does, and rescans. Returns false when
/// the sidecar could not be written, or the check names nothing to ignore.
///
/// The dismissal is written on the layer whose page has the update, up to the newest file the check reported
/// (`UpdateCheck.dismissableUpTo`), so anything uploaded after speaks up again.
Future<bool> ignoreUpdate(
  ProviderContainer container, {
  required ModInfo mod,
  required UpdateCheck check,
  OriginWriter? writer,
}) async {
  final subject = check.subjectModId;
  final until = check.dismissableUpTo;
  if (subject == null || until == null) return false;
  final write = writer ?? originWriterFor(container.read(modManagerServiceProvider.future));
  final result = await whileWritingMod(
    container,
    mod.id,
    () => write(mod.id, (origin) => origin?.withDismissal(subject: subject, until: until)),
  );
  if (!result.ok) return false;
  final checks = container.read(modUpdateChecksProvider.notifier);
  if (checks.state[mod.id] case final held?) {
    checks.state = {...checks.state, mod.id: refoldDismissal(held, subject, true)};
  }
  await container.read(libraryProvider.notifier).rescan();
  return true;
}

/// Writes the titles of [pages] onto the sidecars of the library's mods whose downloads they name
/// (`ModDownload.name`), and rescans when one changed. Run after a check, which fetches every tracked mod's page.
///
/// A failure is logged and goes no further: the name is a display copy, and the next check tries again. [writer] is
/// the caller's seam, the library service's write by default.
Future<void> rememberDownloadNamesFrom(WidgetRef ref, Map<int, GbMod> pages, {OriginWriter? writer}) async {
  if (pages.isEmpty) return;
  // A mod whose folder is being written is left out, with nothing said: the next page fetched names it.
  final writing = ref.read(modWritesInProgressProvider);
  final mods = ref.read(modsProvider).where((m) => !writing.contains(m.id));
  final library = ref.read(libraryProvider.notifier);
  final write = writer ?? originWriterFor(ref.read(modManagerServiceProvider.future));
  try {
    final wrote = await rememberDownloadNames(mods: mods, pages: pages, write: write);
    if (wrote) await library.rescan();
  } catch (e) {
    _log.warning('download names were not saved', error: e);
  }
}

/// What the resolution screen would show for the records currently in hand.
///
/// Derived rather than stored, so it tracks the library as a rescan changes it:
/// resolving a mod through the per-mod dialog removes its row here without the
/// records being re-fetched.
///
/// Planned with no records in hand as well, because the untracked list needs no mod page.
/// Its `unreachable` then counts every tracked mod, which is "not looked up yet" rather than a failure.
final bulkResolutionPlanProvider = Provider<BulkResolutionPlan>((ref) {
  return planBulkResolution(
    mods: ref.watch(modsProvider),
    records: ref.watch(modUpdateRecordsProvider),
  );
});

/// What a "check all" would look up.
///
/// Built from the **whole library** ([modsProvider]) rather than from what the
/// All mods table shows, and that is a deliberate departure from where "mark as
/// current" gets its list. The rule those two follow is the same one: *a bulk
/// control must act on the set the user can see*. What differs is the stake.
/// "Assume current" **rewrites sidecars**, so acting past the rows on screen is
/// a silent change to mods the user never enumerated. A check writes nothing at all; its only effect is badges, and those are drawn
/// across the whole library — so scoping it to one character tab would leave
/// every other tab looking checked-and-clean when it was never asked about.
final bulkUpdateCheckPlanProvider = Provider<BulkUpdateCheckPlan>((ref) {
  return planBulkUpdateCheck(ref.watch(modsProvider));
});

/// How many mods **in the current view** the last check flagged.
///
/// Scoped exactly like [modsNeedingAttentionCountProvider], and for the same
/// reason: it is the number on a control that *filters*, so it has to describe
/// what pressing it would leave on screen. A library-wide number on a character
/// tab would promise mods the filter cannot reach.
///
/// Note the asymmetry with [bulkUpdateCheckPlanProvider], which is deliberate:
/// the **check** covers the whole library because its badges are drawn on every
/// tab, while the **filter** covers this tab because that is all it can narrow.
///
/// Counted over the mods rather than over the results map so a mod deleted since
/// the check can't keep contributing to the number, and ignored updates fall out
/// for free because [UpdateCheck.hasUpdate] is already false for them.
final modsWithUpdatesCountProvider = Provider<int>((ref) {
  final checks = ref.watch(modUpdateChecksProvider);
  if (checks.isEmpty) return 0;
  return ref
      .watch(currentCharacterSkinsProvider)
      .where((mod) => checks[mod.id]?.hasUpdate ?? false)
      .length;
});

/// How many mods **anywhere in the library** have an update to show.
///
/// Deliberately library-wide where [modsWithUpdatesCountProvider] is
/// view-scoped, and the two are not interchangeable. A control that *filters*
/// wants the view count, because that is what pressing it would leave on
/// screen; anything **reporting what a check found** wants this one, or the
/// same sentence means "in your library" or "on this character tab" depending
/// on where the user happened to be standing.
final libraryUpdateCountProvider = Provider<int>((ref) {
  final checks = ref.watch(modUpdateChecksProvider);
  if (checks.isEmpty) return 0;
  return ref
      .watch(modsProvider)
      .where((mod) => checks[mod.id]?.hasUpdate ?? false)
      .length;
});

/// Whether any of them do. Drives the Updates filters switching *themselves* off
/// once there is nothing left to show — on the view-scoped count that would fire
/// merely because the user picked a character with no updates of its own,
/// giving a filter that vanishes when you look somewhere else.
final libraryHasUpdatesProvider = Provider<bool>((ref) {
  return ref.watch(libraryUpdateCountProvider) > 0;
});

/// Pre-update snapshots, in `<appData>/backups`.
///
/// One instance so the retention policy is stated once. Nothing here reads
/// config, so it needs no async initialisation — the path comes from
/// [PathHelper], the same way the downloads folder does.
final snapshotServiceProvider = Provider<SnapshotService>(
  (ref) => SnapshotService(),
);

/// Which mods have a snapshot to roll back to, **by uid**.
///
/// A single directory listing of `<appData>/backups` — the folder names *are*
/// the answer, so this reads no manifests and walks no files. It exists so the
/// context menu can offer "restore a previous version" only where there is one,
/// rather than showing a permanently-present entry that usually opens an empty
/// dialog.
///
/// Uids rather than mod names, because that is what the store is keyed by; the
/// caller compares against `ModInfo.uid`, which the scan already carries. A mod
/// with no uid is absent from this by construction, which is correct — every
/// mod is given one at install or on the scan, so the only folder without one
/// is one that cannot be written, and nothing could have been filed under an
/// identity that never reached disk.
///
/// Invalidated by whatever writes a snapshot; there is no watcher, because the
/// only things that create one are inside this app.
final modBackupsProvider = FutureProvider<Set<String>>((ref) async {
  return ref.read(snapshotServiceProvider).uidsWithSnapshots();
});

/// The mods, by folder id, whose folders an update, a reinstall, a patch installed or taken out, or a restore is
/// changing right now. The History tab of the mod's page holds its buttons while its mod is here: nothing else on
/// screen shows the write is running, and a second write into the same folder would snapshot it half done. A switch
/// press on the mod waits for it ([LibraryToggles]).
final modWritesInProgressProvider = StateProvider<Set<String>>((ref) => const {});

/// How many writes are running on each mod in [modWritesInProgressProvider], so a mod stays there until its last one
/// ends.
final _modWriteCountsProvider = StateProvider<Map<String, int>>((ref) => const {});

/// Runs [write] with [modId] in [modWritesInProgressProvider].
Future<T> whileWritingMod<T>(ProviderContainer container, String modId, Future<T> Function() write) async {
  final counts = container.read(_modWriteCountsProvider.notifier);
  final busy = container.read(modWritesInProgressProvider.notifier);
  void add(int delta) {
    final count = (counts.state[modId] ?? 0) + delta;
    counts.state = {...counts.state, modId: count}..removeWhere((_, n) => n <= 0);
    busy.state = counts.state.keys.toSet();
  }

  add(1);
  try {
    return await write();
  } finally {
    add(-1);
    if (!busy.state.contains(modId)) {
      final marked = container.read(_turnedOffDuringWriteProvider.notifier);
      if (marked.state.contains(modId)) marked.state = {...marked.state}..remove(modId);
    }
  }
}

/// The mods One at a time turned off while their folders were being written. The write leaves such a mod off when it
/// ends rather than turning it back on, which would also place its shader files again (`docs/applying-updates.md`).
final _turnedOffDuringWriteProvider = StateProvider<Set<String>>((ref) => const {});

/// Asked as One at a time turns off [modId] to turn another of its character's mods on. When its folder is being
/// written, marks it so the write leaves it off, and answers true.
bool turnOffDuringWrite(ProviderContainer container, String modId) {
  if (!container.read(modWritesInProgressProvider).contains(modId)) return false;
  final marked = container.read(_turnedOffDuringWriteProvider.notifier);
  marked.state = {...marked.state, modId};
  return true;
}

/// Whether [modId] was turned off during its running write, so the write must not turn it back on.
bool leftOffAfterWrite(ProviderContainer container, String modId) =>
    container.read(_turnedOffDuringWriteProvider).contains(modId);

/// One snapshot and the origin block its copy of the sidecar holds, which says the file the mod was at then. The
/// origin is null when that sidecar is missing or unreadable.
typedef SnapshotEntry = ({ModSnapshot snapshot, ModOrigin? origin});

/// A mod's snapshots by uid, newest first, each with the origin it was taken at: the History tab's installed files.
///
/// Rebuilt whenever [modBackupsProvider] is invalidated, which every write that takes or deletes a snapshot does.
final modSnapshotsProvider = FutureProvider.autoDispose.family<List<SnapshotEntry>, String>((ref, uid) async {
  ref.watch(modBackupsProvider);
  final snapshots = await ref.read(snapshotServiceProvider).list(uid);
  final sidecars = ModMetadataService();
  return [
    for (final snapshot in snapshots)
      (
        snapshot: snapshot,
        origin: (await sidecars.read(p.join(snapshot.directory.path, 'files')))?.origin,
      ),
  ];
});
