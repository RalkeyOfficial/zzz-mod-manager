import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../models/character_info.dart';
import '../../services/origin_status.dart';

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
/// The two quiet states are told apart by **shape, not colour** — a dot against
/// a clock face. Two muted colours at 9px would be indistinguishable, and would
/// stay indistinguishable for anyone colourblind.
///
/// All three are tappable and all three open the same dialog: none of them is an
/// error, but each is a case a user *may* want to change, and giving them no
/// affordance would leave the context menu as the only way in.
///
/// The slot sits **bottom-left of the cover**, the one corner the card had free —
/// top-left is the details button, top-right the enable switch, bottom-right the
/// source link and favourite. It keeps a constant size across states so the
/// artwork underneath doesn't reflow when a mod is resolved.
class ModStatusSlot extends StatelessWidget {
  const ModStatusSlot({
    super.key,
    required this.mod,
    required this.onTap,
  });

  final ModInfo mod;
  final VoidCallback onTap;

  /// The colour of the actionable state.
  ///
  /// A literal rather than `colorScheme.tertiary` and friends: the library card
  /// draws its own palette (the accent, the active green, the favourite yellow)
  /// over artwork rather than over a themed surface, so a scheme colour would be
  /// the only thing on the card that changes with the theme — and amber has to
  /// stay amber to keep meaning "attention" beside that green.
  static const Color amber = Color(0xFFF59E0B);

  /// Matches the card's other round overlay buttons (an 18px icon in 6px of
  /// padding), so the four corners read as one family.
  static const double _diameter = 30;

  @override
  Widget build(BuildContext context) {
    final status = modOriginStatus(mod.origin);
    if (status == ModOriginStatus.none) return const SizedBox.shrink();

    final loc = context.loc;
    final actionable = status == ModOriginStatus.versionUnknown;
    final muted = Colors.white.withValues(alpha: 0.55);

    return Tooltip(
      message: loc.t(switch (status) {
        ModOriginStatus.versionUnknown => 'mods.origin.version_unknown_tooltip',
        ModOriginStatus.versionGuessed => 'mods.origin.version_guessed_tooltip',
        ModOriginStatus.untracked ||
        ModOriginStatus.none =>
          'mods.origin.untracked_tooltip',
      }),
      child: Material(
        color: actionable
            ? amber.withValues(alpha: 0.9)
            : Colors.black.withValues(alpha: 0.35),
        shape: const CircleBorder(),
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          // One footprint for every state, so resolving a mod doesn't reflow the
          // artwork under it. Only what sits inside changes.
          child: SizedBox.square(
            dimension: _diameter,
            child: Center(
              child: switch (status) {
                ModOriginStatus.versionUnknown => const Icon(
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
