import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_file.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_mod.dart';
import 'package:mod_manager_flutter/services/download/download_job.dart';
import 'package:mod_manager_flutter/services/download/download_queue.dart';
import 'package:mod_manager_flutter/services/download/download_request.dart';
import 'package:mod_manager_flutter/services/storage/reclaim_plan.dart';
import 'package:mod_manager_flutter/services/storage/storage_providers.dart';
import 'package:mod_manager_flutter/services/storage/storage_roots.dart';
import 'package:path/path.dart' as path;

import '../support/library_override.dart';

/// The Storage reclaim's gate as the app wires it, from the download queue: the temp extractions a download is
/// still using are refused whole, whatever their age.
void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('reclaim_gate_test_'));
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// Roots entirely inside the test's directory, since the reclaim deletes.
  StorageRoots roots() => StorageRoots(
        appData: Directory(path.join(root.path, 'appdata'))..createSync(recursive: true),
        downloads: Directory(path.join(root.path, 'appdata', 'downloads')),
        logs: Directory(path.join(root.path, 'appdata', 'logs')),
        legacyImages: Directory(path.join(root.path, 'appdata', 'mod_images')),
        backups: Directory(path.join(root.path, 'appdata', 'backups')),
        temp: Directory(path.join(root.path, 'temp'))..createSync(recursive: true),
      );

  DownloadJob job(DownloadJobState state) => DownloadJob(
        seq: 1,
        request: DownloadRequest(url: Uri.parse('https://gamebanana.com/dl/1')),
        intent: DownloadIntent.install,
        subject: 'Ellen Swimsuit',
        file: const GbFile(idRow: 1),
        mod: const GbMod(idRow: 1001, name: 'Ellen Swimsuit'),
        state: state,
      );

  /// Runs the reclaim with one download in [state] beside an unpack past the one-hour grace, and returns whether
  /// the unpack is still there, with what the reclaim said about the temp extractions.
  Future<(bool, ReclaimSkipReason?)> reclaimBeside(DownloadJobState state) async {
    final unpack = Directory(path.join(root.path, 'temp', 'zzz_archive_extract_update'))..createSync(recursive: true);
    File(path.join(unpack.path, 'Ellen.ini'))
      ..writeAsStringSync('[Constants]')
      ..setLastModifiedSync(DateTime.now().subtract(const Duration(hours: 6)));

    final container = ProviderContainer(overrides: [
      storageRootsProvider.overrideWithValue(roots()),
      downloadQueueProvider.overrideWith(() => _SeededQueue([job(state)])),
      libraryOf(const []),
    ]);
    addTearDown(container.dispose);

    // Built first: a press while its build is loading is taken for a press while a sweep runs.
    await container.read(reclaimControllerProvider.future);
    await container.read(reclaimControllerProvider.notifier).run();
    final outcome = container.read(reclaimControllerProvider).requireValue!;
    final temp = outcome.targets.where((result) => result.target == ReclaimTarget.tempExtracts).firstOrNull;
    return (unpack.existsSync(), temp?.refusal);
  }

  test("an update's unpack is in use while it asks and writes", () async {
    final (kept, refusal) = await reclaimBeside(DownloadJobState.updating);

    expect(kept, isTrue);
    expect(refusal, ReclaimSkipReason.installInProgress);
  });

  test("an install's unpack is in use while it imports", () async {
    final (kept, refusal) = await reclaimBeside(DownloadJobState.installing);

    expect(kept, isTrue);
    expect(refusal, ReclaimSkipReason.installInProgress);
  });

  test('a finished download uses nothing, so an abandoned unpack goes', () async {
    final (kept, refusal) = await reclaimBeside(DownloadJobState.done);

    expect(kept, isFalse);
    expect(refusal, isNull);
  });
}

class _SeededQueue extends DownloadQueue {
  _SeededQueue(this._seed);

  final List<DownloadJob> _seed;

  @override
  List<DownloadJob> build() {
    super.build();
    return _seed;
  }
}
