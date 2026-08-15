/// An in-memory TTL cache of GameBanana response bodies.
///
/// The server's own `max-age` is honoured whenever it sends one — when it tells
/// us how long a response stays good, that is both cheaper and more honest than
/// guessing. **apiv13 sends no `cache-control` at all** (apiv11 sent
/// `public, max-age=600`), so in practice [defaultTtl] is what applies, and the
/// ten minutes it carries is our own choice — inherited from what apiv11 used to
/// advertise, for want of a better-informed number.
///
/// Two deliberate choices:
///
/// - **Values are raw body strings, not parsed objects.** Re-parsing costs
///   microseconds, and it keeps the door open for a disk-backed tier later with
///   the same key and value types. (That tier is not needed until the bulk
///   update pass wants cheap re-runs across launches — and it must not live in
///   `config.json`, which is rewritten wholesale on every setting change.)
/// - **Only successful responses are stored.** Caching an error would turn a
///   transient blip into ten minutes of a broken screen.
class GameBananaResponseCache {
  GameBananaResponseCache({
    DateTime Function()? now,
    this.defaultTtl = const Duration(minutes: 10),
    this.maxEntries = 128,
  }) : _now = now ?? DateTime.now;

  /// Injected so TTL expiry can be tested without waiting ten real minutes.
  final DateTime Function() _now;

  final Duration defaultTtl;

  /// Bounded so a long browsing session can't grow the cache without limit.
  final int maxEntries;

  /// Insertion-ordered, which makes eviction of the oldest entry a `.first`.
  final Map<Uri, _Entry> _entries = <Uri, _Entry>{};

  int get length => _entries.length;

  /// The cached body for [key], or null when absent or expired.
  String? get(Uri key) {
    final entry = _entries[key];
    if (entry == null) return null;
    if (!_now().isBefore(entry.expiresAt)) {
      _entries.remove(key);
      return null;
    }
    return entry.body;
  }

  /// Stores [body] under [key].
  ///
  /// [ttl] should be the server's own `max-age` when it sent one; otherwise
  /// [defaultTtl] applies.
  void put(Uri key, String body, {Duration? ttl}) {
    final lifetime = ttl ?? defaultTtl;
    if (lifetime <= Duration.zero) return;

    // Re-insert so refreshed entries move to the back of the eviction order.
    _entries.remove(key);
    _entries[key] = _Entry(body, _now().add(lifetime));

    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }

  void remove(Uri key) => _entries.remove(key);

  void clear() => _entries.clear();
}

class _Entry {
  const _Entry(this.body, this.expiresAt);

  final String body;
  final DateTime expiresAt;
}
