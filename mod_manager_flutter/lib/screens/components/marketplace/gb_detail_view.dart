import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/palette.dart';
import '../../../core/type_scale.dart';
import '../../../l10n/app_localizations.dart';
import '../../../models/gamebanana/gamebanana.dart';
import '../../../services/api_service.dart';
import '../../../services/download/download_job.dart';
import '../../../services/gamebanana/content_filter.dart';
import '../../../services/gamebanana/file_selection.dart';
import '../../../services/gamebanana/remote_mod_metadata.dart';
import '../../../services/installed_mods_index.dart';
import '../../../utils/byte_format.dart';
import '../../../utils/html_to_markdown.dart';
import '../../../utils/markdown_description.dart';
import '../../../utils/marketplace_providers.dart';
import '../../../utils/state_providers.dart';
import '../../../utils/zzz_characters.dart';
import '../category_picker.dart';
import '../character_tile.dart';
import '../mod_detail_parts.dart' show SectionHeading;
import '../page_crumbs.dart';
import '../zenith_controls.dart';
import '../zenith_switch.dart';
import 'gb_file_list.dart';
import 'gb_mod_card.dart';
import 'gb_state_view.dart';
import 'gb_thumbnail.dart';

/// Queues [files] of [mod], one job each in the order given, filed under [characterId], to be installed or kept as
/// archives as [intent] says.
typedef GbQueueFiles =
    void Function(GbMod mod, List<GbFile> files, {required String? characterId, required DownloadIntent intent});

/// Asks which character or built-in category to install for, or Unassigned; null keeps the current one.
typedef CharacterPicker = Future<String?> Function(BuildContext context, {required String currentId});

/// The picker an install offers: `showCategoryPicker` with Unassigned among the categories.
Future<String?> pickInstallTarget(BuildContext context, {required String currentId}) =>
    showCategoryPicker(context, currentId: currentId, offerUnassigned: true);

/// Saves the Turn on after installing switch.
typedef TurnOnAfterInstallWriter = Future<void> Function(bool turnOn);

/// A mod's page in Browse, as the `BrowseMod` artboard draws it: the crumbs, then the gallery, the description and
/// the author's update posts beside a panel with the name, who installs it for whom, the files and the Install button.
///
/// Holds per-mod state, the gallery's picture, the reveal, the older files, the picked files and the character, so
/// it is keyed by mod id and starts afresh for each mod (`docs/marketplace.md` §3).
class GbDetailView extends ConsumerStatefulWidget {
  const GbDetailView({
    super.key,
    required this.modId,
    required this.onBack,
    required this.onQueue,
    required this.onOpenInBrowser,
    this.onBrowse,
    this.parent,
    this.onOpenCreator,
    this.pickCharacter = pickInstallTarget,
    this.turnOnWriter,
  });

  final int modId;

  /// Goes back one page.
  final VoidCallback onBack;

  /// Goes back to the grid: the Browse crumb, and the category crumb after it sets the chips. Defaults to [onBack],
  /// which is the same for a page opened from the grid.
  final VoidCallback? onBrowse;

  /// The page this one was opened from when that is not the grid, such as the creator's page, drawn as the crumb
  /// after Browse in place of the category.
  final Crumb? parent;

  /// Opens the author's page: the author's name in the panel is a link when this is set.
  final ValueChanged<GbSubmitter>? onOpenCreator;

  /// The mod is passed alongside the files because the origin block records remote *identity*, which is a property
  /// of the mod, not of a file.
  final GbQueueFiles onQueue;

  final void Function(String url) onOpenInBrowser;

  /// Seam for tests. Production is [pickInstallTarget].
  final CharacterPicker pickCharacter;

  /// Seam for tests, defaulting to `ApiService.setMarketplaceTurnOnAfterInstall`. `ApiService` writes the real
  /// `config.json`, so a test that flips the switch passes its own.
  final TurnOnAfterInstallWriter? turnOnWriter;

  /// The two columns' narrowest, from the artboard: side by side from here, stacked below it.
  static const double mainMin = 520;
  static const double sideMin = 340;
  static const double gap = 28;

