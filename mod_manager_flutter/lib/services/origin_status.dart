import '../models/character_info.dart';
import '../models/mod_origin.dart';
import '../models/origin_enums.dart';
import 'update_check.dart';

/// What a library mod's card says about its origin — **one slot, one state.**
///
/// Pure: a fold of the sidecar's origin block into the single thing the card is
/// allowed to render. No I/O, no widgets, no theme; the colours and the wording
/// live in the widget, the *decision* lives here so it can be tested and so the
/// "needs attention" filter and the badge can never disagree about which mods
/// are which.
///
/// The one-slot rule is the point. A card that can stack three badges shows
/// none of them, and badging every unversioned mod ambers an entire legacy
/// library — which trains the user to ignore the slot altogether. So the states
/// are ordered by how *actionable* they are and the first match wins.
enum ModOriginStatus {
  /// Nothing to show. Either the origin is as known as it needs to be, or the
  /// user has opted this mod out.
  none,

  /// No remote identity at all: a hand-copied folder, a legacy import, a mod
  /// from a site we don't browse. **Informational, never alarming** — most of a
  /// library that predates the origin block looks like this.
  untracked,

  /// Identity known and a version *recorded*, but only as a guess — the user
  /// answered "I don't know which file, I got it around then", or a future bulk
  /// pass inferred one.
  ///
  /// **Informational, like [untracked], and deliberately not amber.** Nothing is
  /// wrong here and nothing is owed: settling for a date is a legitimate answer,
  /// and the bulk action exists to make it the answer for a whole library at
  /// once. What the user loses without this state is the ability to tell a mod
  /// they *resolved* from one they *waved through*, since both otherwise render
  /// nothing at all.
  versionGuessed,

  /// Identity known, installed version unknown. The actionable one: we *can*
  /// query this mod's file list, we just can't judge what came back, and one
  /// pass through the resolve dialog fixes it.
  versionUnknown,

  /// The folder is recorded as holding a **patch** and nobody has said what it
  /// patches, so the app can only ask about one of the two mods in it.
  ///
  /// **A new state, deliberately not a new visual.** It renders as the same
  /// amber pill and the same glyph as [versionUnknown] and differs only in its
  /// tooltip — the pattern the slot already uses for `updateAvailable` versus
  /// `possiblyOutdated`. Folding it into [versionUnknown] outright would make
  /// the card say "we don't know which file you have", which is false for a
  /// patch we downloaded and recorded at `exact`; the unknown is the *other*
  /// mod.
  ///
  /// Like [versionUnknown] and unlike [sourceGone], it can be cleared by doing
  /// work — naming the base mod — which is what earns it a place in the "needs
  /// attention" filter.
  secondIdentityUnknown,

  /// The mod page this folder is bound to is private, trashed or withheld, and
  /// the bulk resolution pass recorded that.
  ///
  /// **Its own state rather than silence**, which is the correction the flag's
  /// first writer forced. While nothing wrote `remote_missing` the slot could
  /// treat it like `tracking: "off"` and render nothing; the moment something
  /// does, that becomes a mod which silently stopped being watched with no
  /// wording anywhere explaining why. It is deliberately *not* amber: the amber
  /// state's whole offer is "click to set the version", and there is no page
  /// left to read one off. It is a statement of fact, like [untracked].
  sourceGone,

  /// The last update check found something newer published.
  ///
  /// **Never returned by [modOriginStatus]** — it is not a property of the
  /// origin block at all, but of a check somebody ran against a mod page. It
  /// lives in this enum rather than in one of its own because the card has
  /// exactly *one* slot, and precedence between "you have not sorted this mod
  /// out" and "this mod has an update" has to be a single decision in a single
  /// place. [modSlotStatus] is that place.
  updateAvailable,
}

