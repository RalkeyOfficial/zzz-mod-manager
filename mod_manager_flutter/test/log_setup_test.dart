import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/services/log/log_setup.dart';
import 'package:mod_manager_flutter/services/log/logger.dart';

/// Bootstrap: the shape the app really runs with, and the setting it has to
/// honour before the thing that owns settings exists.
void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('log_setup_test_'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    Log.install(LogRouter(sinks: []));
  });

  File config(String contents) =>
      File('${tmp.path}${Platform.pathSeparator}config.json')
        ..writeAsStringSync(contents);

  Directory logs() => Directory('${tmp.path}${Platform.pathSeparator}logs');

  group('reading the setting off the disk', () {
    test('a config saying no means no', () {
      expect(
        readFileLoggingFromDisk(configFile: config('{"file_logging": false}')),
        isFalse,
      );
    });

    test('a config saying yes means yes', () {
      expect(
        readFileLoggingFromDisk(configFile: config('{"file_logging": true}')),
        isTrue,
      );
    });

    test('a config that has never heard of it means yes', () {
      expect(readFileLoggingFromDisk(configFile: config('{"theme":"dark"}')),
          isTrue);
    });

    test('no config at all means yes, because that is a first run', () {
      expect(
        readFileLoggingFromDisk(
          configFile: File('${tmp.path}/nothing-here.json'),
        ),
        isTrue,
      );
    });

    test('a corrupt config means yes, because that is worth a log', () {
      // The state a broken install is in, and precisely when somebody wants
      // the file. Failing towards silence here would hide the thing itself.
      expect(readFileLoggingFromDisk(configFile: config('{oh dear')), isTrue);
      expect(readFileLoggingFromDisk(configFile: config('[]')), isTrue);
      expect(
        readFileLoggingFromDisk(configFile: config('{"file_logging": "yes"}')),
        isTrue,
        reason: 'a non-boolean is not an instruction to stop logging',
      );
    });
  });

  group('against this actual machine', () {
    // Every other redaction test supplies its own home and username, which
    // proves the rules and proves nothing about the wiring. This one asks the
    // platform service, like the app does, and is the only test that would
    // catch `homeDirectoryPath` being left unimplemented on one platform.
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'];

    test(
      'the real home directory does not survive into a line',
      () {
        final redact = buildRedactor();

        final line = redact('opened $home/.local/share/zzz-mod-manager');

        expect(line, isNot(contains(home!)));
        expect(line, startsWith('opened ~'));
      },
      skip: home == null ? 'no home directory in this environment' : false,
    );

    test('a real filesystem exception is censored', () {
      // Thrown by the OS, stringified by Dart, with the absolute path baked
      // in by neither of them at our request.
      Object? caught;
      try {
        File('$home/definitely-not-here-${DateTime.now().microsecondsSinceEpoch}')
            .readAsStringSync();
      } catch (error) {
        caught = error;
      }

      Log.install(buildProductionRouter(
        fileLogging: false,
        logsDirectory: logs(),
      ));
      Log.of('test').error('read failed', error: caught);

      expect(Log.recent.single, isNot(contains(home!)));
    }, skip: home == null ? 'no home directory in this environment' : false);
  });

  group('the production router', () {
    test('writes a file when the setting allows it', () async {
      Log.install(buildProductionRouter(
        fileLogging: true,
        logsDirectory: logs(),
        now: () => DateTime(2026, 8, 31, 14, 2, 11),
      ));

      Log.of('test').info('hello');
      // An `info` is buffered on purpose — flushing every line would make a
      // library scan I/O-bound. Only `error` and `critical` force it, and the
      // window-close path does the rest.
      await Log.router.flush();

      final written = logs().listSync().whereType<File>().single;
      expect(written.readAsStringSync(), contains('hello'));
      expect(Log.filePath, written.path);
    });

    test('writes no file at all when the setting forbids it', () {
      Log.install(buildProductionRouter(
        fileLogging: false,
        logsDirectory: logs(),
      ));

      Log.of('test').info('hello');

      expect(logs().existsSync(), isFalse,
          reason: 'off means no file appears, not an empty one');
      expect(Log.filePath, isNull);
    });

    test('still keeps recent lines in memory with the file off', () {
      // "Copy diagnostics" has to work for the user who turned the file off —
      // it is how they report a bug without one.
      Log.install(buildProductionRouter(
        fileLogging: false,
        logsDirectory: logs(),
      ));

      Log.of('test').info('still here');

      expect(Log.recent.single, contains('still here'));
    });

    test('the startup header says what it is censoring', () async {
      Log.install(buildProductionRouter(
        fileLogging: true,
        logsDirectory: logs(),
        now: () => DateTime(2026, 8, 31, 14, 2, 11),
      ));

      logStartupHeader(fileLogging: true);
      await Log.router.flush();

      final text = logs().listSync().whereType<File>().single.readAsStringSync();
      expect(text, contains('app  started'));
      expect(text, contains('version='));
      expect(text, contains('os='));
      expect(text, contains('username_token='),
          reason: 'whether the bare name is censored is stated, not implied');
      expect(
        text,
        isNot(contains('file=off')),
        reason: 'the sink opens on its first write, so the path is only '
            'knowable once something has been written — reporting it too '
            'early says the file is off while writing to it',
      );
      expect(text, contains('logs${Platform.pathSeparator}'),
          reason: 'the header names the file it is in');
    });
  });
}
