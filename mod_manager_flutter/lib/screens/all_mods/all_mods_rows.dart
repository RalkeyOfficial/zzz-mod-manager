import '../../l10n/app_localizations.dart';
import '../../models/character_info.dart';
import '../../models/gamebanana/gb_mod.dart';
import '../../models/origin_enums.dart';
import '../../services/installed_record.dart';
import '../../services/origin_status.dart';
import '../../services/platform_service.dart';
import '../../services/update_check.dart';
import '../../utils/categories.dart';
import '../../utils/state_providers.dart';
import '../../utils/zzz_characters.dart';
import '../components/character_tile.dart';

/// One row of the All mods table: a mod in the library, or a link in ZZMI's mods folder whose folder is missing.
sealed class AllModsRow {
  const AllModsRow();

  /// Unique across both kinds, for keys and selection.
  String get key;

  String get name;
}

class ModRow extends AllModsRow {
  const ModRow(this.mod);

  final ModInfo mod;

  @override
  String get key => 'mod_${mod.id}';

  @override
  String get name => mod.name;
}

/// A dead link. It can't be selected or acted on: it is never removed, and works again once its folder is back.
class MissingRow extends AllModsRow {
  const MissingRow(this.link);

  final DeadModLink link;

  @override
  String get key => 'missing_${link.name}';

  @override
  String get name => link.name;
}

/// A group's heading in a grouped table.
class AllModsGroup {
  const AllModsGroup({required this.id, required this.label, required this.rows, this.characterId});

  final String id;
  final String label;
  final List<AllModsRow> rows;

  /// The character list row the group is, for its tile; null for the one group of an ungrouped table.
  final String? characterId;
}

/// What the table needs to know about the session to filter and sort its rows.
class AllModsContext {
  const AllModsContext({
    required this.checks,
    required this.pages,
    required this.sizes,
    required this.loc,
  });

  final Map<String, UpdateCheck> checks;
  final Map<int, GbMod> pages;
  final Map<String, int> sizes;
  final AppLocalizations loc;

  /// The mod page's author, once this session holds the page.
  String? authorOf(ModInfo mod) => installedRecord(mod, pages).page?.submitter?.name;

  String characterOf(ModInfo mod) => libraryGroupName(libraryGroupOf(mod.characterId), loc);

  bool hasUpdate(ModInfo mod) => checks[mod.id]?.hasUpdate ?? false;

  UpdatesCell updatesOf(ModInfo mod) => updatesCellOf(mod, checks[mod.id]);
}

/// What the Updates column says about a mod, one state per cell, in the order the column sorts by need.
enum UpdatesCell {
  newerFile,
  maybeNewer,
  whichFile,
  baseUnknown,
  notTracked,
  notOnGameBanana,
  couldntCheck,
  upToDate,
  local,

  /// No verdict to show: no check this session, a check that didn't cover the mod, or one about tracking it no
  /// longer has.
  unchecked,
}

/// The Updates column's state for [mod]: the check's verdict wherever the app could check it, and what the tracking
/// asks for where it couldn't.
///
/// An ignored update reads Up to date: it was ignored as not the user's file, a different variant say. Which file?
/// stays the prompt whatever the check said; Base unknown gives way to a live update of the patch's own page.
UpdatesCell updatesCellOf(ModInfo mod, UpdateCheck? check) {
  if (isLocalMod(mod)) return UpdatesCell.local;
  final live = !(check?.hasUpdate ?? false)
      ? null
      : check!.outcome == UpdateOutcome.updateAvailable
      ? UpdatesCell.newerFile
      : UpdatesCell.maybeNewer;
  switch (modOriginStatus(mod.origin)) {
    case ModOriginStatus.untracked:
      return UpdatesCell.notTracked;
    case ModOriginStatus.versionUnknown:
      return UpdatesCell.whichFile;
    case ModOriginStatus.secondIdentityUnknown:
      return live ?? UpdatesCell.baseUnknown;
    case ModOriginStatus.none || ModOriginStatus.versionGuessed || ModOriginStatus.updateAvailable:
      break;
  }
  if (check == null) return UpdatesCell.unchecked;
  if (live != null) return live;
  return switch (check.outcome) {
    // Not live here, so ignored.
    UpdateOutcome.updateAvailable || UpdateOutcome.possiblyOutdated || UpdateOutcome.upToDate => UpdatesCell.upToDate,
    UpdateOutcome.sourceGone => UpdatesCell.notOnGameBanana,
    UpdateOutcome.indeterminate => UpdatesCell.couldntCheck,
    UpdateOutcome.versionUnknown ||
    UpdateOutcome.tracksPatchOnly ||
    UpdateOutcome.untracked ||
    UpdateOutcome.trackingOff => UpdatesCell.unchecked,
  };
}

/// How many rows each chip of the table would leave. [updates] is null before any check, when "0" would claim one ran.
class AllModsCounts {
  const AllModsCounts({
    required this.all,
    required this.active,
    required this.off,
    required this.updates,
    required this.folderMissing,
    required this.favorites,
    required this.needsAttention,
  });

  final int all;
  final int active;
  final int off;
  final int? updates;
  final int folderMissing;
  final int favorites;
  final int needsAttention;

  int? of(AllModsFilter filter) => switch (filter) {
    AllModsFilter.all => all,
    AllModsFilter.active => active,
    AllModsFilter.off => off,
    AllModsFilter.updates => updates,
    AllModsFilter.folderMissing => folderMissing,
    AllModsFilter.favorites => favorites,
    AllModsFilter.needsAttention => needsAttention,
  };
}

