import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;
import 'package:flutter_staggered_animations/flutter_staggered_animations.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:cross_file/cross_file.dart';
import '../core/constants.dart';
import '../models/character_info.dart';
import '../models/mod_origin_seed.dart';
import '../services/api_service.dart';
import '../services/archive_service.dart';
import '../services/ingest_origin_builder.dart';
import '../services/patch_scan.dart';
import '../utils/notifications.dart';
import '../utils/state_providers.dart';
import '../utils/categories.dart';
import '../utils/mod_group_diff.dart';
import '../utils/zzz_characters.dart';
import '../l10n/app_localizations.dart';
import 'components/mode_toggle_widget.dart';
import 'components/character_cards_list_widget.dart';
import 'components/mod_card_widget.dart';
import 'components/mods_toolbar.dart';
import 'components/mods_action_buttons.dart';
import 'components/mods_empty_states.dart';
import 'components/mods_grouped_view.dart';
import 'components/own_scroll_controller.dart';
import 'dialogs/rename_mod_dialog.dart';
import 'dialogs/delete_mod_dialog.dart';
import 'dialogs/duplicate_archive_dialog.dart';
import 'dialogs/import_selection_dialog.dart';
import 'dialogs/keybinds_dialog.dart';
import 'dialogs/mod_context_menu.dart';
import 'dialogs/edit_mod_dialog.dart';
import 'dialogs/mod_details_dialog.dart';
import 'dialogs/mod_backups_dialog.dart';
import 'dialogs/mod_update_dialog.dart';
import 'dialogs/resolve_origin_dialog.dart';
import '../utils/url_utils.dart';

class ModsScreen extends ConsumerStatefulWidget {
  const ModsScreen({super.key});

  @override
  ConsumerState<ModsScreen> createState() => _ModsScreenState();
}

