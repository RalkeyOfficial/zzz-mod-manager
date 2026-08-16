import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/character_info.dart';
import '../services/api_service.dart';
import '../services/bulk_resolution.dart';
import '../services/download/download_service.dart';
import '../models/gamebanana/gb_enums.dart';
import '../models/gamebanana/gb_mod.dart';
import '../services/gamebanana/content_filter.dart';
import '../services/gamebanana/gamebanana_client.dart';
import '../services/backup/snapshot_service.dart';
import '../services/bulk_assume_current.dart';
import '../services/bulk_update_check.dart';
import '../services/installed_mods_index.dart';
import '../services/mod_manager_service.dart';
import '../services/origin_status.dart';
import '../services/update_check.dart';

// The marketplace's own browsing state (query, results, categories, open mod)
// lives in `marketplace_providers.dart` — one screen's session rather than
// app-wide state, and keeping it there is what stops this registry sprawling.
//
// The notification stack lives in `notifications.dart` for the same reason: it
// is one subsystem with its own vocabulary (severity, pinning, handles), and
// call sites reach it through `context.notify` rather than through a provider.

// API Service Provider
final modManagerServiceProvider = FutureProvider<ModManagerService>((ref) async {
  return await ApiService.getModManagerService();
});

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

/// The mod-archive downloader.
///
/// Shared rather than per-screen so the resume bookkeeping in
/// `<appData>/downloads` has a single owner, and so a download survives the
/// user navigating away from the screen that started it.
final downloadServiceProvider = Provider<DownloadService>((ref) {
  final service = DownloadService();
  ref.onDispose(service.close);
  return service;
});

/// What the local library already has, keyed by remote identity.
///
/// Its own snapshot rather than a view over [charactersProvider], for a reason
/// that is structural: the three tabs are keyed children of an `AnimatedSwitcher`
/// with no keep-alive, so `ModsScreen` is **disposed** while the marketplace is
/// open and nothing is refreshing that list. Deriving badges from it would mean a
/// mod installed from the marketplace stayed un-badged until the user visited the
/// Mods tab — the one moment they cannot see the badge.
///
/// So this reloads instead, and the marketplace invalidates it when it opens and
/// after every install. That costs one library scan per marketplace visit, which
/// is cheap enough not to design around: measured against a mirror of a real
/// 23-mod / 748-file library, the metadata pass over its sidecars is **4 ms warm,
/// 12 ms cold**, and building the index from the result is **under 1 ms**. It is
/// the same work the Mods tab's own scan already does.
///
/// Read it as `valueOrNull ?? InstalledModsIndex.empty`: while it loads, "nothing
/// is known to be installed" renders no badge, which is the right way to be wrong.
final installedModsIndexProvider =
    FutureProvider<InstalledModsIndex>((ref) async {
  return InstalledModsIndex.fromMods(await ApiService.getMods());
});

// Zoom scale provider
final zoomScaleProvider = StateProvider<double>((ref) => 1.0);

// Tab index provider
final tabIndexProvider = StateProvider<int>((ref) => 0);

// Characters list
final charactersProvider = StateProvider<List<CharacterInfo>>((ref) => []);

// Selected character index
final selectedCharacterIndexProvider = StateProvider<int>((ref) => 0);

/// Every mod in the library, once each, regardless of which character group it
/// is filed under.
///
/// Derived rather than stored. It was a `StateProvider` that nothing ever wrote
/// to and nothing ever read — a declaration that *looked* like the library list
/// while the real one lived inside [charactersProvider]'s groups, which is
/// exactly the kind of thing someone reaches for and gets an empty list from.
///
/// Deduplicated by folder id because the grouping is not a partition: a mod
/// appears under its character *and* under the "all" group. Anything asking a
/// question about the whole library — the bulk update check, most obviously —
/// wants this rather than [currentCharacterSkinsProvider], which is one tab's
/// worth.
final modsProvider = Provider<List<ModInfo>>((ref) {
  final seen = <String>{};
  final all = <ModInfo>[];
  for (final character in ref.watch(charactersProvider)) {
    for (final mod in character.skins) {
      if (seen.add(mod.id)) all.add(mod);
    }
  }
  return all;
});

