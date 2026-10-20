import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/palette.dart';
import '../../core/type_scale.dart';
import '../../l10n/app_localizations.dart';
import '../../models/character_info.dart';
import '../../models/gamebanana/gb_mod.dart';
import '../../models/gamebanana/gb_update.dart';
import '../../models/mod_download.dart';
import '../../models/origin_enums.dart';
import '../../services/backup/snapshot_service.dart';
import '../../services/gamebanana/file_selection.dart';
import '../../services/installed_record.dart';
import '../../services/log/logger.dart';
import '../../services/origin_status.dart';
import '../../services/platform_service_factory.dart';
import '../../utils/home_relative.dart';
import '../../utils/categories.dart';
import '../../utils/state_providers.dart';
import '../../utils/url_utils.dart';
import '../../utils/zzz_characters.dart';
import '../components/character_tile.dart';
import '../components/mod_details_panel.dart' show canCheckForUpdate;
import '../components/mod_detail_parts.dart';
import '../components/mod_status_slot.dart';
import '../components/resolve/resolve_fragments.dart' show formatResolveDate;
import '../components/shader_part_summary.dart';
import '../components/zenith_controls.dart';
import '../shell/keycap.dart';
import 'mod_page_history.dart';

final Logger _log = Logger('mods');

/// A mod's page in the Library: its pictures, whether it is on, what can be done with it, and four tabs, Overview,
/// In-game keys, History and Note (`docs/library-screen.md` §15).
///
/// Shown in place of the character view, which stays mounted under it so the grid keeps its scroll position. Every
/// action is the Library's own, handed in, as the details panel's are.
///
/// Opening it fetches the GameBanana page of each download in the folder and the base mod's update feed, once: the
/// user asked to look at this mod, which a selection in passing is not. A mod marked Local, or with no page, fetches
/// nothing.
class LibraryModPage extends ConsumerStatefulWidget {
  const LibraryModPage({
    super.key,
    required this.mod,
    required this.initialTab,
    required this.onBack,
    required this.onToggle,
    required this.onFavoriteToggle,
    required this.onEdit,
    required this.onEditKeys,
    required this.onOpenFolder,
    required this.onCheckForUpdate,
    required this.onResolveOrigin,
    required this.onDelete,
    required this.onReinstall,
    required this.onRestore,
    required this.onTakeOut,
    required this.onStopIgnoring,
    this.noteWriter,
  });

  final ModInfo mod;
  final ModPageTab initialTab;
  final VoidCallback onBack;

  /// Null while the switch can't be pressed.
  final VoidCallback? onToggle;
  final VoidCallback onFavoriteToggle;
  final VoidCallback onEdit;
  final VoidCallback onEditKeys;
  final VoidCallback onOpenFolder;
  final VoidCallback onCheckForUpdate;
  final VoidCallback onResolveOrigin;
  final VoidCallback onDelete;
  final VoidCallback onReinstall;
  final ValueChanged<ModSnapshot> onRestore;
  final ValueChanged<ModDownload> onTakeOut;
  final ValueChanged<ModDownload> onStopIgnoring;
  final NoteWriter? noteWriter;

  /// The widths the hero and the tab body sit side by side from: the canvas's two columns at their narrowest.
  static const double _mainMin = 480;
  static const double _sideMin = 340;
  static const double _gap = 28;
  static const double _gutter = 32;

  @override
  ConsumerState<LibraryModPage> createState() => _LibraryModPageState();
}

class _LibraryModPageState extends ConsumerState<LibraryModPage> {
  late ModPageTab _tab = widget.initialTab;

  /// The base mod's update posts, newest first; null until they load, and for a mod that has none to load.
  List<GbUpdate>? _updates;