  @override
  ConsumerState<GbDetailView> createState() => _GbDetailViewState();
}

class _GbDetailViewState extends ConsumerState<GbDetailView> {
  /// The width the thumbnails ask for, and therefore what the hero shows while its own copy loads: one constant, so
  /// the stand-in stays a cache hit rather than a second download.
  static const int _thumbWidth = 220;

  int _galleryIndex = 0;
  bool _revealed = false;
  bool _showArchived = false;

  /// The files picked, by id; null until the user picks, which leaves [defaultPickedFiles].
  Set<int>? _picked;

  /// The character, built-in category or Unassigned the user picked over the GameBanana category's, held while this
  /// page is open.
  String? _pickedCharacter;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final profile = ref.watch(modProfileProvider(widget.modId));

    return ColoredBox(
      color: palette.ground,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _crumbs(context, loc, profile.valueOrNull, failed: profile.hasError),
          Expanded(
            child: profile.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => GbFailureState(
                error: error,
                onRetry: () => ref.invalidate(modProfileProvider(widget.modId)),
              ),
              data: (mod) => _body(context, mod),
            ),
          ),
        ],
      ),
    );
  }

  /// Back, "Browse / Ellen Joe / Victorian Ballgown", and Open on GameBanana, the way out to everything this page
  /// doesn't draw: comments, threads, credits.
  Widget _crumbs(BuildContext context, AppLocalizations loc, GbMod? mod, {required bool failed}) {
    final url = mod?.profileUrl ?? 'https://gamebanana.com/mods/${widget.modId}';
    final category = mod?.displayCategory;
    return PageCrumbs(
      backTooltip: loc.t('marketplace.back'),
      onBack: widget.onBack,
      trail: [
        (label: loc.t('marketplace.title'), onTap: widget.onBrowse ?? widget.onBack),
        if (widget.parent case final parent?)
          parent
        else if (category?.name case final name?)
          (label: name, onTap: category!.idRow == null ? null : () => _showCategory(mod!, category)),
      ],
      // The id once the profile has failed: there is no name to show and never will be, and "Loading…" over a
      // message saying the load failed reads as a contradiction.
      current: mod?.name ?? (failed ? '#${widget.modId}' : loc.t('marketplace.loading')),
      trailing: TextButton.icon(
        style: smallButtonStyle(context),
        onPressed: () => widget.onOpenInBrowser(url),
        iconAlignment: IconAlignment.end,
        icon: const Icon(Icons.open_in_new_rounded, size: 16),
        label: Text(loc.t('marketplace.open_on_gamebanana')),
      ),
    );
  }

  /// The grid filtered by the mod's category, which for a ZZZ mod is usually its character: the chips are set as
  /// `MarketplaceQuery.showingCategory` says, and the page goes back to the grid.
  void _showCategory(GbMod mod, GbCategoryRef category) {
    final notifier = ref.read(marketplaceQueryProvider.notifier);
    notifier.state = notifier.state.showingCategory(
      id: category.idRow!,
      name: category.name,
      parentId: (mod.rootCategory ?? mod.superCategory)?.idRow,
    );
    (widget.onBrowse ?? widget.onBack)();
  }

  Widget _body(BuildContext context, GbMod mod) {
    final treatment = contentTreatment(mod.effectiveVisibility, ref.watch(contentFilterProvider));
    final installed = ref.watch(installedModsIndexProvider).valueOrNull ?? InstalledModsIndex.empty;
    final category = RemoteModMetadata.characterIdForCategory(mod.displayCategory?.name);
    // A category that maps to no character installs under Unassigned, said explicitly on the job, so the import
    // never falls back to guessing from the folder's name.
    final target = _pickedCharacter ?? category ?? unknownCharacterId;
    final picked = _picked ?? defaultPickedFiles(mod.files);

    final main = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 22,
      children: [
        ..._notices(context, mod, treatment),
        _gallery(context, mod, treatment, characterId: target),
        ?_about(context, mod),
        _GbUpdates(modId: mod.idRow),
      ],
    );
    final side = _GbInstallPanel(
      mod: mod,
      installedAs: installed.installsOfMod(mod.idRow),
      matchInstalled: (file) => installed.matchFile(fileId: file.idRow, md5: file.md5Checksum),
      characterId: target,
      pickedByUser: _pickedCharacter != null,
      categoryHasCharacter: category != null,
      onChangeCharacter: () => _changeCharacter(target, category ?? unknownCharacterId),
      picked: picked,
      onToggleFile: (file) => setState(() {
        // The picks as they are now, not as this build saw them: two presses can land before the next build.
        final next = {...(_picked ?? defaultPickedFiles(mod.files))};
        if (!next.remove(file.idRow)) next.add(file.idRow);
        _picked = next;
      }),
      showArchived: _showArchived,
      onToggleArchived: () => setState(() => _showArchived = !_showArchived),
      onQueue: (intent) => widget.onQueue(
        mod,
        [
          for (final file in [...?mod.files, ...?mod.archivedFiles])
            if (picked.contains(file.idRow)) file,
        ],
        characterId: target,
        intent: intent,
      ),
      turnOnWriter: widget.turnOnWriter ?? ApiService.setMarketplaceTurnOnAfterInstall,
      onOpenCreator: widget.onOpenCreator,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        const gutter = PageCrumbs.gutter;
        final width = constraints.maxWidth - gutter * 2;
        final free = width - GbDetailView.mainMin - GbDetailView.gap - GbDetailView.sideMin;
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(gutter, 24, gutter, 32),
          // The artboard's wrapping flex row: each column grows from its narrowest, 3 to 2, and below the two
          // narrowest side by side the panel goes under the main column.
          child: free < 0
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: GbDetailView.gap,
                  children: [main, side],
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: GbDetailView.gap,
                  children: [
                    SizedBox(width: GbDetailView.mainMin + free * 3 / 5, child: main),
                    SizedBox(width: GbDetailView.sideMin + free * 2 / 5, child: side),
                  ],
                ),
        );
      },
    );
  }

  /// Opens the picker. Picking what the category gives, its character or Unassigned for one with none, goes back to
  /// it, so the card says where it came from.
  Future<void> _changeCharacter(String current, String fromCategory) async {
    final id = await widget.pickCharacter(context, currentId: current);
    if (id == null || !mounted) return;
    setState(() => _pickedCharacter = id == fromCategory ? null : id);
  }

  List<Widget> _notices(BuildContext context, GbMod mod, ContentTreatment treatment) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    return [
      if (mod.isRemoteMissing) _Notice(message: loc.t('marketplace.remote_missing'), tone: palette.badgeMissing),
      // Not the same thing as removed: the mod still exists and still downloads, its author flagged it superseded.
      if (mod.isObsolete) _Notice(message: loc.t('marketplace.obsolete_notice'), tone: palette.badgeNeutral),
      if (treatment != ContentTreatment.show && !_revealed)
        _Notice(
          message: loc.t('marketplace.content_warning'),
          // The profile carries `_aContentRatings`, so this can name the reasons rather than only flag.
          detail: mod.contentRatings.values.join(', '),
          tone: palette.badgeUpdate,
          icon: Icons.warning_amber_rounded,
          action: TextButton(
            style: smallButtonStyle(context),
            onPressed: () => setState(() => _revealed = true),
            child: Text(loc.t('marketplace.content_reveal')),
          ),
        ),
    ];
  }

  /// The 16:9 picture with arrows, and a six-column grid of every picture under it. A mod with no pictures shows
  /// its character's dotted ground with its initials, as the Library's mod page does.
  Widget _gallery(BuildContext context, GbMod mod, ContentTreatment treatment, {required String characterId}) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final images = mod.images;
    final index = images.isEmpty ? 0 : _galleryIndex.clamp(0, images.length - 1);

    final Widget hero;
    if (images.isEmpty) {
      final ground = palette.groundFor(elementToneOf(characterId));
      hero = DottedGround(
        ground: ground,
        child: Center(
          child: OutlinedInitials(
            nameInitials(mod.name ?? ''),
            style: ZenithType.of(context).watermarkMedium,
            color: ground.stroke,
          ),
        ),
      );
    } else {
      hero = Stack(
        fit: StackFit.expand,
        children: [
          GbThumbnail(
            image: images[index],
            treatment: treatment,
            revealed: _revealed,
            minWidth: 800,
            fit: BoxFit.contain,
            // The width the thumbnails asked for, so the small copy fills the frame the instant the picture changes
            // and the 800px one paints over it, rather than a blank frame for the length of a download.
            placeholderMinWidth: _thumbWidth,
          ),
          if (images.length > 1) ...[
            Positioned(
              left: 12,
              top: 0,
              bottom: 0,
              child: Center(
                child: _GalleryArrow(
                  icon: Icons.chevron_left_rounded,
                  tooltip: loc.t('marketplace.previous'),
                  onPressed: index > 0 ? () => setState(() => _galleryIndex = index - 1) : null,
                ),
              ),
            ),
            Positioned(
              right: 12,
              top: 0,
              bottom: 0,
              child: Center(
                child: _GalleryArrow(
                  icon: Icons.chevron_right_rounded,
                  tooltip: loc.t('marketplace.next'),
                  onPressed: index < images.length - 1 ? () => setState(() => _galleryIndex = index + 1) : null,
                ),
              ),
            ),
          ],
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        AspectRatio(
          aspectRatio: 16 / 9,
          child: Container(
            key: const ValueKey('gallery_hero'),
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(color: palette.card, borderRadius: BorderRadius.circular(14)),
            foregroundDecoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: palette.outline),
            ),
            child: hero,
          ),
        ),
        if (images.length > 1)
          LayoutBuilder(
            builder: (context, constraints) {
              const columns = 6;
              const spacing = 8.0;
              // Floored to a hundredth so six cells and five gaps never sum past the row and wrap one early.
              final cell = ((constraints.maxWidth - spacing * (columns - 1)) / columns * 100).floorToDouble() / 100;
              return Wrap(
                spacing: spacing,
                runSpacing: spacing,
                children: [
                  for (var i = 0; i < images.length; i++)
                    SizedBox(
                      key: ValueKey('gallery_thumb_$i'),
                      width: cell,
                      height: cell * 10 / 16,
                      child: _Thumb(
                        image: images[i],
                        treatment: treatment,
                        revealed: _revealed,
                        minWidth: _thumbWidth,
                        shown: i == index,
                        label: loc.t('marketplace.picture', params: {'index': '${i + 1}', 'total': '${images.length}'}),
                        onTap: () => setState(() => _galleryIndex = i),
                      ),
                    ),
                ],
              );
            },
          ),
      ],
    );
  }

  /// About this mod: the description, the author's tags, and where both came from. Absent for a mod with neither.
  Widget? _about(BuildContext context, GbMod mod) {
    final html = mod.text;
    final hasText = html != null && html.trim().isNotEmpty;
    if (!hasText && mod.tags.isEmpty) return null;
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(loc.t('marketplace.about_title'), style: text.titleMedium?.copyWith(color: palette.text)),
        const SizedBox(height: 12),
        // `_sText` is HTML while every description this app renders is markdown, so it is converted rather than
        // handed to the markdown widget, which would show the tags.
        if (hasText) buildDescriptionMarkdown(context, htmlToMarkdown(html), onLaunchUrl: widget.onOpenInBrowser),
        // In the "Title: Value" form the library stores: an install copies these strings onto the mod, so a tag
        // reads the same on the page and on the folder it became.
        if (mod.tags.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [for (final tag in mod.tags) _TagChip(tag)],
            ),
          ),
        const SizedBox(height: 12),
        Text(loc.t('marketplace.text_source'), style: text.bodySmall?.copyWith(color: palette.text3)),
      ],
    );
  }
}

