import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/palette.dart';
import '../../core/type_scale.dart';
import '../../l10n/app_localizations.dart';
import '../../models/character_info.dart';
import '../../models/origin_enums.dart';
import '../../services/bulk_assume_current.dart';
import '../../services/bulk_update_check.dart';
import '../../services/origin_write.dart';
import '../../utils/byte_format.dart';
import '../../utils/categories.dart';
import '../../utils/notifications.dart';
import '../../utils/state_providers.dart';
import '../components/character_tile.dart';
import '../components/library_actions_host.dart';
import '../components/mod_thumb.dart';
import '../components/resolve/resolve_fragments.dart';
import '../components/zenith_controls.dart';
import '../dialogs/assume_current_dialog.dart';
import 'all_mods_bulk.dart';
import 'all_mods_rows.dart';

/// The Library's All mods view: every mod in one table, with filters, a search, grouping, and bulk actions on the
/// mods ticked (`docs/library-screen.md` §16).
///
/// Its state lives in providers, like the character view's, since the Library page is disposed on every page
/// switch. The checks and the tracking screen run in [LibraryActionsHost], above the page.
class AllModsView extends ConsumerStatefulWidget {
  const AllModsView({
    super.key,
    required this.onOpenPage,
    required this.onContextMenu,
    required this.onShowUpdate,
    required this.onResolveOrigin,
    this.loadError,
    this.originWriter,
  });

  /// Shown in place of the table when the library didn't load, with its Retry.
  final Widget? loadError;

  /// A row pressed: the mod's page.
  final void Function(ModInfo mod) onOpenPage;

  /// A right-click or the ⋯ button: the mod's menu at [position].
  final void Function(BuildContext context, ModInfo mod, Offset position) onContextMenu;

  /// An update badge pressed: the update dialog.
  final void Function(ModInfo mod) onShowUpdate;

  /// A tracking badge or "Track" pressed: the resolve dialog.
  final void Function(ModInfo mod) onResolveOrigin;

  /// Injected only by tests — see [OriginWriter].
  final OriginWriter? originWriter;

  @override
  ConsumerState<AllModsView> createState() => _AllModsViewState();
}

class _AllModsViewState extends ConsumerState<AllModsView> {
  late final TextEditingController _search = TextEditingController(text: ref.read(allModsSearchProvider));

  /// The row a Shift-click on a checkbox extends the selection from.
  String? _anchor;

  AppLocalizations get loc => context.loc;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The box follows a search cleared from elsewhere, as the no-results line's Show all clears it.
    ref.listen(allModsSearchProvider, (_, search) {
      if (_search.text != search) _search.text = search;
    });
    final palette = ZenithPalette.of(context);
    final library = ref.watch(libraryProvider);
    final mods = ref.watch(modsProvider);
    final missing = ref.watch(deadModLinksProvider).valueOrNull ?? const [];
    final checks = ref.watch(modUpdateChecksProvider);
    final filter = ref.watch(allModsFilterProvider);
    final session = AllModsContext(
      checks: checks,
      pages: ref.watch(knownModPagesProvider),
      sizes: ref.watch(librarySizesProvider).valueOrNull ?? const {},
      loc: loc,
    );
    final rows = visibleAllModsRows(
      mods: mods,
      missing: missing,
      filter: filter,
      search: ref.watch(allModsSearchProvider),
      sort: ref.watch(allModsSortProvider) ?? AllModsSort.byDefault,
      session: session,
    );
    final unfolded = unfoldedAllModsRows(rows, ref.watch(allModsGroupingProvider), ref.watch(allModsCollapsedProvider), loc);
    final shown = [for (final row in unfolded) if (row case ModRow(:final mod)) mod];
    final picked = ref.watch(allModsSelectionProvider);
    // Only what is on screen: a bulk action never reaches a mod the filter, the search or a folded group has hidden.
    final selected = [for (final mod in shown) if (picked.contains(mod.id)) mod];

