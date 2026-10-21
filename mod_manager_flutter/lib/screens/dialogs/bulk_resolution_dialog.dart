import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../models/character_info.dart';
import '../../models/gamebanana/gb_file.dart';
import '../../models/mod_origin.dart';
import '../../models/origin_enums.dart';
import '../../services/bulk_resolution.dart';
import '../../services/gamebanana/file_selection.dart';
import '../../services/origin_resolution.dart';
import '../../services/origin_write.dart';
import '../../services/update_check.dart';
import '../../utils/gamebanana_url.dart';
import '../../utils/notifications.dart';
import '../../utils/state_providers.dart';
import '../../utils/url_utils.dart';
import '../components/dialog_section.dart';
import 'resolve_origin_dialog.dart';

/// Opens the per-mod resolve dialog for one mod.
/// A seam for tests; production passes [showResolveOriginDialogForResult].
typedef ResolveOriginOpener = Future<ResolveOriginResult?> Function(
  BuildContext context,
  ModInfo mod,
);

/// The bulk check's **results screen**, which is also the bulk **resolution**
/// screen.
///
/// One screen, two jobs, and folding them together is the decision rather than a convenience: the check already fetched every tracked mod's record, and that one response carries the mod's name and its whole file list — everything resolution needs.
/// A separate migration screen would re-fetch the same library to ask questions about it, and would go stale the day the last legacy mod was resolved.
///
/// Four things about this surface are decisions, not layout:
///
/// - **Nothing ticked here is written until Apply.** Writing the safe inferences immediately and offering an undo loses:
///   the control that got the user here says "check for updates" and nothing about rewriting sidecars,
///   and this codebase's own placement rule — the one the bulk "assume current" button follows — is that a bulk rewrite acts only on a set the user has seen.
///   A pre-ticked row costs one glance and one press; an undo costs noticing a summary nobody asked for.
///   The untracked list is the one exception, and it is not a bulk write: each mod goes through the per-mod dialog, which saves as it closes.
/// - **Identity starts unticked, everything else starts ticked.** The asymmetry is the point.
///   A file this pass inferred is a statement the app is making and can defend.
///   An identity is the one thing only the user can settle: `mod_id` came from a free-form url somebody pasted, and pre-ticking it would turn the glance test into a rubber stamp — the exact failure the "bulk acts only on precise handles" rule exists to prevent.
/// - **The comparison is name to name, and there is no remote thumbnail.** The
///   plan asked for one; `Mod/Multi` cannot supply the content-filter hint
///   (`_sInitialVisibility` is rejected as an unknown property there), and the
///   one available proxy is unreliable — apiv13's server-pixelated
///   `_sFileNNNSfw` copy is missing on a mod the profile reports as `hide`
///   (measured on 541825). Rendering an unblurred adult cover in the library
///   tab to make a name comparison prettier is not a trade worth making, and
///   the realistic failure this pass catches is a wrong paste, where the two
///   names disagree completely.
/// - **A row that can be answered wrong offers the way out.** Every row links
///   to the mod page, and anything the list cannot settle stays a per-mod
///   resolve dialog away.
///
/// Opens when the plan has a question row or an untracked mod to list.
///
/// Returns true when at least one sidecar was written, so the caller rescans —
/// the status slot reads `ModInfo.origin`, which only a scan refreshes.
/// That includes a mod saved through the per-mod dialog, which writes on its own whether or not Apply follows.
///
/// Apply clears the stored update verdict of each mod it writes, unless that verdict found an update. No mod is checked again.
Future<bool> showBulkResolutionDialog(
  BuildContext context,
  BulkResolutionPlan plan, {
  int updatesFound = 0,
  int unreachable = 0,
  required OriginWriter writer,
  required OriginReader reader,
  ResolveOriginOpener resolveOrigin = showResolveOriginDialogForResult,
}) async {
  if (!plan.listsAnything) return false;
  // The app's container, so the verdicts below are cleared even if the caller is gone by the time Apply's writes land.
  final container = ProviderScope.containerOf(context, listen: false);
  var resolvedAny = false;
  final answers = await showDialog<Map<String, BulkResolutionAnswer>>(
    context: context,
    builder: (_) => BulkResolutionDialog(
      plan: plan,
      updatesFound: updatesFound,
      unreachable: unreachable,
      readOrigin: reader,
      resolveOrigin: (context, mod) async {
        final result = await resolveOrigin(context, mod);
        if (result != null) resolvedAny = true;
        return result;
      },
    ),
  );
  if (answers == null || answers.isEmpty) return resolvedAny;
  if (!context.mounted) return resolvedAny;

  final outcome = await _applyAnswers(
    answers,
    (modId, update) => whileWritingMod(container, modId, () => writer(modId, update)),
  );
  if (outcome.writtenIds.isNotEmpty) {
    // The update dialog skips its check while a verdict is stored, so a written mod's verdict is cleared.
    // A found update is kept, dismissed or not: this screen never rebinds a folder, so it is still about the right page.
    final checks = container.read(modUpdateChecksProvider.notifier);
    checks.state = {...checks.state}..removeWhere(
        (modId, check) =>
            outcome.writtenIds.contains(modId) && !_foundUpdate(check),
      );
  }
  final wrote = outcome.written > 0 || resolvedAny;
  if (!context.mounted) return wrote;
  _showOutcome(context, outcome);
  return wrote;
}

