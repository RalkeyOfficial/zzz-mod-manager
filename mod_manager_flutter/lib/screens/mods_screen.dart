import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:path/path.dart' as path;
import 'package:flutter_staggered_animations/flutter_staggered_animations.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';
import '../core/constants.dart';
import '../models/character_info.dart';
import '../models/keybind_info.dart';
import '../services/api_service.dart';
import '../services/archive_service.dart';
import '../utils/state_providers.dart';
import '../utils/categories.dart';
import '../utils/zzz_characters.dart';
import '../l10n/app_localizations.dart';
import 'components/mode_toggle_widget.dart';
import 'components/character_cards_list_widget.dart';
import 'components/category_picker.dart';
import 'components/mod_card_widget.dart';
import 'components/mods_toolbar.dart';

/// A staged gallery entry in the edit dialog. It's one of: an image already in
/// the mod folder ([existingPath]), a newly picked file to import on save
/// ([pickedPath]), or pasted bytes to write on save ([pastedBytes]). Nothing
/// touches disk until the dialog is saved.
class _EditImage {
  final String? existingPath;
  final String? pickedPath;
  final Uint8List? pastedBytes;

  const _EditImage.existing(this.existingPath)
    : pickedPath = null,
      pastedBytes = null;
  const _EditImage.picked(this.pickedPath)
    : existingPath = null,
      pastedBytes = null;
  const _EditImage.pasted(this.pastedBytes)
    : existingPath = null,
      pickedPath = null;
}

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

  // Collapsed group ids in the grouped "ALL" view (in-memory, by character id).
  final Set<String> _collapsedGroups = {};

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
      final Map<String, List<ModInfo>> characterMods = {};
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
        if (charId.isEmpty || charId == 'unknown') {
          charId = detectCharacterId(oldMod.name) ?? charId;
        }

        // Preserve all service-resolved metadata (image, description, url,
        // tags, images, keybinds); only override the per-install bits here.
        final mod = oldMod.copyWith(
          characterId: charId,
          isFavorite: favoriteSet.contains(oldMod.id),
        );

        // Додаємо в загальний список
        allMods.add(mod);

        if (!characterMods.containsKey(charId)) {
          characterMods[charId] = [];
        }
        characterMods[charId]!.add(mod);
      }

      // Очищуємо теги для видалених модів
      await configService.cleanupInvalidTags(validModIds);

      // Перезавантажуємо теги після очищення
      setState(() {
        modCharacterTags = configService.modCharacterTags;
        favoriteMods = favoriteSet;
      });

      // Створюємо список персонажів, додаючи "ALL" на початок
      var characters = <CharacterInfo>[];

      // Додаємо "ALL" персонаж якщо є моди
      if (allMods.isNotEmpty) {
        characters.add(
          CharacterInfo(
            id: 'all',
            name: loc.t('mods.all'),
            iconPath: null, // Використаємо іконку по замовчуванню
            skins: allMods,
          ),
        );
      }

      // Built-in non-character categories (UI/Texture/Audio/Misc) come before
      // the characters and are always shown once any mod exists — even with no
      // mods assigned yet — so users can see where non-character mods belong.
      // (Characters, by contrast, only appear once they have a mod.)
      if (allMods.isNotEmpty) {
        characters.addAll(
          builtInCategories.map((cat) {
            return CharacterInfo(
              id: cat.id,
              name: categoryDisplayName(cat.id, loc),
              icon: cat.icon,
              skins: characterMods[cat.id] ?? [],
            );
          }).toList(),
        );
      }

      // Додаємо інших персонажів
      characters.addAll(
        zzzCharacterIds
            .map((charId) {
              return CharacterInfo(
                id: charId,
                name: getCharacterDisplayName(charId),
                iconPath:
                    'assets/characters/${getCharacterAssetName(charId)}.png',
                skins: characterMods[charId] ?? [],
              );
            })
            .where((char) => char.skins.isNotEmpty)
            .toList(),
      );

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

      if (_charactersActuallyChanged(characters)) {
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

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              wasActive
                  ? loc.t('mods.snackbar.deactivated')
                  : loc.t('mods.snackbar.activated'),
            ),
            duration: AppConstants.snackBarDuration,
            behavior: SnackBarBehavior.floating,
            width: 200,
          ),
        );
      }
      _isOperationInProgress = false;
    } catch (e) {
      _isOperationInProgress = false;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              loc.t('mods.errors.generic', params: {'message': e.toString()}),
            ),
            backgroundColor: Colors.red,
          ),
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                Icon(
                  success ? Icons.check_circle : Icons.error,
                  color: Colors.white,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Text(
                  success
                      ? loc.t('mods.snackbar.reload_success')
                      : loc.t('mods.snackbar.reload_failure'),
                ),
              ],
            ),
            backgroundColor: success ? Colors.green : Colors.red,
            duration: const Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
            width: 300,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              loc.t('mods.errors.generic', params: {'message': e.toString()}),
            ),
            backgroundColor: Colors.red,
          ),
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              isFavorite
                  ? loc.t('mods.snackbar.favorites_removed')
                  : loc.t('mods.snackbar.favorites_added'),
            ),
            duration: const Duration(seconds: 1),
            behavior: SnackBarBehavior.floating,
            width: 240,
          ),
        );
      }

      await loadMods(showLoading: false);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              loc.t('mods.errors.generic', params: {'message': e.toString()}),
            ),
            backgroundColor: Colors.red,
          ),
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(loc.t('mods.snackbar.list_refreshed')),
        duration: const Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
        width: 220,
      ),
    );
  }

  Widget _buildAutoF10Toggle() {
    final autoF10Enabled = ref.watch(autoF10ReloadProvider);

    return Tooltip(
      message: autoF10Enabled
          ? loc.t('mods.tooltips.auto_f10_on')
          : loc.t('mods.tooltips.auto_f10_off'),
      child: GestureDetector(
        onTap: () {
          ref.read(autoF10ReloadProvider.notifier).state = !autoF10Enabled;
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: autoF10Enabled
                ? const Color(0xFF10B981) // Зелений коли увімкнено
                : const Color(0xFFEF4444), // Червоний коли вимкнено
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color:
                    (autoF10Enabled
                            ? const Color(0xFF10B981)
                            : const Color(0xFFEF4444))
                        .withOpacity(0.4),
                blurRadius: 12,
                spreadRadius: 1,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Icon(
            autoF10Enabled ? Icons.power : Icons.power_off,
            color: Colors.white,
            size: 20,
          ),
        ),
      ),
    );
  }

  Widget _buildF10ReloadButton() {
    return Tooltip(
      message: loc.t('mods.tooltips.reload'),
      child: Container(
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF0EA5E9), Color(0xFF06B6D4)],
          ),
          borderRadius: BorderRadius.circular(8),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF0EA5E9).withOpacity(0.3),
              blurRadius: 8,
              spreadRadius: 1,
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: _isOperationInProgress ? null : _reloadMods,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedRotation(
                    turns: _isOperationInProgress ? 1 : 0,
                    duration: const Duration(milliseconds: 1000),
                    child: Icon(Icons.refresh, color: Colors.white, size: 18),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'F10',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRefreshModsButton() {
    final isBusy = isLoading || _isLoadingMods;

    return Tooltip(
      message: loc.t('mods.tooltips.refresh'),
      child: Container(
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF6366F1), Color(0xFF8B5CF6)],
          ),
          borderRadius: BorderRadius.circular(8),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF6366F1).withOpacity(0.3),
              blurRadius: 8,
              spreadRadius: 1,
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: isBusy ? null : _refreshModsList,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    transitionBuilder: (child, animation) => FadeTransition(
                      opacity: animation,
                      child: ScaleTransition(scale: animation, child: child),
                    ),
                    child: isBusy
                        ? const SizedBox(
                            key: ValueKey('loader'),
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                Colors.white,
                              ),
                            ),
                          )
                        : const Icon(
                            Icons.sync,
                            key: ValueKey('icon'),
                            color: Colors.white,
                            size: 18,
                          ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    loc.t('mods.actions.refresh'),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Renames a mod (its on-disk folder). Live-validates the new name and
  /// delegates to [ApiService.renameMod], which also migrates the active link
  /// and the mod's active/favorite/category state.
  void _showRenameDialog(ModInfo mod) {
    final controller = TextEditingController(text: mod.name);
    // Existing mod names (lowercased) for a live collision check; the service
    // re-checks authoritatively.
    final existingLower = <String>{
      for (final c in ref.read(charactersProvider))
        for (final m in c.skins) m.id.toLowerCase(),
    }..remove(mod.id.toLowerCase());
    final messenger = ScaffoldMessenger.of(context);

    showDialog(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setLocal) {
            final name = controller.text.trim();
            String? error;
            if (name.isNotEmpty && name != mod.name) {
              if (RegExp(r'[\\/<>:"|?*]').hasMatch(name) ||
                  name.startsWith('.') ||
                  name.startsWith('__')) {
                error = loc.t('mods.dialog.rename_invalid');
              } else if (existingLower.contains(name.toLowerCase())) {
                error = loc.t('mods.dialog.rename_exists');
              }
            }
            final canRename =
                name.isNotEmpty && name != mod.name && error == null;

            Future<void> submit() async {
              Navigator.pop(dialogContext);
              try {
                final ok = await ApiService.renameMod(mod.id, name);
                if (!mounted) return;
                if (ok) {
                  messenger.showSnackBar(
                    SnackBar(
                      content: Text(loc.t('mods.snackbar.renamed')),
                      duration: const Duration(seconds: 1),
                    ),
                  );
                  unawaited(loadMods(showLoading: false));
                } else {
                  messenger.showSnackBar(
                    SnackBar(
                      content: Text(loc.t('mods.dialog.rename_exists')),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              } catch (e) {
                if (!mounted) return;
                messenger.showSnackBar(
                  SnackBar(
                    content: Text(
                      loc.t(
                        'mods.errors.generic',
                        params: {'message': e.toString()},
                      ),
                    ),
                    backgroundColor: Colors.red,
                  ),
                );
              }
            }

            return AlertDialog(
              title: Row(
                children: [
                  const Icon(Icons.drive_file_rename_outline, size: 24),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      loc.t('mods.dialog.rename_title'),
                      style: const TextStyle(fontSize: 18),
                    ),
                  ),
                ],
              ),
              content: SizedBox(
                width: 380,
                child: TextField(
                  controller: controller,
                  autofocus: true,
                  onChanged: (_) => setLocal(() {}),
                  onSubmitted: canRename ? (_) => submit() : null,
                  decoration: InputDecoration(
                    labelText: loc.t('mods.dialog.rename_label'),
                    errorText: error,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: Text(loc.t('mods.dialog.cancel')),
                ),
                FilledButton(
                  onPressed: canRename ? submit : null,
                  child: Text(loc.t('mods.dialog.rename_confirm')),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// Opens the mod's on-disk folder in the system file manager.
  Future<void> _openModFolder(ModInfo mod) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final ok = await ApiService.openModFolder(mod.id);
      if (!mounted || ok) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(loc.t('mods.snackbar.open_folder_failed')),
          backgroundColor: Colors.red,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            loc.t('mods.errors.generic', params: {'message': e.toString()}),
          ),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  /// Confirms and permanently deletes a mod (its folder and all state). The
  /// action is irreversible, so it requires an explicit confirmation.
  void _showDeleteDialog(ModInfo mod) {
    final messenger = ScaffoldMessenger.of(context);
    showDialog(
      context: context,
      builder: (dialogContext) {
        Future<void> confirm() async {
          Navigator.pop(dialogContext);
          try {
            final ok = await ApiService.deleteMod(mod.id);
            if (!mounted) return;
            if (ok) {
              messenger.showSnackBar(
                SnackBar(
                  content: Text(loc.t('mods.snackbar.deleted')),
                  duration: const Duration(seconds: 1),
                ),
              );
              unawaited(loadMods(showLoading: false));
            } else {
              messenger.showSnackBar(
                SnackBar(
                  content: Text(loc.t('mods.snackbar.delete_failed')),
                  backgroundColor: Colors.red,
                ),
              );
            }
          } catch (e) {
            if (!mounted) return;
            messenger.showSnackBar(
              SnackBar(
                content: Text(
                  loc.t('mods.errors.generic', params: {'message': e.toString()}),
                ),
                backgroundColor: Colors.red,
              ),
            );
          }
        }

        return AlertDialog(
          title: Row(
            children: [
              const Icon(Icons.warning_amber_rounded,
                  size: 24, color: Colors.red),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  loc.t('mods.dialog.delete_title'),
                  style: const TextStyle(fontSize: 18),
                ),
              ),
            ],
          ),
          content: SizedBox(
            width: 380,
            child: Text(
              loc.t('mods.dialog.delete_message', params: {'mod': mod.name}),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(loc.t('mods.dialog.cancel')),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: confirm,
              child: Text(loc.t('mods.dialog.delete_confirm')),
            ),
          ],
        );
      },
    );
  }

  void _showEditDialog(ModInfo mod) {
    final selectedChar = ValueNotifier<String>(mod.characterId);
    final urlController = TextEditingController(text: mod.sourceUrl ?? '');
    final descController = TextEditingController(text: mod.description ?? '');
    final tagController = TextEditingController();
    final tags = ValueNotifier<List<String>>(List<String>.from(mod.tags));
    // Staged gallery: edits only affect this working list and are committed to
    // disk on Save (Cancel discards them). Seeded from the mod's current images.
    final images = ValueNotifier<List<_EditImage>>(
      mod.images.map((p) => _EditImage.existing(p)).toList(),
    );

    Future<void> pasteImageInto() async {
      final bytes = await Pasteboard.image;
      if (bytes == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(loc.t('mods.snackbar.clipboard_empty'))),
          );
        }
        return;
      }
      images.value = [...images.value, _EditImage.pasted(bytes)];
    }

    Future<void> pickImagesInto() async {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.image,
      );
      if (result == null) return;
      final added = result.files
          .where((f) => f.path != null)
          .map((f) => _EditImage.picked(f.path!))
          .toList();
      if (added.isNotEmpty) images.value = [...images.value, ...added];
    }

    void removeImage(_EditImage item) {
      images.value = images.value.where((e) => e != item).toList();
    }

    void setCover(_EditImage item) {
      images.value = [item, ...images.value.where((e) => e != item)];
    }

    void addTag(String raw) {
      // Allow comma- or enter-separated entry; dedupe case-insensitively.
      final parts = raw
          .split(',')
          .map((t) => t.trim())
          .where((t) => t.isNotEmpty);
      final current = List<String>.from(tags.value);
      for (final t in parts) {
        if (!current.any((e) => e.toLowerCase() == t.toLowerCase())) {
          current.add(t);
        }
      }
      tags.value = current;
      tagController.clear();
    }

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(loc.t('mods.dialog.edit_title')),
        content: SizedBox(
          width: 400,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  mod.name,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  loc.t('mods.dialog.character_tag'),
                  style: const TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 8),
                ValueListenableBuilder<String>(
                  valueListenable: selectedChar,
                  builder: (context, value, _) {
                    final isCategory = isBuiltInCategory(value);
                    final isCharacter =
                        !isCategory && characterById(value) != null;
                    final hasValue = isCategory || isCharacter;
                    return InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () async {
                        final picked = await showCategoryPicker(
                          context,
                          currentId: value,
                        );
                        if (picked != null) selectedChar.value = picked;
                      },
                      child: InputDecorator(
                        decoration: InputDecoration(
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          isDense: true,
                        ),
                        child: Row(
                          children: [
                            if (isCategory)
                              Icon(
                                categoryIcon(value),
                                size: 24,
                                color: Colors.grey[700],
                              )
                            else if (isCharacter)
                              ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child: Image.asset(
                                  'assets/characters/${getCharacterAssetName(value)}.png',
                                  width: 24,
                                  height: 24,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) => Icon(
                                    Icons.person,
                                    size: 24,
                                    color: Colors.grey[600],
                                  ),
                                ),
                              ),
                            if (hasValue) const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                hasValue
                                    ? categoryDisplayName(value, loc)
                                    : loc.t('mods.dialog.no_category'),
                                style: TextStyle(
                                  color: hasValue ? null : Colors.grey[600],
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Icon(
                              Icons.arrow_drop_down,
                              color: Colors.grey[600],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 16),
                Text(
                  loc.t('mods.dialog.source_url'),
                  style: const TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: urlController,
                  keyboardType: TextInputType.url,
                  decoration: InputDecoration(
                    hintText: loc.t('mods.dialog.source_url_hint'),
                    prefixIcon: const Icon(Icons.link, size: 20),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  loc.t('mods.dialog.description'),
                  style: const TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: descController,
                  minLines: 8,
                  maxLines: 8,
                  keyboardType: TextInputType.multiline,
                  decoration: InputDecoration(
                    hintText: loc.t('mods.dialog.description_hint'),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  loc.t('mods.dialog.tags'),
                  style: const TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: tagController,
                  textInputAction: TextInputAction.done,
                  onSubmitted: addTag,
                  decoration: InputDecoration(
                    hintText: loc.t('mods.dialog.tag_add_hint'),
                    prefixIcon: const Icon(Icons.label_outline, size: 20),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.add, size: 20),
                      tooltip: loc.t('mods.dialog.tag_add'),
                      onPressed: () => addTag(tagController.text),
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 8),
                ValueListenableBuilder<List<String>>(
                  valueListenable: tags,
                  builder: (context, value, _) {
                    if (value.isEmpty) return const SizedBox.shrink();
                    return Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: value
                          .map(
                            (tag) => Chip(
                              label: Text(tag),
                              visualDensity: VisualDensity.compact,
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                              onDeleted: () {
                                tags.value = List<String>.from(value)
                                  ..remove(tag);
                              },
                            ),
                          )
                          .toList(),
                    );
                  },
                ),
                const SizedBox(height: 16),
                Text(
                  loc.t('mods.dialog.images'),
                  style: const TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 8),
                ValueListenableBuilder<List<_EditImage>>(
                  valueListenable: images,
                  builder: (context, value, _) {
                    if (value.isEmpty) {
                      return Text(
                        loc.t('mods.details.no_images'),
                        style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                      );
                    }
                    return Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (int i = 0; i < value.length; i++)
                          _editImageThumb(
                            value[i],
                            isCover: i == 0,
                            onSetCover: () => setCover(value[i]),
                            onRemove: () => removeImage(value[i]),
                          ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: pasteImageInto,
                      icon: const Icon(Icons.content_paste, size: 16),
                      label: Text(loc.t('mods.dialog.image_paste')),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: pickImagesInto,
                      icon: const Icon(
                        Icons.add_photo_alternate_outlined,
                        size: 16,
                      ),
                      label: Text(loc.t('mods.dialog.image_add')),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(loc.t('mods.dialog.cancel')),
          ),
          FilledButton(
            onPressed: () async {
              // Fold any text still in the tag input into the list.
              addTag(tagController.text);

              // 1) Persist everything (the actual save — fast disk writes):
              //    commit staged images, then the metadata + character tag.
              final committedImages = await _commitGalleryImages(
                mod,
                images.value,
              );
              await ApiService.updateMod(
                mod.copyWith(
                  characterId: selectedChar.value,
                  sourceUrl: urlController.text.trim(),
                  description: descController.text.trim(),
                  tags: tags.value,
                  images: committedImages,
                ),
              );
              await ApiService.setModCharacter(mod.id, selectedChar.value);

              if (!mounted) return;
              // 2) Close + confirm immediately — the save is done.
              setState(() => modCharacterTags[mod.id] = selectedChar.value);
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(loc.t('mods.snackbar.tag_saved')),
                  duration: const Duration(seconds: 1),
                ),
              );
              // 3) Refresh the list afterwards, without blocking the dialog.
              unawaited(loadMods(showLoading: false));
            },
            child: Text(loc.t('mods.dialog.save')),
          ),
        ],
      ),
    );
  }

  /// Read-only dialog showing everything about a mod: gallery, character,
  /// description, tags, source link, and keybinds (VK_-stripped for readability).
  void _showModDetailsDialog(ModInfo mod) {
    final selectedImage = ValueNotifier<int>(0);
    final validKeybinds = (mod.keybinds ?? [])
        .where((kb) => kb.keyValue != null && kb.keyValue!.isNotEmpty)
        .toList();
    final hasCharacter =
        mod.characterId.isNotEmpty && mod.characterId != 'unknown';
    final hasDescription =
        mod.description != null && mod.description!.isNotEmpty;
    final hasUrl = mod.sourceUrl != null && mod.sourceUrl!.isNotEmpty;

    showDialog(
      context: context,
      builder: (context) {
        final media = MediaQuery.of(context);
        final dialogWidth = (media.size.width * 0.85).clamp(420.0, 820.0);
        // Leave room for the dialog's title, actions, and insets so the
        // fixed-height content can't overflow on a small window.
        final dialogHeight = (media.size.height * 0.7).clamp(300.0, 560.0);

        return AlertDialog(
          title: Row(
            children: [
              Expanded(
                child: Text(mod.name, style: const TextStyle(fontSize: 18)),
              ),
              IconButton(
                icon: const Icon(Icons.edit_outlined, size: 20),
                tooltip: loc.t('mods.context_menu.edit'),
                onPressed: () {
                  Navigator.pop(context);
                  _showEditDialog(mod);
                },
              ),
            ],
          ),
          content: SizedBox(
            width: dialogWidth,
            height: dialogHeight,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Left: gallery fills the available vertical space.
                SizedBox(width: 300, child: _detailGallery(mod, selectedImage)),
                const SizedBox(width: 20),
                // Right: scrollable info column.
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (hasCharacter) ...[
                          Row(
                            children: [
                              if (isBuiltInCategory(mod.characterId))
                                Icon(
                                  categoryIcon(mod.characterId),
                                  size: 28,
                                  color: Colors.grey[700],
                                )
                              else
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(4),
                                  child: Image.asset(
                                    'assets/characters/${getCharacterAssetName(mod.characterId)}.png',
                                    width: 28,
                                    height: 28,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, __, ___) => Icon(
                                      Icons.person,
                                      size: 28,
                                      color: Colors.grey[600],
                                    ),
                                  ),
                                ),
                              const SizedBox(width: 8),
                              Text(
                                categoryDisplayName(mod.characterId, loc),
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                        ],
                        // Description is always shown, even when empty.
                        _detailSectionLabel(loc.t('mods.dialog.description')),
                        const SizedBox(height: 4),
                        if (hasDescription)
                          _buildDescriptionMarkdown(context, mod.description!)
                        else
                          Text(
                            loc.t('mods.details.no_description'),
                            style: TextStyle(
                              fontSize: 13,
                              color: Colors.grey[500],
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        const SizedBox(height: 16),
                        if (mod.tags.isNotEmpty) ...[
                          _detailSectionLabel(loc.t('mods.dialog.tags')),
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: mod.tags
                                .map(
                                  (t) => Chip(
                                    label: Text(t),
                                    visualDensity: VisualDensity.compact,
                                    materialTapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                  ),
                                )
                                .toList(),
                          ),
                          const SizedBox(height: 16),
                        ],
                        if (hasUrl) ...[
                          _detailSectionLabel(loc.t('mods.dialog.source_url')),
                          const SizedBox(height: 4),
                          InkWell(
                            onTap: () => _openModLink(mod),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.open_in_new,
                                  size: 16,
                                  color: Color(0xFF6366F1),
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    mod.sourceUrl!,
                                    style: const TextStyle(
                                      fontSize: 13,
                                      color: Color(0xFF6366F1),
                                      decoration: TextDecoration.underline,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),
                        ],
                        if (validKeybinds.isNotEmpty) ...[
                          _detailSectionLabel(loc.t('mods.details.keybinds')),
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: validKeybinds
                                .map(_detailKeybindChip)
                                .toList(),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(loc.t('mods.keybinds.close')),
            ),
          ],
        );
      },
    );
  }

  /// Left-hand gallery for the details dialog: a large cover that fills the
  /// available height, with a thumbnail strip below when there's more than one
  /// image. Shows a placeholder when the mod has no images.
  Widget _detailGallery(ModInfo mod, ValueNotifier<int> selected) {
    if (mod.images.isEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Container(
          color: Colors.black.withOpacity(0.2),
          alignment: Alignment.center,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.image_not_supported_outlined,
                size: 40,
                color: Colors.grey[600],
              ),
              const SizedBox(height: 8),
              Text(
                loc.t('mods.details.no_images'),
                style: TextStyle(fontSize: 12, color: Colors.grey[500]),
              ),
            ],
          ),
        ),
      );
    }

    final hasThumbs = mod.images.length > 1;

    return LayoutBuilder(
      builder: (context, constraints) {
        // Size the cover to a square that fits the available space, reserving
        // room for the thumbnail strip so it sits directly beneath the image.
        const thumbsReserved = 64.0; // 56 strip + 8 gap
        final coverSize = min(
          constraints.maxWidth,
          constraints.maxHeight - (hasThumbs ? thumbsReserved : 0),
        ).clamp(80.0, 360.0).toDouble();

        return Column(
          // Keep the image + carousel together, centered as one group.
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Square cover box; the full image is fitted inside (contain) so
            // both portrait and landscape images show completely, letterboxed.
            SizedBox(
              width: coverSize,
              height: coverSize,
              child: ValueListenableBuilder<int>(
                valueListenable: selected,
                builder: (context, index, _) {
                  final safe = index.clamp(0, mod.images.length - 1);
                  return MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: () => _showImageLightbox(mod.images[safe]),
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.25),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: const Color(0xFF334155),
                            width: 1,
                          ),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: Image.file(
                          File(mod.images[safe]),
                          fit: BoxFit.contain,
                          errorBuilder: (_, __, ___) =>
                              _detailImagePlaceholder(double.infinity),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            if (hasThumbs) ...[
              const SizedBox(height: 8),
              SizedBox(
                height: 56,
                child: ValueListenableBuilder<int>(
                  valueListenable: selected,
                  builder: (context, index, _) {
                    return ListView.separated(
                      scrollDirection: Axis.horizontal,
                      shrinkWrap: true,
                      itemCount: mod.images.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 6),
                      itemBuilder: (context, i) {
                        final isSelected = i == index;
                        return InkWell(
                          onTap: () => selected.value = i,
                          child: Container(
                            width: 56,
                            decoration: BoxDecoration(
                              color: Colors.black.withOpacity(0.25),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: isSelected
                                    ? const Color(0xFF6366F1)
                                    : const Color(0xFF334155),
                                width: 2,
                              ),
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: Image.file(
                              File(mod.images[i]),
                              fit: BoxFit.contain,
                              errorBuilder: (_, __, ___) =>
                                  _detailImagePlaceholder(52),
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  /// Opens an image large and centered over a translucent dark backdrop.
  /// Tap anywhere (or the image) to dismiss — no chrome.
  void _showImageLightbox(String imagePath) {
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: Colors.black.withOpacity(0.85),
      transitionDuration: const Duration(milliseconds: 150),
      pageBuilder: (context, _, __) {
        return GestureDetector(
          onTap: () => Navigator.of(context).pop(),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Center(
              child: InteractiveViewer(
                maxScale: 5,
                child: Image.file(
                  File(imagePath),
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => Icon(
                    Icons.broken_image_outlined,
                    size: 64,
                    color: Colors.grey[500],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _detailImagePlaceholder(double height) {
    return Container(
      height: height.isFinite ? height : null,
      width: double.infinity,
      alignment: Alignment.center,
      color: Colors.black.withOpacity(0.2),
      child: Icon(Icons.broken_image_outlined, color: Colors.grey[600]),
    );
  }

  Widget _detailSectionLabel(String text) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.bold,
        color: Colors.grey[400],
        letterSpacing: 0.4,
      ),
    );
  }

  Widget _detailKeybindChip(KeybindInfo keybind) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            const Color(0xFF1E293B).withOpacity(0.8),
            const Color(0xFF0F172A).withOpacity(0.9),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF334155), width: 1.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            keybind.displayName,
            style: const TextStyle(
              color: Color(0xFFE2E8F0),
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            keybind.displayKeyValue ?? '',
            style: const TextStyle(
              color: Color(0xFFFBBF24),
              fontSize: 12,
              fontWeight: FontWeight.bold,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }

  /// Commits the staged gallery to disk: imports newly picked files and pasted
  /// bytes into the mod folder, deletes removed images **only when they are
  /// managed copies** (inside `.zzz-mod-manager/images/` — never the mod's own
  /// files like a shipped Preview.png), and returns the final absolute paths.
  Future<List<String>> _commitGalleryImages(
    ModInfo mod,
    List<_EditImage> items,
  ) async {
    final modManager = await ApiService.getModManagerService();
    final modsPath = modManager.modsPath;
    if (modsPath == null) return mod.images;
    final folder = path.join(modsPath, mod.id);
    final managedDir = modManager.metadataService.imagesDir(folder);

    final finalAbs = <String>[];
    final keptExisting = <String>{};
    for (final item in items) {
      if (item.existingPath != null) {
        finalAbs.add(item.existingPath!);
        keptExisting.add(item.existingPath!);
      } else if (item.pastedBytes != null) {
        final rel = await modManager.metadataService.addImageBytes(
          folder,
          item.pastedBytes!,
        );
        if (rel != null) finalAbs.add(path.join(folder, rel));
      } else if (item.pickedPath != null) {
        final rel = await modManager.metadataService.importImageFile(
          folder,
          item.pickedPath!,
        );
        if (rel != null) finalAbs.add(path.join(folder, rel));
      }
    }

    for (final original in mod.images) {
      if (keptExisting.contains(original)) continue;
      if (path.isWithin(managedDir, original)) {
        try {
          final file = File(original);
          if (await file.exists()) await file.delete();
        } catch (_) {
          // Ignore: file may already be gone.
        }
      }
    }
    return finalAbs;
  }

  /// A thumbnail in the edit dialog's image manager: shows the (possibly not
  /// yet saved) image, a cover badge / set-as-cover tap, and a remove button.
  Widget _editImageThumb(
    _EditImage item, {
    required bool isCover,
    required VoidCallback onSetCover,
    required VoidCallback onRemove,
  }) {
    final Widget image = item.pastedBytes != null
        ? Image.memory(
            item.pastedBytes!,
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) =>
                Icon(Icons.broken_image_outlined, color: Colors.grey[600]),
          )
        : Image.file(
            File(item.existingPath ?? item.pickedPath!),
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) =>
                Icon(Icons.broken_image_outlined, color: Colors.grey[600]),
          );
    return SizedBox(
      width: 72,
      height: 72,
      child: Stack(
        children: [
          Positioned.fill(
            child: Tooltip(
              message: loc.t('mods.dialog.image_set_cover'),
              child: InkWell(
                onTap: isCover ? null : onSetCover,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.25),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: isCover
                          ? const Color(0xFF6366F1)
                          : const Color(0xFF334155),
                      width: 2,
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: image,
                ),
              ),
            ),
          ),
          if (isCover)
            Positioned(
              left: 2,
              bottom: 2,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: const Color(0xFF6366F1),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  loc.t('mods.dialog.image_cover'),
                  style: const TextStyle(fontSize: 9, color: Colors.white),
                ),
              ),
            ),
          Positioned(
            right: 0,
            top: 0,
            child: InkWell(
              onTap: onRemove,
              child: Container(
                decoration: const BoxDecoration(
                  color: Colors.black54,
                  shape: BoxShape.circle,
                ),
                padding: const EdgeInsets.all(2),
                child: const Icon(Icons.close, size: 14, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Renders a mod [description] as markdown for the details dialog.
  ///
  /// Adds two ZZZ-specific extensions on top of standard markdown:
  /// - a run of `>` is treated as a single blockquote level
  ///   ([_FlatBlockquoteSyntax]) so decorative `>>>>> ... <<<<<` lines survive;
  /// - GitHub-style alerts (`> [!NOTE]`, `[!TIP]`, `[!IMPORTANT]`, `[!WARNING]`,
  ///   `[!CAUTION]`, plus a non-standard `[!INFO]` alias of note) render as
  ///   coloured callouts ([_AlertElementBuilder]).
  Widget _buildDescriptionMarkdown(BuildContext context, String description) {
    final styleSheet =
        MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
          p: const TextStyle(fontSize: 13),
          a: const TextStyle(
            fontSize: 13,
            color: Color(0xFF6366F1),
            decoration: TextDecoration.underline,
          ),
          // A `>` at the start of a line is markdown blockquote syntax. Keep the
          // text readable (inherit the body color) with a subtle accent bar
          // instead of the default washed-out, heavily padded box.
          blockquote: TextStyle(
            fontSize: 13,
            color: Theme.of(context).textTheme.bodyMedium?.color,
          ),
          blockquotePadding: const EdgeInsets.fromLTRB(12, 4, 8, 4),
          blockquoteDecoration: BoxDecoration(
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(4),
            border: const Border(
              left: BorderSide(color: Color(0xFF6366F1), width: 3),
            ),
          ),
        );

    return MarkdownBody(
      data: description,
      selectable: true,
      shrinkWrap: true,
      // Render single newlines as line breaks instead of collapsing them into
      // spaces (matches what users type in the plain-text editor).
      softLineBreak: true,
      // Alerts must be tried before the flat blockquote so `> [!WARNING]` wins
      // over the generic `>` handling.
      blockSyntaxes: const [_AlertBlockSyntax(), _FlatBlockquoteSyntax()],
      builders: {
        'alert': _AlertElementBuilder(
          onTapLink: _launchUrl,
          styleSheet: styleSheet,
        ),
      },
      onTapLink: (text, href, title) {
        if (href != null) _launchUrl(href);
      },
      styleSheet: styleSheet,
    );
  }

  /// Opens a mod's source URL in the default browser.
  Future<void> _openModLink(ModInfo mod) async {
    final url = mod.sourceUrl;
    if (url == null || url.isEmpty) return;
    await _launchUrl(url);
  }

  /// Opens [url] in the default external browser, validating the scheme and
  /// surfacing errors as snackbars. Shared by the source-URL link and any
  /// links embedded in a mod's markdown description.
  Future<void> _launchUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(loc.t('mods.snackbar.invalid_url')),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return;
    }
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              loc.t('mods.errors.generic', params: {'message': e.toString()}),
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _showEditKeybindDialog(ModInfo mod, KeybindInfo keybind) {
    final keyController = TextEditingController(text: keybind.keyValue ?? '');

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.edit_outlined, size: 24),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                loc.t(
                  'mods.keybinds.edit_title',
                  params: {'name': keybind.displayName},
                ),
                style: const TextStyle(fontSize: 18),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              loc.t('mods.keybinds.edit_prompt'),
              style: const TextStyle(fontSize: 13, color: Color(0xFF94A3B8)),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: keyController,
              decoration: InputDecoration(
                labelText: loc.t('mods.keybinds.field_label'),
                hintText: loc.t('mods.keybinds.field_hint'),
                prefixIcon: const Icon(
                  Icons.keyboard,
                  color: Color(0xFFFBBF24),
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Color(0xFF334155)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Color(0xFF334155)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(
                    color: Color(0xFFFBBF24),
                    width: 2,
                  ),
                ),
              ),
              autofocus: true,
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B).withOpacity(0.5),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFF334155)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    loc.t('mods.keybinds.common_title'),
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFFE2E8F0),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    loc.t('mods.keybinds.common_list'),
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF94A3B8),
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
            child: Text(loc.t('mods.keybinds.cancel')),
          ),
          FilledButton(
            onPressed: () async {
              final newKey = keyController.text.trim();
              if (newKey.isNotEmpty) {
                await _saveKeybindChange(mod, keybind, newKey);
                Navigator.pop(context);
                // Перезавантажити моди щоб побачити зміни
                await loadMods(showLoading: false);
              }
            },
            child: Text(loc.t('mods.keybinds.save')),
          ),
        ],
      ),
    );
  }

  Future<void> _saveKeybindChange(
    ModInfo mod,
    KeybindInfo keybind,
    String newKey,
  ) async {
    try {
      final modManagerService = await ApiService.getModManagerService();
      final modsPath = modManagerService.modsPath;

      if (modsPath == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(loc.t('mods.keybinds.error_no_path'))),
          );
        }
        return;
      }

      // Знаходимо INI файл моду
      final modPath = path.join(modsPath, mod.id);
      final modDir = Directory(modPath);

      if (!await modDir.exists()) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(loc.t('mods.keybinds.error_no_dir'))),
          );
        }
        return;
      }

      // Шукаємо INI файли
      final iniFiles = await modDir
          .list(recursive: true)
          .where(
            (entity) =>
                entity is File && entity.path.toLowerCase().endsWith('.ini'),
          )
          .cast<File>()
          .toList();

      if (iniFiles.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(loc.t('mods.keybinds.error_no_ini'))),
          );
        }
        return;
      }

      // Читаємо і оновлюємо INI файл
      for (final iniFile in iniFiles) {
        String content = await iniFile.readAsString();
        final lines = content.split('\n');
        bool inTargetSection = false;
        bool updated = false;

        for (int i = 0; i < lines.length; i++) {
          final line = lines[i].trim();

          // Перевіряємо чи це наша секція
          if (line.toLowerCase() == '[${keybind.section.toLowerCase()}]') {
            inTargetSection = true;
            continue;
          }

          // Перевіряємо чи почалась нова секція
          if (line.startsWith('[') && line.endsWith(']')) {
            inTargetSection = false;
          }

          // Якщо ми в потрібній секції і знайшли рядок з key (key= або Key =)
          if (inTargetSection &&
              RegExp(r'^key\s*=', caseSensitive: false).hasMatch(line)) {
            lines[i] = 'key = $newKey';
            updated = true;
            break;
          }
        }

        if (updated) {
          await iniFile.writeAsString(lines.join('\n'));
          // The .ini changed — drop this mod's cached keybinds so the reload
          // re-parses it.
          await ApiService.invalidateKeybinds(mod.id);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  loc.t(
                    'mods.keybinds.updated',
                    params: {'name': keybind.displayName, 'key': newKey},
                  ),
                ),
                backgroundColor: const Color(0xFF10B981),
              ),
            );
          }
          break;
        }
      }
    } catch (e) {
      print('Error saving keybind: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              loc.t(
                'mods.keybinds.error_save',
                params: {'message': e.toString()},
              ),
            ),
          ),
        );
      }
    }
  }

  void _showKeybindsDialog(ModInfo mod) {
    if (mod.keybinds == null || mod.keybinds!.isEmpty) return;

    // Фільтруємо тільки keybinds з key значенням
    final validKeybinds = mod.keybinds!
        .where((kb) => kb.keyValue != null && kb.keyValue!.isNotEmpty)
        .toList();

    if (validKeybinds.isEmpty) return;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.keyboard_outlined, size: 24),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                loc.t('mods.keybinds.title', params: {'name': mod.name}),
                style: const TextStyle(fontSize: 18),
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: 400,
          child: SingleChildScrollView(
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: validKeybinds.map((keybind) {
                return InkWell(
                  onTap: () {
                    Navigator.pop(context);
                    _showEditKeybindDialog(mod, keybind);
                  },
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          const Color(0xFF1E293B).withOpacity(0.8),
                          const Color(0xFF0F172A).withOpacity(0.9),
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: const Color(0xFF334155),
                        width: 1.5,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          keybind.displayName,
                          style: const TextStyle(
                            color: Color(0xFFE2E8F0),
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFF0F172A),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: const Color(0xFFFBBF24).withOpacity(0.3),
                              width: 1.5,
                            ),
                          ),
                          child: Text(
                            keybind.keyValue ?? '',
                            style: const TextStyle(
                              color: Color(0xFFFBBF24),
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              fontFamily: 'monospace',
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        const Icon(
                          Icons.edit_outlined,
                          size: 14,
                          color: Color(0xFF94A3B8),
                        ),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(loc.t('mods.keybinds.close')),
          ),
        ],
      ),
    );
  }

  void _showContextMenu(BuildContext context, ModInfo mod, Offset position) {
    showMenu(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: [
        PopupMenuItem(
          child: Row(
            children: [
              const Icon(Icons.info_outline, size: 18),
              const SizedBox(width: 8),
              Text(loc.t('mods.context_menu.details')),
            ],
          ),
          onTap: () {
            Future.delayed(Duration.zero, () => _showModDetailsDialog(mod));
          },
        ),
        PopupMenuItem(
          child: Row(
            children: [
              const Icon(Icons.edit, size: 18),
              const SizedBox(width: 8),
              Text(loc.t('mods.context_menu.edit')),
            ],
          ),
          onTap: () {
            Future.delayed(Duration.zero, () => _showEditDialog(mod));
          },
        ),
        PopupMenuItem(
          child: Row(
            children: [
              const Icon(Icons.drive_file_rename_outline, size: 18),
              const SizedBox(width: 8),
              Text(loc.t('mods.context_menu.rename')),
            ],
          ),
          onTap: () {
            Future.delayed(Duration.zero, () => _showRenameDialog(mod));
          },
        ),
        PopupMenuItem(
          child: Row(
            children: [
              const Icon(Icons.folder_open, size: 18),
              const SizedBox(width: 8),
              Text(loc.t('mods.context_menu.open_folder')),
            ],
          ),
          onTap: () {
            Future.delayed(Duration.zero, () => _openModFolder(mod));
          },
        ),
        // Відкрити сторінку джерела, якщо вказано посилання
        if (mod.sourceUrl != null && mod.sourceUrl!.isNotEmpty)
          PopupMenuItem(
            child: Row(
              children: [
                const Icon(Icons.open_in_new, size: 18),
                const SizedBox(width: 8),
                Text(loc.t('mods.context_menu.open_link')),
              ],
            ),
            onTap: () {
              Future.delayed(Duration.zero, () => _openModLink(mod));
            },
          ),
        // Показати keybinds якщо є
        if (mod.keybinds != null && mod.keybinds!.isNotEmpty)
          PopupMenuItem(
            child: Row(
              children: [
                const Icon(Icons.keyboard_outlined, size: 18),
                const SizedBox(width: 8),
                Text(
                  loc.t(
                    'mods.context_menu.edit_keybinds',
                    params: {'count': '${mod.keybinds!.length}'},
                  ),
                ),
              ],
            ),
            onTap: () {
              Future.delayed(Duration.zero, () => _showKeybindsDialog(mod));
            },
          ),
        PopupMenuItem(
          child: Row(
            children: [
              Icon(mod.isFavorite ? Icons.star : Icons.star_border, size: 18),
              const SizedBox(width: 8),
              Text(
                mod.isFavorite
                    ? loc.t('mods.context_menu.favorite_remove')
                    : loc.t('mods.context_menu.favorite_add'),
              ),
            ],
          ),
          onTap: () {
            Future.delayed(Duration.zero, () => _toggleFavorite(mod));
          },
        ),
        PopupMenuItem(
          child: Row(
            children: [
              const Icon(Icons.delete_outline, size: 18, color: Colors.red),
              const SizedBox(width: 8),
              Text(
                loc.t('mods.context_menu.delete'),
                style: const TextStyle(color: Colors.red),
              ),
            ],
          ),
          onTap: () {
            Future.delayed(Duration.zero, () => _showDeleteDialog(mod));
          },
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final characters = ref.watch(charactersProvider);
    final selectedIndex = ref.watch(selectedCharacterIndexProvider);
    final currentSkins = ref.watch(currentCharacterSkinsProvider);
    final isDarkMode = ref.watch(isDarkModeProvider);

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
                          color: const Color(0xFF0EA5E9).withOpacity(0.3),
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
                      ? Colors.white.withOpacity(0.1)
                      : Colors.black.withOpacity(0.05),
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
                          ).withOpacity(0.1),
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
                      _buildAutoF10Toggle(),
                      const SizedBox(width: 12),
                      _buildRefreshModsButton(),
                      const SizedBox(width: 12),
                      // F10 Reload button
                      _buildF10ReloadButton(),
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
          // toolbar, not the whole screen.
          if (currentSkins.isNotEmpty) const ModsToolbar(),

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
                      ).withOpacity(0.1),
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
                                        child: _buildAddModCard(),
                                      ),
                                    ],
                                  ),
                                )
                              : (_isFiltering && visibleSkins.isEmpty)
                              ? _buildNoResults()
                              : isAllView
                              ? _buildGroupedModsView(visibleSkins)
                              : _OwnScrollController(
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
                                                  child: _buildAddModCard(),
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

  /// Section separator/identifier for a group in the grouped "ALL" view —
  /// renders as `▾ ── Label (count) ─────────────`. The whole row is clickable
  /// to collapse/expand the group.
  Widget _buildSectionHeader(
    String label,
    int count, {
    required bool collapsed,
    required VoidCallback onToggle,
  }) {
    final isDarkMode = ref.read(isDarkModeProvider);
    final lineColor = isDarkMode
        ? Colors.white.withOpacity(0.15)
        : Colors.black.withOpacity(0.12);
    final textColor = isDarkMode
        ? Colors.white.withOpacity(0.85)
        : Colors.black.withOpacity(0.72);
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: AppConstants.smallPadding,
        vertical: 4,
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onToggle,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
            child: Row(
              children: [
                AnimatedRotation(
                  turns: collapsed ? -0.25 : 0,
                  duration: const Duration(milliseconds: 150),
                  child: Icon(
                    Icons.keyboard_arrow_down,
                    size: 22,
                    color: textColor,
                  ),
                ),
                const SizedBox(width: 6),
                SizedBox(
                  width: 16,
                  child: Divider(color: lineColor, thickness: 1.5),
                ),
                const SizedBox(width: 12),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: textColor,
                    letterSpacing: 0.3,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: lineColor,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '$count',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: textColor,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(child: Divider(color: lineColor, thickness: 1.5)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The "ALL" tab: cards grouped by character, each group preceded by a
  /// section header. Group order follows the canonical roster; mods with no
  /// known character fall into a trailing "Other" group. Within-group order
  /// honours the active sort, and empty groups simply don't appear (so the
  /// active filter naturally hides them).
  Widget _buildGroupedModsView(List<ModInfo> visibleSkins) {
    final groups = <String, List<ModInfo>>{};
    for (final mod in visibleSkins) {
      final id = mod.characterId.isEmpty
          ? '__other__'
          : mod.characterId.toLowerCase();
      groups.putIfAbsent(id, () => []).add(mod);
    }

    // Built-in categories first, then the character roster, then any unknown
    // ids (alpha), then "Other".
    final orderedIds = <String>[
      for (final cat in builtInCategories)
        if (groups.containsKey(cat.id)) cat.id,
      for (final id in zzzCharacterIds)
        if (groups.containsKey(id)) id,
    ];
    final leftover =
        groups.keys
            .where(
              (id) =>
                  id != '__other__' &&
                  !zzzCharacterIds.contains(id) &&
                  !isBuiltInCategory(id),
            )
            .toList()
          ..sort();
    orderedIds.addAll(leftover);
    if (groups.containsKey('__other__')) orderedIds.add('__other__');

    const gridDelegate = SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: 6,
      childAspectRatio: 0.7,
      crossAxisSpacing: 16,
      mainAxisSpacing: 16,
    );

    final slivers = <Widget>[
      const SliverToBoxAdapter(child: SizedBox(height: 8)),
    ];
    for (final id in orderedIds) {
      final mods = groups[id]!;
      final label = id == '__other__'
          ? loc.t('mods.uncategorized')
          : categoryDisplayName(id, loc);
      final collapsed = _collapsedGroups.contains(id);
      slivers.add(
        SliverToBoxAdapter(
          child: _buildSectionHeader(
            label,
            mods.length,
            collapsed: collapsed,
            onToggle: () => setState(() {
              if (!_collapsedGroups.remove(id)) _collapsedGroups.add(id);
            }),
          ),
        ),
      );
      if (collapsed) continue;
      slivers.add(
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            AppConstants.smallPadding,
            0,
            AppConstants.smallPadding,
            12,
          ),
          sliver: SliverGrid(
            gridDelegate: gridDelegate,
            delegate: SliverChildBuilderDelegate((context, index) {
              final mod = mods[index];
              return AnimationConfiguration.staggeredGrid(
                key: ValueKey('mod_${mod.id}_${mod.isActive}'),
                position: index,
                columnCount: 6,
                duration: const Duration(milliseconds: 500),
                child: ScaleAnimation(
                  scale: 0.5,
                  curve: Curves.easeOutBack,
                  child: FadeInAnimation(
                    curve: Curves.easeOut,
                    child: _buildModCard(mod),
                  ),
                ),
              );
            }, childCount: mods.length),
          ),
        ),
      );
    }

    // Trailing "Add" card, hidden while filtering to match the flat grid.
    if (!_isFiltering) {
      slivers.add(
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            AppConstants.smallPadding,
            0,
            AppConstants.smallPadding,
            8,
          ),
          sliver: SliverGrid(
            gridDelegate: gridDelegate,
            delegate: SliverChildListDelegate([_buildAddModCard()]),
          ),
        ),
      );
    }

    return _OwnScrollController(
      builder: (context, scrollController) => AnimationLimiter(
        child: ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(
            dragDevices: {
              PointerDeviceKind.touch,
              PointerDeviceKind.mouse,
              PointerDeviceKind.trackpad,
              PointerDeviceKind.stylus,
            },
            physics: const BouncingScrollPhysics(),
          ),
          child: CustomScrollView(
            controller: scrollController,
            slivers: slivers,
          ),
        ),
      ),
    );
  }

  Widget _buildNoResults() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.search_off, size: 64, color: Colors.grey[400]),
          const SizedBox(height: 16),
          Text(
            loc.t('mods.toolbar.no_results'),
            style: TextStyle(fontSize: 16, color: Colors.grey[600]),
          ),
          const SizedBox(height: 12),
          TextButton.icon(
            onPressed: () => clearModFilters(ref),
            icon: const Icon(Icons.clear, size: 18),
            label: Text(loc.t('mods.toolbar.clear_filters')),
          ),
        ],
      ),
    );
  }

  Widget _buildAddModCard() {
    final isDarkMode = ref.watch(isDarkModeProvider);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: _showImportDialog,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: _isDragging
                  ? [
                      const Color(0xFF0EA5E9).withOpacity(0.3),
                      const Color(0xFF06B6D4).withOpacity(0.3),
                    ]
                  : [
                      isDarkMode
                          ? const Color(0xFF1F2937).withOpacity(0.5)
                          : const Color(0xFFF9FAFB),
                      isDarkMode
                          ? const Color(0xFF111827).withOpacity(0.5)
                          : const Color(0xFFF3F4F6),
                    ],
            ),
            border: Border.all(
              color: _isDragging
                  ? const Color(0xFF0EA5E9)
                  : isDarkMode
                  ? Colors.white.withOpacity(0.1)
                  : Colors.black.withOpacity(0.08),
              width: _isDragging ? 2.5 : 2,
              strokeAlign: BorderSide.strokeAlignInside,
            ),
            boxShadow: _isDragging
                ? [
                    BoxShadow(
                      color: const Color(0xFF0EA5E9).withOpacity(0.3),
                      blurRadius: 20,
                      spreadRadius: 2,
                    ),
                  ]
                : [
                    BoxShadow(
                      color: isDarkMode
                          ? Colors.black.withOpacity(0.2)
                          : Colors.grey.withOpacity(0.1),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
          ),
          child: Container(
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(19)),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: _isDragging
                        ? const Color(0xFF0EA5E9).withOpacity(0.2)
                        : (isDarkMode
                              ? Colors.white.withOpacity(0.05)
                              : Colors.black.withOpacity(0.03)),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    _isDragging ? Icons.file_download : Icons.add,
                    size: 48,
                    color: _isDragging
                        ? const Color(0xFF0EA5E9)
                        : (isDarkMode
                              ? Colors.white.withOpacity(0.6)
                              : Colors.black.withOpacity(0.4)),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  _isDragging
                      ? loc.t('mods.empty.prompt')
                      : loc.t('mods.empty.cta'),
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: _isDragging
                        ? const Color(0xFF0EA5E9)
                        : (isDarkMode
                              ? Colors.white.withOpacity(0.7)
                              : Colors.black.withOpacity(0.6)),
                  ),
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    _isDragging
                        ? loc.t('mods.empty.add_folders')
                        : loc.t('mods.empty.drag'),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      color: isDarkMode
                          ? Colors.white.withOpacity(0.5)
                          : Colors.black.withOpacity(0.4),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
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
                ).withOpacity(0.3),
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
                        )
                      : Container(
                          color: Colors.grey.withOpacity(0.1),
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
            onOpenLink: () => _openModLink(mod),
          ),
        ),
      ),
    );
  }

  bool _charactersActuallyChanged(List<CharacterInfo> newCharacters) {
    if (_lastCharactersState == null) return true;
    if (_lastCharactersState!.length != newCharacters.length) return true;

    for (int i = 0; i < newCharacters.length; i++) {
      final oldChar = _lastCharactersState![i];
      final newChar = newCharacters[i];

      if (oldChar.id != newChar.id ||
          oldChar.name != newChar.name ||
          oldChar.skins.length != newChar.skins.length) {
        return true;
      }

      // Check if any mod states changed (including editable metadata, so edits
      // to URL/description/tags/images refresh the in-memory state).
      for (int j = 0; j < newChar.skins.length; j++) {
        final oldMod = oldChar.skins[j];
        final newMod = newChar.skins[j];
        if (oldMod.id != newMod.id ||
            oldMod.isActive != newMod.isActive ||
            oldMod.name != newMod.name ||
            oldMod.isFavorite != newMod.isFavorite ||
            oldMod.characterId != newMod.characterId ||
            oldMod.sourceUrl != newMod.sourceUrl ||
            oldMod.description != newMod.description ||
            oldMod.imagePath != newMod.imagePath ||
            !listEquals(oldMod.tags, newMod.tags) ||
            !listEquals(oldMod.images, newMod.images)) {
          return true;
        }
      }
    }

    return false;
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
            folderPaths.addAll(result.extractedFolders!);
            tempFoldersToCleanup.addAll(result.extractedFolders!);
            successfullyExtractedArchives.add(archiveFile.path);
            final archiveBaseName = path.basenameWithoutExtension(
              archiveFile.path,
            );
            for (final folder in result.extractedFolders!) {
              detectionHints[folder] = archiveBaseName;
            }
            print(
              'ModsScreen: Розархівовано ${result.extractedFolders!.length} папок з ${archiveFile.name}',
            );
          } else {
            print(
              'ModsScreen: Помилка розархівування ${archiveFile.name}: ${result.error}',
            );
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    'Помилка розархівування ${archiveFile.name}: ${result.error}',
                  ),
                  backgroundColor: Colors.orange,
                ),
              );
            }
          }
        }
      }

      if (folderPaths.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(loc.t('mods.snackbar.import_no_folders')),
              backgroundColor: Colors.orange,
            ),
          );
        }
        return;
      }

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
                        'count': folderPaths.length.toString(),
                        'plural': folderPaths.length == 1
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
      final (importedMods, autoTags) = await modManagerService.importMods(
        folderPaths,
        detectionHints: detectionHints,
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
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  const Icon(Icons.info_outline, color: Colors.white, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(loc.t('mods.snackbar.import_duplicates')),
                  ),
                ],
              ),
              backgroundColor: Colors.orange,
              duration: const Duration(seconds: 3),
            ),
          );
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
                      color: const Color(0xFF0EA5E9).withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: const Color(0xFF0EA5E9).withOpacity(0.3),
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.error_outline, color: Colors.white, size: 20),
                const SizedBox(width: 8),
                Expanded(child: Text('Помилка імпорту: $e')),
              ],
            ),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 4),
          ),
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
                color: const Color(0xFF0EA5E9).withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: const Color(0xFF0EA5E9).withOpacity(0.3),
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
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(loc.t('clipboard.empty')),
              backgroundColor: Colors.orange,
            ),
          );
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
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(loc.t('clipboard.no_paths')),
              backgroundColor: Colors.orange,
            ),
          );
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
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(loc.t('clipboard.no_valid')),
              backgroundColor: Colors.orange,
            ),
          );
        }
        return;
      }

      // Імпортуємо папки
      await _importModsFromFolders(validFolders);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              loc.t(
                'mods.snackbar.paste_error',
                params: {'message': e.toString()},
              ),
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }
}