  /// Counts the fetches started, so one that lands after the mod was pointed elsewhere is dropped.
  int _fetches = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_fetch());
  }

  /// Tracking › change can point the mod at another page, mark it Local or set it up, all while the page is open.
  @override
  void didUpdateWidget(LibraryModPage old) {
    super.didUpdateWidget(old);
    if (_source(old.mod) == _source(widget.mod)) return;
    setState(() => _updates = null);
    unawaited(_fetch());
  }

  /// What the fetch depends on: whether the mod is tracked, and the pages its downloads name.
  static String _source(ModInfo mod) {
    final origin = mod.origin;
    return '${origin?.tracking}:${[for (final download in origin?.downloads ?? const <ModDownload>[]) download.modId]}';
  }

  Future<void> _fetch() async {
    final generation = ++_fetches;
    final origin = widget.mod.origin;
    if (origin == null || origin.tracking == OriginTracking.off) return;
    final ids = {for (final download in origin.downloads) ?download.modId};
    if (ids.isEmpty) return;
    final client = ref.read(gameBananaClientProvider);
    final pages = <int, GbMod>{};
    for (final id in ids) {
      try {
        pages[id] = await client.modProfile(id);
      } catch (e) {
        _log.warning('mod page did not load', error: e, fields: {'mod_id': id});
      }
    }
    List<GbUpdate>? updates;
    if (origin.base?.modId case final baseId?) {
      try {
        updates = await client.modUpdates(baseId);
      } catch (e) {
        _log.warning('update feed did not load', error: e, fields: {'mod_id': baseId});
      }
    }
    if (!mounted || generation != _fetches) return;
    keepModPages(ref, pages);
    // A fetch rewrites each download's saved name, as a check's does.
    unawaited(rememberDownloadNamesFrom(ref, pages));
    setState(() => _updates = updates);
  }

  @override
  Widget build(BuildContext context) {
    final mod = widget.mod;
    final palette = ZenithPalette.of(context);
    return ColoredBox(
      color: palette.ground,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Crumbs(mod: mod, onBack: widget.onBack),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final wide =
                    constraints.maxWidth - LibraryModPage._gutter * 2 >=
                    LibraryModPage._mainMin + LibraryModPage._gap + LibraryModPage._sideMin;
                return SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(LibraryModPage._gutter, 24, LibraryModPage._gutter, 0),
                        child: _columns(
                          wide: wide,
                          main: _Carousel(key: ValueKey('carousel_${mod.id}'), mod: mod),
                          side: _Summary(
                            mod: mod,
                            onToggle: widget.onToggle,
                            onFavoriteToggle: widget.onFavoriteToggle,
                            onEdit: widget.onEdit,
                            onOpenFolder: widget.onOpenFolder,
                            onCheckForUpdate: widget.onCheckForUpdate,
                            onResolveOrigin: widget.onResolveOrigin,
                            onDelete: widget.onDelete,
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      _TabBar(mod: mod, current: _tab, onSelect: (tab) => setState(() => _tab = tab)),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(LibraryModPage._gutter, 22, LibraryModPage._gutter, 32),
                        child: _columns(
                          wide: wide,
                          main: KeyedSubtree(key: ValueKey(_tab), child: _tabBody()),
                          side: _InTheFolder(mod: mod, onResolveOrigin: widget.onResolveOrigin),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// The main column and the side column, 3 to 2 side by side, or one above the other in a narrow window.
  Widget _columns({required bool wide, required Widget main, required Widget side}) {
    if (!wide) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: LibraryModPage._gap,
        children: [main, side],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: LibraryModPage._gap,
      children: [
        Expanded(flex: 3, child: main),
        Expanded(flex: 2, child: side),
      ],
    );
  }

  Widget _tabBody() {
    final mod = widget.mod;
    return switch (_tab) {
      ModPageTab.overview => _Overview(
        mod: mod,
        onResolveOrigin: widget.onResolveOrigin,
        onManageHistory: () => setState(() => _tab = ModPageTab.history),
      ),
      ModPageTab.keys => _Keys(mod: mod, onEditKeys: widget.onEditKeys),
      ModPageTab.history => ModHistoryTab(
        mod: mod,
        updates: _updates,
        onReinstall: widget.onReinstall,
        onRestore: widget.onRestore,
        onTakeOut: widget.onTakeOut,
        onStopIgnoring: widget.onStopIgnoring,
      ),
      ModPageTab.note => _Note(mod: mod, writer: widget.noteWriter),
    };
  }
}

/// Back, and where the page is: Characters / the character / the mod, or All mods / the mod and Updates / the mod
/// when it was opened from one of those.
class _Crumbs extends ConsumerWidget {
  const _Crumbs({required this.mod, required this.onBack});

  final ModInfo mod;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = switch (ref.watch(destinationProvider)) {
      AppDestination.allMods => 'navigation.all_mods',
      AppDestination.updates => 'navigation.updates',
      _ => null,
    };
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final style = Theme.of(context).textTheme.bodySmall;
    final crumb = style?.copyWith(color: palette.text3);
    final slash = Text('/', style: style?.copyWith(color: palette.check));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: LibraryModPage._gutter, vertical: 14),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: palette.divider)),
      ),
      child: Row(
        spacing: 8,
        children: [
          IconButton(
            style: smallButtonStyle(context, iconOnly: true),
            tooltip: loc.t('library.page.back'),
            onPressed: onBack,
            icon: const Icon(Icons.chevron_left_rounded),
          ),
          if (view != null)
            ZenithLink(loc.t(view), onTap: onBack, style: crumb)
          else ...[
            ZenithLink(loc.t('navigation.characters'), onTap: onBack, style: crumb),
            slash,
            ZenithLink(libraryGroupName(libraryGroupOf(mod.characterId), loc), onTap: onBack, style: crumb),
          ],
          slash,
          Flexible(
            child: Text(
              mod.name,
              overflow: TextOverflow.ellipsis,
              style: style?.copyWith(color: palette.text),
            ),
          ),
        ],
      ),
    );
  }
}