/// Whether [check] reports something newer, including one the user dismissed.
bool _foundUpdate(UpdateCheck check) =>
    check.outcome == UpdateOutcome.updateAvailable ||
    check.outcome == UpdateOutcome.possiblyOutdated;

/// How the write loop ended.
///
/// A decline is the re-read guard doing its job: the mod was resolved by something else
/// between building this list and pressing Apply. It is counted apart from a failure.
class BulkResolutionOutcome {
  const BulkResolutionOutcome({
    required this.writtenIds,
    required this.skipped,
    required this.failed,
  });

  /// Mod folder ids whose sidecar was written.
  final Set<String> writtenIds;
  final int skipped;
  final int failed;

  int get written => writtenIds.length;
}

Future<BulkResolutionOutcome> _applyAnswers(
  Map<String, BulkResolutionAnswer> answers,
  OriginWriter writer,
) async {
  final written = <String>{};
  var skipped = 0;
  var failed = 0;
  for (final entry in answers.entries) {
    // Sequential, like every other bulk write here: these are small sidecar
    // rewrites through one service, and the ordering keeps a failure
    // attributable to a mod rather than to the batch.
    final result = await writer(
      entry.key,
      (current) => applyBulkResolution(current, entry.value),
    );
    switch (result) {
      case OriginWriteResult.written:
        written.add(entry.key);
      case OriginWriteResult.declined:
        skipped++;
      case OriginWriteResult.folderMissing:
      case OriginWriteResult.writeFailed:
        failed++;
    }
  }
  return BulkResolutionOutcome(
    writtenIds: written,
    skipped: skipped,
    failed: failed,
  );
}

void _showOutcome(BuildContext context, BulkResolutionOutcome outcome) {
  final loc = context.loc;
  String plural(String key, int count) =>
      loc.plural(key, count, params: {'count': '$count'});

  // Each half is pluralised on the count it is actually about: the title on
  // what was written, the body on what failed.
  final (title, body, kind) = switch (outcome) {
    BulkResolutionOutcome(written: 0, failed: 0) => (
        loc.t('mods.bulk_resolve.nothing_to_change'),
        plural('mods.bulk_resolve.already_done', outcome.skipped),
        NotificationKind.note,
      ),
    BulkResolutionOutcome(failed: 0) => (
        plural('mods.bulk_resolve.done_title', outcome.written),
        loc.t('mods.bulk_resolve.done_body'),
        NotificationKind.done,
      ),
    BulkResolutionOutcome(written: 0) => (
        loc.t('mods.bulk_resolve.not_saved_title'),
        plural('mods.bulk_resolve.failed', outcome.failed),
        NotificationKind.error,
      ),
    _ => (
        plural('mods.bulk_resolve.done_partial_title', outcome.written),
        plural('mods.bulk_resolve.done_partial_body', outcome.failed),
        NotificationKind.warning,
      ),
  };
  // No portrait: this is about a count across the library, not about one mod.
  context.notify.show(kind, title, body: body);
}

class BulkResolutionDialog extends StatefulWidget {
  const BulkResolutionDialog({
    super.key,
    required this.plan,
    this.updatesFound = 0,
    this.unreachable = 0,
    required this.readOrigin,
    this.resolveOrigin = showResolveOriginDialogForResult,
  });

  final BulkResolutionPlan plan;

  /// From the same pass, so the screen can state what the check itself found
  /// instead of leaving the user to read it off the cards behind the dialog.
  final int updatesFound;
  final int unreachable;

