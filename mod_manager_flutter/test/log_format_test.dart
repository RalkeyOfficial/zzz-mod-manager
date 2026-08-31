import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/services/log/log_format.dart';
import 'package:mod_manager_flutter/services/log/log_level.dart';
import 'package:mod_manager_flutter/services/log/log_record.dart';

/// The two renderings.
///
/// A `DateTime.utc` throughout, so the offset is `+00:00` and a machine in
/// another timezone gets the same answer — a formatting test that depends on
/// where it runs is a test that fails on somebody else's laptop.
void main() {
  LogRecord record({
    LogLevel level = LogLevel.info,
    String source = 'gamebanana.client',
    String message = 'request',
    Map<String, Object?> fields = const {},
    Object? error,
    StackTrace? stack,
  }) =>
      LogRecord(
        time: DateTime.utc(2026, 8, 31, 14, 2, 11, 882),
        level: level,
        source: source,
        message: message,
        fields: fields,
        error: error,
        stackTrace: stack,
      );

  group('the file line', () {
    test('leads with a sortable timestamp carrying its offset', () {
      expect(
        formatForFile(record()),
        startsWith('2026-08-31T14:02:11.882+00:00'),
      );
    });

    test('puts the level in a fixed-width column so the file greps', () {
      final lines = [
        for (final level in LogLevel.values) formatForFile(record(level: level)),
      ];
      final columns = [
        for (final line in lines) line.substring(30, 35),
      ];

      expect(columns, ['DEBUG', 'INFO ', 'WARN ', 'ERROR', 'CRIT ']);
    });

    test('carries the whole dotted source and the message', () {
      expect(
        formatForFile(record()),
        contains('gamebanana.client  request'),
      );
    });

    test('renders fields as key=value in the order they were given', () {
      expect(
        formatForFile(record(fields: {'url': '/Mod/1', 'status': 200})),
        endsWith('request url=/Mod/1 status=200'),
      );
    });

    test('the exception goes on its own line, with its type', () {
      final line = formatForFile(record(
        level: LogLevel.error,
        message: 'parse failed',
        error: const FormatException('Unexpected end of input'),
      ));

      expect(line.split('\n'), hasLength(2));
      expect(line, contains('FormatException: Unexpected end of input'));
    });

    test('a stack follows the exception, truncated', () {
      final line = formatForFile(record(
        level: LogLevel.error,
        error: StateError('x'),
        stack: StackTrace.fromString(
          List.generate(40, (i) => '#$i      frame$i').join('\n'),
        ),
      ));

      expect(line.split('\n'), hasLength(10),
          reason: 'the message, the exception, and eight frames');
      expect(line, contains('#7'));
      expect(line, isNot(contains('#9')),
          reason: 'a 40-frame Flutter stack would eat the size cap');
    });
  });

  group('field values', () {
    String fields(Map<String, Object?> f) => formatFields(f);

    test('a value with a space is quoted, so a reader can still split on =',
        () {
      expect(fields({'mod': 'Ellen Bikini'}), 'mod="Ellen Bikini"');
    });

    test('a value containing = or a quote is quoted and escaped', () {
      expect(fields({'q': 'a=b'}), 'q="a=b"');
      expect(fields({'q': 'say "hi"'}), r'q="say \"hi\""');
    });

    test('null is written, not dropped', () {
      // `mod_id=null` is a fact about an untracked mod. Dropping it would make
      // that indistinguishable from a caller who forgot the field.
      expect(fields({'mod_id': null}), 'mod_id=null');
    });

    test('an empty string is visible', () {
      expect(fields({'name': ''}), 'name=""');
    });

    test('a duration reads as milliseconds', () {
      expect(fields({'took': const Duration(milliseconds: 284)}), 'took=284ms');
    });

    test('no fields render to nothing at all', () {
      expect(formatForFile(record()), endsWith('request'));
    });
  });

  group('the terminal line', () {
    test('is time, level, the first segment of the source, and the message',
        () {
      expect(
        formatForTerminal(record()),
        '14:02:11 INFO  gamebanana  request',
      );
    });

    test('puts fields in parentheses', () {
      expect(
        formatForTerminal(record(fields: {'status': 200})),
        endsWith('request (status=200)'),
      );
    });

    test('keeps an exception to one line', () {
      final line = formatForTerminal(record(
        level: LogLevel.error,
        error: const FormatException('bad'),
        stack: StackTrace.fromString('#0  frame'),
      ));

      expect(line.split('\n'), hasLength(1),
          reason: 'a wall of stacks is how a terminal stops being read');
      expect(line, contains('— FormatException: bad'));
    });

    test('shows a stack only when the app has no answer at all', () {
      final line = formatForTerminal(record(
        level: LogLevel.critical,
        error: StateError('x'),
        stack: StackTrace.fromString('#0  frame'),
      ));

      expect(line, contains('#0  frame'));
    });
  });

  group('an exception whose text already names its type', () {
    test('is not given a second copy of it', () {
      // Dart's own exceptions stringify with the type in front.
      expect(
        describeError(const FormatException('x')),
        'FormatException: x',
      );
    });

    test('a bare string gets its type, so the layer that threw is visible', () {
      expect(describeError('something went wrong'),
          'String: something went wrong');
    });

    test('a multi-line message is flattened, so a record is one line', () {
      expect(describeError(StateError('one\ntwo')), isNot(contains('\n')));
    });
  });
}
