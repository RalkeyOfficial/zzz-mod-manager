/// Transfer rate and ETA over a sliding window.
///
/// A bare percentage bar is not enough here. Mod archives reach 1.24 GB, and a
/// degraded CDN node has been measured serving at 0.08 MB/s — roughly 25 minutes
/// for one file, with no way to route around it. Over a wait that long the user
/// needs to know whether anything is actually moving, and roughly how long is
/// left, which is what this provides.
///
/// The window matters: an instantaneous rate computed from the last chunk swings
/// wildly, and a cumulative average from the start never recovers from a slow
/// opening. A few seconds of history gives a number that is steady enough to
/// read but still reacts when the connection changes.
class RateEstimator {
  RateEstimator({
    DateTime Function()? now,
    this.window = const Duration(seconds: 5),
    this.minimumSpan = const Duration(seconds: 1),
  }) : _now = now ?? DateTime.now;

  final DateTime Function() _now;

  /// How much history the rate is averaged over.
  final Duration window;

  /// Below this much elapsed history, [bytesPerSecond] stays null.
  final Duration minimumSpan;

  final List<_Sample> _samples = <_Sample>[];

  /// Records cumulative bytes received so far.
  void add(int cumulativeBytes) {
    final at = _now();
    _samples.add(_Sample(at, cumulativeBytes));
    final cutoff = at.subtract(window);
    // Drop samples until the *second* one is newer than the cutoff, which
    // leaves exactly one sample at or before it. Keeping that one is what makes
    // a span measurable at all; keeping any more would let an old fast burst go
    // on inflating the rate long after the transfer had actually stalled.
    while (_samples.length > 2 && !_samples[1].at.isAfter(cutoff)) {
      _samples.removeAt(0);
    }
  }

  /// Bytes per second across the window, or null when it can't be said yet.
  ///
  /// Null rather than zero or a guess: showing "0 B/s" during the first moments
  /// of a healthy download, or a wild figure extrapolated from one chunk, is
  /// worse than showing nothing. The UI renders a placeholder until this
  /// settles.
  double? get bytesPerSecond {
    if (_samples.length < 2) return null;
    final first = _samples.first;
    final last = _samples.last;
    final elapsed = last.at.difference(first.at);
    if (elapsed < minimumSpan) return null;
    final micros = elapsed.inMicroseconds;
    if (micros <= 0) return null;
    final delta = last.bytes - first.bytes;
    if (delta < 0) return null;
    return delta * Duration.microsecondsPerSecond / micros;
  }

  /// Time remaining for [total] bytes, or null when unknowable.
  ///
  /// Null when the total is unknown, when the rate hasn't settled, or when the
  /// transfer has stalled — an ETA computed from a rate near zero is a number
  /// in the millions of seconds, which is worse than admitting we don't know.
  Duration? etaFor({required int received, int? total}) {
    if (total == null || total <= 0) return null;
    final remaining = total - received;
    if (remaining <= 0) return Duration.zero;
    final rate = bytesPerSecond;
    if (rate == null || rate < 1) return null;
    return Duration(seconds: (remaining / rate).round());
  }

  void reset() => _samples.clear();
}

class _Sample {
  const _Sample(this.at, this.bytes);

  final DateTime at;
  final int bytes;
}