/// Gives its [builder] a private [ScrollController] tied to this element's
/// lifetime. The mods grid and the grouped view live inside an
/// [AnimatedSwitcher], so during a tab transition the outgoing and incoming
/// lists are briefly mounted together; a shared controller would then have two
/// ScrollPositions, which the desktop Scrollbar forbids. A controller per
/// instance keeps each list's position independent.
class _OwnScrollController extends StatefulWidget {
  const _OwnScrollController({required this.builder});

  final Widget Function(BuildContext context, ScrollController controller)
  builder;

  @override
  State<_OwnScrollController> createState() => _OwnScrollControllerState();
}

class _OwnScrollControllerState extends State<_OwnScrollController> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _controller);
}

/// A blockquote syntax that flattens consecutive `>` markers into a single
/// quote level. CommonMark treats `>>>>>` as five *nested* blockquotes; mod
/// descriptions use runs of `>` decoratively (e.g. `>>>>> NOTE <<<<<`), so we
/// strip every leading marker and render one quote level instead of N.
///
/// Passed to [MarkdownBody.blockSyntaxes], where it is tried before the
/// built-in [md.BlockquoteSyntax] and wins on the same `>` lines.
class _FlatBlockquoteSyntax extends md.BlockquoteSyntax {
  const _FlatBlockquoteSyntax();

