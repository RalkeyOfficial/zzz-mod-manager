/// How the rest of the app says what it is doing.
///
/// ```dart
/// final _log = Logger('gamebanana.client');
///
/// _log.debug('request', fields: {'url': url, 'cache': 'miss'});
/// _log.warning('empty body, retrying', fields: {'status': 200, 'attempt': 1});
/// _log.error('extraction failed', error: e, stack: s);
/// ```
///
/// ## Three decisions worth knowing before using it
///
/// **It is synchronous.** `FlutterError.onError` is a sync callback and
/// `PlatformDispatcher.instance.onError` must *return a bool*; a logger that had
/// to be awaited could not be used from either, which is to say it could not be
/// used for crashes. Awaiting would also insert a suspension point into every
/// caller — a behaviour change caused by adding a log line. The asynchrony lives
/// inside `IOSink`, where it belongs.
///
/// **An uninitialised `Log` is a working `Log`.** [Log.router] builds a
/// terminal-only router on first use, so a unit test that logs needs no setup,
/// no call site needs a null check, and a converted `print` in a pure function
/// still prints. Only `main()` calls [Log.install].
///
/// **A `Logger` resolves the router on every call** rather than capturing one.
/// Loggers are `final` fields at the top of a file, initialised lazily but
/// exactly once — capture the router there and every one of them would be bound
/// to the terminal-only default that existed before `main()` swapped it, and
/// nothing would ever reach the file. Every test would still pass.
library;

import '../../utils/path_helper.dart';
import 'log_format.dart';
import 'log_level.dart';
import 'log_record.dart';
import 'log_redaction.dart';
import 'log_sinks.dart';

/// A source tag bound to the app's current router.
class Logger {
  const Logger(this.source);

  /// Dotted, and from the list in `docs/logging.md` — `gamebanana.client`,
  /// `download.queue`, `update.apply`. One per file, declared at the top.
  final String source;

  void debug(String message, {Map<String, Object?>? fields}) =>
      _emit(LogLevel.debug, message, fields);

  void info(String message, {Map<String, Object?>? fields}) =>
      _emit(LogLevel.info, message, fields);

  void warning(
    String message, {
    Map<String, Object?>? fields,
    Object? error,
    StackTrace? stack,
  }) =>
      _emit(LogLevel.warning, message, fields, error, stack);

  void error(
    String message, {
    Object? error,
    StackTrace? stack,
    Map<String, Object?>? fields,
  }) =>
      _emit(LogLevel.error, message, fields, error, stack);

  void critical(
    String message, {
    Object? error,
    StackTrace? stack,
    Map<String, Object?>? fields,
  }) =>
      _emit(LogLevel.critical, message, fields, error, stack);

  /// For a caller that already holds a level — a severity mapped in from
  /// somewhere else, like a notification's. Everywhere else, use the named
  /// methods: a literal level at a call site is a decision made twice.
  void at(
    LogLevel level,
    String message, {
    Map<String, Object?>? fields,
    Object? error,
    StackTrace? stack,
  }) =>
      _emit(level, message, fields, error, stack);

  void _emit(
    LogLevel level,
    String message, [
    Map<String, Object?>? fields,
    Object? error,
    StackTrace? stack,
  ]) {
    // `Log.router` here, never a captured field — see the library note.
    final router = Log.router;
    router.add(LogRecord(
      time: router.now(),
      level: level,
      source: source,
      message: message,
      fields: fields ?? const <String, Object?>{},
      error: error,
      stackTrace: stack,
    ));
  }
}

/// Renders, censors, and hands the result to every sink that wants it.
class LogRouter {
  LogRouter({
    List<LogSink>? sinks,
    LogRedactor? redactor,
    DateTime Function()? now,
  })  :
        // **Quiet by default**, because the default router is the one nobody
        // installed: a unit test, a pure function, anything running before
        // `main()`. Debug lines there are noise in a test runner's output, and
        // a test suite that scrolls its own diagnostics past the failures is
        // worse off for having them. Production builds its own sinks and sets
        // its own thresholds.
        sinks = sinks ??
            <LogSink>[TerminalLogSink(threshold: LogLevel.warning)],
        redactor = redactor ?? LogRedactor.pathsOnly,
        now = now ?? DateTime.now;

