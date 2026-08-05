import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/character_info.dart';
import '../services/api_service.dart';
import '../services/download/download_service.dart';
import '../services/gamebanana/content_filter.dart';
import '../services/gamebanana/gamebanana_client.dart';
import '../services/mod_manager_service.dart';

// The marketplace's own browsing state (query, results, categories, open mod)
// lives in `marketplace_providers.dart` — one screen's session rather than
// app-wide state, and keeping it there is what stops this registry sprawling.

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

// Zoom scale provider
final zoomScaleProvider = StateProvider<double>((ref) => 1.0);

// Tab index provider
final tabIndexProvider = StateProvider<int>((ref) => 0);

// Characters list
final charactersProvider = StateProvider<List<CharacterInfo>>((ref) => []);

// Selected character index
final selectedCharacterIndexProvider = StateProvider<int>((ref) => 0);

// Current mods list (all mods)
final modsProvider = StateProvider<List<ModInfo>>((ref) => []);

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

/// Whether any filter (search / tags / favorites) is currently narrowing the
/// list. Sort mode is not a filter.
final modFiltersActiveProvider = Provider<bool>((ref) {
  return ref.watch(modSearchQueryProvider).isNotEmpty ||
      ref.watch(modTagFiltersProvider).isNotEmpty ||
      ref.watch(modFavoritesOnlyProvider);
});

/// Resets the mods search / tag / favorites filters (leaves the sort mode).
void clearModFilters(WidgetRef ref) {
  ref.read(modSearchQueryProvider.notifier).state = '';
  ref.read(modTagFiltersProvider.notifier).state = <String>{};
  ref.read(modFavoritesOnlyProvider.notifier).state = false;
}

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
