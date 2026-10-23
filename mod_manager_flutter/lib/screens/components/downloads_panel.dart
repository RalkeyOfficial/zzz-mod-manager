import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/palette.dart';
import '../../core/type_scale.dart';
import '../../l10n/app_localizations.dart';
import '../../models/character_info.dart';
import '../../models/gamebanana/gb_file.dart';
import '../../services/api_service.dart';
import '../../services/download/download_exceptions.dart';
import '../../services/download/download_job.dart';
import '../../services/download/download_progress.dart';
import '../../services/download/download_queue.dart';
import '../../services/download/queue_policy.dart';
import '../../services/gamebanana/content_filter.dart';
import '../../services/gamebanana/file_selection.dart';
import '../../services/log/logger.dart';
import '../../services/platform_service.dart';
import '../../services/platform_service_factory.dart';
import '../../services/shader_fixes/shader_fixes_service.dart';
import '../../utils/byte_format.dart';
import '../../utils/categories.dart';
import '../../utils/notification_actions.dart';
import '../../utils/notifications.dart';
import '../../utils/state_providers.dart';
import '../../utils/zzz_characters.dart';
import 'character_tile.dart';
import 'download_queue_host.dart';
import 'marketplace/gb_mod_card.dart';
import 'marketplace/gb_thumbnail.dart';
import 'network_link_notice.dart';
import 'resolve/resolve_fragments.dart';
import 'shader_fixes_notices.dart';
import 'zenith_controls.dart';

final Logger _log = Logger('ui.downloads');

/// The Downloads panel as a route on the root `Navigator`: from the right edge, under the title bar, over a scrim
/// that covers the sidebar and the page.
///
/// A route rather than an overlay entry, so it opens above whatever is on screen, a dialog included, and a question
/// dialog the host opens from a row lands above it. Escape, the scrim and the panel's own × close it.
class DownloadsPanelRoute extends RawDialogRoute<void> {
  DownloadsPanelRoute(BuildContext context)
      : super(
          pageBuilder: (context, animation, _) => Align(
            alignment: Alignment.centerRight,
            child: SlideTransition(
              position: Tween(begin: const Offset(1, 0), end: Offset.zero)
                  .animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
              child: const SizedBox(width: DownloadsPanel.width, height: double.infinity, child: DownloadsPanel()),
            ),
          ),
          barrierDismissible: true,
          barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
          barrierColor: ZenithPalette.of(context).downloadsScrim,
          transitionDuration: const Duration(milliseconds: 220),
          transitionBuilder: (context, animation, secondary, child) => child,
        );

  /// Closes the panel: animated when it is on top, at once when a dialog is above it.
  void close() {
    final navigator = this.navigator;
    if (!isActive || navigator == null) return;
    if (isCurrent) {
      navigator.pop();
    } else {
      navigator.removeRoute(this);
    }
  }
}

/// Everything the app is fetching or has fetched this session, grouped by what it needs (`docs/downloads.md` §13).
///
/// The Working notification says how far along a download is; this says what, exactly, and lets the user change it.
/// Finished rows stay until they are cleared, since a row that vanished on its own would take the only record of a
/// failure with it.
class DownloadsPanel extends ConsumerStatefulWidget {
  const DownloadsPanel({
    super.key,
    this.enabler = ApiService.enableMod,
    this.folderOpener,
    this.clock = DateTime.now,
  });

  static const double width = 440;

  /// Seam for tests. Production is `ApiService.enableMod`, the path every enable from the library takes.
  final ModEnabler enabler;

  /// Seam for tests: opens the folder a saved archive is in. Null opens it in the file manager.
  final NotificationFolderOpener? folderOpener;

  /// Seam for tests: the time the Finished rows' ages are measured from.
  final DateTime Function() clock;

  @override
  ConsumerState<DownloadsPanel> createState() => _DownloadsPanelState();
}

class _DownloadsPanelState extends ConsumerState<DownloadsPanel> {
  final ScrollController _scroll = ScrollController();

