import '../../models/character_info.dart';
import '../../models/origin_enums.dart';
import '../../services/origin_status.dart';
import '../../services/update_check.dart';
import '../all_mods/all_mods_rows.dart';

/// What the Updates page's coverage strip says about one mod, in the strip's order.
enum CoverageKind {
  /// Checked this session against its known file, or one worked out and accepted in the tracking screen.
  checked,

  /// Checked this session by the day it was added, since it was marked as current.
  datedOnly,

  /// One the app can check, not checked yet this session.
  unchecked,

  whichFile,

  /// A patch whose own page is checked, over a base mod nobody named.
  baseUnknown,

  notTracked,
}

/// What [mod]'s tracking lets the app do, whatever has been checked: [CoverageKind.checked] or
/// [CoverageKind.datedOnly] for a mod a check can compare, the question it asks otherwise, and null for a Local mod,
/// which the user said is never checked. A folder can be compared only when every layer in it can
/// (`modOriginStatus`).
CoverageKind? coverageOf(ModInfo mod) {
  if (isLocalMod(mod)) return null;
  return switch (modOriginStatus(mod.origin)) {
    ModOriginStatus.untracked => CoverageKind.notTracked,
    ModOriginStatus.versionUnknown => CoverageKind.whichFile,
    ModOriginStatus.secondIdentityUnknown => CoverageKind.baseUnknown,
    ModOriginStatus.versionGuessed => mod.origin?.base?.versionConfidence == OriginConfidence.assumedLatest
        ? CoverageKind.datedOnly
        : CoverageKind.checked,
    ModOriginStatus.none || ModOriginStatus.updateAvailable => CoverageKind.checked,
  };
}

/// Whether [check] is an answer from the mod's page: an update, up to date, or the page gone. A verdict about
/// tracking the mod no longer has, or a page that couldn't be compared, is not. Nor is a folder with a layer still
/// asking which file: a base just marked as current reads that way until a check compares it by date, though a patch
/// on it was answered.
bool answeredByCheck(UpdateCheck? check) {
  final answered = switch (check?.outcome) {
    UpdateOutcome.updateAvailable ||
    UpdateOutcome.possiblyOutdated ||
    UpdateOutcome.upToDate ||
    UpdateOutcome.sourceGone =>
      true,
    _ => false,
  };
  return answered && !check!.layers.any((layer) => layer.check.outcome == UpdateOutcome.versionUnknown);
}

/// The library sorted into the coverage strip's cells.
class UpdatesCoverage {
  const UpdatesCoverage({required this.cells, required this.local});

  /// One per mod that isn't Local, in [CoverageKind] order and by name within a kind.
  final List<(ModInfo, CoverageKind)> cells;

  /// The Local mods, which have no cell.
  final int local;

  int get total => cells.length;

  int count(CoverageKind kind) => cells.where((c) => c.$2 == kind).length;

  /// Checked this session, by file or by date.
  int get checked => count(CoverageKind.checked) + count(CoverageKind.datedOnly);

  List<ModInfo> of(CoverageKind kind) => [for (final (mod, k) in cells) if (k == kind) mod];
}

/// [mods] sorted into cells. A mod the app can check is [CoverageKind.unchecked] until [checks] holds an answer for
/// it, or the running check has [reached] it.
UpdatesCoverage coverageFor(
  List<ModInfo> mods,
  Map<String, UpdateCheck> checks, {
  Set<String> reached = const {},
}) {
  final cells = <(ModInfo, CoverageKind)>[];
  var local = 0;
  for (final mod in mods) {
    final kind = coverageOf(mod);
    if (kind == null) {
      local++;
    } else if ((kind == CoverageKind.checked || kind == CoverageKind.datedOnly) &&
        !answeredByCheck(checks[mod.id]) &&
        !reached.contains(mod.id)) {
      cells.add((mod, CoverageKind.unchecked));
    } else {
      cells.add((mod, kind));
    }
  }
  cells.sort((a, b) {
    final byKind = a.$2.index.compareTo(b.$2.index);
    return byKind != 0 ? byKind : a.$1.name.toLowerCase().compareTo(b.$1.name.toLowerCase());
  });
  return UpdatesCoverage(cells: cells, local: local);
}

/// The strip's pills for [cells]: the checked mods, then empty pills up to [minimum], then the mods that can't be
/// checked. A mod not checked yet has no pill of its own, so the strip grows a pill as the check reaches each mod
/// once the empty ones run out. Null is an empty pill.
List<CoverageKind?> coveragePills(List<CoverageKind> cells, {required int minimum}) {
  bool isChecked(CoverageKind kind) => kind == CoverageKind.checked || kind == CoverageKind.datedOnly;
  final checked = [for (final kind in cells) if (isChecked(kind)) kind];
  final questions = [
    for (final kind in cells)
      if (!isChecked(kind) && kind != CoverageKind.unchecked) kind,
  ];
  final empty = minimum - checked.length - questions.length;
  return [...checked, for (var i = 0; i < empty; i++) null, ...questions];
}

/// Where the question pills start in [pills]: they are the strip's tail.
int _questionsAt(List<CoverageKind?> pills) {
  bool isQuestion(CoverageKind? kind) =>
      kind == CoverageKind.whichFile || kind == CoverageKind.baseUnknown || kind == CoverageKind.notTracked;
  var start = pills.length;
  while (start > 0 && isQuestion(pills[start - 1])) {
    start--;
  }
  return start;
}

/// For each place of [after], the place in [before] it was, or null for a place the strip didn't have. Places are
/// matched from the left up to the questions and from the right among them, so a strip that grows fills from the left
/// and its questions keep their colours.
List<int?> pillPlacesBefore(List<CoverageKind?> before, List<CoverageKind?> after) {
  final oldQuestions = _questionsAt(before);
  final newQuestions = _questionsAt(after);
  return [
    for (var i = 0; i < after.length; i++)
      if (i < newQuestions)
        i < oldQuestions ? i : null
      else if (before.length - (after.length - i) case final j when j >= oldQuestions)
        j
      else
        null,
  ];
}

/// The pills of [after] that show something new, each with what was in its place in [before] and that place's index
/// there (`pillPlacesBefore`): null for an empty pill, and both null for a place the strip didn't have.
List<(int, CoverageKind?, int?)> pillChanges(List<CoverageKind?> before, List<CoverageKind?> after) {
  final places = pillPlacesBefore(before, after);
  final changes = <(int, CoverageKind?, int?)>[];
  for (var i = 0; i < after.length; i++) {
    final from = places[i];
    final was = from == null ? null : before[from];
    if (was != after[i]) changes.add((i, was, from));
  }
  return changes;
}

/// The mods with an update to show, each with its check, the most recently uploaded newer file first. The same set
/// the sidebar's Updates count covers.
List<(ModInfo, UpdateCheck)> newerFilesOf(List<ModInfo> mods, Map<String, UpdateCheck> checks) {
  final found = [
    for (final mod in mods)
      if (checks[mod.id] case final check? when check.hasUpdate) (mod, check),
  ];
  found.sort((a, b) {
    final da = a.$2.dismissableUpTo;
    final db = b.$2.dismissableUpTo;
    if (da == null || db == null) return (da == null ? 1 : 0) - (db == null ? 1 : 0);
    return db.compareTo(da);
  });
  return found;
}