// Search query provider
final searchQueryProvider = StateProvider<String>((ref) => '');

// Filtered characters based on search - optimized with select
final filteredCharactersProvider = Provider<List<CharacterInfo>>((ref) {
  final characters = ref.watch(charactersProvider);
  final query = ref.watch(searchQueryProvider);

  if (query.isEmpty) {
    return characters;
  }

  final lowerQuery = query.toLowerCase();
  return characters.where((character) {
    return character.name.toLowerCase().contains(lowerQuery) ||
        character.id.toLowerCase().contains(lowerQuery);
  }).toList();
});

// Skins for selected character - optimized
final currentCharacterSkinsProvider = Provider<List<ModInfo>>((ref) {
  final characters = ref.watch(charactersProvider);
  final selectedIndex = ref.watch(selectedCharacterIndexProvider);

  if (characters.isEmpty || selectedIndex < 0 || selectedIndex >= characters.length) {
    return const [];
  }

  return characters[selectedIndex].skins;
}); // Theme mode provider (dark/light)
final isDarkModeProvider = StateProvider<bool>((ref) => true);

// Settings providers
final modsPathProvider = StateProvider<String>((ref) => '');
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

/// The sort a fresh install starts on: newest submissions first.
///
/// Worth knowing what this trades away — `Generic_Newest` orders by
/// `_tsDateAdded`, so a mod published long ago and updated an hour ago sorts to its
/// *original* date and sinks far down the list. "Recently updated"
/// (`GbModSort.latestModified`) is the sort for that, and GameBanana's own site
/// surfaces updates too, so the two views differ. This only decides the *first*
/// run, since the choice is persisted from then on.
const GbModSort kDefaultMarketplaceSort = GbModSort.newest;

// View mode: grid or carousel
final isGridViewProvider = StateProvider<bool>((ref) => true);

// Locale provider for localization
final localeProvider = StateProvider<Locale>((ref) => const Locale('en'));

// Activation mode: single (один скін) або multi (кілька скінів)
enum ActivationMode { single, multi }

final activationModeProvider = StateProvider<ActivationMode>((ref) => ActivationMode.single);

// Sidebar collapsed state
final sidebarCollapsedProvider = StateProvider<bool>((ref) => false);

// Auto F10 reload toggle (green = enabled, red = disabled)
final autoF10ReloadProvider = StateProvider<bool>((ref) => false);

// ── Mods toolbar: search / sort / tag filter / favorites ────────────────────
// Held here (not as ad-hoc widget state) so the toolbar and the mods grid each
// rebuild only on the slice they watch, instead of rebuilding the whole screen.

/// Sort options for the mods list.
enum ModSort { added, nameAsc, nameDesc }

final modSortProvider = StateProvider<ModSort>((ref) => ModSort.added);
final modSearchQueryProvider = StateProvider<String>((ref) => '');
final modTagFiltersProvider = StateProvider<Set<String>>((ref) => <String>{});
// false = match ANY selected tag, true = match ALL.
final modTagMatchAllProvider = StateProvider<bool>((ref) => false);
final modFavoritesOnlyProvider = StateProvider<bool>((ref) => false);

/// Show only mods whose origin isn't fully known — the "needs attention" filter.
///
/// A status dot on a card is *spatial*: to act on 80 mods you first have to be
/// able to enumerate them. This is that, and it deliberately covers both
/// non-empty states of the slot rather than only the amber one — see
/// [modNeedsAttention] for why the badge and the filter answer different
/// questions.
final modNeedsAttentionOnlyProvider = StateProvider<bool>((ref) => false);

/// Whether any filter (search / tags / favorites / needs-attention) is
/// currently narrowing the list. Sort mode is not a filter.
final modFiltersActiveProvider = Provider<bool>((ref) {
  return ref.watch(modSearchQueryProvider).isNotEmpty ||
      ref.watch(modTagFiltersProvider).isNotEmpty ||
      ref.watch(modFavoritesOnlyProvider) ||
      ref.watch(modNeedsAttentionOnlyProvider) ||
      ref.watch(modUpdatesOnlyProvider);
});