  /// What an untracked mod's "Resolve…" button opens.
  final ResolveOriginOpener resolveOrigin;

  /// Reads a mod's origin as saved now, so each Resolve opens on that rather than on the copy this screen was built with.
  final OriginReader readOrigin;

  @override
  State<BulkResolutionDialog> createState() => _BulkResolutionDialogState();
}

class _BulkResolutionDialogState extends State<BulkResolutionDialog> {
  /// Mod folder ids whose identity the user has confirmed.
  final Set<String> _identity = <String>{};

  /// Mod folder id -> the file to record and the tier it may claim.
  final Map<String, ({GbFile file, OriginConfidence tier})> _files = {};

  /// Untracked mod folder ids the per-mod dialog has since settled: bound to a page, or marked not from GameBanana.
  /// Already saved, so they are never part of [_answers].
  final Map<String, ResolveOriginResult> _resolved = {};

  /// Whether a per-mod dialog has saved anything, which turns Cancel into Close: nothing is undone by leaving.
  bool _savedAny = false;

  /// Set while a per-mod dialog is open, so a double click opens one.
  bool _resolving = false;

  @override
  void initState() {
    super.initState();
    for (final row in widget.plan.rows) {
      // Pre-ticked: the app's own statements, each defensible from the response
      // in hand. Identity is deliberately absent from this loop.
      if (row.suggestion case final candidate?) {
        _files[row.mod.id] = (
          file: candidate.file,
          tier: candidate.isExact
              ? OriginConfidence.exact
              : OriginConfidence.inferred,
        );
      }
    }
  }

  /// The answer each row would write, keyed by mod folder id, empty ones
  /// dropped.
  Map<String, BulkResolutionAnswer> get _answers {
    final out = <String, BulkResolutionAnswer>{};
    for (final row in widget.plan.rows) {
      final choice = _files[row.mod.id];
      final answer = BulkResolutionAnswer(
        modId: row.remote.idRow,
        confirmIdentity: _identity.contains(row.mod.id),
        file: choice?.file,
        fileConfidence: choice?.tier ?? OriginConfidence.inferred,
      );
      if (!answer.isEmpty) out[row.mod.id] = answer;
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final scheme = Theme.of(context).colorScheme;
    final answers = _answers;
    // **Grouped by the question each row leads with, and a row is never in two
    // groups.** Ungrouped, every row looked identical whatever it was asking,
    // and the screen read as a wall of checkboxes. Splitting by question and
    // duplicating a mod across sections was the other option and is worse: on a
    // legacy library nearly every row asks both, so the same names would appear
    // twice throughout. A row that asks about identity is filed there whatever
    // else it asks.
    final identityRows =
        widget.plan.rows.where((r) => r.needsIdentity).toList();
    final versionOnly =
        widget.plan.rows.where((r) => !r.needsIdentity).toList();

    return AlertDialog(
      title: Text(loc.t('mods.bulk_resolve.title')),
      content: SizedBox(
        width: 700,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Bounded and scrolling inside itself so the action bar stays put:
            // a library can put fifty rows in here, and an AlertDialog that
            // grows past the window takes its own buttons with it. The intro
            // scrolls with the rows, since on a small window it alone can
            // outgrow the dialog.
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  // About the ticked boxes, so absent when there are none.
                  if (widget.plan.hasWork)
                    DialogNotice(
                      icon: Icons.help_outline,
                      message: loc.t('mods.bulk_resolve.intro'),
                    ),
                  if (widget.updatesFound > 0 || widget.unreachable > 0)
                    _checkSummary(loc, scheme),
                  const SizedBox(height: 8),
                  if (identityRows.isNotEmpty)
                    _section(
                      loc,
                      scheme,
                      title: 'mods.bulk_resolve.section_identity',
                      why: 'mods.bulk_resolve.section_identity_why',
                      rows: identityRows,
                      trailing: identityRows.length > 1
                          ? _confirmAll(loc, identityRows)
                          : null,
                    ),
                  if (versionOnly.isNotEmpty)
                    _section(
                      loc,
                      scheme,
                      title: 'mods.bulk_resolve.section_version',
                      why: 'mods.bulk_resolve.section_version_why',
                      rows: versionOnly,
                    ),
                  if (widget.plan.untracked.isNotEmpty)
                    _untracked(loc, scheme),
                  _excluded(loc),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(loc.t(
            _savedAny ? 'mods.update.close' : 'mods.bulk_resolve.cancel',
          )),
        ),
        // Absent with no question rows, since there is nothing it could ever save.
        if (widget.plan.hasWork)
          FilledButton(
            // Disabled rather than hidden when nothing is ticked:
            // unticking everything is a legitimate way to leave, and a button that vanishes reads as a bug.
            onPressed: answers.isEmpty
                ? null
                : () => Navigator.pop(context, Map.of(answers)),
            child: Text(loc.plural(
              'mods.bulk_resolve.apply',
              answers.length,
              params: {'count': '${answers.length}'},
            )),
          ),
      ],
    );
  }

