import '../models/character_info.dart';

/// Whether a fresh scan differs from what the mods screen is already showing.
///
/// A scan runs after every toggle, rename, edit and import, and most of them
/// change one mod or nothing at all — so `ModsScreen` only pushes a new list
/// into `charactersProvider` when this says yes, to keep the whole grid from
/// rebuilding on every trivial action.
///
/// **The failure mode is silence.** A field this misses is a surface rendering
/// yesterday's data until the tab is switched, with nothing thrown. It happened
/// twice while this was a hand-written field list: `origin`, so a resolved mod
/// kept its amber mark, and `keybinds`, so an edited hotkey kept the old key.
/// Both are now covered by [ModInfo]'s own value equality, which is what this
/// compares — so a new field is covered by being a field.
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
/// Kept as a named function because that is what makes the rule above
/// greppable; the comparison itself is [ModInfo]'s own value equality.
bool modChanged(ModInfo before, ModInfo after) => before != after;