    return ColoredBox(
      color: palette.ground,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(mods: mods, sizes: session.sizes),
          _FilterRow(
            controller: _search,
            counts: countAllMods(mods, missing, checks),
          ),
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: widget.loadError != null
                      ? Center(child: Padding(padding: const EdgeInsets.all(28), child: widget.loadError))
                      : !library.hasValue
                      ? const Center(child: CircularProgressIndicator())
                      : rows.isEmpty
                      ? _empty(mods.isEmpty && missing.isEmpty)
                      : _Table(
                          rows: rows,
                          session: session,
                          picked: picked,
                          selectable: shown.length,
                          selectedCount: selected.length,
                          onPick: (row, value) => _pick(unfolded, row, value),
                          onPickAll: (value) => _pickAll(shown, value),
                          onOpenPage: widget.onOpenPage,
                          onContextMenu: widget.onContextMenu,
                          onShowUpdate: widget.onShowUpdate,
                          onResolveOrigin: widget.onResolveOrigin,
                        ),
                ),
                if (selected.isNotEmpty)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 22,
                    child: Center(child: _selectionBar(selected, shown: shown.length)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Marks the ticked mods that ask "Which file?" as current. The confirmation lists each one with a box to untick.
  ///
  /// Reads the app's container rather than [ref], as the other bulk actions do, so leaving the page mid-run still
  /// reports and rescans.
  Future<void> _assumeCurrent(BulkAssumeCurrentPlan plan) async {
    final loc = this.loc;
    final notify = context.notify;
    final container = ProviderScope.containerOf(context, listen: false);
    final write = widget.originWriter ?? originWriterFor(container.read(modManagerServiceProvider.future));
    // Checked as each mod's turn comes, as the other bulk actions do.
    final writing = <ModInfo>[];
    final outcome = await confirmAndApplyAssumeCurrent(
      context,
      plan,
      writer: (modId, update) async {
        final mod = plan.eligible.firstWhere((m) => m.id == modId);
        if (!isBeingWritten(container, mod)) return whileWritingMod(container, modId, () => write(modId, update));
        writing.add(mod);
        return OriginWriteResult.declined;
      },
    );
    if (outcome == null) return;
    // The skipped mods are reported on their own, not as "already done".
    final shown = BulkAssumeCurrentOutcome(
      written: outcome.written,
      skipped: outcome.skipped - writing.length,
      failed: outcome.failed,
    );
    reportSkippedWhileWriting(loc, notify, writing);
    if (shown.written + shown.skipped + shown.failed > 0) {
      showAssumeCurrentOutcome(loc, notify, shown, into: outcome.card);
    } else {
      outcome.card?.dismiss();
    }
    // Even when nothing was written: a run that only declined means the plan on screen was stale.
    await container.read(libraryProvider.notifier).rescan();
  }

  Widget _empty(bool libraryEmpty) {
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 12,
          children: [
            Text(
              loc.t(libraryEmpty ? 'library.all.empty' : 'library.all.no_results'),
              style: text.bodyMedium?.copyWith(color: palette.text2),
            ),
            if (libraryEmpty)
              Text(loc.t('library.grid.drop_title'), style: text.bodySmall?.copyWith(color: palette.text3))
            else
              OutlinedButton(
                style: smallButtonStyle(context),
                onPressed: () {
                  ref.read(allModsSearchProvider.notifier).state = '';
                  ref.read(allModsFilterProvider.notifier).state = AllModsFilter.all;
                },
                child: Text(loc.t('library.grid.show_all')),
              ),
          ],
        ),
      ),
    );
  }

  /// Ticks or clears one row; with Shift held, every row from the last one ticked to this one.
  void _pick(List<AllModsRow> rows, ModRow row, bool value) {
    final selection = ref.read(allModsSelectionProvider.notifier);
    final ids = {...selection.state};
    final shift = HardwareKeyboard.instance.isShiftPressed;
    final from = rows.indexWhere((r) => r.key == _anchor);
    final to = rows.indexOf(row);
    if (shift && from >= 0 && to >= 0) {
      final (start, end) = from < to ? (from, to) : (to, from);
      for (final r in rows.sublist(start, end + 1)) {
        if (r case ModRow(:final mod)) value ? ids.add(mod.id) : ids.remove(mod.id);
      }
    } else {
      value ? ids.add(row.mod.id) : ids.remove(row.mod.id);
    }
    _anchor = row.key;
    selection.state = ids;
  }

  void _pickAll(List<ModInfo> shown, bool value) {
    final selection = ref.read(allModsSelectionProvider.notifier);
    final ids = {for (final mod in shown) mod.id};
    selection.state = value ? {...selection.state, ...ids} : selection.state.difference(ids);
  }

  /// The bar over the ticked mods in [selected]. [shown] is how many mods the table shows, the most that can be ticked.
  Widget _selectionBar(List<ModInfo> selected, {required int shown}) {
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final container = ProviderScope.containerOf(context, listen: false);
    final checking = ref.watch(libraryCheckRunningProvider);
    final anyOff = selected.any((m) => !m.isActive);
    final anyOn = selected.any((m) => m.isActive);
    final checkable = planBulkUpdateCheck(selected).hasWork;
    final assumable = planBulkAssumeCurrent(selected);
    // Only while a ticked mod asks "Which file?": the rest have nothing to mark.
    final markCount = assumable.hasWork ? assumable.eligible.length : null;

    // Held off while a switch press lands too: under One at a time, a press and a bulk Enable running together could
    // leave two of a character's mods on.
    final busy = ref.watch(allModsBulkRunningProvider) || ref.watch(libraryTogglesProvider) > 0;

    Future<void> run(Future<void> Function() action) async {
      final running = container.read(allModsBulkRunningProvider.notifier);
      if (running.state || container.read(libraryTogglesProvider) > 0) return;
      running.state = true;
      try {
        await action();
      } finally {
        running.state = false;
      }
    }

    // Labelled where its widest form fits, and icons with their label as the tooltip otherwise. [selectedCount] and
    // [markCount] are what the labels count; the widest form counts every mod shown, with Mark as current showing.
    Widget bar({required bool compact, required int selectedCount, required int? markCount}) {
      Widget button(String label, IconData icon, VoidCallback? onPressed, {Color? color}) {
        final pressed = busy ? null : onPressed;
        // A coloured button, Delete, greys out with the rest while disabled.
        final foreground = color == null || pressed == null ? null : WidgetStatePropertyAll(color);
        if (compact) {
          return IconButton(
            style: smallButtonStyle(context, iconOnly: true).copyWith(foregroundColor: foreground),
            tooltip: label,
            onPressed: pressed,
            icon: Icon(icon),
          );
        }
        return OutlinedButton(
          style: smallButtonStyle(context).copyWith(foregroundColor: foreground),
          onPressed: pressed,
          child: Text(label),
        );
      }

      return Container(
        padding: const EdgeInsets.fromLTRB(16, 6, 6, 6),
        decoration: BoxDecoration(
          color: palette.toast.background,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: palette.toast.border!),
          boxShadow: [BoxShadow(color: palette.overlay, blurRadius: 48, offset: const Offset(0, 16))],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 6,
          children: [
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(
                loc.plural('library.all.selected', selectedCount, params: {'count': '$selectedCount'}),
                style: text.bodyMedium?.copyWith(color: palette.toast.foreground, fontWeight: FontWeight.w600),
              ),
            ),
            button(
              loc.t('library.all.enable'),
              Icons.toggle_on_outlined,
              anyOff ? () => run(() => bulkEnable(context, container, selected)) : null,
            ),
            button(
              loc.t('library.all.disable'),
              Icons.toggle_off_outlined,
              anyOn ? () => run(() => bulkDisable(context, container, selected)) : null,
            ),
            button(
              loc.t('library.all.check'),
              Icons.sync_rounded,
              checkable && !checking ? () => unawaited(LibraryActionsHost.of(context).checkMods(selected)) : null,
            ),
            if (markCount != null)
              button(
                loc.plural('library.all.assume_current', markCount, params: {'count': '$markCount'}),
                Icons.event_available_rounded,
                () => run(() => _assumeCurrent(assumable)),
              ),
            button(
              loc.t('library.all.delete'),
              Icons.delete_outline_rounded,
              () => run(() => bulkDelete(context, container, selected)),
              color: palette.redText,
            ),
            IconButton(
              style: smallButtonStyle(context, iconOnly: true),
              tooltip: loc.t('library.all.clear_selection'),
              onPressed: () => ref.read(allModsSelectionProvider.notifier).state = const {},
              icon: const Icon(Icons.close_rounded),
            ),
          ],
        ),
      );
    }

    return Semantics(
      container: true,
      label: loc.t('library.all.selection_actions'),
      child: _WideOrCompact(
        wide: bar(compact: false, selectedCount: selected.length, markCount: markCount),
        compact: bar(compact: true, selectedCount: selected.length, markCount: markCount),
        widest: bar(compact: false, selectedCount: shown, markCount: shown),
      ),
    );
  }
}

