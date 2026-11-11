import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/utils/serial_queue.dart';

void main() {
  test('runs each action once the one before it has ended', () async {
    final queue = SerialQueue();
    final first = Completer<void>();
    final order = <String>[];

    final a = queue.run(() async {
      order.add('a starts');
      await first.future;
      order.add('a ends');
      return 1;
    });
    final b = queue.run(() async {
      order.add('b starts');
      return 2;
    });

    await Future<void>.delayed(Duration.zero);
    expect(order, ['a starts']);

    first.complete();
    expect(await a, 1);
    expect(await b, 2);
    expect(order, ['a starts', 'a ends', 'b starts']);
  });

  test('an action that fails reports its error and does not stop the next', () async {
    final queue = SerialQueue();
    final failing = queue.run<void>(() async => throw StateError('broken'));
    final next = queue.run(() async => 'ran');

    await expectLater(failing, throwsStateError);
    expect(await next, 'ran');
  });
}
