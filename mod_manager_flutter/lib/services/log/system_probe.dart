/// Putting the machine's description into the log, a moment after startup.
///
/// **Not part of the header written at open**, and that is the design rather
/// than an accident. The synchronous half — app version, OS, locale, paths — is
/// free and goes in immediately. This half spawns three to five short processes,
/// and a `where 7z` walking a cold Windows `PATH` is a visible pause. Blocking
/// the first frame on a diagnostic would be paying for the log with the thing
/// the log is meant to protect.
///
/// So it runs unawaited after `runApp` and appends ordinary records, which land
/// a few hundred milliseconds in. The file is read in timestamp order either
/// way, and two labelled blocks beat one header that lies about being complete.
library;

import 'dart:async';

import '../../utils/process_probe.dart';
import '../platform_service_factory.dart';
import 'logger.dart';
import 'system_report.dart';

final Logger _log = Logger('system');

/// Probes the machine and writes what it found.
///
/// Never throws and never hangs: every probe is bounded by [ProcessProbe], and
/// the whole gather is bounded again here, because a tool that ignores SIGKILL
/// is not a reason for a log line to be outstanding forever.
Future<void> logSystemReport({
  ProcessProbe probe = const ProcessProbe(),
  Duration budget = const Duration(seconds: 10),
}) async {
  try {
    final report = await PlatformServiceFactory.getInstance()
        .describeSystem(probe: probe)
        .timeout(budget);

    _log.info('environment', fields: osFields(report.os));
    for (final tool in report.tools) {
      // One line per tool rather than one line listing them: a reader greps
      // `tool=7-zip` and gets the answer, wherever the log came from.
      final missing = tool.state == ToolState.missing;
      final fields = toolFields(tool);
      if (missing) {
        _log.warning('tool', fields: fields);
      } else {
        _log.info('tool', fields: fields);
      }
    }
  } on TimeoutException {
    _log.warning('environment probe timed out', fields: {
      'budget': budget,
    });
  } catch (error, stack) {
    _log.warning('environment probe failed', error: error, stack: stack);
  }
}
