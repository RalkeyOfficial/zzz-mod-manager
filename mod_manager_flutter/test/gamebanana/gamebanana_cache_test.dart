import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/services/gamebanana/gamebanana_response_cache.dart';

/// The cache in isolation. The client tests already cover it end-to-end; these
/// cover what only reaches it directly — expiry boundaries and the size bound.
void main() {
  late DateTime clock;
  GameBananaResponseCache build({int maxEntries = 128, Duration? ttl}) {
    return GameBananaResponseCache(
      now: () => clock,
      maxEntries: maxEntries,
      defaultTtl: ttl ?? const Duration(minutes: 10),
    );
  }

  final a = Uri.parse('https://gamebanana.com/apiv13/Mod/1/ProfilePage');
  final b = Uri.parse('https://gamebanana.com/apiv13/Mod/2/ProfilePage');

  setUp(() => clock = DateTime.utc(2026, 8, 1, 12));

  test('stores and returns a body', () {
    final cache = build()..put(a, 'body-a');
    expect(cache.get(a), 'body-a');
  });

  test('a miss is null, not an error', () {
    expect(build().get(a), isNull);
  });

  test('keys are per-url', () {
    final cache = build()
      ..put(a, 'body-a')
      ..put(b, 'body-b');
    expect(cache.get(a), 'body-a');
    expect(cache.get(b), 'body-b');
  });

  group('expiry', () {
    test('lives right up to the TTL and dies after it', () {
      final cache = build()..put(a, 'body');

      clock = clock.add(const Duration(seconds: 599));
      expect(cache.get(a), 'body');

      clock = clock.add(const Duration(seconds: 2)); // 601s total
      expect(cache.get(a), isNull);
    });

    test('an explicit ttl overrides the default', () {
      final cache = build()..put(a, 'body', ttl: const Duration(seconds: 60));

      clock = clock.add(const Duration(seconds: 59));
      expect(cache.get(a), 'body');
      clock = clock.add(const Duration(seconds: 2));
      expect(cache.get(a), isNull);
    });

    test('a zero or negative ttl stores nothing', () {
      // `max-age=0` means "do not reuse this", so honour it rather than
      // caching a body that is already stale.
      final cache = build()
        ..put(a, 'body', ttl: Duration.zero)
        ..put(b, 'body', ttl: const Duration(seconds: -5));
      expect(cache.get(a), isNull);
      expect(cache.get(b), isNull);
      expect(cache.length, 0);
    });

    test('an expired entry is dropped, not just hidden', () {
      final cache = build()..put(a, 'body');
      clock = clock.add(const Duration(hours: 1));
      expect(cache.get(a), isNull);
      expect(cache.length, 0);
    });

    test('re-putting refreshes the deadline', () {
      final cache = build()..put(a, 'v1');
      clock = clock.add(const Duration(minutes: 9));
      cache.put(a, 'v2');
      clock = clock.add(const Duration(minutes: 9));
      expect(cache.get(a), 'v2');
    });
  });

  group('bounds', () {
    test('evicts the oldest entry past maxEntries', () {
      final cache = build(maxEntries: 2)
        ..put(a, 'a')
        ..put(b, 'b')
        ..put(Uri.parse('https://x.test/3'), 'c');

      expect(cache.length, 2);
      expect(cache.get(a), isNull, reason: 'oldest evicted first');
      expect(cache.get(b), 'b');
    });

    test('a refreshed entry moves to the back of the eviction order', () {
      final cache = build(maxEntries: 2)
        ..put(a, 'a')
        ..put(b, 'b')
        ..put(a, 'a2') // touch a, so b is now the oldest
        ..put(Uri.parse('https://x.test/3'), 'c');

      expect(cache.get(a), 'a2');
      expect(cache.get(b), isNull);
    });
  });

  test('remove and clear', () {
    final cache = build()
      ..put(a, 'a')
      ..put(b, 'b');

    cache.remove(a);
    expect(cache.get(a), isNull);
    expect(cache.get(b), 'b');

    cache.clear();
    expect(cache.length, 0);
  });
}