/// The mod's pictures one at a time, with arrows between them. A picture opens large when pressed. A mod with none
/// shows its character's dotted ground.
class _Carousel extends StatefulWidget {
  const _Carousel({super.key, required this.mod});

  final ModInfo mod;

  @override
  State<_Carousel> createState() => _CarouselState();
}

class _CarouselState extends State<_Carousel> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final images = widget.mod.images;
    final ground = palette.groundFor(elementToneOf(widget.mod.characterId));
    final index = _index.clamp(0, images.isEmpty ? 0 : images.length - 1);

    Widget arrow(IconData icon, String tooltip, int to) => IconButton(
      style: IconButton.styleFrom(
        backgroundColor: palette.artworkScrim,
        foregroundColor: palette.text,
        fixedSize: const Size(36, 36),
        minimumSize: const Size(36, 36),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: palette.control),
        ),
      ),
      tooltip: tooltip,
      onPressed: () => setState(() => _index = to % images.length),
      icon: Icon(icon),
    );

    final Widget content;
    if (images.isEmpty) {
      content = DottedGround(
        ground: ground,
        child: Center(
          child: OutlinedInitials(
            nameInitials(widget.mod.name),
            style: ZenithType.of(context).watermarkMedium,
            color: ground.stroke,
          ),
        ),
      );
    } else {
      content = Stack(
        fit: StackFit.expand,
        children: [
          MouseRegion(
            cursor: SystemMouseCursors.zoomIn,
            child: GestureDetector(
              onTap: () => showImageLightbox(context, images[index]),
              child: Image.file(
                File(images[index]),
                key: ValueKey(images[index]),
                fit: BoxFit.cover,
                cacheWidth: 1280,
                gaplessPlayback: true,
                errorBuilder: (_, __, ___) => DottedGround(ground: ground),
              ),
            ),
          ),
          if (images.length > 1) ...[
            Positioned(
              left: 12,
              top: 0,
              bottom: 0,
              child: Center(
                child: arrow(Icons.chevron_left_rounded, loc.t('library.page.previous_picture'), index - 1),
              ),
            ),
            Positioned(
              right: 12,
              top: 0,
              bottom: 0,
              child: Center(child: arrow(Icons.chevron_right_rounded, loc.t('library.page.next_picture'), index + 1)),
            ),
            Positioned(
              right: 14,
              bottom: 10,
              child: Text(
                '${index + 1} / ${images.length}',
                style: ZenithType.of(context).monoSmall.copyWith(color: palette.text.withValues(alpha: 0.4)),
              ),
            ),
          ],
        ],
      );
    }

    return AspectRatio(
      aspectRatio: 16 / 8,
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(14)),
        foregroundDecoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: palette.outline),
        ),
        child: content,
      ),
    );
  }
}

