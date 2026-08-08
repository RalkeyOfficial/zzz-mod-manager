import '../models/character_info.dart';
import '../models/mod_origin.dart';
import '../models/origin_enums.dart';

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
}

/// The status to render for [origin].
///
/// The order of these checks is the whole design:
///
/// - **`tracking: off` wins over everything.** It is the user saying "not from
///   GameBanana / it's my own", and the promise attached to it is that the slot
///   goes quiet permanently. A stale `source_url` still sitting in the sidecar
///   must not talk them out of it.
/// - **`remote_missing` is treated the same way**, for a different reason: the
///   amber state's whole offer is "click to set the version", and that means
///   reading a mod page that is private, trashed or withheld. Offering an
///   action that cannot complete is worse than staying quiet. Nothing writes
///   this flag yet — §7.6's bulk pass is what sets it — and when it does, the
///   honest thing is its *own* wording ("source no longer available") rather
///   than borrowing one of the three states here.
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
  if (origin.remoteMissing) return ModOriginStatus.none;
  if (!origin.hasIdentity) return ModOriginStatus.untracked;
  return switch (origin.versionConfidence) {
    OriginConfidence.unknown => ModOriginStatus.versionUnknown,
    // A recorded guess. `inferred` is included even though nothing writes it
    // yet — the bulk resolution pass will, and a guess that renders as
    // fully-known is precisely the gap this state exists to close.
    OriginConfidence.assumedLatest ||
    OriginConfidence.inferred =>
      ModOriginStatus.versionGuessed,
    OriginConfidence.user || OriginConfidence.exact => ModOriginStatus.none,
  };
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
bool modNeedsAttention(ModOrigin? origin) => switch (modOriginStatus(origin)) {
      ModOriginStatus.untracked || ModOriginStatus.versionUnknown => true,
      ModOriginStatus.versionGuessed || ModOriginStatus.none => false,
    };

/// [modNeedsAttention] over a scanned mod. Convenience only — the decision is
/// entirely the origin block's.
bool modInfoNeedsAttention(ModInfo mod) => modNeedsAttention(mod.origin);