/// The panel beside the pictures: the badges, the name, who made it and when, whether the library has it, the
/// character it installs for, the files, and Install.
class _GbInstallPanel extends ConsumerWidget {
  const _GbInstallPanel({
    required this.mod,
    required this.installedAs,
    required this.matchInstalled,
    required this.characterId,
    required this.pickedByUser,
    required this.categoryHasCharacter,
    required this.onChangeCharacter,
    required this.picked,
    required this.onToggleFile,
    required this.showArchived,
    required this.onToggleArchived,
    required this.onQueue,
    required this.turnOnWriter,
    required this.onOpenCreator,
  });

  final GbMod mod;
  final List<String> installedAs;
  final InstalledFileMatch Function(GbFile file) matchInstalled;
  /// A roster id, a built-in category id, or [unknownCharacterId].
  final String characterId;
  final bool pickedByUser;
  final bool categoryHasCharacter;
  final VoidCallback onChangeCharacter;
  final Set<int> picked;
  final ValueChanged<GbFile> onToggleFile;
  final bool showArchived;
  final VoidCallback onToggleArchived;
  final ValueChanged<DownloadIntent> onQueue;
  final TurnOnAfterInstallWriter turnOnWriter;
  final ValueChanged<GbSubmitter>? onOpenCreator;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final turnOn = ref.watch(marketplaceTurnOnAfterInstallProvider);
    final group = libraryGroupName(characterId, loc);
    final count = picked.length;

