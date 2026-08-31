/// Turning a [LogRecord] into a line, twice: one for a file somebody will grep
/// six months from now, one for a terminal somebody is watching right now.
///
/// The two have different jobs and so they are different functions:
///
/// - **[formatForFile]** is complete and machine-friendly. Full timestamp with
///   offset, fixed-width level, the whole dotted source, every field, and the
///   exception and stack on their own indented lines. Nothing is elided, because
///   the thing it is for is a question nobody has thought to ask yet.
/// - **[formatForTerminal]** is short. Time only, the first segment of the
///   source, fields in parentheses, the exception on one line and **no stack
///   unless it is critical**. A wall of stack traces during development is how a
///   terminal stops being read at all.
///
/// Pure — strings in, strings out — which is what lets the awkward cases (a
/// field value containing a space, a null, an exception with no message) be
/// pinned by tests rather than discovered in a log.
library;

import 'log_level.dart';
import 'log_record.dart';

/// Which rendering a sink wants. A sink declares this rather than calling the
/// formatter itself, so redaction can sit between the two — see `logger.dart`.
enum LogFormat { file, terminal }

String formatRecord(LogRecord record, LogFormat format) => switch (format) {
      LogFormat.file => formatForFile(record),
      LogFormat.terminal => formatForTerminal(record),
    };

String formatForFile(LogRecord record) {
  final line = StringBuffer()
    ..write(formatTimestamp(record.time))
    ..write(' ')
    ..write(record.level.label.padRight(5))
    ..write(' ')
    ..write(record.source)
    ..write('  ')
    ..write(record.message);

  final fields = formatFields(record.fields);
  if (fields.isNotEmpty) line.write(' $fields');

  if (record.error != null) {
    line.write('\n    ${describeError(record.error)}');
  }
  if (record.stackTrace != null) {
    for (final frame in _stackLines(record.stackTrace!)) {
      line.write('\n      $frame');
    }
  }
  return line.toString();
}

String formatForTerminal(LogRecord record) {
  final line = StringBuffer()
    ..write(_clockOnly(record.time))
    ..write(' ')
    ..write(record.level.label.padRight(5))
    ..write(' ')
    ..write(record.source.split('.').first)
    ..write('  ')
    ..write(record.message);

  final fields = formatFields(record.fields);
  if (fields.isNotEmpty) line.write(' ($fields)');

  if (record.error != null) {
    line.write(' — ${describeError(record.error)}');
  }
  // Only the level that means "the app has no answer for this" is worth a stack
  // in a terminal; everything else is readable without one and the file has it.
  if (record.stackTrace != null && record.level == LogLevel.critical) {
    for (final frame in _stackLines(record.stackTrace!)) {
      line.write('\n      $frame');
    }
  }
  return line.toString();
}

/// `key=value` pairs, space separated, in the order the caller wrote them.
///
/// A value containing a space, a quote or an `=` is quoted, because the whole
/// point of `key=value` is that a reader — or an `awk` — can split on it. A
/// **null is rendered rather than dropped**: `mod_id=null` is a fact about a mod
/// with no tracking, and dropping it would make the absent case indistinguishable
/// from a caller who forgot the field.
String formatFields(Map<String, Object?> fields) {
  if (fields.isEmpty) return '';
  final parts = <String>[];
  for (final entry in fields.entries) {
    parts.add('${entry.key}=${_value(entry.value)}');
  }
  return parts.join(' ');
}

String _value(Object? value) {
  if (value == null) return 'null';
  if (value is Duration) return '${value.inMilliseconds}ms';
  final text = value.toString();
  if (text.isEmpty) return '""';
  if (text.contains(' ') || text.contains('"') || text.contains('=')) {
    return '"${text.replaceAll('"', r'\"')}"';
  }
  return text;
}

/// The exception as one line, with its type in front.
///
/// The type is worth more than the message here and is the half that goes
/// missing: `GbFormatException: Unexpected end of input` says which layer
/// decided, where the message alone could have come from anywhere.
String describeError(Object? error) {
  if (error == null) return '';
  final text = error.toString().replaceAll('\n', ' ');
  final type = error.runtimeType.toString();
  // Dart's own exceptions already stringify with their type in front; adding a
  // second copy of it is noise.
  return text.startsWith(type) ? text : '$type: $text';
}

/// ISO-8601 local time **with the offset**, because a log read a week later in
/// another timezone is otherwise a guess.
///
/// A `DateTime.utc` renders as `+00:00`, which is what makes this testable — a
/// test asserting a formatted line must not depend on the machine's timezone.
String formatTimestamp(DateTime time) {
  final offset = time.timeZoneOffset;
  final sign = offset.isNegative ? '-' : '+';
  final abs = offset.abs();
  final hours = abs.inHours.toString().padLeft(2, '0');
  final minutes = (abs.inMinutes % 60).toString().padLeft(2, '0');
  // `toIso8601String` appends `Z` on a UTC instant, which would contradict the
  // offset we are about to write.
  final stamp = time.toIso8601String().replaceFirst(RegExp(r'Z$'), '');
  return '$stamp$sign$hours:$minutes';
}

String _clockOnly(DateTime time) {
  final h = time.hour.toString().padLeft(2, '0');
  final m = time.minute.toString().padLeft(2, '0');
  final s = time.second.toString().padLeft(2, '0');
  return '$h:$m:$s';
}

/// The first frames only.
///
/// A Flutter stack is routinely 60 frames of framework internals; the top eight
/// carry the answer and the rest costs kilobytes per line in a file that has a
/// size cap. The count is stated here rather than tuned per call site.
const int _stackFrames = 8;

Iterable<String> _stackLines(StackTrace stack) => stack
    .toString()
    .split('\n')
    .where((line) => line.trim().isNotEmpty)
    .take(_stackFrames);
