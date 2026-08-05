import '../../models/gamebanana/gb_enums.dart';

/// Builds every url the GameBanana client requests.
///
/// Kept pure and separate from the client so the request shapes can be asserted
/// directly, with no transport and no async. That matters more than usual here:
/// the API's error responses never enumerate valid values, so a malformed url
/// comes back as a bare `400` with no hint, and the fastest way to catch that
/// class of bug is a unit test on the [Uri] itself.
class GameBananaEndpoints {
  const GameBananaEndpoints({this.gameId, this.baseUrl = defaultBaseUrl});

  static const String defaultBaseUrl = 'https://gamebanana.com/apiv11';

  /// Zenless Zone Zero. Every listing request is scoped to it.
  final int? gameId;

  final String baseUrl;

  /// `Mod/Index` — the browse workhorse.
  ///
  /// Used instead of `Game/<id>/Subfeed` because Subfeed accepts **no filters
  /// and no sort**, while the results grid needs both: the character filter is
  /// only expressible as a `Generic_Category` over the children of the
  /// Character Skins category.
  ///
  /// Note `_nPerpage` is clamped to 50 — asking for more is a hard
  /// `INVALID_PERPAGE` error, not a silent cap.
  Uri modIndex({
    int? categoryId,
    int? submitterId,
    GbModSort sort = GbModSort.newest,
    int page = 1,
    int perPage = 30,
  }) {
    return _uri('Mod/Index', {
      if (gameId != null) '_aFilters[Generic_Game]': '$gameId',
      if (categoryId != null) '_aFilters[Generic_Category]': '$categoryId',
      if (submitterId != null) '_aFilters[Generic_Submitter]': '$submitterId',
      '_sSort': sort.wireValue,
      '_nPerpage': '${clampPerPage(perPage)}',
      '_nPage': '${page < 1 ? 1 : page}',
    });
  }

  /// `Util/Search/Results` — text search.
  ///
  /// Note the parameter spellings differ from [modIndex] entirely: search takes
  /// `_idGameRow`, while Index takes `_aFilters[Generic_Game]`. They do not
  /// overlap, and sending Index's spelling here silently drops the game scope.
  ///
  /// No `perPage`: the server caps this endpoint at 15 **silently**, with no
  /// error, so offering the knob would only let callers believe a number that
  /// was never applied. Read the applied value back from `_aMetadata`.
  Uri search(String query, {int page = 1}) {
    return _uri('Util/Search/Results', {
      '_sModelName': 'Mod',
      '_sSearchString': query,
      if (gameId != null) '_idGameRow': '$gameId',
      '_nPage': '${page < 1 ? 1 : page}',
    });
  }

  /// `Game/<id>/TopSubs` — the game's "best of period" list, which is what the
  /// featured carousel is built from.
  ///
  /// Takes **no parameters at all**: `_nPerpage` and `_sPeriod` are both ignored
  /// (verified — it returns the same 21 entries regardless), so the shape is
  /// fixed at 3 submissions × 7 windows. Returns a **bare array**.
  Uri topSubs() => _uri('Game/$gameId/TopSubs', const {});

  /// `Mod/<id>/ProfilePage` — everything the detail screen needs in one call.
  Uri modProfile(int modId) => _uri('Mod/$modId/ProfilePage', const {});

  /// `Mod/<id>/DownloadPage` — just the file lists. Cheaper than a profile for
  /// an update check, but carries no `_idRow` of its own.
  Uri modDownloadPage(int modId) => _uri('Mod/$modId/DownloadPage', const {});

  /// `Mod/Categories` — the category tree. Returns a **bare array**.
  ///
  /// `_sSort` is always sent because the endpoint requires it: its own internal
  /// default is a value it does not accept, so omitting it is always an error.
  Uri categories({
    int? categoryId,
    GbCategorySort sort = GbCategorySort.aToZ,
    int perPage = 50,
  }) {
    return _uri('Mod/Categories', {
      if (categoryId != null)
        '_idCategoryRow': '$categoryId'
      else if (gameId != null)
        '_idGameRow': '$gameId',
      '_sSort': sort.wireValue,
      '_nPerpage': '${clampPerPage(perPage)}',
    });
  }

  /// `Mod/Multi` — many mods' chosen fields in one request. Returns a **bare
  /// array**, in the order the ids were given.
  ///
  /// Not used yet; the bulk update pass is what needs it, and it turns an
  /// 80-mod library from 80 requests into a couple.
  Uri modsMulti(List<int> modIds, List<String> properties) {
    return _uri('Mod/Multi', {
      '_csvRowIds': modIds.join(','),
      if (properties.isNotEmpty) '_csvProperties': properties.join(','),
    });
  }

  /// The hard server-side maximum on `Mod/Index` and `Subfeed`.
  static const int maxPerPage = 50;

  /// Clamps a requested page size into the range the server accepts.
  static int clampPerPage(int value) =>
      value < 1 ? 1 : (value > maxPerPage ? maxPerPage : value);

  Uri _uri(String path, Map<String, String> query) {
    final base = Uri.parse('$baseUrl/$path');
    return query.isEmpty ? base : base.replace(queryParameters: query);
  }
}