class _ModsScreenState extends ConsumerState<ModsScreen>
    with TickerProviderStateMixin {
  AppLocalizations get loc => context.loc;
  bool isLoading = false;
  String? errorMessage;
  Map<String, String> modCharacterTags = {}; // modId -> characterId
  Set<String> favoriteMods = {};
  late AnimationController _loadingAnimationController;
  late Animation<double> _loadingAnimation;

  // Animation controller for mode toggle liquid effect
  late AnimationController _modeToggleAnimationController;
  late Animation<double> _modeToggleAnimation;

  // Debounce timers to prevent rapid rebuilds
  Timer? _rebuildDebounce;
  Timer? _characterSelectionDebounce;

  // Prevent multiple simultaneous operations
  bool _isOperationInProgress = false;
  bool _isLoadingMods = false;

  // Cache for preventing unnecessary rebuilds
  List<CharacterInfo>? _lastCharactersState;

  // Drag & drop state
  bool _isDragging = false;

  // Focus node для обробки клавіатури
  final FocusNode _focusNode = FocusNode();

  // Mods list sorting & filtering live in providers (see state_providers.dart);
  // the toolbar UI lives in [ModsToolbar].
  bool get _isFiltering => ref.read(modFiltersActiveProvider);

  @override
  void initState() {
    super.initState();
    _loadingAnimationController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    );
    _loadingAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _loadingAnimationController,
        curve: Curves.easeInOut,
      ),
    );

    // Initialize liquid animation controller
    _modeToggleAnimationController = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    );
    _modeToggleAnimation = CurvedAnimation(
      parent: _modeToggleAnimationController,
      curve: Curves.easeInOutCubic,
    );

    _loadTags();
    loadMods();
  }

  @override
  void dispose() {
    _loadingAnimationController.dispose();
    _modeToggleAnimationController.dispose();
    _rebuildDebounce?.cancel();
    _characterSelectionDebounce?.cancel();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _loadTags() async {
    final configService = await ApiService.getConfigService();
    setState(() {
      modCharacterTags = configService.modCharacterTags;
    });
  }

  Future<void> _saveTag(String modId, String characterId) async {
    // Writes the in-folder sidecar (rename-safe) and mirrors to config.json.
    await ApiService.setModCharacter(modId, characterId);
    setState(() {
      modCharacterTags[modId] = characterId;
    });

    // Перезавантажуємо моди, щоб оновити UI з новими тегами
    // Це необхідно, бо мод може переміститись в іншу категорію персонажа
    await loadMods(showLoading: false);
  }

  Future<void> loadMods({bool showLoading = true}) async {
    // Prevent multiple simultaneous load operations
    if (_isLoadingMods) return;
    _isLoadingMods = true;

    setState(() {
      if (showLoading) {
        isLoading = true;
      }
      errorMessage = null;
    });

    try {
      final loadedMods = await ApiService.getMods();
      final configService = await ApiService.getConfigService();
      final favoriteSet = configService.favoriteMods.toSet();
      final List<ModInfo> allMods = [];
      final List<String> validModIds = [];

      for (var oldMod in loadedMods) {
        validModIds.add(oldMod.id);

        // characterId is resolved by the service (in-folder metadata, then the
        // legacy config tag). Fall back to name-based auto-detection — using the
        // shared detector (brief/real names + aliases, word-boundary aware) so
        // names whose id differs from the spoken form (e.g. "Zhu Yuan" vs the
        // id "zhuyuan") still resolve instead of dropping into Unknown.
        String charId = oldMod.characterId;
        if (isUnassignedCharacterId(charId)) {
          charId = detectCharacterId(oldMod.name) ?? charId;
        }

        // Preserve all service-resolved metadata (image, description, url,
        // tags, images, keybinds); only override the per-install bits here.
        allMods.add(
          oldMod.copyWith(
            characterId: charId,
            isFavorite: favoriteSet.contains(oldMod.id),
          ),
        );
      }

      // Очищуємо теги для видалених модів
      await configService.cleanupInvalidTags(validModIds);

      // Перезавантажуємо теги після очищення
      setState(() {
        modCharacterTags = configService.modCharacterTags;
        favoriteMods = favoriteSet;
      });

      // Group the flat list into the sidebar's character/category structure.
      var characters = _buildGroups(allMods);

      // Збагачуємо персонажів keybinds з INI файлів
      try {
        final modManagerService = await ApiService.getModManagerService();
        characters = await modManagerService.enrichCharactersWithKeybinds(
          characters,
        );
      } catch (e) {
        print('Failed to load keybinds: $e');
        // Продовжуємо без keybinds у разі помилки
      }

      // Only update state if it actually changed to prevent unnecessary rebuilds
      final previousCharacters = ref.read(charactersProvider);
      final selectedIndex = ref.read(selectedCharacterIndexProvider);
      String? previousSelectedId;
      if (previousCharacters.isNotEmpty &&
          selectedIndex >= 0 &&
          selectedIndex < previousCharacters.length) {
        previousSelectedId = previousCharacters[selectedIndex].id;
      }

      if (modGroupsChanged(_lastCharactersState, characters)) {
        _lastCharactersState = List.from(characters);
        ref.read(charactersProvider.notifier).state = characters;
      }

      if (previousSelectedId != null && characters.isNotEmpty) {
        final newIndex = characters.indexWhere(
          (char) => char.id == previousSelectedId,
        );
        ref.read(selectedCharacterIndexProvider.notifier).state = newIndex != -1
            ? newIndex
            : 0;
      } else if (characters.isNotEmpty) {
        ref.read(selectedCharacterIndexProvider.notifier).state = 0;
      }

      if (showLoading) {
        setState(() => isLoading = false);
      } else if (mounted) {
        setState(() {});
      }
    } catch (e) {
      setState(() {
        errorMessage = e.toString();
        isLoading = false;
      });
    } finally {
      _isLoadingMods = false;
    }
  }

  /// Groups a flat mod list into the sidebar structure: an "ALL" group, the
  /// built-in non-character categories (shown whenever any mod exists), then
  /// each character that has at least one mod. Pure (no disk I/O), so both
  /// [loadMods] and the targeted in-memory updates below reuse it.
  List<CharacterInfo> _buildGroups(List<ModInfo> allMods) {
    final Map<String, List<ModInfo>> characterMods = {};
    for (final mod in allMods) {
      characterMods.putIfAbsent(mod.characterId, () => []).add(mod);
    }

    final characters = <CharacterInfo>[];
    if (allMods.isNotEmpty) {
      characters.add(
        CharacterInfo(
          id: 'all',
          name: loc.t('mods.all'),
          iconPath: null, // Використаємо іконку по замовчуванню
          skins: allMods,
        ),
      );
      // Built-in categories (UI/Texture/Audio/Misc) always show once any mod
      // exists — even with none assigned — so users can see where non-character
      // mods belong. (Characters, below, only appear once they have a mod.)
      characters.addAll(
        builtInCategories.map(
          (cat) => CharacterInfo(
            id: cat.id,
            name: categoryDisplayName(cat.id, loc),
            icon: cat.icon,
            skins: characterMods[cat.id] ?? [],
          ),
        ),
      );
    }
    characters.addAll(
      zzzCharacterIds
          .map(
            (charId) => CharacterInfo(
              id: charId,
              name: getCharacterDisplayName(charId),
              iconPath:
                  'assets/characters/${getCharacterAssetName(charId)}.png',
              skins: characterMods[charId] ?? [],
            ),
          )
          .where((char) => char.skins.isNotEmpty),
    );
    return characters;
  }

  /// The current flat mod list, recovered from the "ALL" group in
  /// [charactersProvider]. Returns null if the list hasn't been built yet, so
  /// callers can fall back to a full [loadMods].
  List<ModInfo>? _currentAllMods() {
    for (final char in ref.read(charactersProvider)) {
      if (char.id == 'all') return List<ModInfo>.from(char.skins);
    }
    return null;
  }

  /// Rebuilds [charactersProvider] from an updated flat mod list without a disk
  /// rescan, keeping the selected character where possible. Backs the targeted
  /// editorial-action handlers (rename/edit/favorite/delete) so a single-mod
  /// action costs O(1) instead of an O(N) rescan of every mod.
  void _applyGroups(List<ModInfo> allMods) {
    final characters = _buildGroups(allMods);

    final previousCharacters = ref.read(charactersProvider);
    final selectedIndex = ref.read(selectedCharacterIndexProvider);
    String? previousSelectedId;
    if (previousCharacters.isNotEmpty &&
        selectedIndex >= 0 &&
        selectedIndex < previousCharacters.length) {
      previousSelectedId = previousCharacters[selectedIndex].id;
    }

    _lastCharactersState = List.from(characters);
    ref.read(charactersProvider.notifier).state = characters;

    if (previousSelectedId != null && characters.isNotEmpty) {
      final newIndex =
          characters.indexWhere((char) => char.id == previousSelectedId);
      ref.read(selectedCharacterIndexProvider.notifier).state =
          newIndex != -1 ? newIndex : 0;
    } else if (characters.isNotEmpty) {
      ref.read(selectedCharacterIndexProvider.notifier).state = 0;
    }

    if (mounted) setState(() {});
  }

  /// Reflects a completed rename in the UI without a rescan. The folder op and
  /// the service's state migration (active link, config keys, keybind cache)
  /// already happened; only [charactersProvider] needs the id/name swap — plus
  /// a rewrite of the cached image paths, which are absolute and still point at
  /// the old folder (otherwise the thumbnail can't load until a refresh).
  Future<void> _onModRenamed(String oldId, String newName) async {
    final allMods = _currentAllMods();
    final index = allMods?.indexWhere((m) => m.id == oldId) ?? -1;
    final modsPath = (await ApiService.getModManagerService()).modsPath;
    if (allMods == null || index == -1 || modsPath == null || !mounted) {
      unawaited(loadMods(showLoading: false));
      return;
    }

    // Repoint any path under the old folder (managed gallery images and shipped
    // previews alike) at the new folder; leave anything else untouched.
    final oldFolder = path.join(modsPath, oldId);
    final newFolder = path.join(modsPath, newName);
    String remap(String abs) {
      final rel = path.relative(abs, from: oldFolder);
      return rel.startsWith('..') ? abs : path.join(newFolder, rel);
    }

    final old = allMods[index];
    final newImages = old.images.map(remap).toList();
    // Rename preserves character, keybinds (the .ini is unchanged) and every
    // metadata field; only the identity and image locations change.
    allMods[index] = old.copyWith(
      id: newName,
      name: newName,
      imagePath: newImages.isNotEmpty ? newImages.first : null,
      images: newImages,
    );
    _applyGroups(allMods);
  }

  /// Reflects a saved edit in the UI without a rescan. [updated] carries the
  /// edited fields (character, url, description, tags, images) already written
  /// to disk; a character change moves the mod between groups via [_buildGroups].
  void _onModEdited(ModInfo updated) {
    final allMods = _currentAllMods();
    final index = allMods?.indexWhere((m) => m.id == updated.id) ?? -1;
    if (allMods == null || index == -1) {
      unawaited(loadMods(showLoading: false));
      return;
    }
    final existing = allMods[index];
    // Normalize the character the same way loadMods does (explicit pick wins,
    // else fall back to name-based auto-detection).
    var charId = updated.characterId;
    if (isUnassignedCharacterId(charId)) {
      charId = detectCharacterId(updated.name) ?? charId;
    }
    // Rebuild explicitly (not copyWith) so cleared fields — a removed cover or
    // emptied url/description — actually reset instead of keeping stale values.
    allMods[index] = ModInfo(
      id: updated.id,
      name: updated.name,
      characterId: charId,
      isActive: existing.isActive,
      imagePath: updated.images.isNotEmpty ? updated.images.first : null,
      description: updated.description,
      sourceUrl: updated.sourceUrl,
      tags: updated.tags,
      images: updated.images,
      isFavorite: existing.isFavorite,
      keybinds: existing.keybinds,
    );
    setState(() => modCharacterTags[updated.id] = charId);
    _applyGroups(allMods);
  }

  /// Removes a deleted mod from the UI without a rescan (its folder and state
  /// are already gone).
  void _onModDeleted(String modId) {
    final allMods = _currentAllMods();
    if (allMods == null) {
      unawaited(loadMods(showLoading: false));
      return;
    }
    allMods.removeWhere((m) => m.id == modId);
    _applyGroups(allMods);
  }

  Future<void> toggleMod(ModInfo mod) async {
    // Prevent multiple simultaneous operations
    if (_isOperationInProgress) return;
    _isOperationInProgress = true;

    // Cancel any pending debounce
    _rebuildDebounce?.cancel();

    try {
      final wasActive = mod.isActive;
      final activationMode = ref.read(activationModeProvider);

      // If activating a mod in single mode, deactivate other active mods for this character
      if (!wasActive && activationMode == ActivationMode.single) {
        await _deactivateOtherModsForCharacter(
          mod.characterId,
          excludeModId: mod.id,
        );
      }

      await ApiService.toggleMod(mod.id);

      // Оновлюємо стан локально без перезавантаження всіх модів
      if (mounted) {
        final characters = ref.read(charactersProvider);
        final updatedCharacters = characters.map((char) {
          final updatedSkins = char.skins.map((skin) {
            if (skin.id == mod.id) {
              return skin.copyWith(isActive: !wasActive);
            }
            // Якщо single mode, деактивуємо інші моди того ж персонажа
            if (!wasActive &&
                activationMode == ActivationMode.single &&
                skin.characterId == mod.characterId &&
                skin.id != mod.id &&
                skin.isActive) {
              return skin.copyWith(isActive: false);
            }
            return skin;
          }).toList();
          return char.copyWith(skins: updatedSkins);
        }).toList();

        ref.read(charactersProvider.notifier).state = updatedCharacters;
        _lastCharactersState = List.from(updatedCharacters);

        context.notify.success(
          wasActive
              ? loc.t('mods.snackbar.deactivated')
              : loc.t('mods.snackbar.activated'),
          icon: wasActive
              ? Icons.toggle_off_outlined
              : Icons.toggle_on_outlined,
          // Shorter than the default: this confirms a switch the user is
          // looking at, and a queue of them would otherwise fill the corner
          // while they work through a list.
          duration: AppConstants.notificationBriefDuration,
        );
      }
      _isOperationInProgress = false;
    } catch (e) {
      _isOperationInProgress = false;
      if (mounted) {
        context.notify.error(
          loc.t('mods.errors.generic', params: {'message': e.toString()}),
        );
      }
    }
  }

  Future<void> _reloadMods() async {
    if (_isOperationInProgress) return;

    setState(() {
      _isOperationInProgress = true;
    });

    try {
      final modManagerService = await ref.read(
        modManagerServiceProvider.future,
      );
      final success = await modManagerService.reloadMods();

      if (mounted) {
        context.notify.show(
          success
              ? loc.t('mods.snackbar.reload_success')
              : loc.t('mods.snackbar.reload_failure'),
          severity: success
              ? NotificationSeverity.success
              : NotificationSeverity.error,
        );
      }
    } catch (e) {
      if (mounted) {
        context.notify.error(
          loc.t('mods.errors.generic', params: {'message': e.toString()}),
        );
      }
    } finally {
      setState(() {
        _isOperationInProgress = false;
      });
    }
  }

  Future<void> _toggleFavorite(ModInfo mod) async {
    try {
      final configService = await ApiService.getConfigService();
      final isFavorite = favoriteMods.contains(mod.id);

      if (isFavorite) {
        await configService.removeFavoriteMod(mod.id);
      } else {
        await configService.addFavoriteMod(mod.id);
      }

      if (mounted) {
        setState(() {
          final updatedFavorites = Set<String>.from(favoriteMods);
          if (isFavorite) {
            updatedFavorites.remove(mod.id);
          } else {
            updatedFavorites.add(mod.id);
          }
          favoriteMods = updatedFavorites;
        });
      }

      if (mounted) {
        context.notify.success(
          isFavorite
              ? loc.t('mods.snackbar.favorites_removed')
              : loc.t('mods.snackbar.favorites_added'),
          icon: isFavorite ? Icons.star_border_rounded : Icons.star_rounded,
          duration: AppConstants.notificationBriefDuration,
        );
      }

      // Targeted update: flip the one mod's favorite flag instead of rescanning.
      final allMods = _currentAllMods();
      final index = allMods?.indexWhere((m) => m.id == mod.id) ?? -1;
      if (allMods != null && index != -1) {
        allMods[index] = allMods[index].copyWith(isFavorite: !isFavorite);
        _applyGroups(allMods);
      } else {
        await loadMods(showLoading: false);
      }
    } catch (e) {
      if (mounted) {
        context.notify.error(
          loc.t('mods.errors.generic', params: {'message': e.toString()}),
        );
      }
    }
  }

  Future<void> _refreshModsList() async {
    if (_isLoadingMods) return;
    // A manual refresh re-reads everything from disk, including .ini files that
    // may have changed outside the app.
    await ApiService.clearKeybindCache();
    await loadMods(showLoading: false);
    if (!mounted || errorMessage != null) return;
    context.notify.success(
      loc.t('mods.snackbar.list_refreshed'),
      icon: Icons.refresh_rounded,
      duration: AppConstants.notificationBriefDuration,
    );
  }

  /// Renames a mod (its on-disk folder). Live-validates the new name and
  /// delegates to [ApiService.renameMod], which also migrates the active link
  /// and the mod's active/favorite/category state.
  Future<void> _openModFolder(ModInfo mod) async {
    final notify = context.notify;
    try {
      final ok = await ApiService.openModFolder(mod.id);
      if (!mounted || ok) return;
      notify.error(loc.t('mods.snackbar.open_folder_failed'));
    } catch (e) {
      if (!mounted) return;
      notify.error(
        loc.t('mods.errors.generic', params: {'message': e.toString()}),
      );
    }
  }

  /// Confirms and permanently deletes a mod (its folder and all state). The
  /// action is irreversible, so it requires an explicit confirmation.
  void _showEditDialog(ModInfo mod) {
    showEditModDialog(
      context,
      mod,
      onSaved: _onModEdited,
    );
  }

  void _showModDetailsDialog(ModInfo mod) {
    showModDetailsDialog(
      context,
      mod,
      onEdit: () => _showEditDialog(mod),
      onChanged: () => unawaited(loadMods(showLoading: false)),
    );
  }

  /// Opens the resolve dialog and rescans if it wrote anything — the status
  /// slot is drawn from `ModInfo.origin`, which only a scan refreshes.
  Future<void> _resolveOrigin(ModInfo mod) async {
    if (await showResolveOriginDialog(context, mod)) {
      await loadMods(showLoading: false);
    }
  }

  /// Opens the update dialog and rescans if it wrote anything — dismissing an
  /// update lands in the origin block, which only a scan re-reads.
  Future<void> _checkForUpdate(ModInfo mod) async {
    if (await showModUpdateDialog(context, mod)) {
      await loadMods(showLoading: false);
    }
  }

  /// Opens the rollback list and rescans if anything was restored — the folder
  /// itself changes, not just the sidecar.
  Future<void> _restoreBackup(ModInfo mod) async {
    if (await showModBackupsDialog(context, mod)) {
      await loadMods(showLoading: false);
    }
  }

  void _showContextMenu(BuildContext context, ModInfo mod, Offset position) {
    showModContextMenu(
      context,
      mod,
      position,
      onResolveOrigin: () => unawaited(_resolveOrigin(mod)),
      onCheckForUpdate: () => unawaited(_checkForUpdate(mod)),
      onRestoreBackup: () => unawaited(_restoreBackup(mod)),
      // `valueOrNull` rather than a `when`: the listing is one readdir and
      // resolves long before a right-click, and a menu that waited on it would
      // be a menu that sometimes did not open.
      hasBackups:
          ref.read(modBackupsProvider).valueOrNull?.contains(mod.id) ?? false,
      onDetails: () => _showModDetailsDialog(mod),
      onEdit: () => _showEditDialog(mod),
      onRename: () => showRenameModDialog(
        context,
        ref,
        mod,
        onRenamed: (newName) => unawaited(_onModRenamed(mod.id, newName)),
      ),
      onOpenFolder: () => _openModFolder(mod),
      onOpenLink: () => openModLink(context, mod),
      onEditKeybinds: () => showKeybindsDialog(
        context,
        mod,
        onSaved: () => unawaited(loadMods(showLoading: false)),
      ),
      onToggleFavorite: () => _toggleFavorite(mod),
      onDelete: () => showDeleteModDialog(
        context,
        mod,
        onDeleted: () => _onModDeleted(mod.id),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final characters = ref.watch(charactersProvider);
    final selectedIndex = ref.watch(selectedCharacterIndexProvider);
    final currentSkins = ref.watch(currentCharacterSkinsProvider);
    final isDarkMode = ref.watch(isDarkModeProvider);

    // Watched, not read on demand: the context menu asks whether this mod has a
    // rollback to offer, and a `read` from inside the menu builder would start
    // the listing at that moment and answer "no" the first time. Watching it
    // here costs one rebuild when a single readdir resolves.
    ref.watch(modBackupsProvider);

    // The aggregate "ALL" view groups its cards under per-character section
    // headers; every other tab is a single flat grid.
    final selectedCharacterId =
        (selectedIndex >= 0 && selectedIndex < characters.length)
        ? characters[selectedIndex].id
        : null;
    final isAllView = selectedCharacterId == 'all';

    if (isLoading) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedBuilder(
              animation: _loadingAnimation,
              builder: (context, child) {
                return Transform.scale(
                  scale: 0.8 + (_loadingAnimation.value * 0.2),
                  child: Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF0EA5E9), Color(0xFF06B6D4)],
                      ),
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF0EA5E9).withValues(alpha: 0.3),
                          blurRadius: 20,
                          spreadRadius: 5,
                        ),
                      ],
                    ),
                    child: const CircularProgressIndicator(
                      strokeWidth: 3,
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 24),
            AnimatedBuilder(
              animation: _loadingAnimation,
              builder: (context, child) {
                return Opacity(
                  opacity: _loadingAnimation.value,
                  child: Text(
                    loc.t('mods.loading.title'),
                    style: TextStyle(
                      fontSize: 16,
                      color: Colors.grey[600],
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      );
    }

    if (errorMessage != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 48, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              loc.t('mods.errors.load'),
              style: TextStyle(fontSize: 16, color: Colors.grey[600]),
            ),
            const SizedBox(height: 8),
            Text(
              errorMessage!,
              style: TextStyle(fontSize: 12, color: Colors.grey[500]),
            ),
            const SizedBox(height: 24),
            TextButton.icon(
              onPressed: () => loadMods(),
              icon: const Icon(Icons.refresh),
              label: Text(loc.t('mods.errors.retry')),
            ),
          ],
        ),
      );
    }

    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: (node, event) {
        // Обробка Ctrl+V
        if (event is KeyDownEvent) {
          final isControlPressed =
              HardwareKeyboard.instance.isControlPressed ||
              HardwareKeyboard.instance.isMetaPressed;
          if (isControlPressed && event.logicalKey == LogicalKeyboardKey.keyV) {
            _handlePasteFromClipboard();
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      child: Column(
        children: [
          // Header з вибором персонажа
          Container(
            height: 140,
            decoration: BoxDecoration(
              color: Theme.of(context).cardColor,
              border: Border(
                bottom: BorderSide(
                  color: isDarkMode
                      ? Colors.white.withValues(alpha: 0.1)
                      : Colors.black.withValues(alpha: 0.05),
                ),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: EdgeInsets.all(AppConstants.defaultPadding),
                  child: Row(
                    children: [
                      Text(
                        loc.t('mods.headers.characters'),
                        style: TextStyle(
                          fontSize: AppConstants.headerTextSize,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: AppConstants.smallPadding,
                          vertical: AppConstants.tinyPadding,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(
                            AppConstants.activeModBorderColor,
                          ).withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(
                            AppConstants.smallPadding,
                          ),
                        ),
                        child: Text(
                          // Count only real characters — exclude the synthetic
                          // "ALL" entry and the built-in categories.
                          '${characters.where((c) => c.id != 'all' && !isBuiltInCategory(c.id)).length}',
                          style: TextStyle(
                            fontSize: AppConstants.captionTextSize,
                            color: const Color(
                              AppConstants.activeModBorderColor,
                            ),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const Spacer(),
                      // Auto F10 toggle
                      const AutoF10Toggle(),
                      const SizedBox(width: 12),
                      RefreshModsButton(busy: isLoading || _isLoadingMods, onRefresh: _refreshModsList),
                      const SizedBox(width: 12),
                      // F10 Reload button
                      F10ReloadButton(busy: _isOperationInProgress, onReload: _reloadMods),
                      const SizedBox(width: 12),
                      // Mode toggle buttons
                      ModeToggleWidget(
                        modeToggleAnimationController:
                            _modeToggleAnimationController,
                        modeToggleAnimation: _modeToggleAnimation,
                        activationMode: ref.watch(activationModeProvider),
                        onModeChanged: (ActivationMode newMode) {
                          _rebuildDebounce?.cancel();
                          _characterSelectionDebounce?.cancel();
                          _isOperationInProgress = false;
                          ref.read(activationModeProvider.notifier).state =
                              newMode;
                        },
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: CharacterCardsListWidget(
                    characters: characters,
                    selectedIndex: selectedIndex,
                    onCharacterSelected: (int index) {
                      ref.read(selectedCharacterIndexProvider.notifier).state =
                          index;
                    },
                    onCharacterTagSaved: _saveTag,
                    modCharacterTags: modCharacterTags,
                  ),
                ),
              ],
            ),
          ),
          // Search / sort / tag-filter toolbar. Self-contained and
          // provider-driven, so a keystroke or filter toggle rebuilds only the
          // toolbar, not the whole screen. The callback is for the one thing it
          // does that isn't filtering — the bulk "assume current" action writes
          // sidecars, and the status slots are drawn from `ModInfo.origin`,
          // which only a rescan refreshes.
          if (currentSkins.isNotEmpty)
            ModsToolbar(
              onLibraryChanged: () => unawaited(loadMods(showLoading: false)),
            ),

          // Counter for active mods
          if (currentSkins.isNotEmpty)
            Container(
              padding: EdgeInsets.symmetric(
                horizontal: AppConstants.defaultPadding,
                vertical: AppConstants.smallPadding,
              ),
              child: Row(
                children: [
                  Text(
                    loc.t('mods.headers.active_mods'),
                    style: TextStyle(
                      fontSize: AppConstants.titleTextSize,
                      fontWeight: FontWeight.w500,
                      color: Colors.grey[600],
                    ),
                  ),
                  SizedBox(width: AppConstants.smallMargin),
                  Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: AppConstants.smallPadding,
                      vertical: AppConstants.tinyPadding,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(
                        AppConstants.activeModCountColor,
                      ).withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(
                        AppConstants.smallPadding,
                      ),
                    ),
                    child: Text(
                      '${currentSkins.where((mod) => mod.isActive).length}/${currentSkins.length}',
                      style: TextStyle(
                        fontSize: AppConstants.captionTextSize,
                        color: const Color(AppConstants.activeModCountColor),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),

          // Моди для вибраного персонажа
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 500),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (Widget child, Animation<double> animation) {
                // Для старого контенту (що виходить)
                final isOldWidget =
                    child.key !=
                        ValueKey(
                          'character_${selectedIndex}_${currentSkins.length}',
                        ) &&
                    child.key != const ValueKey('empty');

                // Старий контент йде вліво
                final outOffset =
                    Tween<Offset>(
                      begin: Offset.zero,
                      end: const Offset(-1.0, 0),
                    ).animate(
                      CurvedAnimation(
                        parent: animation,
                        curve: Curves.easeInCubic,
                      ),
                    );

                // Новий контент приходить справа
                final inOffset =
                    Tween<Offset>(
                      begin: const Offset(1.0, 0),
                      end: Offset.zero,
                    ).animate(
                      CurvedAnimation(
                        parent: animation,
                        curve: Curves.easeOutCubic,
                      ),
                    );

                // Масштабування для більш плавного ефекту
                final scaleAnimation = Tween<double>(begin: 0.8, end: 1.0)
                    .animate(
                      CurvedAnimation(
                        parent: animation,
                        curve: Curves.easeOutCubic,
                      ),
                    );

                return SlideTransition(
                  position: animation.status == AnimationStatus.reverse
                      ? outOffset
                      : inOffset,
                  child: FadeTransition(
                    opacity: animation,
                    child: ScaleTransition(scale: scaleAnimation, child: child),
                  ),
                );
              },
              child: Padding(
                key: ValueKey(
                  'character_${selectedIndex}_${currentSkins.length}',
                ),
                padding: EdgeInsets.all(AppConstants.defaultPadding),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    return DropTarget(
                      onDragEntered: (details) {
                        setState(() => _isDragging = true);
                      },
                      onDragExited: (details) {
                        setState(() => _isDragging = false);
                      },
                      onDragDone: (details) {
                        _importModsFromFolders(details.files);
                      },
                      // Scoped Consumer: the filtered/sorted list and the
                      // empty/no-results states rebuild here on filter changes,
                      // without rebuilding the rest of the screen.
                      child: Consumer(
                        builder: (context, ref, _) {
                          final visibleSkins = ref.watch(visibleModsProvider);
                          // Also rebuild when the active-filter flag flips (it
                          // drives the no-results / add-card states).
                          ref.watch(modFiltersActiveProvider);
                          return currentSkins.isEmpty && characters.isEmpty
                              ? Center(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(
                                        Icons.inbox_outlined,
                                        size: 64,
                                        color: Colors.grey[400],
                                      ),
                                      const SizedBox(height: 16),
                                      Text(
                                        loc.t('mods.empty.title'),
                                        style: TextStyle(
                                          fontSize: 16,
                                          color: Colors.grey[600],
                                        ),
                                      ),
                                      const SizedBox(height: 24),
                                      SizedBox(
                                        width: 250,
                                        height: 350,
                                        child: AddModCard(isDragging: _isDragging, onTap: _showImportDialog),
                                      ),
                                    ],
                                  ),
                                )
                              : (_isFiltering && visibleSkins.isEmpty)
                              ? ModsNoResults(onClear: () => clearModFilters(ref))
                              : isAllView
                              ? ModsGroupedView(
                                  visibleSkins: visibleSkins,
                                  isFiltering: _isFiltering,
                                  addModCard: AddModCard(isDragging: _isDragging, onTap: _showImportDialog),
                                  modCardBuilder: _buildModCard,
                                )
                              : OwnScrollController(
                                  builder: (context, scrollController) => AnimationLimiter(
                                    child: ScrollConfiguration(
                                      behavior: ScrollConfiguration.of(context)
                                          .copyWith(
                                            dragDevices: {
                                              PointerDeviceKind.touch,
                                              PointerDeviceKind.mouse,
                                              PointerDeviceKind.trackpad,
                                              PointerDeviceKind.stylus,
                                            },
                                            physics:
                                                const BouncingScrollPhysics(),
                                          ),
                                      child: GridView.builder(
                                        controller: scrollController,
                                        // Vertical padding leaves room for the cards'
                                        // hover lift/scale so the top row isn't clipped.
                                        padding: EdgeInsets.symmetric(
                                          horizontal: AppConstants.smallPadding,
                                          vertical: 14,
                                        ),
                                        gridDelegate:
                                            const SliverGridDelegateWithFixedCrossAxisCount(
                                              crossAxisCount: 6,
                                              childAspectRatio: 0.7,
                                              crossAxisSpacing: 16,
                                              mainAxisSpacing: 16,
                                            ),
                                        // The "Add" card is hidden while filtering so
                                        // a no-match search doesn't show just the +.
                                        itemCount:
                                            visibleSkins.length +
                                            (_isFiltering ? 0 : 1),
                                        itemBuilder: (context, index) {
                                          // Кнопка "Додати" в кінці
                                          if (index == visibleSkins.length) {
                                            return AnimationConfiguration.staggeredGrid(
                                              key: const ValueKey(
                                                'add_mod_card',
                                              ),
                                              position: index,
                                              columnCount: 4,
                                              duration: const Duration(
                                                milliseconds: 500,
                                              ),
                                              child: ScaleAnimation(
                                                scale: 0.5,
                                                curve: Curves.easeOutBack,
                                                child: FadeInAnimation(
                                                  curve: Curves.easeOut,
                                                  child: AddModCard(isDragging: _isDragging, onTap: _showImportDialog),
                                                ),
                                              ),
                                            );
                                          }

                                          final mod = visibleSkins[index];
                                          return AnimationConfiguration.staggeredGrid(
                                            key: ValueKey(
                                              'mod_${mod.id}_${mod.isActive}',
                                            ),
                                            position: index,
                                            columnCount: 4,
                                            duration: const Duration(
                                              milliseconds: 500,
                                            ),
                                            child: ScaleAnimation(
                                              scale: 0.5,
                                              curve: Curves.easeOutBack,
                                              child: FadeInAnimation(
                                                curve: Curves.easeOut,
                                                child: _buildModCard(mod),
                                              ),
                                            ),
                                          );
                                        },
                                      ),
                                    ),
                                  ),
                                );
                        },
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModCard(ModInfo mod) {
    final isDarkMode = ref.watch(isDarkModeProvider);

    return LongPressDraggable<ModInfo>(
      data: mod,
      delay: AppConstants.dragDelay,
      hapticFeedbackOnStart: true,
      feedback: Material(
        elevation: AppConstants.dragFeedbackElevation,
        borderRadius: BorderRadius.circular(AppConstants.modCardBorderRadius),
        child: Container(
          width: 200, // Fixed width for feedback
          height: 280, // Fixed height for feedback
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            borderRadius: BorderRadius.circular(
              AppConstants.modCardBorderRadius,
            ),
            border: Border.all(
              color: const Color(AppConstants.activeModBorderColor),
              width: AppConstants.modCardBorderWidthActive,
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(
                  AppConstants.activeModBorderColor,
                ).withValues(alpha: 0.3),
                blurRadius: AppConstants.modCardBlurRadiusActive,
                spreadRadius: AppConstants.modCardSpreadRadiusActive,
              ),
            ],
          ),
          child: Column(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(12),
                  ),
                  child:
                      mod.imagePath != null && File(mod.imagePath!).existsSync()
                      ? Image.file(
                          File(mod.imagePath!),
                          fit: BoxFit.cover,
                          width: double.infinity,
                          // Same reason as ModCardWidget: this is the other card
                          // render path, and leaving it unbounded would keep the
                          // ImageCache-flooding bug alive in whichever view uses it.
                          cacheWidth: AppConstants.modCardDecodeWidth,
                        )
                      : Container(
                          color: Colors.grey.withValues(alpha: 0.1),
                          child: Icon(
                            Icons.image_not_supported,
                            size: 32,
                            color: Colors.grey[600],
                          ),
                        ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  mod.name,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
      childWhenDragging: Opacity(
        opacity: AppConstants.dragFeedbackOpacity,
        child: ModCardWidget(
          mod: mod,
          isDarkMode: isDarkMode,
          onFavoriteToggle: () {},
          onShowDetails: () {},
          onOpenLink: () {},
        ),
      ),
      child: Tooltip(
        message: loc.t('mods.tooltips.card'),
        child: GestureDetector(
          onTap: () => toggleMod(mod),
          onSecondaryTapDown: (details) {
            _showContextMenu(context, mod, details.globalPosition);
          },
          child: ModCardWidget(
            mod: mod,
            isDarkMode: isDarkMode,
            onFavoriteToggle: () => _toggleFavorite(mod),
            onShowDetails: () => _showModDetailsDialog(mod),
            onOpenLink: () => openModLink(context, mod),
            onResolveOrigin: () => unawaited(_resolveOrigin(mod)),
            onShowUpdate: () => unawaited(_checkForUpdate(mod)),
          ),
        ),
      ),
    );
  }

  Future<void> _deactivateOtherModsForCharacter(
    String characterId, {
    String? excludeModId,
  }) async {
    try {
      final characters = ref.read(charactersProvider);
      final character = characters.firstWhere(
        (char) => char.id == characterId,
        orElse: () =>
            CharacterInfo(id: '', name: '', iconPath: null, skins: []),
      );

      if (character.id.isNotEmpty) {
        final activeMods = character.skins
            .where((mod) => mod.isActive && mod.id != excludeModId)
            .toList();
        for (final mod in activeMods) {
          await ApiService.toggleMod(mod.id);
        }
      }
    } catch (e) {
      // Handle error silently
    }
  }

  /// Імпортує моди з перетягнутих папок
  Future<void> _importModsFromFolders(List<XFile> files) async {
    if (_isOperationInProgress) return;

    setState(() {
      _isOperationInProgress = true;
      _isDragging = false;
    });

    // Показуємо діалог з прогресом
    bool dialogShown = false;

    try {
      // Збираємо папки і архіви
      final folderPaths = <String>[];
      final archivesToExtract = <XFile>[];
      final successfullyExtractedArchives = <String>[];
      final tempFoldersToCleanup = <String>[];
      // Extracted-folder path -> originating archive base name, used as an extra
      // character-detection hint (the character is often in the archive name).
      final detectionHints = <String, String>{};
      // Same shape and the same reason: one drop can mix folders from several
      // archives with folders dragged in directly, so provenance is per-folder.
      final originSeeds = <String, ModOriginSeed>{};
      // Set when an archive was recognised as one already in the library and the
      // user chose not to install it again. Distinguishes "you declined" from
      // "there was nothing here" once the folder list comes out empty.
      var declinedDuplicate = false;

      for (final file in files) {
        // Перевіряємо чи це архів
        if (ArchiveService.isArchiveFile(file.path)) {
          archivesToExtract.add(file);
          print('ModsScreen: Знайдено архів: ${file.path}');
        } else {
          // Перевіряємо чи це папка
          final dir = Directory(file.path);
          if (await dir.exists()) {
            folderPaths.add(file.path);
            originSeeds[file.path] = ModOriginSeed.importedFolder;
          }
        }
      }

      // Розархівуємо архіви
      if (archivesToExtract.isNotEmpty) {
        print(
          'ModsScreen: Розархівування ${archivesToExtract.length} архівів...',
        );

        for (final archiveFile in archivesToExtract) {
          final file = File(archiveFile.path);

          if (!await file.exists()) {
            print('ModsScreen: Файл не існує: ${archiveFile.path}');
            continue;
          }

          final result = await ArchiveService.extractArchive(archiveFile: file);

          if (result.success && result.extractedFolders != null) {
            // Per archive, not per drop: one drop can mix several archives, and
            // recognising one of them as a duplicate says nothing about the rest.
            // Declining drops this archive's folders and leaves the others alone;
            // its temp dir is cleaned up with the others below, since it is
            // registered for cleanup either way.
            if (!mounted) return;
            tempFoldersToCleanup.addAll(result.extractedFolders!);
            if (!await confirmArchiveNotDuplicate(
              context,
              ref,
              result.archiveMd5,
            )) {
              declinedDuplicate = true;
              continue;
            }
            folderPaths.addAll(result.extractedFolders!);
            successfullyExtractedArchives.add(archiveFile.path);
            final archiveBaseName = path.basenameWithoutExtension(
              archiveFile.path,
            );
            for (final folder in result.extractedFolders!) {
              detectionHints[folder] = archiveBaseName;
              originSeeds[folder] = ModOriginSeed.importedArchive(
                archiveMd5: result.archiveMd5,
              );
            }
            print(
              'ModsScreen: Розархівовано ${result.extractedFolders!.length} папок з ${archiveFile.name}',
            );
          } else {
            print(
              'ModsScreen: Помилка розархівування ${archiveFile.name}: ${result.error}',
            );
            if (mounted) {
              context.notify.warning(
                loc.t('mods.snackbar.import_error', params: {
                  'message': '${archiveFile.name}: ${result.error}',
                }),
              );
            }
          }
        }
      }

      // Deletes the temp extract dirs (zzz_archive_extract_*). Declared before
      // the early return below, not after it: an archive the user declined as a
      // duplicate was already extracted, so that return path has temp dirs to
      // clean up too.
      Future<void> cleanupTempFolders() async {
        for (final tempPath in tempFoldersToCleanup) {
          try {
            final tempDir = Directory(tempPath);
            if (await tempDir.exists()) {
              final parentDir = tempDir.parent;
              if (parentDir.path.contains('zzz_archive_extract_')) {
                await parentDir.delete(recursive: true);
              }
            }
          } catch (e) {
            print('ModsScreen: temp cleanup error $tempPath: $e');
          }
        }
      }

      if (folderPaths.isEmpty) {
        await cleanupTempFolders();
        // Nothing to say when the user just declined every duplicate — they were
        // asked and answered. "No mod folders found" would be a different claim
        // entirely, and a false one.
        if (mounted && !declinedDuplicate) {
          context.notify.warning(loc.t('mods.snackbar.import_no_folders'));
        }
        return;
      }

      // Default combined name: the shared originating archive name when all
      // folders came from one archive, else the first folder's name.
      final hints = folderPaths.map((f) => detectionHints[f]).toSet();
      final sharedHint =
          (hints.length == 1 && (hints.first?.isNotEmpty ?? false))
              ? hints.first
              : null;

      // When more than one folder would be installed, let the user choose which
      // ones — and whether each becomes its own mod or they combine into one.
      // Shared with the marketplace auto-install via resolveImportSelection.
      if (!mounted) return;
      final plan = await resolveImportSelection(
        context,
        folderPaths,
        defaultCombinedName: sharedHint ?? path.basename(folderPaths.first),
      );
      if (plan == null) {
        await cleanupTempFolders();
        return;
      }
      folderPaths
        ..clear()
        ..addAll(plan.folders);
      final combine = plan.combine;
      final combinedName = plan.combinedName;
      final combinedHint = sharedHint;
      // Merging folders from different sources yields a mod that is only partly
      // from any one archive, so combineSeeds drops to the least-trusted answer
      // rather than claiming a hash that would imply the whole folder matches a
      // published file.
      final combinedSeed = IngestOriginBuilder.combineSeeds(
        folderPaths.map((folder) => originSeeds[folder]),
      );

      final expectedCount = combine ? 1 : folderPaths.length;

      // Показуємо діалог з прогресом
      if (mounted) {
        dialogShown = true;
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) => PopScope(
            canPop: false,
            child: AlertDialog(
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 50,
                    height: 50,
                    child: CircularProgressIndicator(
                      strokeWidth: 4,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        Color(0xFF0EA5E9),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    loc.t(
                      'mods.dialog.import_progress',
                      params: {
                        'count': expectedCount.toString(),
                        'plural': expectedCount == 1
                            ? loc.t('mods.import.single')
                            : loc.t('mods.import.plural'),
                      },
                    ),
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    loc.t('mods.dialog.import_progress_hint'),
                    style: TextStyle(fontSize: 13, color: Colors.grey[600]),
                  ),
                ],
              ),
            ),
          ),
        );
      }

      // Імпортуємо моди
      final modManagerService = await ref.read(
        modManagerServiceProvider.future,
      );
      final (importedMods, autoTags) = combine
          ? await modManagerService.importCombinedMod(
              folderPaths,
              combinedName,
              detectionHint: combinedHint,
              origin: combinedSeed,
            )
          : await modManagerService.importMods(
              folderPaths,
              detectionHints: detectionHints,
              originSeeds: originSeeds,
            );

      // Закриваємо діалог прогресу
      if (mounted && dialogShown) {
        Navigator.of(context).pop();
        dialogShown = false;
      }

      if (importedMods.isEmpty) {
        // Очищаємо тимчасові папки якщо імпорт не вдався
        if (tempFoldersToCleanup.isNotEmpty) {
          print(
            'ModsScreen: Очищення ${tempFoldersToCleanup.length} тимчасових папок (імпорт не вдався)...',
          );
          for (final tempPath in tempFoldersToCleanup) {
            try {
              final tempDir = Directory(tempPath);
              if (await tempDir.exists()) {
                final parentDir = tempDir.parent;
                if (parentDir.path.contains('zzz_archive_extract_')) {
                  await parentDir.delete(recursive: true);
                  print(
                    'ModsScreen: Видалено тимчасову директорію: ${parentDir.path}',
                  );
                }
              }
            } catch (e) {
              print(
                'ModsScreen: Помилка очищення тимчасової папки $tempPath: $e',
              );
            }
          }
        }

        if (mounted) {
          context.notify.warning(loc.t('mods.snackbar.import_duplicates'));
        }
        return;
      }

      // importMods already persisted the detected tags (sidecar + config); just
      // mirror them into the current UI state.
      setState(() {
        modCharacterTags.addAll(autoTags);
      });

      // Перезавантажуємо список модів
      await loadMods(showLoading: false);

      // Safety net: warn about any imported mod that has no .ini at all — a
      // strong sign the mod is incomplete (e.g. a broken multi-folder archive).
      final modsPath = modManagerService.modsPath;
      if (modsPath != null) {
        final noIni = await ArchiveService.modsWithoutIni(
          modsPath,
          importedMods,
        );
        if (noIni.isNotEmpty && mounted) {
          context.notify.warning(
            loc.t(
              'mods.snackbar.import_no_ini',
              params: {'mods': noIni.join(', ')},
            ),
          );
        }

        // A folder whose .ini opens files it does not contain is a *patch* — it
        // needs the mod it patches to already be installed here. Said now
        // rather than left for the user to discover by launching the game and
        // seeing nothing change. Only for mods that have an .ini at all, so it
        // never doubles up with the warning above.
        final patches = await modsThatLookLikePatches(
          modsPath,
          importedMods.where((name) => !noIni.contains(name)),
        );
        if (patches.isNotEmpty && mounted) {
          context.notify.warning(
            loc.t(
              'mods.snackbar.import_patch',
              params: {'mods': patches.join(', ')},
            ),
          );
        }
      }

      // Reported once, here: nothing re-attempts an origin write, because it
      // happens at ingest and never during a scan. Without this the mod would
      // just be silently untracked for updates with no explanation.
      final originFailures = modManagerService.takeOriginWriteFailures();
      if (originFailures.isNotEmpty && mounted) {
        context.notify.warning(
          loc.t(
            'mods.snackbar.origin_write_failed',
            params: {'mods': originFailures.join(', ')},
          ),
        );
      }

      // Видаляємо успішно імпортовані архіви
      if (successfullyExtractedArchives.isNotEmpty) {
        print(
          'ModsScreen: Видалення ${successfullyExtractedArchives.length} архівів...',
        );
        for (final archivePath in successfullyExtractedArchives) {
          try {
            final archiveFile = File(archivePath);
            if (await archiveFile.exists()) {
              await archiveFile.delete();
              print('ModsScreen: Видалено архів: $archivePath');
            }
          } catch (e) {
            print('ModsScreen: Помилка видалення архіву $archivePath: $e');
          }
        }
      }

      // Очищаємо тимчасові папки після успішного імпорту
      if (tempFoldersToCleanup.isNotEmpty) {
        print(
          'ModsScreen: Очищення ${tempFoldersToCleanup.length} тимчасових папок...',
        );
        for (final tempPath in tempFoldersToCleanup) {
          try {
            final tempDir = Directory(tempPath);
            if (await tempDir.exists()) {
              // Отримуємо батьківську директорію (zzz_archive_extract_*)
              final parentDir = tempDir.parent;
              if (parentDir.path.contains('zzz_archive_extract_')) {
                await parentDir.delete(recursive: true);
                print(
                  'ModsScreen: Видалено тимчасову директорію: ${parentDir.path}',
                );
              }
            }
          } catch (e) {
            print(
              'ModsScreen: Помилка очищення тимчасової папки $tempPath: $e',
            );
          }
        }
      }

      if (mounted) {
        // Показуємо детальне повідомлення про успіх
        final hasAutoTags = autoTags.isNotEmpty;
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: Row(
              children: [
                const Icon(
                  Icons.check_circle,
                  color: Color(0xFF10B981),
                  size: 28,
                ),
                const SizedBox(width: 8),
                Text(loc.t('mods.snackbar.import_success_title')),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  loc.t(
                    importedMods.length == 1
                        ? 'mods.import.success_single'
                        : 'mods.import.success_plural',
                    params: {'count': importedMods.length.toString()},
                  ),
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (hasAutoTags) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0EA5E9).withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: const Color(0xFF0EA5E9).withValues(alpha: 0.3),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(
                              Icons.auto_awesome,
                              color: Color(0xFF0EA5E9),
                              size: 18,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              loc.t('mods.dialog.import_auto_tags'),
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF0EA5E9),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        ...autoTags.entries
                            .take(5)
                            .map(
                              (entry) => Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 2,
                                ),
                                child: Text(
                                  '• ${entry.key} → ${getCharacterDisplayName(entry.value)}',
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ),
                            ),
                        if (autoTags.length > 5)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              loc.t(
                                'mods.import.auto_tag_and_more',
                                params: {
                                  'count': (autoTags.length - 5).toString(),
                                },
                              ),
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.grey[600],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Text(
                  loc.t('mods.dialog.import_ready'),
                  style: TextStyle(fontSize: 13, color: Colors.grey[600]),
                ),
              ],
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: Text(loc.t('mods.dialog.great')),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      // Закриваємо діалог прогресу якщо він відкритий
      if (mounted && dialogShown) {
        Navigator.of(context).pop();
      }

      if (mounted) {
        context.notify.error(
          loc.t('mods.snackbar.import_error', params: {'message': '$e'}),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isOperationInProgress = false;
        });
      }
    }
  }

  /// Показує діалог вибору папок для імпорту
  Future<void> _showImportDialog() async {
    if (_isOperationInProgress) return;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.add_circle_outline, color: Color(0xFF0EA5E9)),
            const SizedBox(width: 8),
            Text(loc.t('mods.dialog.add_mods_title')),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              loc.t('mods.dialog.add_mods_description'),
              style: const TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF0EA5E9).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: const Color(0xFF0EA5E9).withValues(alpha: 0.3),
                ),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.lightbulb_outline,
                    color: Color(0xFF0EA5E9),
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      loc.t('mods.dialog.hint'),
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF0EA5E9),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(loc.t('mods.dialog.got_it')),
          ),
        ],
      ),
    );
  }

  /// Обробка Ctrl+V для вставки шляхів з буфера обміну
  Future<void> _handlePasteFromClipboard() async {
    if (_isOperationInProgress) return;

    try {
      final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
      if (clipboardData == null ||
          clipboardData.text == null ||
          clipboardData.text!.isEmpty) {
        if (mounted) {
          context.notify.warning(loc.t('clipboard.empty'));
        }
        return;
      }

      // Розбиваємо текст на рядки та фільтруємо шляхи
      final paths = clipboardData.text!
          .split('\n')
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .toList();

      if (paths.isEmpty) {
        if (mounted) {
          context.notify.warning(loc.t('clipboard.no_paths'));
        }
        return;
      }

      // Перевіряємо що це дійсно папки та створюємо XFile об'єкти
      final validFolders = <XFile>[];
      for (final filePath in paths) {
        // Видаляємо file:// префікс якщо є
        String cleanPath = filePath;
        if (cleanPath.startsWith('file://')) {
          cleanPath = Uri.parse(cleanPath).toFilePath();
        }

        final dir = Directory(cleanPath);
        if (await dir.exists()) {
          validFolders.add(XFile(cleanPath));
        }
      }

      if (validFolders.isEmpty) {
        if (mounted) {
          context.notify.warning(loc.t('clipboard.no_valid'));
        }
        return;
      }

      // Імпортуємо папки
      await _importModsFromFolders(validFolders);
    } catch (e) {
      if (mounted) {
        context.notify.error(
          loc.t('mods.snackbar.paste_error', params: {'message': e.toString()}),
        );
      }
    }
  }
}