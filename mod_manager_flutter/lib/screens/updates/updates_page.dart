import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/button_working.dart';
import '../../core/palette.dart';
import '../../core/type_scale.dart';
import '../../l10n/app_localizations.dart';
import '../../models/character_info.dart';
import '../../models/gamebanana/gb_file.dart';
import '../../models/mod_download.dart';
import '../../services/bulk_assume_current.dart';
import '../../services/gamebanana/file_selection.dart';
import '../../services/installed_record.dart';
import '../../services/origin_write.dart';
import '../../services/update_check.dart';
import '../../utils/categories.dart';
import '../../utils/notifications.dart';
import '../../utils/state_providers.dart';
import '../all_mods/all_mods_bulk.dart';
import '../components/character_tile.dart';
import '../components/library_actions_host.dart';
import '../components/mod_thumb.dart';
import '../components/resolve/resolve_fragments.dart';
import '../components/zenith_controls.dart';
import '../dialogs/assume_current_dialog.dart';
import 'updates_coverage.dart';

/// The Library's Updates page: how much of the library the app can check, the mods with a newer file, and the ones
/// it can't check yet with the ways to settle them (`docs/library-screen.md` §17).
class UpdatesPage extends ConsumerWidget {
  const UpdatesPage({
    super.key,
    required this.onOpenPage,
    required this.onShowUpdate,
    this.loadError,
    this.originWriter,
  });

  /// A mod's name pressed: the mod's page.
  final void Function(ModInfo mod) onOpenPage;

  /// Update pressed: the update dialog.
  final void Function(ModInfo mod) onShowUpdate;

  /// Shown in place of the page when the library didn't load, with its Retry.
  final Widget? loadError;

  /// Injected only by tests — see [OriginWriter].
  final OriginWriter? originWriter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = ZenithPalette.of(context);
    final scanned = ref.watch(libraryProvider.select((l) => l.hasValue));
    final mods = ref.watch(modsProvider);
    final coverage = coverageFor(
      mods,
      ref.watch(modUpdateChecksProvider),
      reached: ref.watch(libraryCheckProgressProvider),
    );
    final marking = ref.watch(lastMarkingProvider);
    final cantCheck = coverage.count(CoverageKind.whichFile) +
        coverage.count(CoverageKind.baseUnknown) +
        coverage.count(CoverageKind.notTracked);

    return ColoredBox(
      color: palette.ground,
      child: loadError != null
          ? Center(child: Padding(padding: const EdgeInsets.all(28), child: loadError))
          : !scanned
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              child: Align(
                alignment: Alignment.topLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1120),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(32, 24, 32, 40),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      spacing: 28,
                      children: [
                        const _Header(),
                        if (coverage.total > 0) _Coverage(coverage: coverage),
                        _NewerFiles(mods: mods, onOpenPage: onOpenPage, onShowUpdate: onShowUpdate, writer: originWriter),
                        if (cantCheck > 0 || marking != null)
                          _CantCheck(coverage: coverage, count: cantCheck, writer: originWriter),
                      ],
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}

/// The title, when the library was last checked, and the whole-library check.
class _Header extends ConsumerStatefulWidget {
  const _Header();

  @override
  ConsumerState<_Header> createState() => _HeaderState();
}

class _HeaderState extends ConsumerState<_Header> {
  /// Keeps "Last checked 2 minutes ago" true while the page is open.
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
    final checking = ref.watch(libraryCheckRunningProvider);
    final checkPlan = ref.watch(bulkUpdateCheckPlanProvider);
    final checkedAt = ref.watch(libraryCheckedAtProvider);

    return Wrap(
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
            Text(loc.t('navigation.updates'), style: text.headlineLarge?.copyWith(color: palette.text)),
            Text(_lastChecked(loc, checkedAt), style: text.bodyMedium?.copyWith(color: palette.text2)),
          ],
        ),
        // Working while the check it started runs; off while any other check runs.
        WorkingAction(
          onPressed: checking || !checkPlan.hasWork
              ? null
              : (work) => LibraryActionsHost.of(context).checkForUpdates(work: work),
          builder: (context, onPressed) => OutlinedButton.icon(
            onPressed: onPressed,
            icon: const WorkingIcon(Icon(Icons.sync_rounded)),
            label: Text(loc.t('library.all.check_all')),
          ),
        ),
      ],
    );
  }

  String _lastChecked(AppLocalizations loc, DateTime? at) {
    if (at == null) return loc.t('library.updates.not_checked');
    final minutes = DateTime.now().difference(at).inMinutes;
    if (minutes < 1) return loc.t('library.updates.checked_now');
    if (minutes < 60) return loc.plural('library.updates.checked_minutes', minutes, params: {'count': '$minutes'});
    final hours = minutes ~/ 60;
    return loc.plural('library.updates.checked_hours', hours, params: {'count': '$hours'});
  }
}

/// "N of your M mods checked for updates", over the strip and a legend.
class _Coverage extends StatelessWidget {
  const _Coverage({required this.coverage});

  final UpdatesCoverage coverage;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final small = Theme.of(context).textTheme.bodySmall?.copyWith(color: palette.text2);
    final colors = _CoverageColors.of(palette);
    String plural(String key, int count) => loc.plural(key, count, params: {'count': '$count'});

    final total = coverage.total;
    final checked = coverage.checked;
    final line = checked == 0
        ? plural('library.updates.coverage_none', total)
        : checked == total
        ? plural('library.updates.coverage_all', total)
        : loc.plural('library.updates.coverage', total, params: {'checked': '$checked', 'count': '$total'});

