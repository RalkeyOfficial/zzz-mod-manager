import 'package:mod_manager_flutter/services/download/download_job.dart';
import 'package:mod_manager_flutter/services/download/download_request.dart';
import 'package:mod_manager_flutter/services/download/update_job.dart';

import 'seeded_queue.dart';

/// A queue that keeps what each press asked for and starts nothing, so no transfer leaves the test.
/// It answers a job for the picks of the mods in [adds] and nothing for the rest.
class RecordingQueue extends SeededQueue {
  RecordingQueue({this.adds = const {}}) : super(const []);

  final Set<String> adds;
  final List<List<UpdateEnqueue>> pressed = [];

  @override
  List<DownloadJob?> enqueueUpdates(List<UpdateEnqueue> presses) {
    pressed.add(presses);
    return [
      for (final (i, press) in presses.indexed)
        adds.contains(press.task.primary.modId)
            ? DownloadJob(
                seq: i + 1,
                request: DownloadRequest(url: Uri.parse('https://gamebanana.com/dl/${press.file.idRow}')),
                intent: DownloadIntent.update,
                subject: press.subject,
                file: press.file,
                update: press.task,
              )
            : null,
    ];
  }
}
