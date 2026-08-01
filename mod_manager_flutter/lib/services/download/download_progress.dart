/// Where a download is in its lifecycle.
enum DownloadState {
  /// Request sent, headers not back yet.
  connecting,

  /// Bytes are arriving.
  downloading,

  /// Finished; the file is at its final name.
  completed,

  /// Stopped by the user.
  cancelled,

  /// Stopped by an error.
  failed;

  bool get isTerminal =>
      this == completed || this == cancelled || this == failed;
}

/// An immutable snapshot of a download, for the UI.
///
/// Carries rate and ETA rather than just a fraction because these transfers can
/// genuinely run for tens of minutes: over that long, "43%" alone doesn't tell
/// the user whether anything is still happening.
class DownloadProgress {
  const DownloadProgress({
    required this.state,
    this.received = 0,
    this.total,
    this.bytesPerSecond,
    this.eta,
    this.resumedFrom = 0,
    this.error,
  });

  final DownloadState state;

  /// Bytes on disk, **including** any prefix carried over from a resume.
  final int received;

  /// Total size once known, else null.
  final int? total;

  /// Current rate, or null before it has settled. Null means "not yet known",
  /// never "zero".
  final double? bytesPerSecond;

  /// Estimated time remaining, or null when it can't honestly be given.
  final Duration? eta;

  /// Bytes that were already on disk when this attempt started. Non-zero means
  /// the user is seeing a resumed download, which is worth telling them.
  final int resumedFrom;

  /// Set only in [DownloadState.failed].
  final Object? error;

  bool get isResumed => resumedFrom > 0;

  bool get isTerminal => state.isTerminal;

  /// Completion in 0..1, or null when the total is unknown — in which case the
  /// UI should show an indeterminate bar rather than inventing a number.
  double? get fraction {
    final size = total;
    if (size == null || size <= 0) return null;
    final value = received / size;
    return value.isNaN ? null : value.clamp(0.0, 1.0);
  }

  DownloadProgress copyWith({
    DownloadState? state,
    int? received,
    int? total,
    double? bytesPerSecond,
    Duration? eta,
    int? resumedFrom,
    Object? error,
  }) =>
      DownloadProgress(
        state: state ?? this.state,
        received: received ?? this.received,
        total: total ?? this.total,
        bytesPerSecond: bytesPerSecond ?? this.bytesPerSecond,
        eta: eta ?? this.eta,
        resumedFrom: resumedFrom ?? this.resumedFrom,
        error: error ?? this.error,
      );
}