    final legend = <(String, CoverageKind?, String?)>[
      for (final (kind, key, tooltip) in [
        (CoverageKind.checked, 'library.updates.legend_checked', null),
        (CoverageKind.datedOnly, 'library.updates.legend_dated', null),
        (CoverageKind.unchecked, 'library.updates.legend_unchecked', null),
        (CoverageKind.whichFile, 'library.updates.legend_which', null),
        (CoverageKind.baseUnknown, 'library.updates.legend_base', loc.t('library.updates.base_tooltip')),
        (CoverageKind.notTracked, 'library.updates.legend_not_tracked', null),
      ])
        if (coverage.count(kind) > 0) (plural(key, coverage.count(kind)), kind, tooltip),
      if (coverage.local > 0) (plural('library.updates.legend_local', coverage.local), null, null),
    ];

    return Container(
      padding: const EdgeInsets.fromLTRB(22, 20, 22, 20),
      decoration: BoxDecoration(
        color: palette.dialog,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: palette.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 12,
        children: [
          Text(line, style: ZenithType.of(context).lead.copyWith(color: palette.text)),
          // The line above and the legend below say what the strip draws.
          ExcludeSemantics(
            child: SizedBox(
              height: 34,
              child: _Strip(cells: [for (final (_, kind) in coverage.cells) kind], colors: colors),
            ),
          ),
          Wrap(
            spacing: 20,
            runSpacing: 6,
            children: [
              for (final (label, kind, tooltip) in legend)
                _LegendItem(label: label, kind: kind, tooltip: tooltip, colors: colors, style: small),
            ],
          ),
        ],
      ),
    );
  }
}

/// The strip's colours, worked out from the palette.
class _CoverageColors {
  const _CoverageColors({
    required this.checked,
    required this.dated,
    required this.empty,
    required this.which,
    required this.gap,
    required this.hatch,
  });

  factory _CoverageColors.of(ZenithPalette palette) => _CoverageColors(
        checked: palette.accent,
        dated: Color.lerp(palette.raised, palette.accent, 0.5)!,
        empty: palette.raised,
        which: palette.coverageWhich,
        gap: palette.dialog,
        hatch: palette.hatch,
      );

  final Color checked;
  final Color dated;

  /// An empty pill, standing in for mods not checked yet.
  final Color empty;
  final Color which;

  /// Between a base-unknown cell's checked cap and its unchecked body: the section's own ground.
  final Color gap;
  final TonePair hatch;

  /// The fill of a one-colour pill, or null for the two drawn in parts. Null [kind] is an empty pill.
  Color? solid(CoverageKind? kind) => switch (kind) {
        CoverageKind.checked => checked,
        CoverageKind.datedOnly => dated,
        CoverageKind.unchecked || null => empty,
        CoverageKind.whichFile => which,
        CoverageKind.baseUnknown || CoverageKind.notTracked => null,
      };
}

/// The strip: a pill for every mod checked this session and every mod that can't be checked, with empty pills
/// between the two to make up [_minPills]. A mod gets its pill when the check reaches it, so the empty pills turn
/// into checked ones and, once they run out, the strip grows a pill per mod.
///
/// A pill that changes colour fades from the colour on screen to its new one, each a moment after the one before and
/// a batch after the one before it (never queued far ahead), so the strip fills from the left; the pills narrow
/// smoothly as it grows. A base-unknown or hatched pill changes at once.
class _Strip extends StatefulWidget {
  const _Strip({required this.cells, required this.colors});

  /// Every mod's cell. The ones not checked yet have no pill of their own.
  final List<CoverageKind> cells;
  final _CoverageColors colors;

  @override
  State<_Strip> createState() => _StripState();
}

class _StripState extends State<_Strip> with SingleTickerProviderStateMixin {
  static const int _minPills = 60;
  static const Duration _fade = Duration(milliseconds: 350);
  static const Duration _stagger = Duration(milliseconds: 18);

  /// The longest a whole batch takes to start fading, however many pills it adds.
  static const Duration _staggerCap = Duration(milliseconds: 1200);

  /// The furthest ahead of now a batch may be queued to start.
  static const Duration _queueCap = Duration(milliseconds: 300);

  /// Made on the first change.
  Ticker? _ticker;
  Duration _now = Duration.zero;

  /// What each pill shows, null for an empty one.
  late List<CoverageKind?> _pills = _pillsFor(widget.cells);

  /// Per pill fading to its colour, by place: the colour it fades from, and when its fade starts.
  final Map<int, (Color, Duration)> _fades = {};

  /// How many pills the layout is sized for, from and to, while the strip grows or shrinks, and when that started.
  (double, double, Duration)? _resize;

  static List<CoverageKind?> _pillsFor(List<CoverageKind> cells) => coveragePills(cells, minimum: _minPills);

  /// How far a fade that starts at [start] has gone, eased.
  double _progress(Duration start) =>
      Curves.easeOut.transform(((_now - start).inMicroseconds / _fade.inMicroseconds).clamp(0.0, 1.0));

  /// The colour place [i] shows right now, mid-fade or not.
  Color? _onScreen(int i) {
    final to = widget.colors.solid(i < _pills.length ? _pills[i] : null);
    final fade = _fades[i];
    if (fade == null || to == null) return to;
    return Color.lerp(fade.$1, to, _progress(fade.$2));
  }