  /// Redraws the Finished rows' ages while the panel is open.
  late final Timer _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _close() {
    if (ModalRoute.of(context) case final DownloadsPanelRoute route) route.close();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(downloadsPanelCloseRequestProvider, (_, __) => _close());
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final jobs = ref.watch(downloadQueueProvider);
    final mods = ref.watch(modsProvider);
    final now = widget.clock();

    final attention = [for (final j in jobs) if (j.state == DownloadJobState.waiting) j];
    // A resumed download waiting for a slot stays with In progress, where its Resume was pressed.
    final inProgress = [
      for (final j in jobs)
        if (j.state.isActive && j.state != DownloadJobState.waiting && (j.state != DownloadJobState.queued || j.resumed))
          j,
    ];
    final waiting = [for (final j in jobs) if (j.state == DownloadJobState.queued && !j.resumed) j];
    final finished = [for (final j in jobs) if (j.isTerminal) j]..sort(_newestFirst);

    final groups = <(String, Color?, List<DownloadJob>)>[
      (loc.t('downloads.group_attention', params: {'count': '${attention.length}'}), palette.attentionTile.foreground, attention),
      (loc.t('downloads.group_in_progress'), null, inProgress),
      (loc.t('downloads.group_waiting'), null, waiting),
      (loc.t('downloads.group_finished'), null, finished),
    ].where((g) => g.$3.isNotEmpty).toList();

    final actions = _RowCallbacks(
      jobs: jobs,
      mods: mods,
      writing: ref.watch(modWritesInProgressProvider),
      now: now,
      turnOn: _turnOn,
      show: _show,
    );

    return Material(
      type: MaterialType.transparency,
      child: Container(
        decoration: BoxDecoration(
          color: palette.panel,
          border: Border(left: BorderSide(color: palette.line)),
          boxShadow: [BoxShadow(color: palette.downloadsShadow, offset: const Offset(-24, 0), blurRadius: 60)],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(showClear: finished.isNotEmpty, onClose: _close),
            Expanded(
              child: groups.isEmpty
                  ? Center(
                      child: Text(
                        loc.t('downloads.empty'),
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: palette.text3),
                      ),
                    )
                  : Scrollbar(
                      controller: _scroll,
                      child: SingleChildScrollView(
                        controller: _scroll,
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          spacing: 10,
                          children: [
                            for (final (i, (label, color, rows)) in groups.indexed) ...[
                              _GroupLabel(label, first: i == 0, color: color),
                              for (final job in rows) _DownloadRow(key: ValueKey(job.seq), job: job, actions: actions),
                            ],
                          ],
                        ),
                      ),
                    ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              decoration: BoxDecoration(border: Border(top: BorderSide(color: palette.divider))),
              child: Text(
                loc.t('downloads.footer'),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: palette.text3),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Turn on: the enable the library's switch runs, One at a time included, in turn with the library's other presses,
  /// and after a running bulk action of the All mods table has ended.
  Future<void> _turnOn(String modId) async {
    final container = ProviderScope.containerOf(context, listen: false);
    final notify = context.notify;
    final loc = context.loc;
    final enabler = widget.enabler;
    await bulkActionEnded(container);
    // The install's own scan may still be running, and the list before it has no such mod.
    if (container.read(libraryProvider).isLoading) {
      try {
        await container.read(libraryProvider.future);
      } catch (_) {
        // Read below as a mod not found.
      }
    }
    final library = container.read(libraryProvider.notifier);
    await container.read(libraryTogglesProvider.notifier).run(modId, () async {
      final mods = container.read(modsProvider);
      final mod = mods.where((m) => m.id == modId).firstOrNull;
      if (mod == null) {
        notify.note(loc.t('notifications.mod_gone'), body: modId);
        return;
      }
      if (mod.isActive) return;
      final switchOff = modsToSwitchOff(
        mods,
        mod,
        container.read(oneAtATimeProvider),
        beingWritten: container.read(modWritesInProgressProvider),
      );
      final failedTitle = loc.t('library.card.enable_failed_title');
      try {
        final done = await enabler(
          modId,
          switchOff: switchOff,
          whileWritten: (other) => turnOffDuringWrite(container, other),
        );
        if (!done) {
          notify.error(failedTitle, body: mod.name, characterId: mod.characterId);
          await library.rescan();
          return;
        }
        library.put([
          for (final m in container.read(modsProvider))
            if (m.id == modId)
              m.copyWith(isActive: true)
            else if (switchOff.contains(m.id))
              m.copyWith(isActive: false)
            else
              m,
        ]);
      } on ShaderPlacementRefused catch (refusal) {
        reportShaderRefusal(loc, notify, refusal, characterId: mod.characterId, container: container);
        await library.rescan();
      } on NetworkLinkRefused {
        reportNetworkLinkRefused(loc, notify, [mod.name], characterId: mod.characterId);
        await library.rescan();
      } catch (error) {
        _log.warning('mod not turned on from downloads', error: error, fields: {'mod': modId});
        notify.error(failedTitle, body: mod.name, characterId: mod.characterId);
        await library.rescan();
      }
    });
  }

  /// Show: the mod in the Characters view with its details panel open, the panel closed; for a saved archive, the
  /// folder it is in.
  Future<void> _show(DownloadJob job) async {
    final notify = context.notify;
    final loc = context.loc;
    if (job.outcome == JobOutcome.saved) {
      final folder = job.archive?.parent.path;
      if (folder == null) return;
      final open = widget.folderOpener ?? PlatformServiceFactory.getInstance().openFolderInFileManager;
      var ok = false;
      try {
        ok = await open(folder);
      } catch (_) {}
      if (!ok) notify.error(loc.t('notifications.open_folder_failed_title'), body: folder);
      return;
    }
    if (job.installed.isEmpty) return;
    final container = ProviderScope.containerOf(context, listen: false);
    final folder =
        container.read(modsProvider).map((m) => m.id).where(job.installed.contains).firstOrNull ?? job.installed.first;
    _close();
    if (await showModInCharacters(container, folder) == ShowModResult.notInLibrary) {
      notify.note(loc.t('notifications.mod_gone'), body: folder);
    }
  }
}

int _newestFirst(DownloadJob a, DownloadJob b) {
  final at = a.finishedAt;
  final bt = b.finishedAt;
  if (at != null && bt != null && at != bt) return bt.compareTo(at);
  return b.seq.compareTo(a.seq);
}

class _Header extends ConsumerWidget {
  const _Header({required this.showClear, required this.onClose});

  final bool showClear;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: palette.divider))),
      child: Row(
        spacing: 4,
        children: [
          Expanded(
            child: Text(
              loc.t('downloads.title'),
              style: ZenithType.of(context).panelTitle.copyWith(color: palette.text),
            ),
          ),
          if (showClear)
            TextButton(
              style: smallButtonStyle(context),
              onPressed: () => ref.read(downloadQueueProvider.notifier).clearFinished(),
              child: Text(loc.t('downloads.clear_finished')),
            ),
          IconButton(
            style: smallButtonStyle(context, iconOnly: true),
            tooltip: loc.t('downloads.close'),
            onPressed: onClose,
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
    );
  }
}

class _GroupLabel extends StatelessWidget {
  const _GroupLabel(this.text, {required this.first, this.color});

  final String text;
  final bool first;
  final Color? color;

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(2, first ? 4 : 12, 2, 4),
        child: Text(
          text.toUpperCase(),
          style: ZenithType.of(context).caps.copyWith(color: color ?? ZenithPalette.of(context).text3),
        ),
      );
}

/// What a row reads from the panel: the queue and the library, and the two calls that need the panel's context.
class _RowCallbacks {
  const _RowCallbacks({
    required this.jobs,
    required this.mods,
    required this.writing,
    required this.now,
    required this.turnOn,
    required this.show,
  });

