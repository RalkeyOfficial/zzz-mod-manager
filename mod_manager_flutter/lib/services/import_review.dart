/// The decisions of the import review: what each mod about to be created is called and filed under, which of them
/// meet a mod the library already has, and whether the import may go ahead.
///
/// Pure, so every rule can be pinned with no dialog and no library on disk (`docs/importing-mods.md` §2 to §4).
library;

import '../models/character_info.dart';
import '../models/mod_origin.dart';

/// What the user does with a row whose name is a mod the library already has.
enum OnClash {
  /// Write the dropped files into the existing mod (`docs/importing-mods.md` §5).
  update,

  /// Install the dropped mod beside it, under the first free `Name (2)`.
  keepBoth,
}

/// Why a name cannot be used.
enum NameProblem {
  empty,

  /// The rename rules: no `\ / < > : " | ? *`, no leading `.` or `__`.
  invalid,

  /// Another row ends up in the same folder.
  twin,
}

/// A mod the library already has, as far as the review needs to know it.
class ExistingMod {
  const ExistingMod({
    required this.id,
    required this.characterId,
    this.installedAt,
    this.busy = false,
    this.flattensPatch = false,
  });

  /// Builds one from the library's mod. [busy] is whether its folder is being written right now.
  factory ExistingMod.of(ModInfo mod, {required bool busy}) => ExistingMod(
    id: mod.id,
    characterId: mod.characterId,
    installedAt: mod.origin?.installedAt,
    busy: busy,
    flattensPatch: _flattensPatch(mod.origin),
  );

  /// The mod's folder name.
  final String id;
  final String characterId;

  /// Null for a mod no record says when it came.
  final DateTime? installedAt;

  /// Its folder is being written, so it cannot be updated now.
  final bool busy;

  /// A patch is recorded on it and nothing records which files are the patch's, so an update cannot put it back.
  final bool flattensPatch;

  static bool _flattensPatch(ModOrigin? origin) =>
      origin != null && origin.patches.isNotEmpty && (origin.ingest?.patchFiles ?? const <String>[]).isEmpty;
}

/// One mod the import will create, as the user sees it and edits it.
class ImportItem {
  const ImportItem({
    required this.id,
    required this.sources,
    required this.label,
    required this.kind,
    required this.name,
    this.bytes,
    this.guessedCharacter,
    this.pickedCharacter,
    this.choice = OnClash.update,
  });

  /// A key that stays the same while the row is edited.
  final String id;

  /// The folders that make the mod: one, or several that are combined into it.
  final List<String> sources;

  /// The archive's file name, or the folder's name.
  final String label;
  final ImportSourceKind kind;
  final int? bytes;

  /// What the mod is called, as typed.
  final String name;

  /// What the app brings to the row: the character the user dropped on, else the guess from the names. Null is no
  /// answer, and the row asks.
  final String? guessedCharacter;

  /// What the user chose in the row, which beats everything else.
  final String? pickedCharacter;

  /// Used only while [name] is a mod the library has.
  final OnClash choice;

  /// [clearPick] forgets the user's character choice, which a change of [choice] does: the character an update keeps
  /// is the existing mod's, and the user has not yet said otherwise.
  ImportItem copyWith({String? name, String? pickedCharacter, OnClash? choice, bool clearPick = false}) => ImportItem(
    id: id,
    sources: sources,
    label: label,
    kind: kind,
    name: name ?? this.name,
    bytes: bytes,
    guessedCharacter: guessedCharacter,
    pickedCharacter: clearPick ? null : pickedCharacter ?? this.pickedCharacter,
    choice: choice ?? this.choice,
  );
}

enum ImportSourceKind { archive, folder, combined }

/// What the review concludes about one row.
class ImportRow {
  const ImportRow({
    required this.item,
    required this.finalName,
    required this.character,
    required this.choice,
    this.existing,
    this.problem,
  });

  final ImportItem item;

  /// The folder the mod will be in: the typed name, the existing mod's own spelling when it is updated, or the first
  /// free `Name (2)` when both are kept.
  final String finalName;

  /// Where it will be filed, or null while the row still needs an answer.
  final String? character;

  /// The answer in force: [OnClash.keepBoth] where the existing mod cannot be updated.
  final OnClash choice;

  /// The mod the name matches, in the library.
  final ExistingMod? existing;
  final NameProblem? problem;

  bool get clashes => existing != null;
  bool get updates => clashes && choice == OnClash.update;
  bool get needsCharacter => character == null;

  /// Update it is not offered because the existing mod's folder is being written.
  bool get updateBlocked => existing?.busy ?? false;
}