  Widget _section(
    AppLocalizations loc,
    ColorScheme scheme, {
    required String title,
    required String why,
    required List<BulkResolutionRow> rows,
    Widget? trailing,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: DialogSection(
        title: loc.t(title, params: {'count': '${rows.length}'}),
        subtitle: loc.t(why),
        children: [
          if (trailing != null)
            Align(alignment: Alignment.centerLeft, child: trailing),
          for (final row in rows) _row(row, scheme, loc),
        ],
      ),
    );
  }

  /// A shortcut for a list the user has already read, never a default: it is a
  /// second press, after the rows are on screen, and it says how many it covers.
  /// Offered only above **two or more** rows — over a single row it is the row's
  /// own checkbox with more words.
  Widget _confirmAll(AppLocalizations loc, List<BulkResolutionRow> rows) {
    final all = rows.every((r) => _identity.contains(r.mod.id));
    return TextButton.icon(
      icon: Icon(all ? Icons.remove_done : Icons.done_all, size: 16),
      onPressed: () => setState(() {
        for (final row in rows) {
          all ? _identity.remove(row.mod.id) : _identity.add(row.mod.id);
        }
      }),
      label: Text(loc.t(
        all
            ? 'mods.bulk_resolve.confirm_none'
            : 'mods.bulk_resolve.confirm_all',
        params: {'count': '${rows.length}'},
      )),
    );
  }

  /// What the check itself concluded, above the questions.
  ///
  /// Stated here because this dialog *replaces* the summary notification when it
  /// opens — two reports of one press, one behind the other, is how a user ends
  /// up reading neither.
  Widget _checkSummary(AppLocalizations loc, ColorScheme scheme) {
    String plural(String key, int count) =>
        loc.plural(key, count, params: {'count': '$count'});
    final parts = <String>[
      if (widget.updatesFound > 0)
        plural('mods.update.bulk_found', widget.updatesFound),
      if (widget.unreachable > 0)
        plural('mods.update.bulk_failed', widget.unreachable),
    ];
    return DialogNotice(
      icon: Icons.info_outline,
      message: parts.join(' · '),
    );
  }

