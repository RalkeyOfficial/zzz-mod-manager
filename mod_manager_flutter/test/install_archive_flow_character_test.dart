import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/gamebanana/gamebanana.dart';
import 'package:mod_manager_flutter/models/install_result.dart';
import 'package:mod_manager_flutter/screens/dialogs/install_archive_flow.dart';
import 'package:mod_manager_flutter/services/download/download_handle.dart';
import 'package:mod_manager_flutter/services/download/download_job.dart';
import 'package:mod_manager_flutter/services/download/download_queue.dart';
import 'package:mod_manager_flutter/services/download/download_request.dart';
import 'package:path/path.dart' as p;

import 'support/library_override.dart';
import 'support/localized_harness.dart';
import 'support/temp_library.dart';

/// The character a Browse install files its mod under is the one the job carries, the mod page's pick, and the
/// import is told it: not the GameBanana category's, which the user may have changed, and not the folder name's.
/// A page that names no character carries Unassigned, which the import honours too.
///
/// The whole install over a real zip and a library in a temp directory, since the part worth trusting is the sidecar
/// the import writes.
void main() {
  /// A zip at [path] holding one mod folder named [folder].
  File zipOf(String path, String folder) {
    final archive = Archive();
    final ini = '[TextureOverrideBody]\nhash = 1\n'.codeUnits;
    archive.addFile(ArchiveFile('$folder/mod.ini', ini.length, ini));
    return File(path)..writeAsBytesSync(ZipEncoder().encode(archive)!);
  }

  // A Zhao skin whose name reads as Nicole, filed under Ellen Joe upstream: three different answers.
  const page = GbMod(
    idRow: 900001,
    name: 'Zhao Nicole',
    category: GbCategoryRef(idRow: 30306, name: 'Ellen Joe'),
    superCategory: GbCategoryRef(idRow: 30305, name: 'Character Skins'),
  );

  late TempLibrary temp;
  late Directory downloads;
  late BuildContext context;
  late WidgetRef ref;
  late _HeldQueue queue;

  Future<void> mount(WidgetTester tester) async {
    await tester.runAsync(() async {
      temp = await TempLibrary.create();
      downloads = Directory.systemTemp.createTempSync('zzz_flow_zip_');
    });
    addTearDown(() => downloads.deleteSync(recursive: true));
    queue = _HeldQueue();
    await pumpLocalized(
      tester,
      Consumer(
        builder: (c, r, _) {
          context = c;
          ref = r;
          return const SizedBox.shrink();
        },
      ),
      overrides: [...temp.overrides, libraryOf(const []), downloadQueueProvider.overrideWith(() => queue)],
    );
    ref.read(downloadQueueProvider);
  }

  /// Runs the install of [file] from [mod], an archive named after the file holding one [folder], as job [seq].
  Future<InstallResult?> run(
    WidgetTester tester, {
    int seq = 1,
    GbMod mod = page,
    GbFile file = const GbFile(idRow: 900002, file: 'Zhao Nicole.zip'),
    String folder = 'Zhao Nicole',
    required String? characterId,
  }) async {
    InstallResult? result;
    await tester.runAsync(() async {
      final zip = zipOf(p.join(downloads.path, file.file!), folder);
      final job = DownloadJob(
        seq: seq,
        request: DownloadRequest(url: Uri.parse('https://gamebanana.com/dl/${file.idRow}')),
        intent: DownloadIntent.install,
        subject: mod.name!,
        file: file,
        mod: mod,
        characterId: characterId,
        state: DownloadJobState.installing,
        result: DownloadResult(file: zip, totalBytes: zip.lengthSync()),
      );
      queue.add(job);
      final step = await runArchiveInstall(context, ref, job);
      result = (step as InstallEnds).result;
      queue.finished(seq, result!.mods);
    });
    await tester.pumpAndSettle();
    return result;
  }

  String? characterOf(String mod) {
    final sidecar = temp.read(mod, '.zzz-mod-manager/metadata.json');
    return sidecar == null ? null : (jsonDecode(sidecar) as Map<String, dynamic>)['character_id'] as String?;
  }

  testWidgets("the import files the mod under the job's character, over the category and the folder name", (
    tester,
  ) async {
    await mount(tester);
    final result = await run(tester, characterId: 'anby');
    expect(result?.mods, ['Zhao Nicole']);
    expect(result?.characterId, 'anby');
    expect(characterOf('Zhao Nicole'), 'anby');
  });

  testWidgets("the category's character, when that is what the page showed", (tester) async {
    await mount(tester);
    await run(tester, characterId: 'ellen');
    expect(characterOf('Zhao Nicole'), 'ellen', reason: 'not Nicole, which the folder name reads as');
  });

  testWidgets('a page that names no character files the mod under Unassigned, not under the folder name', (
    tester,
  ) async {
    await mount(tester);
    const misc = GbMod(
      idRow: 900003,
      name: 'Zhao Nicole',
      category: GbCategoryRef(idRow: 29496, name: 'Other/Misc'),
    );
    final result = await run(tester, mod: misc, characterId: 'unknown');
    expect(result?.mods, ['Zhao Nicole']);
    expect(characterOf('Zhao Nicole'), isNull, reason: 'Unassigned, stored as absence; the name reads as Nicole');
    expect(temp.read('Zhao Nicole', '.zzz-mod-manager/metadata.json'), isNot(contains('"unknown"')),
        reason: 'the placeholder never reaches disk');
  });

  testWidgets('two files of one page with the same folder inside install side by side, the later one named after '
      'its variant', (tester) async {
    await mount(tester);
    const ellen = GbMod(idRow: 900010, name: 'Ellen Maid');
    final first = await run(
      tester,
      mod: ellen,
      file: const GbFile(idRow: 1, file: 'ellen_maid.zip', description: 'Default'),
      folder: 'Ellen Maid',
      characterId: 'ellen',
    );
    final second = await run(
      tester,
      seq: 2,
      mod: ellen,
      file: const GbFile(idRow: 2, file: 'ellen_maid_white.zip', description: 'White hair ver.'),
      folder: 'Ellen Maid',
      characterId: 'ellen',
    );
    final third = await run(
      tester,
      seq: 3,
      mod: ellen,
      file: const GbFile(idRow: 3, file: 'ellen_maid_white2.zip', description: 'White hair ver.'),
      folder: 'Ellen Maid',
      characterId: 'ellen',
    );

    expect(first?.mods, ['Ellen Maid']);
    expect(second?.mods, ['Ellen Maid (White hair ver)'], reason: 'never skipped as already in the library');
    expect(third?.mods, ['Ellen Maid (White hair ver) (2)']);
    for (final mod in ['Ellen Maid', 'Ellen Maid (White hair ver)', 'Ellen Maid (White hair ver) (2)']) {
      expect(temp.has(mod, 'mod.ini'), isTrue, reason: mod);
      expect(characterOf(mod), 'ellen', reason: mod);
    }
  });

  testWidgets('a folder name another mod page installed is still left alone', (tester) async {
    await mount(tester);
    await run(
      tester,
      mod: const GbMod(idRow: 900020, name: 'Ellen Maid'),
      file: const GbFile(idRow: 1, file: 'ellen_maid.zip'),
      folder: 'Ellen Maid',
      characterId: 'ellen',
    );
    final other = await run(
      tester,
      seq: 2,
      mod: const GbMod(idRow: 900021, name: 'Another Ellen Maid'),
      file: const GbFile(idRow: 2, file: 'another.zip', description: 'v2'),
      folder: 'Ellen Maid',
      characterId: 'ellen',
    );
    expect(other?.mods, isEmpty);
    expect(temp.modFolder('Ellen Maid (v2)').existsSync(), isFalse);
  });
}

/// The queue's rows the install reads: each job as it runs, then as finished with what it installed.
class _HeldQueue extends DownloadQueue {
  @override
  List<DownloadJob> build() {
    super.build();
    return const [];
  }

  void add(DownloadJob job) => state = [...state, job];

  void finished(int seq, List<String> mods) => markDone(seq, outcome: JobOutcome.installed, installed: mods);
}
