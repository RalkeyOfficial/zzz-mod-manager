import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/palette.dart';
import '../../core/type_scale.dart';
import '../../l10n/app_localizations.dart';
import '../../models/character_info.dart';
import '../../models/gamebanana/gb_mod.dart';
import '../../models/keybind_info.dart';
import '../../models/mod_download.dart';
import '../../models/origin_enums.dart';
import '../../services/api_service.dart';
import '../../services/gamebanana/file_selection.dart';
import '../../services/installed_record.dart';
import '../../services/update_check.dart';
import '../../utils/byte_format.dart';
import '../../utils/gamebanana_url.dart';
import '../../utils/markdown_description.dart';
import '../../utils/markdown_style.dart';
import '../../utils/notifications.dart';
import '../../utils/state_providers.dart';
import '../../utils/url_utils.dart';
import '../shell/keycap.dart';
import 'folder_downloads_summary.dart' show downloadName;
import 'resolve/resolve_fragments.dart' show formatResolveDate;
import 'zenith_controls.dart';
import 'zenith_switch.dart';

/// The pieces the details panel and a mod's page both draw: the description, the Active box, the in-game keys, the
/// downloads a folder is made of, the facts and the note.

/// Saves a mod's note. Production is `ApiService.setModNote`; tests inject one so typing never reaches the
/// developer's own `config.json`.
typedef NoteWriter = Future<bool> Function(String modId, String note);

/// A link in running text, in the body size.
class ModTextLink extends StatelessWidget {
  const ModTextLink(this.label, {super.key, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ZenithLink(
    label,
    onTap: onTap,
    style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: ZenithPalette.of(context).link),
  );
}

/// A link in the size of the line that explains something.
class SmallLink extends StatelessWidget {
  const SmallLink(this.label, {super.key, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ZenithLink(
    label,
    onTap: onTap,
    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: ZenithPalette.of(context).link),
  );
}

/// [template] with its `{author}` placeholder replaced by a link to [author], so each language puts the name where
/// its word order wants it.
Widget authorLine(BuildContext context, {required String template, required String author, required VoidCallback onTap}) {
  final palette = ZenithPalette.of(context);
  return Text.rich(
    TextSpan(
      children: [
        for (final (i, part) in template.split('{author}').indexed) ...[
          if (i > 0)
            WidgetSpan(
              alignment: PlaceholderAlignment.baseline,
              baseline: TextBaseline.alphabetic,
              child: ModTextLink(author, onTap: onTap),
            ),
          if (part.isNotEmpty) TextSpan(text: part),
        ],
      ],
    ),
    style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: palette.text2),
  );
}

/// Opens an image large over a dark backdrop. A tap anywhere closes it.
void showImageLightbox(BuildContext context, String imagePath) {
  final palette = ZenithPalette.of(context);
  showGeneralDialog(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: palette.overlay,
    transitionDuration: const Duration(milliseconds: 150),
    pageBuilder: (context, _, __) => GestureDetector(
      onTap: () => Navigator.of(context).pop(),
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Center(
          child: InteractiveViewer(
            maxScale: 5,
            child: Image.file(
              File(imagePath),
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => Icon(Icons.broken_image_outlined, size: 64, color: palette.text3),
            ),
          ),
        ),
      ),
    ),
  );
}

/// A description in markdown. [foldable] shows three lines' worth until the user asks for the rest.
class ModDescription extends StatefulWidget {
  const ModDescription({super.key, required this.text, this.foldable = true});

  final String text;
  final bool foldable;

  @override
  State<ModDescription> createState() => _ModDescriptionState();
}

