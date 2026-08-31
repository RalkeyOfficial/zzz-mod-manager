/// Running a short command and getting its output back, or giving up.
///
/// Written for the log's system header — "is 7-Zip there, and which version?" —
/// and deliberately general, because this codebase has **40 bare `Process.run`
/// calls and not one of them can time out**. A `where 7z` walking a cold
/// Windows `PATH`, or an `xdotool` waiting on a display that is not answering,
/// currently hangs whatever awaited it, forever.
///
/// Three implementation facts decide whether a helper like this actually works,
/// and each is a bug if got wrong:
///
/// 1. **`Process.run(...).timeout(d)` does not kill the child.** It abandons the
///    future while the process keeps running and the pipes stay open. So this
///    uses `Process.start` and kills on expiry.
/// 2. **Both pipes must be drained, always.** A child that fills the ~64 KB pipe
///    buffer blocks on write and never exits — which is exactly how a "timeout
///    helper" comes to hang. Both streams are consumed concurrently.
/// 3. **The output is not necessarily UTF-8.** A Windows console speaks whatever
///    code page it is set to, so decoding uses [SystemEncoding] and tolerates
///    malformed bytes rather than throwing over a version string.
library;

import 'dart:async';
import 'dart:io';

class ProbeResult {
  const ProbeResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    this.timedOut = false,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
  final bool timedOut;

  /// Both streams, for a tool that prints its banner to stderr — several do.
  String get output => stdout.isNotEmpty ? stdout : stderr;
}

class ProcessProbe {
  const ProcessProbe({
    this.timeout = const Duration(seconds: 2),
    this.maxBytes = 64 * 1024,
  });

  final Duration timeout;

  /// A cap on what is kept, not on what the child may write. Draining
  /// continues past it; only the accumulation stops.
  final int maxBytes;

  /// Runs [executable], or returns **null** when it could not be run at all —
  /// not installed, not executable, not permitted.
  ///
  /// Never throws. A caller asking "is this tool here?" has no use for an
  /// exception, and a caller writing a log header must not be able to fail
  /// because a diagnostic did.
  Future<ProbeResult?> run(
    String executable,
    List<String> arguments, {
    Duration? timeout,
  }) async {
    final Process process;
    try {
      // Never through a shell: quoting rules differ between platforms and a
      // shell is one more thing that can be missing or hostile.
      process = await Process.start(executable, arguments, runInShell: false);
    } catch (_) {
      return null;
    }

    final out = _collect(process.stdout);
    final err = _collect(process.stderr);

    var timedOut = false;
    final exitCode = await process.exitCode.timeout(
      timeout ?? this.timeout,
      onTimeout: () {
        timedOut = true;
        process.kill(ProcessSignal.sigkill);
        return process.exitCode;
      },
    );

    return ProbeResult(
      exitCode: exitCode,
      stdout: await out,
      stderr: await err,
      timedOut: timedOut,
    );
  }

  Future<String> _collect(Stream<List<int>> stream) async {
    final buffer = StringBuffer();
    const decoder = SystemEncoding();
    await for (final chunk in stream) {
      if (buffer.length >= maxBytes) continue; // still draining, just not keeping
      try {
        buffer.write(decoder.decode(chunk));
      } catch (_) {
        // A code page we cannot decode is not a reason to fail a probe.
      }
    }
    return buffer.toString();
  }
}

/// The first version-shaped token in [output], or null.
///
/// Deliberately loose. `7-Zip 24.09 (x64)`, `xdotool version 3.20211022.1` and
/// `ydotool v1.0.4` are three different shapes from three tools, and a parser
/// that insisted on one of them would report "no version" for the others. What
/// matters is that an unexpected banner degrades to *present, version unknown*
/// rather than to an error.
String? parseVersionToken(String output) {
  final match = RegExp(r'\d+(?:\.\d+)+').firstMatch(output);
  return match?.group(0);
}
