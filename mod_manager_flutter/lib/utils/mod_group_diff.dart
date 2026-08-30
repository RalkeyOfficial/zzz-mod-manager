import '../models/character_info.dart';
import '../models/keybind_info.dart';

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
/// **It happened a second time, to `keybinds`.** They were omitted on the
/// grounds that they are re-parsed from `.ini` on every scan and `KeybindInfo`
/// had no value equality, so comparing them would report a change every time and
/// turn this guard off entirely — with the note that keybind edits "refresh
/// through their own dialog's callback instead". They did not: that callback is
/// `loadMods`, which runs this guard, so editing a hotkey wrote the `.ini`,
/// dropped the mod's keybind cache, re-parsed correctly, and then had the whole
/// result discarded here. `KeybindInfo` has value equality now and they are
/// compared like everything else.
///
/// One deliberate omission remains:
///
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
    !_sameStrings(before.images, after.images) ||
    !_sameKeybinds(before.keybinds, after.keybinds);

bool _sameStrings(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Nullable because a mod with no `.ini` bindings never gets the field set at
/// all, which is a different state from "parsed and found none" only in that it
/// costs nothing — both are stable across scans, which is what matters here.
bool _sameKeybinds(List<KeybindInfo>? a, List<KeybindInfo>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null || a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