/// Lays out [wide] when [widest] fits with room to spare, and [compact] otherwise. Only the one laid out is painted,
/// pressed or read out; [widest] is only measured, so the choice doesn't change with what is ticked.
class _WideOrCompact extends StatefulWidget {
  const _WideOrCompact({required this.wide, required this.compact, required this.widest});

  final Widget wide;
  final Widget compact;
  final Widget widest;

  @override
  State<_WideOrCompact> createState() => _WideOrCompactState();
}

/// Keeps the hidden one out of keyboard focus, once layout has said which it is: Tab never lands on a button that
/// isn't drawn.
class _WideOrCompactState extends State<_WideOrCompact> {
  bool _compact = false;

  void _chosen(bool compact) {
    if (compact == _compact) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && compact != _compact) setState(() => _compact = compact);
    });
  }

  @override
  Widget build(BuildContext context) => _WideOrCompactLayout(
    onChosen: _chosen,
    children: [
      ExcludeFocus(excluding: _compact, child: widget.wide),
      ExcludeFocus(excluding: !_compact, child: widget.compact),
      ExcludeFocus(child: widget.widest),
    ],
  );
}

class _WideOrCompactLayout extends MultiChildRenderObjectWidget {
  const _WideOrCompactLayout({required this.onChosen, required super.children});

  /// Told after each layout whether the compact one is shown.
  final ValueChanged<bool> onChosen;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderWideOrCompact(onChosen);

  @override
  void updateRenderObject(BuildContext context, _RenderWideOrCompact renderObject) =>
      renderObject.onChosen = onChosen;

  @override
  MultiChildRenderObjectElement createElement() => _WideOrCompactElement(this);
}

/// Reports only the shown child as on stage, as `IndexedStack` does, so a finder sees one bar.
class _WideOrCompactElement extends MultiChildRenderObjectElement {
  _WideOrCompactElement(super.widget);

  @override
  void debugVisitOnstageChildren(ElementVisitor visitor) {
    final shown = (renderObject as _RenderWideOrCompact)._shown;
    for (final child in children) {
      if (child.renderObject == shown) visitor(child);
    }
  }
}

class _WideOrCompactParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderWideOrCompact extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _WideOrCompactParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _WideOrCompactParentData> {
  _RenderWideOrCompact(this.onChosen);

  ValueChanged<bool> onChosen;

  RenderBox? _shown;