  @override
  void didUpdateWidget(_Strip old) {
    super.didUpdateWidget(old);
    final next = _pillsFor(widget.cells);
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      _fades.clear();
      _resize = null;
      _pills = next;
      return;
    }
    // Only one-colour pills fade, from one-colour pills: a base-unknown or hatched pill, or one replacing it, changes at
    // once. A pill fades from the colour its old place shows now, mid-fade included, and a place the strip didn't
    // have fades from empty.
    final changed = <(int, Color)>[
      for (final (i, was, from) in pillChanges(_pills, next))
        if (widget.colors.solid(next[i]) != null && widget.colors.solid(was) != null)
          (i, (from == null ? null : _onScreen(from)) ?? widget.colors.solid(was)!),
    ];
    final grows = next.length != _pills.length;
    if (changed.isNotEmpty || grows) {
      final ticker = _ticker ??= createTicker(_tick);
      if (!ticker.isActive) {
        _now = Duration.zero;
        _fades.clear();
      }
      // A fade still running moves with its pill, whose place shifts among the questions as the strip grows or shrinks.
      final places = pillPlacesBefore(_pills, next);
      final moved = {
        for (final (i, from) in places.indexed)
          if (from != null)
            if (_fades[from] case final fade?) i: fade,
      };
      _fades
        ..clear()
        ..addAll(moved);
      // A batch starts after the last fade still waiting, so a second batch doesn't overtake the first; but never
      // more than [_queueCap] ahead, so batches arriving faster than they fade don't leave the strip lagging.
      var first = _now;
      for (final (_, start) in _fades.values) {
        if (start > first) first = start;
      }
      if (first > _now + _queueCap) first = _now + _queueCap;
      final step = _stagger * changed.length > _staggerCap ? _staggerCap ~/ changed.length : _stagger;
      for (final (order, (i, from)) in changed.indexed) {
        _fades[i] = (from, first + step * order);
      }
      if (grows) _resize = (_layoutCount, next.length.toDouble(), _now);
      if (!ticker.isActive) unawaited(ticker.start());
    }
    _pills = next;
  }

  /// How many pills wide the layout is right now.
  double get _layoutCount {
    final resize = _resize;
    if (resize == null) return _pills.length.toDouble();
    final t = ((_now - resize.$3).inMicroseconds / _fade.inMicroseconds).clamp(0.0, 1.0);
    return resize.$1 + (resize.$2 - resize.$1) * Curves.easeOut.transform(t);
  }

  void _tick(Duration elapsed) {
    setState(() {
      _now = elapsed;
      _fades.removeWhere((_, fade) => _now >= fade.$2 + _fade);
      if (_resize case final resize? when _now >= resize.$3 + _fade) _resize = null;
    });
    if (_fades.isEmpty && _resize == null) _ticker?.stop();
  }

  @override
  void dispose() {
    _ticker?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Its own layer, so a frame of the fade repaints the strip and not the page.
    return RepaintBoundary(
      child: CustomPaint(
        painter: _StripPainter(
          kinds: _pills,
          colors: widget.colors,
          count: _layoutCount,
          from: {
            for (final MapEntry(key: i, value: (from, start)) in _fades.entries) i: (from, _progress(start)),
          },
        ),
      ),
    );
  }
}

/// One cell per pill, in [CoverageKind] order. Narrow cells lose their gaps, and a library too large for cells at all
/// reads as a bar of segments.
class _StripPainter extends CustomPainter {
  _StripPainter({required this.kinds, required this.colors, double? count, this.from = const {}})
    : count = count ?? kinds.length.toDouble();

  /// Null is an empty pill.
  final List<CoverageKind?> kinds;
  final _CoverageColors colors;

  /// How many pills wide the layout is, which runs between two lengths while the strip grows.
  final double count;

  /// The pills fading in, by index: the colour each fades from, and how far it has gone.
  final Map<int, (Color, double)> from;

  @override
  void paint(Canvas canvas, Size size) {
    final n = kinds.length;
    if (n == 0) return;
    double cellWidth(double gap) => (size.width - gap * (count - 1)) / count;
    var gap = 3.0;
    if (cellWidth(gap) < 4) gap = 1;
    if (cellWidth(gap) < 2) gap = 0;
    final width = cellWidth(gap);
    final radius = Radius.circular(gap == 0 ? 0 : math.min(3, width / 2));

    canvas.save();
    canvas.clipRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(3)));
    for (var i = 0; i < n; i++) {
      final rect = Rect.fromLTWH(i * (width + gap), 0, width, size.height);
      final cell = RRect.fromRectAndRadius(rect, radius);
      final kind = kinds[i];
      if (colors.solid(kind) case final fill?) {
        final fading = from[i];
        canvas.drawRRect(cell, Paint()..color = fading == null ? fill : Color.lerp(fading.$1, fill, fading.$2)!);
        continue;
      }
      switch (kind) {
        case CoverageKind.checked || CoverageKind.datedOnly || CoverageKind.unchecked || CoverageKind.whichFile || null:
          break;
        case CoverageKind.baseUnknown:
          // A thin checked cap for the patch, a gap, and the unnamed base under it.
          canvas.save();
          canvas.clipRRect(cell);
          final h = size.height;
          canvas.drawRect(Rect.fromLTWH(rect.left, 0, width, h * 0.18), Paint()..color = colors.checked);
          canvas.drawRect(Rect.fromLTWH(rect.left, h * 0.18, width, h * 0.08), Paint()..color = colors.gap);
          canvas.drawRect(Rect.fromLTWH(rect.left, h * 0.26, width, h * 0.74), Paint()..color = colors.which);
          canvas.restore();
        case CoverageKind.notTracked:
          canvas.save();
          canvas.clipRRect(cell);
          _hatch(canvas, rect, size.height);
          canvas.restore();
      }
    }
    canvas.restore();
  }

  /// 4px stripes 8px apart at 45°, laid from the strip's left edge so neighbouring cells line up.
  void _hatch(Canvas canvas, Rect rect, double height) {
    canvas.drawRect(rect, Paint()..color = colors.hatch.background);
    final stripe = Paint()
      ..color = colors.hatch.foreground
      ..strokeWidth = 4;
    const step = 8 * math.sqrt2;
    final first = ((rect.left - height) / step).floor() * step;
    for (var x = first; x < rect.right; x += step) {
      canvas.drawLine(Offset(x, height), Offset(x + height, 0), stripe);
    }
  }

  @override
  bool shouldRepaint(_StripPainter old) => true;
}

