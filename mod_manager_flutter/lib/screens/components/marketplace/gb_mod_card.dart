import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/palette.dart';
import '../../../l10n/app_localizations.dart';
import '../../../models/gamebanana/gb_file.dart';
import '../../../models/gamebanana/gb_mod.dart';
import '../../../services/download/download_queue.dart';
import '../../../services/gamebanana/content_filter.dart';
import '../../../services/gamebanana/file_selection.dart';
import '../../../services/update_check.dart';
import '../../../utils/marketplace_providers.dart';
import '../../../utils/notifications.dart';
import '../../../utils/relative_time.dart';
import '../../../utils/state_providers.dart';
import '../../dialogs/mod_update_dialog.dart';
import '../zenith_controls.dart';
import 'gb_thumbnail.dart';

/// One mod in the results grid, as the Browse artboard's card draws it: a 4:3 cover with its badges, the name and
/// "author · updated", likes and downloads, and one button.
///
/// The cover and the name open the mod page; the button acts on its own. Downloads show only when the page's
/// `Mod/Multi` enrichment carried a number: a listing has none, and "0 downloads" on a mod with 40 000 is worse than
/// no number.
class GbModCard extends ConsumerStatefulWidget {
  const GbModCard({
    super.key,
    required this.mod,
    required this.treatment,
    required this.onOpen,
    this.enrichment,
    this.installedAs = const <String>[],
    this.onInstallFile,
    this.bylineSubject,
    this.showCategory = true,
  });

  final GbMod mod;
  final ContentTreatment treatment;

  /// Opens the mod page.
  final VoidCallback onOpen;

  /// This mod's `Mod/Multi` record — download count, category and files — or null while it loads, when it failed,
  /// or for a mod GameBanana blanked.
  final GbMod? enrichment;

  /// Mod folders in the local library that came from this remote mod, or empty.
  ///
  /// A list rather than a bool because one GameBanana page routinely becomes several folders — two variants of one
  /// mod installed side by side. Keyed on the *mod*, not the file: which file is installed is the detail view's
  /// question.
  final List<String> installedAs;

  /// Queues [GbFile] as an install. Install calls it only when the enrichment lists exactly one current file;
  /// otherwise it opens the mod page, since a file is never picked for the user. Null opens the mod page always.
  final void Function(GbFile file)? onInstallFile;

  /// Who or what the byline names before the date: the author by default, the character on a creator's page,
  /// where every card has the same author.
  final String? bylineSubject;

  /// Whether the cover names the character or category at its top-right. A creator's page leaves it out, since its
  /// byline names it.
  final bool showCategory;

  /// The height of everything under the cover, at the current text scale: the name, the byline and the button row.
  /// Fixed, so a narrow card keeps its text and only the cover changes with the width.
  static double textBlockHeight(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scaler = MediaQuery.textScalerOf(context);
    // Rounded up, as text layout rounds a line to whole pixels.
    double line(TextStyle style) => (scaler.scale(style.fontSize!) * style.height!).ceilToDouble();
    const top = 12.0;
    const gap = 3.0;
    const buttonRow = 12.0 + 30.0 + 12.0;
    return top + line(text.titleSmall!) + gap + line(text.bodySmall!) + buttonRow;
  }

  /// The grid's tile height for a card [width] wide: a 4:3 cover inside the 1px border, and the text block.
  static double extentFor(BuildContext context, double width) => (width - 2) * 3 / 4 + textBlockHeight(context) + 2;

  @override
  ConsumerState<GbModCard> createState() => _GbModCardState();
}

enum _CardAction { install, queued, inLibrary, update }

/// The narrowest the character badge is drawn: its padding and a few letters. Below it the badge is left out.
const double _categoryMinWidth = 48;