  final List<DownloadJob> jobs;
  final List<ModInfo> mods;
  final Set<String> writing;
  final DateTime now;
  final Future<void> Function(String modId) turnOn;
  final Future<void> Function(DownloadJob job) show;

  ModInfo? mod(String id) => mods.where((m) => m.id == id).firstOrNull;

  /// The character the row is about: the one the job named, the one the install filed it under, else the installed
  /// mod's own as the library reads it.
  String? characterOf(DownloadJob job) {
    if (job.characterId ?? job.filedUnder case final id?) return id;
    for (final folder in job.installed) {
      if (mod(folder) case final found?) return found.characterId;
    }
    return null;
  }

  List<DownloadRowAction> actionsFor(DownloadJob job) => rowActions(
        job,
        jobs,
        modIsOn: (id) => mod(id)?.isActive ?? false,
        modBeingWritten: writing.contains,
      ).where((a) => a != DownloadRowAction.show || job.outcome == JobOutcome.saved || job.installed.isNotEmpty).toList();
}

class _DownloadRow extends ConsumerWidget {
  const _DownloadRow({super.key, required this.job, required this.actions});

  final DownloadJob job;
  final _RowCallbacks actions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final queue = ref.read(downloadQueueProvider.notifier);
    final questions = ref.read(downloadQuestionsProvider);
    final rowActions = actions.actionsFor(job);
    final nameStyle = text.bodyMedium?.copyWith(fontWeight: FontWeight.w600, color: palette.text);
    final lineStyle = text.bodySmall?.copyWith(color: palette.text3);
    final name = Text(job.subject, maxLines: 1, overflow: TextOverflow.ellipsis, style: nameStyle);
    final file = _FileLine(job.file);
    final tile = _Tile(job: job, characterId: actions.characterOf(job));