    return Container(
      key: const ValueKey('install_panel'),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: palette.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: palette.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 18,
        children: [
          _header(context, loc, palette),
          if (installedAs.isNotEmpty) _InLibraryLine(folders: installedAs),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 8,
            children: [
              SectionHeading(loc.t('marketplace.install_for')),
              _InstallForCard(
                characterId: characterId,
                name: group,
                detail: loc.t(
                  pickedByUser
                      ? 'marketplace.picked_by_you'
                      : categoryHasCharacter
                      ? 'marketplace.picked_from_category'
                      : 'marketplace.no_category_character',
                ),
                onTap: onChangeCharacter,
              ),
            ],
          ),
          GbFileList(
            files: mod.files,
            archivedFiles: mod.archivedFiles,
            picked: picked,
            onToggle: onToggleFile,
            showArchived: showArchived,
            onToggleArchived: onToggleArchived,
            // Keyed on the file, not the mod: a mod being in the library says nothing about which of its files is.
            // Older files go through the same lookup, where a banked hash pays off most.
            matchInstalled: matchInstalled,
          ),
          Row(
            spacing: 10,
            children: [
              ZenithSwitch(
                value: turnOn,
                semanticLabel: loc.t('marketplace.turn_on_after_install'),
                onChanged: (on) => turnOnWriter(on),
              ),
              Expanded(
                child: GestureDetector(
                  onTap: () => turnOnWriter(!turnOn),
                  child: Text(
                    loc.t('marketplace.turn_on_after_install'),
                    style: text.bodyMedium?.copyWith(color: palette.text2),
                  ),
                ),
              ),
            ],
          ),
          SizedBox(
            height: 44,
            child: FilledButton.icon(
              key: const ValueKey('install_button'),
              style: ButtonStyle(textStyle: WidgetStatePropertyAll(text.titleSmall)),
              onPressed: count == 0 ? null : () => onQueue(DownloadIntent.install),
              icon: const Icon(Icons.download_rounded, size: 16),
              label: Text(
                count == 0
                    ? loc.t('marketplace.pick_a_file')
                    : loc.plural('marketplace.install_files', count, params: {'count': '$count'}),
              ),
            ),
          ),
          if (count > 0)
            Column(
              spacing: 8,
              children: [
                Text(
                  loc.t(
                    count == 1 ? 'marketplace.becomes_mod_under' : 'marketplace.each_becomes_mod_under',
                    params: {'character': group},
                  ),
                  textAlign: TextAlign.center,
                  style: text.bodySmall?.copyWith(color: palette.text3),
                ),
                TextButton(
                  style: smallButtonStyle(context),
                  onPressed: () => onQueue(DownloadIntent.keepArchive),
                  child: Text(loc.t('marketplace.download_without_installing')),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _header(BuildContext context, AppLocalizations loc, ZenithPalette palette) {
    final text = Theme.of(context).textTheme;
    final type = _typeLabel(loc);
    final category = mod.displayCategory?.name;
    final byline = _byline(context, loc, palette);
    final size = selectDefaultFile(mod.files).file?.filesize;
    final stats = [
      if (mod.likeCount case final likes?)
        loc.plural('marketplace.likes', likes, params: {'count': compactCount(likes)}),
      if (mod.downloadCount case final downloads?)
        loc.plural('marketplace.downloads', downloads, params: {'count': compactCount(downloads)}),
      if (size != null) formatBytes(size),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 8,
      children: [
        if (type != null || category != null)
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              if (type != null) ZenithBadge(label: type, tone: palette.badgeInfo),
              if (category != null) ZenithBadge(label: category, tone: palette.badgeNeutral),
            ],
          ),
        Text(
          mod.name ?? loc.t('marketplace.untitled_mod'),
          style: text.headlineMedium?.copyWith(color: palette.text),
        ),
        ?byline,
        if (stats.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Wrap(
              spacing: 16,
              runSpacing: 4,
              children: [
                for (final stat in stats) Text(stat, style: text.bodySmall?.copyWith(color: palette.text3)),
              ],
            ),
          ),
      ],
    );
  }

  /// "Character" for a Character Skins mod, else the type chip's label for its root, or the root's own name for a
  /// root the chips don't know. A profile filed directly under a root has no parent: its category is the root.
  String? _typeLabel(AppLocalizations loc) {
    final root = mod.rootCategory ?? mod.superCategory ?? mod.category;
    if (root?.idRow case final id?) {
      if (kTypeChipLabelKeys[id] case final key?) return loc.t(key);
    }
    return root?.name;
  }

  /// "by lacequeen · updated 5 days ago", with the date in its tooltip. The name is a link to the author's page.
  Widget? _byline(BuildContext context, AppLocalizations loc, ZenithPalette palette) {
    final style = Theme.of(context).textTheme.bodyMedium?.copyWith(color: palette.text2);
    final submitter = mod.submitter;
    final author = submitter?.name;
    final added = mod.dateAdded;
    final updated = mod.dateUpdated;
    // `_tsDateUpdated` is null on a mod never updated, and some records echo the release date there, so a mod reads
    // as updated only when that date is later than its release.
    final hasUpdate = updated != null && (added == null || updated.isAfter(added));
    final date = hasUpdate ? updated : added;
    final age = date == null
        ? null
        : loc.t(
            hasUpdate ? 'marketplace.updated_ago' : 'marketplace.added_ago',
            params: {'age': relativeAgeLabel(loc, date, DateTime.now().toUtc())},
          );
    if (author == null && age == null) return null;

    final spans = <InlineSpan>[];
    if (author != null) {
      // The name is cut out of the translated "by {author}", so it can be a link wherever the language puts it.
      const placeholder = '{author}';
      final template = loc.t('marketplace.by_author');
      final at = template.indexOf(placeholder);
      final open = onOpenCreator;
      if (at < 0 || open == null || submitter == null) {
        spans.add(TextSpan(text: loc.t('marketplace.by_author', params: {'author': author})));
      } else {
        spans.add(TextSpan(text: template.substring(0, at)));
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: Tooltip(
              message: loc.t('marketplace.creator.link_tooltip', params: {'author': author}),
              child: ZenithLink(author, onTap: () => open(submitter), style: style?.copyWith(color: palette.link)),
            ),
          ),
        );
        spans.add(TextSpan(text: template.substring(at + placeholder.length)));
      }
    }
    if (age != null) spans.add(TextSpan(text: author == null ? age : ' · $age'));

    final line = Text.rich(TextSpan(children: spans), style: style);
    if (date == null) return line;
    return Tooltip(
      message: loc.t(hasUpdate ? 'marketplace.last_updated' : 'marketplace.first_released', params: {'date': _absolute(date)}),
      child: line,
    );
  }

