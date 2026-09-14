import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_staggered_animations/flutter_staggered_animations.dart';

import '../core/constants.dart';
import '../l10n/app_localizations.dart';
import '../services/storage/storage_providers.dart';
import '../services/storage/storage_usage.dart';
import '../utils/byte_format.dart';
import '../utils/state_providers.dart';
import 'components/storage/reclaim_button.dart';
import 'components/storage/storage_category_detail.dart';
import 'components/storage/storage_donut.dart';
import 'components/storage/storage_legend.dart';

/// What this app is keeping on disk, and where.
///
/// **Nothing on this screen owns the scan.** Tabs are keyed `AnimatedSwitcher`
/// children with no keep-alive, so this `State` is disposed the moment the user
/// switches away; the measurements live in container-owned providers, which is
/// what lets a walk finish while the user is elsewhere and be waiting when they
/// come back.
class StorageScreen extends ConsumerStatefulWidget {
  const StorageScreen({super.key});

  @override
  ConsumerState<StorageScreen> createState() => _StorageScreenState();
}

class _StorageScreenState extends ConsumerState<StorageScreen> {
  bool _refreshedOnEntry = false;
  StorageCategoryId? _expanded;

  /// How many mods the library held when it was last walked, so the page can
  /// admit it is out of date rather than quietly showing an old number.
  int? _scannedModCount;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Here rather than `initState`: `invalidate` resolves the provider with
    // `listen: true`, which throws there.
    if (_refreshedOnEntry) return;
    _refreshedOnEntry = true;
    _refreshCheap();
  }

  /// The five that re-read in milliseconds. **Not the library walk** — bouncing
  /// off this tab must not re-walk gigabytes, so that stays cached behind the
  /// explicit Rescan.
  void _refreshCheap() {
    for (final id in cheapStorageCategories) {
      ref.invalidate(storageCategoryProvider(id));
    }
    ref.invalidate(storageFreeSpaceProvider);
  }

  void _rescanLibrary() {
    setState(() => _scannedModCount = ref.read(modsProvider).length);
    // The scanner memoises its walk, so the categories have to come off a fresh
    // one rather than off the instance that already answered.
    ref.invalidate(storageScannerProvider);
    for (final id in StorageCategoryId.values) {
      ref.invalidate(storageCategoryProvider(id));
    }
    ref.invalidate(storageFreeSpaceProvider);
  }

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final theme = Theme.of(context);
    final isDarkMode = ref.watch(isDarkModeProvider);

    return Column(
      children: [
        Container(
          padding: EdgeInsets.all(AppConstants.defaultPadding * 1.5),
          decoration: BoxDecoration(
            color: theme.cardColor,
            border: Border(
              bottom: BorderSide(
                color: isDarkMode
                    ? Colors.white.withValues(alpha: 0.1)
                    : Colors.black.withValues(alpha: 0.05),
              ),
            ),
          ),
          child: Row(
            children: [
              // The title takes the slack and the button keeps its intrinsic
              // size; the reverse squeezes the control into a sliver at a
              // narrow window, which is how this tab's layout has broken
              // before.
              Expanded(
                child: Text(
                  loc.t('storage.title'),
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: AppConstants.headerTextSize + 4,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              IconButton(
                onPressed: _rescanLibrary,
                tooltip: loc.t('storage.rescan'),
                icon: const Icon(Icons.refresh_rounded, size: 18),
              ),
            ],
          ),
        ),
        Expanded(
          child: AnimationLimiter(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: AnimationConfiguration.toStaggeredList(
                  duration: const Duration(milliseconds: 375),
                  childAnimationBuilder: (widget) => SlideAnimation(
                    verticalOffset: 50.0,
                    child: FadeInAnimation(child: widget),
                  ),
                  children: [
                    _Breakdown(
                      expanded: _expanded,
                      onToggle: (id) => setState(
                        () => _expanded = _expanded == id ? null : id,
                      ),
                    ),
                    const SizedBox(height: 24),
                    const _FreeSpace(),
                    const SizedBox(height: 24),
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: ReclaimButton(),
                    ),
                    if (_libraryChanged()) ...[
                      const SizedBox(height: 16),
                      _StaleNotice(onRescan: _rescanLibrary),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  bool _libraryChanged() {
    final scanned = _scannedModCount;
    if (scanned == null) return false;
    return ref.watch(modsProvider).length != scanned;
  }
}

/// The ring and its legend.
class _Breakdown extends ConsumerWidget {
  const _Breakdown({required this.expanded, required this.onToggle});

  final StorageCategoryId? expanded;
  final ValueChanged<StorageCategoryId> onToggle;

  /// One colour per category, fixed, so a slice keeps its identity between the
  /// ring and the legend and between visits.
  static const Map<StorageCategoryId, Color> _colors = {
    StorageCategoryId.mods: Color(AppConstants.primaryColor),
    StorageCategoryId.savedVersions: Color(AppConstants.activeModBorderColor),
    StorageCategoryId.downloads: Color(AppConstants.secondaryColor),
    StorageCategoryId.sidecars: Color(AppConstants.activeModCountColor),
    StorageCategoryId.logs: Color(0xFF94A3B8),
    StorageCategoryId.leftovers: Color(0xFFF59E0B),
  };

  /// The label key; the one-line explanation is the same key plus `_hint`.
  static const Map<StorageCategoryId, String> _labelKeys = {
    StorageCategoryId.mods: 'storage.categories.mods',
    StorageCategoryId.savedVersions: 'storage.categories.saved_versions',
    StorageCategoryId.downloads: 'storage.categories.downloads',
    StorageCategoryId.sidecars: 'storage.categories.sidecars',
    StorageCategoryId.logs: 'storage.categories.logs',
    StorageCategoryId.leftovers: 'storage.categories.leftovers',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = context.loc;
    final totals = ref.watch(storageTotalsProvider);
    final categories = <StorageCategoryId, StorageCategory?>{
      for (final id in StorageCategoryId.values)
        id: ref.watch(storageCategoryProvider(id)).valueOrNull,
    };

    final donut = StorageDonut(
      slices: [
        for (final id in StorageCategoryId.values)
          DonutSlice(
            id: id,
            bytes: categories[id]?.hasMeasurement == true
                ? categories[id]!.bytes
                : 0,
            color: _colors[id]!,
          ),
      ],
      centerLabel: totals.anyFloor
          ? loc.t('storage.at_least',
              params: {'size': formatBytes(totals.bytes)})
          : formatBytes(totals.bytes),
      centerCaption: totals.isComplete
          ? loc.t('storage.total')
          : loc.t('storage.measuring'),
    );

    final legend = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final id in StorageCategoryId.values) ...[
          StorageLegendRow(
            category: categories[id] ??
                StorageCategory(
                  id: id,
                  read: StorageRead.ok,
                  bytes: 0,
                ),
            color: _colors[id]!,
            label: loc.t(_labelKeys[id]!),
            hint: loc.t('${_labelKeys[id]!}_hint'),
            expanded: expanded == id,
            onTap: () => onToggle(id),
          ),
          if (expanded == id && categories[id] != null)
            StorageCategoryDetail(category: categories[id]!),
        ],
      ],
    );

    // Side by side where there is room, stacked where there is not. The ring is
    // a fixed 200px, so below roughly 640px of content the legend's rows start
    // ellipsing rather than wrapping.
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 640) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(child: donut),
              const SizedBox(height: 24),
              legend,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 8, right: 32),
              child: donut,
            ),
            Expanded(child: legend),
          ],
        );
      },
    );
  }
}