  // Any remaining leading `>` markers (each with an optional following space)
  // after the base parser has already stripped the first one.
  static final _extraMarkers = RegExp(r'^[ ]{0,3}(?:>[ \t]?)+');

  @override
  md.Node parse(md.BlockParser parser) {
    // The base implementation strips only the first `>` from each line; remove
    // the rest so the recursive parse can't build nested blockquotes.
    final childLines = parseChildLines(parser)
        .map((line) => md.Line(line.content.replaceFirst(_extraMarkers, '')))
        .toList();
    final children = md.BlockParser(
      childLines,
      parser.document,
    ).parseLines(parentSyntax: this);
    return md.Element('blockquote', children);
  }
}

/// Parses GitHub-style alerts — a `> [!TYPE]` line followed by `>`-prefixed
/// body lines — into an `alert` element carrying the type and the raw body
/// markdown. Rendered by [_AlertElementBuilder]. Also accepts a non-standard
/// `[!INFO]` type (GitHub has no such alert); people unfamiliar with GitHub's
/// flavour commonly reach for `INFO` over `NOTE`, so it renders identically to
/// `[!NOTE]`.
///
/// The body is kept as raw markdown (rather than pre-parsed AST children)
/// because a custom block builder replaces the auto-built children; the builder
/// re-renders the body in a nested [MarkdownBody] so links/bold/lists work.
class _AlertBlockSyntax extends md.BlockSyntax {
  const _AlertBlockSyntax();