/// Beside the pictures: the badges, the name, who made it and when, the Active box and the mod's buttons.
class _Summary extends ConsumerWidget {
  const _Summary({
    required this.mod,
    required this.onToggle,
    required this.onFavoriteToggle,
    required this.onEdit,
    required this.onOpenFolder,
    required this.onCheckForUpdate,
    required this.onResolveOrigin,
    required this.onDelete,
  });

  final ModInfo mod;
  final VoidCallback? onToggle;
  final VoidCallback onFavoriteToggle;
  final VoidCallback onEdit;
  final VoidCallback onOpenFolder;
  final VoidCallback onCheckForUpdate;
  final VoidCallback onResolveOrigin;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final origin = mod.origin;
    final group = libraryGroupOf(mod.characterId);
    final (:page, file: recorded) = installedRecord(mod, ref.watch(knownModPagesProvider));
    final file = (origin?.base?.versionConfidence.namesFile ?? false) ? recorded : null;
    final check = ref.watch(modUpdateChecksProvider.select((checks) => checks[mod.id]));
    // The status badge says nothing for a tracked mod with nothing to report, and the canvas names the source there.
    final quietTracked =
        isQuietStatus(mod, modSlotStatus(origin, check)) &&
        origin?.tracking != OriginTracking.off &&
        (origin?.hasIdentity ?? false);

    final facts = [
      if (file?.dateAdded case final date?)
        loc.t('library.page.file_uploaded', params: {'date': formatResolveDate(date)}),
      if (origin?.installedAt case final date?)
        loc.t('library.page.installed', params: {'date': formatResolveDate(date)}),
    ];
    final author = page?.submitter?.name;