  static String _absolute(DateTime date) {
    final d = date.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }
}

/// "In your library as Ellen Swimsuit", with Show, which opens it in the Characters view, and Update when a folder
/// of the mod has a confirmed newer file this session, which opens the update dialog the card's Update opens.
class _InLibraryLine extends ConsumerWidget {
  const _InLibraryLine({required this.folders});

  final List<String> folders;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final hasUpdate = ref.watch(modUpdateChecksProvider.select((checks) => folders.any((f) => confirmedUpdate(checks[f]))));
    final link = text.bodyMedium?.copyWith(color: palette.link);
    return Wrap(
      spacing: 10,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          folders.length == 1
              ? loc.t('marketplace.installed_as', params: {'mods': folders.single})
              : loc.plural('marketplace.installed_as_count', folders.length, params: {'count': '${folders.length}'}),
          style: text.bodyMedium?.copyWith(color: palette.text2),
        ),
        ZenithLink(
          loc.t('marketplace.show_in_library'),
          onTap: () => showMarketplaceModInLibrary(context, ref, folders),
          style: link,
        ),
        if (hasUpdate)
          ZenithLink(loc.t('marketplace.update'), onTap: () => updateMarketplaceMod(context, ref, folders), style: link),
      ],
    );
  }
}

/// The character an install files its mods under, in the picked look of a file row: the portrait on its element's
/// tile, the name, where the choice came from, and Change.
class _InstallForCard extends StatelessWidget {
  const _InstallForCard({required this.characterId, required this.name, required this.detail, required this.onTap});

