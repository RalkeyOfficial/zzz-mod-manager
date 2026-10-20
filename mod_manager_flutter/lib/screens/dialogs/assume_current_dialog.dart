import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/palette.dart';
import '../../core/type_scale.dart';
import '../../l10n/app_localizations.dart';
import '../../models/character_info.dart';
import '../../services/bulk_assume_current.dart';
import '../../services/installed_record.dart';
import '../../services/log/logger.dart';
import '../../services/origin_write.dart';
import '../../utils/categories.dart';
import '../../utils/notifications.dart';
import '../../utils/state_providers.dart';
import '../components/character_tile.dart';
import '../components/mod_thumb.dart';
import '../components/resolve/resolve_fragments.dart';
import '../components/zenith_controls.dart';

final Logger _log = Logger('origin');

/// How a bulk run ended.
///
/// A decline is the re-read guard working: the mod was already resolved by the time its turn came.
/// It is counted apart from a failure, which is a state worth reporting since nothing re-attempts an origin write.
class BulkAssumeCurrentOutcome {
  const BulkAssumeCurrentOutcome({
    required this.written,
    required this.skipped,
    required this.failed,
  });

  /// Sidecars actually rewritten.
  final int written;

  /// Mods the transform declined because they no longer needed the action.
  final int skipped;

  /// Mods whose sidecar could not be written.
  final int failed;
}

/// Confirms the bulk "assume current" action and, if the user agrees, applies it to the mods left ticked. Returns
/// null when they cancelled.
///
/// **The confirmation lists every mod it would write**, each with a box to untick, so the set rewritten is the set
/// the user has seen (`docs/origin-tracking.md` §6). It also names what it leaves alone, because "12 mods" is a very
/// different offer from "12 of your 47".
Future<BulkAssumeCurrentOutcome?> confirmAndApplyAssumeCurrent(
  BuildContext context,
  BulkAssumeCurrentPlan plan, {
  required OriginWriter writer,
}) async {
  if (!plan.hasWork) return null;
  final chosen = await showDialog<List<ModInfo>>(
    context: context,
    builder: (context) => _AssumeCurrentConfirmation(plan: plan),
  );
  if (chosen == null || chosen.isEmpty) return null;

  var written = 0;
  var skipped = 0;
  var failed = 0;
  for (final mod in chosen) {
    // Sequential on purpose. These are small sidecar rewrites through one
    // service, and the ordering keeps a failure attributable to a mod rather
    // than to the batch.
    final result = await writer(mod.id, bulkAssumeCurrent);
    switch (result) {
      case OriginWriteResult.written:
        written++;
        _log.info('marked as current', fields: {'mod': mod.id, 'baseline': mod.origin?.installedAt});
      case OriginWriteResult.declined:
        skipped++;
      case OriginWriteResult.folderMissing:
      case OriginWriteResult.writeFailed:
        failed++;
        _log.warning('could not mark as current', fields: {'mod': mod.id, 'result': result.name});
    }
  }
  return BulkAssumeCurrentOutcome(
    written: written,
    skipped: skipped,
    failed: failed,
  );
}

/// Reports the outcome once, in one message.
///
/// A partial run deliberately gets its own wording rather than two stacked
/// notifications: "31 done, 4 couldn't be saved" is one fact about one action,
/// and splitting it makes the failure look like a separate event the user
/// missed.
///
/// A run that only *declined* says so plainly and calmly — it is not a failure
/// and must not be coloured or worded like one.
///
/// Takes [loc] and [notify] rather than a context: the writes run after the confirmation closes, and the page that
/// asked may be gone by the time they end.
void showAssumeCurrentOutcome(
  AppLocalizations loc,
  NotificationCenter notify,
  BulkAssumeCurrentOutcome outcome,
) {
  String plural(String key, int count) =>
      loc.plural(key, count, params: {'count': '$count'});

  // Each half is pluralised on the count it is actually about: the title on
  // what was written, the body on what failed.
  final (title, body, severity) = switch (outcome) {
    // Nothing was written and nothing broke: every mod had already been sorted
    // out. Almost always a second press before the rescan caught up.
    BulkAssumeCurrentOutcome(written: 0, failed: 0) => (
        loc.t('mods.assume_current.nothing_to_change'),
        plural('mods.assume_current.already_done', outcome.skipped),
        NotificationSeverity.info,
      ),
    BulkAssumeCurrentOutcome(failed: 0) => (
        plural('mods.assume_current.done_partial_title', outcome.written),
        plural('mods.assume_current.done', outcome.written),
        NotificationSeverity.success,
      ),
    BulkAssumeCurrentOutcome(written: 0) => (
        loc.t('mods.assume_current.not_saved_title'),
        plural('mods.assume_current.failed', outcome.failed),
        NotificationSeverity.warning,
      ),
    _ => (
        plural('mods.assume_current.done_partial_title', outcome.written),
        plural('mods.assume_current.done_partial_body', outcome.failed),
        NotificationSeverity.warning,
      ),
  };
  // No portrait: this is about a count across the library, not about one mod.
  notify.show(title, body: body, severity: severity);
}