  // The opener line: `> [!NOTE]` and friends (case-insensitive).
  static final _opener = RegExp(
    r'^\s{0,3}>\s{0,3}\\?\[!(note|tip|important|caution|warning|info)\\?\]\s*$',
    caseSensitive: false,
  );
  static final _quoteLine = RegExp(r'^\s{0,3}>');
  static final _quoteMarker = RegExp(r'^\s{0,3}>[ \t]?');

  @override
  RegExp get pattern => _opener;

  @override
  bool canParse(md.BlockParser parser) =>
      _opener.hasMatch(parser.current.content);

  @override
  md.Node parse(md.BlockParser parser) {
    final type = _opener
        .firstMatch(parser.current.content)!
        .group(1)!
        .toLowerCase();
    parser.advance(); // consume the `[!TYPE]` marker line

    // Collect the following `>`-prefixed lines as the raw body, stripping the
    // leading marker (and one optional space) from each.
    final bodyLines = <String>[];
    while (!parser.isDone) {
      final content = parser.current.content;
      if (!_quoteLine.hasMatch(content)) break;
      bodyLines.add(content.replaceFirst(_quoteMarker, ''));
      parser.advance();
    }

    return md.Element('alert', <md.Node>[])
      ..attributes['type'] = type
      ..attributes['body'] = bodyLines.join('\n');
  }
}

