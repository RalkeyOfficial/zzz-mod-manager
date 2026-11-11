import 'package:mod_manager_flutter/services/download/download_job.dart';
import 'package:mod_manager_flutter/services/download/download_queue.dart';

/// A download queue that starts with [_seed] in it rather than empty, for a test that needs jobs in a given state.
///
/// A job the queue adds later takes a number above every seeded one, so the two never share a `seq`.
class SeededQueue extends DownloadQueue {
  SeededQueue(this._seed);

  final List<DownloadJob> _seed;

  @override
  List<DownloadJob> build() {
    super.build();
    return _seed;
  }

  /// Re-emits without changing anything:
  /// a stand-in for a progress tick, which the real queue produces twice a second per running transfer.
  void tick() => state = [...state];

  /// Moves [seq] to [next], as the real queue does on a pause or a handover.
  void put(int seq, DownloadJobState next) => state = [
        for (final job in state)
          if (job.seq == seq) job.copyWith(state: next) else job,
      ];
}
