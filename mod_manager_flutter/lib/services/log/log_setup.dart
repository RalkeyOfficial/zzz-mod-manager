/// Building the router the app actually runs with, and installing the handlers
/// that catch what nobody caught before.
///
/// This runs **first in `main()`**, before the Flutter binding and before
/// `window_manager`. It can, because nothing here needs Flutter:
/// `PathHelper.getAppDataPath()` is synchronous and environment-based, the
/// redactor reads two environment variables, and the file sink opens lazily on
/// its first line. That ordering is the point — `windowManager.ensureInitialized()`
/// failing on a broken display is currently a completely silent death, and it is
/// the single most valuable thing this file makes visible.
///
/// **Nothing in here may log.** `PathHelper`, the redactor and the setting read
/// all run *inside* logger construction; a log call from any of them would
/// recurse through a router that does not exist yet.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/constants.dart';
import '../../utils/path_helper.dart';
import '../platform_service_factory.dart';
import 'log_level.dart';
import 'log_redaction.dart';
import 'log_sinks.dart';
import 'logger.dart';

/// The setting's key in `config.json`. Mirrored by `ConfigService`, which owns
/// it everywhere except here.
const String kFileLoggingKey = 'file_logging';

/// Whether to write a file this session, read **straight off the disk**.
///
/// `ConfigService` is the right owner of this setting and cannot answer yet:
/// it is backed by `SharedPreferences`, which does not exist until
/// `ApiService.initialize` runs inside the first frame — long after the first
/// lines worth keeping. `config.json` is already the canonical mirror of every
/// setting (`docs/configuration.md`), it is a few hundred bytes, and
/// `PathHelper` is synchronous, so reading it here costs one `readAsStringSync`.
///
/// **Any failure means yes.** A missing, unreadable or malformed config is the
/// state a first run and a corrupted install share, and both are exactly when
/// somebody wants the log.
bool readFileLoggingFromDisk({File? configFile}) {
  try {
    final file = configFile ??
        File('${PathHelper.getAppDataPath()}${Platform.pathSeparator}'
            '${AppConstants.configFileName}');
    if (!file.existsSync()) return true;
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map) return true;
    final value = decoded[kFileLoggingKey];
    return value is bool ? value : true;
  } catch (_) {
    return true;
  }
}

/// A redactor that knows this machine, or one that still censors paths if it
/// cannot find out — see [LogRedactor.pathsOnly].
LogRedactor buildRedactor() {
  try {
    final platform = PlatformServiceFactory.getInstance();
    return LogRedactor(
      home: platform.homeDirectoryPath,
      username: platform.osUserName,
      caseInsensitive: Platform.isWindows,
    );
  } catch (_) {
    return LogRedactor.pathsOnly;
  }
}

/// The router for a real run: a terminal, the last 200 lines in memory, and —
/// unless the user turned it off — a file.
///
/// [fileLogging] and [logsDirectory] are parameters rather than reads so a test
/// can build the production shape without touching the developer's own
/// `<appData>`.
LogRouter buildProductionRouter({
  bool? fileLogging,
  Directory? logsDirectory,
  DateTime Function()? now,
}) {
  final clock = now ?? DateTime.now;
  final sinks = <LogSink>[
    // Quieter in a release build: a packaged app's terminal, where it has one,
    // is not somebody's development console. The file always gets everything,
    // which is why there is no level setting to get wrong.
    TerminalLogSink(threshold: kDebugMode ? LogLevel.debug : LogLevel.info),
    MemoryLogSink(),
  ];

  if (fileLogging ?? readFileLoggingFromDisk()) {
    final file = buildFileSink(logsDirectory: logsDirectory, now: clock);
    if (file != null) sinks.add(file);
  }

  return LogRouter(sinks: sinks, redactor: buildRedactor(), now: clock);
}

/// The file sink a real run uses, or null when there is nowhere to put it.
///
/// Shared by [buildProductionRouter] and the Settings toggle, so a file opened
/// mid-session is identical to one opened at launch — same directory, same
/// retention, same failure handling.
FileLogSink? buildFileSink({
  Directory? logsDirectory,
  DateTime Function()? now,
}) {
  Directory? directory = logsDirectory;
  if (directory == null) {
    try {
      directory = Directory(PathHelper.getLogsPath());
    } catch (_) {
      // No home directory to put it in. The terminal and the memory sink still
      // work, and "Copy diagnostics" still has something to copy.
      return null;
    }
  }
  return FileLogSink(
    directory: directory,
    now: now ?? DateTime.now,
    onDisabled: (reason) => Log.of('log').warning(
      'file logging stopped',
      fields: {'reason': reason},
    ),
  );
}