/// Why the primary button is off.
enum BlockedKind { character, name }

class Blocked {
  const Blocked(this.kind, this.name, this.more);

  final BlockedKind kind;

  /// The first row that stops the import.
  final String name;

  /// How many more rows stop it for the same reason.
  final int more;
}

/// The whole review, evaluated.
class ImportReview {
  const ImportReview(this.rows, this.blocked);

  final List<ImportRow> rows;
  final Blocked? blocked;

  bool get canImport => blocked == null && rows.isNotEmpty;
}

/// Whether [name] breaks the rename rules.
bool isInvalidModName(String name) =>
    RegExp(r'[\\/<>:"|?*]').hasMatch(name) || name.startsWith('.') || name.startsWith('__');

/// Evaluates [items] against [library].
///
/// **A clash is library-wide and ignores letter case**: the library is flat, so a folder of that name exists whatever
/// character it is filed under. Where the filesystem tells `Foo` and `foo` apart and the library has both, the exact
/// spelling is the match, and a name spelled a third way matches neither. The final names are settled in two passes,
/// so a row that keeps both takes the first `Name (n)` that no folder and no other row has.
ImportReview evaluateImport(List<ImportItem> items, Iterable<ExistingMod> library) {
  final exact = {for (final mod in library) mod.id: mod};
  final folded = <String, List<ExistingMod>>{};
  for (final mod in exact.values) {
    folded.putIfAbsent(mod.id.toLowerCase(), () => []).add(mod);
  }
  final taken = folded.keys.toSet();
  ExistingMod? matching(String name) {
    final same = folded[name.toLowerCase()];
    if (same == null) return null;
    return exact[name] ?? (same.length == 1 ? same.single : null);
  }

  final names = <String>[for (final item in items) item.name.trim()];

  final existing = <ExistingMod?>[];
  final choices = <OnClash>[];
  for (var i = 0; i < items.length; i++) {
    final mod = names[i].isEmpty ? null : matching(names[i]);
    existing.add(mod);
    choices.add(mod == null || mod.busy ? OnClash.keepBoth : items[i].choice);
  }

  // Pass one: everything that keeps its own name.
  final finals = List<String>.filled(items.length, '');
  final claimed = <String, int>{};
  for (var i = 0; i < items.length; i++) {
    final mod = existing[i];
    if (mod != null && choices[i] == OnClash.keepBoth) continue;
    finals[i] = mod?.id ?? names[i];
    if (finals[i].isNotEmpty) claimed.update(finals[i].toLowerCase(), (n) => n + 1, ifAbsent: () => 1);
  }
  // Pass two: the rows that keep both take a free name.
  for (var i = 0; i < items.length; i++) {
    if (existing[i] == null || choices[i] != OnClash.keepBoth) continue;
    var n = 2;
    while (taken.contains('${names[i]} ($n)'.toLowerCase()) || claimed.containsKey('${names[i]} ($n)'.toLowerCase())) {
      n++;
    }
    finals[i] = '${names[i]} ($n)';
    claimed['${names[i]} ($n)'.toLowerCase()] = 1;
  }

  final rows = <ImportRow>[];
  for (var i = 0; i < items.length; i++) {
    final item = items[i];
    final mod = existing[i];
    NameProblem? problem;
    if (names[i].isEmpty) {
      problem = NameProblem.empty;
    } else if (isInvalidModName(names[i])) {
      problem = NameProblem.invalid;
    } else if ((claimed[finals[i].toLowerCase()] ?? 0) > 1) {
      problem = NameProblem.twin;
    }
    final updates = mod != null && choices[i] == OnClash.update;
    rows.add(
      ImportRow(
        item: item,
        finalName: finals[i],
        character: item.pickedCharacter ?? (updates ? mod.characterId : item.guessedCharacter),
        choice: choices[i],
        existing: mod,
        problem: problem,
      ),
    );
  }

  return ImportReview(rows, _blocked(rows));
}

Blocked? _blocked(List<ImportRow> rows) {
  String shown(ImportRow row) => row.item.name.trim().isEmpty ? row.item.label : row.item.name.trim();

  final needing = [for (final row in rows) if (row.needsCharacter) row];
  if (needing.isNotEmpty) return Blocked(BlockedKind.character, shown(needing.first), needing.length - 1);
  final bad = [for (final row in rows) if (row.problem != null) row];
  if (bad.isNotEmpty) return Blocked(BlockedKind.name, shown(bad.first), bad.length - 1);
  return null;
}
