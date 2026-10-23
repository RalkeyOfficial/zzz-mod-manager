import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../models/gamebanana/gb_file.dart';
import '../../models/gamebanana/gb_mod.dart';
import '../../models/mod_download.dart';
import '../../models/mod_origin.dart';
import '../../models/origin_enums.dart';
import '../../services/gamebanana/file_selection.dart';
import '../../services/origin_summary.dart';
import '../../services/update_check_run.dart';
import '../../utils/gamebanana_url.dart';
import '../../utils/state_providers.dart';
import '../../utils/url_utils.dart';
import 'resolve/resolve_fragments.dart';

/// What a row's affordance does, for the rows a caller gives one.
///
/// Two actions rather than one, because the two entries a folder can hold were
/// not learned the same way. The mod a patch applies to is something a person
/// told us, so it can be told again — [change] reopens that question. A patch
/// the app installed into the folder carries an identity it fetched itself, and
/// the only thing left to say about it is that it is not there any more:
/// [remove] drops the record. Re-pointing that one would attach a claim to
/// bytes nobody moved.
enum FolderRowAction {
  /// Reopens the step that named this entry.
  change,

  /// Drops this entry from the folder's record. Touches nothing on disk.
  remove,
}

/// What to call one layer of a folder's stack, without fetching anything.
///
/// [fetched] first, a page this session holds; then the name saved with the
/// layer (`ModDownload.name`); then its id. Only a bottom layer with no id at
/// all is called by [folderName]: a folder can be named after its patch (a patch
/// installed as its own folder, with the mod it patches fetched in), so the
/// folder name is a fact about the folder and not about its base.
String downloadName(
  AppLocalizations loc,
  ModDownload download, {
  required String folderName,
  String? fetched,
}) {
  if (fetched?.trim() case final name? when name.isNotEmpty) return name;
  if (download.name case final name?) return name;
  if (download.modId case final id?) {
    return loc.t('mods.folder.unnamed', params: {'id': '$id'});
  }
  return download.role == DownloadRole.base
      ? folderName
      : loc.t('mods.folder.local_patch');
}

/// Which file a layer is, for telling it apart from another layer of its page:
/// [name] titles it and [detail] goes in grey beneath, as a file is named
/// everywhere else (`docs/update-checks.md` §7).
class LayerFile {
  const LayerFile(this.name, {this.detail});

  final String name;
  final String? detail;
}

/// Whether another layer of [origin] names [download]'s page.
bool sharesPage(ModOrigin? origin, ModDownload download) {
  final id = download.modId;
  if (id == null || origin == null) return false;
  return origin.downloads.where((layer) => layer.modId == id).length > 1;
}

/// [download]'s file, when another layer of [origin] shares its page and so
/// shares its name; null otherwise, or when nothing names the file.
///
/// The filename and its variant text when [file] or [page] has the file
/// record; without one, the variant text saved with the layer, then its
/// version. Never a tag: both rows already carry the Base or Patch badge.
LayerFile? sharedPageFile(
  ModOrigin? origin,
  ModDownload download, {
  GbMod? page,
  GbFile? file,
}) {
  if (!sharesPage(origin, download)) return null;
  final record = file ??
      switch (download.fileId) {
        final id? => fileWithId(page?.allFiles, id),
        null => null,
      };
  if (record != null) {
    return LayerFile(fileDisplayName(record), detail: fileDisplayDetail(record));
  }
  final label = download.versionLabel?.trim();
  if (label != null && label.isNotEmpty) return LayerFile(label);
  final version = download.version?.trim();
  if (version != null && version.isNotEmpty) return LayerFile(version);
  return null;
}

/// A layer named on one line, where there is no room for a second:
/// `<page> · <file>` when [file] tells it apart from another layer of its page.
String layerLine(String pageName, LayerFile? file) =>
    file == null ? pageName : '$pageName · ${file.name}';

