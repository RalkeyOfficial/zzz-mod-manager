/// How bad it is, and therefore who needs to see it.
///
/// Five levels, ordered least to most severe so [index] is the comparison. The
/// distinction that matters in practice is **warning vs error**: a warning is
/// something the app recovered from on its own and the user may never notice; an
/// error is an operation that did not happen. Anything a user would describe as
/// "it didn't work" belongs at [error] or above, because that is what somebody
/// reading a log for a bug report greps for first.
library;

enum LogLevel {
  /// The step-by-step narration of an attempt. Useful when reproducing
  /// something, noise otherwise.
  debug('DEBUG'),

  /// Something happened that a reader reconstructing the session wants in the
  /// timeline: a download finished, a snapshot was taken, the user accepted a
  /// confirmation.
  info('INFO'),

  /// A problem the app handled. A retry, a fallback, a file it skipped. The
  /// operation still completed.
  warning('WARN'),

  /// An operation did not happen. Usually paired with something the user was
  /// told, and the log line is the detail the notification could not carry.
  error('ERROR'),

  /// The app is in a state it has no answer for — an uncaught exception, a
  /// platform that cannot be supported. Always flushed to disk immediately,
  /// because the next thing that happens may be the process ending.
  critical('CRIT');

  const LogLevel(this.label);

  /// Fixed-width in the file so the level column lines up when read in a plain
  /// text editor, which is how a log actually gets read.
  final String label;

  /// Whether this is at least as severe as [other].
  bool operator >=(LogLevel other) => index >= other.index;

  /// Whether reaching this level should force the file to disk now rather than
  /// at the next flush.
  ///
  /// An error is often the last thing to happen before a crash or a kill, and a
  /// buffered line lost at that moment is the one line that mattered.
  bool get flushesImmediately => index >= LogLevel.error.index;
}
