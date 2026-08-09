/// Which of a mod's keys the update actually changed.
///
/// The surviving half of a rejected feature. Re-*applying* a user's `.ini` edits
/// across an update was considered and dropped — there is no pristine baseline
/// to diff the author's changes against, and a wrong guess writes a broken
/// `.ini` into the folder. What is defensible is telling the user what moved.
///
/// **A diff, not a list.** The first version showed every keybind the mod had
/// before the update, which is unreadable: a list of `[KeySkin] — F7` with no
/// context asks the reader to remember what it used to be and compare by hand.
/// It also cannot be empty, so it appeared after every update whether anything
/// changed or not, which trains people to ignore it. Reporting only what
/// *differs* makes the section self-explanatory and makes it disappear in the
/// common case where the author changed nothing.
///
/// Pure: the caller parses both sides with the existing `IniParserService`.
library;

import '../../models/keybind_info.dart';

/// What happened to one keybind across an update.
enum KeybindChangeKind {
  /// The section still exists and its key is different.
  rebound,

  /// The section is gone from the new version entirely.
  removed,
}

/// One keybind that is not what it was.
class KeybindChange {
  const KeybindChange({
    required this.section,
    required this.displayName,
    required this.before,
    this.after,
    required this.kind,
  });

  /// The raw `.ini` section name, e.g. `KeySkin`.
  final String section;

  /// The friendly form the keybinds view already uses, e.g. `Skin`.
  final String displayName;

  /// The key as the user had it, formatted for display.
  final String before;

  /// The key the new version ships, or null when the section is gone.
  final String? after;

  final KeybindChangeKind kind;

  @override
  bool operator ==(Object other) =>
      other is KeybindChange &&
      other.section == section &&
      other.before == before &&
      other.after == after &&
      other.kind == kind;

  @override
  int get hashCode => Object.hash(section, before, after, kind);

  @override
  String toString() => '$section: $before → ${after ?? '(gone)'}';
}

/// Compares the keybinds a mod had before an update with the ones it has now.
///
/// Matched by **section name**, case-insensitively, because that is the only
/// stable identifier an `.ini` gives a keybind — the key itself is exactly what
/// changed, and position in the file means nothing.
///
/// Only losses are reported. A section the new version *added* is not a change
/// to anything the user had, and listing it would put "here is a new feature"
/// in a section headed "what you lost".
List<KeybindChange> keybindChanges({
  required List<KeybindInfo> before,
  required List<KeybindInfo> after,
}) {
  final now = <String, KeybindInfo>{
    for (final bind in after) bind.section.toLowerCase(): bind,
  };

  final changes = <KeybindChange>[];
  for (final bind in before) {
    final was = bind.displayKeyValue;
    // A section binding nothing had nothing to lose.
    if (was == null || was.trim().isEmpty) continue;

    final match = now[bind.section.toLowerCase()];
    if (match == null) {
      changes.add(
        KeybindChange(
          section: bind.section,
          displayName: bind.displayName,
          before: was,
          kind: KeybindChangeKind.removed,
        ),
      );
      continue;
    }

    final becomes = match.displayKeyValue;
    if (becomes == null || becomes.trim().isEmpty) {
      changes.add(
        KeybindChange(
          section: bind.section,
          displayName: bind.displayName,
          before: was,
          kind: KeybindChangeKind.removed,
        ),
      );
      continue;
    }
    // Compared on the *display* form, so `VK_F7` and `F7` are not reported as a
    // change the user could act on — they are the same key written two ways.
    if (_key(becomes) == _key(was)) continue;

    changes.add(
      KeybindChange(
        section: bind.section,
        displayName: bind.displayName,
        before: was,
        after: becomes,
        kind: KeybindChangeKind.rebound,
      ),
    );
  }

  changes.sort((a, b) => a.displayName.toLowerCase().compareTo(
        b.displayName.toLowerCase(),
      ));
  return changes;
}

/// Modifier order is not meaningful (`ctrl F7` and `F7 ctrl` are one binding),
/// so compare as a normalised set of tokens rather than as a string.
String _key(String value) {
  final tokens = value.toLowerCase().split(RegExp(r'\s+'))
    ..removeWhere((t) => t.isEmpty)
    ..sort();
  return tokens.join(' ');
}
