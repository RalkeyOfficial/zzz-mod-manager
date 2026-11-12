import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_file.dart';
import 'package:mod_manager_flutter/models/mod_download.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/screens/components/library_actions_host.dart';
import 'package:mod_manager_flutter/screens/dialogs/update_modal.dart';
import 'package:mod_manager_flutter/services/download/download_job.dart';
import 'package:mod_manager_flutter/services/download/download_queue.dart';
import 'package:mod_manager_flutter/services/download/download_request.dart';
import 'package:mod_manager_flutter/services/download/update_job.dart';
import 'package:mod_manager_flutter/services/update_check.dart';
import 'package:mod_manager_flutter/utils/notifications.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

import 'support/all_mods_harness.dart';
import 'support/library_override.dart';
import 'support/localized_harness.dart';
import 'support/origin_shorthand.dart';
import 'support/seeded_queue.dart';

/// The press of "Update N" (`docs/update-runs.md` §3, §9): the picks go into the download queue as a run and the list
/// closes, with no window per mod, and the button is never held off by the run.
void main() {
  ModInfo mod(String id, int modId, {String? uid, DateTime? dismissed}) => ModInfo(
        id: id,
        name: '$id Outfit',
        characterId: 'ellen',
        isActive: false,
        uid: uid,
        origin: originFixture(
          modId: modId,
          modIdConfidence: OriginConfidence.exact,
          fileId: 1,
          versionConfidence: OriginConfidence.exact,
        ).copyBase(updatesDismissedUntil: dismissed),
      );

  final ignoredUntil = DateTime.utc(2026, 9, 1);

  GbFile newer(int fileId) => GbFile(idRow: fileId, file: 'f$fileId.zip', dateAdded: DateTime.utc(2026, 10, 1));

  UpdateCheck withFile(int modId, int fileId) => UpdateCheck(
        outcome: UpdateOutcome.updateAvailable,
        newerFiles: [newer(fileId)],
        subject: DownloadKey.base(modId),
      );

  final mods = [mod('A', 100, uid: 'uid-a', dismissed: ignoredUntil), mod('B', 200, uid: 'uid-b')];

  testWidgets('the press puts every pick in the queue and closes the list, with no window per mod', (tester) async {
    final queue = _RecordingQueue();
    final container = await pumpAllModsTable(
      tester,
      mods,
      overrides: [downloadQueueProvider.overrideWith(() => queue)],
    );
    container.read(modUpdateChecksProvider.notifier).state = {'A': withFile(100, 2), 'B': withFile(200, 3)};
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Update 2'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Update 2 mods'));
    await tester.pumpAndSettle();

    expect(find.byType(UpdateModal), findsNothing, reason: 'the list closes on the press');
    expect(find.byType(Dialog), findsNothing, reason: 'nothing is confirmed, waited on or reported in a window');
    expect(queue.pressed, hasLength(1), reason: 'one press is one call');
    final press = queue.pressed.single;
    expect([for (final p in press) p.task.primary.modId], ['A', 'B']);
    expect(press.first.file.idRow, 2);
    expect(press.first.subject, 'A Outfit');
    expect(press.first.characterId, 'ellen');
    expect(press.first.task.primary.layer, const DownloadKey.base(100));
    expect(press.first.task.primary.uid, 'uid-a');
    expect(press.first.task.primary.heldFileId, 1, reason: 'the file the layer held, to tell a write meanwhile');
    expect(press.first.task.primary.heldDismissedUntil, ignoredUntil,
        reason: 'the dismissal the layer held, so only one written since reads as an Ignore');
    expect(press.first.task.primary.name, 'A Outfit');
    expect(press.first.task.published.map((f) => f.idRow), [2]);
  });

  testWidgets('a mod gone from the library between the list and the press is left out', (tester) async {
    final queue = _RecordingQueue();
    final container = ProviderContainer(
      overrides: [libraryOf([mods.first]), downloadQueueProvider.overrideWith(() => queue)],
    );
    addTearDown(container.dispose);
    await pumpLocalized(
      tester,
      LibraryActionsHost(
        child: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => LibraryActionsHost.of(context).updateMods([
              for (final (id, modId) in [('A', 100), ('B', 200)])
                UpdatePick(modId: id, file: newer(2), subject: DownloadKey.base(modId), published: [newer(2)]),
            ]),
            child: const Text('press'),
          ),
        ),
      ),
      container: container,
    );
    expectBuilt(ElevatedButton);

    await tester.tap(find.text('press'));
    await tester.pump();

    expect([for (final p in queue.pressed.single) p.task.primary.modId], ['A']);
  });

  testWidgets('a pick that adds nothing says so, rather than closing as if it worked', (tester) async {
    // Adds A and not B, as the queue does when B's file is already in another download.
    final queue = _RecordingQueue(adds: {'A'});
    final container = ProviderContainer(
      overrides: [libraryOf(mods), downloadQueueProvider.overrideWith(() => queue)],
    );
    addTearDown(container.dispose);
    await pumpLocalized(
      tester,
      LibraryActionsHost(
        child: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => LibraryActionsHost.of(context).updateMods([
              UpdatePick(modId: 'A', file: newer(2), subject: const DownloadKey.base(100), published: [newer(2)]),
              UpdatePick(modId: 'B', file: newer(3), subject: const DownloadKey.base(200), published: [newer(3)]),
            ]),
            child: const Text('press'),
          ),
        ),
      ),
      container: container,
    );
    expectBuilt(ElevatedButton);

    await tester.tap(find.text('press'));
    await tester.pump();

    final note = container.read(notificationsProvider).single;
    expect(note.kind, NotificationKind.note);
    expect(note.title, '1 update not added: its file is already in another download');
    expect(note.body, 'B Outfit');
  });
}

/// A queue that keeps what each press asked for and starts nothing, so no transfer leaves the test.
/// It answers a job for the picks of the mods in [adds] and nothing for the rest.
class _RecordingQueue extends SeededQueue {
  _RecordingQueue({this.adds = const {}}) : super(const []);

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
