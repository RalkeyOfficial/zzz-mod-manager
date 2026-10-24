import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/button_working.dart';
import '../../../core/palette.dart';
import '../../../core/type_scale.dart';
import '../../../l10n/app_localizations.dart';
import '../../../models/character_info.dart';
import '../../../services/download/download_paths.dart';
import '../../../services/log/log_rotation.dart' show keptLogFiles;
import '../../../services/platform_service_factory.dart';
import '../../../services/storage/storage_providers.dart';
import '../../../services/storage/storage_usage.dart';
import '../../../utils/byte_format.dart';
import '../../../utils/categories.dart';
import '../../../utils/notifications.dart';
import '../../../utils/state_providers.dart';
import '../character_tile.dart';
import '../storage/largest_mods.dart';
import '../storage/reclaim_actions.dart';
import '../storage/saved_versions_detail.dart';
import '../storage/storage_meter.dart';
import '../storage/storage_row.dart';
import '../zenith_controls.dart';
import 'settings_widgets.dart';

/// Opens a folder in the file manager. Production is the platform service.
typedef StorageFolderOpener = Future<bool> Function(String folder);

/// What Zenith is keeping on disk, and what can be cleared (`docs/disk-usage.md`).
///
/// **Nothing here owns the scan.** Pages are keyed `AnimatedSwitcher` children with no keep-alive, so this `State` is disposed the moment the user switches away.
/// The measurements live in container-owned providers, which is what lets a walk finish while the user is elsewhere and be waiting when they come back.
///
/// [reclaim], [openFolder] and [now] are the seams a widget test replaces, so a press needs no temp directory, opens no file manager and a clock can be moved.
class StorageSection extends ConsumerStatefulWidget {
  const StorageSection({super.key, this.reclaim, this.openFolder, this.now = DateTime.now});

  final ReclaimRunner? reclaim;
  final StorageFolderOpener? openFolder;

  /// The time the "Measured … ago" label counts from.
  final DateTime Function() now;

  @override
  ConsumerState<StorageSection> createState() => _StorageSectionState();
}

/// The categories in the order the meter and the rows show them, which is also the order of [ZenithPalette.storageCategories].
const List<StorageCategoryId> _order = [
  StorageCategoryId.mods,
  StorageCategoryId.savedVersions,
  StorageCategoryId.leftovers,
  StorageCategoryId.downloads,
  StorageCategoryId.sidecars,
  StorageCategoryId.logs,
];

const Map<StorageCategoryId, String> _nameKeys = {
  StorageCategoryId.mods: 'storage.categories.mods',
  StorageCategoryId.savedVersions: 'storage.categories.saved_versions',
  StorageCategoryId.leftovers: 'storage.categories.leftovers',
  StorageCategoryId.downloads: 'storage.categories.downloads',
  StorageCategoryId.sidecars: 'storage.categories.sidecars',
  StorageCategoryId.logs: 'storage.categories.logs',
};

/// What a category says it holds when it has nothing to count.
const Map<StorageCategoryId, String> _hintKeys = {
  StorageCategoryId.mods: 'storage.categories.mods_hint',
  StorageCategoryId.savedVersions: 'storage.categories.saved_versions_hint',
  StorageCategoryId.leftovers: 'storage.categories.leftovers_hint',
  StorageCategoryId.downloads: 'storage.categories.downloads_hint',
  StorageCategoryId.sidecars: 'storage.categories.sidecars_hint',
  StorageCategoryId.logs: 'storage.categories.logs_hint',
};

class _StorageSectionState extends ConsumerState<StorageSection> {
  bool _refreshedOnEntry = false;

  /// The category under the pointer or holding keyboard focus, on the meter or in the list.
  StorageCategoryId? _hovered;
  bool _versionsOpen = false;

  /// This section's own press is waiting.
  bool _running = false;