    Widget iconButton(IconData icon, String tooltip, VoidCallback onPressed) => IconButton(
          style: smallButtonStyle(context, iconOnly: true),
          tooltip: tooltip,
          onPressed: onPressed,
          icon: Icon(icon),
        );

    Widget control(DownloadRowAction action) => switch (action) {
          DownloadRowAction.pause => iconButton(Icons.pause_rounded, loc.t('downloads.pause'), () => queue.pause(job.seq)),
          DownloadRowAction.resume =>
            iconButton(Icons.play_arrow_rounded, loc.t('downloads.resume'), () => queue.resume(job.seq)),
          DownloadRowAction.cancel =>
            iconButton(Icons.close_rounded, loc.t('downloads.cancel'), () => queue.cancel(job.seq)),
          DownloadRowAction.removeFromQueue =>
            iconButton(Icons.close_rounded, loc.t('downloads.remove_from_queue'), () => queue.cancel(job.seq)),
          DownloadRowAction.answer => OutlinedButton(
              style: smallButtonStyle(context),
              onPressed: () => questions.answer(job.seq),
              child: Text(loc.t(_answerKey(job.wait?.question))),
            ),
          DownloadRowAction.dontInstall => TextButton(
              style: smallButtonStyle(context),
              onPressed: () => queue.decline(job.seq),
              child: Text(loc.t('downloads.dont_install')),
            ),
          DownloadRowAction.openModPage => TextButton(
              style: smallButtonStyle(context),
              onPressed: () => questions.openModPage(job.seq),
              child: Text(loc.t('downloads.open_mod_page')),
            ),
          DownloadRowAction.turnOn => FilledButton(
              style: smallButtonStyle(context),
              onPressed: () => actions.turnOn(job.installed.single),
              child: Text(loc.t('downloads.turn_on')),
            ),
          DownloadRowAction.show => OutlinedButton(
              style: smallButtonStyle(context),
              onPressed: () => actions.show(job),
              child: Text(loc.t('downloads.show')),
            ),
          DownloadRowAction.retry => OutlinedButton(
              style: smallButtonStyle(context),
              onPressed: () => queue.retry(job.seq),
              child: Text(loc.t('downloads.retry')),
            ),
          DownloadRowAction.dismiss =>
            iconButton(Icons.close_rounded, loc.t('downloads.dismiss'), () => queue.remove(job.seq)),
        };

