import 'dart:async';

import '../../core/constants.dart';
import '../../models/gamebanana/gamebanana.dart';
import '../../utils/gamebanana_url.dart';
import '../http/http_transport.dart';
import '../http/package_http_transport.dart';
import 'gamebanana_endpoints.dart';
import 'gamebanana_error_mapper.dart';
import 'gamebanana_response_cache.dart';

/// Read-only client for GameBanana's `apiv11`.
///
/// The protocol is documented in `docs/gamebanana-api.md`; this class is only
/// about *our* client. Its surface is kept deliberately small — search, browse,
/// mod profile, category tree — because the API is undocumented upstream and
/// every endpoint we depend on is one more thing that can change without
/// notice.
///
/// **JSON GETs only.** File downloads are not served here: they need streamed
/// bodies, `Range`/`If-Range` resume, redirect inspection and socket
/// backpressure, none of which belong on a JSON transport. That is a separate
/// service with its own client.
///
/// Everything is injectable — transport, cache, clock, sleep — so the whole
/// class is testable with no network and no real waiting.
class GameBananaClient {
  GameBananaClient({
    HttpTransport? transport,
    GameBananaResponseCache? cache,
    GameBananaEndpoints? endpoints,
    GameBananaErrorMapper errorMapper = const GameBananaErrorMapper(),
    int gameId = AppConstants.gameBananaGameId,
    String? userAgent,
    Future<void> Function(Duration)? sleep,
    this.maxRetries = 2,
    this.timeout = const Duration(seconds: 30),
  })  : _transport = transport ?? PackageHttpTransport(),
        _cache = cache ?? GameBananaResponseCache(),
        _endpoints = endpoints ?? GameBananaEndpoints(gameId: gameId),
        _errors = errorMapper,
        _sleep = sleep ?? Future.delayed,
        _userAgent = userAgent ?? AppConstants.httpUserAgent;

  final HttpTransport _transport;
  final GameBananaResponseCache _cache;
  final GameBananaEndpoints _endpoints;
  final GameBananaErrorMapper _errors;
  final Future<void> Function(Duration) _sleep;
  final String _userAgent;

  /// Retries applied to `429`/`503` only.
  final int maxRetries;

  final Duration timeout;

  /// Requests in flight, so two widgets asking for the same thing at the same
  /// moment issue one request rather than two.
  final Map<Uri, Future<String>> _inFlight = <Uri, Future<String>>{};

  GameBananaEndpoints get endpoints => _endpoints;

  // ---------------------------------------------------------------- browsing

  /// Browses mods via `Mod/Index`.
  ///
  /// [perPage] is clamped to the server's maximum of 50; read
  /// [GbPage.perPage] back for what was actually applied.
  Future<GbPage<GbMod>> browseMods({
    int? categoryId,
    int? submitterId,
    GbModSort sort = GbModSort.newest,
    int page = 1,
    int perPage = 30,
    bool refresh = false,
  }) async {
    final body = await _fetch(
      _endpoints.modIndex(
        categoryId: categoryId,
        submitterId: submitterId,
        sort: sort,
        page: page,
        perPage: perPage,
      ),
      refresh: refresh,
    );
    return parseEnvelope(body, GbMod.fromJson);
  }

  /// Text search via `Util/Search/Results`.
  ///
  /// There is no page-size parameter on purpose: the server silently caps this
  /// endpoint at 15 results per page, so the applied value is only knowable
  /// from [GbPage.perPage].
  Future<GbPage<GbMod>> searchMods(
    String query, {
    int page = 1,
    bool refresh = false,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      return const GbPage<GbMod>(records: [], recordCount: 0, isComplete: true);
    }
    final body =
        await _fetch(_endpoints.search(trimmed, page: page), refresh: refresh);
    return parseEnvelope(body, GbMod.fromJson);
  }

  /// The game's "best of period" submissions via `Game/<id>/TopSubs` — three
  /// mods for each of seven windows (today … all time).
  ///
  /// Entries whose `_sPeriod` we don't recognise are dropped rather than
  /// mislabelled, so this can return fewer than 21.
  Future<List<GbTopSub>> topSubs({bool refresh = false}) async {
    final body = await _fetch(_endpoints.topSubs(), refresh: refresh);
    return parseBareList(body, GbTopSub.fromJson);
  }

