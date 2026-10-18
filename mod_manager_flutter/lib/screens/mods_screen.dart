import 'dart:async';
import 'dart:io';

import 'package:cross_file/cross_file.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;

import '../core/constants.dart';
import '../core/palette.dart';
import '../l10n/app_localizations.dart';
import '../models/character_info.dart';
import '../models/mod_download.dart';
import '../models/mod_origin_seed.dart';
import '../services/api_service.dart';
import '../services/archive_service.dart';
import '../services/import_result.dart';
import '../services/ingest_origin_builder.dart';
import '../services/log/logger.dart';
import '../services/shader_fixes/shader_fixes_service.dart';
import '../services/update_apply/mod_activation_port.dart';
import '../services/update_apply/update_applier.dart';
import '../utils/notifications.dart';
import '../utils/state_providers.dart';
import 'components/folder_downloads_summary.dart';
import '../utils/url_utils.dart';
import '../utils/zzz_characters.dart';
import 'components/character_hero.dart';
import 'components/character_list.dart';
import 'components/character_tile.dart';
import 'components/import_failure_message.dart';
import 'components/install_result_feedback.dart';
import 'components/mod_card_widget.dart';
import 'components/mod_details_panel.dart';
import 'components/mods_toolbar.dart';
import 'components/shader_fixes_notices.dart';
import 'components/zenith_controls.dart';
import 'dialogs/delete_mod_dialog.dart';
import 'dialogs/duplicate_archive_dialog.dart';
import 'dialogs/edit_mod_dialog.dart';
import 'dialogs/import_selection_dialog.dart';
import 'dialogs/keybinds_dialog.dart';
import 'dialogs/mod_backups_dialog.dart';
import 'dialogs/mod_context_menu.dart';
import 'dialogs/mod_update_dialog.dart';
import 'dialogs/patch_install_flow.dart';
import 'dialogs/reinstall_flow.dart';
import 'dialogs/remove_patch_flow.dart';
import 'dialogs/rename_mod_dialog.dart';
import 'dialogs/resolve_origin_dialog.dart';

final Logger _log = Logger('mods');
final Logger _files = Logger('fileops');

/// The Library's character view: the character list, the character on screen with their mods, and the details
/// panel for the mod selected among them (`docs/library-screen.md`).
///
/// Everything another surface needs lives in providers ([selectedCharacterIdProvider], [selectedModIdProvider],
/// the filters), because this page is disposed on every page switch.
class ModsScreen extends ConsumerStatefulWidget {
  const ModsScreen({super.key});

  @override
  ConsumerState<ModsScreen> createState() => _ModsScreenState();
}

class _ModsScreenState extends ConsumerState<ModsScreen> {
  AppLocalizations get loc => context.loc;
  String? errorMessage;

  // Prevent multiple simultaneous operations
  bool _isOperationInProgress = false;
  bool _isLoadingMods = false;

  // Drag & drop state
  bool _isDragging = false;