/// The chips' counts over the whole table, before the search narrows it.
AllModsCounts countAllMods(List<ModInfo> mods, List<DeadModLink> missing, Map<String, UpdateCheck> checks) {
  return AllModsCounts(
    // Mods only, as the sidebar and the header count them: a Folder missing row is listed under All but isn't a mod.
    all: mods.length,
    active: mods.where((m) => m.isActive).length,
    off: mods.where((m) => !m.isActive).length,
    updates: checks.isEmpty ? null : mods.where((m) => checks[m.id]?.hasUpdate ?? false).length,
    folderMissing: missing.length,
    favorites: mods.where((m) => m.isFavorite).length,
    needsAttention: mods.where(modInfoNeedsAttention).length,
  );
}

/// The rows [filter] and [search] keep, sorted by [sort].
///
/// A missing folder is listed under All and Folder missing only: it has no state to be on, off, starred or checked.
/// The search matches the name and the character or type.
List<AllModsRow> visibleAllModsRows({
  required List<ModInfo> mods,
  required List<DeadModLink> missing,
  required AllModsFilter filter,
  required String search,
  required AllModsSort sort,
  required AllModsContext session,
}) {
  bool keepMod(ModInfo mod) => switch (filter) {
    AllModsFilter.all => true,
    AllModsFilter.active => mod.isActive,
    AllModsFilter.off => !mod.isActive,
    AllModsFilter.updates => session.hasUpdate(mod),
    AllModsFilter.folderMissing => false,
    AllModsFilter.favorites => mod.isFavorite,
    AllModsFilter.needsAttention => modInfoNeedsAttention(mod),
  };
  final keepMissing = filter == AllModsFilter.all || filter == AllModsFilter.folderMissing;

  final query = search.trim().toLowerCase();
  bool matches(String? text) => text != null && text.toLowerCase().contains(query);

  final rows = <AllModsRow>[
    for (final mod in mods)
      if (keepMod(mod) &&
          (query.isEmpty || matches(mod.name) || matches(session.characterOf(mod))))
        ModRow(mod),
    if (keepMissing)
      for (final link in missing)
        if (query.isEmpty || matches(link.name)) MissingRow(link),
  ];
  rows.sort((a, b) => compareAllModsRows(a, b, sort, session));
  return rows;
}

/// [sort]'s order, with rows that have no value for the column last whichever way it runs, then by name and key so
/// the order never shuffles between rebuilds.
int compareAllModsRows(AllModsRow a, AllModsRow b, AllModsSort sort, AllModsContext session) {
  Comparable<dynamic>? valueOf(AllModsRow row) {
    final mod = switch (row) {
      ModRow(:final mod) => mod,
      MissingRow() => null,
    };
    return switch (sort.column) {
      AllModsColumn.name => row.name.toLowerCase(),
      AllModsColumn.character => mod == null ? null : session.characterOf(mod).toLowerCase(),
      // Active, Off, then Folder missing.
      AllModsColumn.status => mod == null ? 2 : (mod.isActive ? 0 : 1),
      AllModsColumn.updates => switch (mod == null ? UpdatesCell.unchecked : session.updatesOf(mod)) {
        UpdatesCell.unchecked => null,
        final cell => cell.index,
      },
      AllModsColumn.size => mod == null ? null : session.sizes[mod.id],
      AllModsColumn.added => mod?.origin?.installedAt,
    };
  }

  final va = valueOf(a);
  final vb = valueOf(b);
  if (va != null && vb == null) return -1;
  if (va == null && vb != null) return 1;
  if (va != null && vb != null) {
    final byValue = sort.descending ? vb.compareTo(va) : va.compareTo(vb);
    if (byValue != 0) return byValue;
  }
  final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
  return byName != 0 ? byName : a.key.compareTo(b.key);
}

/// [rows] in groups, keeping their order within each. By character in the character list's order of
/// [libraryGroupIds], and a missing folder, whose character is unknown, under Unassigned. Empty groups are left out.
List<AllModsGroup> groupAllModsRows(List<AllModsRow> rows, AllModsGrouping grouping, AppLocalizations loc) {
  switch (grouping) {
    case AllModsGrouping.none:
      return [AllModsGroup(id: 'all', label: '', rows: rows)];
    case AllModsGrouping.character:
      final byGroup = <String, List<AllModsRow>>{};
      for (final row in rows) {
        final group = switch (row) {
          ModRow(:final mod) => libraryGroupOf(mod.characterId),
          MissingRow() => unknownCharacterId,
        };
        (byGroup[group] ??= []).add(row);
      }
      return [
        for (final id in libraryGroupIds)
          if (byGroup[id] case final groupRows?)
            AllModsGroup(id: id, label: libraryGroupName(id, loc), rows: groupRows, characterId: id),
      ];
  }
}

/// The key [group] is folded under in `allModsCollapsedProvider`.
String allModsGroupKey(AllModsGrouping grouping, AllModsGroup group) => '${grouping.name}/${group.id}';

/// [rows] in the order the table shows them, group by group, without the ones in a folded group. A Shift-click
/// range runs over this list, so it spans what is on screen.
List<AllModsRow> unfoldedAllModsRows(
  List<AllModsRow> rows,
  AllModsGrouping grouping,
  Set<String> collapsed,
  AppLocalizations loc,
) {
  if (grouping == AllModsGrouping.none) return rows;
  return [
    for (final group in groupAllModsRows(rows, grouping, loc))
      if (!collapsed.contains(allModsGroupKey(grouping, group))) ...group.rows,
  ];
}

/// Whether the origin block says the user marked the mod as their own.
bool isLocalMod(ModInfo mod) => mod.origin?.tracking == OriginTracking.off;
