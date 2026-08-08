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
ModOriginStatus modOriginStatus(ModOrigin? origin) {
  if (origin == null) return ModOriginStatus.untracked;
  if (origin.tracking == OriginTracking.off) return ModOriginStatus.none;
  if (origin.remoteMissing) return ModOriginStatus.none;
  if (!origin.hasIdentity) return ModOriginStatus.untracked;
  if (origin.versionConfidence == OriginConfidence.unknown) {
    return ModOriginStatus.versionUnknown;
  }
  return ModOriginStatus.none;
}

/// Whether the "needs attention" filter should keep this mod.
///
/// **Both non-empty states count, not just the amber one.** The badge and the
/// filter answer different questions: the badge asks "how loudly should this
/// card speak", where an untracked mod is deliberately quiet, while the filter
/// asks "show me what I could act on" — and the resolve dialog acts on an
/// untracked mod perfectly well, seeded with the folder name. Excluding them
/// would leave a legacy library with an empty filter and no way to enumerate
/// the mods it exists to enumerate.
///
/// (What untracked mods get no access to is *bulk* resolution — that is a
/// separate rule, and it is about fuzzy name matching being unsafe to
/// rubber-stamp, not about which mods are listed here.)
bool modNeedsAttention(ModOrigin? origin) =>
    modOriginStatus(origin) != ModOriginStatus.none;

/// [modNeedsAttention] over a scanned mod. Convenience only — the decision is
/// entirely the origin block's.
bool modInfoNeedsAttention(ModInfo mod) => modNeedsAttention(mod.origin);
