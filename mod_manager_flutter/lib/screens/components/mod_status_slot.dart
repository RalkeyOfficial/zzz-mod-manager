import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../models/character_info.dart';
import '../../services/origin_status.dart';
import '../../services/update_check.dart';
import '../../utils/state_providers.dart';

/// The library card's origin **status slot** — one slot, one state, never a
/// stack.
///
/// The decision of *which* state lives in `services/origin_status.dart`; this
/// widget only dresses it. Keeping them apart is what lets the "needs attention"
/// filter and this badge be one rule instead of two that drift.
///
/// Why the two visible states look as different as they do:
///
/// - **Untracked is a muted dot and nothing else.** Most of a library that
///   predates the origin block is untracked, and a loud badge on every card
///   would train the user to stop seeing the slot — after which the state that
///   *is* actionable can never be noticed either. It is informational, so it
///   whispers.
/// - **Amber is the one that asks for something.** Identity is known and the
///   version is not, which means we can query this mod's file list but cannot
///   judge what comes back, and one pass through the resolve dialog fixes it
///   permanently.
/// - **A recorded guess is a muted clock**, in the same translucent treatment as
///   the dot rather than in amber. Nothing is wrong with a mod tracked by date —
///   settling for one is a legitimate answer and the bulk action makes it the
///   answer for a whole library at once. What the state buys is being able to
///   tell, across a grid, which mods you actually resolved and which you waved
///   through; before it, both rendered nothing.
///
/// - **An available update is blue, and it is the loudest thing here.** It is
///   the only state carrying information the app went and *fetched*, and the
///   only one whose action is "get the new version" rather than "tell us what
///   you have". It differs from amber by **hue at similar weight** rather than
///   by being louder still — the card has no room above amber, and two filled
///   pills that differ only in intensity read as one state rendered twice.
///
/// - **A source that is gone is a broken link, and it is quiet too.** The mod
///   page is private, trashed or withheld, which is not the user's fault and
///   not something they can fix from here — so it states the fact rather than
///   asking for anything. It is the one state that cannot be cleared by doing
///   work, which is also why the "needs attention" filter leaves it out.
///
/// The three quiet states are told apart by **shape, not colour** — a dot, a
/// clock face, a broken link. Three muted colours at 9–15px would be
/// indistinguishable, and would stay indistinguishable for anyone colourblind.
///
/// All of them are tappable and all of them open the same dialog: none is an
/// error, but each is a case a user *may* want to change, and giving them no
/// affordance would leave the context menu as the only way in.
///
/// The slot sits **bottom-left of the cover**, the one corner the card had free —
/// top-left is the details button, top-right the enable switch, bottom-right the
/// source link and favourite. It keeps a constant size across states so the
/// artwork underneath doesn't reflow when a mod is resolved.
///
/// A `ConsumerWidget` rather than taking the verdict as a parameter: the update
/// state is session-scoped and read from one place, and threading it down
/// through both card render paths and the drag-feedback copy would put the same
/// lookup in three call sites that must not drift. It reads a `select` on the
/// results map, so a check landing for one mod rebuilds one slot.
class ModStatusSlot extends ConsumerWidget {
  const ModStatusSlot({
    super.key,
    required this.mod,
    required this.onTap,
    this.onShowUpdate,
  });

  final ModInfo mod;

  /// Opens the resolve dialog — what every *origin* state is asking for.
  final VoidCallback onTap;

  /// Opens the update dialog, used only by the blue state.
  ///
  /// The slot dispatches rather than the caller, because the caller would have
  /// to re-derive which state is showing to know which dialog to open — the one
  /// decision this widget exists to make. Falls back to [onTap] when absent, so
  /// a badge is never inert.
  final VoidCallback? onShowUpdate;

  /// The colour of the actionable state.
  ///
  /// A literal rather than `colorScheme.tertiary` and friends: the library card
  /// draws its own palette (the accent, the active green, the favourite yellow)
  /// over artwork rather than over a themed surface, so a scheme colour would be
  /// the only thing on the card that changes with the theme — and amber has to
  /// stay amber to keep meaning "attention" beside that green.
  static const Color amber = Color(0xFFF59E0B);

