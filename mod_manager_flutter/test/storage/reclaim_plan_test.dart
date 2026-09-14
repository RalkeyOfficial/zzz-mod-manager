import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/services/log/log_rotation.dart';
import 'package:mod_manager_flutter/services/storage/reclaim_plan.dart';

final DateTime now = DateTime(2026, 9, 14, 12);

ReclaimCandidate candidate(
  ReclaimTarget target,
  String name, {
  int bytes = 100,
  Duration age = const Duration(days: 30),
  bool isDirectory = false,
}) =>
    ReclaimCandidate(
      target: target,
      path: '/tmp/$name',
      name: name,
      bytes: bytes,
      modified: now.subtract(age),
      isDirectory: isDirectory,
    );

ReclaimPlan plan(
  List<ReclaimCandidate> inventory, {
  bool downloadsBusy = false,
  bool installBusy = false,
  bool libraryReadable = true,
  Set<String> reachable = const <String>{},
  String? currentLog,
}) =>
    planReclaim(
      inventory,
      now: now,
      downloadsBusy: downloadsBusy,
      installBusy: installBusy,
      libraryReadable: libraryReadable,
      reachableLegacyImages: reachable,
      currentLogFile: currentLog,
    );

void main() {
  group('the download gate', () {
    test('an idle queue lets archives and partials go', () {
      final result = plan([
        candidate(ReclaimTarget.completedArchives, 'mod.rar'),
        candidate(ReclaimTarget.abandonedPartials, 'old.rar.part'),
      ]);

      expect(result.remove.length, 2);
      expect(result.skip, isEmpty);
    });

    test('a busy queue refuses both, naming the reason', () {
      final result = plan(
        [
          candidate(ReclaimTarget.completedArchives, 'mod.rar'),
          candidate(ReclaimTarget.abandonedPartials, 'old.rar.part'),
        ],
        downloadsBusy: true,
      );

      expect(result.remove, isEmpty);
      expect(
        result.refusalFor(ReclaimTarget.completedArchives),
        ReclaimSkipReason.downloadsActive,
      );
      expect(
        result.refusalFor(ReclaimTarget.abandonedPartials),
        ReclaimSkipReason.downloadsActive,
      );
    });

    test('a busy queue does not stop the logs or the legacy images', () {
      final result = plan(
        [
          candidate(ReclaimTarget.completedArchives, 'mod.rar'),
          candidate(ReclaimTarget.legacyImages, 'Gone.png'),
          for (var i = 0; i < 9; i++)
            candidate(ReclaimTarget.oldLogs,
                logFileName(DateTime(2026, 1, i + 1))),
        ],
        downloadsBusy: true,
      );

      expect(result.forTarget(ReclaimTarget.legacyImages), isNotEmpty);
      expect(result.forTarget(ReclaimTarget.oldLogs), isNotEmpty);
      expect(result.forTarget(ReclaimTarget.completedArchives), isEmpty);
    });

    test('an install the queue cannot see also closes the gate', () {
      // A drag-in install unpacks with no download job anywhere, so the queue
      // reads idle while an archive is being consumed.
      final result = plan(
        [candidate(ReclaimTarget.completedArchives, 'mod.rar')],
        installBusy: true,
      );

      expect(
        result.refusalFor(ReclaimTarget.completedArchives),
        ReclaimSkipReason.installInProgress,
      );
    });
  });

  group('temp extractions', () {
    test('an old one goes', () {
      final result = plan([
        candidate(ReclaimTarget.tempExtracts, 'zzz_archive_extract_a',
            age: const Duration(hours: 5), isDirectory: true),
      ]);

      expect(result.remove.single.name, 'zzz_archive_extract_a');
    });

    test('one written ten minutes ago is kept', () {
      final result = plan([
        candidate(ReclaimTarget.tempExtracts, 'zzz_archive_extract_a',
            age: const Duration(minutes: 10), isDirectory: true),
      ]);

      expect(result.remove, isEmpty);
      expect(result.skip.single.reason, ReclaimSkipReason.tooRecent);
    });

    test('an install in progress keeps even an old one', () {
      final result = plan(
        [
          candidate(ReclaimTarget.tempExtracts, 'zzz_archive_extract_a',
              age: const Duration(days: 2), isDirectory: true),
        ],
        installBusy: true,
      );

      expect(result.remove, isEmpty);
      expect(result.skip.single.reason, ReclaimSkipReason.installInProgress);
    });

    test('a busy download queue does not hold up temp extractions', () {
      final result = plan(
        [
          candidate(ReclaimTarget.tempExtracts, 'zzz_archive_extract_a',
              age: const Duration(days: 2), isDirectory: true),
        ],
        downloadsBusy: true,
      );

      expect(result.remove, isNotEmpty);
    });
  });

  group('legacy images', () {
    test('an unreachable one goes', () {
      final result = plan([candidate(ReclaimTarget.legacyImages, 'Gone.png')]);

      expect(result.remove.single.name, 'Gone.png');
    });

    test('one a mod still reaches is kept', () {
      final result = plan(
        [candidate(ReclaimTarget.legacyImages, 'Ellen.png')],
        reachable: {'Ellen.png'},
      );

      expect(result.remove, isEmpty);
      expect(result.skip.single.reason, ReclaimSkipReason.stillReferenced);
    });

    test('an unreadable library sweeps none of them', () {
      // The sharpest edge in the feature: reachability is decided against the
      // library, so an empty or unreadable one makes every image look dead and
      // takes the user's only copy of every cover.
      final result = plan(
        [
          candidate(ReclaimTarget.legacyImages, 'Ellen.png'),
          candidate(ReclaimTarget.legacyImages, 'Nicole.png'),
        ],
        libraryReadable: false,
      );

      expect(result.remove, isEmpty);
      expect(
        result.refusalFor(ReclaimTarget.legacyImages),
        ReclaimSkipReason.libraryUnreadable,
      );
    });
  });

  group('logs', () {
    List<ReclaimCandidate> logs(int count) => [
          for (var i = 0; i < count; i++)
            candidate(ReclaimTarget.oldLogs, logFileName(DateTime(2026, 1, i + 1))),
        ];

    test('the seven newest are kept and the rest go', () {
      final result = plan(logs(10));

      expect(result.forTarget(ReclaimTarget.oldLogs).length, 3);
    });

    test('seven or fewer means nothing goes', () {
      final result = plan(logs(7));

      expect(result.forTarget(ReclaimTarget.oldLogs), isEmpty);
    });

    test('the running session\'s own log is never deleted', () {
      // On Linux this delete succeeds, the sink writes on to an unlinked inode,
      // no space comes back, and the user loses the log of the run they are
      // about to report a problem from.
      final all = logs(10);
      final current = all.first.name;

      final result = plan(all, currentLog: current);

      expect(
        result.forTarget(ReclaimTarget.oldLogs).map((c) => c.name),
        isNot(contains(current)),
      );
      expect(
        result.skip.any((s) => s.reason == ReclaimSkipReason.currentSession),
        isTrue,
      );
    });

    test('a file we did not write is left where it is', () {
      // The user is invited into this folder to attach a log to a report, and
      // may well have left something of their own beside it.
      final result = plan([
        ...logs(10),
        candidate(ReclaimTarget.oldLogs, 'notes.txt'),
      ]);

      expect(
        result.forTarget(ReclaimTarget.oldLogs).map((c) => c.name),
        isNot(contains('notes.txt')),
      );
      expect(
        result.skip.any((s) => s.reason == ReclaimSkipReason.notOurs),
        isTrue,
      );
    });
  });

  group('the plan as a whole', () {
    test('reports what it would free', () {
      final result = plan([
        candidate(ReclaimTarget.completedArchives, 'a.rar', bytes: 400),
        candidate(ReclaimTarget.completedArchives, 'b.rar', bytes: 600),
      ]);

      expect(result.reclaimableBytes, 1000);
      expect(result.isEmpty, isFalse);
    });

    test('nothing to do is empty rather than an error', () {
      final result = plan(const []);

      expect(result.isEmpty, isTrue);
      expect(result.reclaimableBytes, 0);
    });

    test('a target that ran reports no refusal, whatever it skipped', () {
      final result = plan([
        candidate(ReclaimTarget.legacyImages, 'Gone.png'),
        candidate(ReclaimTarget.legacyImages, 'Ellen.png'),
      ], reachable: {
        'Ellen.png'
      });

      expect(result.refusalFor(ReclaimTarget.legacyImages), isNull);
      expect(result.remove.length, 1);
    });
  });
}
