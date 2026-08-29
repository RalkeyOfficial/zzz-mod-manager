/// Human-readable sizes and durations for transfer progress.
///
/// Here rather than beside any one of the three surfaces that show a download —
/// the modal dialog, the downloads panel and the pinned progress notification —
/// so none of them has to import from another's file.
library;

/// Formats a byte count for display, e.g. `21.9 MB`.
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(value >= 100 ? 0 : 1)} ${units[unit]}';
}

/// Formats a remaining time coarsely — a download with 8 minutes left does not
/// benefit from second-level precision, and a jittering countdown reads as
/// instability.
String formatDuration(Duration duration) {
  if (duration.inHours >= 1) {
    final minutes = duration.inMinutes.remainder(60);
    return '${duration.inHours}h ${minutes}m';
  }
  if (duration.inMinutes >= 1) return '${duration.inMinutes}m';
  return '${duration.inSeconds}s';
}