  /// What the widest labelled bar must leave free on each side of the table, so it isn't drawn edge to edge.
  static const double _margin = 24;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _WideOrCompactParentData) child.parentData = _WideOrCompactParentData();
  }

  @override
  void performLayout() {
    final wide = firstChild!;
    final compact = childAfter(wide)!;
    final widest = childAfter(compact)!;
    final fits = widest.getMaxIntrinsicWidth(double.infinity) + _margin * 2 <= constraints.maxWidth;
    _shown = fits ? wide : compact;
    onChosen(!fits);
    // The others are laid out too, at no width, so the framework's bookkeeping holds; they are never painted.
    (fits ? compact : wide).layout(BoxConstraints.tight(Size.zero));
    widest.layout(BoxConstraints.tight(Size.zero));
    _shown!.layout(constraints.loosen(), parentUsesSize: true);
    size = constraints.constrain(_shown!.size);
  }

  @override
  void paint(PaintingContext context, Offset offset) => context.paintChild(_shown!, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      _shown!.hitTest(result, position: position);

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    if (_shown != null) visitor(_shown!);
  }

  @override
  double computeMinIntrinsicWidth(double height) => childAfter(firstChild!)!.getMinIntrinsicWidth(height);

  @override
  double computeMaxIntrinsicWidth(double height) => firstChild!.getMaxIntrinsicWidth(height);

  @override
  double computeMinIntrinsicHeight(double width) => firstChild!.getMinIntrinsicHeight(width);

  @override
  double computeMaxIntrinsicHeight(double width) => firstChild!.getMaxIntrinsicHeight(width);
}

/// The page's title, what the library holds and the whole-library check.
class _Header extends ConsumerStatefulWidget {
  const _Header({required this.mods, required this.sizes});

  final List<ModInfo> mods;
  final Map<String, int> sizes;

  @override
  ConsumerState<_Header> createState() => _HeaderState();
}

class _HeaderState extends ConsumerState<_Header> {
  /// Keeps "checked 2 min ago" true while the page is open.
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted && ref.read(libraryCheckedAtProvider) != null) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final mods = widget.mods;
    final scanned = ref.watch(libraryProvider.select((l) => l.hasValue));
    final checking = ref.watch(libraryCheckRunningProvider);
    final checkPlan = ref.watch(bulkUpdateCheckPlanProvider);
    final checkedAt = ref.watch(libraryCheckedAtProvider);
    final sizesReady = ref.watch(librarySizesProvider).hasValue;

    final agents = {
      for (final mod in mods)
        if (!isOtherType(libraryGroupOf(mod.characterId))) libraryGroupOf(mod.characterId),
    }.length;
    final active = mods.where((m) => m.isActive).length;
    final total = mods.fold<int>(0, (sum, m) => sum + (widget.sizes[m.id] ?? 0));
    final modCount = loc.plural('library.all.mods', mods.length, params: {'count': '${mods.length}'});
    final parts = [
      // "across 0 characters" says nothing when every mod is a UI, texture, audio or misc one.
      if (agents == 0)
        modCount
      else
        loc.t('library.all.summary', params: {
          'mods': modCount,
          'characters': loc.plural('library.all.characters', agents, params: {'count': '$agents'}),
        }),
      loc.plural('library.all.active', active, params: {'count': '$active'}),
      if (sizesReady && mods.isNotEmpty) formatBytes(total),
      if (checkedAt != null) _checkedAgo(loc, checkedAt),
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 24, 32, 16),
      child: Wrap(
        spacing: 16,
        runSpacing: 12,
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.end,
        children: [
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 6,
            children: [
              Text(loc.t('navigation.all_mods'), style: text.headlineLarge?.copyWith(color: palette.text)),
              if (scanned) Text(parts.join(' · '), style: text.bodyMedium?.copyWith(color: palette.text2)),
            ],
          ),
          OutlinedButton.icon(
            onPressed: checking || !checkPlan.hasWork
                ? null
                : () => unawaited(LibraryActionsHost.of(context).checkForUpdates()),
            icon: checking
                ? const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.sync_rounded),
            label: Text(loc.t('library.all.check_all')),
          ),
        ],
      ),
    );
  }

  String _checkedAgo(AppLocalizations loc, DateTime at) {
    final minutes = DateTime.now().difference(at).inMinutes;
    if (minutes < 1) return loc.t('library.all.checked_now');
    if (minutes < 60) return loc.plural('library.all.checked_minutes', minutes, params: {'count': '$minutes'});
    final hours = minutes ~/ 60;
    return loc.plural('library.all.checked_hours', hours, params: {'count': '$hours'});
  }
}

/// The search, the filter chips and the grouping.
class _FilterRow extends ConsumerWidget {
  const _FilterRow({required this.controller, required this.counts});

  final TextEditingController controller;
  final AllModsCounts counts;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final filter = ref.watch(allModsFilterProvider);
    final grouping = ref.watch(allModsGroupingProvider);

    Widget chip(AllModsFilter value, String key, {Color? countColor}) => ZenithChip(
      label: loc.t(key),
      count: counts.of(value),
      countColor: countColor,
      selected: filter == value,
      onTap: () => ref.read(allModsFilterProvider.notifier).state = value,
    );
    // Hidden at zero unless on: usually there are none, and a chip that is on must stay to be switched off.
    bool shows(AllModsFilter value) => filter == value || (counts.of(value) ?? 0) > 0;