    final character = characterById(group);
    final oneAtATime = character != null && isOneAtATime(ref.watch(oneAtATimeProvider), group);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 16,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (mod.isActive) ZenithBadge(label: loc.t('library.card.active'), tone: palette.badgeOn),
            if (quietTracked)
              ZenithBadge(label: loc.t('library.details.tracking_gamebanana'), tone: palette.badgeInfo)
            else
              ModStatusSlot(mod: mod, onTap: onResolveOrigin, onShowUpdate: onCheckForUpdate),
            ZenithBadge(label: libraryGroupName(group, loc), tone: palette.badgeNeutral),
          ],
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 12,
          children: [
            Expanded(
              child: Text(mod.name, style: ZenithType.of(context).pageTitle.copyWith(color: palette.text)),
            ),
            IconButton.outlined(
              // Framed whether starred or not, as the canvas draws it: a selected outlined button drops its border.
              style: IconButton.styleFrom(
                side: BorderSide(color: palette.control),
                backgroundColor: palette.raised,
              ),
              tooltip: loc.t(mod.isFavorite ? 'mods.context_menu.favorite_remove' : 'mods.context_menu.favorite_add'),
              isSelected: mod.isFavorite,
              onPressed: onFavoriteToggle,
              icon: const Icon(Icons.star_outline_rounded),
              selectedIcon: const Icon(Icons.star_rounded),
            ),
          ],
        ),
        if (author != null)
          authorLine(
            context,
            template: [loc.t('library.details.by'), ...facts].join(' · '),
            author: author,
            onTap: () => openModLink(context, mod),
          )
        else if (facts.isNotEmpty)
          Text(facts.join(' · '), style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: palette.text2)),
        ModActiveBox(
          mod: mod,
          onToggle: onToggle,
          large: true,
          onBody: oneAtATime && mod.isActive
              ? loc.t('library.page.active_one_at_a_time', params: {'character': character.fullName})
              : null,
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: onEdit,
              icon: const Icon(Icons.edit_outlined),
              label: Text(loc.t('library.details.edit_info')),
            ),
            OutlinedButton.icon(
              onPressed: onOpenFolder,
              icon: const Icon(Icons.folder_outlined),
              label: Text(loc.t('library.details.open_folder')),
            ),
            if (modPageUrl(mod) != null)
              OutlinedButton.icon(
                onPressed: () => openModLink(context, mod),
                icon: const Icon(Icons.open_in_new_rounded),
                label: Text(loc.t('library.page.mod_page')),
              ),
            OutlinedButton.icon(
              onPressed: canCheckForUpdate(mod) ? onCheckForUpdate : null,
              icon: const Icon(Icons.sync_rounded),
              label: Text(loc.t('library.page.check_update')),
            ),
            Tooltip(
              message: loc.t('library.details.delete'),
              child: OutlinedButton(
                style: ButtonStyle(
                  fixedSize: const WidgetStatePropertyAll(Size(36, 36)),
                  minimumSize: const WidgetStatePropertyAll(Size(36, 36)),
                  padding: const WidgetStatePropertyAll(EdgeInsets.zero),
                  foregroundColor: WidgetStatePropertyAll(palette.redText),
                ),
                onPressed: onDelete,
                child: const Icon(Icons.delete_outline_rounded),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// The four tabs, each with a count where one means something.
class _TabBar extends ConsumerWidget {
  const _TabBar({required this.mod, required this.current, required this.onSelect});

  final ModInfo mod;
  final ModPageTab current;
  final ValueChanged<ModPageTab> onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final keys = modKeyRows(mod).length;
    final uid = mod.uid;
    final snapshots = uid == null ? 0 : (ref.watch(modSnapshotsProvider(uid)).valueOrNull?.length ?? 0);
    // The installed files the History tab lists: the one in use and each snapshot.
    final history = snapshots == 0 ? null : snapshots + 1;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: LibraryModPage._gutter),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: palette.divider)),
      ),
      child: Wrap(
        spacing: 22,
        children: [
          for (final (tab, label, count) in [
            (ModPageTab.overview, loc.t('library.page.tab_overview'), null),
            (ModPageTab.keys, loc.t('library.details.keys'), keys == 0 ? null : keys),
            (ModPageTab.history, loc.t('library.page.tab_history'), history),
            (ModPageTab.note, loc.t('library.details.note'), null),
          ])
            _Tab(label: label, count: count, selected: tab == current, onTap: () => onSelect(tab)),
        ],
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({required this.label, required this.count, required this.selected, required this.onTap});

  final String label;
  final int? count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        onTap: onTap,
        hoverColor: Colors.transparent,
        child: Container(
          height: 42,
          padding: const EdgeInsets.symmetric(horizontal: 2),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: selected ? palette.accent : Colors.transparent, width: 2)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 6,
            children: [
              Text(
                label,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(color: selected ? palette.text : palette.text2),
              ),
              if (count != null) Text('$count', style: ZenithType.of(context).monoSmall.copyWith(color: palette.text3)),
            ],
          ),
        ),
      ),
    );
  }
}

/// The description in full, the tags, what the folder is made of and the facts.
class _Overview extends StatelessWidget {
  const _Overview({required this.mod, required this.onResolveOrigin, required this.onManageHistory});

  final ModInfo mod;
  final VoidCallback onResolveOrigin;
  final VoidCallback onManageHistory;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final description = mod.description?.trim() ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeading(loc.t('library.page.about')),
        const SizedBox(height: 12),
        if (description.isNotEmpty)
          ModDescription(key: ValueKey('description_${mod.id}'), text: description, foldable: false)
        else
          Text(
            loc.t('library.page.no_description'),
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: palette.text3),
          ),
        if (mod.tags.isNotEmpty) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [for (final tag in mod.tags) ZenithBadge(label: tag, tone: palette.badgeNeutral)],
          ),
        ],
        ShaderPartSummary(folderName: mod.name),
        if ((mod.origin?.downloads.length ?? 0) > 1) ...[
          const SizedBox(height: 24),
          ModMadeOf(mod: mod, onManageHistory: onManageHistory, large: true),
        ],
        const SizedBox(height: 24),
        SectionHeading(loc.t('library.page.facts')),
        const SizedBox(height: 10),
        ModFacts(mod: mod, onResolveOrigin: onResolveOrigin),
      ],
    );
  }
}