/// **What this folder holds**, as a list of peers.
///
/// Shown by the resolve dialog. The details panel and the mod's page draw the
/// same stack in the canvas's own layout (`ModMadeOf`, `mod_detail_parts.dart`).
///
/// **Nothing here ranks the folder's own download above the other one.** Which
/// of a mod and its patch a sidecar stores in `origin`'s own fields is install
/// order; a section that made one of them the subject
/// and the other a footnote would put the same pair of mods in different places
/// depending on the order somebody happened to install them. Every entry gets
/// the same row, and the role — mod, or patch — is a label on it rather than a
/// position.
///
/// **Absent for a folder with one download.** A single-entry list is a heading
/// and a row restating the mod you are already looking at; and saying "nothing
/// else here" would be a claim about a scan this never performs.
///
/// **It names no name it was not given.** A companion records a mod id and never
/// a title — a name belongs to the remote, and a stored copy would be a second
/// source of truth for it — so a caller passes what it has fetched, the folder's
/// own entry falls back to the folder name, and a companion falls back to its
/// id. Always with a link, because an id is not something a person can act on.
class FolderDownloadsSummary extends ConsumerStatefulWidget {
  const FolderDownloadsSummary({
    super.key,
    required this.origin,
    required this.folderName,
    this.knownNames = const <int, String>{},
    this.notes = const <DownloadKey, String>{},
    this.lookUpNames = false,
    this.onEdit,
    this.rowActions = const <DownloadKey, FolderRowAction>{},
  });

  final ModOrigin? origin;

  /// Falls to the folder's own entry when nothing has fetched its page. Better
  /// than an id and better than a spinner: it is the name the user knows this
  /// thing by everywhere else in the app.
  final String folderName;

  /// Names the caller already has, by mod id. Anything missing is looked for in
  /// the session's fetched records, then [lookUpNames], then falls back as
  /// above.
  final Map<int, String> knownNames;

  /// One extra line per layer — the update dialog puts that download's own
  /// verdict here, which is what makes the list peers in substance and not just
  /// in layout.
  final Map<DownloadKey, String> notes;

  /// Fetch a missing name over the network, once each, when nothing local has
  /// one. Off by default; the callers' reasoning is in
  /// `docs/origin-tracking.md` §10.
  final bool lookUpNames;

  /// What acting on a row does. Which rows offer it, and which of the two
  /// actions each offers, comes from [rowActions].
  ///
  /// **On the row rather than beside the list.** A separate editable row below
  /// the list would put one download in a place of its own again, which is the
  /// asymmetry this section exists to remove. As an affordance *on* the row, an
  /// entry that can be acted on looks like every other entry and simply has one
  /// more thing on it.
  final void Function(ModDownload download)? onEdit;

  /// Which rows [onEdit] applies to, by layer, and what it does to each. By
  /// layer rather than mod id: a page can be the base and a patch at once, and
  /// the two rows take different actions.
  ///
  /// Explicit rather than derived: what can be done to an entry depends on
  /// which flows exist, not on anything visible in the row, and a widget
  /// guessing at it would offer a button that does nothing. Empty means no row
  /// has one.
  final Map<DownloadKey, FolderRowAction> rowActions;

  @override
  ConsumerState<FolderDownloadsSummary> createState() =>
      _FolderDownloadsSummaryState();
}

