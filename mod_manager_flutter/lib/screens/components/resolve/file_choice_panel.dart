import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../models/gamebanana/gamebanana.dart';
import '../../../services/gamebanana/file_selection.dart';
import '../../../services/origin_resolution.dart';
import 'resolve_fragments.dart';

/// "Which file of it?" — the ranked candidate rows and what each chip claims.
///
/// **Stateless, because the selection is the caller's.** Save reads it, and a
/// panel that owned it would have to be asked back for it.
///
/// The rules it carries are about what a row is allowed to say:
///
/// - **Every suggestion says why.** A ranking with no visible reason is
///   indistinguishable from a ranking with a wrong one, and the user is the
///   only one who can tell them apart.
/// - **"On record" and "our best guess" are different claims**, so they carry
///   different chips — the filled one wins the glance.
/// - **A banked hash *settles* the question rather than hiding it.** The rows
///   stay so the user can see what it resolved to and disagree; what changes is
///   that they no longer have to decide.
class FileChoicePanel extends StatelessWidget {
  const FileChoicePanel({
    super.key,
    required this.resolution,
    required this.selectedFileId,
    required this.onSelected,
    this.recordedFileId,
    this.heading,
    this.maxHeight = 230,
  });

  final FileResolution resolution;

  /// The file the sidecar already names, marked **on record**. Null while the
  /// panel is pointed at a mod the block does not describe.
  final int? recordedFileId;

  final int? selectedFileId;

  /// The chosen file and whether that choice is `exact` — a banked-hash row, or
  /// the row already recorded at `exact`.
  final void Function(GbFile file, bool isExact) onSelected;

  final String? heading;

  /// Bounded and separately scrollable so whatever sits beneath stays one click
  /// away rather than sliding off the bottom. Not hypothetical: a captured
  /// profile publishes six current files beside eight archived ones, and every
  /// one of them is a row here.
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    if (resolution.isEmpty) {
      return resolveNotice(context, loc.t('mods.resolve.no_files'), Icons.block);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (heading case final text?) ...[
          Text(
            text,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
        ],
        if (resolution.isSettled)
          resolveNotice(
            context,
            loc.t('mods.resolve.settled'),
            Icons.check_circle_outline,
            // Not the amber every other notice uses: this one is the answer,
            // not a caveat. It is still only a *match*, though — md5 is a
            // matching key and never verification, so no borrowed checkmark.
            colour: Theme.of(context).colorScheme.primary,
          ),
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: ListView(
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            children: [
              for (final candidate in resolution.candidates)
                _row(context, candidate),
            ],
          ),
        ),
      ],
    );
  }

  Widget _row(BuildContext context, ResolveCandidate candidate) {
    final loc = context.loc;
    final scheme = Theme.of(context).colorScheme;
    final selected = selectedFileId == candidate.file.idRow;
    final reason = switch (candidate.reason) {
      FileMatchReason.archiveHash => loc.t('mods.resolve.reason_hash'),
      FileMatchReason.folderName => loc.t('mods.resolve.reason_folder'),
      FileMatchReason.installDate => loc.t('mods.resolve.reason_date'),
      FileMatchReason.onlyFile => loc.t('mods.resolve.reason_only'),
      FileMatchReason.none => null,
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => onSelected(candidate.file, candidate.isExact),
        child: Container(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected
                  ? scheme.primary.withValues(alpha: 0.7)
                  : scheme.outlineVariant.withValues(alpha: 0.4),
            ),
            color: selected ? scheme.primary.withValues(alpha: 0.06) : null,
          ),
          child: Row(
            children: [
              Icon(
                selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                size: 18,
                color: selected ? scheme.primary : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // A Wrap, not a Row: the chips are three-word labels with
                    // nothing to ellipsise, so in a Row the filename is the
                    // only thing that can give way and the row overflows once
                    // it has.
                    Wrap(
                      spacing: 6,
                      runSpacing: 2,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          fileDisplayName(candidate.file),
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        if (candidate.file.isArchived)
                          resolveChip(loc.t('marketplace.badge_archived'),
                              scheme.onSurfaceVariant),
                        if (recordedFileId == candidate.file.idRow)
                          resolveChip(
                            loc.t('mods.resolve.on_record'),
                            scheme.onPrimary,
                            background: scheme.primary,
                          ),
                        if (reason != null) resolveChip(reason, scheme.primary),
                      ],
                    ),
                    // The author's label sits *under* the filename rather than
                    // replacing it. It is free text and often a sentence, so
                    // leading with it hid which file the row actually is.
                    if (fileDisplayDetail(candidate.file) case final detail?)
                      Text(
                        detail,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    if (candidate.file.dateAdded case final date?)
                      Text(
                        formatResolveDate(date),
                        style: TextStyle(
                          fontSize: 11,
                          color: scheme.onSurfaceVariant,
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
}