/// The status to render for [origin].
///
/// The order of these checks is the whole design:
///
/// - **`tracking: off` wins over everything.** It is the user saying "not from
///   GameBanana / it's my own", and the promise attached to it is that the slot
///   goes quiet permanently. A stale `source_url` still sitting in the sidecar
///   must not talk them out of it.
/// - **`remote_missing` gets its own state**, and does not borrow amber's. The
///   amber state's whole offer is "click to set the version", and that means
///   reading a mod page that is private, trashed or withheld — offering an
///   action that cannot complete is worse than saying what happened. It used to
///   fold to [ModOriginStatus.none], which was correct only while nothing wrote
///   the flag; the bulk resolution pass writes it now, and a mod that quietly
///   stops being watched with no wording anywhere is the silent hole that
///   arrangement would have opened.
/// - **Identity before version.** Without a mod id there is nothing to check a
///   version against, so "untracked" is the truthful answer even though the
///   version is also unknown. Reporting the version instead would promise an
///   update check we cannot run.
/// - **Only `unknown` is actionable.** `assumed_latest` is the user having
///   already answered "I don't know which, I got it around then", and
///   `inferred` is a guess we recorded and label as one. Both are resolved
///   states; re-ambering them would mean the dialog can never be finished.
///   They are not *silent*, though — see [ModOriginStatus.versionGuessed]. A
///   resolved guess and a known file used to render identically, which left the
///   user unable to tell which of their mods they had actually sorted out. The
///   fix is a quieter state, not a louder one.
ModOriginStatus modOriginStatus(ModOrigin? origin) {
  if (origin == null) return ModOriginStatus.untracked;
  if (origin.tracking == OriginTracking.off) return ModOriginStatus.none;
  if (origin.remoteMissing) return ModOriginStatus.sourceGone;
  if (!origin.hasIdentity) return ModOriginStatus.untracked;
  // Above the version switch: "which file of the patch is installed" is an
  // ambiguous question while the folder is known to be two things and only one
  // of them is named. The ordering is low-stakes — one pass through the resolve
  // dialog answers both — but it is decided here rather than left to chance.
  if (origin.needsCompanion) return ModOriginStatus.secondIdentityUnknown;
  // **A folder is only as resolved as its least-resolved identity.** Naming the
  // other mod clears `needsCompanion`, and without this the slot then reads the
  // *primary's* version confidence alone — `exact` for a patch we downloaded —
  // so a folder whose second half we cannot judge rendered nothing at all. Not
  // amber, and not blue either: the check answers `versionUnknown` for that
  // half rather than finding an update, so there was no verdict to show and no
  // mark to explain it.
  for (final companion in origin.companions) {
    if (companion.versionConfidence == OriginConfidence.unknown) {
      return ModOriginStatus.versionUnknown;
    }
  }
  return switch (origin.versionConfidence) {
    OriginConfidence.unknown => ModOriginStatus.versionUnknown,
    // A recorded guess. `inferred` is included even though nothing writes it
    // yet — the bulk resolution pass will, and a guess that renders as
    // fully-known is precisely the gap this state exists to close.
    OriginConfidence.assumedLatest ||
    OriginConfidence.inferred =>
      ModOriginStatus.versionGuessed,
    OriginConfidence.user || OriginConfidence.exact => ModOriginStatus.none,
    // Not reachable: `updateAvailable` and `sourceGone` are not version
    // confidences. The card's fold is [modSlotStatus].
  };
}