    String groupLabel(AllModsGrouping value) => loc.t(switch (value) {
      AllModsGrouping.none => 'library.all.group_none',
      AllModsGrouping.character => 'library.all.group_character',
    });

    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 0, 32, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8,
        children: [
          Expanded(
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 280,
                  child: TextField(
                    controller: controller,
                    onChanged: (value) => ref.read(allModsSearchProvider.notifier).state = value,
                    style: text.bodyMedium?.copyWith(color: palette.text),
                    decoration: InputDecoration(
                      hintText: loc.t('library.all.search_hint'),
                      prefixIcon: const Icon(Icons.search_rounded),
                    ),
                  ),
                ),
                chip(AllModsFilter.all, 'library.grid.all'),
                chip(AllModsFilter.active, 'library.grid.active'),
                chip(AllModsFilter.off, 'library.all.off'),
                // No number before a check: "0 updates" and "not checked" are different claims.
                chip(AllModsFilter.updates, 'library.grid.updates'),
                if (shows(AllModsFilter.folderMissing)) chip(AllModsFilter.folderMissing, 'library.all.folder_missing'),
                chip(AllModsFilter.favorites, 'library.grid.favorites'),
                // Blue, the colour of a badge that asks for something.
                if (shows(AllModsFilter.needsAttention))
                  chip(AllModsFilter.needsAttention, 'library.all.cant_check', countColor: palette.badgeInfo.foreground),
              ],
            ),
          ),
          // Opens leftwards from the button's right edge: a menu too wide to open rightwards is otherwise pushed
          // flush against the window. Items of a fixed width are what let the offset put its right edge there, and
          // they fill the menu, so an item's hover reaches both sides.
          MenuAnchor(
            style: const MenuStyle(alignment: AlignmentDirectional.bottomEnd),
            alignmentOffset: const Offset(-_groupMenuWidth, 4),
            menuChildren: [
              for (final value in AllModsGrouping.values)
                SizedBox(
                  width: _groupMenuWidth,
                  child: MenuItemButton(
                    leadingIcon: Icon(grouping == value ? Icons.check_rounded : null),
                    onPressed: () => ref.read(allModsGroupingProvider.notifier).state = value,
                    child: Text(groupLabel(value)),
                  ),
                ),
            ],
            builder: (context, controller, _) => TextButton.icon(
              style: smallButtonStyle(context),
              onPressed: () => controller.isOpen ? controller.close() : controller.open(),
              icon: const Icon(Icons.expand_more_rounded),
              iconAlignment: IconAlignment.end,
              label: Text(
                loc.t(switch (grouping) {
                  AllModsGrouping.none => 'library.all.group_by',
                  AllModsGrouping.character => 'library.all.grouped_by_character',
                }),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A column of the table, and the narrowest the table may be for it to show.
enum _Column {
  check(36),
  mod(0),
  character(168),
  status(124),
  // The longest state, "Couldn't check" in Ukrainian, is 145px of text.
  updates(172),
  size(84),
  added(104),
  more(44);

  const _Column(this.width);

  /// Fixed width; [mod] takes what is left.
  final double width;
}

/// The narrowest the Mod column gets before a column is dropped.
const double _modMinWidth = 200;

/// The Group by menu's width, room for its longest choice with the check beside it.
const double _groupMenuWidth = 220;

/// A row's height: the canvas's 9px padding around the thumbnail and the two-line name and author.
const double _rowHeight = 55;

/// The columns that fit in [width], dropping Added, Size, Updates and Character in that order.
List<_Column> _columnsFor(double width) {
  final columns = [..._Column.values];
  const dropOrder = [_Column.added, _Column.size, _Column.updates, _Column.character];
  double fixed() => columns.fold(0.0, (sum, c) => sum + c.width);
  for (final column in dropOrder) {
    if (width - fixed() >= _modMinWidth) break;
    columns.remove(column);
  }
  return columns;
}

/// The table: a sticky header and the rows, grouped when asked, with the Folder missing note under them.
class _Table extends ConsumerWidget {
  const _Table({
    required this.rows,
    required this.session,
    required this.picked,
    required this.selectable,
    required this.selectedCount,
    required this.onPick,
    required this.onPickAll,
    required this.onOpenPage,
    required this.onContextMenu,
    required this.onShowUpdate,
    required this.onResolveOrigin,
  });

  final List<AllModsRow> rows;
  final AllModsContext session;
  final Set<String> picked;

  /// The mods shown that can be ticked: every mod row outside a folded group.
  final int selectable;
  final int selectedCount;
  final void Function(ModRow row, bool value) onPick;
  final void Function(bool value) onPickAll;
  final void Function(ModInfo mod) onOpenPage;
  final void Function(BuildContext context, ModInfo mod, Offset position) onContextMenu;
  final void Function(ModInfo mod) onShowUpdate;
  final void Function(ModInfo mod) onResolveOrigin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = context.loc;
    final grouping = ref.watch(allModsGroupingProvider);
    final groups = groupAllModsRows(rows, grouping, loc);
    final collapsed = ref.watch(allModsCollapsedProvider);
    final anyMissing = rows.any((r) => r is MissingRow);

    // Headings and rows as one list, so only the rows on screen are built. A folded group keeps its heading.
    final items = <Object>[
      for (final group in groups) ...[
        if (grouping != AllModsGrouping.none) group,
        if (grouping == AllModsGrouping.none || !collapsed.contains(allModsGroupKey(grouping, group))) ...group.rows,
      ],
      if (anyMissing) const _MissingNote(),
      if (ref.watch(allModsFilterProvider) == AllModsFilter.needsAttention) const _SortOutLine(),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        const gutter = 20.0;
        final columns = _columnsFor(constraints.maxWidth - gutter * 2);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: gutter),
              child: _HeaderRow(
                columns: columns,
                allPicked: selectable > 0 && selectedCount == selectable
                    ? true
                    : selectedCount == 0
                    ? false
                    : null,
                onPickAll: selectable == 0 ? null : onPickAll,
              ),
            ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(gutter, 0, gutter, 90),
                itemCount: items.length,
                itemBuilder: (context, index) => switch (items[index]) {
                  final AllModsGroup group => _GroupHeading(group: group),
                  final ModRow row => _ModTableRow(
                    key: ValueKey(row.key),
                    row: row,
                    columns: columns,
                    session: session,
                    picked: picked.contains(row.mod.id),
                    onPick: (value) => onPick(row, value),
                    onOpenPage: onOpenPage,
                    onContextMenu: onContextMenu,
                    onShowUpdate: onShowUpdate,
                    onResolveOrigin: onResolveOrigin,
                  ),
                  final MissingRow row => _MissingTableRow(key: ValueKey(row.key), row: row, columns: columns),
                  final Widget footer => footer,
                  _ => const SizedBox.shrink(),
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The column labels, the sortable ones pressable, and the box that ticks every row shown.
class _HeaderRow extends ConsumerWidget {
  const _HeaderRow({required this.columns, required this.allPicked, required this.onPickAll});

  final List<_Column> columns;

  /// True when every row shown is ticked, false when none is, null in between.
  final bool? allPicked;
  final void Function(bool value)? onPickAll;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final caps = ZenithType.of(context).caps.copyWith(color: palette.text3);
    final sort = ref.watch(allModsSortProvider);

    Widget label(String key, {AllModsColumn? sortBy, bool end = false}) {
      final on = sortBy != null && sort?.column == sortBy;
      final content = Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 4,
        children: [
          Flexible(
            child: Text(
              loc.t(key).toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: on ? caps.copyWith(color: palette.text) : caps,
            ),
          ),
          if (on) Icon(sort!.descending ? Icons.arrow_downward_rounded : Icons.arrow_upward_rounded, size: 12),
        ],
      );
      final aligned = Align(alignment: end ? Alignment.centerRight : Alignment.centerLeft, child: content);
      if (sortBy == null) return aligned;
      return Semantics(
        button: true,
        // What the arrow says, for a screen reader.
        value: on ? loc.t(sort!.descending ? 'library.all.sorted_descending' : 'library.all.sorted_ascending') : null,
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () => ref.read(allModsSortProvider.notifier).state = AllModsSort.next(sort, sortBy),
          child: aligned,
        ),
      );
    }

    Widget cell(_Column column) => switch (column) {
      _Column.check => Checkbox(
        tristate: true,
        value: allPicked,
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        semanticLabel: loc.t('library.all.select_all'),
        onChanged: onPickAll == null ? null : (_) => onPickAll!(allPicked != true),
      ),
      _Column.mod => label('library.all.col_mod', sortBy: AllModsColumn.name),
      _Column.character => label('library.all.col_character', sortBy: AllModsColumn.character),
      _Column.status => label('library.all.col_status', sortBy: AllModsColumn.status),
      _Column.updates => label('library.all.col_updates', sortBy: AllModsColumn.updates),
      _Column.size => label('library.all.col_size', sortBy: AllModsColumn.size, end: true),
      _Column.added => label('library.all.col_added', sortBy: AllModsColumn.added),
      _Column.more => const SizedBox.shrink(),
    };

    return Container(
      height: 38,
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: palette.outline))),
      child: _CellRow(columns: columns, cell: cell),
    );
  }
}

