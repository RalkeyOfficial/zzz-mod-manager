import 'dart:async';

import '../../core/constants.dart';
import '../../models/gamebanana/gamebanana.dart';
import '../http/http_transport.dart';
import '../http/package_http_transport.dart';
import '../log/logger.dart';
import 'gamebanana_endpoints.dart';
import 'gamebanana_error_mapper.dart';
import 'gamebanana_response_cache.dart';

/// Read-only client for GameBanana's `apiv13`.
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
final Logger _log = Logger('gamebanana.client');

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
    return _fetchParsed(
      _endpoints.modIndex(
        categoryId: categoryId,
        submitterId: submitterId,
        sort: sort,
        page: page,
        perPage: perPage,
      ),
      (body) => parseEnvelope(body, GbMod.fromJson),
      refresh: refresh,
    );
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
    return _fetchParsed(
      _endpoints.search(trimmed, page: page),
      (body) => parseEnvelope(body, GbMod.fromJson),
      refresh: refresh,
    );
  }

  /// The game's "best of period" submissions via `Game/<id>/TopSubs` — three
  /// mods for each of seven windows (today … all time).
  ///
  /// Entries whose `_sPeriod` we don't recognise are dropped rather than
  /// mislabelled, so this can return fewer than 21.
  Future<List<GbTopSub>> topSubs({bool refresh = false}) async {
    return _fetchParsed(
      _endpoints.topSubs(),
      (body) => parseBareList(body, GbTopSub.fromJson),
      refresh: refresh,
    );
  }

  /// Full mod detail via `Mod/<id>/ProfilePage` — one request fills the whole
  /// detail screen, including the file list and gallery.
  Future<GbMod> modProfile(int modId, {bool refresh = false}) async {
    return _fetchParsed(_endpoints.modProfile(modId), (body) {
      final mod = GbMod.fromJson(parseObject(body));
      if (mod == null) {
        throw GbFormatException('Mod $modId: profile carried no _idRow');
      }
      return mod;
    }, refresh: refresh);
  }

  /// Many mods' chosen fields in one request via `Mod/Multi` — a **bare array**
  /// carrying only [properties].
  ///
  /// The batch is all-or-nothing: a single id the server doesn't recognise
  /// fails the whole request with a `400`. That is left to the caller rather
  /// than absorbed here, because recovering from it means deciding what to do
  /// with the ids that *were* fine, which is policy — see
  /// `services/bulk_update_check.dart`.
  ///
  /// [maxBatch] is our cap, not the server's: 60 ids in one url were verified
  /// to work, and 50 keeps the request comfortably inside that while matching
  /// the page size every other endpoint here is limited to.
  static const int maxBatch = 50;

  Future<List<GbMod>> modsMulti(
    List<int> modIds, {
    required List<String> properties,
    bool refresh = false,
  }) async {
    if (modIds.isEmpty) return const <GbMod>[];
    return _fetchParsed(
      _endpoints.modsMulti(modIds, properties),
      (body) => parseBareList(body, GbMod.fromJson),
      refresh: refresh,
    );
  }

  /// The mod's release feed via `Mod/<id>/Updates`, newest first.
  ///
  /// One request, and the newest page is all the update check needs — see
  /// [GameBananaEndpoints.modUpdates].
  Future<List<GbUpdate>> modUpdates(int modId, {bool refresh = false}) async {
    return _fetchParsed(
      _endpoints.modUpdates(modId),
      (body) => parseEnvelope(body, GbUpdate.fromJson).records,
      refresh: refresh,
    );
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
    return _fetchParsed(
      _endpoints.categories(categoryId: categoryId, sort: sort),
      (body) => parseBareList(body, GbCategoryNode.fromJson),
      refresh: refresh,
    );
  }

  // ---------------------------------------------------------------- plumbing

  /// [_fetch], then parse — and **drop the cached body if the parse fails.**
  ///
  /// Every request goes through here rather than through [_fetch] directly,
  /// because a body kept in the cache is a body that will be handed back for the
  /// next ten minutes without asking the server anything. A body that could not
  /// be parsed once cannot be parsed on the next press either, so keeping it
  /// turns a single bad response into a feature that stays broken while the
  /// user retries — which is exactly how one empty `200` on one mod page read as
  /// that page being permanently unopenable.
  ///
  /// Catches everything rather than `GbException`: a parser bug of ours poisons
  /// the cache just as effectively as a malformed body, and re-throwing is the
  /// caller's answer either way.
  Future<T> _fetchParsed<T>(
    Uri url,
    T Function(String body) parse, {
    bool refresh = false,
  }) async {
    final body = await _fetch(url, refresh: refresh);
    try {
      return parse(body);
    } catch (error, stack) {
      _cache.remove(url);
      // The **head of the body, not the body**: 120 characters is enough to
      // tell a Cloudflare interstitial from an error envelope from a changed
      // shape, and a mod page's full JSON in a log file is neither readable
      // nor anybody's business.
      _log.error('could not read the response',
          error: error,
          stack: stack,
          fields: {
            'url': _shortUrl(url),
            'bytes': body.length,
            'head': body.length > 120 ? body.substring(0, 120) : body,
            'cache': 'evicted',
          });
      rethrow;
    }
  }

  /// The path, without the host and without the api version prefix.
  ///
  /// Every line would otherwise carry the same 30 characters of
  /// `https://gamebanana.com/apiv13`, which is in the header already.
  String _shortUrl(Uri url) =>
      url.path.replaceFirst(RegExp(r'^/apiv\d+'), '') +
      (url.hasQuery ? '?${url.query}' : '');

  /// Cache -> coalesce -> transport -> reactive retry -> typed errors.
  Future<String> _fetch(Uri url, {bool refresh = false}) {
    if (!refresh) {
      final cached = _cache.get(url);
      if (cached != null) {
        _log.debug('request', fields: {
          'url': _shortUrl(url),
          'cache': 'hit',
          'bytes': cached.length,
        });
        return Future<String>.value(cached);
      }
    }

    final pending = _inFlight[url];
    if (pending != null) {
      // Two screens wanting the same page at once. Worth a line: it explains a
      // response arriving with no request beside it.
      _log.debug('request', fields: {
        'url': _shortUrl(url),
        'cache': 'coalesced',
      });
      return pending;
    }

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
      _log.debug('request', fields: {
        'url': _shortUrl(url),
        'cache': 'miss',
        if (attempt > 0) 'attempt': attempt + 1,
      });

      final started = DateTime.now();
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
        _log.error('request failed', error: error, fields: {
          'url': _shortUrl(url),
          'kind': 'offline',
          'took': DateTime.now().difference(started),
        });
        // Connectivity, DNS, TLS, timeout — everything the transport throws.
        throw GbNetworkException('Request failed: $url', cause: error);
      }

      // **The line the empty-`200` bug needed and did not have.** Status and
      // body length, before anything has decided what they mean — which is
      // what makes `status=200 bytes=0` the whole diagnosis rather than an
      // "unexpected end of input" three layers later.
      _log.debug('response', fields: {
        'url': _shortUrl(url),
        'status': response.statusCode,
        'bytes': response.body.length,
        'took': DateTime.now().difference(started),
      });

      try {
        final body = _errors.bodyOrThrow(response);
        // Mirror the server's own TTL when it sent one.
        _cache.put(url, body, ttl: response.maxAge);
        return body;
      } on GbRateLimitException catch (e) {
        if (attempt >= maxRetries) {
          _log.error('gave up', fields: {
            'url': _shortUrl(url),
            'kind': 'rate_limited',
            'status': response.statusCode,
            'attempts': attempt + 1,
          });
          rethrow;
        }
        final wait = e.retryAfter ?? _backoffFor(attempt);
        _log.warning('retrying', fields: {
          'url': _shortUrl(url),
          'reason': 'rate_limit',
          'status': response.statusCode,
          'attempt': attempt + 1,
          'wait': wait,
        });
        await _sleep(wait);
        attempt++;
      } on GbEmptyResponseException {
        // A `200` carrying nothing is a transient upstream fault — measured on
        // one mod page, twice in a row, with the same url serving valid JSON a
        // minute later. Retried on exactly the same terms as a back-off, with no
        // `Retry-After` to honour because the server never admitted a problem.
        if (attempt >= maxRetries) {
          _log.error('gave up', fields: {
            'url': _shortUrl(url),
            'kind': 'empty',
            'status': response.statusCode,
            'bytes': 0,
            'attempts': attempt + 1,
          });
          rethrow;
        }
        final wait = _backoffFor(attempt);
        _log.warning('retrying', fields: {
          'url': _shortUrl(url),
          'reason': 'empty_body',
          'status': response.statusCode,
          'attempt': attempt + 1,
          'wait': wait,
        });
        await _sleep(wait);
        attempt++;
      } on GbApiException catch (e) {
        // Not retried — a 404 or a bad request will say the same thing next
        // time — but very much worth a line, because this is what a user sees
        // as "the mod page won't open".
        _log.error('gave up', fields: {
          'url': _shortUrl(url),
          'kind': e.isNotFound ? 'not_found' : 'api',
          'status': response.statusCode,
          'code': e.code,
        });
        rethrow;
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
