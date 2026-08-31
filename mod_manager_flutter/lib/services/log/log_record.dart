/// One thing that happened, as data.
///
/// Deliberately a value type with no rendering on it: `log_format.dart` turns it
/// into a line, and there are two different renderings of the same record (the
/// file's and the terminal's). A record that knew how to print itself would only
/// know one of them.
///
/// **[fields] is the whole reason this exists** rather than a formatted string at
/// the call site. `'empty body, retrying'` plus `{status: 200, bytes: 0, url: …}`
/// stays greppable and stays aligned; the same information interpolated into a
/// sentence is neither. The rule for a call site is: **the message says what
/// happened, the fields say what it happened to.** The same split the
/// notification API already uses for title and body.
library;

import 'log_level.dart';

class LogRecord {
  LogRecord({
    required this.time,
    required this.level,
    required this.source,
    required this.message,
    this.fields = const <String, Object?>{},
    this.error,
    this.stackTrace,
  });

  final DateTime time;
  final LogLevel level;

  /// The area this came from, dotted: `gamebanana.client`, `download.queue`,
  /// `update.apply`. See `docs/logging.md` for the list and the rule for
  /// picking one.
  final String source;

  /// What happened. A short phrase, lower case, no trailing period, and **no
  /// interpolated values** — those are [fields].
  final String message;

  /// What it happened to. Values are rendered by `log_format.dart`, so a caller
  /// passes the value itself rather than a string of it.
  final Map<String, Object?> fields;

  /// The exception, when there was one. Never interpolated into [message] — the
  /// formatter decides how an exception is rendered, so that decision is made
  /// once instead of at 200 call sites.
  final Object? error;

  final StackTrace? stackTrace;
}