/// [columns] laid out at their widths, the Mod column taking the rest.
class _CellRow extends StatelessWidget {
  const _CellRow({required this.columns, required this.cell});

  final List<_Column> columns;
  final Widget Function(_Column column) cell;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (final column in columns)
          if (column == _Column.mod)
            Expanded(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: cell(column)))
          else
            SizedBox(
              width: column.width,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: column == _Column.check || column == _Column.more ? 0 : 12),
                child: cell(column),
              ),
            ),
      ],
    );
  }
}

/// A group's heading, pressed to fold its rows away or bring them back.
class _GroupHeading extends ConsumerWidget {
  const _GroupHeading({required this.group});

  final AllModsGroup group;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final characterId = group.characterId;
    final key = allModsGroupKey(ref.watch(allModsGroupingProvider), group);
    final folded = ref.watch(allModsCollapsedProvider).contains(key);
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Semantics(
        button: true,
        expanded: !folded,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          hoverColor: palette.rowHover,
          onTap: () {
            final collapsed = ref.read(allModsCollapsedProvider.notifier);
            collapsed.state = folded ? ({...collapsed.state}..remove(key)) : {...collapsed.state, key};
          },
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 12, 8),
            child: Row(
              spacing: 10,
              children: [
                AnimatedRotation(
                  turns: folded ? -0.25 : 0,
                  duration: const Duration(milliseconds: 150),
                  child: Icon(Icons.expand_more_rounded, color: palette.text3),
                ),
                if (characterId != null) CharacterTile(groupId: characterId, size: 22, radius: 6),
                Text(group.label, style: text.titleSmall?.copyWith(color: palette.text)),
                Text('${group.rows.length}', style: ZenithType.of(context).monoSmall.copyWith(color: palette.text3)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A mod's row: pressed it opens the mod's page; its box ticks it for the bulk actions.
class _ModTableRow extends ConsumerStatefulWidget {
  const _ModTableRow({
    super.key,
    required this.row,
    required this.columns,
    required this.session,
    required this.picked,
    required this.onPick,
    required this.onOpenPage,
    required this.onContextMenu,
    required this.onShowUpdate,
    required this.onResolveOrigin,
  });

  final ModRow row;
  final List<_Column> columns;
  final AllModsContext session;
  final bool picked;
  final ValueChanged<bool> onPick;
  final void Function(ModInfo mod) onOpenPage;
  final void Function(BuildContext context, ModInfo mod, Offset position) onContextMenu;
  final void Function(ModInfo mod) onShowUpdate;
  final void Function(ModInfo mod) onResolveOrigin;

  @override
  ConsumerState<_ModTableRow> createState() => _ModTableRowState();
}

class _ModTableRowState extends ConsumerState<_ModTableRow> {
  final GlobalKey _moreKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final mod = widget.row.mod;
    final session = widget.session;
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final mono = ZenithType.of(context).mono;
    final dim = text.bodyMedium?.copyWith(color: palette.text2);
    final none = Text('—', style: text.bodyMedium?.copyWith(color: palette.text3));

    Widget cell(_Column column) {
      switch (column) {
        case _Column.check:
          return Checkbox(
            value: widget.picked,
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            semanticLabel: loc.t('library.all.select', params: {'mod': mod.name}),
            onChanged: (value) => widget.onPick(value ?? false),
          );
        case _Column.mod:
          final author = session.authorOf(mod);
          return Row(
            spacing: 12,
            children: [
              ModThumb(mod: mod),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      spacing: 6,
                      children: [
                        Flexible(
                          child: Text(
                            mod.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.bodyMedium?.copyWith(color: palette.text, fontWeight: FontWeight.w600),
                          ),
                        ),
                        if (mod.isFavorite)
                          Icon(
                            Icons.star_rounded,
                            size: 14,
                            color: palette.accent,
                            semanticLabel: loc.t('library.card.favorite'),
                          ),
                      ],
                    ),
                    if (author != null)
                      Text(
                        author,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall?.copyWith(color: palette.text3),
                      ),
                  ],
                ),
              ),
            ],
          );
        case _Column.character:
          return Text(
            session.characterOf(mod),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: text.bodyMedium?.copyWith(color: palette.textProse),
          );
        case _Column.status:
          return Align(
            alignment: Alignment.centerLeft,
            child: mod.isActive
                ? ZenithBadge(label: loc.t('library.card.active'), tone: palette.badgeOn)
                : ZenithBadge(label: loc.t('library.card.off'), tone: palette.badgeNeutral),
          );
        case _Column.updates:
          return Align(alignment: Alignment.centerLeft, child: _updatesCell(mod, session.updatesOf(mod), none));
        case _Column.size:
          final bytes = session.sizes[mod.id];
          return Align(
            alignment: Alignment.centerRight,
            child: bytes == null ? none : Text(formatBytes(bytes), style: mono.copyWith(color: palette.text2)),
          );
        case _Column.added:
          final added = mod.origin?.installedAt;
          return added == null ? none : Text(formatResolveDate(added), style: dim);
        case _Column.more:
          return IconButton(
            key: _moreKey,
            style: smallButtonStyle(context, iconOnly: true),
            tooltip: loc.t('library.all.more', params: {'mod': mod.name}),
            onPressed: () {
              final box = _moreKey.currentContext!.findRenderObject()! as RenderBox;
              widget.onContextMenu(context, mod, box.localToGlobal(box.size.bottomLeft(Offset.zero)));
            },
            icon: const Icon(Icons.more_horiz_rounded),
          );
      }
    }

