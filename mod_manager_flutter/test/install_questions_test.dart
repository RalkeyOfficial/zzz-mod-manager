import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/gamebanana/gamebanana.dart';
import 'package:mod_manager_flutter/screens/dialogs/import_selection_dialog.dart';
import 'package:mod_manager_flutter/screens/dialogs/install_archive_flow.dart';
import 'package:mod_manager_flutter/screens/dialogs/patch_install_prompt.dart';
import 'package:mod_manager_flutter/services/download/download_handle.dart';
import 'package:mod_manager_flutter/services/download/download_job.dart';
import 'package:mod_manager_flutter/services/download/download_request.dart';
import 'package:path/path.dart' as p;

import 'support/localized_harness.dart';
import 'support/temp_library.dart';

/// The install's questions over a real library in a temp directory and real archives: each one makes the install
/// wait without a window, and each answer lets the next run finish.
void main() {
  const page = GbMod(idRow: 700001, name: 'Ellen Swimsuit');

  /// A zip at [file] holding [entries], path to contents.
  File zipOf(File file, Map<String, String> entries) {
    final archive = Archive();
    for (final entry in entries.entries) {
      final bytes = entry.value.codeUnits;
      archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
    }
    return file..writeAsBytesSync(ZipEncoder().encode(archive)!);
  }

  const modIni = '[TextureOverrideBody]\nhash = 1\n';
  // An `.ini` loading a texture the folder does not hold: a patch for another mod.
  const patchIni = '[TextureOverrideBody]\nps-t0 = R\n\n[R]\nfilename = Body.dds\n';

  DownloadJob jobFor(File archive, {Object? prepared, InstallWait? wait, String? password}) => DownloadJob(
        seq: 1,
        request: DownloadRequest(url: Uri.parse('https://gamebanana.com/dl/700002')),
        intent: DownloadIntent.install,
        subject: 'Ellen Swimsuit',
        file: GbFile(idRow: 700002, file: p.basename(archive.path)),
        mod: page,
        characterId: 'ellen',
        state: DownloadJobState.installing,
        result: DownloadResult(file: archive, totalBytes: 1, requestedName: p.basename(archive.path)),
        prepared: prepared,
        wait: wait,
        password: password,
      );

  late TempLibrary temp;
  late Directory downloads;
  late BuildContext context;
  late WidgetRef ref;

  Future<void> mount(WidgetTester tester) async {
    await tester.runAsync(() async {
      temp = await TempLibrary.create();
      downloads = Directory.systemTemp.createTempSync('zzz_questions_dl_');
      addTearDown(() => downloads.deleteSync(recursive: true));
    });
    await pumpLocalized(
      tester,
      Consumer(
        builder: (c, r, _) {
          context = c;
          ref = r;
          return const SizedBox.shrink();
        },
      ),
      overrides: temp.overrides,
    );
  }

  Future<InstallStep> run(WidgetTester tester, DownloadJob job) async {
    late InstallStep step;
    await tester.runAsync(() async => step = await runArchiveInstall(context, ref, job));
    return step;
  }

  testWidgets('several folders: the install waits with the unpacked folders, and the folder pick finishes it',
      (tester) async {
    await mount(tester);
    final archive = zipOf(File(p.join(downloads.path, 'Ellen Pack.zip')), {
      'Ellen A/a.ini': modIni,
      'Ellen B/b.ini': modIni,
    });

    final step = await run(tester, jobFor(archive));

    expect(step, isA<InstallWaits>());
    final waits = step as InstallWaits;
    expect(waits.wait.question, InstallQuestion.severalFolders);
    expect(waits.wait.folderCount, 2);
    expect(archive.existsSync(), isFalse, reason: 'unpacked, so the archive is spent');
    expect(waits.prepared.folders, hasLength(2));
    expect(waits.prepared.folders.every((f) => Directory(f).existsSync()), isTrue,
        reason: 'the waiting job keeps its unpacked folders');
    expect(temp.mods.listSync(), isEmpty, reason: 'nothing installed while it waits');

    // The answer the picker gives: one folder, on its own. No patch, so nothing else to ask.
    final chosen = waits.prepared.folders.firstWhere((f) => p.basename(f) == 'Ellen B');
    final answered = waits.prepared.copyWith(
      plan: ImportPlan(folders: [chosen], combine: false, combinedName: ''),
    );
    final done = await run(tester, jobFor(archive, prepared: answered));

    expect(done, isA<InstallEnds>());
    expect((done as InstallEnds).result.mods, ['Ellen B']);
    expect(Directory(p.join(temp.mods.path, 'Ellen B')).existsSync(), isTrue);
    expect(Directory(p.join(temp.mods.path, 'Ellen A')).existsSync(), isFalse);
    expect(Directory(waits.prepared.folders.first).parent.existsSync(), isFalse,
        reason: 'a finished install deletes its temp folder');
  });

  testWidgets('already installed: a second install of the same archive waits, and Install anyway answers it',
      (tester) async {
    await mount(tester);
    final first = zipOf(File(p.join(downloads.path, 'Ellen Swimsuit.zip')), {'Ellen Swimsuit/mod.ini': modIni});
    final bytes = first.readAsBytesSync();
    final installed = await run(tester, jobFor(first));
    expect((installed as InstallEnds).result.mods, ['Ellen Swimsuit']);

    final again = File(p.join(downloads.path, 'Ellen Swimsuit (2).zip'))..writeAsBytesSync(bytes);
    final step = await run(tester, jobFor(again));
    expect(step, isA<InstallWaits>());
    final waits = step as InstallWaits;
    expect(waits.wait.question, InstallQuestion.alreadyInstalled);
    expect(waits.wait.installedAs, ['Ellen Swimsuit']);

    // The row's Install anyway: no dialog, since one folder and no patch leave nothing else to ask.
    late InstallAnswer answer;
    await tester.runAsync(() async {
      answer = await answerInstallQuestion(context, ref, jobFor(again, prepared: waits.prepared, wait: waits.wait));
    });
    expect(answer, isA<AnswerGiven>());
    final prepared = (answer as AnswerGiven).prepared!;
    expect(prepared.duplicateAnswered, isTrue);
    expect(prepared.destinations, isEmpty);

    final done = await run(tester, jobFor(again, prepared: prepared));
    expect(done, isA<InstallEnds>(), reason: 'the answered question is not asked again');
  });

  testWidgets('a patch: the install waits, and the prompt answers it, keeps it waiting, or ends it', (tester) async {
    await mount(tester);
    final archive = zipOf(File(p.join(downloads.path, 'Ellen Fix.zip')), {'Ellen Fix/fix.ini': patchIni});

    final step = await run(tester, jobFor(archive));
    expect(step, isA<InstallWaits>());
    final waits = step as InstallWaits;
    expect(waits.wait.question, InstallQuestion.patch);
    final waiting = jobFor(archive, prepared: waits.prepared, wait: waits.wait);

    Future<InstallAnswer> answerWith(PatchPromptAnswer? reply) async {
      late InstallAnswer answer;
      await tester.runAsync(() async {
        answer = await answerInstallQuestion(
          context,
          ref,
          waiting,
          prompt: (context, {required List<PatchInstallSubject> subjects, required List<ModInfo> library, bool combined = false}) async {
            expect(subjects.map((s) => s.modName), ['Ellen Fix']);
            return reply;
          },
        );
      });
      return answer;
    }

    final kept = await answerWith(null);
    expect(kept, isA<AnswerKept>(), reason: 'a prompt closed without an answer puts the question back');
    expect((kept as AnswerKept).wait.question, InstallQuestion.patch);

    expect(await answerWith(const PatchPromptAnswer.declined()), isA<AnswerDeclined>());

    final given = await answerWith(const PatchPromptAnswer({'Ellen Fix': InstallAsNewMod()}));
    expect(given, isA<AnswerGiven>());
    final done = await run(tester, jobFor(archive, prepared: (given as AnswerGiven).prepared));
    expect((done as InstallEnds).result.mods, ['Ellen Fix']);
  });

  testWidgets('a closed folder picker keeps the download waiting at that question', (tester) async {
    await mount(tester);
    final archive = zipOf(File(p.join(downloads.path, 'Pack.zip')), {'A/a.ini': modIni, 'B/b.ini': modIni});
    final waits = await run(tester, jobFor(archive)) as InstallWaits;

    InstallAnswer? answer;
    await pumpLocalized(
      tester,
      Consumer(
        builder: (c, r, _) => TextButton(
          onPressed: () async =>
              answer = await answerInstallQuestion(c, r, jobFor(archive, prepared: waits.prepared, wait: waits.wait)),
          child: const Text('answer'),
        ),
      ),
      overrides: temp.overrides,
    );
    await tapWithIo(tester, find.text('answer'));
    expect(find.byType(AlertDialog), findsOneWidget, reason: 'the folder picker, asked from the press');
    await tapWithIo(tester, find.text('Cancel'));

    expect(answer, isA<AnswerKept>());
    expect((answer as AnswerKept).wait.question, InstallQuestion.severalFolders);
    expect(waits.prepared.folders.every((f) => Directory(f).existsSync()), isTrue);
  });
}
