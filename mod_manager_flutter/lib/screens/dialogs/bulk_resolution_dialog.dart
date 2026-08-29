import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../models/gamebanana/gb_file.dart';
import '../../models/origin_enums.dart';
import '../../services/api_service.dart';
import '../../services/bulk_resolution.dart';
import '../../services/gamebanana/file_selection.dart';
import '../../services/origin_resolution.dart';
import '../../utils/gamebanana_url.dart';
import '../../utils/notifications.dart';
import '../../utils/url_utils.dart';
import '../components/dialog_section.dart';
import 'assume_current_dialog.dart' show BulkOriginWriter;

/// The bulk check's **results screen**, which is also the bulk **resolution**
/// screen.
///
/// One screen, two jobs, and folding them together is the decision rather than
/// a convenience: the check already fetched every tracked mod's record, and
/// that one response carries the mod's name, its whole file list and the
/// upstream-gone flags — everything resolution needs. A separate migration
/// screen would re-fetch the same library to ask questions about it, and would
/// go stale the day the last legacy mod was resolved.
///
/// Four things about this surface are decisions, not layout:
///
/// - **Nothing is written until Apply.** The plan it was built from said to
///   write the safe inferences immediately and offer an undo. The control that
///   got the user here says "check for updates" and nothing about rewriting
///   sidecars, and this codebase's own placement rule — the one the bulk
///   "assume current" button follows — is that a bulk rewrite acts only on a
///   set the user has seen. A pre-ticked row costs one glance and one press;
///   an undo costs noticing a summary nobody asked for.
/// - **Identity starts unticked, everything else starts ticked.** The
///   asymmetry is the point. A file this pass inferred, and a page the API
///   itself says is gone, are statements the app is making and can defend. An
///   identity is the one thing only the user can settle: `mod_id` came from a
///   free-form url somebody pasted, and pre-ticking it would turn the glance
///   test into a rubber stamp — the exact failure the "bulk acts only on
///   precise handles" rule exists to prevent.
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
/// Returns true when at least one sidecar was written, so the caller rescans —
/// the status slot reads `ModInfo.origin`, which only a scan refreshes.
Future<bool> showBulkResolutionDialog(
  BuildContext context,
  BulkResolutionPlan plan, {
  int updatesFound = 0,
  int unreachable = 0,
  BulkOriginWriter writer = ApiService.updateModOrigin,
}) async {
  if (!plan.hasWork) return false;
  final answers = await showDialog<Map<String, BulkResolutionAnswer>>(
    context: context,
    builder: (_) => BulkResolutionDialog(
      plan: plan,
      updatesFound: updatesFound,
      unreachable: unreachable,
    ),
  );
  if (answers == null || answers.isEmpty) return false;
  if (!context.mounted) return false;

  final outcome = await _applyAnswers(answers, writer);
  if (!context.mounted) return outcome.written > 0;
  _showOutcome(context, outcome);
  return outcome.written > 0;
}

/// How the write loop ended.
///
/// Three outcomes rather than two, exactly as the bulk "assume current" action
/// found it had to be: `updateOrigin` answers one bare `false` for "the folder
/// is unwritable" and "the transform declined", and those are opposite facts. A
/// decline is the re-read guard doing its job — the mod was resolved by
/// something else between building this list and pressing Apply — and reporting
/// it as a filesystem permission error would blame the user for the guard
/// working.
class BulkResolutionOutcome {
  const BulkResolutionOutcome({
    required this.written,
    required this.skipped,
    required this.failed,
  });

  final int written;
  final int skipped;
  final int failed;
}

