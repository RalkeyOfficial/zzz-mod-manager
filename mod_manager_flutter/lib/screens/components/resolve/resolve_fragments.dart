import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../services/origin_summary.dart';
import '../mod_status_slot.dart';

/// The small shared pieces the resolve surfaces are built from.
///
/// They live here rather than on one dialog because **two screens now ask the
/// same questions** — the folder's own identity, and the other download inside
/// it. A chip that means "on record" on one and something subtly different on
/// the other is the drift this exists to prevent.

/// A caveat, or — with [colour] overridden — an answer.
///
/// Amber by default because almost every use is a caveat. The one exception is
/// a banked-hash match, which is the answer rather than a warning about it.
Widget resolveNotice(
  BuildContext context,
  String message,
  IconData icon, {
  Color? colour,
}) {
  final scheme = Theme.of(context).colorScheme;
  return Container(
    margin: const EdgeInsets.symmetric(vertical: 4),
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    decoration: BoxDecoration(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(
      children: [
        Icon(icon, size: 15, color: colour ?? ModStatusSlot.amber),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            message,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ),
      ],
    ),
  );
}

/// A short label on a file row. [background] fills it rather than tinting it,
/// which is what separates "this is the answer already on file" from "this is
/// our best guess" at a glance.
Widget resolveChip(String label, Color color, {Color? background}) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: background ?? color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );

/// What is on record about **which file**, in one line.
///
/// Shared rather than restated at each call site: the resolve dialog says this
/// about a folder's own download and the install prompt says it about the other
/// one, and two phrasings for "the file you chose" would be two claims.
///
/// The recorded version string leads when there is one — it is the fact the
/// reader came for — with how we know it after.
String describeRecordedFile(AppLocalizations loc, OriginSummary summary) {
  final how = switch (summary.version) {
    VersionSummary.downloaded => loc.t('mods.resolve.tracked_file_downloaded'),
    // A matching key, never an integrity claim — the same phrasing the file
    // list and the duplicate-archive prompt use, deliberately.
    VersionSummary.checksumMatched => loc.t('mods.resolve.tracked_file_hash'),
    VersionSummary.chosen => loc.t('mods.resolve.tracked_file_chosen'),
    VersionSummary.guessed => loc.t('mods.resolve.tracked_file_guessed'),
    VersionSummary.dateOnly => loc.t(
        'mods.resolve.tracked_file_date_only',
        // Straight from the block, not recomputed: a stored baseline is clamped
        // to the mod's creation date, so a value derived here could quote a
        // cutoff that is not the one in force.
        params: {
          'date':
              summary.baseline == null ? '?' : formatResolveDate(summary.baseline!),
        },
      ),
    VersionSummary.none => loc.t('mods.resolve.tracked_file_none'),
  };
  return summary.versionLabel == null
      ? how
      : '${summary.versionLabel} — $how';
}

String formatResolveDate(DateTime date) {
  final d = date.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)}';
}