class _LegendItem extends StatelessWidget {
  const _LegendItem({
    required this.label,
    required this.kind,
    required this.tooltip,
    required this.colors,
    required this.style,
  });

  final String label;

  /// Null for the Local mods, which have no cell and so no swatch.
  final CoverageKind? kind;
  final String? tooltip;
  final _CoverageColors colors;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final kind = this.kind;
    final item = Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 6,
      children: [
        if (kind != null)
          SizedBox(
            width: 9,
            height: kind == CoverageKind.baseUnknown ? 12 : 9,
            child: CustomPaint(painter: _StripPainter(kinds: [kind], colors: colors)),
          ),
        Text(label, style: style),
      ],
    );
    return tooltip == null ? item : Tooltip(message: tooltip, child: item);
  }
}

/// Every mod with an update to show: the file the user has, and the newer one.
class _NewerFiles extends ConsumerWidget {
  const _NewerFiles({required this.mods, required this.onOpenPage, required this.onShowUpdate, required this.writer});

  final List<ModInfo> mods;
  final void Function(ModInfo mod) onOpenPage;
  final void Function(ModInfo mod) onShowUpdate;
  final OriginWriter? writer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final checks = ref.watch(modUpdateChecksProvider);
    final checkedAt = ref.watch(libraryCheckedAtProvider);
    final found = newerFilesOf(mods, checks);
    final frame = BoxDecoration(
      color: palette.dialog,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: palette.outline),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 12,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          spacing: 10,
          children: [
            Text(loc.t('library.updates.newer_files'), style: text.titleMedium?.copyWith(color: palette.text)),
            if (found.isNotEmpty)
              Text('${found.length}', style: ZenithType.of(context).mono.copyWith(color: palette.badgeUpdate.foreground)),
          ],
        ),
        if (found.isEmpty)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
            decoration: frame,
            child: Text(
              loc.t(checks.isEmpty && checkedAt == null ? 'library.updates.none_yet' : 'library.updates.none_found'),
              style: text.bodyMedium?.copyWith(color: palette.text2),
            ),
          )
        else
          DecoratedBox(
            decoration: frame,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(13),
              child: Column(
                children: [
                  for (final (i, (mod, check)) in found.indexed)
                    _NewerFileRow(
                      mod: mod,
                      check: check,
                      last: i == found.length - 1,
                      onOpenPage: onOpenPage,
                      onShowUpdate: onShowUpdate,
                      writer: writer,
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _NewerFileRow extends ConsumerWidget {
  const _NewerFileRow({
    required this.mod,
    required this.check,
    required this.last,
    required this.onOpenPage,
    required this.onShowUpdate,
    required this.writer,
  });

  final ModInfo mod;
  final UpdateCheck check;
  final bool last;
  final void Function(ModInfo mod) onOpenPage;
  final void Function(ModInfo mod) onShowUpdate;
  final OriginWriter? writer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final writing = ref.watch(modWritesInProgressProvider).contains(mod.id);
    final ignorable = check.subjectModId != null && check.dismissableUpTo != null;
    final author = installedRecord(mod, ref.watch(knownModPagesProvider)).page?.submitter?.name;
    final character = libraryGroupName(libraryGroupOf(mod.characterId), loc);

    final name = Row(
      spacing: 12,
      children: [
        ModThumb(mod: mod, width: 56, height: 36),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ZenithLink(
                mod.name,
                onTap: () => onOpenPage(mod),
                style: text.bodyMedium?.copyWith(color: palette.text, fontWeight: FontWeight.w600),
              ),
              Text(
                [character, ?author].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.bodySmall?.copyWith(color: palette.text3),
              ),
            ],
          ),
        ),
      ],
    );
    final files = Row(
      spacing: 16,
      children: [
        Expanded(child: _youHave(context)),
        Icon(Icons.arrow_forward_rounded, size: 20, color: palette.amber),
        Expanded(child: _newer(context)),
      ],
    );
    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 6,
      children: [
        TextButton(
          style: smallButtonStyle(context),
          onPressed: writing || !ignorable ? null : () => unawaited(_ignore(context)),
          child: Text(loc.t('library.updates.ignore')),
        ),
        OutlinedButton(
          style: smallButtonStyle(context),
          onPressed: writing ? null : () => onShowUpdate(mod),
          child: Text(loc.t('library.updates.update')),
        ),
      ],
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        border: last ? null : Border(bottom: BorderSide(color: palette.rowDivider)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) => constraints.maxWidth >= 760
            ? Row(
                spacing: 16,
                children: [
                  Expanded(flex: 13, child: name),
                  Expanded(flex: 21, child: files),
                  actions,
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 10,
                children: [
                  Row(spacing: 16, children: [Expanded(child: name), actions]),
                  files,
                ],
              ),
      ),
    );
  }

  /// Whether the check compared by a date rather than by a file: a mod marked as current, or the layer that won the
  /// fold in a folder whose base is.
  bool get _byDate =>
      check.installedFile == null && check.evidence == InstalledFileEvidence.none && check.comparedAgainst != null;

  Widget _youHave(BuildContext context) {
    final loc = context.loc;
    final installed = check.installedFile;
    final compared = check.comparedAgainst;
    return _FileColumn(
      label: loc.t('library.updates.you_have'),
      file: installed == null ? null : fileDisplayName(installed),
      plain: installed != null ? null : loc.t(_byDate ? 'library.updates.marked_current' : 'library.updates.file_gone'),
      detail: installed?.dateAdded != null
          ? loc.t('library.updates.uploaded', params: {'date': formatResolveDate(installed!.dateAdded!)})
          : _byDate
          ? loc.t('library.updates.newest_on', params: {'date': formatResolveDate(compared!)})
          : null,
    );
  }

  Widget _newer(BuildContext context) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final GbFile? file = check.candidate ?? (check.newerFiles.length == 1 ? check.newerFiles.single : null);
    final label = file?.description?.trim();
    final heading = loc.t(
      check.outcome == UpdateOutcome.updateAvailable ? 'library.updates.newer' : 'library.updates.maybe_newer',
    );
    // No file to name: checked by date, the page changed after it; or the installed file was taken down and every
    // file left shipped with it. The date is only quoted when it is the one the check compared by.
    if (file == null && check.newerFiles.isEmpty) {
      return _FileColumn(
        label: heading,
        labelColor: palette.badgeUpdate.foreground,
        file: null,
        plain: loc.t('library.updates.page_changed'),
        detail: _byDate
            ? loc.t('library.updates.after', params: {'date': formatResolveDate(check.comparedAgainst!)})
            : null,
      );
    }
    DateTime? newest;
    for (final candidate in check.newerFiles) {
      final date = candidate.dateAdded;
      if (date != null && (newest == null || date.isAfter(newest))) newest = date;
    }
    return _FileColumn(
      label: heading,
      labelColor: palette.badgeUpdate.foreground,
      file: file == null ? null : fileDisplayName(file),
      fileColor: palette.text,
      plain: file != null
          ? null
          : loc.plural('library.updates.newer_count', check.newerFiles.length,
              params: {'count': '${check.newerFiles.length}'}),
      detail: [
        if ((file?.dateAdded ?? newest) case final date?)
          loc.t('library.updates.uploaded', params: {'date': formatResolveDate(date)}),
        if (label != null && label.isNotEmpty) loc.t('library.updates.variant', params: {'label': label}),
      ].join(' · '),
    );
  }

  /// Ignores this update, as the update dialog's Ignore does. The row leaves the list, so only a failure is said.
  Future<void> _ignore(BuildContext context) async {
    final loc = context.loc;
    final notify = context.notify;
    final container = ProviderScope.containerOf(context, listen: false);
    final ok = await ignoreUpdate(container, mod: mod, check: check, writer: writer);
    if (ok) return;
    notify.error(
      loc.t('mods.update.dismiss_failed_title'),
      body: loc.t('mods.update.dismiss_failed', params: {'mod': mod.name}),
      characterId: mod.characterId,
    );
  }
}