    return Material(
      color: widget.picked ? Color.lerp(palette.ground, palette.accent, 0.06) : palette.ground,
      child: InkWell(
        // The canvas's row hover is the card colour.
        hoverColor: palette.card,
        onTap: () => widget.onOpenPage(mod),
        onSecondaryTapDown: (details) => widget.onContextMenu(context, mod, details.globalPosition),
        child: Container(
          height: _rowHeight,
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: palette.rowDivider))),
          child: _CellRow(columns: widget.columns, cell: cell),
        ),
      ),
    );
  }

  /// The Updates cell: an amber badge opening the update dialog, a blue one or Not tracked opening the resolve
  /// dialog, or a grey fact. [none] is the table's "—".
  Widget _updatesCell(ModInfo mod, UpdatesCell state, Widget none) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final quiet = Theme.of(context).textTheme.bodyMedium?.copyWith(color: palette.text3);
    void resolve() => widget.onResolveOrigin(mod);
    void showUpdate() => widget.onShowUpdate(mod);

    Widget badge(String label, TonePair tone, String tooltip, VoidCallback onTap) =>
        ZenithBadge(label: loc.t(label), tone: tone, tooltip: loc.t(tooltip), onTap: onTap);
    // A dotted underline marks text with a tooltip, where a solid one is a link.
    Widget fact(String label, {String? tooltip}) {
      final text = Text(loc.t(label), maxLines: 1, overflow: TextOverflow.ellipsis, style: quiet);
      if (tooltip == null) return text;
      return Tooltip(
        message: loc.t(tooltip),
        child: MouseRegion(
          cursor: SystemMouseCursors.help,
          child: CustomPaint(foregroundPainter: _DottedUnderlinePainter(palette.text3), child: text),
        ),
      );
    }

    return switch (state) {
      UpdatesCell.newerFile =>
        badge('library.card.newer_file', palette.badgeUpdate, 'library.all.newer_file_tooltip', showUpdate),
      UpdatesCell.maybeNewer =>
        badge('library.card.maybe_newer', palette.badgeUpdate, 'mods.origin.possibly_outdated_tooltip', showUpdate),
      UpdatesCell.whichFile =>
        badge('library.card.file_unknown', palette.badgeInfo, 'mods.origin.version_unknown_tooltip', resolve),
      UpdatesCell.baseUnknown =>
        badge('library.card.base_unknown', palette.badgeInfo, 'mods.origin.second_identity_tooltip', resolve),
      UpdatesCell.notTracked => ZenithLink(
        loc.t('library.card.not_tracked'),
        onTap: resolve,
        style: quiet?.copyWith(decoration: TextDecoration.underline, decorationColor: palette.edge),
      ),
      UpdatesCell.notOnGameBanana => fact('library.all.not_on_gamebanana', tooltip: 'library.all.not_on_gamebanana_tooltip'),
      UpdatesCell.couldntCheck => fact('library.all.couldnt_check', tooltip: 'library.all.couldnt_check_tooltip'),
      // "Mark as current" records a date and no file, so the check went by the date.
      UpdatesCell.upToDate => fact(
        'library.all.up_to_date',
        tooltip: mod.origin?.base?.versionConfidence == OriginConfidence.assumedLatest
            ? 'library.all.up_to_date_by_date'
            : null,
      ),
      UpdatesCell.local => fact('library.card.local'),
      UpdatesCell.unchecked => none,
    };
  }
}