    switch (job.state) {
      case DownloadJobState.waiting:
        return _RowFrame(
          attention: true,
          children: [
            tile,
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 8,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 2,
                    children: [
                      name,
                      file,
                      Text(_questionLine(loc, job.wait), style: lineStyle?.copyWith(color: palette.attention.foreground)),
                    ],
                  ),
                  Wrap(spacing: 6, runSpacing: 6, children: [for (final a in rowActions) control(a)]),
                ],
              ),
            ),
          ],
        );

      case DownloadJobState.queued when !job.resumed:
        return Opacity(
          opacity: 0.75,
          child: _RowFrame(
            children: [
              tile,
              Expanded(child: _NameAndLine(name: name, file: file, line: Text(_queuedLine(loc, job), style: lineStyle))),
              for (final a in rowActions) control(a),
            ],
          ),
        );

      case DownloadJobState.done || DownloadJobState.failed:
        final failed = job.state == DownloadJobState.failed;
        return _RowFrame(
          children: [
            tile,
            Expanded(
              child: _NameAndLine(
                name: name,
                file: file,
                line: Text(
                  failed ? _failureLine(loc, job.error) : _finishedLine(loc, job, actions),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: failed ? lineStyle?.copyWith(color: palette.redText) : lineStyle,
                ),
              ),
            ),
            for (final a in rowActions) control(a),
          ],
        );

      default:
        final (bar, dimmed) = _barOf(job);
        final fraction = job.progress?.fraction;
        final trailing = switch (job.state) {
          DownloadJobState.updating => Text(
              loc.t('downloads.updating'),
              style: text.labelSmall?.copyWith(fontWeight: FontWeight.w400, letterSpacing: 0, color: palette.text2),
            ),
          DownloadJobState.running || DownloadJobState.paused when fraction != null => Text(
              '${(fraction * 100).round()}%',
              style: ZenithType.of(context).monoSmall.copyWith(color: palette.text2),
            ),
          _ => null,
        };
        return _RowFrame(
          children: [
            tile,
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 6,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    spacing: 1,
                    children: [
                      Row(
                        spacing: 8,
                        children: [Expanded(child: name), ?trailing],
                      ),
                      file,
                    ],
                  ),
                  _Bar(value: bar, dimmed: dimmed),
                  Text(_progressLine(loc, job), maxLines: 2, overflow: TextOverflow.ellipsis, style: lineStyle),
                ],
              ),
            ),
            if (rowActions.isNotEmpty)
              Column(mainAxisSize: MainAxisSize.min, spacing: 2, children: [for (final a in rowActions) control(a)]),
          ],
        );
    }
  }

  /// The bar's fill, null for a sweep, and whether it is dimmed as nothing of it is moving.
  static (double?, bool) _barOf(DownloadJob job) => switch (job.state) {
        DownloadJobState.running => (job.progress?.fraction ?? 0, false),
        DownloadJobState.paused || DownloadJobState.queued => (job.progress?.fraction ?? 0, true),
        DownloadJobState.downloaded => (1, false),
        _ => (null, false),
      };
}

/// The `.dl` box every row is drawn in: amber when it waits for the user's answer.
class _RowFrame extends StatelessWidget {
  const _RowFrame({required this.children, this.attention = false});

  final List<Widget> children;
  final bool attention;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: attention ? palette.attention.background : palette.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: attention ? palette.attention.border! : palette.outline),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, spacing: 12, children: children),
    );
  }
}

class _NameAndLine extends StatelessWidget {
  const _NameAndLine({required this.name, required this.file, required this.line});

  final Widget name;
  final Widget file;
  final Widget line;

  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, spacing: 2, children: [name, file, line]);
}

/// Which file of the mod page the row is, the design's `.fl`: the file name in mono, and the author's variant text
/// in quotes beside it in grey, so two files of one mod read apart. The name gives way first.
class _FileLine extends StatelessWidget {
  const _FileLine(this.file);

  final GbFile file;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    final variant = fileDisplayDetail(file);
    return LayoutBuilder(
      builder: (context, constraints) => Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        spacing: 8,
        children: [
          Flexible(
            child: Text(
              fileDisplayName(file),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ZenithType.of(context).monoSmall.copyWith(color: palette.text2),
              // The line is the 12px caption's, as on the canvas, with or without variant text beside it.
              strutStyle: StrutStyle.fromTextStyle(Theme.of(context).textTheme.bodySmall!, forceStrutHeight: true),
            ),
          ),
          if (variant != null)
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: constraints.maxWidth * 0.6),
              child: Text(
                context.loc.t('marketplace.file_variant', params: {'variant': variant}),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: palette.text3),
              ),
            ),
        ],
      ),
    );
  }
}

/// The row's 56×42 lead: the mod page's first image on the character's element tile, the misc tile for a category or
/// Unknown, or for a waiting download its question's icon on an amber tile.
class _Tile extends ConsumerWidget {
  const _Tile({required this.job, required this.characterId});

  static const double width = 56;
  static const double height = 42;

  final DownloadJob job;
  final String? characterId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = ZenithPalette.of(context);
    if (job.state == DownloadJobState.waiting) {
      return Container(
        width: width,
        height: height,
        decoration: BoxDecoration(color: palette.attentionTile.background, borderRadius: BorderRadius.circular(7)),
        child: Icon(_questionIcon(job.wait?.question), size: 16, color: palette.attentionTile.foreground),
      );
    }
    final ground = DottedGround(ground: palette.groundFor(elementToneOf(characterId ?? unknownCharacterId)), spacing: 7);
    final image = job.mod?.coverImage;
    Widget child = ground;
    if (image != null) {
      // The user asked for this download, so a mature preview is blurred rather than left out.
      final treatment = switch (contentTreatment(job.mod!.effectiveVisibility, ref.watch(contentFilterProvider))) {
        ContentTreatment.omit => ContentTreatment.blur,
        final other => other,
      };
      child = Stack(
        fit: StackFit.expand,
        children: [
          ground,
          GbThumbnail(image: image, treatment: treatment, width: width, height: height, placeholder: ground),
        ],
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(7),
      child: SizedBox(width: width, height: height, child: child),
    );
  }
}