  final String characterId;
  final String name;
  final String detail;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10),
      side: BorderSide(color: pickedBorder(palette)),
    );
    return Material(
      key: const ValueKey('install_for'),
      color: pickedGround(palette),
      shape: shape,
      child: InkWell(
        customBorder: shape,
        hoverColor: palette.rowHover,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            spacing: 12,
            children: [
              CharacterTile(groupId: characterId, size: 30, radius: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name, style: text.bodyMedium?.copyWith(color: palette.text, fontWeight: FontWeight.w600)),
                    Text(detail, style: text.bodySmall?.copyWith(color: palette.text3)),
                  ],
                ),
              ),
              Text(loc.t('marketplace.change'), style: text.bodySmall?.copyWith(color: palette.text2)),
            ],
          ),
        ),
      ),
    );
  }
}

/// The author's update posts, newest first: the post's title, what changed, and how long ago. Not drawn while they
/// load, when they fail, or for a mod with none: the section is extra, and a spinner or an error there reports a
/// problem nobody asked about.
class _GbUpdates extends ConsumerWidget {
  const _GbUpdates({required this.modId});

  final int modId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final epoch = DateTime.fromMillisecondsSinceEpoch(0);
    final updates = [...?ref.watch(modUpdatesProvider(modId)).valueOrNull]
      ..sort((a, b) => (b.dateAdded ?? epoch).compareTo(a.dateAdded ?? epoch));
    if (updates.isEmpty) return const SizedBox.shrink();
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final now = DateTime.now().toUtc();
    return Column(
      key: const ValueKey('updates_section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 10,
      children: [
        Text(loc.t('marketplace.updates_title'), style: text.titleMedium?.copyWith(color: palette.text)),
        for (final post in updates)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: palette.dialog,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: palette.outline),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 14,
              children: [
                SizedBox(
                  width: 110,
                  child: Text(
                    post.name ?? loc.t('mods.update.notes_untitled'),
                    style: text.bodyMedium?.copyWith(color: palette.text, fontWeight: FontWeight.w600),
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 2,
                    children: [
                      for (final line in updatePostLines(post))
                        Text(
                          line,
                          maxLines: post.changeLog.isEmpty ? 3 : null,
                          overflow: post.changeLog.isEmpty ? TextOverflow.ellipsis : null,
                          style: text.bodyMedium?.copyWith(color: palette.textProse),
                        ),
                    ],
                  ),
                ),
                if (post.dateAdded case final date?)
                  Text(relativeAgeLabel(loc, date, now), style: text.bodySmall?.copyWith(color: palette.text3)),
              ],
            ),
          ),
      ],
    );
  }
}