/// Resets the mods search / tag / favorites / needs-attention filters (leaves
/// the sort mode).
void clearModFilters(WidgetRef ref) {
  ref.read(modSearchQueryProvider.notifier).state = '';
  ref.read(modTagFiltersProvider.notifier).state = <String>{};
  ref.read(modFavoritesOnlyProvider.notifier).state = false;
  ref.read(modNeedsAttentionOnlyProvider.notifier).state = false;
  ref.read(modUpdatesOnlyProvider.notifier).state = false;
}

/// How many mods in the current view would survive the needs-attention filter.
///
/// Shown on the toggle so pressing it is a decision rather than a guess: a zero
/// says "nothing here to resolve" without the user having to press and land on
/// an empty grid. Counted over the same list [visibleModsProvider] starts from,
/// so it can't claim mods the view doesn't contain.
final modsNeedingAttentionCountProvider = Provider<int>((ref) {
  return ref
      .watch(currentCharacterSkinsProvider)
      .where(modInfoNeedsAttention)
      .length;
});

/// Distinct tags present in the current view's mods (sorted), for the
/// tag-filter dropdown.
final availableModTagsProvider = Provider<List<String>>((ref) {
  final tags = <String>{};
  for (final m in ref.watch(currentCharacterSkinsProvider)) {
    tags.addAll(m.tags);
  }
  return tags.toList()
    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
});

/// The current view's mods after applying search, favorites, tag filters and
/// sort. Tag filters are intersected with the tags actually present in the view
/// so a tag selected elsewhere (e.g. before switching tabs) can't silently
/// empty the list.
final visibleModsProvider = Provider<List<ModInfo>>((ref) {
  final query = ref.watch(modSearchQueryProvider).toLowerCase();
  final favoritesOnly = ref.watch(modFavoritesOnlyProvider);
  final needsAttentionOnly = ref.watch(modNeedsAttentionOnlyProvider);
  final tagFilters = ref.watch(modTagFiltersProvider);
  final matchAll = ref.watch(modTagMatchAllProvider);
  final sort = ref.watch(modSortProvider);

  Iterable<ModInfo> result = ref.watch(currentCharacterSkinsProvider);

  if (query.isNotEmpty) {
    result = result.where((m) => m.name.toLowerCase().contains(query));
  }
  if (favoritesOnly) {
    result = result.where((m) => m.isFavorite);
  }
  if (needsAttentionOnly) {
    result = result.where(modInfoNeedsAttention);
  }
  if (ref.watch(modUpdatesOnlyProvider)) {
    // Ignored updates fall out here without a second rule: `hasUpdate` is
    // already false once a dismissal covers the finding.
    final checks = ref.watch(modUpdateChecksProvider);
    result = result.where((m) => checks[m.id]?.hasUpdate ?? false);
  }
  final activeTags = tagFilters.isEmpty
      ? const <String>{}
      : tagFilters.intersection(ref.watch(availableModTagsProvider).toSet());
  if (activeTags.isNotEmpty) {
    result = result.where((m) => matchAll
        ? activeTags.every(m.tags.contains)
        : m.tags.any(activeTags.contains));
  }

  final list = result.toList();
  switch (sort) {
    case ModSort.added:
      break; // keep scan/add order
    case ModSort.nameAsc:
      list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      break;
    case ModSort.nameDesc:
      list.sort((a, b) => b.name.toLowerCase().compareTo(a.name.toLowerCase()));
      break;
  }
  return list;
});

/// What the zero-network "assume current" bulk action would do to this view.
///
/// Built from [visibleModsProvider] — **the list the grid actually renders** —
/// and not from the wider list [modsNeedingAttentionCountProvider] counts. The
/// action rewrites every mod it covers, so the one property it cannot give up
/// is that its number describes what is on screen. Sourcing it from the
/// unfiltered view breaks that the moment two filters combine: search `ellen`
/// with the needs-attention filter on and the grid shows three mods while the
/// button offers to rewrite twelve.
///
/// The consequence to know: the button's count and the toolbar's `!` count are
/// then allowed to differ, because they answer different questions — the toggle
/// counts what the view *could* show, the button counts what it *is* showing.
/// They agree whenever the needs-attention filter is the only one active, which
/// is the case the button was designed around.
///
/// The eligible / untracked / undatable split is [planBulkAssumeCurrent]'s, and
/// the confirmation names all three.
final bulkAssumeCurrentPlanProvider = Provider<BulkAssumeCurrentPlan>((ref) {
  return planBulkAssumeCurrent(ref.watch(visibleModsProvider));
});

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