  /// The mods with no mod page, folded under their count.
  ///
  /// Apply never covers them: identifying one means matching a folder name against a search,
  /// so each goes through the per-mod dialog, one at a time, opened only by its own button.
  /// That dialog saves as it closes, and nothing opens by itself afterwards.
  Widget _untracked(AppLocalizations loc, ColorScheme scheme) {
    final theme = Theme.of(context);
    final mods = [...widget.plan.untracked]
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final border = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(8),
      side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.4)),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        shape: border,
        collapsedShape: border,
        leading: const Icon(Icons.link_off),
        title: Text(
          loc.plural('mods.bulk_resolve.excluded_untracked', mods.length,
              params: {'count': '${mods.length}'}),
          style: theme.textTheme.bodyMedium,
        ),
        subtitle: Text(
          loc.t('mods.bulk_resolve.untracked_why'),
          style: theme.textTheme.bodySmall
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
        children: [for (final mod in mods) _untrackedRow(mod, scheme, loc)],
      ),
    );
  }

  Widget _untrackedRow(ModInfo mod, ColorScheme scheme, AppLocalizations loc) {
    final resolved = _resolved[mod.id];
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: scheme.outlineVariant.withValues(alpha: 0.4),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _named(Icons.folder_outlined, mod.name, scheme, strong: true),
                  if (resolved != null && resolved.modId != null) ...[
                    const SizedBox(height: 2),
                    _named(
                      Icons.link,
                      resolved.pageName ?? '#${resolved.modId}',
                      scheme,
                    ),
                  ],
                  if (resolved != null) ...[
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Icon(Icons.check_circle,
                            size: 16, color: scheme.primary),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            loc.t(resolved.modId != null
                                ? 'mods.bulk_resolve.untracked_resolved'
                                : 'mods.bulk_resolve.untracked_marked_own'),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            // Gone once the row is settled: the question it stood for is answered.
            if (resolved == null)
              TextButton(
                onPressed: _resolving ? null : () => _resolve(mod),
                child: Text(loc.t('mods.bulk_resolve.untracked_resolve')),
              ),
          ],
        ),
      ),
    );
  }

  /// A row turns done when the dialog bound the mod to a page or marked it not from GameBanana.
  /// A cancel, or any other answer, leaves it as it was.
  ///
  /// Nothing is fetched for it here: the check never looked this mod up,
  /// so the row says to check again rather than showing a verdict.
  ///
  /// The dialog opens on the mod as saved now, read fresh:
  /// a step that saves without settling the row, such as naming what a patch applies to, leaves the copy this screen was built with out of date.
  Future<void> _resolve(ModInfo mod) async {
    if (_resolving) return;
    setState(() => _resolving = true);
    final ResolveOriginResult? result;
    try {
      final current = await widget.readOrigin(mod.id);
      if (!mounted) return;
      result = await widget.resolveOrigin(context, _withOrigin(mod, current));
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
    if (!mounted || result == null) return;
    final saved = result;
    final settled = saved.modId != null || saved.markedNotFromGameBanana;
    setState(() {
      _savedAny = true;
      if (settled) _resolved[mod.id] = saved;
    });
  }

  /// [mod] carrying [origin] in place of its own, including none: `copyWith` cannot clear the block.
  ModInfo _withOrigin(ModInfo mod, ModOrigin? origin) => ModInfo(
        id: mod.id,
        name: mod.name,
        characterId: mod.characterId,
        isActive: mod.isActive,
        imagePath: mod.imagePath,
        description: mod.description,
        tags: mod.tags,
        images: mod.images,
        isFavorite: mod.isFavorite,
        keybinds: mod.keybinds,
        origin: origin,
        uid: mod.uid,
      );

  /// The mods this screen has nothing to ask about.
  ///
  /// Named for the same reason the "assume current" confirmation names its
  /// exclusions: "eleven mods" out of a library of fifty reads as though it
  /// covered the library unless the other thirty-nine are accounted for.
  Widget _excluded(AppLocalizations loc) {
    if (widget.plan.settled == 0) return const SizedBox.shrink();
    return DialogNotice(
      icon: Icons.playlist_remove,
      message: loc.plural('mods.bulk_resolve.already_known', widget.plan.settled,
          params: {'count': '${widget.plan.settled}'}),
    );
  }

  Widget _row(
    BulkResolutionRow row,
    ColorScheme scheme,
    AppLocalizations loc,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: scheme.outlineVariant.withValues(alpha: 0.4),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // **The glance test, with both halves labelled by an icon.** A
            // folder and a mod page stacked as two bare lines gave no clue
            // which was which, or that the comparison between them was the
            // question being asked.
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _named(
                        Icons.folder_outlined,
                        row.mod.name,
                        scheme,
                        strong: true,
                      ),
                      const SizedBox(height: 2),
                      _named(Icons.link, row.remoteName, scheme),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.open_in_new, size: 18),
                  visualDensity: VisualDensity.compact,
                  tooltip: loc.t('mods.resolve.open_page'),
                  onPressed: () => launchExternalUrl(
                    context,
                    gameBananaModUrl(row.remote.idRow),
                  ),
                ),
              ],
            ),
            if (row.needsIdentity || row.needsVersion)
              const SizedBox(height: 6),
            if (row.needsIdentity) _identityTick(row, loc),
            if (row.needsVersion) _versionControl(row, scheme, loc),
          ],
        ),
      ),
    );
  }

  /// One name with an icon saying what kind of thing it is.
  Widget _named(
    IconData icon,
    String name,
    ColorScheme scheme, {
    bool strong = false,
  }) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon, size: 16, color: scheme.onSurfaceVariant),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: strong
                ? theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  )
                : theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }

  /// The why-line lives in the section subtitle rather than under every row —
  /// repeated fifty-seven times it was noise, and it is the same sentence each
  /// time.
  Widget _identityTick(BulkResolutionRow row, AppLocalizations loc) {
    return _tick(
      value: _identity.contains(row.mod.id),
      label: loc.t('mods.bulk_resolve.confirm_identity'),
      onChanged: (on) => setState(() {
        on ? _identity.add(row.mod.id) : _identity.remove(row.mod.id);
      }),
    );
  }

  /// Either a pre-ticked answer, or the picker.
  ///
  /// The two are not variants of one control: a suggestion the pass can defend
  /// is a checkbox with its reason written on it, while an ambiguous mod is a
  /// list nothing has selected. Preselecting the picker would make a guess look
  /// like an answer, which is the rule the per-mod dialog already holds — only
  /// a checksum match and a single unambiguous file ever start out chosen.
  Widget _versionControl(
    BulkResolutionRow row,
    ColorScheme scheme,
    AppLocalizations loc,
  ) {
    if (row.suggestion case final candidate?) {
      return _tick(
        value: _files.containsKey(row.mod.id),
        label: loc.t(
          'mods.bulk_resolve.record_file',
          params: {'file': fileDisplayName(candidate.file)},
        ),
        subtitle: _reasonLabel(candidate.reason, loc),
        onChanged: (on) => setState(() {
          if (on) {
            _files[row.mod.id] = (
              file: candidate.file,
              tier: candidate.isExact
                  ? OriginConfidence.exact
                  : OriginConfidence.inferred,
            );
          } else {
            _files.remove(row.mod.id);
          }
        }),
      );
    }

    final chosen = _files[row.mod.id]?.file.idRow;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 2, left: 2),
      child: Row(
        children: [
          // Labelled, because inside a section headed "confirm the mod page" an
          // unlabelled dropdown is a control with no stated question.
          Icon(
            Icons.insert_drive_file_outlined,
            size: 16,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: DropdownButton<int>(
              value: chosen,
              isExpanded: true,
              isDense: true,
              hint: Text(
                loc.t('mods.bulk_resolve.choose_file'),
                style: theme.textTheme.bodySmall,
              ),
              items: [
                for (final candidate in row.candidates)
                  DropdownMenuItem<int>(
                    value: candidate.file.idRow,
                    child: Text(
                      _candidateLabel(candidate, loc),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
              ],
              onChanged: (id) => setState(() {
                final candidate = row.candidates
                    .firstWhere((candidate) => candidate.file.idRow == id);
                _files[row.mod.id] = (
                  file: candidate.file,
                  // The user reading this list and choosing a row is exactly
                  // what `user` means — the same claim the per-mod dialog
                  // records for the same act. A hash match stays `exact`.
                  tier: candidate.isExact
                      ? OriginConfidence.exact
                      : OriginConfidence.user,
                );
              }),
            ),
          ),
          if (chosen != null)
            IconButton(
              icon: const Icon(Icons.clear, size: 16),
              visualDensity: VisualDensity.compact,
              tooltip: loc.t('mods.bulk_resolve.clear_choice'),
              onPressed: () => setState(() => _files.remove(row.mod.id)),
            ),
        ],
      ),
    );
  }

  /// One line of a candidate in the picker: the filename, the author's own
  /// words, and — where there is one — why it is being suggested.
  ///
  /// Flattened onto a single line rather than the three the per-mod dialog
  /// gives it, because this list is one control inside one row of a list of
  /// rows. The naming rule itself is shared (`fileDisplayName` /
  /// `fileDisplayDetail`), so the two surfaces cannot name a file differently.
  String _candidateLabel(ResolveCandidate candidate, AppLocalizations loc) {
    final parts = <String>[
      fileDisplayName(candidate.file),
      if (fileDisplayDetail(candidate.file) case final detail?) detail,
      if (_reasonLabel(candidate.reason, loc) case final reason?) reason,
    ];
    return parts.join(' · ');
  }

  String? _reasonLabel(FileMatchReason reason, AppLocalizations loc) =>
      switch (reason) {
        FileMatchReason.archiveHash => loc.t('mods.resolve.reason_hash'),
        FileMatchReason.folderName => loc.t('mods.resolve.reason_folder'),
        FileMatchReason.installDate => loc.t('mods.resolve.reason_date'),
        FileMatchReason.onlyFile => loc.t('mods.resolve.reason_only'),
        FileMatchReason.none => null,
      };

  Widget _tick({
    required bool value,
    required String label,
    String? subtitle,
    required ValueChanged<bool> onChanged,
  }) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox.square(
              dimension: 24,
              child: Checkbox(
                value: value,
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                onChanged: (next) => onChanged(next ?? false),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: theme.textTheme.bodySmall),
                  if (subtitle != null)
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
