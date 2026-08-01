import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/services/download/rate_estimator.dart';

void main() {
  late DateTime clock;
  RateEstimator build() => RateEstimator(now: () => clock);

  setUp(() => clock = DateTime.utc(2026, 8, 1, 12));

  void advance(Duration d) => clock = clock.add(d);

  group('bytesPerSecond', () {
    test('is null until there is enough history', () {
      final estimator = build();
      expect(estimator.bytesPerSecond, isNull, reason: 'no samples');

      estimator.add(0);
      expect(estimator.bytesPerSecond, isNull, reason: 'one sample');

      advance(const Duration(milliseconds: 100));
      estimator.add(1000);
      expect(estimator.bytesPerSecond, isNull,
          reason: 'span shorter than minimumSpan — a wild first-chunk figure');
    });

    test('reports a steady rate once settled', () {
      final estimator = build()..add(0);
      for (var i = 1; i <= 4; i++) {
        advance(const Duration(seconds: 1));
        estimator.add(i * 10 * 1024 * 1024); // 10 MB/s
      }
      expect(estimator.bytesPerSecond, closeTo(10 * 1024 * 1024, 1));
    });

    test('drops toward zero when the transfer stalls', () {
      final estimator = build()..add(0);
      advance(const Duration(seconds: 1));
      estimator.add(1000000);
      expect(estimator.bytesPerSecond, greaterThan(0));

      // Time passes, no new bytes.
      for (var i = 0; i < 5; i++) {
        advance(const Duration(seconds: 1));
        estimator.add(1000000);
      }
      expect(estimator.bytesPerSecond, lessThan(1000));
    });

    test('forgets samples that fall out of the window', () {
      final estimator = RateEstimator(
        now: () => clock,
        window: const Duration(seconds: 3),
      );
      // A fast burst...
      estimator.add(0);
      advance(const Duration(seconds: 1));
      estimator.add(100 * 1024 * 1024);
      // ...then a long slow stretch that should dominate.
      for (var i = 1; i <= 4; i++) {
        advance(const Duration(seconds: 1));
        estimator.add(100 * 1024 * 1024 + i * 1024);
      }
      expect(estimator.bytesPerSecond, lessThan(1024 * 1024),
          reason: 'the old burst must have aged out of the window');
    });

    test('a byte count going backwards yields null, not a negative rate', () {
      final estimator = build()..add(5000);
      advance(const Duration(seconds: 2));
      estimator.add(1000);
      expect(estimator.bytesPerSecond, isNull);
    });
  });

  group('etaFor', () {
    test('is remaining divided by rate', () {
      final estimator = build()..add(0);
      advance(const Duration(seconds: 2));
      estimator.add(2000); // 1000 B/s

      final eta = estimator.etaFor(received: 2000, total: 12000);
      expect(eta, const Duration(seconds: 10));
    });

    test('is null when the total is unknown', () {
      final estimator = build()..add(0);
      advance(const Duration(seconds: 2));
      estimator.add(2000);
      expect(estimator.etaFor(received: 2000, total: null), isNull);
      expect(estimator.etaFor(received: 2000, total: 0), isNull);
    });

    test('is null before the rate has settled', () {
      final estimator = build()..add(0);
      expect(estimator.etaFor(received: 0, total: 1000), isNull);
    });

    test('is null rather than absurd when stalled', () {
      // A rate near zero would produce an ETA of millions of seconds. Saying
      // nothing is more honest than saying "3 weeks remaining".
      final estimator = build()..add(1000);
      for (var i = 0; i < 5; i++) {
        advance(const Duration(seconds: 1));
        estimator.add(1000);
      }
      expect(estimator.etaFor(received: 1000, total: 1000000000), isNull);
    });

    test('is zero once everything has arrived', () {
      final estimator = build()..add(0);
      advance(const Duration(seconds: 2));
      estimator.add(1000);
      expect(estimator.etaFor(received: 1000, total: 1000), Duration.zero);
    });
  });

  test('reset clears history', () {
    final estimator = build()..add(0);
    advance(const Duration(seconds: 2));
    estimator.add(2000);
    expect(estimator.bytesPerSecond, isNotNull);

    estimator.reset();
    expect(estimator.bytesPerSecond, isNull);
  });
}