/// A link in ZZMI's mods folder whose folder is missing: its name, where it points, and the badge. Nothing to
/// press, since the only thing to do with it is bring the folder back.
class _MissingTableRow extends StatelessWidget {
  const _MissingTableRow({super.key, required this.row, required this.columns});

  final MissingRow row;
  final List<_Column> columns;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final none = Text('—', style: text.bodyMedium?.copyWith(color: palette.text3));
    final target = row.link.target;

    Widget cell(_Column column) => switch (column) {
      _Column.check || _Column.more => const SizedBox.shrink(),
      _Column.mod => Row(
        spacing: 12,
        children: [
          SizedBox(
            width: 44,
            height: 28,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(5),
              child: DottedGround(ground: palette.groundFor(ElementTone.neutral), spacing: 6),
            ),
          ),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  row.link.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodyMedium?.copyWith(color: palette.text, fontWeight: FontWeight.w600),
                ),
                if (target != null)
                  Tooltip(
                    message: target,
                    child: Text(
                      loc.t('library.all.points_at', params: {'path': target}),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ZenithType.of(context).monoSmall.copyWith(color: palette.text3),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
      _Column.status => Align(
        alignment: Alignment.centerLeft,
        child: ZenithBadge(label: loc.t('library.all.folder_missing'), tone: palette.badgeMissing),
      ),
      _Column.size => Align(alignment: Alignment.centerRight, child: none),
      _ => none,
    };

    return Container(
      height: _rowHeight,
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: palette.rowDivider))),
      child: _CellRow(columns: columns, cell: cell),
    );
  }
}

/// Under the table while the Can't be checked filter is on: the way to settle those mods, the Updates page.
class _SortOutLine extends ConsumerWidget {
  const _SortOutLine();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = ZenithPalette.of(context);
    final style = Theme.of(context).textTheme.bodySmall;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 0),
      child: Align(
        alignment: Alignment.centerLeft,
        child: ZenithLink(
          context.loc.t('library.all.sort_out'),
          onTap: () => ref.read(destinationProvider.notifier).state = AppDestination.updates,
          style: style?.copyWith(color: palette.link),
        ),
      ),
    );
  }
}

/// What Folder missing means, under a table that shows one.
class _MissingNote extends StatelessWidget {
  const _MissingNote();

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final tone = palette.noteMissing;
    final text = Theme.of(context).textTheme.bodySmall?.copyWith(color: tone.foreground);
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 18, 12, 0),
        constraints: const BoxConstraints(maxWidth: 760),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: tone.background,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: tone.border!),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 12,
          children: [
            Icon(Icons.link_off_rounded, color: palette.badgeMissing.foreground),
            Expanded(
              // One sentence to translate, with the term set in bold wherever the language puts it.
              child: Text.rich(
                TextSpan(
                  children: [
                    for (final (i, part) in loc.t('library.all.missing_note').split('{term}').indexed) ...[
                      if (i > 0)
                        TextSpan(
                          text: loc.t('library.all.folder_missing'),
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      TextSpan(text: part),
                    ],
                  ],
                ),
                style: text,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One-pixel dots, two pixels apart, along the bottom of a line of text. Drawn rather than a dotted text decoration,
/// which sits on the glyphs and blurs to nothing at 1x; the line box's leading puts these clear of the descenders.
class _DottedUnderlinePainter extends CustomPainter {
  _DottedUnderlinePainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    for (var x = 0.0; x < size.width; x += 2) {
      canvas.drawRect(Rect.fromLTWH(x, size.height - 1, 1, 1), paint);
    }
  }

  @override
  bool shouldRepaint(_DottedUnderlinePainter oldDelegate) => oldDelegate.color != color;
}