/// The mod pages the last check fetched, by remote mod id.
///
/// Session-scoped for exactly the reasons [modUpdateChecksProvider] is, and
/// kept for one reason: **the resolution screen has to be re-openable.** Built
/// only from the outcome of a press, it could be shown once and never again —
/// which is what the first version did, and the complaint that produced this
/// provider. Holding the records makes reopening free, and a screen opened with
/// none simply runs the check it would have run anyway.
///
/// Never persisted, so a record can only ever be as old as the current session
/// — a resolution question asked against a mod page nobody has looked at since
/// last week is the same mistake as a restored verdict.
final modUpdateRecordsProvider =
    StateProvider<Map<int, GbMod>>((ref) => const {});

/// What the resolution screen would show for the records currently in hand.
///
/// Derived rather than stored, so it tracks the library as a rescan changes it:
/// resolving a mod through the per-mod dialog removes its row here without the
/// records being re-fetched.
final bulkResolutionPlanProvider = Provider<BulkResolutionPlan>((ref) {
  final records = ref.watch(modUpdateRecordsProvider);
  if (records.isEmpty) return BulkResolutionPlan.empty;
  return planBulkResolution(mods: ref.watch(modsProvider), records: records);
});

/// What a "check all" would look up.
///
/// Built from the **whole library** ([modsProvider]) rather than from
/// [visibleModsProvider], and that is a deliberate departure from where
/// [bulkAssumeCurrentPlanProvider] gets its list. The rule those two follow is
/// the same one: *a bulk control must act on the set the user can see*. What
/// differs is the stake. "Assume current" **rewrites sidecars**, so acting past
/// the edge of the grid is a silent change to mods the user never enumerated. A
/// check writes nothing at all; its only effect is badges, and those are drawn
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
/// One control now does both, so the two numbers answer different halves of it —
/// see the toolbar button for how that reads.
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

/// Whether any of them do. Drives the update filter switching *itself* off once
/// there is nothing left to show — on the view-scoped count that would fire
/// merely because the user clicked a character tab with no updates of its own,
/// giving a filter that vanishes when you look somewhere else.
final libraryHasUpdatesProvider = Provider<bool>((ref) {
  return ref.watch(libraryUpdateCountProvider) > 0;
});

/// Show only mods the last check flagged.
///
/// No control of its own: the toolbar's update-check button carries it, acting
/// as a filter toggle once a check has found something and as the check action
/// before that. Session state like the results it reads, so it cannot outlive
/// them.
///
/// **Switches itself off when the library runs out of updates** — see the
/// toolbar, which owns that. Ignoring the last flagged mod otherwise leaves the
/// grid filtered to nothing, which is the same "the reward for pressing the
/// button is an empty grid" the bulk "assume current" action already avoids.
final modUpdatesOnlyProvider = StateProvider<bool>((ref) => false);

/// Pre-update snapshots, in `<appData>/backups`.
///
/// One instance so the retention policy is stated once. Nothing here reads
/// config, so it needs no async initialisation — the path comes from
/// [PathHelper], the same way the downloads folder does.
final snapshotServiceProvider = Provider<SnapshotService>(
  (ref) => SnapshotService(),
);

/// Which mods have a snapshot to roll back to.
///
/// A single directory listing of `<appData>/backups` — the folder names *are*
/// the answer, so this reads no manifests and walks no files. It exists so the
/// context menu can offer "restore a previous version" only where there is one,
/// rather than showing a permanently-present entry that usually opens an empty
/// dialog.
///
/// Invalidated by whatever writes a snapshot; there is no watcher, because the
/// only things that create one are inside this app.
final modBackupsProvider = FutureProvider<Set<String>>((ref) async {
  return ref.read(snapshotServiceProvider).modsWithSnapshots();
});