  final FocusNode _focusNode = FocusNode();
  final GlobalKey _panelKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_reclaimFocus);
    loadMods();
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_reclaimFocus);
    _focusNode.dispose();
    super.dispose();
  }

  /// Takes keyboard focus back when it falls to the page's own route scope, as it does when a click leaves a text
  /// field. Up there the page's own key handler is below it, so Ctrl+V would reach nothing until a Tab brought it
  /// back.
  ///
  /// Only that scope. Focus at the root of the app is the window being inactive: Flutter parks it there and hands
  /// it back to the field or dialog that had it when the window returns, which taking it here would prevent. And
  /// not while a dialog or another route is above the page.
  void _reclaimFocus() {
    final primary = FocusManager.instance.primaryFocus;
    if (primary == null || primary == _focusNode || primary == FocusManager.instance.rootScope) return;
    if (!_focusNode.ancestors.contains(primary)) return;
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || FocusManager.instance.primaryFocus != primary) return;
      if (!(ModalRoute.of(context)?.isCurrent ?? true)) return;
      _focusNode.requestFocus();
    });
  }

  Future<void> loadMods() async {
    // Prevent multiple simultaneous load operations
    if (_isLoadingMods) return;
    _isLoadingMods = true;
    if (errorMessage != null) setState(() => errorMessage = null);

    try {
      // The scan itself belongs to `libraryProvider`, which outlives this
      // screen; everything on it is derived from the library.
      await ref.read(libraryProvider.notifier).rescan();
      final library = ref.read(libraryProvider);
      if (library.hasError) {
        // With the scan's own stack: the error crossed a provider boundary to
        // get here, and a bare `throw` would start the trace at this line —
        // pointing at the screen for a failure that happened on the disk.
        Error.throwWithStackTrace(library.error!, library.stackTrace!);
      }

      // Reported here because the scan is the only thing that runs the backfill.
      await _reportBackfillWriteFailures();
    } catch (e) {
      if (mounted) setState(() => errorMessage = e.toString());
    } finally {
      _isLoadingMods = false;
    }
  }

  /// Says which mods the scan could not record an identity for.
  ///
  /// Shares the ingest path's wording: the user's loss is the same either way,
  /// and which of our two writers hit the read-only folder is our business.
  Future<void> _reportBackfillWriteFailures() async {
    final service = await ref.read(modManagerServiceProvider.future);
    final failures = service.takeBackfillWriteFailures();
    if (failures.isEmpty || !mounted) return;

    context.notify.warning(
      context.loc.t('mods.snackbar.origin_write_failed_title'),
      body: context.loc.t(
        'mods.snackbar.origin_write_failed_body',
        params: {'mods': failures.join(', ')},
      ),
    );
  }

  /// The library as it stands, to edit a copy of. Null before the first scan
  /// has landed, so callers can fall back to a full [loadMods].
  List<ModInfo>? _currentAllMods() {
    final mods = ref.read(libraryProvider).valueOrNull;
    return mods == null ? null : List<ModInfo>.from(mods);
  }

  /// Publishes an edited library without a disk rescan.
  ///
  /// Backs the targeted handlers (rename/edit/favorite/delete/toggle) so a
  /// single-mod action costs O(1) instead of an O(N) rescan of every mod.
  void _publish(List<ModInfo> allMods) {
    ref.read(libraryProvider.notifier).put(allMods);
  }

  /// Files [mod] under a row of the character list: what dropping its card on that row does.
  Future<void> _retag(ModInfo mod, String groupId) async {
    final notify = context.notify;
    final failedTitle = loc.t('library.card.retag_failed_title');
    final saving = notify.pinned(
      loc.t('mods.dialog.saving_tag'),
      body: mod.name,
      characterId: isOtherType(groupId) ? null : groupId,
    );
    try {
      // Writes the in-folder sidecar (rename-safe) and mirrors to config.json.
      final moved = await ApiService.setModCharacter(mod.id, groupId == unknownCharacterId ? '' : groupId);
      if (!moved) notify.error(failedTitle, body: mod.name, characterId: mod.characterId);
      await loadMods();
    } catch (e) {
      notify.error(failedTitle, body: mod.name, characterId: mod.characterId);
    } finally {
      saving.dismiss();
    }
  }

  /// Reflects a completed rename in the UI without a rescan. The folder op and
  /// the service's state migration (active link, config keys, keybind cache)
  /// already happened; only the library needs the id/name swap — plus a rewrite
  /// of the cached image paths, which are absolute and still point at the old
  /// folder (otherwise the thumbnail can't load until a refresh).
  Future<void> _onModRenamed(String oldId, String newName) async {
    final allMods = _currentAllMods();
    final index = allMods?.indexWhere((m) => m.id == oldId) ?? -1;
    final modsPath =
        (await ref.read(modManagerServiceProvider.future)).modsPath;
    if (allMods == null || index == -1 || modsPath == null || !mounted) {
      unawaited(loadMods());
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
    final selected = ref.read(selectedModIdProvider.notifier);
    if (selected.state == oldId) selected.state = newName;
    _publish(allMods);
  }

  /// Reflects a saved edit in the UI without a rescan. [updated] carries the
  /// edited fields (character, description, tags, images) already written to
  /// disk; a character change moves the mod to another row of the list.
  void _onModEdited(ModInfo updated) {
    final allMods = _currentAllMods();
    final index = allMods?.indexWhere((m) => m.id == updated.id) ?? -1;
    if (allMods == null || index == -1) {
      unawaited(loadMods());
      return;
    }
    final existing = allMods[index];
    // The character the user picked, as the scan reads it: "none" stays none rather than a guess from the name.
    final charId = updated.characterId;
    // Rebuild explicitly (not copyWith) so cleared fields — a removed cover or
    // an emptied description — actually reset instead of keeping stale values.
    allMods[index] = ModInfo(
      id: updated.id,
      name: updated.name,
      characterId: charId,
      isActive: existing.isActive,
      imagePath: updated.images.isNotEmpty ? updated.images.first : null,
      description: updated.description,
      tags: updated.tags,
      images: updated.images,
      isFavorite: existing.isFavorite,
      keybinds: existing.keybinds,
      origin: existing.origin,
      uid: existing.uid,
    );
    _publish(allMods);
  }

  /// Removes a deleted mod from the UI without a rescan (its folder and state
  /// are already gone).
  void _onModDeleted(String modId) {
    final selected = ref.read(selectedModIdProvider.notifier);
    if (selected.state == modId) selected.state = null;
    final allMods = _currentAllMods();
    if (allMods == null) {
      unawaited(loadMods());
      return;
    }
    allMods.removeWhere((m) => m.id == modId);
    _publish(allMods);
  }

  /// Turns [mod] on or off. Turning one on under a character whose One at a time switch is on turns the
  /// character's other mods off first (`docs/library-screen.md` §10).
  Future<void> toggleMod(ModInfo mod) async {
    if (_isOperationInProgress) return;
    _isOperationInProgress = true;

    try {
      final switchOff = modsToSwitchOff(ref.read(modsProvider), mod, ref.read(oneAtATimeProvider));

      final notify = context.notify;
      final failedTitle = loc.t(mod.isActive ? 'library.card.disable_failed_title' : 'library.card.enable_failed_title');
      final done = mod.isActive
          ? await ApiService.disableMod(mod.id)
          : await ApiService.enableMod(mod.id, switchOff: switchOff);
      if (!done) {
        // Said before the rescan, which then shows what is really on: with One at a time, the others may already
        // be off.
        notify.error(failedTitle, body: mod.name, characterId: mod.characterId);
        await loadMods();
        return;
      }

      // Flip the flags in the library rather than rescanning: the toggle is one
      // link, plus the set of mods the enable just turned off.
      final allMods = _currentAllMods();
      if (mounted && allMods != null) {
        _publish([
          for (final candidate in allMods)
            if (candidate.id == mod.id)
              candidate.copyWith(isActive: !mod.isActive)
            else if (switchOff.contains(candidate.id))
              candidate.copyWith(isActive: false)
            else
              candidate,
        ]);
      }
    } on ShaderPlacementRefused catch (refusal) {
      if (mounted) {
        notifyShaderRefusal(context, refusal, characterId: mod.characterId);
        // The dry run passed and the enable was still refused, possibly after
        // the character's other mods were turned off: the cards must show that.
        await loadMods();
      }
    } catch (e) {
      if (mounted) {
        context.notify.error(
          loc.t('mods.errors.generic_title'),
          body: e.toString(),
          characterId: mod.characterId,
        );
        await loadMods();
      }
    } finally {
      _isOperationInProgress = false;
    }
  }

  Future<void> _toggleFavorite(ModInfo mod) async {
    try {
      final notify = context.notify;
      final failedTitle = loc.t('library.card.favorite_failed_title');
      final configService = await ApiService.getConfigService();
      final saved = mod.isFavorite
          ? await configService.removeFavoriteMod(mod.id)
          : await configService.addFavoriteMod(mod.id);
      // The star still follows the press for this session; what failed is keeping it past a restart.
      if (!saved) notify.error(failedTitle, body: mod.name, characterId: mod.characterId);

      // Targeted update: flip the one mod's favorite flag instead of rescanning.
      final allMods = _currentAllMods();
      final index = allMods?.indexWhere((m) => m.id == mod.id) ?? -1;
      if (allMods != null && index != -1) {
        allMods[index] = allMods[index].copyWith(isFavorite: !mod.isFavorite);
        _publish(allMods);
      } else {
        await loadMods();
      }
    } catch (e) {
      if (mounted) {
        context.notify.error(
          loc.t('mods.errors.generic_title'),
          body: e.toString(),
          characterId: mod.characterId,
        );
      }
    }
  }

  /// A manual refresh re-reads everything from disk, including .ini files that
  /// may have changed outside the app.
  Future<void> _refreshModsList() async {
    if (_isLoadingMods) return;
    await ApiService.clearKeybindCache();
    await loadMods();
  }

  Future<void> _openModFolder(ModInfo mod) async {
    final notify = context.notify;
    try {
      final ok = await ApiService.openModFolder(mod.id);
      if (!mounted || ok) return;
      notify.error(
        loc.t('mods.snackbar.open_folder_failed_title'),
        body: mod.name,
        characterId: mod.characterId,
      );
    } catch (e) {
      if (!mounted) return;
      notify.error(
        loc.t('mods.errors.generic_title'),
        body: e.toString(),
        characterId: mod.characterId,
      );
    }
  }

  void _showEditDialog(ModInfo mod) {
    showEditModDialog(context, mod, onSaved: _onModEdited);
  }

  void _select(ModInfo mod) => ref.read(selectedModIdProvider.notifier).state = mod.id;

  /// Opens the resolve dialog and rescans if it wrote anything — the status
  /// badge is drawn from `ModInfo.origin`, which only a scan refreshes.
  Future<void> _resolveOrigin(ModInfo mod) async {
    if (await showResolveOriginDialog(context, mod)) {
      await loadMods();
    }
  }

  /// Opens the update dialog and rescans if it wrote anything — dismissing an
  /// update lands in the origin block, which only a scan re-reads.
  Future<void> _checkForUpdate(ModInfo mod) async {
    if (await showModUpdateDialog(context, mod)) {
      await loadMods();
    }
  }

  /// Asks, then deletes the mod and every saved version of it.
  ///
  /// The count is read here rather than in the dialog: it is one `readdir` of
  /// the mod's own group, and the confirmation must say how much history the
  /// delete takes with it — the only place the user could otherwise find that
  /// out is the entry that stops existing.
  Future<void> _deleteMod(ModInfo mod) async {
    final saved =
        (await ref.read(snapshotServiceProvider).list(mod.uid)).length;
    if (!mounted) return;
    await showDeleteModDialog(
      context,
      mod,
      savedVersions: saved,
      onDeleted: () {
        _onModDeleted(mod.id);
        // The group is gone with the mod, so the cached set of uids that have
        // one is stale — and it is what decides whether a *rollback* entry is
        // offered on every other card.
        ref.invalidate(modBackupsProvider);
      },
    );
  }

  /// Writes the version already installed over the folder again, and rescans:
  /// the files change even though the recorded version does not.
  Future<void> _reinstall(ModInfo mod) async {
    if (await reinstallFlow(context, ref, mod: mod)) {
      await loadMods();
    }
  }

  /// Opens the rollback list and rescans if anything was restored — the folder
  /// itself changes, not just the sidecar.
  Future<void> _restoreBackup(ModInfo mod) async {
    if (await showModBackupsDialog(context, mod)) {
      await loadMods();
    }
  }

  /// Takes one patch back out of a folder and rescans, since the card's status
  /// badge is drawn from `ModInfo.origin`.
  ///
  /// The name comes from what the session already fetched or the layer saved,
  /// falling back to the id: a page fetch on the way into a confirmation would
  /// be a request the user did not ask for.
  Future<void> _removePatch(ModInfo mod, ModDownload patch) async {
    final name = downloadName(context.loc, patch,
        folderName: mod.name,
        fetched: ref.read(knownModPagesProvider)[patch.modId]?.name);
    if (await removePatchFlow(context, ref,
        mod: mod, patch: patch, patchName: name)) {
      await loadMods();
    }
  }

  void _showContextMenu(BuildContext context, ModInfo mod, Offset position) {
    showModContextMenu(
      context,
      mod,
      position,
      onResolveOrigin: () => unawaited(_resolveOrigin(mod)),
      onCheckForUpdate: () => unawaited(_checkForUpdate(mod)),
      onReinstall: () => unawaited(_reinstall(mod)),
      onRestoreBackup: () => unawaited(_restoreBackup(mod)),
      onRemovePatch: (patch) => unawaited(_removePatch(mod, patch)),
      // Whatever this session already knows. Nothing is fetched for a menu.
      patchNames: {
        for (final entry in ref.read(modUpdateRecordsProvider).entries)
          if (entry.value.name case final name?) entry.key: name,
      },
      // `valueOrNull` rather than a `when`: the listing is one readdir and
      // resolves long before a right-click, and a menu that waited on it would
      // be a menu that sometimes did not open.
      // By uid: the store is keyed by the folder's identity so a rename cannot
      // strand it, and a mod with no uid has never had a snapshot taken.
      hasBackups: mod.uid != null &&
          (ref.read(modBackupsProvider).valueOrNull?.contains(mod.uid) ??
              false),
      onDetails: () => _select(mod),
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
        onSaved: () => unawaited(loadMods()),
      ),
      onToggleFavorite: () => _toggleFavorite(mod),
      onDelete: () => unawaited(_deleteMod(mod)),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Watched, not read on demand: the context menu asks whether this mod has a
    // rollback to offer, and a `read` from inside the menu builder would start
    // the listing at that moment and answer "no" the first time. Watching it
    // here costs one rebuild when a single readdir resolves.
    ref.watch(modBackupsProvider);

    final current = ref.watch(currentCharacterIdProvider);
    final selectedId = ref.watch(selectedModIdProvider);
    // The panel shows a mod of the character on screen; picking another character closes it.
    final selected = ref
        .watch(currentCharacterSkinsProvider)
        .where((m) => m.id == selectedId)
        .firstOrNull;

    // **One scroll view for the whole page**: the header and the row of filters scroll away with the mods, so a
    // window at its minimum size still shows some. Fixed above the grid, the two take more than such a window has.
    final page = KeyedSubtree(
      key: ValueKey('character_$current'),
      child: DropTarget(
        onDragEntered: (_) => setState(() => _isDragging = true),
        onDragExited: (_) => setState(() => _isDragging = false),
        onDragDone: (details) => _importModsFromFolders(details.files),
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: CharacterHero(
                groupId: current,
                onFindMods: () => ref.read(destinationProvider.notifier).state = AppDestination.browse,
                onAddMod: _showImportDialog,
              ),
            ),
            SliverToBoxAdapter(
              child: ModsToolbar(onLibraryChanged: () => unawaited(loadMods()), onRescan: _refreshModsList),
            ),
            ..._buildGridSlivers(selected),
          ],
        ),
      ),
    );

    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: (node, event) {
        // A text field's own Ctrl+V lives higher up, in `WidgetsApp`, so this would see it first: in the note or
        // the filter, the key is the field's paste.
        final focused = FocusManager.instance.primaryFocus?.context;
        if (focused?.findAncestorStateOfType<EditableTextState>() != null) return KeyEventResult.ignored;
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
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CharacterList(onRetag: (mod, groupId) => unawaited(_retag(mod, groupId))),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final panel = selected == null
                    ? null
                    : ModDetailsPanel(
                        // A GlobalKey, so the panel keeps its state when it moves between beside and over.
                        key: _panelKey,
                        // Never wider than the page it is drawn over, at the smallest window.
                        width: constraints.maxWidth < ModDetailsPanel.defaultWidth
                            ? constraints.maxWidth
                            : ModDetailsPanel.defaultWidth,
                        mod: selected,
                        onClose: () => ref.read(selectedModIdProvider.notifier).state = null,
                        onToggle: () => toggleMod(selected),
                        onFavoriteToggle: () => _toggleFavorite(selected),
                        onEdit: () => _showEditDialog(selected),
                        onOpenFolder: () => _openModFolder(selected),
                        onCheckForUpdate: () => unawaited(_checkForUpdate(selected)),
                        onResolveOrigin: () => unawaited(_resolveOrigin(selected)),
                        onDelete: () => unawaited(_deleteMod(selected)),
                      );
                // Beside the mods while there is room for a column of cards next to it; over them otherwise.
                const minGrid = 420.0;
                final beside = panel != null && constraints.maxWidth - ModDetailsPanel.defaultWidth >= minGrid;
                final over = panel != null && !beside;
                // **One tree shape whatever the panel does.** The page stays the first child of the same Stack
                // whether the panel is closed, beside it or over it; a different parent for each would throw the
                // page away on every open and close, taking the grid's scroll position with it.
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: AnimatedSwitcher(duration: const Duration(milliseconds: 180), child: page),
                          ),
                          if (over)
                            Positioned(
                              top: 0,
                              right: 0,
                              bottom: 0,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  boxShadow: [BoxShadow(color: ZenithPalette.of(context).overlay, blurRadius: 40)],
                                ),
                                child: panel,
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (beside) panel,
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// The mods under the header and the filter row, as slivers of the page's one scroll view; or what stands in
  /// their place while the library loads, fails to load, or has nothing under the filter.
  List<Widget> _buildGridSlivers(ModInfo? selected) {
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final library = ref.watch(libraryProvider);

    Widget fill(Widget child) => SliverFillRemaining(
      hasScrollBody: false,
      child: Padding(padding: const EdgeInsets.all(28), child: Center(child: child)),
    );

    if (errorMessage != null || library.hasError) {
      return [
        fill(
          Column(
            mainAxisSize: MainAxisSize.min,
            spacing: 8,
            children: [
              Text(loc.t('mods.errors.load'), style: text.titleMedium?.copyWith(color: palette.text)),
              Text(
                errorMessage ?? '${library.error}',
                textAlign: TextAlign.center,
                style: text.bodySmall?.copyWith(color: palette.text3),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: loadMods,
                icon: const Icon(Icons.refresh_rounded),
                label: Text(loc.t('mods.errors.retry')),
              ),
            ],
          ),
        ),
      ];
    }
    if (!library.hasValue) return [fill(const CircularProgressIndicator())];

    final skins = ref.watch(currentCharacterSkinsProvider);
    final visible = ref.watch(visibleModsProvider);
    final filtered = ref.watch(modGridFilterProvider) != ModGridFilter.all;
    final dropTarget = _dropTarget(watch: true);

    if (skins.isNotEmpty && visible.isEmpty) {
      return [
        fill(
          Column(
            mainAxisSize: MainAxisSize.min,
            spacing: 12,
            children: [
              Text(loc.t('library.grid.no_results'), style: text.bodyMedium?.copyWith(color: palette.text2)),
              OutlinedButton(
                style: smallButtonStyle(context),
                onPressed: () => ref.read(modGridFilterProvider.notifier).state = ModGridFilter.all,
                child: Text(loc.t('library.grid.show_all')),
              ),
            ],
          ),
        ),
      ];
    }

    // The drop tile stays out of a filtered grid, where it would read as one of the results, except on a character
    // with no mods, where it is all there is.
    final showDrop = !filtered || skins.isEmpty;
    return [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(28, 20, 28, 96),
        sliver: SliverLayoutBuilder(
          builder: (context, constraints) {
            const gap = 16.0;
            const minCard = 220.0;
            final width = constraints.crossAxisExtent;
            final columns = ((width + gap) / (minCard + gap)).floor().clamp(1, 12);
            final cardWidth = (width - gap * (columns - 1)) / columns;
            return SliverGrid(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                mainAxisSpacing: gap,
                crossAxisSpacing: gap,
                mainAxisExtent: ModCardWidget.extentFor(cardWidth),
              ),
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  if (index == visible.length) {
                    return _DropCard(
                      key: const ValueKey('drop'),
                      filesUnder: dropTarget,
                      dragging: _isDragging,
                      onTap: _showImportDialog,
                    );
                  }
                  final mod = visible[index];
                  return _buildModCard(mod, selected: mod.id == selected?.id);
                },
                childCount: visible.length + (showDrop ? 1 : 0),
                // Finds a card by its folder id when the order changes, so it keeps its state rather than taking
                // over whichever card was at its old position.
                findChildIndexCallback: (key) {
                  if (key is! ValueKey<String>) return null;
                  final index = visible.indexWhere((m) => 'mod_${m.id}' == key.value);
                  return index < 0 ? null : index;
                },
              ),
            );
          },
        ),
      ),
    ];
  }

  Widget _buildModCard(ModInfo mod, {required bool selected}) {
    final palette = ZenithPalette.of(context);
    return LongPressDraggable<ModInfo>(
      key: ValueKey('mod_${mod.id}'),
      data: mod,
      delay: AppConstants.dragDelay,
      hapticFeedbackOnStart: true,
      // A slip with the mod's name on it, for dropping on a row of the character list.
      feedback: Material(
        color: palette.raised,
        elevation: AppConstants.dragFeedbackElevation,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 10,
            children: [
              Icon(Icons.drag_indicator_rounded, color: palette.text3),
              Text(mod.name, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: palette.text)),
            ],
          ),
        ),
      ),
      childWhenDragging: Opacity(
        opacity: AppConstants.dragFeedbackOpacity,
        child: ModCardWidget(mod: mod),
      ),
      child: ModCardWidget(
        mod: mod,
        selected: selected,
        onSelect: () => _select(mod),
        onToggle: () => toggleMod(mod),
        onFavoriteToggle: () => _toggleFavorite(mod),
        onMore: (position) => _showContextMenu(context, mod, position),
        onResolveOrigin: () => unawaited(_resolveOrigin(mod)),
        onShowUpdate: () => unawaited(_checkForUpdate(mod)),
      ),
    );
  }

  /// The character a drop or paste on this page files new mods under, or null when it is worked out from each
  /// mod's name.
  ///
  /// Only a character the user picked by clicking its row: the page shown before they pick one is a fallback, and
  /// the sidebar's Updates button picks one for them; filing five archives for five agents under either would be
  /// the app's guess, not theirs. Unassigned has no one to file under.
  ///
  /// [watch] for the drop tile, which says which of the two a drop will do and has to follow a pick.
  String? _dropTarget({bool watch = false}) {
    final byUser = watch ? ref.watch(characterPickedByUserProvider) : ref.read(characterPickedByUserProvider);
    final picked = watch ? ref.watch(selectedCharacterIdProvider) : ref.read(selectedCharacterIdProvider);
    if (!byUser) return null;
    return picked == null || picked == unknownCharacterId ? null : picked;
  }

  /// Imports dropped or pasted folders and archives.
  ///
  /// Dropped on a character the user picked, a new mod is filed under that character: the user said so by where
  /// they dropped it, so it replaces name detection rather than feeding it ([_dropTarget]). Anywhere else, the
  /// character is worked out from the name.
  Future<void> _importModsFromFolders(List<XFile> files) async {
    if (_isOperationInProgress) return;

    setState(() {
      _isOperationInProgress = true;
      _isDragging = false;
    });

    final droppedOn = _dropTarget();

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
      // Extracted-folder path -> the folder its shader files came from, for the picker.
      final shaderSources = <String, String>{};
      // Set when an archive was recognised as one already in the library and the
      // user chose not to install it again. Distinguishes "you declined" from
      // "there was nothing here" once the folder list comes out empty.
      var declinedDuplicate = false;

      for (final file in files) {
        // Перевіряємо чи це архів
        if (ArchiveService.isArchiveFile(file.path)) {
          archivesToExtract.add(file);
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
        // One line for the batch. The archive service logs each extraction
        // with its own name and result, so a line per file here would say the
        // same thing twice.
        _log.info('extracting dropped archives',
            fields: {'archives': archivesToExtract.length});

        for (final archiveFile in archivesToExtract) {
          final file = File(archiveFile.path);

          if (!await file.exists()) {
            _log.warning('dropped file is gone',
                fields: {'path': archiveFile.path});
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
            shaderSources.addAll(result.shaderSources);
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
            // The archive service already logged the result with the folder
            // count and how long it took.
          } else {
            if (mounted) {
              context.notify.warning(
                loc.t('mods.snackbar.import_error_title'),
                body: '${archiveFile.name}: ${result.error}',
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
            _files.debug('temp cleanup failed',
                fields: {'path': tempPath, 'reason': '$e'});
          }
        }
      }

      if (folderPaths.isEmpty) {
        await cleanupTempFolders();
        // Nothing to say when the user just declined every duplicate — they were
        // asked and answered. "No mod folders found" would be a different claim
        // entirely, and a false one.
        if (mounted && !declinedDuplicate) {
          context.notify.warning(
            loc.t('mods.snackbar.import_no_folders_title'),
            body: loc.t('mods.snackbar.import_no_folders_body'),
          );
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
        shaderSources: shaderSources,
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

      // Read here rather than after the copy: the patch question below needs
      // the library on disk to offer a destination in it.
      final modManagerService = await ref.read(
        modManagerServiceProvider.future,
      );
      final modsPath = modManagerService.modsPath;

      // **The patch question, before anything is copied.** The same prompt the
      // marketplace install raises, so a patch dragged in gets the same offer:
      // a folder of its own — saying which mod it patches — or straight into
      // the mod it patches.
      //
      // No `patchModId` on this path: a folder off a disk has no mod page, so
      // the write into an existing mod places the files and records nothing
      // about where they came from. Nothing else about the two flows differs.
      PatchInstallDecision? patchDecision;
      if (modsPath != null) {
        if (!mounted) return;
        patchDecision = await decidePatchInstall(
          context,
          plan: plan,
          folders: folderPaths,
          modsPath: modsPath,
        );
        // Only this prompt can offer "don't install it at all", and only here,
        // where nothing has been written yet.
        if (patchDecision == null) {
          await cleanupTempFolders();
          return;
        }
        // A folder going into an existing mod creates no new mod folder, so it
        // leaves the import entirely and is written afterwards.
        folderPaths.removeWhere(patchDecision.excludes);
      }

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
                    child: CircularProgressIndicator(strokeWidth: 4),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    loc.plural('mods.dialog.import_progress', expectedCount, params: {'count': '$expectedCount'}),
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    loc.t('mods.dialog.import_progress_hint'),
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: ZenithPalette.of(context).text2,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }

      // Імпортуємо моди
      final importResult = folderPaths.isEmpty
          // Every folder went into a mod that already exists. Calling
          // `importMods` with nothing answers "no mods imported", which the
          // guard below reads as a duplicate — a failure report for an install
          // that is going fine.
          ? const ImportResult.nothing()
          : combine
          ? await modManagerService.importCombinedMod(
              folderPaths,
              combinedName,
              detectionHint: combinedHint,
              origin: combinedSeed,
              knownCharacter: droppedOn,
            )
          : await modManagerService.importMods(
              folderPaths,
              detectionHints: detectionHints,
              originSeeds: originSeeds,
              knownCharacters: droppedOn == null ? null : {for (final folder in folderPaths) folder: droppedOn},
            );

      // Закриваємо діалог прогресу
      if (mounted && dialogShown) {
        Navigator.of(context).pop();
        dialogShown = false;
      }

      final importedMods = importResult.imported;
      // Only names the app worked out are worth listing; a drop on a character says where they went.
      final autoTags = droppedOn == null ? importResult.autoTags : const <String, String>{};

      // Nothing imported *and* nothing to write into an existing mod. With a
      // patch write pending this is an install going fine, not a duplicate.
      if (importedMods.isEmpty && (patchDecision?.writes.isEmpty ?? true)) {
        // Очищаємо тимчасові папки якщо імпорт не вдався
        if (tempFoldersToCleanup.isNotEmpty) {
          _files.debug('cleaning up after a failed import',
              fields: {'folders': tempFoldersToCleanup.length});
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
              _files.debug('temp cleanup failed',
                  fields: {'path': tempPath, 'reason': '$e'});
            }
          }
        }

        if (mounted) {
          // A refusal says what it was. Only a genuine "you already have these"
          // carries no failure, and that is the one case this wording fits.
          if (importResult.failure case final failure?) {
            final lines = importFailureMessage(
              loc,
              failure,
              requiredBytes: importResult.requiredBytes,
              availableBytes: importResult.availableBytes,
            );
            context.notify.error(lines.title, body: lines.body);
          } else {
            context.notify.warning(
              loc.t('mods.snackbar.import_duplicates_title'),
              body: loc.t('mods.snackbar.import_duplicates_body'),
            );
          }
        }
        return;
      }

      // Перезавантажуємо список модів
      await loadMods();

      // **Everything the patch answers imply, now the folders exist.** Writes
      // into an existing mod are update-shaped — deactivate, snapshot, place,
      // reactivate — and every new patch folder is marked, which is the record
      // that outlives the warning. Shared with the marketplace install, so the
      // two cannot do different things with the same answer.
      if (patchDecision != null && modsPath != null) {
        final lines = await applyPatchInstall(
          loc,
          decision: patchDecision,
          importedMods: importedMods,
          modsPath: modsPath,
          applier: UpdateApplier(
            snapshots: ref.read(snapshotServiceProvider),
            activation: ModManagerActivationPort(modManagerService),
          ),
          amend: modManagerService.updateModOrigin,
          // Naming what a patch patches installs that mod into the folder, the
          // same as it does for a download from the Marketplace.
          installBase: (modName, base, baseFile) => installNamedBase(
            context,
            ref,
            modName: modName,
            modsPath: modsPath,
            base: base,
            file: baseFile,
          ),
        );
        if (mounted) showNotificationLines(context, lines);
      }

      // Reported once, here: nothing re-attempts an origin write, because it
      // happens at ingest and never during a scan. Without this the mod would
      // just be silently untracked for updates with no explanation.
      final originFailures = modManagerService.takeOriginWriteFailures();
      if (originFailures.isNotEmpty && mounted) {
        context.notify.warning(
          loc.t('mods.snackbar.origin_write_failed_title'),
          body: loc.t(
            'mods.snackbar.origin_write_failed_body',
            params: {'mods': originFailures.join(', ')},
          ),
        );
      }

      // Видаляємо успішно імпортовані архіви
      if (successfullyExtractedArchives.isNotEmpty) {
        _files.debug('deleting consumed archives',
            fields: {'archives': successfullyExtractedArchives.length});
        for (final archivePath in successfullyExtractedArchives) {
          try {
            final archiveFile = File(archivePath);
            if (await archiveFile.exists()) {
              await archiveFile.delete();
            }
          } catch (e) {
            _files.warning('could not delete a consumed archive',
                error: e, fields: {'archive': archivePath});
          }
        }
      }

      // Очищаємо тимчасові папки після успішного імпорту
      if (tempFoldersToCleanup.isNotEmpty) {
        _files.debug('cleaning up after an import',
            fields: {'folders': tempFoldersToCleanup.length});
        for (final tempPath in tempFoldersToCleanup) {
          try {
            final tempDir = Directory(tempPath);
            if (await tempDir.exists()) {
              // Отримуємо батьківську директорію (zzz_archive_extract_*)
              final parentDir = tempDir.parent;
              if (parentDir.path.contains('zzz_archive_extract_')) {
                await parentDir.delete(recursive: true);
              }
            }
          } catch (e) {
            _files.debug('temp cleanup failed',
                fields: {'path': tempPath, 'reason': '$e'});
          }
        }
      }

      // **What the user asked for, and what they got instead.** A refusal means
      // the install did something other than what it was told, so this report
      // may not open with "Imported successfully" — it says so, and names which
      // of the reasons it was.
      final refusals = patchRefusalHeadlines(
        loc,
        patchDecision?.refused ?? const {},
      );

      // Nothing new to report: every folder went into a mod that already
      // exists, and the change is not visible as a card. The pinned "patch
      // applied" notification is the report for that, and a dialog announcing
      // "0 mods imported" over it is worse than no dialog.
      if (mounted && importedMods.isNotEmpty) {
        // Показуємо детальне повідомлення про успіх
        final hasAutoTags = autoTags.isNotEmpty;
        final palette = ZenithPalette.of(context);
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: Row(
              children: [
                Icon(
                  refusals.isEmpty
                      ? Icons.check_circle
                      : Icons.warning_amber_rounded,
                  color: refusals.isEmpty ? palette.accent : palette.amber,
                  size: 28,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(loc.t(refusals.isEmpty
                      ? 'mods.snackbar.import_success_title'
                      : 'mods.dialog.import_not_as_asked')),
                ),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  loc.plural(
                    'mods.import.success',
                    importedMods.length,
                    params: {'count': importedMods.length.toString()},
                  ),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (refusals.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: palette.amber.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: palette.amber.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          loc.t('mods.dialog.import_refused_heading'),
                          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 6),
                        for (final line in refusals)
                          Padding(
                            padding:
                                const EdgeInsets.symmetric(vertical: 2),
                            child: Text('• $line',
                                style: Theme.of(context).textTheme.bodySmall),
                          ),
                        const SizedBox(height: 6),
                        Text(
                          loc.t('mods.dialog.import_refused_instead'),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ],
                if (hasAutoTags) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: palette.blue.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: palette.blue.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.auto_awesome,
                              color: palette.blue,
                              size: 18,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              loc.t('mods.dialog.import_auto_tags'),
                              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: palette.blue,
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
                                  style: Theme.of(context).textTheme.bodySmall,
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
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: palette.text3,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
                // Left out when something was refused: a patch installed as its
                // own mod is not ready to use, and saying so under the
                // explanation of why contradicts it.
                if (refusals.isEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    loc.t('mods.dialog.import_ready'),
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: palette.text2),
                  ),
                ],
              ],
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(context),
                // **Nothing celebratory over a warning.** "Great!" is the app
                // being pleased with itself about an install that did not do
                // what it was told; the only honest button there acknowledges.
                child: Text(loc.t(refusals.isEmpty
                    ? 'mods.dialog.great'
                    : 'mods.dialog.got_it')),
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
          loc.t('mods.snackbar.import_error_title'),
          body: '$e',
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

  /// Explains how to add a mod: drop or paste a folder or an archive onto the page.
  Future<void> _showImportDialog() async {
    if (_isOperationInProgress) return;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(loc.t('mods.dialog.add_mods_title')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 16,
          children: [
            Text(
              loc.t('mods.dialog.add_mods_description'),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            Text(
              loc.t('mods.dialog.hint'),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: ZenithPalette.of(context).text2,
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
          context.notify.warning(
            loc.t('clipboard.empty_title'),
            body: loc.t('clipboard.empty_body'),
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
          context.notify.warning(
            loc.t('clipboard.no_paths_title'),
            body: loc.t('clipboard.no_paths_body'),
          );
        }
        return;
      }

      // Folders and archives, the same as a drop takes.
      final validFolders = <XFile>[];
      for (final filePath in paths) {
        String cleanPath = filePath;
        if (cleanPath.startsWith('file://')) {
          cleanPath = Uri.parse(cleanPath).toFilePath();
        }

        final isFolder = await Directory(cleanPath).exists();
        final isArchive = !isFolder && ArchiveService.isArchiveFile(cleanPath) && await File(cleanPath).exists();
        if (isFolder || isArchive) validFolders.add(XFile(cleanPath));
      }

      if (validFolders.isEmpty) {
        if (mounted) {
          context.notify.warning(
            loc.t('clipboard.no_valid_title'),
            body: loc.t('clipboard.no_valid_body'),
          );
        }
        return;
      }

      // Імпортуємо папки
      await _importModsFromFolders(validFolders);
    } catch (e) {
      if (mounted) {
        context.notify.error(
          loc.t('mods.snackbar.paste_error_title'),
          body: e.toString(),
        );
      }
    }
  }
}

/// The last tile of a character's grid: where a dropped folder or archive lands. Pressing it says how to add one.
class _DropCard extends StatelessWidget {
  const _DropCard({
    super.key,
    required this.filesUnder,
    required this.dragging,
    required this.onTap,
  });

  /// The character a drop is filed under, or null when it is worked out from the name.
  final String? filesUnder;
  final bool dragging;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final under = filesUnder;
    final hint = under == null
        ? loc.t('library.grid.drop_detects')
        : loc.t('library.grid.drop_lands_on', params: {'name': libraryGroupName(under, loc)});

    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        hoverColor: palette.rowHover,
        onTap: onTap,
        child: DashedBox(
          color: dragging ? palette.accent : palette.fieldBorder,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              spacing: 10,
              children: [
                Icon(Icons.file_upload_outlined, size: 28, color: dragging ? palette.accent : palette.text3),
                Text(
                  loc.t(dragging ? 'library.grid.drop_release' : 'library.grid.drop_title'),
                  textAlign: TextAlign.center,
                  style: text.bodyMedium?.copyWith(color: palette.textProse, fontWeight: FontWeight.w600),
                ),
                Text(hint, textAlign: TextAlign.center, style: text.bodySmall?.copyWith(color: palette.text3)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