class _AssumeCurrentConfirmation extends ConsumerStatefulWidget {
  const _AssumeCurrentConfirmation({required this.plan});

  final BulkAssumeCurrentPlan plan;

  @override
  ConsumerState<_AssumeCurrentConfirmation> createState() => _AssumeCurrentConfirmationState();
}

class _AssumeCurrentConfirmationState extends ConsumerState<_AssumeCurrentConfirmation> {
  /// The mods unticked, by folder id: left asking "Which file?".
  final Set<String> _off = {};

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final plan = widget.plan;
    final eligible = plan.eligible;
    final chosen = [for (final mod in eligible) if (!_off.contains(mod.id)) mod];
    final count = chosen.length;
    final small = text.bodySmall?.copyWith(color: palette.text2);
    final info = palette.badgeInfo;

    String plural(String key, int n, [Map<String, String> more = const {}]) =>
        loc.plural(key, n, params: {'count': '$n', ...more});

    final left = [
      if (plan.untracked.isNotEmpty) plural('mods.assume_current.left_untracked', plan.untracked.length),
      if (plan.undatable.isNotEmpty) plural('mods.assume_current.left_undatable', plan.undatable.length),
      if (plan.elsewhere.isNotEmpty) plural('mods.assume_current.left_elsewhere', plan.elsewhere.length),
    ];

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 18,
            children: [
              Row(
                spacing: 14,
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: info.background,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: info.border!),
                    ),
                    child: Icon(Icons.event_available_rounded, size: 20, color: info.foreground),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      spacing: 2,
                      children: [
                        Text(plural('mods.assume_current.title', count),
                            style: text.titleLarge?.copyWith(color: palette.text)),
                        Row(
                          spacing: 6,
                          children: [
                            Text(loc.t('mods.assume_current.subtitle'),
                                style: text.bodySmall?.copyWith(color: palette.text3)),
                            ZenithBadge(label: loc.t('library.card.file_unknown'), tone: info, small: true),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              Text(loc.t('mods.assume_current.body'), style: text.bodyMedium?.copyWith(color: palette.textProse)),
              _Example(mod: eligible.first),
              _ModList(
                eligible: eligible,
                off: _off,
                onChanged: (id, on) => setState(() => on ? _off.remove(id) : _off.add(id)),
                onAll: (on) => setState(() => on ? _off.clear() : _off.addAll(eligible.map((m) => m.id))),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 6,
                children: [
                  if (left.isNotEmpty)
                    Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: '${loc.t('mods.assume_current.left_title')} ',
                            style: TextStyle(fontWeight: FontWeight.w600, color: palette.textProse),
                          ),
                          TextSpan(
                            text: switch (left) {
                              [final a] => '$a.',
                              [final a, final b] => loc.t('mods.assume_current.left_both', params: {'a': a, 'b': b}),
                              _ => loc.t('mods.assume_current.left_three',
                                  params: {'a': left[0], 'b': left[1], 'c': left[2]}),
                            },
                          ),
                        ],
                      ),
                      style: small,
                    ),
                  if (plan.anyBaselineIsProxy) Text(loc.t('mods.assume_current.proxy_caveat'), style: small),
                ],
              ),
              Row(
                spacing: 8,
                children: [
                  Expanded(
                    child: Text(loc.t('mods.assume_current.nothing_downloaded'),
                        style: text.bodySmall?.copyWith(color: palette.text3)),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(loc.t('mods.assume_current.cancel')),
                  ),
                  FilledButton(
                    onPressed: count == 0 ? null : () => Navigator.pop(context, chosen),
                    child: Text(plural('mods.assume_current.confirm', count)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One mod's date added as the line between what counts as the user's file and what shows as an update.
class _Example extends StatelessWidget {
  const _Example({required this.mod});

  final ModInfo mod;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final added = mod.origin?.installedAt;
    final small = text.bodySmall;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      decoration: BoxDecoration(
        color: palette.ground,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 10,
        children: [
          Text.rich(
            TextSpan(
              children: [
                TextSpan(text: loc.t('mods.assume_current.example', params: {'mod': mod.name})),
                if (added != null)
                  TextSpan(
                    text: ' ${formatResolveDate(added)}',
                    style: TextStyle(fontWeight: FontWeight.w600, color: palette.text),
                  ),
              ],
            ),
            style: small?.copyWith(color: palette.text2),
          ),
          SizedBox(
            height: 18,
            child: LayoutBuilder(
              builder: (context, constraints) => Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 5,
                    height: 8,
                    child: Row(
                      spacing: 3,
                      children: [
                        Expanded(
                          flex: 3,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: Color.lerp(palette.raised, palette.accent, 0.45),
                              borderRadius: const BorderRadius.horizontal(left: Radius.circular(99)),
                            ),
                          ),
                        ),
                        Expanded(
                          flex: 2,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: palette.badgeUpdate.border,
                              borderRadius: const BorderRadius.horizontal(right: Radius.circular(99)),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Positioned(
                    left: constraints.maxWidth * 0.6 - 1,
                    top: 0,
                    width: 2,
                    height: 18,
                    child: DecoratedBox(
                      decoration: BoxDecoration(color: palette.text, borderRadius: BorderRadius.circular(2)),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Row(
            spacing: 16,
            children: [
              Expanded(
                child: Text(loc.t('mods.assume_current.by_then'), style: small?.copyWith(color: palette.textProse)),
              ),
              Expanded(
                child: Text(
                  loc.t('mods.assume_current.after'),
                  textAlign: TextAlign.right,
                  style: small?.copyWith(color: palette.badgeUpdate.foreground),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The mods the action would mark, each with a box: unticked, a mod is left asking.
class _ModList extends ConsumerWidget {
  const _ModList({required this.eligible, required this.off, required this.onChanged, required this.onAll});

  final List<ModInfo> eligible;
  final Set<String> off;
  final void Function(String id, bool on) onChanged;
  final ValueChanged<bool> onAll;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final pages = ref.watch(knownModPagesProvider);
    final count = eligible.length - off.length;

    Widget box({required bool? value, required ValueChanged<bool?> onChanged, required String label}) => Checkbox(
      tristate: value == null,
      value: value,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      semanticLabel: label,
      onChanged: onChanged,
    );

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: palette.card,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              spacing: 12,
              children: [
                box(
                  value: off.isEmpty ? true : (count == 0 ? false : null),
                  label: loc.t('library.all.select_all'),
                  onChanged: (_) => onAll(off.isNotEmpty),
                ),
                Expanded(
                  child: Text(
                    loc.t('mods.assume_current.count_of', params: {'count': '$count', 'total': '${eligible.length}'}),
                    style: text.bodyMedium?.copyWith(color: palette.text, fontWeight: FontWeight.w600),
                  ),
                ),
                Text(loc.t('mods.assume_current.untick_hint'), style: text.bodySmall?.copyWith(color: palette.text3)),
              ],
            ),
          ),
          Divider(height: 1, color: palette.outline),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 216),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: eligible.length,
              itemBuilder: (context, index) {
                final mod = eligible[index];
                final on = !off.contains(mod.id);
                final author = installedRecord(mod, pages).page?.submitter?.name;
                final added = mod.origin?.installedAt;
                final byline = [libraryGroupName(libraryGroupOf(mod.characterId), loc), ?author].join(' · ');
                return Opacity(
                  opacity: on ? 1 : 0.55,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(border: Border(bottom: BorderSide(color: palette.rowDivider))),
                    child: Row(
                      spacing: 12,
                      children: [
                        box(
                          value: on,
                          label: loc.t('mods.assume_current.mark_one', params: {'mod': mod.name}),
                          onChanged: (value) => onChanged(mod.id, value ?? false),
                        ),
                        ModThumb(mod: mod, width: 36, height: 24),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                mod.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: text.bodyMedium?.copyWith(color: palette.text, fontWeight: FontWeight.w600),
                              ),
                              Text(
                                byline,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: text.bodySmall?.copyWith(color: palette.text3),
                              ),
                            ],
                          ),
                        ),
                        if (added != null)
                          Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(text: '${loc.t('mods.assume_current.added')} '),
                                TextSpan(text: formatResolveDate(added), style: ZenithType.of(context).monoSmall),
                              ],
                            ),
                            style: text.bodySmall?.copyWith(color: palette.text2),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