IconData _questionIcon(InstallQuestion? question) => switch (question) {
      InstallQuestion.patch => Icons.link_rounded,
      InstallQuestion.severalFolders => Icons.folder_outlined,
      InstallQuestion.alreadyInstalled => Icons.copy_rounded,
      InstallQuestion.password || null => Icons.lock_outline_rounded,
    };

String _answerKey(InstallQuestion? question) => switch (question) {
      InstallQuestion.alreadyInstalled => 'downloads.answer_already_installed',
      InstallQuestion.severalFolders => 'downloads.answer_several_folders',
      InstallQuestion.patch => 'downloads.answer_patch',
      InstallQuestion.password || null => 'downloads.answer_password',
    };

/// The bar under a row's name: [value] filled in the accent, or a sweep when null. [dimmed] for one not moving.
class _Bar extends StatelessWidget {
  const _Bar({required this.value, this.dimmed = false});

  final double? value;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    final fill = palette.accent.withValues(alpha: dimmed ? 0.4 : 1);
    return ClipRRect(
      borderRadius: BorderRadius.circular(99),
      child: SizedBox(
        height: 6,
        child: ColoredBox(
          color: palette.track,
          child: value == null
              ? _Sweep(color: palette.accent.withValues(alpha: 0.7))
              : Align(
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: value!.clamp(0.0, 1.0),
                    heightFactor: 1,
                    child: DecoratedBox(
                      decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(99)),
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}

/// A third of the bar running across it, for work that reports no fraction.
class _Sweep extends StatefulWidget {
  const _Sweep({required this.color});

  final Color color;

  @override
  State<_Sweep> createState() => _SweepState();
}

class _SweepState extends State<_Sweep> with SingleTickerProviderStateMixin {
  late final AnimationController _run =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat();

  @override
  void dispose() {
    _run.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          final span = constraints.maxWidth * 0.35;
          return AnimatedBuilder(
            animation: _run,
            builder: (context, _) => Stack(
              children: [
                Positioned(
                  left: -span + (constraints.maxWidth + span) * _run.value,
                  top: 0,
                  bottom: 0,
                  width: span,
                  child: DecoratedBox(
                    decoration: BoxDecoration(color: widget.color, borderRadius: BorderRadius.circular(99)),
                  ),
                ),
              ],
            ),
          );
        },
      );
}

/// The question a waiting row says.
String _questionLine(AppLocalizations loc, InstallWait? wait) => switch (wait) {
      InstallWait(passwordFailed: true) => loc.t('downloads.question.password_wrong'),
      InstallWait(question: InstallQuestion.password) || null => loc.t('downloads.question.password'),
      InstallWait(question: InstallQuestion.alreadyInstalled, :final installedAs) =>
        loc.t('downloads.question.already_installed', params: {'mods': installedAs.join(', ')}),
      InstallWait(question: InstallQuestion.severalFolders, :final folderCount) =>
        loc.plural('downloads.question.several_folders', folderCount, params: {'count': '$folderCount'}),
      InstallWait(question: InstallQuestion.patch) => loc.t('downloads.question.patch'),
    };

/// The size a job will be, once known: the transfer's own total, else the file's listed size.
int? _sizeOf(DownloadJob job) {
  final size = job.progress?.total ?? job.request.expectedSize;
  return size != null && size > 0 ? size : null;
}

/// "133 MB of 214 MB", or what has arrived while the total is unknown.
String? _transferred(AppLocalizations loc, DownloadJob job) {
  final progress = job.progress;
  if (progress == null) return null;
  final total = progress.total;
  if (total == null || total <= 0) return formatBytes(progress.received);
  return loc.t('downloads.transfer', params: {'received': formatBytes(progress.received), 'total': formatBytes(total)});
}

String _queuedLine(AppLocalizations loc, DownloadJob job) => switch (_sizeOf(job)) {
      final size? => loc.t('downloads.starts_after', params: {'size': formatBytes(size)}),
      null => loc.t('downloads.queued'),
    };

/// An In progress row's line. The running line has no time left: the rate is what tells a slow node from a dead
/// one (`docs/downloads.md` §5).
String _progressLine(AppLocalizations loc, DownloadJob job) {
  switch (job.state) {
    case DownloadJobState.running:
      final progress = job.progress;
      if (progress == null || progress.state == DownloadState.connecting) return loc.t('downloads.connecting');
      final rate = progress.bytesPerSecond;
      // An agent only: a category or Unknown says nothing about who a mod is for.
      final agent = characterById(job.characterId ?? '');
      return [
        ?_transferred(loc, job),
        if (rate != null) loc.t('marketplace.download_rate', params: {'rate': formatBytes(rate.round())}),
        if (agent != null) loc.t('downloads.for_character', params: {'character': agent.fullName}),
      ].join(' · ');
    case DownloadJobState.paused:
      return [loc.t('downloads.paused'), ?_transferred(loc, job)].join(' · ');
    case DownloadJobState.queued:
      return [loc.t('downloads.queued'), ?_transferred(loc, job)].join(' · ');
    case DownloadJobState.downloaded:
      return switch (_sizeOf(job)) {
        final size? => loc.t('downloads.installs_after', params: {'size': formatBytes(size)}),
        null => loc.t('downloads.installs_after_unsized'),
      };
    case DownloadJobState.installing:
      return loc.t(job.installStage == InstallStage.installing ? 'downloads.installing' : 'downloads.stage_unpacking');
    case DownloadJobState.updating:
      final date = job.file.dateAdded;
      final params = {if (date != null) 'date': formatResolveDate(date)};
      return switch (job.updateStep) {
        UpdateStep.confirming => loc.t('downloads.update_confirming'),
        UpdateStep.writing =>
          loc.t(date == null ? 'downloads.update_writing_undated' : 'downloads.update_writing', params: params),
        UpdateStep.unpacking || null =>
          loc.t(date == null ? 'downloads.update_unpacking_undated' : 'downloads.update_unpacking', params: params),
      };
    default:
      return '';
  }
}

/// A Finished row's line: what it came to, where the mod was filed, and how long ago.
String _finishedLine(AppLocalizations loc, DownloadJob job, _RowCallbacks actions) {
  final date = job.file.dateAdded;
  final params = {if (date != null) 'date': formatResolveDate(date)};
  String dated(String key, String undated) => loc.t(date == null ? undated : key, params: params);

  final head = switch (job.outcome) {
    JobOutcome.installed when job.installed.length > 1 =>
      loc.plural('downloads.installed_many', job.installed.length, params: {'count': '${job.installed.length}'}),
    JobOutcome.installed => loc.t('downloads.done'),
    JobOutcome.updated => dated('downloads.updated', 'downloads.updated_undated'),
    JobOutcome.reinstalled => dated('downloads.reinstalled', 'downloads.reinstalled_undated'),
    JobOutcome.baseInstalled => loc.t('downloads.base_installed'),
    JobOutcome.saved => loc.t('downloads.saved'),
    JobOutcome.nothingInstalled || null => job.headline ?? loc.t('downloads.done'),
  };
  if (job.outcome == JobOutcome.nothingInstalled) return head;

  // Where the install filed it, Unknown included, since that is where to look for it. A saved archive is in no
  // character.
  final character = job.outcome == JobOutcome.saved ? null : actions.characterOf(job);
  final finishedAt = job.finishedAt;
  return [
    head,
    if (character != null) libraryGroupName(libraryGroupOf(character), loc),
    if (finishedAt != null) relativeAgeLabel(loc, finishedAt, actions.now),
  ].join(' · ');
}

/// What went wrong, as specifically as the failure allows.
///
/// A stall is the one transfer failure with a way out, so it says so instead of sharing the generic wording with a
/// 404. An install failure carries its own message: the bytes arrived fine, so "Download failed" would name the one
/// half that worked.
String _failureLine(AppLocalizations loc, Object? error) => switch (error) {
      InstallFailure(:final message) => message,
      DownloadStalledException() => loc.t('downloads.failed_stalled'),
      DownloadNetworkException() => loc.t('downloads.failed_network'),
      // Named with its numbers, or "not enough space" is a dead end.
      InsufficientSpaceException(:final requiredBytes, :final availableBytes) => loc.t('downloads.failed_space', params: {
          'required': formatBytes(requiredBytes),
          'available': formatBytes(availableBytes),
        }),
      _ => loc.t('downloads.failed'),
    };