  /// The colour of "an update is published". Same family and same weight as
  /// [amber], a different hue — and not the card's own accent, which is already
  /// spoken for by the toolbar's active states.
  static const Color updateBlue = Color(0xFF3B82F6);

  /// Matches the card's other round overlay buttons (an 18px icon in 6px of
  /// padding), so the four corners read as one family.
  static const double _diameter = 30;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final update = ref.watch(
      modUpdateChecksProvider.select((checks) => checks[mod.id]),
    );
    final status = modSlotStatus(mod.origin, update);
    if (status == ModOriginStatus.none) return const SizedBox.shrink();

    final loc = context.loc;
    final muted = Colors.white.withValues(alpha: 0.55);
    final fill = switch (status) {
      ModOriginStatus.updateAvailable => updateBlue.withValues(alpha: 0.92),
      // The unnamed second identity shares amber's pixels exactly. It is the
      // same ask — "tell us what this is, and one dialog fixes it permanently"
      // — and the card has no room for a sixth treatment.
      ModOriginStatus.versionUnknown ||
      ModOriginStatus.secondIdentityUnknown =>
        amber.withValues(alpha: 0.9),
      _ => Colors.black.withValues(alpha: 0.35),
    };

    return Tooltip(
      message: loc.t(switch (status) {
        // The guess and the confirmed finding share the slot but not the
        // sentence, and the badge is the only place that distinction can be
        // read without opening anything.
        //
        // **Keyed on the outcome, not on `isGuess`.** They are not the same
        // condition and conflating them overclaims: a mod recorded at
        // `exact`/`exact` whose author published a newer file under a
        // *different label* is `possiblyOutdated` with `isGuess == false`, and
        // read off `isGuess` the card asserted "an update is published" while
        // the dialog for the same mod said "possibly outdated". The outcome is
        // what the wording is about.
        ModOriginStatus.updateAvailable =>
          update?.outcome == UpdateOutcome.updateAvailable
              ? 'mods.origin.update_available_tooltip'
              : 'mods.origin.possibly_outdated_tooltip',
        ModOriginStatus.versionUnknown => 'mods.origin.version_unknown_tooltip',
        // The same pill, a different sentence — and the sentence is the whole
        // reason this is its own state. "We don't know which file you have" is
        // false for a patch we downloaded and recorded exactly; what is
        // unknown is the other mod in the folder.
        ModOriginStatus.secondIdentityUnknown =>
          'mods.origin.second_identity_tooltip',
        ModOriginStatus.versionGuessed => 'mods.origin.version_guessed_tooltip',
        ModOriginStatus.sourceGone => 'mods.origin.source_gone_tooltip',
        ModOriginStatus.untracked ||
        ModOriginStatus.none =>
          'mods.origin.untracked_tooltip',
      }),
      child: Material(
        color: fill,
        shape: const CircleBorder(),
        child: InkWell(
          onTap: status == ModOriginStatus.updateAvailable
              ? (onShowUpdate ?? onTap)
              : onTap,
          customBorder: const CircleBorder(),
          // One footprint for every state, so resolving a mod doesn't reflow the
          // artwork under it. Only what sits inside changes.
          child: SizedBox.square(
            dimension: _diameter,
            child: Center(
              child: switch (status) {
                ModOriginStatus.updateAvailable => const Icon(
                    Icons.arrow_circle_up,
                    size: 18,
                    color: Colors.white,
                  ),
                ModOriginStatus.versionUnknown ||
                ModOriginStatus.secondIdentityUnknown =>
                  const Icon(
                    Icons.priority_high,
                    size: 18,
                    color: Colors.white,
                  ),
                // Larger than the dot because an outlined glyph needs the room
                // to stay legible, but the same muted white so the two read as
                // one family rather than as two levels of severity.
                ModOriginStatus.versionGuessed => Icon(
                    Icons.schedule,
                    size: 15,
                    color: muted,
                  ),
                ModOriginStatus.sourceGone => Icon(
                    Icons.link_off,
                    size: 15,
                    color: muted,
                  ),
                ModOriginStatus.untracked ||
                ModOriginStatus.none =>
                  Icon(Icons.circle, size: 9, color: muted),
              },
            ),
          ),
        ),
      ),
    );
  }
}