  /// An action is deleting, so no other button starts one: a second sweep would plan against an inventory the first is in the middle of removing.
  /// The sweep is held by [reclaimControllerProvider] and outlives this `State`, so one started before the user left and came back counts too.
  bool _actionRunning() => _running || ref.watch(reclaimControllerProvider).isLoading;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Here rather than `initState`: `invalidate` resolves the provider with `listen: true`, which throws there.
    if (_refreshedOnEntry) return;
    _refreshedOnEntry = true;
    // The ones that re-read in milliseconds. **Not the library walk**: bouncing off this section must not re-walk gigabytes, so that stays cached behind the explicit Rescan.
    for (final id in cheapStorageCategories) {
      ref.invalidate(storageCategoryProvider(id));
    }
    ref.invalidate(storageFreeSpaceProvider);
  }

  void _hover(StorageCategoryId? id) {
    if (_hovered != id) setState(() => _hovered = id);
  }

  /// Walks the library again.
  /// The scanner memoises its walk, so the categories have to come off a fresh one; they watch it, so replacing it re-reads every one of them.
  Future<void> _rescan(WorkSpan work) async {
    final container = ProviderScope.containerOf(context, listen: false);
    ref.invalidate(storageScannerProvider);
    await work(() => container.read(storageCategoryProvider(StorageCategoryId.mods).future));
  }

  Future<void> _act(StorageAction action, WorkSpan work) async {
    Future<T> span<T>(Future<T> Function() task) => work(() async {
          if (mounted) setState(() => _running = true);
          try {
            return await task();
          } finally {
            if (mounted) setState(() => _running = false);
          }
        });

    await runStorageAction(context, action, work: span, runner: widget.reclaim);
  }

  Future<void> _openFolder(String folder) async {
    final loc = context.loc;
    final notify = context.notify;
    var opened = false;
    try {
      opened = await (widget.openFolder ?? PlatformServiceFactory.getInstance().openFolderInFileManager)(folder);
    } catch (_) {}
    if (!opened) notify.error(loc.t('notifications.open_folder_failed_title'), body: folder);
  }

  /// Shows [mod]'s page in the Library's Characters view: Settings is a page of its own, so the view is switched too.
  void _openMod(ModInfo mod) {
    ref.read(selectedCharacterIdProvider.notifier).state = libraryGroupOf(mod.characterId);
    ref.read(selectedModIdProvider.notifier).state = mod.id;
    ref.read(openModPageProvider.notifier).state = ModPageRequest(mod.id, pageKey: mod.uid ?? mod.id);
    ref.read(destinationProvider.notifier).state = AppDestination.characters;
  }

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final categories = {
      for (final id in StorageCategoryId.values) id: ref.watch(storageCategoryProvider(id)).valueOrNull,
    };
    final totals = ref.watch(storageTotalsProvider);
    final measuring = ref.watch(storageCategoryProvider(StorageCategoryId.mods)).isLoading || !totals.isComplete;
    final library = ref.watch(libraryProvider).valueOrNull;
    final modsByFolder = {for (final mod in library ?? const <ModInfo>[]) mod.id: mod};
    final saved = categories[StorageCategoryId.savedVersions];

    // The groups of saved versions no mod in the library carries, once the library has been read.
    // Not while the Mods category is unmeasured: a library that cannot be found reads as an empty list, which would tag every group.
    final modsMeasured = categories[StorageCategoryId.mods]?.hasMeasurement ?? false;
    final uids = {for (final mod in library ?? const <ModInfo>[]) mod.uid};
    final unclaimed = library == null || saved == null || !modsMeasured
        ? null
        : {
            for (final item in saved.items)
              if (!uids.contains(item.id)) item.id,
          };
    // Offered unless the library has been read and holds every group's mod.
    final canClear = modsMeasured && (unclaimed == null || unclaimed.isNotEmpty);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 24,
      children: [
        _hero(loc, palette, categories, totals, measuring),
        if (_libraryChanged(categories[StorageCategoryId.mods], library)) _staleNotice(loc, measuring),
        Semantics(
          container: true,
          label: loc.t('storage.by_category'),
          child: SettingsGroup(
            children: [
              for (final id in _order) _row(loc, palette, id, categories[id], totals, saved, unclaimed, canClear),
            ],
          ),
        ),
        ?_largest(loc, categories, modsByFolder),
      ],
    );
  }

  Widget _hero(
    AppLocalizations loc,
    ZenithPalette palette,
    Map<StorageCategoryId, StorageCategory?> categories,
    StorageTotals totals,
    bool measuring,
  ) {
    final text = Theme.of(context).textTheme;
    final volumes = ref.watch(storageFreeSpaceProvider).valueOrNull ?? const <VolumeFreeSpace>[];
    final measuredAt = ref.read(storageScannerProvider).libraryMeasuredAt;

    final segments = [
      for (final (i, id) in _order.indexed)
        if (categories[id] case final category? when category.hasMeasurement && category.bytes > 0)
          MeterSegment(
            id: id,
            name: loc.t(_nameKeys[id]!),
            size: formatBytes(category.bytes),
            share: loc.t('storage.tip_share', params: {'percent': percentLabel(category.bytes, totals.bytes)}),
            bytes: category.bytes,
            color: palette.storageCategories[i],
          ),
    ];

    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: palette.outline),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 16,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.end,
              spacing: 16,
              runSpacing: 16,
              children: [
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 4,
                  children: [
                    Text(loc.t('storage.hero_label').toUpperCase(), style: ZenithType.of(context).caps.copyWith(color: palette.text3)),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      spacing: 10,
                      children: [
                        Text(
                          totals.anyFloor
                              ? loc.t('storage.at_least', params: {'size': formatBytes(totals.bytes)})
                              : formatBytes(totals.bytes),
                          style: text.displayLarge?.copyWith(
                            color: palette.text,
                            fontWeight: FontWeight.w700,
                            height: 1,
                          ),
                        ),
                        Flexible(child: _freeSpace(loc, palette, volumes, measuring)),
                      ],
                    ),
                  ],
                ),
                _rescanButton(loc, measuring, measuredAt),
              ],
            ),
            StorageMeter(
              segments: segments,
              hovered: _hovered,
              onHover: _hover,
              semanticLabel: loc.t(
                'storage.meter_label',
                params: {'parts': segments.map((s) => '${s.name} ${s.size}').join(', ')},
              ),
              footer: Text(loc.t('storage.only_counts'), style: text.bodySmall?.copyWith(color: palette.text3)),
            ),
          ],
        ),
      ),
    );
  }

  /// Free space beside the total: one line for one disk, one per volume when the library is on another.
  Widget _freeSpace(AppLocalizations loc, ZenithPalette palette, List<VolumeFreeSpace> volumes, bool measuring) {
    final style = Theme.of(context).textTheme.bodyMedium?.copyWith(color: palette.text2);
    if (measuring && volumes.isEmpty) return Text(loc.t('storage.measuring'), style: style);
    if (volumes.isEmpty) return const SizedBox.shrink();

    String free(VolumeFreeSpace volume) => volume.freeBytes == null
        ? loc.t('storage.free.unknown')
        : loc.t('storage.free.available', params: {'size': formatBytes(volume.freeBytes!)});

    if (volumes.length == 1) {
      return Text(free(volumes.single), style: style);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final volume in volumes) Text('${loc.t('storage.free.${volume.label}')} · ${free(volume)}', style: style),
      ],
    );
  }

  Widget _rescanButton(AppLocalizations loc, bool measuring, DateTime? measuredAt) {
    return Tooltip(
      message: loc.t('storage.rescan'),
      child: WorkingAction(
        onPressed: measuring || _actionRunning() ? null : _rescan,
        builder: (context, onPressed) => TextButton.icon(
          style: smallButtonStyle(context),
          onPressed: onPressed,
          icon: const WorkingIcon(Icon(Icons.sync_rounded, size: 16)),
          label: measuring
              ? Text(loc.t('storage.measuring'))
              : measuredAt == null
                  ? Text(loc.t('storage.rescan'))
                  : _MeasuredAgo(key: ValueKey(measuredAt), measuredAt: measuredAt, now: widget.now),
        ),
      ),
    );
  }

  /// Whether the library holds mods the walk did not see, or the walk saw mods the library no longer holds.
  ///
  /// By name rather than by count, so a rename shows too.
  /// A link is not held against the library, since a dead one is in the walk and never in the scan.
  bool _libraryChanged(StorageCategory? mods, List<ModInfo>? library) {
    if (mods == null || library == null || !mods.hasMeasurement) return false;
    final measured = {for (final item in mods.items) item.id};
    final held = {for (final mod in library) mod.id};
    if (held.any((id) => !measured.contains(id))) return true;
    return mods.items.any((item) => item.kind == StorageItemKind.modFolder && !held.contains(item.id));
  }

  Widget _staleNotice(AppLocalizations loc, bool measuring) {
    final palette = ZenithPalette.of(context);
    final tone = palette.badgeUpdate;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tone.background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: tone.border!),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          spacing: 10,
          children: [
            Icon(Icons.info_outline_rounded, size: 16, color: tone.foreground),
            Expanded(
              child: Text(
                loc.t('storage.library_changed'),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tone.foreground),
              ),
            ),
            WorkingAction(
              onPressed: measuring || _actionRunning() ? null : _rescan,
              builder: (context, onPressed) => TextButton(
                style: smallButtonStyle(context).merge(
                  ButtonStyle(foregroundColor: WidgetStatePropertyAll(tone.foreground)),
                ),
                onPressed: onPressed,
                child: Text(loc.t('storage.rescan')),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(
    AppLocalizations loc,
    ZenithPalette palette,
    StorageCategoryId id,
    StorageCategory? category,
    StorageTotals totals,
    StorageCategory? saved,
    Set<String>? unclaimed,
    bool canClear,
  ) {
    final index = _order.indexOf(id);
    final measured = category?.hasMeasurement ?? false;
    final hasItems = measured && category!.items.isNotEmpty;

    // The primary button is 600 where the others are 500.
    final primaryStyle = smallButtonStyle(context).merge(
      ButtonStyle(
        textStyle: WidgetStatePropertyAll(
          Theme.of(context).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
    );

    final busy = _actionRunning();
    Widget action(StorageAction what, String label, {bool primary = false}) => WorkingAction(
          onPressed: busy || !hasItems ? null : (work) => _act(what, work),
          builder: (context, onPressed) => primary
              ? FilledButton(style: primaryStyle, onPressed: onPressed, child: Text(label))
              : OutlinedButton(style: smallButtonStyle(context), onPressed: onPressed, child: Text(label)),
        );

    final folder = category?.rootPath;
    final name = loc.t(_nameKeys[id]!);
    final openFolder = IconButton(
      style: smallButtonStyle(context, iconOnly: true),
      // The sidecars live inside each mod folder, so this opens the library root, which is also what Installed mods opens.
      tooltip: id == StorageCategoryId.sidecars
          ? loc.t('storage.open_sidecars_folder')
          : loc.t('storage.open_folder', params: {'name': name}),
      onPressed: folder == null ? null : () => _openFolder(folder),
      icon: const Icon(Icons.folder_outlined),
    );

    final actions = switch (id) {
      StorageCategoryId.leftovers => [
        action(StorageAction.cleanUpLeftovers, loc.t('storage.actions.clean_up'), primary: true),
        openFolder,
      ],
      StorageCategoryId.downloads => [
        action(StorageAction.clearDownloads, loc.t('storage.actions.clear')),
        openFolder,
      ],
      StorageCategoryId.logs => [action(StorageAction.clearLogs, loc.t('storage.actions.clear')), openFolder],
      StorageCategoryId.savedVersions => [
        Semantics(
          expanded: _versionsOpen,
          child: OutlinedButton(
            style: smallButtonStyle(context),
            onPressed: hasItems ? () => setState(() => _versionsOpen = !_versionsOpen) : null,
            child: Text(loc.t('storage.actions.manage')),
          ),
        ),
        openFolder,
      ],
      // The sidecar holds a mod's origin tracking and the user's own covers, which cannot be fetched again, so there is nothing to clear: only a way to look.
      StorageCategoryId.mods || StorageCategoryId.sidecars => [openFolder],
    };

    Widget? detail;
    if (id == StorageCategoryId.savedVersions && _versionsOpen && measured) {
      detail = SavedVersionsDetail(
        category: category!,
        unclaimed: unclaimed,
        clear: canClear ? action(StorageAction.clearVersions, loc.t('storage.actions.clear_versions')) : null,
      );
    }

    return StorageRow(
      key: ValueKey('row_${id.name}'),
      color: palette.storageCategories[index],
      name: name,
      description: _describe(loc, id, category),
      size: _sizeText(loc, category),
      percent: measured ? percentLabel(category!.bytes, totals.bytes) : '',
      actions: actions,
      highlighted: _hovered == id,
      onHover: (over) => _hover(over ? id : null),
      detail: detail,
    );
  }

  static String _sizeText(AppLocalizations loc, StorageCategory? category) {
    if (category == null) return '…';
    return switch (category.read) {
      StorageRead.ok => formatBytes(category.bytes),
      StorageRead.partial => loc.t('storage.at_least', params: {'size': formatBytes(category.bytes)}),
      StorageRead.notConfigured => loc.t('storage.read.not_configured'),
      StorageRead.absent => loc.t('storage.read.absent'),
      StorageRead.unreadable => loc.t('storage.read.unreadable'),
    };
  }

  /// What the category holds, counted where there is something to count.
  String _describe(AppLocalizations loc, StorageCategoryId id, StorageCategory? category) {
    String counted(String key, int count) => loc.plural(key, count, params: {'count': '$count'});
    final hint = loc.t(_hintKeys[id]!);
    if (category == null || !category.hasMeasurement || category.items.isEmpty) return hint;

    switch (id) {
      case StorageCategoryId.mods:
        return counted('storage.rows.mods', category.items.length);
      case StorageCategoryId.savedVersions:
        return '${counted('storage.rows.snapshots', category.fileCount)}, ${counted('storage.rows.across', category.items.length)}';
      case StorageCategoryId.downloads:
        final archives = category.items.where((i) => i.kind == StorageItemKind.archive).length;
        final partials = category.items
            .where((i) => i.kind == StorageItemKind.partialDownload && i.label.endsWith(DownloadPaths.partSuffix))
            .length;
        final parts = [
          if (archives > 0) counted('storage.rows.archives', archives),
          if (partials > 0) counted('storage.rows.partials', partials),
        ];
        return parts.isEmpty ? hint : parts.join(', ');
      case StorageCategoryId.logs:
        return counted('storage.rows.logs', keptLogFiles);
      case StorageCategoryId.leftovers:
      case StorageCategoryId.sidecars:
        return hint;
    }
  }

  Widget? _largest(
    AppLocalizations loc,
    Map<StorageCategoryId, StorageCategory?> categories,
    Map<String, ModInfo> modsByFolder,
  ) {
    final mods = categories[StorageCategoryId.mods];
    if (mods == null || !mods.hasMeasurement) return null;
    final saved = categories[StorageCategoryId.savedVersions];
    final savedKnown = saved != null && saved.hasMeasurement;

    final entries = largestMods(
      mods.items,
      savedKnown ? saved.items : const <StorageItem>[],
      (folder) => modsByFolder[folder]?.uid,
    );
    if (entries.isEmpty) return null;
    final largest = entries.first.totalBytes;

    return LargestMods(
      rows: [
        for (final entry in entries)
          () {
            final mod = modsByFolder[entry.item.id];
            final detail = [
              if (mod != null) libraryGroupName(libraryGroupOf(mod.characterId), loc),
              if (savedKnown)
                entry.savedCount == 0
                    ? loc.t('storage.largest.no_versions')
                    : loc.plural('storage.item.versions', entry.savedCount, params: {'count': '${entry.savedCount}'}),
            ].join(' · ');
            return LargestModView(
              name: mod?.name ?? entry.item.label,
              detail: detail,
              // A link holds no bytes of its own, and "0 B" beside a mod's name reads as an empty mod.
              size: entry.isLinked ? loc.t('storage.item.linked') : formatBytes(entry.totalBytes),
              fraction: largest == 0 ? 0 : entry.totalBytes / largest,
              onOpen: mod == null ? null : () => _openMod(mod),
            );
          }(),
      ],
    );
  }
}

/// "Measured 12 minutes ago", counted again every minute: nothing else rebuilds the section on a clock.
class _MeasuredAgo extends StatefulWidget {
  const _MeasuredAgo({super.key, required this.measuredAt, required this.now});

  final DateTime measuredAt;
  final DateTime Function() now;

  @override
  State<_MeasuredAgo> createState() => _MeasuredAgoState();
}

class _MeasuredAgoState extends State<_MeasuredAgo> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(minutes: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    String counted(String key, int count) => loc.plural(key, count, params: {'count': '$count'});
    final ago = widget.now().difference(widget.measuredAt);
    return Text(
      ago.inMinutes < 1
          ? loc.t('storage.measured_now')
          : ago.inHours < 1
              ? counted('storage.measured_minutes', ago.inMinutes)
              : ago.inDays < 1
                  ? counted('storage.measured_hours', ago.inHours)
                  : counted('storage.measured_days', ago.inDays),
    );
  }
}