/// What an update post says, as plain lines: its changelog entries one per line, or, for a post without one, its
/// text with the markup taken out, as one line.
List<String> updatePostLines(GbUpdate post) {
  if (post.changeLog.isNotEmpty) return [for (final entry in post.changeLog) entry.text];
  final html = post.text;
  if (html == null) return const [];
  final plain = htmlToMarkdown(html)
      .replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), '')
      .replaceAllMapped(RegExp(r'\[([^\]]*)\]\([^)]*\)'), (m) => m[1]!)
      .replaceAll(RegExp(r'(\*\*|__|~~|`)'), '')
      .replaceAll(RegExp(r'^\s*(#+|>|[-*+])\s+', multiLine: true), '')
      .split(RegExp(r'\s*\n\s*'))
      .where((line) => line.isNotEmpty)
      .join(' ');
  return plain.isEmpty ? const [] : [plain];
}

/// A notice over the gallery: the mod is gone from GameBanana, flagged obsolete, or flagged as adult content.
class _Notice extends StatelessWidget {
  const _Notice({required this.message, required this.tone, this.detail, this.icon = Icons.info_outline_rounded, this.action});

  final String message;
  final String? detail;
  final TonePair tone;
  final IconData icon;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: tone.background,
        borderRadius: BorderRadius.circular(10),
        border: tone.border == null ? null : Border.all(color: tone.border!),
      ),
      child: Row(
        spacing: 10,
        children: [
          Icon(icon, size: 18, color: tone.foreground),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(message, style: text.bodyMedium?.copyWith(color: tone.foreground, fontWeight: FontWeight.w600)),
                if (detail case final detail? when detail.isNotEmpty)
                  Text(detail, style: text.bodySmall?.copyWith(color: tone.foreground)),
              ],
            ),
          ),
          ?action,
        ],
      ),
    );
  }
}

