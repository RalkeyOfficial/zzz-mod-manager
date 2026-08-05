import 'gb_category.dart';
import 'gb_coerce.dart';
import 'gb_enums.dart';
import 'gb_submitter.dart';

/// The time window a [GbTopSub] won.
///
/// Declaration order **is** display order — shortest window first, matching how
/// `Game/<id>/TopSubs` returns them and how the site presents them.
enum GbTopSubPeriod {
  today('today'),
  week('week'),
  month('month'),
  threeMonths('3month'),
  sixMonths('6month'),
  year('year'),
  allTime('alltime');

  const GbTopSubPeriod(this.wire);

  /// The literal `_sPeriod` value.
  final String wire;

  /// Suffix of the l10n key for this period's label
  /// (`marketplace.period_<key>`), kept here so a new period upstream needs one
  /// translation rather than a `switch` in the widget.
  String get l10nKey => name;

  /// Parses `_sPeriod`, returning **null** for anything unrecognised.
  ///
  /// Null rather than a fallback member on purpose: a new window appearing
  /// upstream should be skipped, not silently mislabelled as "today". The caller
  /// drops those entries.
  static GbTopSubPeriod? parse(Object? value) {
    final raw = gbString(value);
    if (raw == null) return null;
    for (final period in GbTopSubPeriod.values) {
      if (period.wire == raw) return period;
    }
    return null;
  }
}

/// One entry of `Game/<id>/TopSubs` — the "best of period" list behind the
/// marketplace's featured carousel.
///
/// A **separate type from `GbMod`, deliberately.** This endpoint returns its own
/// shape rather than a subset of the mod object: images arrive as two
/// pre-resolved urls (`_sImageUrl`, `_sThumbnailUrl`) instead of the
/// `_aPreviewMedia` base-plus-variants ladder that `GbImage` models, and it
/// carries `_sPeriod`, which exists nowhere else. Forcing it into `GbMod` would
/// mean either faking a `GbImage` from a finished url or making `GbMod` lie about
/// which fields a response can carry.
///
/// [idRow] is a real mod id, so opening one goes through the normal
/// `Mod/<id>/ProfilePage` detail path — nothing about the detail view needs to
/// know these exist.
class GbTopSub {
  const GbTopSub({
    required this.idRow,
    required this.period,
    this.name,
    this.description,
    this.profileUrl,
    this.imageUrl,
    this.thumbnailUrl,
    this.visibility,
    this.submitter,
    this.likeCount,
    this.postCount,
    this.rootCategory,
  });

  /// `_idRow` — the mod id.
  final int idRow;

  /// `_sPeriod`, parsed. Non-null: entries with an unknown window are dropped.
  final GbTopSubPeriod period;

  /// `_sName`.
  final String? name;

  /// `_sDescription` — a short tagline. Present on only a minority of entries
  /// (3 of 21 in the captured response), so treat it as optional decoration.
  final String? description;

  /// `_sProfileUrl`.
  final String? profileUrl;

  /// `_sImageUrl` — a finished url for the large (800px) image.
  final String? imageUrl;

  /// `_sThumbnailUrl` — a finished url for the 220px thumbnail.
  final String? thumbnailUrl;

  /// `_sInitialVisibility`. Present on every captured entry, which matters: the
  /// carousel has to honour the content filter like any other listing, and the
  /// list skews heavily adult (20 of 21 captured entries were `warn`/`hide`).
  final GbVisibility? visibility;

  final GbSubmitter? submitter;
  final int? likeCount;
  final int? postCount;

  /// `_aRootCategory` — only the root here, so the badge is "Character Skins"
  /// rather than a character name. This endpoint carries no `_aSubCategory`.
  final GbCategoryRef? rootCategory;

  /// Fails closed, exactly as `GbMod.effectiveVisibility` does: an absent hint is
  /// treated as needing a warning rather than assumed safe.
  GbVisibility get effectiveVisibility => visibility ?? GbVisibility.warn;

  /// Returns null when the row has no id or an unrecognised period.
  static GbTopSub? fromJson(Map<String, dynamic> json) {
    final id = gbInt(json['_idRow']);
    final period = GbTopSubPeriod.parse(json['_sPeriod']);
    if (id == null || period == null) return null;

    return GbTopSub(
      idRow: id,
      period: period,
      name: gbString(json['_sName']),
      description: gbString(json['_sDescription']),
      profileUrl: gbString(json['_sProfileUrl']),
      imageUrl: gbString(json['_sImageUrl']),
      thumbnailUrl: gbString(json['_sThumbnailUrl']),
      visibility: json.containsKey('_sInitialVisibility')
          ? GbVisibility.parse(json['_sInitialVisibility'])
          : null,
      submitter: GbSubmitter.fromJson(json['_aSubmitter']),
      likeCount: gbInt(json['_nLikeCount']),
      postCount: gbInt(json['_nPostCount']),
      rootCategory: GbCategoryRef.fromJson(json['_aRootCategory']),
    );
  }
}

/// Groups top submissions by window, in [GbTopSubPeriod] declaration order.
///
/// Pure and separate from the widget so the ordering and the empty-group rules
/// are testable without a layout. Two rules worth stating:
///
/// - **Declared order wins, not response order.** The response happens to arrive
///   shortest-window-first, but relying on that would make the carousel silently
///   reorder itself if the server ever changed.
/// - **Empty groups are omitted**, which is not hypothetical: with the content
///   filter set to hide adult mods, most of this list disappears, and a labelled
///   "Best of today" header over nothing would look broken.
List<({GbTopSubPeriod period, List<GbTopSub> mods})> groupTopSubs(
  Iterable<GbTopSub> subs,
) {
  final byPeriod = <GbTopSubPeriod, List<GbTopSub>>{};
  for (final sub in subs) {
    byPeriod.putIfAbsent(sub.period, () => <GbTopSub>[]).add(sub);
  }
  return [
    for (final period in GbTopSubPeriod.values)
      if (byPeriod[period] case final mods? when mods.isNotEmpty)
        (period: period, mods: mods),
  ];
}
