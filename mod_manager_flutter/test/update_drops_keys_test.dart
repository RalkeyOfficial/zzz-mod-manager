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
import 'package:mod_manager_flutter/services/download/download_queue.dart';
import 'package:mod_manager_flutter/services/download/download_service.dart';
import 'package:mod_manager_flutter/utils/notifications.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';
import 'package:path/path.dart' as p;

import 'support/fake_download_transport.dart';
import 'support/localized_harness.dart';
import 'support/origin_shorthand.dart';
import 'support/recording_service.dart';
import 'support/system_temp.dart';
import 'support/temp_library.dart';

/// An update drops the mod's cached keys whether or not it lands: a write that failed part-way may still have changed
/// the folder, and a file written over one of the same size can keep its times on NTFS, so the `.ini` stamp alone
/// could miss it (`docs/library-screen.md` §12). While it writes, the mod is marked as being written, which holds a
/// press on its switch (§16).
///
/// The writes fail where they fail last, at the record, after the files are in.
void main() {
  const modName = 'Ellen';
  const patchId = 605460;

  late TempLibrary temp;
  late RecordingService service;
  late FakeDownloadTransport transport;

  /// Every mod marked as being written while the flow ran, which is what holds a press on its switch.
  late Set<String> markedWriting;

  /// The container the last flow ran in, and every card raised there in every state it was in.
  late ProviderContainer flowContainer;
  late List<AppNotification> raised;

  setUp(() async {
    temp = await TempLibrary.create(prefix: 'zzz_update_keys_');
    service = RecordingService(temp);
    transport = FakeDownloadTransport();
    markedWriting = {};
    raised = [];
  });

  /// Serves a zip of [files] as file [fileId] of the mod's page.
  GbFile serve(int fileId, Map<String, String> files) {
    final archive = Archive();
    for (final entry in files.entries) {
      final bytes = utf8.encode(entry.value);
      archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
    }
    final body = ZipEncoder().encode(archive)!;
    final url = Uri.parse('https://gamebanana.com/dl/$fileId');
    transport.enqueue(url, body: body);
    return GbFile(idRow: fileId, file: 'ellen$fileId.zip', filesize: body.length, downloadUrl: '$url');
  }

  Future<ModInfo> installed(WidgetTester tester, ModOrigin origin) async {
    temp.write(modName, 'Ellen.ini', '[KeySwap]\nkey = VK_1\n');
    await tester.runAsync(() => temp.writeOrigin(modName, origin));
    return ModInfo(id: modName, name: modName, characterId: 'ellen', isActive: false, origin: origin);
  }

  /// Runs [flow] from a button, with every origin write refused once it starts, and waits for it to end.
  Future<bool?> runFailingAtTheRecord(
    WidgetTester tester,
    Future<bool> Function(BuildContext context, WidgetRef ref) flow,
  ) async {
    bool? changed;
    final container = ProviderContainer(overrides: [
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
    flowContainer = container;
    container.listen(modWritesInProgressProvider, (_, writing) => markedWriting.addAll(writing));
    container.listen(notificationsProvider, (_, next) => raised.addAll(next));
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
    service.failOriginWrites = true;

    // The download's progress window spins until the flow ends, so the frames are pumped by hand.
    await tester.runAsync(() => tester.tap(find.text('update')));
    for (var i = 0; i < 100 && changed == null; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    expect(changed, isNotNull, reason: 'the flow never ended');
    return changed;
  }

  testWidgets("an update that fails after writing the folder drops the mod's keys, and marked it while writing",
      (tester) async {
    final mod = await installed(
      tester,
      originFixture(
        modId: 100,
        modIdConfidence: OriginConfidence.exact,
        fileId: 1,
        versionConfidence: OriginConfidence.exact,
        ingest: const ModIngest(folders: [modName]),
      ),
    );
    final file = serve(2, {'Ellen/Ellen.ini': '[KeySwap]\nkey = VK_2\n'});

    await runFailingAtTheRecord(
      tester,
      (context, ref) => applyUpdateFlow(context, ref, mod: mod, remoteModId: 100, file: file, confirm: false),
    );

    expect(temp.read(modName, 'Ellen.ini'), contains('VK_2'), reason: 'the new files are in');
    expect(service.keysDropped, contains(modName));
    expect(markedWriting, {modName}, reason: "a press on the mod's switch waits for the write");
  });

  testWidgets('a write into one folder shows a Working card, which becomes its failure with Copy details',
      (tester) async {
    final mod = await installed(
      tester,
      originFixture(
        modId: 100,
        modIdConfidence: OriginConfidence.exact,
        fileId: 1,
        versionConfidence: OriginConfidence.exact,
        ingest: const ModIngest(folders: [modName]),
      ),
    );
    final file = serve(2, {'Ellen/Ellen.ini': '[KeySwap]\nkey = VK_2\n'});

    await runFailingAtTheRecord(
      tester,
      (context, ref) => applyUpdateFlow(context, ref, mod: mod, remoteModId: 100, file: file, confirm: false),
    );

    final working = raised.where((n) => n.kind == NotificationKind.working && n.title == 'Updating…').toList();
    expect(working, isNotEmpty);
    expect(working.first.body, modName);
    expect(working.first.characterId, 'ellen');
    final card = flowContainer.read(notificationsProvider).single;
    expect(card.id, working.first.id, reason: 'the Working card became the failure rather than raising a second card');
    expect(card.kind, NotificationKind.error);
    expect(card.title, 'The update failed');
    expect(card.actions.map((a) => a.label), ['Copy details']);
  });

  testWidgets("the base a dropped patch named is written under its own title, not the update's", (tester) async {
    final mod = await installed(
      tester,
      originFixture(
        modId: 100,
        modIdConfidence: OriginConfidence.exact,
        fileId: 1,
        versionConfidence: OriginConfidence.exact,
        ingest: const ModIngest(folders: [modName]),
      ),
    );
    final file = serve(2, {'Ellen/Ellen.ini': '[KeySwap]\nkey = VK_2\n'});

    await runFailingAtTheRecord(
      tester,
      (context, ref) =>
          applyUpdateFlow(context, ref, mod: mod, remoteModId: 100, file: file, asCompanion: true, confirm: false),
    );

    final titles = [for (final n in raised) if (n.kind == NotificationKind.working) n.title];
    expect(titles, contains('Installing the mod it patches…'));
    expect(titles, isNot(contains('Updating…')));
  });

  testWidgets("a patch update that fails after writing the folder drops the mod's keys, and marked it while writing",
      (tester) async {
    temp.write(modName, 'Textures/Patch.dds', 'v1');
    final mod = await installed(
      tester,
      originFixture(
        modId: 100,
        modIdConfidence: OriginConfidence.exact,
        patches: [
          patchFixture(
            modId: patchId,
            files: const [InstalledFile(path: 'Textures/Patch.dds', role: InstalledFileRole.added)],
          ),
        ],
      ),
    );
    final file = serve(3, {'Ellen Fix/Textures/Patch.dds': 'v2'});

    final changed = await runFailingAtTheRecord(
      tester,
      (context, ref) => applyPatchUpdateFlow(context, ref, mod: mod, remoteModId: patchId, file: file, asCompanion: true),
    );

    expect(changed, isFalse);
    expect(temp.read(modName, 'Textures/Patch.dds'), 'v2', reason: 'the new files are in');
    expect(service.keysDropped, contains(modName));
    expect(markedWriting, {modName}, reason: "a press on the mod's switch waits for the write");
  });

  group('the unpack an update made', () {
    // The system temp folder is pointed into the library's, so what an update leaves there can be seen apart from
    // other tests' work.
    late Directory systemTemp;
    setUp(() {
      systemTemp = Directory(p.join(temp.root.path, 'system_temp'))..createSync();
      IOOverrides.global = SystemTempIn(systemTemp);
    });
    tearDown(() => IOOverrides.global = null);

    List<String> leftOver() => [
          for (final entry in systemTemp.listSync())
            if (p.basename(entry.path).startsWith('zzz_archive_extract_')) p.basename(entry.path),
        ];

    testWidgets('is deleted whole when the mod came out a level down, as Mods/<mod>', (tester) async {
      final mod = await installed(
        tester,
        originFixture(
          modId: 100,
          modIdConfidence: OriginConfidence.exact,
          fileId: 1,
          versionConfidence: OriginConfidence.exact,
          ingest: const ModIngest(folders: [modName]),
        ),
      );
      final file = serve(2, {'Mods/Ellen/Ellen.ini': '[KeySwap]\nkey = VK_2\n'});

      await runFailingAtTheRecord(
        tester,
        (context, ref) => applyUpdateFlow(context, ref, mod: mod, remoteModId: 100, file: file, confirm: false),
      );

      expect(temp.read(modName, 'Ellen.ini'), contains('VK_2'), reason: 'the unpack ran and was written from');
      expect(leftOver(), isEmpty);
    });

    testWidgets("and a patch update's too", (tester) async {
      temp.write(modName, 'Textures/Patch.dds', 'v1');
      final mod = await installed(
        tester,
        originFixture(
          modId: 100,
          modIdConfidence: OriginConfidence.exact,
          patches: [
            patchFixture(
              modId: patchId,
              files: const [InstalledFile(path: 'Textures/Patch.dds', role: InstalledFileRole.added)],
            ),
          ],
        ),
      );
      final file = serve(3, {'Mods/Ellen Fix/Textures/Patch.dds': 'v2'});

      await runFailingAtTheRecord(
        tester,
        (context, ref) =>
            applyPatchUpdateFlow(context, ref, mod: mod, remoteModId: patchId, file: file, asCompanion: true),
      );

      expect(temp.read(modName, 'Textures/Patch.dds'), 'v2', reason: 'the unpack ran and was written from');
      expect(leftOver(), isEmpty);
    });
  });
}