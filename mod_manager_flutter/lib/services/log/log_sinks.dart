/// Where a line ends up: a terminal somebody is watching, or a file somebody
/// will attach to a bug report.
///
/// **A sink is handed a line that is already rendered and already redacted.**
/// It chooses only *which* rendering it wants ([LogSink.format]) and what to do
/// with it. That is what keeps redaction to a single call in `logger.dart`
/// instead of one per sink, and it is why a new sink cannot leak a username by
/// forgetting something.
///
/// Both sinks share one posture, and it is not negotiable: **the logger may
/// never take the app down.** Everything that touches the terminal or the disk
/// is wrapped, and a sink that fails turns itself off and says so once. The
/// thing being logged is frequently a failure already; a logger that throws
/// during one is how a recoverable problem becomes a crash.
library;

import 'dart:io';

import 'log_format.dart';
import 'log_level.dart';
import 'log_record.dart';
import 'log_rotation.dart';

abstract class LogSink {
  /// Which rendering this sink is given.
  LogFormat get format;

  /// The lowest level this sink accepts.
  LogLevel get threshold;

  /// [line] is rendered per [format] and already redacted.
  void write(LogRecord record, String line);

  Future<void> flush() async {}

  Future<void> close() async {}
}

/// The developer's terminal: short lines, colour when it is a real terminal.
///
/// **`stdout.writeln`, deliberately not `print` and not `debugPrint`.** `print`
/// is the lint this whole change exists to satisfy, and it would need an ignore
/// in the one file that ought to be exemplary. `debugPrint` is worse: it
/// throttles at ~12.8 KB/s and *defers* the overflow, so a logger built on it
/// reorders and drops its own output during exactly the burst worth reading.
class TerminalLogSink extends LogSink {
  TerminalLogSink({LogLevel? threshold, bool? colour})
      : threshold = threshold ?? LogLevel.debug,
        _colour = colour ?? _terminalSupportsColour();

  @override
  final LogLevel threshold;

  final bool _colour;

  /// A packaged Windows app is a GUI-subsystem process with **no attached
  /// console**, so writing to stdout can throw rather than going nowhere. One
  /// failure is enough to stop trying for the rest of the session.
  bool _usable = true;

  @override
  LogFormat get format => LogFormat.terminal;

  @override
  void write(LogRecord record, String line) {
    if (!_usable) return;
    try {
      stdout.writeln(_colour ? '${_colourFor(record.level)}$line$_reset' : line);
    } catch (_) {
      _usable = false;
    }
  }

  static bool _terminalSupportsColour() {
    try {
      return stdout.hasTerminal && stdout.supportsAnsiEscapes;
    } catch (_) {
      return false;
    }
  }

  static const String _reset = '\x1B[0m';

  static String _colourFor(LogLevel level) => switch (level) {
        LogLevel.critical => '\x1B[1;31m',
        LogLevel.error => '\x1B[31m',
        LogLevel.warning => '\x1B[33m',
        LogLevel.info => '',
        LogLevel.debug => '\x1B[2m',
      };
}

/// One file per launch, in a directory this app owns.
///
/// Opened lazily on the first record so that a session which logs nothing — a
/// test, a `--help`-shaped run — leaves no file behind, and so that construction
/// cannot fail.
class FileLogSink implements LogSink {
  FileLogSink({
    required this.directory,
    required DateTime Function() now,
    this.keep = 7,
    this.maxBytes = 16 * 1024 * 1024,
    String? lineEnding,
    IOSink Function(File file)? openSink,
    void Function(String reason)? onDisabled,
  })  : _now = now,
        // CRLF on Windows: a log is meant to be opened by whoever is being
        // asked for it, and plenty of Windows tooling still renders a
        // LF-only file as one enormous line.
        _lineEnding = lineEnding ?? (Platform.isWindows ? '\r\n' : '\n'),
        _openSink = openSink ?? _defaultOpen,
        _onDisabled = onDisabled;

  final Directory directory;
  final DateTime Function() _now;

  /// How many files the directory holds, **including the one this session is
  /// about to write**.
  final int keep;

  /// A cap on one session, not on the directory.
  ///
  /// A bug in a loop can write megabytes a second. Past this the sink stops —
  /// **it does not roll into a second file**, because a runaway session that
  /// rotated would evict all seven of the previous sessions' logs and destroy
  /// the history that answers "when did this start?". Losing the tail of the
  /// broken run is the cheaper loss.
  final int maxBytes;

  final String _lineEnding;
  final IOSink Function(File file) _openSink;
  final void Function(String reason)? _onDisabled;