class _ModDescriptionState extends State<ModDescription> {
  /// Around the More and Less word, on each side.
  static const double _morePadding = 6;

  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final markdown = buildDescriptionMarkdown(
      context,
      widget.text,
      onLaunchUrl: (href) => launchExternalUrl(context, href),
    );
    if (!widget.foldable) return markdown;
    // Three lines of the paragraph style the markdown is drawn in, plus the padding above the first.
    final sheet = buildMarkdownStyleSheet(context);
    final p = sheet.p;
    // Scaled as the text is, so a larger desktop text size still folds after the third line.
    final fontSize = MediaQuery.textScalerOf(context).scale(p?.fontSize ?? 13);
    final collapsed = fontSize * (p?.height ?? 1.45) * 3 + (sheet.pPadding?.top ?? 0);
    return LayoutBuilder(
      builder: (context, constraints) {
        // Long enough to need folding: a rough measure, since the markdown lays itself out.
        final long = widget.text.length > constraints.maxWidth / 6 * 3 || widget.text.contains('\n');
        if (!long) return markdown;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AnimatedSize(
              duration: const Duration(milliseconds: 160),
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: _expanded ? double.infinity : collapsed),
                // The markdown lays out at its full height inside a scroll view that can't be scrolled, and the clip
                // shows three lines of it. Squeezed into the box itself, its column overflows instead.
                child: ClipRect(
                  child: SingleChildScrollView(physics: const NeverScrollableScrollPhysics(), child: markdown),
                ),
              ),
            ),
            // A snug hover box, as wide around the word as it is tall, pulled left by its padding so the word lines
            // up with the description above it.
            Transform.translate(
              offset: const Offset(-_morePadding, 0),
              child: TextButton(
                style: smallButtonStyle(context).copyWith(
                  minimumSize: const WidgetStatePropertyAll(Size.zero),
                  padding: const WidgetStatePropertyAll(
                    EdgeInsets.symmetric(horizontal: _morePadding, vertical: 3),
                  ),
                  shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(6))),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: () => setState(() => _expanded = !_expanded),
                child: Text(loc.t(_expanded ? 'library.details.less' : 'library.details.more')),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The switch that turns the mod on, in a box tinted with the accent while it is on. [onBody] replaces the line
/// under "Active in game". The defaults are the panel's; the mod's page sets [large].
class ModActiveBox extends StatelessWidget {
  const ModActiveBox({super.key, required this.mod, required this.onToggle, this.onBody, this.large = false});

  final ModInfo mod;

  /// Null greys the switch out, as while the All mods table's bulk action runs.
  final VoidCallback? onToggle;
  final String? onBody;

  /// The page's box: radius 12 and 14/16 padding, where the panel's is radius 10 and 12/14.
  final bool large;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final on = mod.isActive;
    return Container(
      padding: large
          ? const EdgeInsets.symmetric(horizontal: 16, vertical: 14)
          : const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: on ? Color.lerp(palette.card, palette.accent, 0.09) : palette.card,
        borderRadius: BorderRadius.circular(large ? 12 : 10),
        border: Border.all(color: on ? Color.lerp(palette.outline, palette.accent, 0.3)! : palette.outline),
      ),
      child: Row(
        spacing: 12,
        children: [
          ZenithSwitch(
            value: on,
            semanticLabel: loc.t('library.card.toggle', params: {'name': mod.name}),
            onChanged: onToggle == null ? null : (_) => onToggle!(),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  loc.t(on ? 'library.details.active_title' : 'library.details.off_title'),
                  style: text.bodyMedium?.copyWith(color: palette.text, fontWeight: FontWeight.w600),
                ),
                Text(
                  onBody ?? loc.t(on ? 'library.details.active_body' : 'library.details.off_body'),
                  style: text.bodySmall?.copyWith(color: palette.text2),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The keys [mod]'s `.ini` binds, as (name, keys) pairs, leaving out entries with no key.
List<(String, String)> modKeyRows(ModInfo mod) => [
  for (final k in mod.keybinds ?? const <KeybindInfo>[])
    if (k.displayKeyValue case final value? when value.isNotEmpty) (k.displayName, value),
];

/// The keys a mod's `.ini` binds, each as keycaps. Tokens such as `no_shift` say which modifier must **not** be
/// held, so they are left out of the caps.
class ModKeysList extends StatelessWidget {
  const ModKeysList({super.key, required this.keys, this.heading = true, this.radius = 10});

  final List<(String, String)> keys;

  /// The caps heading above the list. A page whose tab already names it leaves it out.
  final bool heading;

  /// 10 in the panel, 12 on the mod's page.
  final double radius;

  static List<String> _caps(String value) => [
    for (final token in value.split(RegExp(r'\s+')))
      if (token.isNotEmpty && !token.toLowerCase().startsWith('no_'))
        token.length == 1 ? token.toUpperCase() : '${token[0].toUpperCase()}${token.substring(1)}',
  ];

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        if (heading) SectionHeading(loc.t('library.details.keys'), aside: loc.t('library.details.keys_source')),
        Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(color: palette.outline),
          ),
          child: Column(
            children: [
              for (var i = 0; i < keys.length; i++)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                  decoration: BoxDecoration(
                    border: i == keys.length - 1 ? null : Border(bottom: BorderSide(color: palette.divider)),
                  ),
                  child: Row(
                    spacing: 12,
                    children: [
                      Expanded(
                        child: Text(
                          keys[i].$1,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodyMedium?.copyWith(color: palette.text),
                        ),
                      ),
                      Wrap(spacing: 4, children: [for (final cap in _caps(keys[i].$2)) Keycap(cap)]),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A section's label in caps, and a quieter remark on the right: 11px in the panel, 12px on the mod's page ([large]).
class SectionHeading extends StatelessWidget {
  const SectionHeading(this.label, {super.key, this.aside, this.large = false});

  final String label;
  final String? aside;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      spacing: 12,
      children: [
        Expanded(
          child: Text(label.toUpperCase(), style: ZenithType.of(context).caps.copyWith(color: palette.text3)),
        ),
        if (aside != null)
          Flexible(
            child: Text(
              aside!,
              textAlign: TextAlign.right,
              style: (large ? Theme.of(context).textTheme.bodySmall : Theme.of(context).textTheme.labelSmall)
                  ?.copyWith(color: palette.text3, fontWeight: FontWeight.w400),
            ),
          ),
      ],
    );
  }
}

/// The downloads a folder is made of, in stack order: the base first, each patch above what it is written over
/// (`docs/origin-tracking.md` §10). Shown only for a folder with more than one.
///
/// Like the facts, a row's file, author and upload date come from a page this session holds, fetched by a check, an
/// install, a dialog or the mod's page, and are absent without one; the file and its date also need the file on
/// record to be confirmed.
class ModMadeOf extends ConsumerWidget {
  const ModMadeOf({super.key, required this.mod, this.onManageHistory, this.large = false});

  final ModInfo mod;

  /// The mod's page: radius 12 and its 12px side note, where the panel has radius 10 and 11px.
  final bool large;

  /// Opens the History tab of the mod's page, where the patches are taken out. Null leaves the link out, as the
  /// page's own History tab does.
  final VoidCallback? onManageHistory;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final downloads = mod.origin?.downloads ?? const <ModDownload>[];
    final records = ref.watch(knownModPagesProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        SectionHeading(
          loc.plural('library.details.made_of', downloads.length, params: {'count': '${downloads.length}'}),
          aside: loc.t('library.details.made_of_order'),
          large: large,
        ),
        Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(large ? 12 : 10),
            border: Border.all(color: palette.outline),
          ),
          child: Column(
            children: [
              for (final (i, download) in downloads.indexed)
                _DownloadRow(
                  download: download,
                  folderName: mod.name,
                  records: records,
                  last: i == downloads.length - 1,
                ),
            ],
          ),
        ),
        if (onManageHistory != null)
          Align(
            alignment: Alignment.centerLeft,
            child: SmallLink(loc.t('library.details.manage_history'), onTap: onManageHistory!),
          ),
      ],
    );
  }
}

class _DownloadRow extends StatelessWidget {
  const _DownloadRow({required this.download, required this.folderName, required this.records, required this.last});

  final ModDownload download;
  final String folderName;
  final Map<int, GbMod> records;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final (:page, file: recorded) = downloadRecord(download, records);
    final file = download.versionConfidence.namesFile ? recorded : null;
    final isBase = download.role == DownloadRole.base;

    final byline = [
      ?page?.submitter?.name,
      if (file?.dateAdded case final date?)
        loc.t('library.details.uploaded_on', params: {'date': formatResolveDate(date)}),
    ].join(' · ');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        border: last ? null : Border(bottom: BorderSide(color: palette.divider)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 10,
        children: [
          ZenithBadge(
            label: loc.t(isBase ? 'library.details.role_base' : 'library.details.role_patch'),
            tone: palette.badgeNeutral,
            minWidth: 46,
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 1,
              children: [
                DownloadTitle(download: download, folderName: folderName, page: page),
                if (file != null)
                  Text(
                    fileDisplayName(file),
                    style: ZenithType.of(context).monoSmall.copyWith(color: palette.text2, height: 1.4),
                  ),
                if (byline.isNotEmpty)
                  Text(byline, style: text.labelSmall?.copyWith(color: palette.text3, fontWeight: FontWeight.w400)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A download's name, linked to its GameBanana page when it has one: an id is not something a person can act on.
class DownloadTitle extends StatelessWidget {
  const DownloadTitle({super.key, required this.download, required this.folderName, required this.page});

  final ModDownload download;
  final String folderName;
  final GbMod? page;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final name = downloadName(loc, download, folderName: folderName, fetched: page?.name);
    final style = Theme.of(context).textTheme.bodyMedium?.copyWith(color: palette.text, fontWeight: FontWeight.w600);
    final modId = download.modId;
    if (modId == null) return Text(name, style: style);
    return Tooltip(
      message: loc.t('mods.folder.open_page'),
      child: ZenithLink(name, onTap: () => launchExternalUrl(context, gameBananaModUrl(modId)), style: style),
    );
  }
}

/// The base mod's verdict from this session's check, not the folder's: in a folder with a patch on top, the folder's
/// verdict can be the patch's.
UpdateCheck? baseUpdateCheck(ModInfo mod, UpdateCheck? check) {
  if (check == null) return null;
  if (check.layers.isNotEmpty) return check.layers.first.check;
  return check.subjectModId == mod.origin?.base?.modId ? check : null;
}

/// File, variant, upload date, tracking, when it was added, and its size.
class ModFacts extends ConsumerWidget {
  const ModFacts({super.key, required this.mod, required this.onResolveOrigin});

  final ModInfo mod;
  final VoidCallback onResolveOrigin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = context.loc;
    final origin = mod.origin;
    final base = origin?.base;
    final (page: _, file: recorded) = installedRecord(mod, ref.watch(knownModPagesProvider));
    final file = (base?.versionConfidence.namesFile ?? false) ? recorded : null;
    final check = ref.watch(modUpdateChecksProvider.select((checks) => checks[mod.id]));
    final size = ref.watch(modSizeProvider(mod.id)).valueOrNull;
    final baseCheck = baseUpdateCheck(mod, check);

    String? uploaded;
    if (file?.dateAdded case final date?) {
      final verdict = switch (baseCheck?.outcome) {
        UpdateOutcome.upToDate => loc.t('library.details.nothing_newer'),
        UpdateOutcome.updateAvailable => loc.t('library.details.newer_out'),
        _ => null,
      };
      uploaded = [formatResolveDate(date), ?verdict].join(' · ');
    }

    final installedAt = origin?.installedAt;
    return FactRows(
      rows: [
        if (file != null) (loc.t('library.details.file'), FactValue(fileDisplayName(file), mono: true)),
        if (base?.versionLabel case final label? when file != null && label.isNotEmpty)
          (loc.t('library.details.variant'), FactValue(label)),
        if (uploaded != null) (loc.t('library.details.uploaded'), FactValue(uploaded)),
        (loc.t('library.details.tracking'), TrackingFact(mod: mod, onResolveOrigin: onResolveOrigin)),
        if (installedAt != null) (loc.t('library.details.added'), FactValue(formatResolveDate(installedAt))),
        if (size != null && size.bytes > 0) (loc.t('library.details.size'), FactValue(formatBytes(size.bytes))),
      ],
    );
  }
}

/// Labels on the left in grey, values on the right.
class FactRows extends StatelessWidget {
  const FactRows({super.key, required this.rows});

  final List<(String, Widget)> rows;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    final style = Theme.of(context).textTheme.bodySmall;
    return Column(
      spacing: 8,
      children: [
        for (final (label, value) in rows)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 16,
            children: [
              Text(label, style: style?.copyWith(color: palette.text3)),
              Expanded(child: Align(alignment: Alignment.centerRight, child: value)),
            ],
          ),
      ],
    );
  }
}

/// One value of [FactRows]. [mono] for a file name or a path.
class FactValue extends StatelessWidget {
  const FactValue(this.value, {super.key, this.mono = false});

  final String value;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    final style = mono
        ? ZenithType.of(context).mono.copyWith(color: palette.text)
        : Theme.of(context).textTheme.bodySmall?.copyWith(color: palette.text);
    return Text(value, textAlign: TextAlign.right, style: style);
  }
}

/// "GameBanana · change", "Not tracked · set up" or "Local · change": the first half opens the page when there is
/// one, the second the resolve dialog. [file] goes between the two when given.
class TrackingFact extends StatelessWidget {
  const TrackingFact({super.key, required this.mod, required this.onResolveOrigin, this.file});

  final ModInfo mod;
  final VoidCallback onResolveOrigin;
  final String? file;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final style = Theme.of(context).textTheme.bodySmall;
    final origin = mod.origin;
    final (label, open, change) = origin?.tracking == OriginTracking.off
        ? (loc.t('library.details.tracking_local'), null, loc.t('library.details.tracking_change'))
        : (origin?.hasIdentity ?? false)
        ? (loc.t('library.details.tracking_gamebanana'), () => openModLink(context, mod), loc.t('library.details.tracking_change'))
        : (loc.t('library.details.tracking_none'), null, loc.t('library.details.tracking_set_up'));
    final dot = Text(' · ', style: style?.copyWith(color: palette.text3));
    return Wrap(
      alignment: WrapAlignment.end,
      children: [
        if (open != null) SmallLink(label, onTap: open) else Text(label, style: style?.copyWith(color: palette.textProse)),
        if (file != null) ...[dot, Text(file!, style: ZenithType.of(context).mono.copyWith(color: palette.text))],
        dot,
        SmallLink(change, onTap: onResolveOrigin),
      ],
    );
  }
}

/// The user's note on the mod, saved as they type (`docs/library-screen.md` §11).
///
/// Keyed by the mod, so selecting another mod disposes this one, and a note still waiting to be saved is saved on
/// the way out.
class ModNoteField extends ConsumerStatefulWidget {
  const ModNoteField({super.key, required this.modId, this.writer, this.label = true, this.minLines = 2, this.maxLines = 6});

  final String modId;
  final NoteWriter? writer;

  /// The caps label above the field. A page whose tab already names it leaves it out.
  final bool label;
  final int minLines;
  final int maxLines;

  @override
  ConsumerState<ModNoteField> createState() => _ModNoteFieldState();
}

class _ModNoteFieldState extends ConsumerState<ModNoteField> {
  static const Duration _pause = Duration(milliseconds: 600);

  late final TextEditingController _controller;
  final FocusNode _focus = FocusNode();
  Timer? _debounce;
  late String _saved;

  /// Held from the start, so a save on the way out can still publish and still report: by then `ref` and
  /// `context` may no longer be used.
  late final StateController<Map<String, String>> _notes;
  late NotificationCenter _notify;
  late String _failedTitle;

  @override
  void initState() {
    super.initState();
    _notes = ref.read(modNotesProvider.notifier);
    _saved = _notes.state[widget.modId] ?? '';
    _controller = TextEditingController(text: _saved);
    // The details panel's field stays alive under the mod's page, whose Note tab edits the same note: follow what
    // the other field saved, unless this one is being typed in.
    ref.listenManual(modNotesProvider.select((notes) => notes[widget.modId] ?? ''), (_, note) {
      if (note == _saved || _focus.hasFocus) return;
      _debounce?.cancel();
      _saved = note;
      _controller.text = note;
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _notify = context.notify;
    _failedTitle = context.loc.t('library.details.note_failed_title');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _save(duringDispose: true);
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// [duringDispose] publishes in a microtask: a dispose runs inside a build, where Riverpod refuses a provider
  /// write. The microtask is queued before the write starts, so it still lands first.
  void _save({bool duringDispose = false}) {
    final note = _controller.text;
    if (note == _saved) return;
    _saved = note;
    // Published before it is written, so a field rebuilt for this mod while the write is in flight shows what was
    // typed rather than the note before it.
    final notesController = _notes;
    final modId = widget.modId;
    void publish() {
      final notes = {...notesController.state};
      if (note.trim().isEmpty) {
        notes.remove(modId);
      } else {
        notes[modId] = note;
      }
      notesController.state = notes;
    }

    if (duringDispose) {
      scheduleMicrotask(publish);
    } else {
      publish();
    }
    final notify = _notify;
    final title = _failedTitle;
    unawaited(
      (widget.writer ?? ApiService.setModNote)(widget.modId, note).then((saved) {
        if (!saved) notify.error(title, body: widget.modId);
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 6,
      children: [
        if (widget.label)
          Text(
            loc.t('library.details.note').toUpperCase(),
            style: ZenithType.of(context).caps.copyWith(color: palette.text3),
          ),
        TextField(
          controller: _controller,
          focusNode: _focus,
          minLines: widget.minLines,
          maxLines: widget.maxLines,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: palette.text),
          decoration: InputDecoration(hintText: loc.t('library.details.note_hint')),
          onChanged: (_) {
            _debounce?.cancel();
            _debounce = Timer(_pause, _save);
          },
          // Saves, and lets go of the caret as a field does when you click elsewhere.
          onTapOutside: (_) {
            _save();
            FocusManager.instance.primaryFocus?.unfocus();
          },
        ),
      ],
    );
  }
}
