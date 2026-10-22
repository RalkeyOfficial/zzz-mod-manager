import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_file.dart';
import 'package:mod_manager_flutter/models/installed_file.dart';
import 'package:mod_manager_flutter/models/mod_ingest.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/screens/dialogs/apply_update_flow.dart';
import 'package:mod_manager_flutter/services/download/download_job.dart';
import 'package:mod_manager_flutter/services/download/download_queue.dart';
import 'package:mod_manager_flutter/services/download/download_service.dart';
import 'package:mod_manager_flutter/utils/marketplace_providers.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';
import 'package:path/path.dart' as p;

import 'support/fake_download_transport.dart';
import 'support/localized_harness.dart';
import 'support/origin_shorthand.dart';
import 'support/recording_service.dart';
import 'support/temp_library.dart';

/// An update's download stays on the panel until the update ends, and every way the update flows end ends it:
/// Finished with what was written, failed with the flow's own headline, or off the list when declined
/// (`docs/downloads.md` §13).
void main() {
  const modName = 'Ellen';
  const patchId = 605460;

  late TempLibrary temp;
  late RecordingService service;
  late FakeDownloadTransport transport;
  late ProviderContainer container;

  /// Every state the update's job passed through, by step.
  late List<(DownloadJobState, UpdateStep?)> seen;

  setUp(() async {
    temp = await TempLibrary.create(prefix: 'zzz_update_row_');
    service = RecordingService(temp);
    transport = FakeDownloadTransport();
    seen = [];
  });

  GbFile serveBytes(int fileId, List<int> body) {
    final url = Uri.parse('https://gamebanana.com/dl/$fileId');
    transport.enqueue(url, body: body);
    return GbFile(idRow: fileId, file: 'ellen$fileId.zip', filesize: body.length, downloadUrl: '$url');
  }

  /// Serves a zip of [files] as file [fileId] of the mod's page.
  GbFile serve(int fileId, Map<String, String> files) {
    final archive = Archive();
    for (final entry in files.entries) {
      final bytes = utf8.encode(entry.value);
      archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
    }
    return serveBytes(fileId, ZipEncoder().encode(archive)!);
  }

  Future<ModInfo> installed(WidgetTester tester, ModOrigin origin) async {
    temp.write(modName, 'Ellen.ini', '[KeySwap]\nkey = VK_1\n');
    await tester.runAsync(() => temp.writeOrigin(modName, origin));
    return ModInfo(id: modName, name: modName, characterId: 'ellen', isActive: false, origin: origin);
  }

  ModOrigin tracked() => originFixture(
        modId: 100,
        modIdConfidence: OriginConfidence.exact,
        fileId: 1,
        versionConfidence: OriginConfidence.exact,
        ingest: const ModIngest(folders: [modName]),
      );

  /// Presses a button running [flow], and pumps until it ends or [until] says to stop.
  Future<bool?> run(
    WidgetTester tester,
    Future<bool> Function(BuildContext context, WidgetRef ref) flow, {
    bool Function()? until,
  }) async {
    bool? changed;
    container = ProviderContainer(overrides: [
      ...service.overrides,
      downloadServiceProvider.overrideWith(
        (ref) => DownloadService(
          transport: transport,
          directory: Directory(p.join(temp.root.path, 'downloads')),
          progressInterval: const Duration(milliseconds: 10),
          freeSpace: (_) async => 1 << 40,
        ),
      ),
    ]);
    addTearDown(container.dispose);
    container.listen(downloadQueueProvider, (_, jobs) {
      for (final job in jobs) {
        final step = (job.state, job.updateStep);
        if (seen.isEmpty || seen.last != step) seen.add(step);
      }
    });
    await pumpLocalized(
      tester,
      Consumer(
        builder: (context, ref, _) => ElevatedButton(
          onPressed: () async => changed = await flow(context, ref),
          child: const Text('update'),
        ),
      ),
      container: container,
    );
    expectBuilt(ElevatedButton);

    // The download's progress window spins until the flow ends, so the frames are pumped by hand.
    await tester.runAsync(() => tester.tap(find.text('update')));
    bool done() => changed != null || (until?.call() ?? false);
    for (var i = 0; i < 100 && !done(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    expect(done(), isTrue, reason: 'the flow never ended');
    return changed;
  }

  List<DownloadJob> jobs() => container.read(downloadQueueProvider);

  /// The flow ends behind its result window, which these tests leave open.
  bool finished() => jobs().any((j) => j.state == DownloadJobState.done);

  testWidgets('a written update is Finished with what it wrote, after unpacking and writing on the panel',
      (tester) async {
    final mod = await installed(tester, tracked());
    final file = serve(2, {'Ellen/Ellen.ini': '[KeySwap]\nkey = VK_2\n'});

    await run(
      tester,
      (context, ref) => applyUpdateFlow(context, ref, mod: mod, remoteModId: 100, file: file, confirm: false),
      until: finished,
    );

    final job = jobs().single;
    expect(job.state, DownloadJobState.done);
    expect(job.outcome, JobOutcome.updated);
    expect(job.filedUnder, 'ellen');
    expect(seen, containsAllInOrder([
      (DownloadJobState.updating, UpdateStep.unpacking),
      (DownloadJobState.updating, UpdateStep.writing),
      (DownloadJobState.done, UpdateStep.writing),
    ]));
  });

  testWidgets('the base a dropped patch named is Finished as that, not as an update', (tester) async {
    final mod = await installed(tester, tracked());
    final file = serve(2, {'Ellen/Ellen.ini': '[KeySwap]\nkey = VK_2\n'});

    await run(
      tester,
      (context, ref) =>
          applyUpdateFlow(context, ref, mod: mod, remoteModId: 100, file: file, asCompanion: true, confirm: false),
      until: finished,
    );

    expect(jobs().single.outcome, JobOutcome.baseInstalled);
  });

  testWidgets('a write that fails ends the row as a failure with the update headline, offering no retry',
      (tester) async {
    final mod = await installed(tester, tracked());
    final file = serve(2, {'Ellen/Ellen.ini': '[KeySwap]\nkey = VK_2\n'});
    service.failOriginWrites = true;

    await run(tester, (context, ref) => applyUpdateFlow(context, ref, mod: mod, remoteModId: 100, file: file, confirm: false));

    final job = jobs().single;
    expect(job.state, DownloadJobState.failed);
    expect(job.error, isA<InstallFailure>());
    expect('${job.error}', 'The update failed');
  });

  testWidgets('an archive that will not unpack ends the row as a failure', (tester) async {
    final mod = await installed(tester, tracked());
    final file = serveBytes(2, List<int>.generate(300, (i) => (i * 7) % 256));

    await run(tester, (context, ref) => applyUpdateFlow(context, ref, mod: mod, remoteModId: 100, file: file, confirm: false));

    expect(jobs().single.state, DownloadJobState.failed);
  });

  testWidgets('an update declined at its confirmation leaves the list, having waited on the panel for the answer',
      (tester) async {
    final mod = await installed(tester, tracked());
    final file = serve(2, {'Ellen/Ellen.ini': '[KeySwap]\nkey = VK_2\n'});

    final changed = <bool>[];
    await run(
      tester,
      (context, ref) async {
        final result = await applyUpdateFlow(context, ref, mod: mod, remoteModId: 100, file: file);
        changed.add(result);
        return result;
      },
      until: () => find.text('Cancel').evaluate().isNotEmpty,
    );
    expect(jobs().single.updateStep, UpdateStep.confirming);

    await tester.runAsync(() => tester.tap(find.text('Cancel').last));
    for (var i = 0; i < 40 && changed.isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    expect(changed, [false]);
    expect(jobs(), isEmpty);
  });

  testWidgets("Open mod page in the update's password dialog closes the windows over the pages and opens it in Browse",
      (tester) async {
    final mod = await installed(tester, tracked());
    late List<int> locked;
    await tester.runAsync(() async {
      final src = Directory(p.join(temp.root.path, 'src', modName))..createSync(recursive: true);
      File(p.join(src.path, 'Ellen.ini')).writeAsStringSync('[KeySwap]\nkey = VK_2\n');
      final zip = p.join(temp.root.path, 'locked.zip');
      final made = await Process.run(_sevenZip!, ['a', '-tzip', '-pSECRET', zip, modName], workingDirectory: src.parent.path);
      expect(made.exitCode, 0, reason: '${made.stderr}');
      locked = File(zip).readAsBytesSync();
    });
    final file = serveBytes(5, locked);

    await run(
      tester,
      // Started from a window of its own, as the mod's update window does.
      (context, ref) {
        final done = Completer<bool>();
        showDialog<void>(
          context: context,
          builder: (_) => _UpdateWindow(
            flow: (context, ref) => applyUpdateFlow(context, ref, mod: mod, remoteModId: 100, file: file),
            done: done,
          ),
        );
        return done.future;
      },
      until: () => find.text('Open mod page').evaluate().isNotEmpty,
    );
    expect(find.text('Update window'), findsOneWidget);

    await tester.runAsync(() => tester.tap(find.text('Open mod page')));
    for (var i = 0; i < 40 && jobs().isNotEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    await tester.pumpAndSettle();

    expect(jobs(), isEmpty, reason: 'the update ended');
    expect(find.text('Update window'), findsNothing, reason: 'the page opens in Browse, not under the window');
    expect(find.byType(AlertDialog), findsNothing);
    expect(container.read(downloadsPanelCloseRequestProvider), 1);
    expect(container.read(destinationProvider), AppDestination.browse);
    expect(container.read(marketplaceOpenModProvider), 100);
  }, skip: _writesZip ? false : true);

  testWidgets('a patch update ends its row on success and on failure', (tester) async {
    temp.write(modName, 'Textures/Patch.dds', 'v1');
    final origin = originFixture(
      modId: 100,
      modIdConfidence: OriginConfidence.exact,
      patches: [
        patchFixture(
          modId: patchId,
          files: const [InstalledFile(path: 'Textures/Patch.dds', role: InstalledFileRole.added)],
        ),
      ],
    );
    final mod = await installed(tester, origin);
    final file = serve(3, {'Ellen Fix/Textures/Patch.dds': 'v2'});
    service.failOriginWrites = true;

    await run(
      tester,
      (context, ref) => applyPatchUpdateFlow(context, ref, mod: mod, remoteModId: patchId, file: file, asCompanion: true),
    );
    expect(jobs().single.state, DownloadJobState.failed);

    service.failOriginWrites = false;
    final again = serve(4, {'Ellen Fix/Textures/Patch.dds': 'v3'});
    await run(
      tester,
      (context, ref) => applyPatchUpdateFlow(context, ref, mod: mod, remoteModId: patchId, file: again, asCompanion: true),
      until: finished,
    );
    expect(jobs().single.state, DownloadJobState.done);
    expect(jobs().single.outcome, JobOutcome.updated);
  });
}

/// Path to a 7-Zip binary, or null when none is installed.
final String? _sevenZip = () {
  for (final candidate in ['7z', '7za']) {
    try {
      final which = Process.runSync('which', [candidate]);
      if (which.exitCode == 0 && which.stdout.toString().trim().isNotEmpty) return which.stdout.toString().trim();
    } catch (_) {
      // `which` missing (Windows); the test skips.
    }
  }
  return null;
}();

/// Whether a 7-Zip that writes encrypted zips is installed (`7zr` writes none).
final bool _writesZip = _sevenZip != null;

/// A window an update is started from, as the mod's update window is: the flow runs on this window's context.
class _UpdateWindow extends ConsumerStatefulWidget {
  const _UpdateWindow({required this.flow, required this.done});

  final Future<bool> Function(BuildContext context, WidgetRef ref) flow;
  final Completer<bool> done;

  @override
  ConsumerState<_UpdateWindow> createState() => _UpdateWindowState();
}

class _UpdateWindowState extends ConsumerState<_UpdateWindow> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async => widget.done.complete(await widget.flow(context, ref)));
  }

  @override
  Widget build(BuildContext context) => const AlertDialog(content: Text('Update window'));
}