/// Free space, one line per volume.
///
/// Not a slice of the ring: the library is routinely on a different disk than
/// app data, and a single "free" wedge would be arithmetic across two
/// filesystems.
class _FreeSpace extends ConsumerWidget {
  const _FreeSpace();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = context.loc;
    final theme = Theme.of(context);
    final volumes = ref.watch(storageFreeSpaceProvider).valueOrNull;
    if (volumes == null || volumes.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final volume in volumes)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              children: [
                Icon(Icons.storage_rounded,
                    size: 15, color: theme.dividerColor),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    loc.t('storage.free.${volume.label}'),
                    style: theme.textTheme.bodySmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  volume.freeBytes == null
                      ? loc.t('storage.free.unknown')
                      : loc.t('storage.free.available', params: {
                          'size': formatBytes(volume.freeBytes!),
                        }),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.textTheme.bodySmall?.color
                        ?.withValues(alpha: 0.7),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _StaleNotice extends StatelessWidget {
  const _StaleNotice({required this.onRescan});

  final VoidCallback onRescan;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF59E0B).withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline_rounded,
              size: 16, color: Color(0xFFF59E0B)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              loc.t('storage.library_changed'),
              style: theme.textTheme.bodySmall,
            ),
          ),
          TextButton(
            onPressed: onRescan,
            child: Text(loc.t('storage.rescan')),
          ),
        ],
      ),
    );
  }
}