/// A caps label over a file name in mono, or over [plain] text when there is no file to name, and a detail line.
class _FileColumn extends StatelessWidget {
  const _FileColumn({
    required this.label,
    this.labelColor,
    required this.file,
    this.fileColor,
    required this.plain,
    required this.detail,
  });

  final String label;
  final Color? labelColor;
  final String? file;
  final Color? fileColor;
  final String? plain;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final type = ZenithType.of(context);
    final file = this.file;
    final detail = this.detail;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label.toUpperCase(), style: type.caps.copyWith(color: labelColor ?? palette.text3)),
        if (file != null)
          Tooltip(
            message: file,
            child: Text(
              file,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: type.mono.copyWith(color: fileColor ?? palette.text2),
            ),
          )
        else
          Text(plain ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: text.bodySmall?.copyWith(color: palette.text2)),
        if (detail != null && detail.isNotEmpty)
          Text(detail, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.bodySmall?.copyWith(color: palette.text3)),
      ],
    );
  }
}

/// The mods the app can't check yet, and the ways to settle them. Folds away for the session.
class _CantCheck extends ConsumerWidget {
  const _CantCheck({required this.coverage, required this.count, required this.writer});

  final UpdatesCoverage coverage;
  final int count;
  final OriginWriter? writer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final hidden = ref.watch(updatesCantCheckHiddenProvider);
    final marking = ref.watch(lastMarkingProvider);
    final which = coverage.of(CoverageKind.whichFile);
    final untracked = coverage.of(CoverageKind.notTracked);
    final baseUnknown = coverage.of(CoverageKind.baseUnknown);