/// Every key the mod's `.ini` binds, and the way to change them.
class _Keys extends StatelessWidget {
  const _Keys({required this.mod, required this.onEditKeys});

  final ModInfo mod;
  final VoidCallback onEditKeys;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final keys = modKeyRows(mod);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 12,
      children: [
        PageHeading(loc.t('library.details.keys'), aside: loc.t('library.details.keys_source')),
        if (keys.isEmpty)
          Text(loc.t('library.page.no_keys'), style: text.bodyMedium?.copyWith(color: palette.text3))
        else ...[
          ModKeysList(keys: keys, heading: false, radius: 12),
          Row(
            spacing: 12,
            children: [
              OutlinedButton.icon(
                onPressed: onEditKeys,
                icon: const Icon(Icons.keyboard_outlined),
                label: Text(loc.t('library.page.edit_keys')),
              ),
              Expanded(
                child: Text.rich(
                  TextSpan(children: keycapSentence(context, loc.t('library.page.keys_reload'), 'F10')),
                  style: text.bodySmall?.copyWith(color: palette.text3),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// The user's note, with room to write.
class _Note extends StatelessWidget {
  const _Note({required this.mod, required this.writer});

  final ModInfo mod;
  final NoteWriter? writer;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 12,
      children: [
        PageHeading(loc.t('library.details.note'), aside: loc.t('library.page.note_aside')),
        ModNoteField(
          key: ValueKey('note_${mod.id}'),
          modId: mod.id,
          writer: writer,
          label: false,
          minLines: 8,
          maxLines: 20,
        ),
      ],
    );
  }
}

/// Where the mod lives: the library folder, its link in ZZMI's Mods folder, and what it is tracked against.
class _InTheFolder extends ConsumerWidget {
  const _InTheFolder({required this.mod, required this.onResolveOrigin});

  final ModInfo mod;
  final VoidCallback onResolveOrigin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final home = PlatformServiceFactory.getInstance().homeDirectoryPath;
    final library = ref.watch(modsPathProvider);
    final links = ref.watch(linksFolderProvider);
    final zzmi = ref.watch(zzmiPathProvider);
    final (page: _, file: recorded) = installedRecord(mod, ref.watch(knownModPagesProvider));
    final named = mod.origin?.base?.versionConfidence.namesFile ?? false;
    final file = named && recorded != null ? fileDisplayName(recorded) : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 12,
      children: [
        PageHeading(loc.t('library.page.in_folder')),
        Text(
          loc.t('library.page.in_folder_note'),
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: palette.text3),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: FactRows(
            rows: [
              if (library.isNotEmpty)
                (
                  loc.t('library.page.stored_at'),
                  FactValue(homeRelative(p.join(library, mod.id), home: home), mono: true),
                ),
              (
                loc.t('library.page.linked_as'),
                // From the ZZMI folder itself, `ZZMI/Mods/<folder>`: where it lives is in the status bar.
                links != null && mod.isActive
                    ? FactValue(p.relative(p.join(links, mod.id), from: p.dirname(p.normalize(zzmi))), mono: true)
                    : FactValue(loc.t('library.page.not_linked')),
              ),
              (loc.t('library.details.tracking'), TrackingFact(mod: mod, onResolveOrigin: onResolveOrigin, file: file)),
            ],
          ),
        ),
      ],
    );
  }
}

/// A tab's heading in the canvas's 15px weight, with a quieter remark on the right.
class PageHeading extends StatelessWidget {
  const PageHeading(this.label, {super.key, this.aside});

  final String label;
  final String? aside;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      spacing: 12,
      children: [
        Text(label, style: text.titleMedium?.copyWith(color: palette.text)),
        if (aside != null)
          Expanded(
            child: Text(
              aside!,
              textAlign: TextAlign.right,
              style: text.bodySmall?.copyWith(color: palette.text3),
            ),
          )
        else
          const Spacer(),
      ],
    );
  }
}
