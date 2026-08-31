/// Which log files survive, and which the next launch deletes.
///
/// A pure decision over filenames, split from the sink that performs it for the
/// reason `backup/retention.dart` gives about snapshots: the interesting part is
/// an off-by-one and a tie-break, and neither is worth a temp directory to test.
///
/// ## Two rules the filesystem cannot be trusted for
///
/// - **A file whose name this cannot parse is never deleted and never counted.**
///   The logs directory is ours, but a user who went looking for a log to attach
///   to a report may well leave `notes.txt` or a copy of one next to it.
///   Deleting an unrecognised file in a directory somebody has been told to open
///   is a data-loss bug, and the cap is not worth one.
/// - **Order comes from the name, never from the modification time.** The
///   running session rewrites its own file's mtime continuously, and a backup or
///   sync tool rewrites everyone's — either would make the *newest* file look
///   oldest and delete the wrong one. The name carries the moment the file was
///   opened, which is the thing being ordered.
library;

/// The moment a log file was opened, encoded so the name sorts chronologically.
///
/// Deliberately the same shape as the snapshot directory names in
/// `backup/snapshot_service.dart` — one timestamp convention in this codebase,
/// not two — and local time, so the filename matches the clock the user was
/// looking at when the thing went wrong.
String logFileName(DateTime when, {int collision = 0}) {
  String two(int value) => value.toString().padLeft(2, '0');
  final stamp = '${when.year}-${two(when.month)}-${two(when.day)}'
      '_${two(when.hour)}-${two(when.minute)}-${two(when.second)}';
  final suffix = collision == 0 ? '' : '-${two(collision)}';
  return '$logFilePrefix$stamp$suffix$logFileSuffix';
}

const String logFilePrefix = 'zzz-mod-manager_';
const String logFileSuffix = '.log';

final RegExp _logFileName = RegExp(
  '^${RegExp.escape(logFilePrefix)}'
  r'(\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2})(?:-(\d{2}))?'
  '${RegExp.escape(logFileSuffix)}\$',
);

/// Whether [name] is a log this app wrote, and therefore one it may delete.
bool isLogFileName(String name) => _logFileName.hasMatch(name);

/// What to delete so that opening one more file leaves [keep] in the directory.
///
/// **[keep] counts the file about to be opened**, which is the off-by-one worth
/// stating: asked to keep 7 with 7 already there, this returns 1 to delete, not
/// 0. Called at open rather than at exit, because a process that crashes never
/// reaches exit — and a crash is when the directory most needs pruning.
List<String> planLogRotation(Iterable<String> names, {int keep = 7}) {
  final ours = [
    for (final name in names)
      if (isLogFileName(name)) name,
  ]..sort();

  // Room for the one about to be created.
  final survivors = keep - 1;
  if (survivors <= 0) return ours;
  if (ours.length <= survivors) return const <String>[];
  return ours.take(ours.length - survivors).toList();
}