/// Visual spec for one alert type: label, icon, and accent colour.
class _AlertSpec {
  const _AlertSpec(this.title, this.icon, this.color);
  final String title;
  final IconData icon;
  final Color color;
}

const Map<String, _AlertSpec> _alertSpecs = {
  'note': _AlertSpec('Note', Icons.info_outline, Color(0xFF3B82F6)),
  'info': _AlertSpec('Info', Icons.info_outline, Color(0xFF3B82F6)),
  'tip': _AlertSpec('Tip', Icons.lightbulb_outline, Color(0xFF22C55E)),
  'important': _AlertSpec(
    'Important',
    Icons.campaign_outlined,
    Color(0xFF8B5CF6),
  ),
  'warning': _AlertSpec(
    'Warning',
    Icons.warning_amber_rounded,
    Color(0xFFF59E0B),
  ),
  'caution': _AlertSpec('Caution', Icons.report_outlined, Color(0xFFEF4444)),
};

/// Renders an `alert` element (see [_AlertBlockSyntax]) as a coloured callout
/// with an icon, a title, and the body rendered as nested markdown.
class _AlertElementBuilder extends MarkdownElementBuilder {
  _AlertElementBuilder({required this.onTapLink, required this.styleSheet});

  final void Function(String href) onTapLink;
  final MarkdownStyleSheet styleSheet;

  @override
  bool isBlockElement() => true;

  @override
  Widget visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final spec = _alertSpecs[element.attributes['type']] ?? _alertSpecs['note']!;
    final body = element.attributes['body'] ?? '';

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: spec.color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
        border: Border(left: BorderSide(color: spec.color, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(spec.icon, size: 16, color: spec.color),
              const SizedBox(width: 6),
              Text(
                spec.title,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: spec.color,
                ),
              ),
            ],
          ),
          if (body.trim().isNotEmpty) ...[
            const SizedBox(height: 4),
            MarkdownBody(
              data: body,
              selectable: true,
              shrinkWrap: true,
              softLineBreak: true,
              // Allow runs of `>` inside an alert body, but not nested alerts.
              blockSyntaxes: const [_FlatBlockquoteSyntax()],
              onTapLink: (text, href, title) {
                if (href != null) onTapLink(href);
              },
              styleSheet: styleSheet,
            ),
          ],
        ],
      ),
    );
  }
}