/// The **one** state a library card's slot renders, folding the origin block
/// together with whatever the last update check said about this mod.
///
/// Precedence, and the reasons rather than the order:
///
/// - **The origin block still wins first for the two "don't ask" states.**
///   `tracking: "off"` renders nothing and `remote_missing` renders its own
///   quiet mark, and an update verdict must not talk over either. In practice a
///   check on such a mod cannot produce one — `checkForUpdate` short-circuits on
///   `tracking: "off"` and answers `sourceGone` for a missing page — so this is
///   belt and braces rather than a live branch.
/// - **An update beats every origin state.** The two overlap in exactly the
///   cases worth thinking about: a mod tracked by date only can be flagged as
///   *possibly* outdated, and a mod whose version was never recorded can still
///   be identified by a banked archive hash. In both, "something newer is
///   published" is the newer, more actionable fact, and the origin state it
///   replaces is still one click away in the same dialog.
/// - **[UpdateCheck.isGuess] does not get its own state.** It changes the
///   *wording*, not the slot: a card has one mark and splitting it into
///   "definitely" and "probably" would spend the library's whole visual budget
///   on a distinction the tooltip can make in a sentence.
ModOriginStatus modSlotStatus(ModOrigin? origin, UpdateCheck? update) {
  // Narrowly the two silencing flags, **not** every route to
  // [ModOriginStatus.none]: a mod whose file is recorded at `user` or `exact`
  // also folds to `none`, and that is precisely the mod best placed to have a
  // confirmed update. Short-circuiting on the state rather than on its cause
  // would hide the strongest verdict this feature can produce.
  if (origin != null &&
      (origin.tracking == OriginTracking.off || origin.remoteMissing)) {
    return modOriginStatus(origin);
  }
  if (update?.hasUpdate ?? false) return ModOriginStatus.updateAvailable;
  return modOriginStatus(origin);
}

/// Whether the "needs attention" filter should keep this mod.
///
/// **`untracked` and `versionUnknown`, and deliberately not
/// [ModOriginStatus.versionGuessed].** The badge and the filter answer
/// different questions: the badge asks "how loudly should this card speak",
/// where an untracked mod is deliberately quiet, while the filter asks "show me
/// what I have not dealt with". Untracked mods belong in it — the resolve
/// dialog acts on one perfectly well, seeded with the folder name, and
/// excluding them would leave a legacy library with an empty filter and no way
/// to enumerate the mods it exists to enumerate.
///
/// A recorded guess does **not** belong in it, and this is the one place the
/// two rules had to come apart rather than share a single "is the slot empty?"
/// test. The bulk "assume current" action turns amber mods into guessed ones,
/// and the count dropping is the entire visible proof that it worked. Were
/// guessed mods still counted, the number would sit unchanged while the marks
/// merely changed shape, which reads as a button that did nothing.
///
/// (What untracked mods get no access to is *bulk* resolution — that is a
/// separate rule, and it is about fuzzy name matching being unsafe to
/// rubber-stamp, not about which mods are listed here.)
/// [ModOriginStatus.updateAvailable] is out for a third reason again: it is not
/// a state of the origin block, so [modOriginStatus] never returns it here.
/// "Which mods have updates" is a different question with a different control,
/// and folding it into this filter would make the count change whenever a check
/// ran — a filter whose meaning depends on what the network last said.
/// [ModOriginStatus.sourceGone] is out for a fourth reason: the filter's promise
/// is that everything in it can be dealt with, and a private, trashed or
/// withheld mod page cannot. Counting it would leave a number that never reaches
/// zero however much work the user does — the one thing that turns a count into
/// noise. The mark on the card still says what happened, and the resolve dialog
/// still rebinds the folder for anyone whose mod was reuploaded elsewhere.
bool modNeedsAttention(ModOrigin? origin) => switch (modOriginStatus(origin)) {
      ModOriginStatus.untracked ||
      ModOriginStatus.versionUnknown ||
      // In, for the same reason `sourceGone` is out: the user can finish it,
      // and finishing it moves the count. Naming the base mod is the work.
      ModOriginStatus.secondIdentityUnknown =>
        true,
      ModOriginStatus.versionGuessed ||
      ModOriginStatus.sourceGone ||
      ModOriginStatus.updateAvailable ||
      ModOriginStatus.none =>
        false,
    };

/// [modNeedsAttention] over a scanned mod. Convenience only — the decision is
/// entirely the origin block's.
bool modInfoNeedsAttention(ModInfo mod) => modNeedsAttention(mod.origin);
