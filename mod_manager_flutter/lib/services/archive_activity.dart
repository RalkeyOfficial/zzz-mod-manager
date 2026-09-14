/// Whether an archive is being unpacked right now.
///
/// A counter rather than a flag because two imports can overlap — the download
/// queue runs two at a time — and the first to finish must not report the
/// second's work as over.
///
/// **This exists for one reader: the storage reclaim.** The download queue can
/// answer for anything it started, but a drag-in or file-picker install unpacks
/// with no download job anywhere, so the queue reads idle while an archive is
/// being consumed. This is what the sweep asks instead.
///
/// A plain static rather than a provider deliberately. It is written from
/// [ArchiveService], which is a static service with no `ref`, and routing it
/// through Riverpod would mean threading a container into every extraction call
/// site to record a fact none of them care about.
///
/// It covers **the unpack**, not the copy into the library that follows. That
/// window is covered instead by the reclaim's one-hour grace on an extraction
/// directory, measured from the newest write inside it: a directory an import is
/// still reading from was written minutes ago, so it is never a candidate.
library;

class ArchiveActivity {
  ArchiveActivity._();

  static int _inFlight = 0;

  static bool get isBusy => _inFlight > 0;

  /// Bracket an unpack. Always paired with [end] in a `finally`, or a thrown
  /// extraction would leave the app believing it is busy forever — and a gate
  /// stuck closed means the reclaim button silently stops working.
  static void begin() => _inFlight++;

  static void end() {
    if (_inFlight > 0) _inFlight--;
  }

  /// For tests, which must not inherit a count from whatever ran before.
  static void resetForTests() => _inFlight = 0;
}