/// One of the author's tags, in a neutral badge's look, cut with an ellipsis where the row ends.
class _TagChip extends StatelessWidget {
  const _TagChip(this.tag);

  final String tag;

  @override
  Widget build(BuildContext context) {
    final tone = ZenithPalette.of(context).badgeNeutral;
    return Container(
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: tone.background,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: tone.border!),
      ),
      child: Align(
        widthFactor: 1,
        child: Text(
          tag,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: tone.foreground),
        ),
      ),
    );
  }
}

/// A thumbnail under the gallery: the one shown carries a 2px accent outline, the rest are faded to 55%.
class _Thumb extends StatelessWidget {
  const _Thumb({
    required this.image,
    required this.treatment,
    required this.revealed,
    required this.minWidth,
    required this.shown,
    required this.label,
    required this.onTap,
  });

  final GbImage image;
  final ContentTreatment treatment;
  final bool revealed;
  final int minWidth;
  final bool shown;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    final radius = BorderRadius.circular(7);
    return Semantics(
      button: true,
      selected: shown,
      label: label,
      child: Opacity(
        opacity: shown ? 1 : 0.55,
        child: Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(color: palette.card, borderRadius: radius),
          foregroundDecoration: shown
              ? BoxDecoration(borderRadius: radius, border: Border.all(color: palette.accent, width: 2))
              : null,
          child: Stack(
            fit: StackFit.expand,
            children: [
              GbThumbnail(image: image, treatment: treatment, revealed: revealed, minWidth: minWidth),
              Material(
                type: MaterialType.transparency,
                child: InkWell(onTap: onTap, hoverColor: palette.rowHover.withValues(alpha: 0.3)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// An arrow over the gallery's picture, in the Library mod page's shape, drawn on artwork whatever the theme. Null
/// [onPressed] disables it, which is how the ends of the gallery are shown: it clamps rather than wraps.
class _GalleryArrow extends StatelessWidget {
  const _GalleryArrow({required this.icon, required this.tooltip, required this.onPressed});

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    return IconButton(
      style: IconButton.styleFrom(
        backgroundColor: palette.artworkScrim,
        foregroundColor: palette.onArtwork,
        disabledBackgroundColor: palette.artworkScrim,
        disabledForegroundColor: palette.onArtwork.withValues(alpha: 0.4),
        fixedSize: const Size(36, 36),
        minimumSize: const Size(36, 36),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: palette.control),
        ),
      ),
      tooltip: onPressed == null ? null : tooltip,
      onPressed: onPressed,
      icon: Icon(icon),
    );
  }
}