    final left = [
      if (marking != null) _MarkedCard(marking: marking, writer: writer),
      if (which.isNotEmpty) _WhichFileCard(mods: which, writer: writer),
    ];
    final right = untracked.isEmpty && baseUnknown.isEmpty
        ? null
        : _OriginCard(untracked: untracked, baseUnknown: baseUnknown);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 14,
      children: [
        Row(
          spacing: 10,
          children: [
            Text(loc.t('library.all.cant_check'), style: text.titleMedium?.copyWith(color: palette.text)),
            if (count > 0)
              Text('$count', style: ZenithType.of(context).mono.copyWith(color: palette.badgeInfo.foreground)),
            if (hidden) Text('· ${loc.t('library.updates.hidden')}', style: text.bodySmall?.copyWith(color: palette.text3)),
            const Spacer(),
            TextButton.icon(
              style: smallButtonStyle(context),
              onPressed: () => ref.read(updatesCantCheckHiddenProvider.notifier).state = !hidden,
              iconAlignment: IconAlignment.end,
              icon: AnimatedRotation(
                turns: hidden ? -0.25 : 0,
                duration: const Duration(milliseconds: 150),
                child: const Icon(Icons.expand_more_rounded),
              ),
              label: Text(loc.t(hidden ? 'library.updates.show' : 'library.updates.hide')),
            ),
          ],
        ),
        if (!hidden) ...[
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Text(loc.t('library.updates.cant_intro'), style: text.bodyMedium?.copyWith(color: palette.text2)),
          ),
          LayoutBuilder(
            builder: (context, constraints) {
              final leftColumn = left.isEmpty
                  ? null
                  : Column(crossAxisAlignment: CrossAxisAlignment.stretch, spacing: 14, children: left);
              if (leftColumn != null && right != null && constraints.maxWidth >= 760) {
                return IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    spacing: 14,
                    children: [
                      Expanded(flex: 3, child: leftColumn),
                      Expanded(flex: 2, child: right),
                    ],
                  ),
                );
              }
              return ConstrainedBox(
                constraints: BoxConstraints(maxWidth: leftColumn != null && right != null ? double.infinity : 640),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 14,
                  children: [?leftColumn, ?right],
                ),
              );
            },
          ),
        ],
      ],
    );
  }
}

/// A card of the Can't be checked section: an icon beside a title and a line, then [children].
class _Card extends StatelessWidget {
  const _Card({
    required this.tone,
    required this.icon,
    required this.title,
    this.badge,
    this.body,
    required this.children,
    this.decoration,
  });

  final TonePair tone;
  final IconData icon;
  final String title;
  final Widget? badge;
  final String? body;
  final List<Widget> children;
  final BoxDecoration? decoration;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final body = this.body;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: decoration ??
          BoxDecoration(
            color: palette.card,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: palette.outline),
          ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 14,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 12,
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: tone.background,
                  borderRadius: BorderRadius.circular(9),
                  border: tone.border == null ? null : Border.all(color: tone.border!),
                ),
                child: Icon(icon, size: 16, color: tone.foreground),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 4,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(title, style: text.titleSmall?.copyWith(color: palette.text)),
                        ?badge,
                      ],
                    ),
                    if (body != null) Text(body, style: text.bodyMedium?.copyWith(color: palette.textProse)),
                  ],
                ),
              ),
            ],
          ),
          ...children,
        ],
      ),
    );
  }
}

/// "Lab Coat, Office Attire, Track Suit and 27 more".
String _namesLine(AppLocalizations loc, List<ModInfo> mods) {
  final names = mods.take(3).map((m) => m.name).join(', ');
  final more = mods.length - 3;
  return more <= 0 ? names : loc.plural('library.updates.names_more', more, params: {'names': names, 'count': '$more'});
}

/// The names line with its "See them" link, which opens All mods on Can't be checked.
class _NamesWithLink extends ConsumerWidget {
  const _NamesWithLink({required this.mods});

  final List<ModInfo> mods;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final style = Theme.of(context).textTheme.bodySmall;
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text('${_namesLine(loc, mods)} · ', style: style?.copyWith(color: palette.text2)),
        ZenithLink(
          loc.t('library.updates.see_them'),
          onTap: () => openAllModsFiltered(ref, AllModsFilter.needsAttention),
          style: style?.copyWith(color: palette.link),
        ),
      ],
    );
  }
}

/// The mods whose page is known and whose file isn't: mark them all as current, or pick each file.
class _WhichFileCard extends ConsumerWidget {
  const _WhichFileCard({required this.mods, required this.writer});

  final List<ModInfo> mods;
  final OriginWriter? writer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final checking = ref.watch(libraryCheckRunningProvider);
    final plan = planBulkAssumeCurrent(mods);
    final characters = <String>{for (final mod in mods) libraryGroupOf(mod.characterId)}.take(5).toList();

