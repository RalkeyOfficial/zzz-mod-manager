import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/palette.dart';
import '../../l10n/app_localizations.dart';
import '../../models/character_info.dart';
import '../../models/origin_enums.dart';
import '../../services/origin_status.dart';
import '../../services/update_check.dart';
import '../../utils/state_providers.dart';
import 'zenith_controls.dart';

/// The library card's **status badge** — one badge, one state, never a stack. The card's Active badge beside it is
/// the switch's state shown on the cover, not a second status.
///
/// The decision of *which* state lives in `services/origin_status.dart`; this widget only dresses it, so the "needs
/// attention" filter and this badge are one rule instead of two that drift.
///
/// - **Amber is an update**, the only state carrying something the app went and fetched. "Newer file" when the
///   check confirmed it, "Maybe newer" when it rests on a guess — keyed on the outcome, never on `isGuess`, which
///   overclaims for a mod whose author published a newer file under a different label.
/// - **Blue asks for something**: identity known and the file not, or a patch whose base mod nobody has named. One
///   pass through the resolve dialog settles either for good.
/// - **Grey states a fact**: a version on record by date only ("Dated only"), a file worked out rather than confirmed
///   ("Guessed file"), a mod not tracked at all, and "Local" for one the user marked as their own.
///   Most of an older library is untracked, and a loud mark on every card would teach the user to stop seeing it.
///
/// Every state but Local opens a dialog: the update dialog for amber, the resolve dialog for the rest.
///
/// A `ConsumerWidget` reading a `select` on the results map, so a check landing for one mod rebuilds one badge.
class ModStatusSlot extends ConsumerWidget {
  const ModStatusSlot({super.key, required this.mod, required this.onTap, this.onShowUpdate});

  final ModInfo mod;

  /// Opens the resolve dialog, what every origin state is asking for.
  final VoidCallback onTap;

  /// Opens the update dialog, used only by the amber state. Falls back to [onTap].
  final VoidCallback? onShowUpdate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final update = ref.watch(modUpdateChecksProvider.select((checks) => checks[mod.id]));
    final palette = ZenithPalette.of(context);
    final loc = context.loc;

    if (mod.origin?.tracking == OriginTracking.off) {
      return ZenithBadge(
        label: loc.t('library.card.local'),
        tone: palette.badgeNeutral,
        tooltip: loc.t('library.card.local_tooltip'),
      );
    }

    final status = modSlotStatus(mod.origin, update);
    if (status == ModOriginStatus.none) return const SizedBox.shrink();

    final confirmed = update?.outcome == UpdateOutcome.updateAvailable;
    final (label, tone, tooltip) = switch (status) {
      ModOriginStatus.updateAvailable => (
        confirmed ? 'library.card.newer_file' : 'library.card.maybe_newer',
        palette.badgeUpdate,
        confirmed ? 'mods.origin.update_available_tooltip' : 'mods.origin.possibly_outdated_tooltip',
      ),
      ModOriginStatus.versionUnknown => (
        'library.card.file_unknown',
        palette.badgeInfo,
        'mods.origin.version_unknown_tooltip',
      ),
      // Not folded into the state above: a patch downloaded here knows its file exactly, and what is unknown is the
      // other mod in the folder.
      ModOriginStatus.secondIdentityUnknown => (
        'library.card.base_unknown',
        palette.badgeInfo,
        'mods.origin.second_identity_tooltip',
      ),
      // Two ways to a version on record that is not confirmed, said apart: "mark all as current" records a date
      // and no file, while a worked-out file is a file.
      ModOriginStatus.versionGuessed when _datedOnly(mod) => (
        'library.card.dated',
        palette.badgeNeutral,
        'mods.origin.version_guessed_tooltip',
      ),
      ModOriginStatus.versionGuessed => (
        'library.card.guessed',
        palette.badgeNeutral,
        'library.card.guessed_tooltip',
      ),
      ModOriginStatus.untracked || ModOriginStatus.none => (
        'library.card.not_tracked',
        palette.badgeNeutral,
        'mods.origin.untracked_tooltip',
      ),
    };

    return ZenithBadge(
      label: loc.t(label),
      tone: tone,
      tooltip: loc.t(tooltip),
      onTap: status == ModOriginStatus.updateAvailable ? (onShowUpdate ?? onTap) : onTap,
    );
  }

  /// Whether the version on record is a date with no file. Read off the base download, the one `versionGuessed`
  /// is decided from; a patch layer's confidence is not what the badge describes.
  static bool _datedOnly(ModInfo mod) =>
      mod.origin?.base?.versionConfidence == OriginConfidence.assumedLatest;
}