class _GbModCardState extends ConsumerState<GbModCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    final mod = widget.mod;
    final folders = widget.installedAs;

    // Selected down to a bool: the queue changes on every progress tick, and a grid of cards rebuilding for each
    // would be the whole grid redrawn several times a second.
    final queued =
        ref.watch(marketplacePendingInstallsProvider.select((ids) => ids.contains(mod.idRow))) ||
        ref.watch(downloadQueueProvider.select((jobs) => jobs.any((j) => !j.isTerminal && j.mod?.idRow == mod.idRow)));
    final hasUpdate =
        folders.isNotEmpty &&
        ref.watch(modUpdateChecksProvider.select((checks) => folders.any((f) => confirmedUpdate(checks[f]))));

    final action = queued
        ? _CardAction.queued
        : hasUpdate
        ? _CardAction.update
        : folders.isNotEmpty
        ? _CardAction.inLibrary
        : _CardAction.install;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          color: palette.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _hovered ? palette.edge : palette.outline),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Expanded rather than an AspectRatio: the grid sizes the tile so this is 4:3, and taking the remainder
            // keeps a rounding pixel from overflowing the fixed text block below.
            Expanded(child: _cover(context, palette, hasUpdate: hasUpdate)),
            SizedBox(height: GbModCard.textBlockHeight(context), child: _textBlock(context, palette, action)),
          ],
        ),
      ),
    );
  }

  Widget _cover(BuildContext context, ZenithPalette palette, {required bool hasUpdate}) {
    final loc = context.loc;
    final mod = widget.mod;
    final blurred = widget.treatment == ContentTreatment.blur;
    final category = widget.showCategory ? mod.displayCategory?.name ?? widget.enrichment?.category?.name : null;
    final installed = widget.installedAs.isNotEmpty;

    return Semantics(
      link: true,
      label: mod.name ?? loc.t('marketplace.untitled_mod'),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onOpen,
          child: Stack(
            fit: StackFit.expand,
            children: [
              GbThumbnail(image: mod.coverImage, treatment: widget.treatment),
              // No reveal on the card: a click opens the mod page, whose own reveal stays.
              if (blurred) _MatureOverlay(palette: palette),
              // After the overlay, so they read over the blur: owning a mod, or its character, is not adult content.
              // The badges on the left stay whole and the character takes what is left of the row, cut short or
              // left out, so neither covers the other at any width.
              Positioned(
                left: 10,
                top: 10,
                right: 10,
                child: Row(
                  spacing: 6,
                  children: [
                    if (hasUpdate)
                      ZenithBadge(label: loc.t('marketplace.badge_update'), tone: palette.badgeUpdate)
                    else if (installed)
                      ZenithBadge(
                        label: loc.t('marketplace.badge_installed'),
                        tone: palette.badgeOn,
                        // The folders go in the tooltip: the badge has room for one word at the narrow end.
                        tooltip: loc.t('marketplace.installed_as', params: {'mods': widget.installedAs.join(', ')}),
                      ),
                    if (mod.isObsolete)
                      ZenithBadge(label: loc.t('marketplace.badge_obsolete'), tone: palette.badgeOverArt),
                    Expanded(
                      child: category == null
                          ? const SizedBox.shrink()
                          : LayoutBuilder(
                              builder: (context, row) => row.maxWidth < _categoryMinWidth
                                  ? const SizedBox.shrink()
                                  : Align(
                                      alignment: AlignmentDirectional.centerEnd,
                                      child: _CategoryBadge(label: category, tone: palette.badgeOverArt),
                                    ),
                            ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _textBlock(BuildContext context, ZenithPalette palette, _CardAction action) {
    final loc = context.loc;
    final text = Theme.of(context).textTheme;
    final mod = widget.mod;
    final byline = _byline(loc, mod);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 3,
            children: [
              ZenithLink(
                mod.name ?? loc.t('marketplace.untitled_mod'),
                onTap: widget.onOpen,
                maxLines: 1,
                style: text.titleSmall!.copyWith(color: palette.text),
              ),
              Tooltip(
                message: byline.tooltip ?? '',
                child: Text(
                  byline.text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodySmall!.copyWith(color: palette.text3),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            spacing: 12,
            children: [
              Expanded(
                // Scaled down rather than clipped or overflowing: a count can reach "1.2M" and the button label
                // is longer in Ukrainian, at the narrowest card the grid makes.
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: AlignmentDirectional.centerStart,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    spacing: 12,
                    children: [
                      if (mod.likeCount case final likes?)
                        GbStat(icon: Icons.favorite_border_rounded, value: compactCount(likes)),
                      if (widget.enrichment?.downloadCount case final downloads?)
                        GbStat(icon: Icons.download_rounded, value: compactCount(downloads)),
                    ],
                  ),
                ),
              ),
              SizedBox(height: 30, child: _button(context, action)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _button(BuildContext context, _CardAction action) {
    final loc = context.loc;
    final style = smallButtonStyle(context);
    return switch (action) {
      _CardAction.install => FilledButton(style: style, onPressed: _install, child: Text(loc.t('marketplace.install'))),
      // Inert, as the download is already on its way and the panel is where it is followed, but drawn as the
      // default button rather than greyed: nothing is wrong with it.
      _CardAction.queued => OutlinedButton(
        style: style.copyWith(foregroundColor: WidgetStatePropertyAll(ZenithPalette.of(context).text)),
        onPressed: null,
        child: Text(loc.t('marketplace.queued')),
      ),
      _CardAction.inLibrary => TextButton(
        style: style,
        onPressed: () => showMarketplaceModInLibrary(context, ref, widget.installedAs),
        child: Text(loc.t('marketplace.in_library')),
      ),
      _CardAction.update => OutlinedButton(style: style, onPressed: _update, child: Text(loc.t('marketplace.update'))),
    };
  }

  /// Queues the mod's one current file, or opens the mod page when there are several, none, or no file list.
  void _install() {
    final file = selectDefaultFile(widget.enrichment?.files).file;
    final install = widget.onInstallFile;
    if (file != null && install != null) {
      install(file);
    } else {
      widget.onOpen();
    }
  }

  Future<void> _update() => updateMarketplaceMod(context, ref, widget.installedAs);

  ({String text, String? tooltip}) _byline(AppLocalizations loc, GbMod mod) {
    final author = widget.bylineSubject ?? mod.submitter?.name ?? '—';
    final added = mod.dateAdded;
    final updated = mod.dateUpdated;
    // `_tsDateUpdated` is null on a mod never updated, and some records echo the release date there, so a mod
    // reads as updated only when that date is later than its release.
    final hasUpdate = updated != null && (added == null || updated.isAfter(added));
    final date = hasUpdate ? updated : added;
    if (date == null) return (text: author, tooltip: null);
    final age = relativeAgeLabel(loc, date, DateTime.now().toUtc());
    return (
      text: loc.t(
        hasUpdate ? 'marketplace.card_byline_updated' : 'marketplace.card_byline_added',
        params: {'author': author, 'age': age},
      ),
      tooltip: loc.t(
        hasUpdate ? 'marketplace.last_updated' : 'marketplace.first_released',
        params: {'date': _absolute(date)},
      ),
    );
  }

  static String _absolute(DateTime date) {
    final d = date.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }
}

/// Whether [check] found a newer file. A possibly outdated mod is a guess, which Browse leaves to the Library to
/// raise, so it reads In library here.
bool confirmedUpdate(UpdateCheck? check) =>
    check != null && !check.dismissed && check.outcome == UpdateOutcome.updateAvailable;

/// The update dialog for the first of [folders], in library order, that has a newer file, as the Updates page opens
/// it; the library is read again when it wrote anything. A card's Update and the mod page's.
Future<void> updateMarketplaceMod(BuildContext context, WidgetRef ref, List<String> folders) async {
  final checks = ref.read(modUpdateChecksProvider);
  final target = ref.read(modsProvider).where((m) => folders.contains(m.id) && confirmedUpdate(checks[m.id])).firstOrNull;
  if (target == null) return;
  final container = ProviderScope.containerOf(context, listen: false);
  if (await showModUpdateDialog(context, target)) {
    await container.read(libraryProvider.notifier).rescan();
  }
}

/// The character or category name at the cover's top-right, `ZenithBadge`'s geometry with a label that is cut with an
/// ellipsis where its box ends. `ZenithBadge` hugs its label and cannot be cut.
class _CategoryBadge extends StatelessWidget {
  const _CategoryBadge({required this.label, required this.tone});

  final String label;
  final TonePair tone;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: tone.background,
        borderRadius: BorderRadius.circular(6),
        border: tone.border == null ? null : Border.all(color: tone.border!),
      ),
      // Placed in a box of bounded width, so the label may be flexible and hug or cut as it needs.
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(color: tone.foreground),
            ),
          ),
        ],
      ),
    );
  }
}

/// The blur mode's veil over a flagged cover: the crossed eye, "Mature content", and where that was set.
class _MatureOverlay extends StatelessWidget {
  const _MatureOverlay({required this.palette});

  final ZenithPalette palette;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final text = Theme.of(context).textTheme;
    return ColoredBox(
      color: palette.artworkScrim,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            spacing: 4,
            children: [
              Icon(Icons.visibility_off_outlined, size: 20, color: palette.onArtwork),
              Text(
                loc.t('marketplace.mature_content'),
                textAlign: TextAlign.center,
                style: text.bodyMedium!.copyWith(color: palette.artworkTitle, fontWeight: FontWeight.w600),
              ),
              Text(
                loc.t('marketplace.mature_blurred'),
                textAlign: TextAlign.center,
                style: text.labelSmall!.copyWith(
                  color: palette.onArtwork.withValues(alpha: 0.8),
                  fontWeight: FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A count with its 13px icon, the design's `.stat`: likes, downloads.
class GbStat extends StatelessWidget {
  const GbStat({super.key, required this.icon, required this.value, this.color});

  final IconData icon;
  final String value;

  /// Defaults to the hint grey.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final foreground = color ?? ZenithPalette.of(context).text3;
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 4,
      children: [
        Icon(icon, size: 13, color: foreground),
        Text(value, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: foreground)),
      ],
    );
  }
}

/// `12.3k` / `1.2M`. Popular ZZZ mods run to six figures of downloads, which would otherwise crowd the button.
String compactCount(int n) {
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
  return '$n';
}

/// How long ago [instant] was, in words: "3 days ago", "1 week ago", "just now". [relativeAge] picks the unit.
String relativeAgeLabel(AppLocalizations loc, DateTime instant, DateTime now) {
  final age = relativeAge(instant, now: now);
  final params = {'count': '${age.count}'};
  return switch (age.unit) {
    RelativeUnit.justNow => loc.t('time.just_now'),
    RelativeUnit.minutes => loc.plural('time.minutes_ago', age.count, params: params),
    RelativeUnit.hours => loc.plural('time.hours_ago', age.count, params: params),
    RelativeUnit.days => loc.plural('time.days_ago', age.count, params: params),
    RelativeUnit.weeks => loc.plural('time.weeks_ago', age.count, params: params),
    RelativeUnit.months => loc.plural('time.months_ago', age.count, params: params),
    RelativeUnit.years => loc.plural('time.years_ago', age.count, params: params),
  };
}

/// Shows the mod in the Library's Characters view with its details panel open: the first of [folders] in library
/// order, as the install notification's Open does. A folder gone since the library was read says so.
Future<void> showMarketplaceModInLibrary(BuildContext context, WidgetRef ref, List<String> folders) async {
  if (folders.isEmpty) return;
  final folder = ref.read(modsProvider).map((m) => m.id).where(folders.contains).firstOrNull ?? folders.first;
  final container = ProviderScope.containerOf(context, listen: false);
  final notify = context.notify;
  final gone = context.loc.t('notifications.mod_gone');
  if (await showModInCharacters(container, folder) == ShowModResult.notInLibrary) {
    notify.note(gone, body: folder);
  }
}