    return _Card(
      tone: palette.badgeInfo,
      icon: Icons.contact_support_outlined,
      title: loc.plural('library.all.mods', mods.length, params: {'count': '${mods.length}'}),
      badge: ZenithBadge(label: loc.t('library.card.file_unknown'), tone: palette.badgeInfo),
      body: loc.t('library.updates.which_line'),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: palette.badgeInfo.border ?? palette.outline),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [palette.infoWash, palette.card],
          stops: const [0, 0.7],
        ),
      ),
      children: [
        Row(
          spacing: 10,
          children: [
            _PortraitStack(groupIds: characters),
            Expanded(child: _NamesWithLink(mods: mods)),
          ],
        ),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: palette.ground,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: palette.divider),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 4,
            children: [
              Text(
                loc.t('library.updates.mark_all_title'),
                style: text.bodyMedium?.copyWith(color: palette.text, fontWeight: FontWeight.w600),
              ),
              Text(loc.t('library.updates.mark_all_line'), style: text.bodySmall?.copyWith(color: palette.text2)),
            ],
          ),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: plan.hasWork ? () => unawaited(_markAll(context, plan)) : null,
              icon: const Icon(Icons.event_available_outlined),
              label: Text(loc.t('library.updates.mark_all')),
            ),
            TextButton(
              onPressed: checking ? null : () => unawaited(LibraryActionsHost.of(context).sortOutTracking()),
              child: Text(loc.t('library.updates.one_by_one')),
            ),
          ],
        ),
      ],
    );
  }

  /// Marks the mods asking "Which file?" as current, after the confirmation that lists each one, and keeps what each
  /// base was for Undo. Reads the app's container, so leaving the page mid-run still records, reports and rescans.
  Future<void> _markAll(BuildContext context, BulkAssumeCurrentPlan plan) async {
    final loc = context.loc;
    final notify = context.notify;
    final container = ProviderScope.containerOf(context, listen: false);
    final write = writer ?? originWriterFor(container.read(modManagerServiceProvider.future));
    final writing = <ModInfo>[];
    final marked = <MarkedAsCurrent>[];
    final outcome = await confirmAndApplyAssumeCurrent(
      context,
      plan,
      // The dialog's transform is `bulkAssumeCurrent`; the recorded one writes the same and says what it replaced.
      writer: (modId, _) async {
        final mod = plan.eligible.firstWhere((m) => m.id == modId);
        if (isBeingWritten(container, mod)) {
          writing.add(mod);
          return OriginWriteResult.declined;
        }
        ModDownload? before;
        DateTime? baseline;
        final result = await whileWritingMod(
          container,
          modId,
          () => write(
            modId,
            (current) => bulkAssumeCurrentRecorded(current, (base, date) {
              before = base;
              baseline = date;
            }),
          ),
        );
        if (result.ok && before != null) marked.add(MarkedAsCurrent(modId: modId, before: before!, baseline: baseline));
        return result;
      },
    );
    if (outcome == null) return;
    final shown = BulkAssumeCurrentOutcome(
      written: outcome.written,
      skipped: outcome.skipped - writing.length,
      failed: outcome.failed,
    );
    reportSkippedWhileWriting(loc, notify, writing);
    // What was written shows as the marked card, so only a failure or a run that wrote nothing is said.
    if (shown.failed > 0 || (shown.written == 0 && shown.skipped > 0)) {
      showAssumeCurrentOutcome(loc, notify, shown, into: outcome.card);
    } else {
      outcome.card?.dismiss();
    }
    await container.read(libraryProvider.notifier).rescan();
    // After the rescan, so Check them now on the card checks the mods as marked.
    if (marked.isNotEmpty) container.read(lastMarkingProvider.notifier).state = marked;
  }
}

/// After "Mark all as current": how many were marked, a check of just those, and Undo.
class _MarkedCard extends ConsumerStatefulWidget {
  const _MarkedCard({required this.marking, required this.writer});

  final List<MarkedAsCurrent> marking;
  final OriginWriter? writer;

  @override
  ConsumerState<_MarkedCard> createState() => _MarkedCardState();
}

class _MarkedCardState extends ConsumerState<_MarkedCard> {
  bool _undoing = false;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final checking = ref.watch(libraryCheckRunningProvider);
    final count = widget.marking.length;
    final ids = {for (final m in widget.marking) m.modId};
    final mods = [for (final mod in ref.watch(modsProvider)) if (ids.contains(mod.id)) mod];

