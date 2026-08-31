import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/services/log/log_format.dart';
import 'package:mod_manager_flutter/services/log/log_level.dart';
import 'package:mod_manager_flutter/services/log/log_record.dart';
import 'package:mod_manager_flutter/services/log/log_redaction.dart';
import 'package:mod_manager_flutter/services/log/log_rotation.dart';
import 'package:mod_manager_flutter/services/log/log_sinks.dart';
import 'package:mod_manager_flutter/services/log/logger.dart';

/// The file sink and the router: the parts that touch a disk, and the wiring
/// between them.
///
/// The rule every case here is really testing is the same one: **the logger may
/// never take the app down, and may never publish a username.** A sink that
/// cannot write turns itself off; a router hands out nothing that has not been
/// through the redactor.
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('log_sinks_test_');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Directory logs() => Directory('${tmp.path}${Platform.pathSeparator}logs');

  LogRecord record(
    String message, {
    LogLevel level = LogLevel.info,
    Map<String, Object?> fields = const {},
    Object? error,
  }) =>
      LogRecord(
        time: DateTime.utc(2026, 8, 31, 14, 2, 11),
        level: level,
        source: 'test',
        message: message,
        fields: fields,
        error: error,
      );

  FileLogSink sink({
    DateTime? when,
    int keep = 7,
    int maxBytes = 16 * 1024 * 1024,
    IOSink Function(File)? openSink,
    void Function(String)? onDisabled,
  }) =>
      FileLogSink(
        directory: logs(),
        now: () => when ?? DateTime(2026, 8, 31, 14, 2, 11),
        keep: keep,
        maxBytes: maxBytes,
        lineEnding: '\n',
        openSink: openSink,
        onDisabled: onDisabled,
      );

  List<File> logFiles() => logs().existsSync()
      ? (logs().listSync().whereType<File>().toList()
        ..sort((a, b) => a.path.compareTo(b.path)))
      : <File>[];

  group('writing', () {
    test('creates the directory on the first line, not before', () async {
      final file = sink();
      expect(logs().existsSync(), isFalse,
          reason: 'a session that logs nothing leaves nothing behind');

      file.write(record('hello'), 'hello');
      await file.close();

      expect(logFiles(), hasLength(1));
      expect(logFiles().single.readAsStringSync(), 'hello\n');
    });

    test('appends, in order', () async {
      final file = sink();
      for (final line in ['one', 'two', 'three']) {
        file.write(record(line), line);
      }
      await file.close();

      expect(logFiles().single.readAsLinesSync(), ['one', 'two', 'three']);
    });

    test('the line ending is the platform\'s, and is injectable', () async {
      // A Windows log gets CRLF so it opens as a log rather than as one very
      // long line. Injectable so this can be asserted from Linux.
      final windows = FileLogSink(
        directory: logs(),
        now: () => DateTime(2026, 8, 31, 14, 2, 11),
        lineEnding: '\r\n',
      );
      windows.write(record('hello'), 'hello');
      await windows.close();

      expect(logFiles().single.readAsStringSync(), 'hello\r\n');
    });

    test('two sessions in the same second do not share a file', () async {
      final first = sink()..write(record('a'), 'a');
      await first.close();
      final second = sink()..write(record('b'), 'b');
      await second.close();

      expect(logFiles(), hasLength(2));
    });
  });

  group('rotation on the disk', () {
    test('pruning happens at open, so the cap holds after a crash', () async {
      // Eight sessions that each died without closing cleanly.
      for (var hour = 1; hour <= 8; hour++) {
        sink(when: DateTime(2026, 8, 31, hour)).write(record('x'), 'x');
      }

      expect(logFiles(), hasLength(7));
      expect(
        logFiles().first.path,
        contains('02-00-00'),
        reason: 'the 01:00 session was the one evicted',
      );
    });

    test('a file that is not ours is left where it is', () async {
      logs().createSync(recursive: true);
      final note = File('${logs().path}${Platform.pathSeparator}notes.txt')
        ..writeAsStringSync('mine');
      for (var hour = 1; hour <= 9; hour++) {
        sink(when: DateTime(2026, 8, 31, hour)).write(record('x'), 'x');
      }

      expect(note.existsSync(), isTrue);
    });
  });

  group('when the disk will not have it', () {
    test('an open that throws disables the sink and says so once', () async {
      final reasons = <String>[];
      final file = sink(
        openSink: (_) => throw const FileSystemException('read-only'),
        onDisabled: reasons.add,
      );

      for (var i = 0; i < 100; i++) {
        file.write(record('line $i'), 'line $i');
      }

      expect(reasons, hasLength(1), reason: 'reported once, not per line');
      expect(reasons.single, contains('could not open'));
    });

    test('a write that throws disables the sink rather than the app', () async {
      final reasons = <String>[];
      final file = sink(
        openSink: (_) => _ThrowingSink(),
        onDisabled: reasons.add,
      );

      expect(() => file.write(record('x'), 'x'), returnsNormally);
      expect(reasons.single, contains('write failed'));
    });

    test('a stream that fails later is caught too', () async {
      // The failure most easily missed: a disk that fills mid-session reports
      // on `IOSink.done`, never at the call that wrote the line.
      final reasons = <String>[];
      final failing = _LateFailingSink();
      final file = sink(openSink: (_) => failing, onDisabled: reasons.add);

      file.write(record('x'), 'x');
      failing.fail();
      await Future<void>.delayed(Duration.zero);

      expect(reasons.single, contains('stream failed'));
    });

    test('the size cap stops this session and spares the others', () async {
      final earlier = sink(when: DateTime(2026, 8, 31, 1))
        ..write(record('old'), 'old');
      await earlier.close();

      final file = sink(when: DateTime(2026, 8, 31, 2), maxBytes: 64);
      for (var i = 0; i < 50; i++) {
        file.write(record('x' * 20), 'x' * 20);
      }
      await file.close();

      final capped = logFiles().last;
      expect(capped.lengthSync(), lessThan(200),
          reason: 'it stopped rather than rolling into a second file');
      expect(logFiles().first.readAsStringSync(), 'old\n',
          reason: 'a runaway session must not evict the history');
    });
  });

  group('the router', () {
    test('gives every sink a redacted line', () {
      final memory = MemoryLogSink();
      final router = LogRouter(
        sinks: [memory],
        redactor: LogRedactor(home: '/home/ralkey', username: 'ralkey'),
      );

      router.add(record('wrote', fields: {'path': '/home/ralkey/mods/Ellen'}));

      expect(memory.lines.single, contains('path=~/mods/Ellen'));
      expect(memory.lines.single, isNot(contains('ralkey')));
    });

    test('an exception is redacted too, since the line is what is censored',
        () {
      final memory = MemoryLogSink();
      final router = LogRouter(
        sinks: [memory],
        redactor: LogRedactor(home: '/home/ralkey', username: 'ralkey'),
      );

      router.add(record(
        'could not write',
        level: LogLevel.error,
        error: const FileSystemException(
          'Cannot open file',
          '/home/ralkey/.local/share/zzz-mod-manager/config.json',
        ),
      ));

      expect(memory.lines.single, isNot(contains('ralkey')));
      expect(memory.lines.single, contains('~/.local/share'));
    });

    test('a sink below the threshold is skipped', () {
      final quiet = MemoryLogSink();
      final router = LogRouter(sinks: [_Thresholded(quiet, LogLevel.warning)]);

      router.add(record('chatter', level: LogLevel.debug));
      router.add(record('trouble', level: LogLevel.warning));

      expect(quiet.lines, hasLength(1));
      expect(quiet.lines.single, contains('trouble'));
    });

    test('a sink that throws does not take the caller down', () {
      final router = LogRouter(sinks: [_ThrowingLogSink()]);

      expect(() => router.add(record('x')), returnsNormally);
    });

    test('the memory sink keeps only the most recent lines', () {
      final memory = MemoryLogSink(capacity: 3);
      final router = LogRouter(sinks: [memory]);

      for (var i = 0; i < 10; i++) {
        router.add(record('line $i'));
      }

      expect(memory.lines, hasLength(3));
      expect(memory.lines.last, contains('line 9'));
    });
  });

  group('the static entry point', () {
    tearDown(() => Log.install(LogRouter(sinks: [])));

    test('logs before anything is installed, rather than throwing', () {
      Log.install(LogRouter(sinks: []));
      expect(() => Log.of('early').info('before main'), returnsNormally);
    });

    test('a Logger built before install still reaches the new router', () {
      // The subtle one. Loggers are `final` top-level fields, initialised once
      // and long before `main()` swaps the router in. A `Logger` that captured
      // the router at construction would send every line to the throwaway
      // default for the life of the app — and every test would still pass.
      const early = Logger('built.early');
      final memory = MemoryLogSink();

      Log.install(LogRouter(sinks: [memory]));
      early.info('after install');

      expect(memory.lines.single, contains('after install'));
    });

    test('recent lines come from the memory sink, already redacted', () {
      final memory = MemoryLogSink();
      Log.install(LogRouter(
        sinks: [memory],
        redactor: LogRedactor(home: '/home/ralkey', username: 'ralkey'),
      ));

      Log.of('test').info('scan', fields: {'path': '/home/ralkey/mods'});

      expect(Log.recent.single, contains('~/mods'));
      expect(Log.recent.single, isNot(contains('ralkey')));
    });
  });

  test('the name of the file is the moment it was opened', () {
    expect(
      logFileName(DateTime(2026, 8, 31, 14, 2, 11)),
      'zzz-mod-manager_2026-08-31_14-02-11.log',
    );
  });
}

class _ThrowingSink implements IOSink {
  @override
  void write(Object? object) => throw const FileSystemException('no space');

  @override
  Future<void> get done => Completer<void>().future;

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _LateFailingSink implements IOSink {
  final Completer<void> _done = Completer<void>();

  void fail() => _done.completeError(const FileSystemException('disk full'));

  @override
  void write(Object? object) {}

  @override
  Future<void> get done => _done.future;

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ThrowingLogSink extends LogSink {
  @override
  LogFormat get format => LogFormat.file;

  @override
  LogLevel get threshold => LogLevel.debug;

  @override
  void write(LogRecord record, String line) => throw StateError('broken sink');
}

/// A sink that only accepts [threshold] and above, delegating everything else.
class _Thresholded extends LogSink {
  _Thresholded(this._inner, this.threshold);

  final MemoryLogSink _inner;

  @override
  final LogLevel threshold;

  @override
  LogFormat get format => _inner.format;

  @override
  void write(LogRecord record, String line) => _inner.write(record, line);
}