  IOSink? _sink;
  File? _file;
  int _written = 0;
  bool _dead = false;
  bool _opened = false;

  /// The file this session is writing to, once there is one.
  File? get file => _file;

  @override
  LogFormat get format => LogFormat.file;

  /// Everything. The file is the complete record; the terminal is the summary.
  @override
  LogLevel get threshold => LogLevel.debug;

  @override
  void write(LogRecord record, String line) {
    if (_dead) return;
    if (!_opened) _open();
    final sink = _sink;
    if (sink == null) return;

    if (_written >= maxBytes) {
      _disable('size cap reached, ${_written ~/ (1024 * 1024)}MB');
      return;
    }

    try {
      sink.write('$line$_lineEnding');
      _written += line.length + _lineEnding.length;
      if (record.level.flushesImmediately) unawaited(flush());
    } catch (error) {
      _disable('write failed: $error');
    }
  }

  void _open() {
    _opened = true;
    try {
      if (!directory.existsSync()) directory.createSync(recursive: true);
      _prune();
      _file = _freeFile();
      final sink = _openSink(_file!);
      // **An `IOSink` reports asynchronous failures here, not at the write.** A
      // disk that fills mid-session, or a volume that goes away, surfaces only
      // on `done` — a sink that guards `write` alone drops the rest of the
      // session with no sign anywhere.
      sink.done.catchError((Object error) {
        _disable('stream failed: $error');
      });
      _sink = sink;
    } catch (error) {
      _disable('could not open: $error');
    }
  }

  /// The oldest files, gone, before the new one exists — see
  /// [planLogRotation] for why the count includes the file about to be opened.
  void _prune() {
    try {
      final names = <String>[
        for (final entry in directory.listSync(followLinks: false))
          if (entry is File) entry.uri.pathSegments.last,
      ];
      for (final name in planLogRotation(names, keep: keep)) {
        try {
          File('${directory.path}${Platform.pathSeparator}$name').deleteSync();
        } catch (_) {
          // Locked by a viewer, or gone already. The cap is a tidiness rule and
          // is never worth failing an open over.
        }
      }
    } catch (_) {
      // An unlistable directory still gets written to; it just stops pruning.
    }
  }

  File _freeFile() {
    final when = _now();
    for (var collision = 0; collision < 100; collision++) {
      final candidate = File(
        '${directory.path}${Platform.pathSeparator}'
        '${logFileName(when, collision: collision)}',
      );
      if (!candidate.existsSync()) return candidate;
    }
    // A hundred launches inside one second is not a thing; appending to the
    // last name beats throwing on a logger's behalf.
    return File(
      '${directory.path}${Platform.pathSeparator}${logFileName(when)}',
    );
  }

  void _disable(String reason) {
    // Redundant with the `_dead` check in [write] today, and kept as the
    // structural guarantee: whatever route reaches here, the report is once.
    if (_dead) return;
    _dead = true;
    final sink = _sink;
    _sink = null;
    try {
      sink?.close();
    } catch (_) {
      // Already broken; that is why we are here.
    }
    _onDisabled?.call(reason);
  }

  @override
  Future<void> flush() async {
    try {
      await _sink?.flush();
    } catch (error) {
      _disable('flush failed: $error');
    }
  }

  @override
  Future<void> close() async {
    final sink = _sink;
    _sink = null;
    _dead = true;
    try {
      await sink?.flush();
      await sink?.close();
    } catch (_) {
      // Nothing useful is left to do about a file that will not close.
    }
  }
}

IOSink _defaultOpen(File file) => file.openWrite(mode: FileMode.writeOnlyAppend);

/// Keeps the last [capacity] lines in memory, for "Copy diagnostics".
///
/// Holds **rendered, redacted lines** rather than records, so what reaches the
/// clipboard is censored by the same single guarantee as the file rather than by
/// a second implementation of it.
class MemoryLogSink extends LogSink {
  MemoryLogSink({this.capacity = 200});

  final int capacity;
  final List<String> _lines = <String>[];

  List<String> get lines => List.unmodifiable(_lines);

  @override
  LogFormat get format => LogFormat.file;

  @override
  LogLevel get threshold => LogLevel.debug;

  @override
  void write(LogRecord record, String line) {
    _lines.add(line);
    if (_lines.length > capacity) _lines.removeAt(0);
  }
}

/// `unawaited` without importing `dart:async` for one call.
void unawaited(Future<void> future) {
  future.catchError((Object _) {});
}