class _FolderDownloadsSummaryState
    extends ConsumerState<FolderDownloadsSummary> {
  /// Names fetched by this widget. Separate from
  /// [FolderDownloadsSummary.knownNames] so a rebuild cannot lose them and
  /// cannot overwrite what the caller supplied.
  final Map<int, String> _fetched = <int, String>{};
  final Set<int> _asked = <int>{};

  /// **The stack, as recorded.** No derivation and no reordering: the list is
  /// already bottom-up, which is the order the files themselves go on disk.
  List<ModDownload> get _downloads =>
      widget.origin?.downloads ?? const <ModDownload>[];

  @override
  void initState() {
    super.initState();
    _maybeLookUp();
  }

  @override
  void didUpdateWidget(FolderDownloadsSummary oldWidget) {
    super.didUpdateWidget(oldWidget);
    _maybeLookUp();
  }

  /// One request per unnamed download, at most once each.
  ///
  /// A failure is silent and leaves the fallback showing. Nothing here is
  /// load-bearing — the row already states the role, what is on record and a
  /// link — so a name that will not load is a cosmetic loss, and an error
  /// notice about it would be noise on a dialog opened to read something else.
  void _maybeLookUp() {
    if (!widget.lookUpNames) return;
    if (_downloads.length < 2) return;
    for (final download in _downloads) {
      final id = download.modId;
      if (id == null || _asked.contains(id)) continue;
      if (widget.knownNames.containsKey(id)) continue;
      if (ref.read(knownModPagesProvider).containsKey(id)) continue;
      _asked.add(id);
      fetchModRecord(ref.read(gameBananaClientProvider), id).then((record) {
        if (!mounted) return;
        keepModPages(ref, {id: record});
        final name = record.name;
        if (name == null || name.isEmpty) return;
        setState(() => _fetched[id] = name);
      }).catchError((_) {});
    }
  }

  String _nameOf(ModDownload download) {
    final id = download.modId;
    final fetched = id == null
        ? null
        : widget.knownNames[id] ??
            _fetched[id] ??
            ref.watch(knownModPagesProvider)[id]?.name;
    return downloadName(context.loc, download,
        folderName: widget.folderName, fetched: fetched);
  }

  @override
  Widget build(BuildContext context) {
    final downloads = _downloads;
    if (downloads.length < 2) return const SizedBox.shrink();

    final loc = context.loc;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          loc.t('mods.folder.heading'),
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        for (var i = 0; i < downloads.length; i++)
          _row(downloads[i], widget.origin!.keyAt(i)),
      ],
    );
  }

  Widget _row(ModDownload download, DownloadKey? key) {
    final loc = context.loc;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isPatch = download.role == DownloadRole.patch;
    final detail = _detailLine(loc, download);
    final note = key == null ? null : widget.notes[key];
    final file = sharedPageFile(widget.origin, download,
        page: ref.watch(knownModPagesProvider)[download.modId]);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // A coloured rule, the same marker the update dialog puts beside a
          // section header — so a patch is recognisable as one across the two
          // screens rather than being a different idea on each.
          Container(
            width: 3,
            height: 22,
            decoration: BoxDecoration(
              color: isPatch ? scheme.tertiary : scheme.primary,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _nameOf(download),
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                    const SizedBox(width: 6),
                    resolveChip(
                      loc.t(isPatch
                          ? 'mods.folder.role_patch'
                          : 'mods.folder.role_mod'),
                      isPatch ? scheme.tertiary : scheme.primary,
                    ),
                  ],
                ),
                // Two layers of one page carry one name, so each names its
                // file, with the variant text in grey beneath.
                if (file != null) ...[
                  const SizedBox(height: 2),
                  Text(file.name, style: theme.textTheme.bodySmall),
                ],
                if ((file == null
                        ? detail
                        : file.detail ?? (detail == file.name ? null : detail))
                    case final line?) ...[
                  const SizedBox(height: 2),
                  Text(
                    line,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
                if (note != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    note,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ],
            ),
          ),
          if (download.modId case final id?)
            IconButton(
              icon: const Icon(Icons.open_in_new, size: 16),
              tooltip: loc.t('mods.folder.open_page'),
              visualDensity: VisualDensity.compact,
              onPressed: () =>
                  launchExternalUrl(context, gameBananaModUrl(id)),
            ),
          if (widget.onEdit case final edit?)
            if (key != null)
              if (widget.rowActions[key] case final action?)
                IconButton(
                  icon: Icon(
                    switch (action) {
                      FolderRowAction.change => Icons.edit_outlined,
                      FolderRowAction.remove => Icons.delete_outline,
                    },
                    size: 16,
                  ),
                  tooltip: loc.t(switch (action) {
                    FolderRowAction.change => 'mods.folder.change',
                    FolderRowAction.remove => 'mods.folder.remove',
                  }),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => edit(download),
                ),
        ],
      ),
    );
  }

  /// What is worth saying about **which file** of this download is installed, or
  /// null when the answer is nothing.
  ///
  /// Deliberately **not** [describeRecordedFile], which the resolve surfaces use
  /// and which always produces a line. Three of its six phrasings are
  /// how-we-know with no *what* — "the file you chose", "the file you
  /// downloaded", "byte-identical to the archive you installed" — and a download
  /// carrying a `file_id` and no version string is the common case, since
  /// GameBanana's `_sVersion` is routinely null. On a row whose job is naming a
  /// download, that renders as filler.
  ///
  /// One of them would also be **wrong for the wrong layer**, which is why
  /// [summarizeDownload] reads that layer's own archive hash rather than only
  /// the folder's provenance: a patch the app fetched into a hand-imported
  /// folder is a file we downloaded, and calling it a checksum match credits
  /// the user with a choice they never made.
  ///
  /// What survives is the half a reader can act on: the version when there is
  /// one, and the caveat when the record is short of a file.
  String? _detailLine(AppLocalizations loc, ModDownload download) {
    final summary = summarizeDownload(
      download,
      provenance:
          widget.origin?.provenance ?? OriginProvenance.importedFolder,
    );
    return switch (summary.version) {
      VersionSummary.none ||
      VersionSummary.dateOnly ||
      VersionSummary.guessed =>
        describeRecordedFile(loc, summary),
      VersionSummary.chosen ||
      VersionSummary.downloaded ||
      VersionSummary.checksumMatched =>
        summary.versionLabel,
    };
  }
}