    final card = _Card(
      tone: TonePair(Color.lerp(palette.card, palette.accent, 0.16)!, palette.accent,
          Color.lerp(palette.card, palette.accent, 0.4)),
      icon: Icons.check_rounded,
      title: loc.plural('library.updates.marked_title', count, params: {'count': '$count'}),
      badge: ZenithBadge(label: loc.t('library.card.dated'), tone: palette.badgeNeutral),
      body: loc.t('library.updates.marked_line'),
      decoration: BoxDecoration(
        color: Color.lerp(palette.card, palette.accent, 0.06),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Color.lerp(palette.outline, palette.accent, 0.4)!),
      ),
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            WorkingAction(
              onPressed: checking || _undoing || mods.isEmpty
                  ? null
                  : (work) => LibraryActionsHost.of(context).checkMods(mods, work: work),
              builder: (context, onPressed) => FilledButton.icon(
                onPressed: onPressed,
                icon: const WorkingIcon(Icon(Icons.sync_rounded)),
                label: Text(loc.t('library.updates.check_them')),
              ),
            ),
            TextButton(
              onPressed: _undoing ? null : () => unawaited(_undo()),
              child: Text(loc.t('library.updates.undo')),
            ),
          ],
        ),
      ],
    );
    return Semantics(liveRegion: true, container: true, child: card);
  }

  /// Puts back each marked mod's tracking from before the marking. A mod answered another way since is left as it
  /// is. The session's verdict by date on the ones put back is dropped, since they no longer have the date; one about
  /// a patch in the same folder stays.
  ///
  /// A mod whose folder is being written is skipped and named, as the bulk actions do. It and any whose write fails
  /// stay in the marking, so Undo can be pressed again for them. One whose folder is gone is named and let go.
  Future<void> _undo() async {
    final loc = context.loc;
    final notify = context.notify;
    final container = ProviderScope.containerOf(context, listen: false);
    final write = widget.writer ?? originWriterFor(container.read(modManagerServiceProvider.future));
    final mods = {for (final mod in container.read(modsProvider)) mod.id: mod};
    setState(() => _undoing = true);
    final undone = <MarkedAsCurrent>[];
    final kept = <MarkedAsCurrent>[];
    final failed = <String>[];
    final missing = <String>[];
    final skipped = <ModInfo>[];
    for (final marked in widget.marking) {
      final mod = mods[marked.modId];
      if (mod != null && isBeingWritten(container, mod)) {
        skipped.add(mod);
        kept.add(marked);
        continue;
      }
      final result = await whileWritingMod(
        container,
        marked.modId,
        () => write(marked.modId, (origin) => undoAssumeCurrent(origin, marked)),
      );
      switch (result) {
        case OriginWriteResult.written:
          undone.add(marked);
        case OriginWriteResult.writeFailed:
          failed.add(mod?.name ?? marked.modId);
          kept.add(marked);
        // Named but not kept: a folder renamed or removed since the marking can't be found under this name again.
        case OriginWriteResult.folderMissing:
          missing.add(mod?.name ?? marked.modId);
        case OriginWriteResult.declined:
          break;
      }
    }
    if (failed.isNotEmpty || missing.isNotEmpty) {
      final count = failed.length + missing.length;
      // A warning when some were put back, an error when none were.
      notify.show(
        undone.isEmpty ? NotificationKind.error : NotificationKind.warning,
        loc.plural('library.updates.undo_failed_title', count, params: {'count': '$count'}),
        body: [
          if (failed.isNotEmpty) loc.t('library.updates.undo_failed_write', params: {'names': failed.join(', ')}),
          if (missing.isNotEmpty) loc.t('library.updates.undo_failed_gone', params: {'names': missing.join(', ')}),
        ].join(' '),
      );
    }
    reportSkippedWhileWriting(loc, notify, skipped);
    await container.read(libraryProvider.notifier).rescan();
    // After the rescan, so the strip and the cards never show a mod as both put back and still marked.
    final checks = container.read(modUpdateChecksProvider.notifier);
    final next = {...checks.state};
    for (final marked in undone) {
      final check = next[marked.modId];
      if (check == null) continue;
      if (forgetBaseVerdict(check) case final folder?) {
        next[marked.modId] = folder;
      } else {
        next.remove(marked.modId);
      }
    }
    checks.state = next;
    container.read(lastMarkingProvider.notifier).state = kept.isEmpty ? null : kept;
    if (mounted) setState(() => _undoing = false);
  }
}

/// The mods with no page on record, and the patches over a base nobody named. Both are settled in the tracking
/// screen.
class _OriginCard extends ConsumerWidget {
  const _OriginCard({required this.untracked, required this.baseUnknown});

  final List<ModInfo> untracked;
  final List<ModInfo> baseUnknown;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final checking = ref.watch(libraryCheckRunningProvider);
    final strong = text.bodyMedium?.copyWith(color: palette.text, fontWeight: FontWeight.w600);

    Widget entry({required String title, required Widget badge, required Widget line, required bool divided}) =>
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            border: divided ? Border(bottom: BorderSide(color: palette.divider)) : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 2,
            children: [
              Row(spacing: 8, children: [Text(title, style: strong), badge]),
              line,
            ],
          ),
        );

    return _Card(
      tone: palette.badgeNeutral,
      icon: Icons.link_off_rounded,
      title: loc.t('library.updates.origin_title'),
      children: [
        Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: palette.divider),
          ),
          child: Column(
            children: [
              if (untracked.isNotEmpty)
                entry(
                  title: loc.plural('library.all.mods', untracked.length, params: {'count': '${untracked.length}'}),
                  badge: ZenithBadge(label: loc.t('library.card.not_tracked'), tone: palette.badgeNeutral),
                  line: _NamesWithLink(mods: untracked),
                  divided: baseUnknown.isNotEmpty,
                ),
              if (baseUnknown.isNotEmpty)
                entry(
                  title: loc.plural('library.updates.patches', baseUnknown.length,
                      params: {'count': '${baseUnknown.length}'}),
                  badge: ZenithBadge(label: loc.t('library.card.base_unknown'), tone: palette.badgeInfo),
                  line: Text(
                    loc.plural('library.updates.base_line', baseUnknown.length,
                        params: {'count': '${baseUnknown.length}'}),
                    style: text.bodySmall?.copyWith(color: palette.text2),
                  ),
                  divided: false,
                ),
            ],
          ),
        ),
        Text(loc.t('library.updates.origin_footer'), style: text.bodySmall?.copyWith(color: palette.text2)),
        OutlinedButton(
          onPressed: checking ? null : () => unawaited(LibraryActionsHost.of(context).sortOutTracking()),
          child: Text(loc.t('library.updates.sort_out')),
        ),
      ],
    );
  }
}

/// Up to five portraits, each overlapping the one before.
class _PortraitStack extends StatelessWidget {
  const _PortraitStack({required this.groupIds});

  final List<String> groupIds;

  static const double _size = 28;
  static const double _step = 20;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    if (groupIds.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      width: _size + _step * (groupIds.length - 1),
      height: _size,
      child: Stack(
        children: [
          for (final (i, id) in groupIds.indexed)
            Positioned(
              left: i * _step,
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: palette.card, width: 2),
                ),
                child: CharacterTile(groupId: id, size: _size - 4, radius: 6),
              ),
            ),
        ],
      ),
    );
  }
}