/// Starts or stops the file for the rest of this session, and says so in it.
///
/// The "stopping" line is written **before** the sink goes, so the file it
/// lands in explains its own last line rather than simply ending.
void applyFileLogging(bool enabled, {Directory? logsDirectory}) {
  if (enabled == Log.writesToFile) return;
  if (enabled) {
    Log.setFileSink(buildFileSink(logsDirectory: logsDirectory));
    logStartupHeader(fileLogging: true);
    Log.of('log').info('file logging turned on');
  } else {
    Log.of('log').info('file logging turned off, this file ends here');
    Log.setFileSink(null);
  }
}

/// What "Copy diagnostics" puts on the clipboard.
///
/// A short header plus the lines still in memory. **Not read from the file**:
/// this has to work with the file switched off, must not be slow, and the ring
/// buffer already holds redacted lines — so what reaches the clipboard is
/// censored by the same single guarantee, not by a second implementation.
///
/// The header is rebuilt rather than taken from the top of the buffer, which on
/// a long session has scrolled away — and a paste with no version in it is the
/// one thing whoever reads it will ask for first.
String diagnosticsText() {
  final redactor = Log.router.redactor;
  final buffer = StringBuffer()
    ..writeln('zzz-mod-manager ${AppConstants.appVersion} · '
        '${Platform.operatingSystem} · '
        '${Platform.operatingSystemVersion} · '
        'locale=${Platform.localeName}')
    ..writeln('log=${redactor(Log.filePath ?? 'off')}')
    ..writeln('--- recent log lines ---');
  for (final line in Log.recent) {
    buffer.writeln(line);
  }
  return buffer.toString();
}

/// Routes Flutter's own error channels into the log.
///
/// **Must run after `WidgetsFlutterBinding.ensureInitialized()`**: the binding
/// installs its own `FlutterError.onError` in its constructor, so anything set
/// before that is silently replaced.
void installErrorHandlers() {
  final log = Log.of('flutter');

  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    log.critical(
      'unhandled framework error',
      error: details.exception,
      stack: details.stack,
      fields: {
        'library': details.library ?? 'unknown',
        'context': details.context?.toDescription() ?? '',
        'silent': details.silent,
      },
    );
    // Kept, deliberately: this is the red error screen and the console dump
    // that developers work from every day. Replacing it would trade a visible
    // failure for a line in a file nobody has opened yet.
    previous?.call(details);
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    try {
      Log.of('isolate').critical(
        'unhandled asynchronous error',
        error: error,
        stack: stack,
      );
    } catch (_) {
      // An error handler that throws is a hang. Let the default one have it.
      return false;
    }
    return true;
  };
}

/// What every log file opens with, before anything has happened.
///
/// The half that costs nothing: no process, no file read beyond what is already
/// in memory. Whatever needs probing is appended afterwards by the system probe
/// so that startup is never waiting on `where 7z` walking a cold PATH.
void logStartupHeader({required bool fileLogging}) {
  final log = Log.of('app');
  final redactor = Log.router.redactor;
  log.info('started', fields: {
    'version': AppConstants.appVersion,
    'build': kReleaseMode ? 'release' : 'debug',
    'os': Platform.operatingSystem,
    'os_version': Platform.operatingSystemVersion,
    'dart': Platform.version.split(' ').first,
    'locale': Platform.localeName,
    'cpus': Platform.numberOfProcessors,
  });
  // **After the line above, deliberately.** The file sink opens on its first
  // write, so until something has been logged there is no path to report —
  // asking for it any earlier reports `off` for a file that is about to exist.
  log.info('logging', fields: {
    'file': Log.filePath ?? 'off',
    'enabled': fileLogging,
    'home_censored': redactor.home == null ? 'unknown' : 'yes',
    // Stated rather than silent: a short or absent account name means the bare
    // token is left in the file, and a reader chasing a suspected leak should
    // find that out at the top instead of guessing.
    'username_token': redactor.censorsUsernameToken ? 'yes' : 'skipped',
  });
}
