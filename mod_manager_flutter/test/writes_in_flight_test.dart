import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/services/writes_in_flight.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

import 'support/held_write.dart';

/// What closing the app waits for: the writes into mod folders running at the moment, for at most a bound.
void main() {
  late WritesInFlight writes;

  setUp(() => writes = WritesInFlight());

  test('never waits when no write is running', () async {
    final clock = Stopwatch()..start();
    expect(await writes.settle(const Duration(seconds: 5)), isTrue);
    expect(clock.elapsed, lessThan(const Duration(seconds: 1)));
  });

  test('waits for a write in flight to end', () async {
    final done = Completer<void>();
    unawaited(writes.track(() => done.future));
    var settled = false;
    final waiting = writes.settle(const Duration(seconds: 5)).then((v) => settled = v);

    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(settled, isFalse, reason: 'the write is still running');

    done.complete();
    await waiting;
    expect(settled, isTrue);
    expect(writes.count, 0);
  });

  test('gives up once the bound runs out', () async {
    unawaited(writes.track(() => Completer<void>().future));
    final clock = Stopwatch()..start();

    expect(await writes.settle(const Duration(milliseconds: 50)), isFalse);
    expect(clock.elapsed, greaterThanOrEqualTo(const Duration(milliseconds: 50)));
    expect(writes.count, 1);
  });

  test('waits for every write, including one that started while it waited', () async {
    final first = Completer<void>();
    final second = Completer<void>();
    unawaited(writes.track(() => first.future));
    var settled = false;
    final waiting = writes.settle(const Duration(seconds: 5)).then((v) => settled = v);

    unawaited(writes.track(() => second.future));
    first.complete();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(settled, isFalse, reason: 'the second write is still running');

    second.complete();
    await waiting;
    expect(settled, isTrue);
  });

  test('a write that throws stops being counted', () async {
    await expectLater(writes.track<void>(() async => throw StateError('copy failed')), throwsStateError);
    expect(writes.count, 0);
    expect(await writes.settle(Duration.zero), isTrue);
  });

  group('once closing has begun', () {
    test('a new write never starts, is not counted, and its future does not complete', () async {
      writes.close();
      var ran = false;
      var finished = false;
      unawaited(writes.track(() async => ran = true).then((_) => finished = true));

      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(writes.closing, isTrue);
      expect(ran, isFalse);
      expect(finished, isFalse);
      expect(writes.count, 0);
      expect(await writes.settle(Duration.zero), isTrue);
    });

    test('a write already running still runs its own steps to the end', () async {
      final halfway = Completer<void>();
      final carryOn = Completer<void>();
      var stepRan = false;
      final running = writes.track(() async {
        halfway.complete();
        await carryOn.future;
        await writes.track(() async => stepRan = true);
      });

      await halfway.future;
      writes.close();
      final waiting = writes.settle(const Duration(seconds: 5));
      carryOn.complete();

      expect(await waiting, isTrue);
      await running;
      expect(stepRan, isTrue);
    });
  });

  test('a write whileWritingMod is asked for once closing has begun marks nothing', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    WritesInFlight.shared.close();
    addTearDown(WritesInFlight.shared.reopenForTests);
    var ran = false;

    unawaited(whileWritingMod(container, 'Ellen', () async => ran = true));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(ran, isFalse);
    expect(container.read(modWritesInProgressProvider), isEmpty, reason: 'a switch press on the mod would wait for it');
    expect(container.read(modWritesStartedProvider), isEmpty);
  });

  test('every write whileWritingMod marks is counted', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final before = WritesInFlight.shared.count;

    final held = holdWrite(container, 'Ellen');
    expect(WritesInFlight.shared.count, before + 1);

    await held.release();
    expect(WritesInFlight.shared.count, before);
  });
}