  final List<LogSink> sinks;

  /// The single point every line passes through on its way out — see
  /// `log_redaction.dart` for why it cannot live at the call sites.
  final LogRedactor redactor;

  final DateTime Function() now;

  void add(LogRecord record) {
    // Rendered at most once per format however many sinks want it, and only
    // for formats something actually asked for.
    String? file;
    String? terminal;

    for (final sink in sinks) {
      if (record.level.index < sink.threshold.index) continue;
      final String line;
      switch (sink.format) {
        case LogFormat.file:
          line = file ??= redactor(formatForFile(record));
        case LogFormat.terminal:
          line = terminal ??= redactor(formatForTerminal(record));
      }
      try {
        sink.write(record, line);
      } catch (_) {
        // A sink that throws out of `write` has already failed at its own job;
        // it must not take the caller's operation down with it.
      }
    }
  }

  Future<void> flush() async {
    for (final sink in sinks) {
      await sink.flush();
    }
  }

  Future<void> close() async {
    for (final sink in sinks) {
      await sink.close();
    }
  }
}

/// The app's one router, and how anything reaches it.
///
/// Static rather than a Riverpod provider because the places that most need to
/// log have no `ref` and no `BuildContext`: `main()` before the binding exists,
/// a plain service, an error handler, a port listener. `PathHelper` is the
/// precedent. The Riverpod registry gets exactly one logging entry — the
/// *setting* — because that is app state.
class Log {
  Log._();

  static LogRouter? _router;

  /// Never null and never throws: the default writes to the terminal only.
  static LogRouter get router => _router ??= LogRouter();

  /// Replaces the router, closing whatever was there. `main()` only.
  static void install(LogRouter router) {
    final previous = _router;
    _router = router;
    if (previous != null) unawaited(previous.close());
  }

  static Logger of(String source) => Logger(source);

  /// The recent lines held in memory, for "Copy diagnostics" — already
  /// redacted, because that is what a [MemoryLogSink] stores.
  static List<String> get recent {
    for (final sink in router.sinks) {
      if (sink is MemoryLogSink) return sink.lines;
    }
    return const <String>[];
  }

  /// The folder the logs live in — **uncensored**, because this is what gets
  /// handed to a file manager rather than written into a file.
  static String get logsDirectory {
    for (final sink in router.sinks) {
      if (sink is FileLogSink) return sink.directory.path;
    }
    // Nothing has been written this session (the setting is off), and the
    // folder is still where the previous seven runs left their files.
    return PathHelper.getLogsPath();
  }

  /// The file this session is writing to, if any.
  static String? get filePath {
    for (final sink in router.sinks) {
      if (sink is FileLogSink) return sink.file?.path;
    }
    return null;
  }

  /// Flush and close every sink. Called when the window is closing, where
  /// otherwise the tail of every clean exit is lost.
  static Future<void> shutdown() => router.close();

  /// Starts or stops writing to a file, without restarting the app.
  ///
  /// **Turning it off closes the file and leaves it on disk.** Deleting
  /// somebody's logs as a side effect of a toggle would throw away the very
  /// thing they may be about to attach to a report; the folder button is how
  /// they remove them.
  ///
  /// Turning it on opens a **new** file, with its own header, rather than
  /// appending to whatever the last session left. The alternative is a file
  /// whose header describes a run that already ended.
  static void setFileSink(FileLogSink? sink) {
    final sinks = router.sinks;
    final existing = sinks.whereType<FileLogSink>().toList();
    for (final old in existing) {
      unawaited(old.close());
      sinks.remove(old);
    }
    if (sink != null) sinks.add(sink);
  }

  /// Whether this session is writing to a file right now.
  static bool get writesToFile =>
      router.sinks.whereType<FileLogSink>().isNotEmpty;
}