  /// Full mod detail via `Mod/<id>/ProfilePage` — one request fills the whole
  /// detail screen, including the file list and gallery.
  Future<GbMod> modProfile(int modId, {bool refresh = false}) async {
    final body = await _fetch(_endpoints.modProfile(modId), refresh: refresh);
    final mod = GbMod.fromJson(parseObject(body));
    if (mod == null) {
      throw GbFormatException('Mod $modId: profile carried no _idRow');
    }
    return mod;
  }

  /// Resolves a GameBanana **mod page** url and fetches its profile.
  ///
  /// Throws [GbFormatException] when the url isn't a mod page — including a
  /// `/dl/<id>` file link, which is a different id space entirely.
  ///
  /// `async` so a bad url surfaces through the returned future like every other
  /// failure here, rather than throwing synchronously and forcing callers to
  /// guard the call site *and* the future.
  Future<GbMod> modProfileByUrl(String url, {bool refresh = false}) async {
    final modId = gameBananaModIdFromUrl(url);
    if (modId == null) {
      throw GbFormatException('Not a GameBanana mod page url: $url');
    }
    return modProfile(modId, refresh: refresh);
  }

  /// The category tree via `Mod/Categories` — roots when [categoryId] is null,
  /// otherwise that category's children. Returns a **bare array**, not a page.
  ///
  /// The 60 children of Character Skins are effectively the live ZZZ character
  /// roster, which is what the browse screen's character filter is built from.
  Future<List<GbCategoryNode>> categories({
    int? categoryId,
    GbCategorySort sort = GbCategorySort.aToZ,
    bool refresh = false,
  }) async {
    final body = await _fetch(
      _endpoints.categories(categoryId: categoryId, sort: sort),
      refresh: refresh,
    );
    return parseBareList(body, GbCategoryNode.fromJson);
  }

  // ---------------------------------------------------------------- plumbing

  /// Cache -> coalesce -> transport -> reactive retry -> typed errors.
  Future<String> _fetch(Uri url, {bool refresh = false}) {
    if (!refresh) {
      final cached = _cache.get(url);
      if (cached != null) return Future<String>.value(cached);
    }

    final pending = _inFlight[url];
    if (pending != null) return pending;

    // Block body, not an arrow: `Map.remove` returns the removed value, and an
    // arrow would hand that value — this very future — back to whenComplete,
    // which would then wait for it to finish. The request would hang forever
    // waiting on itself.
    final request = _send(url).whenComplete(() {
      _inFlight.remove(url);
    });
    _inFlight[url] = request;
    return request;
  }

  Future<String> _send(Uri url) async {
    var attempt = 0;
    while (true) {
      final HttpResponse response;
      try {
        response = await _transport.get(
          url,
          headers: {'User-Agent': _userAgent, 'Accept': 'application/json'},
          timeout: timeout,
        );
      } on GbException {
        rethrow;
      } catch (error) {
        // Connectivity, DNS, TLS, timeout — everything the transport throws.
        throw GbNetworkException('Request failed: $url', cause: error);
      }

      try {
        final body = _errors.bodyOrThrow(response);
        // Mirror the server's own TTL when it sent one.
        _cache.put(url, body, ttl: response.maxAge);
        return body;
      } on GbRateLimitException catch (e) {
        if (attempt >= maxRetries) rethrow;
        await _sleep(e.retryAfter ?? _backoffFor(attempt));
        attempt++;
      }
    }
  }

  /// 1s, 2s, 4s… Node assignment upstream is deterministic per file, so an
  /// immediate retry storm buys nothing; spacing attempts out is the only
  /// thing that helps, and only for genuine throttling.
  Duration _backoffFor(int attempt) => Duration(seconds: 1 << attempt);

  /// Drops every cached response. Useful behind a manual "refresh" action.
  void clearCache() => _cache.clear();

  void close() => _transport.close();
}
