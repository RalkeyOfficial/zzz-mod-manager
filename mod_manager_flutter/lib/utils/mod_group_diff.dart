import '../models/character_info.dart';

/// Whether a fresh scan differs from what the mods screen is already showing.
///
/// A scan runs after every toggle, rename, edit and import, and most of them
/// change one mod or nothing at all — so `ModsScreen` only pushes a new list
/// into `charactersProvider` when this says yes, to keep the whole grid from
/// rebuilding on every trivial action.
///
/// **The failure mode is silence, and it has already happened once.** This is a
/// hand-written field list standing in for value equality `ModInfo` doesn't
/// have. When `ModInfo` gained its `origin` field, this list wasn't extended —
/// so resolving a mod through the resolve dialog wrote the sidecar correctly,
/// the rescan re-read it correctly, this returned `false`, and the card went on
/// showing the amber "needs attention" mark until the user switched tabs (which
/// disposes the screen and forces a rebuild from scratch). Nothing failed
/// loudly; the feature just looked broken.
///
/// So: **anything `ModInfo` gains that any surface renders must be added here.**
/// It lives in `utils/` rather than as a private method on the screen's `State`
/// precisely so that rule can be pinned by a test instead of remembered.
///
/// Two deliberate omissions:
///
/// - **`keybinds`.** They are enriched from `.ini` files on every scan and
///   `KeybindInfo` has no value equality, so comparing them would report a
///   change every single time and turn this guard off entirely. Keybind edits
///   refresh through their own dialog's callback instead.
/// - **Group *ordering*.** Groups are compared pairwise by index, matching how
///   `_buildGroups` builds them deterministically. A reordering with identical
///   contents would be missed, which cannot happen while the builder is stable.
bool modGroupsChanged(
  List<CharacterInfo>? previous,
  List<CharacterInfo> next,
) {
  if (previous == null) return true;
  if (previous.length != next.length) return true;

  for (var i = 0; i < next.length; i++) {
    final oldGroup = previous[i];
    final newGroup = next[i];

    if (oldGroup.id != newGroup.id ||
        oldGroup.name != newGroup.name ||
        oldGroup.skins.length != newGroup.skins.length) {
      return true;
    }

    for (var j = 0; j < newGroup.skins.length; j++) {
      if (modChanged(oldGroup.skins[j], newGroup.skins[j])) return true;
    }
  }

  return false;
}

/// Whether one mod differs in anything the UI draws.
///
/// Split out so the field list is readable and directly testable. `origin` is
/// compared as a whole through [ModOrigin]'s value equality rather than field by
/// field, so a new origin field is covered the day it is added — the rest of
/// this list has no such protection.
bool modChanged(ModInfo before, ModInfo after) =>
    before.id != after.id ||
    before.isActive != after.isActive ||
    before.name != after.name ||
    before.isFavorite != after.isFavorite ||
    before.characterId != after.characterId ||
    before.sourceUrl != after.sourceUrl ||
    before.description != after.description ||
    before.imagePath != after.imagePath ||
    before.origin != after.origin ||
    !_sameStrings(before.tags, after.tags) ||
    !_sameStrings(before.images, after.images);

bool _sameStrings(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