Future<BulkResolutionOutcome> _applyAnswers(
  Map<String, BulkResolutionAnswer> answers,
  BulkOriginWriter writer,
) async {
  var written = 0;
  var skipped = 0;
  var failed = 0;
  for (final entry in answers.entries) {
    // Sequential, like every other bulk write here: these are small sidecar
    // rewrites through one service, and the ordering keeps a failure
    // attributable to a mod rather than to the batch.
    var declined = false;
    final ok = await writer(entry.key, (current) {
      final next = applyBulkResolution(current, entry.value);
      if (next == null) declined = true;
      return next;
    });
    if (ok) {
      written++;
    } else if (declined) {
      skipped++;
    } else {
      failed++;
    }
  }
  return BulkResolutionOutcome(
    written: written,
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
  final (title, body, severity) = switch (outcome) {
    BulkResolutionOutcome(written: 0, failed: 0) => (
        loc.t('mods.bulk_resolve.nothing_to_change'),
        plural('mods.bulk_resolve.already_done', outcome.skipped),
        NotificationSeverity.info,
      ),
    BulkResolutionOutcome(failed: 0) => (
        plural('mods.bulk_resolve.done_title', outcome.written),
        loc.t('mods.bulk_resolve.done_body'),
        NotificationSeverity.success,
      ),
    BulkResolutionOutcome(written: 0) => (
        loc.t('mods.bulk_resolve.not_saved_title'),
        plural('mods.bulk_resolve.failed', outcome.failed),
        NotificationSeverity.warning,
      ),
    _ => (
        plural('mods.bulk_resolve.done_partial_title', outcome.written),
        plural('mods.bulk_resolve.done_partial_body', outcome.failed),
        NotificationSeverity.warning,
      ),
  };
  // No portrait: this is about a count across the library, not about one mod.
  context.notify.show(title, body: body, severity: severity);
}

class BulkResolutionDialog extends StatefulWidget {
  const BulkResolutionDialog({
    super.key,
    required this.plan,
    this.updatesFound = 0,
    this.unreachable = 0,
  });

  final BulkResolutionPlan plan;

  /// From the same pass, so the screen can state what the check itself found
  /// instead of leaving the user to read it off the cards behind the dialog.
  final int updatesFound;
  final int unreachable;

  @override
  State<BulkResolutionDialog> createState() => _BulkResolutionDialogState();
}

class _BulkResolutionDialogState extends State<BulkResolutionDialog> {
  /// Mod folder ids whose identity the user has confirmed.
  final Set<String> _identity = <String>{};

  /// Mod folder id -> the file to record and the tier it may claim.
  final Map<String, ({GbFile file, OriginConfidence tier})> _files = {};

  /// Mod folder ids whose `remote_missing` answer is ticked.
  final Set<String> _source = <String>{};

  @override
  void initState() {
    super.initState();
    for (final row in widget.plan.rows) {
      // Pre-ticked: the app's own statements, each defensible from the response
      // in hand. Identity is deliberately absent from this loop.
      if (row.sourceGone || row.sourceBack) _source.add(row.mod.id);
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
        remoteMissing: _source.contains(row.mod.id)
            ? (row.sourceGone ? true : (row.sourceBack ? false : null))
            : null,
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
    // twice throughout.
    //
    // **A cascade, not four independent filters**, which is the correction: a
    // mod recorded as gone whose page came back *and* whose identity was never
    // confirmed carries both questions, and with `back` unguarded it was listed
    // under two headings with the same two checkboxes. Nothing was written
    // twice — both copies key off the same mod id — but "Save 1 mod" under two
    // visible rows reads as a bug, and it contradicted the one invariant this
    // layout is built on. `gone` needs no guard: `planBulkResolution` returns
    // early for a missing record, so such a row can never carry another
    // question.
    final identityRows =
        widget.plan.rows.where((r) => r.needsIdentity).toList();
    final gone = widget.plan.rows.where((r) => r.sourceGone).toList();
    final back = widget.plan.rows
        .where((r) => r.sourceBack && !r.needsIdentity)
        .toList();
    final versionOnly = widget.plan.rows
        .where((r) => !r.needsIdentity && !r.sourceGone && !r.sourceBack)
        .toList();

    return AlertDialog(
      title: Text(loc.t('mods.bulk_resolve.title')),
      content: SizedBox(
        width: 700,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DialogNotice(
              icon: Icons.help_outline,
              message: loc.t('mods.bulk_resolve.intro'),
            ),
            if (widget.updatesFound > 0 || widget.unreachable > 0)
              _checkSummary(loc, scheme),
            const SizedBox(height: 8),
            // Bounded and scrolling inside itself so the action bar stays put:
            // a library can put fifty rows in here, and an AlertDialog that
            // grows past the window takes its own buttons with it.
            Flexible(
              child: ListView(
                shrinkWrap: true,
                // The main work first, the two rare factual sections after it.
                // A library with one dead mod page and fifty to confirm should
                // not open on the dead one.
                children: [
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
                  if (gone.isNotEmpty)
                    _section(
                      loc,
                      scheme,
                      title: 'mods.bulk_resolve.section_gone',
                      why: 'mods.bulk_resolve.section_gone_why',
                      rows: gone,
                    ),
                  if (back.isNotEmpty)
                    _section(
                      loc,
                      scheme,
                      title: 'mods.bulk_resolve.section_back',
                      why: 'mods.bulk_resolve.section_back_why',
                      rows: back,
                    ),
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
          child: Text(loc.t('mods.bulk_resolve.cancel')),
        ),
        FilledButton(
          // Disabled rather than hidden when nothing is ticked: unticking
          // everything is a legitimate way to leave, and a button that vanishes
          // reads as a bug.
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

  /// The two groups this screen is deliberately *not* acting on.
  ///
  /// Named for the same reason the "assume current" confirmation names its
  /// exclusions: "eleven mods" out of a library of fifty reads as though it
  /// covered the library unless the other thirty-nine are accounted for.
  Widget _excluded(AppLocalizations loc) {
    String plural(String key, int count) =>
        loc.plural(key, count, params: {'count': '$count'});
    final lines = <String>[
      if (widget.plan.untracked.isNotEmpty)
        plural('mods.bulk_resolve.excluded_untracked',
            widget.plan.untracked.length),
      if (widget.plan.settled > 0)
        plural('mods.bulk_resolve.already_known', widget.plan.settled),
    ];
    if (lines.isEmpty) return const SizedBox.shrink();
    return DialogNotice(
      icon: Icons.playlist_remove,
      message: lines.join('\n'),
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
            if (row.needsIdentity ||
                row.needsVersion ||
                row.sourceGone ||
                row.sourceBack)
              const SizedBox(height: 6),
            if (row.needsIdentity) _identityTick(row, loc),
            if (row.sourceGone || row.sourceBack) _sourceTick(row, loc),
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
                ? theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  )
                : theme.textTheme.bodyMedium
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

  Widget _sourceTick(BulkResolutionRow row, AppLocalizations loc) {
    return _tick(
      value: _source.contains(row.mod.id),
      label: loc.t(row.sourceGone
          ? 'mods.bulk_resolve.record_source_gone'
          : 'mods.bulk_resolve.record_source_back'),
      onChanged: (on) => setState(() {
        on ? _source.add(row.mod.id) : _source.remove(row.mod.id);
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
                style: theme.textTheme.bodyMedium,
              ),
              items: [
                for (final candidate in row.candidates)
                  DropdownMenuItem<int>(
                    value: candidate.file.idRow,
                    child: Text(
                      _candidateLabel(candidate, loc),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium,
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
                  Text(label, style: theme.textTheme.bodyMedium),
                  if (subtitle != null)
                    Text(
                      subtitle,
                      style: theme.textTheme.bodyMedium?.copyWith(
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
