import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/services/log/log_rotation.dart';

void main() {
  String at(int hour, {int collision = 0}) => logFileName(
        DateTime(2026, 8, 31, hour, 0, 0),
        collision: collision,
      );

  group('the name', () {
    test('sorts chronologically as plain text', () {
      final names = [at(23), at(1), at(9)]..sort();
      expect(names, [at(1), at(9), at(23)]);
    });

    test('a second file in the same second is a distinct name', () {
      // Two launches from a double-click, or a crash loop relaunching.
      expect(at(9, collision: 1), isNot(at(9)));
      expect(isLogFileName(at(9, collision: 1)), isTrue);
    });

    test('recognises only what this app writes', () {
      expect(isLogFileName(at(9)), isTrue);
      expect(isLogFileName('notes.txt'), isFalse);
      expect(isLogFileName('zzz-mod-manager_2026-08-31.log'), isFalse);
      expect(isLogFileName('zzz-mod-manager_old.log'), isFalse);
      expect(isLogFileName('crash.dmp'), isFalse);
    });
  });

  group('planning the prune', () {
    test('room to spare deletes nothing', () {
      expect(planLogRotation([at(1), at(2), at(3)], keep: 7), isEmpty);
    });

    test('six existing and one about to open is exactly full', () {
      final six = [for (var h = 1; h <= 6; h++) at(h)];
      expect(planLogRotation(six, keep: 7), isEmpty);
    });

    test('seven existing deletes the oldest, because the new one counts',
        () {
      // The off-by-one. `keep` includes the file that is about to be created,
      // so a full directory has to give one up before the open, not after.
      final seven = [for (var h = 1; h <= 7; h++) at(h)];

      expect(planLogRotation(seven, keep: 7), [at(1)]);
    });

    test('a long-neglected directory is brought down in one pass', () {
      final twenty = [for (var h = 1; h <= 20; h++) at(h)];

      final deleted = planLogRotation(twenty, keep: 7);

      expect(deleted, hasLength(14));
      expect(deleted.last, at(14));
      expect(deleted, isNot(contains(at(15))),
          reason: 'the six newest survive alongside the new one',
      );
    });

    test('order comes from the name, not the order it was listed in', () {
      // `Directory.list` gives no ordering guarantee at all.
      final shuffled = [at(5), at(1), at(7), at(3), at(2), at(6), at(4)];

      expect(planLogRotation(shuffled, keep: 7), [at(1)]);
    });
  });

  group('files that are not ours', () {
    test('are never deleted', () {
      final names = [
        for (var h = 1; h <= 9; h++) at(h),
        'notes.txt',
        'crash.dmp',
        'zzz-mod-manager_old.log',
      ];

      final deleted = planLogRotation(names, keep: 7);

      expect(deleted, isNot(contains('notes.txt')));
      expect(deleted, isNot(contains('crash.dmp')));
      expect(deleted, isNot(contains('zzz-mod-manager_old.log')));
    });

    test('are not counted towards the cap either', () {
      // Otherwise a user who left three files in the folder would silently lose
      // three sessions of history.
      final names = [
        for (var h = 1; h <= 6; h++) at(h),
        'notes.txt',
        'crash.dmp',
        'a copy of the log I sent.log',
      ];

      expect(planLogRotation(names, keep: 7), isEmpty);
    });
  });

  group('planLogReclaim', () {
    test('takes every file but the running one, however few there are', () {
      final names = [for (var h = 1; h <= 3; h++) at(h)];

      expect(planLogReclaim(names, current: at(3)), [at(1), at(2)]);
    });

    test('takes the whole folder when nothing is running', () {
      final names = [for (var h = 1; h <= 10; h++) at(h)];

      expect(planLogReclaim(names), hasLength(10));
    });

    test('never the running session, even when it is the oldest', () {
      // On Linux this delete succeeds, the sink writes on to an unlinked inode,
      // the space comes back only at exit, and the user loses the log of the
      // run they are about to report a problem from.
      final names = [for (var h = 1; h <= 10; h++) at(h)];

      final deleted = planLogReclaim(names, current: at(1));

      expect(deleted, isNot(contains(at(1))));
      expect(deleted, hasLength(9));
    });

    test('leaves a file we did not write where it is', () {
      final names = [for (var h = 1; h <= 10; h++) at(h), 'notes.txt'];

      expect(planLogReclaim(names), isNot(contains('notes.txt')));
    });
  });
}
