import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/core/palette.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_file.dart';
import 'package:mod_manager_flutter/models/mod_download.dart';
import 'package:mod_manager_flutter/screens/components/downloads_button.dart';
import 'package:mod_manager_flutter/screens/components/downloads_panel.dart';
import 'package:mod_manager_flutter/screens/components/library_actions_host.dart';
import 'package:mod_manager_flutter/screens/components/progress_track.dart';
import 'package:mod_manager_flutter/screens/updates/updates_page.dart';
import 'package:mod_manager_flutter/services/download/download_exceptions.dart';
import 'package:mod_manager_flutter/services/download/download_job.dart';
import 'package:mod_manager_flutter/services/download/download_progress.dart';
import 'package:mod_manager_flutter/services/download/download_queue.dart';
import 'package:mod_manager_flutter/services/download/update_job.dart';
import 'package:mod_manager_flutter/services/origin_write.dart';
import 'package:mod_manager_flutter/services/update_apply/update_applier.dart' show UpdateWriteStep;
import 'package:mod_manager_flutter/services/update_apply/update_layout.dart';
import 'package:mod_manager_flutter/services/update_apply/update_prepare.dart';
import 'package:mod_manager_flutter/services/update_apply/update_run_stages.dart';
import 'package:mod_manager_flutter/services/update_apply/update_target.dart';
import 'package:mod_manager_flutter/services/update_apply/update_write.dart';
import 'package:mod_manager_flutter/services/update_check.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

import 'support/all_mods_harness.dart';
import 'support/library_override.dart';
import 'support/localized_harness.dart';
import 'support/seeded_queue.dart';
import 'support/update_jobs.dart';

/// Where an update run shows (`docs/update-runs.md` §5, §10): the Downloads panel's groups and rows, the sidebar
/// badge, and the Updates page's status cell. Every surface reads the queue's jobs, seeded here.
void main() {
  final dark = ZenithPalette.dark(AccentChoice.violet);
  final aug = DateTime.utc(2026, 8, 12);

  ProviderContainer seeded(List<DownloadJob> jobs, {List<ModInfo> library = const []}) {
    final container = ProviderContainer(
      overrides: [downloadQueueProvider.overrideWith(() => SeededQueue(jobs)), libraryOf(library)],
    );
    addTearDown(container.dispose);
    return container;
  }

  DownloadJob downloading(int seq, {int size = 233 * mb, int received = 79 * mb, double? rate = 4.1 * mb}) =>
      updateJob(seq, state: DownloadJobState.running, size: size).copyWith(
        progress: DownloadProgress(
          state: DownloadState.downloading,
          received: received,
          total: size,
          bytesPerSecond: rate,
        ),
      );

  DownloadJob writing(int seq, UpdateWriteStep? step) {
    final job = updateJob(seq, state: DownloadJobState.updating, step: UpdateStep.writing);
    return step == null ? job : job.withWriting(UpdateWriting('mod$seq', step));
  }

  DownloadJob asking(int seq, UpdateWait wait, {Object? prepared}) =>
      updateJob(seq, state: DownloadJobState.waiting).copyWith(prepared: prepared).withUpdateWait(wait);

  DownloadJob failed(int seq, Object error) => updateJob(seq, state: DownloadJobState.failed, error: error);

  DownloadJob written(int seq, {UpdateReport? report}) => updateJob(seq, state: DownloadJobState.done).copyWith(
        outcome: JobOutcome.updated,
        report: report,
        modResults: [UpdateModResult.written(baseOf('mod$seq', seq))],
      );

  DownloadJob skipped(int seq) => updateJob(seq, state: DownloadJobState.done).copyWith(
        outcome: JobOutcome.skipped,
        skipReason: UpdateSkipReason.skippedByUser,
        modResults: [UpdateModResult.skipped(baseOf('mod$seq', seq), UpdateSkipReason.skippedByUser)],
      );

  const unpack = UpdateUnpacked(root: null, folders: ['/tmp/a/One', '/tmp/a/Two'], archiveMd5: null);
  const foldersKept = UpdateRunKept(
    unpacked: unpack,
    foldersQuestion: FoldersQuestion(
      problem: UpdateLayoutProblem.layoutUnknown,
      unpacked: unpack,
      choices: [
        UpdateFolderChoice(path: '/tmp/a/One', name: 'One', looksLikeMod: true),
        UpdateFolderChoice(path: '/tmp/a/Two', name: 'Two', looksLikeMod: true),
      ],
    ),
  );

  group('the Downloads panel', () {
    Future<void> pumpPanel(WidgetTester t, ProviderContainer container) async {
      await pumpLocalized(
        t,
        Align(
          alignment: Alignment.centerRight,
          child: SizedBox(width: DownloadsPanel.width, height: 1400, child: DownloadsPanel(clock: () => aug)),
        ),
        container: container,
        surfaceSize: const Size(1200, 1500),
        settle: false,
      );
      expectBuilt(DownloadsPanel);
    }

    double top(WidgetTester t, String text) => t.getTopLeft(find.text(text)).dy;

    testWidgets('questions and failures need attention, the rest is Updating in its order, and the footer says so',
        (t) async {
      final container = seeded([
        asking(1, const UpdateWait(UpdateQuestionKind.folders), prepared: foldersKept),
        failed(2, const UpdateFailure(UpdateFailureKind.noSpace, requiredBytes: 2 * mb, availableBytes: mb)),
        downloading(3),
        writing(4, UpdateWriteStep.replacingFiles),
        updateJob(5, size: 50 * mb),
        updateJob(6, size: 80 * mb),
        written(7),
      ]);
      await pumpPanel(t, container);

      expect(find.text('NEEDS YOUR ATTENTION · 2'), findsOneWidget);
      expect(find.text('UPDATING'), findsOneWidget);
      expect(find.textContaining('ONE DOWNLOAD AT A TIME'), findsNothing);
      expect(find.text('FINISHED'), findsOneWidget);
      expect(find.text('Each update keeps the file it replaces as a snapshot.'), findsOneWidget);

      expect(find.text('This update has 2 folders. Pick the ones that replace the mod.'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Pick folders…'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Skip update'), findsOneWidget);
      expect(find.text('Not enough space — 2.0 MB needed, 1.0 MB free. Nothing was changed.'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Remove from the list'), findsOneWidget);
      expect(find.text('Try again'), findsNothing);

      // The order of work: the write, the download, then the line.
      expect(top(t, 'mod 4'), lessThan(top(t, 'mod 3')));
      expect(top(t, 'mod 3'), lessThan(top(t, 'mod 5')));
      expect(top(t, 'mod 5'), lessThan(top(t, 'mod 6')));
      expect(find.text('Installing'), findsOneWidget);
      expect(find.text('The old file is kept: replacing the files'), findsOneWidget);
      expect(find.text('79.0 MB of 233 MB · 4.1 MB/s'), findsOneWidget);
      expect(find.text('34%'), findsOneWidget);
      expect(find.text('50.0 MB · waits for an install to finish'), findsOneWidget,
          reason: 'three are ahead of the install, which is the lookahead full');
      expect(find.text('80.0 MB · 1 ahead of it'), findsOneWidget);
      final dimmed = t.widget<Opacity>(find.ancestor(of: find.text('mod 5'), matching: find.byType(Opacity)).first);
      expect(dimmed.opacity, 0.75);
    });

    testWidgets('the first in line downloads next, and with every place taken by questions it waits for the answers',
        (t) async {
      var container = seeded([updateJob(1, size: 10 * mb), updateJob(2, size: 20 * mb)]);
      await pumpPanel(t, container);
      expect(find.text('10.0 MB · downloads next'), findsOneWidget);
      expect(find.text('20.0 MB · 1 ahead of it'), findsOneWidget);

      container = seeded([
        for (final seq in [1, 2, 3]) asking(seq, const UpdateWait(UpdateQuestionKind.patchShaped)),
        updateJob(4, size: 10 * mb),
      ]);
      await pumpPanel(t, container);
      expect(find.text('10.0 MB · waits for your answers'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Pick folders…'), findsNothing,
          reason: 'a patch-shaped file is not asked here, only skipped');
      expect(find.widgetWithText(TextButton, 'Skip update'), findsNWidgets(3));
    });

    testWidgets("a shared archive's writing line dates the file of the mod being written", (t) async {
      final container = seeded([
        updateJob(1, state: DownloadJobState.updating, step: UpdateStep.writing, mods: [baseOf('mod1', 1), baseOf('Miyabi', 1)])
            .withWriting(const UpdateWriting('Miyabi', UpdateWriteStep.replacingFiles)),
      ]);
      UpdateCheck holding(DateTime date) => UpdateCheck(
            outcome: UpdateOutcome.updateAvailable,
            installedFile: GbFile(idRow: 1, file: 'old.zip', dateAdded: date),
            subject: const DownloadKey.base(1),
          );
      container.read(modUpdateChecksProvider.notifier).state = {
        'mod1': holding(aug),
        'Miyabi': holding(DateTime.utc(2026, 7, 1)),
      };
      await pumpPanel(t, container);
      expect(find.text('The 2026-07-01 file is kept: replacing the files'), findsOneWidget);
    });

    testWidgets('a download in its first second says Connecting...', (t) async {
      await pumpPanel(t, seeded([downloading(1, received: 0, rate: null)]));
      expect(find.text('Connecting...'), findsOneWidget);
    });

    testWidgets('a halted run says what stopped it on the rows it holds, landed and unpacked ones included', (t) async {
      const halt = UpdateHalt(cause: UpdateFailure(UpdateFailureKind.snapshotFailed), bySeq: 9);
      await pumpPanel(
        t,
        seeded([
          updateJob(1, halt: halt),
          updateJob(2, state: DownloadJobState.downloaded, halt: halt),
          updateJob(3, state: DownloadJobState.updating, step: UpdateStep.unpacked, halt: halt),
        ]),
      );
      expect(find.text("Stopped: Couldn't save the old file as a snapshot. Nothing was changed."), findsNWidgets(3));
      expect(find.text('Checking what is in the file'), findsNothing);
      expect(find.text('Unpacking'), findsNothing);
    });

    testWidgets('Clear finished leaves a failed update in Needs your attention', (t) async {
      final container = seeded([
        failed(1, const UpdateFailure(UpdateFailureKind.noSpace, requiredBytes: 2 * mb, availableBytes: mb)),
        written(2),
      ]);
      await pumpPanel(t, container);
      await t.tap(find.widgetWithText(TextButton, 'Clear finished'));
      await t.pump();
      expect([for (final j in container.read(downloadQueueProvider)) j.seq], [1]);
      expect(find.text('NEEDS YOUR ATTENTION · 1'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Clear finished'), findsNothing);
    });
  });

  group('the sidebar badge counts update jobs', () {
    Future<void> pumpItem(WidgetTester t, ProviderContainer container) async {
      await pumpLocalized(t, const Center(child: SizedBox(width: 196, child: DownloadsNavItem())), container: container);
      expectBuilt(DownloadsNavItem);
    }

    testWidgets('an update waiting on a question is the amber pill', (t) async {
      await pumpItem(t, seeded([asking(1, const UpdateWait(UpdateQuestionKind.password)), writing(2, null)]));
      expect(find.byTooltip('1 download needs your attention'), findsOneWidget);
    });

    testWidgets('a failed update is the red pill', (t) async {
      await pumpItem(t, seeded([failed(1, const DownloadNetworkException('gone'))]));
      expect(find.byTooltip('1 download failed'), findsOneWidget);
    });

    testWidgets('updates at work are the plain count', (t) async {
      await pumpItem(t, seeded([downloading(1), writing(2, null), written(3)]));
      expect(find.text('2'), findsOneWidget);
    });
  });

  group("the Updates page's rows", () {
    ModInfo mod(String id) => ModInfo(id: id, name: id, characterId: 'ellen', isActive: false);

    UpdateCheck check(int remoteId) => UpdateCheck(
          outcome: UpdateOutcome.updateAvailable,
          installedFile: GbFile(idRow: 1, file: 'old$remoteId.zip', dateAdded: aug),
          newerFiles: [GbFile(idRow: 2, file: 'new$remoteId.zip', dateAdded: DateTime.utc(2026, 10, 1))],
          subject: DownloadKey.base(remoteId),
        );

    Future<ProviderContainer> pumpUpdates(
      WidgetTester t,
      List<DownloadJob> jobs,
      Map<String, UpdateCheck> checks, {
      required List<String> mods,
    }) async {
      final container = seeded(jobs, library: [for (final id in mods) mod(id)]);
      container.read(modUpdateChecksProvider.notifier).state = checks;
      await loadTableFonts(t);
      await pumpLocalized(
        t,
        LibraryActionsHost(
          updateFetcher: (_) async => throw StateError('no fetch expected'),
          originWriter: (_, _) async => OriginWriteResult.writeFailed,
          child: UpdatesPage(onOpenPage: (_) {}, onShowUpdate: (_) {}),
        ),
        container: container,
        surfaceSize: const Size(1400, 1000),
        settle: false,
      );
      await t.pump();
      expectBuilt(UpdatesPage);
      return container;
    }

    Finder inRow(String mod, Finder finder) => find.descendant(
          of: find.ancestor(of: find.text(mod), matching: find.byKey(ValueKey(mod))),
          matching: finder,
        );

    testWidgets('a mod in a run shows its phase in place of Update and Ignore, one not in a run keeps them',
        (t) async {
      await pumpUpdates(
        t,
        [
          downloading(1),
          asking(2, const UpdateWait(UpdateQuestionKind.password)),
          writing(3, UpdateWriteStep.linking),
          updateJob(4, state: DownloadJobState.downloaded),
          asking(5, const UpdateWait(UpdateQuestionKind.unrecordedPatch)),
          updateJob(6),
        ],
        {for (final (i, id) in ['mod1', 'mod2', 'mod3', 'mod4', 'mod5', 'mod6', 'mod7'].indexed) id: check(i + 1)},
        mods: ['mod1', 'mod2', 'mod3', 'mod4', 'mod5', 'mod6', 'mod7'],
      );

      expect(inRow('mod1', find.text('Downloading')), findsOneWidget);
      final bar = t.widget<ProgressTrack>(inRow('mod1', find.byType(ProgressTrack)));
      expect(bar.value, closeTo(79 / 233, 0.001));
      expect(t.getSize(inRow('mod1', find.byType(ProgressTrack))), const Size(90, 4));
      expect(inRow('mod1', find.text('Update')), findsNothing);
      expect(inRow('mod1', find.text('Ignore')), findsNothing);

      expect(inRow('mod2', find.text('Needs you ·')), findsOneWidget);
      expect(inRow('mod2', find.text('Answer')), findsOneWidget);
      final needsYou = t.widget<Text>(inRow('mod2', find.text('Needs you ·')));
      expect(needsYou.style?.color, dark.badgeInfo.foreground);

      expect(inRow('mod3', find.text('Installing · linking it in')), findsOneWidget);
      expect(t.widget<ProgressTrack>(inRow('mod3', find.byType(ProgressTrack))).value, isNull, reason: 'a sweep');
      expect(inRow('mod4', find.text('Checking what is in the file')), findsOneWidget);
      expect(inRow('mod5', find.text('Skip update')), findsOneWidget, reason: 'a question the app cannot ask yet');
      expect(inRow('mod6', find.text('Waiting to update')), findsOneWidget);

      expect(inRow('mod7', find.text('Update')), findsOneWidget);
      expect(inRow('mod7', find.text('Ignore')), findsOneWidget);
    });

    testWidgets('a written mod keeps its row, read from the verdict its write removed, with the run line', (t) async {
      final removed = check(1);
      final container = await pumpUpdates(
        t,
        [
          written(
            1,
            report: UpdateReport(
              applied: const [],
              outcome: const GroupWriteOutcome(settledMarks: {'mod1'}, changed: true),
              removedMarks: {'mod1': removed},
            ),
          ),
          downloading(2),
        ],
        {'mod2': check(2)},
        mods: ['mod1', 'mod2'],
      );

      expect(inRow('mod1', find.text('Updated')), findsOneWidget);
      expect(t.widget<Text>(inRow('mod1', find.text('Updated'))).style?.color, dark.accent);
      expect(inRow('mod1', find.text('new1.zip')), findsOneWidget, reason: 'the row still reads as it did');
      expect(inRow('mod1', find.text('Update')), findsNothing);
      expect(find.text('1 of 2 updated'), findsOneWidget);

      await t.tap(find.widgetWithText(TextButton, 'Clear finished'));
      await t.pump();
      expect(find.byKey(const ValueKey('mod1')), findsNothing, reason: "Clear finished takes the run's ended rows");
      expect(find.text('0 of 1 updated'), findsOneWidget);
      expect(container.read(downloadQueueProvider), hasLength(1));
    });

    testWidgets('a failure says why under the status, with the figures, and Update comes back; so does a skip',
        (t) async {
      await pumpUpdates(
        t,
        [
          failed(1, const UpdateFailure(UpdateFailureKind.noSpace, requiredBytes: 3 * mb, availableBytes: mb)),
          skipped(2),
          failed(3, const DownloadStalledException('stalled', stallTimeout: Duration(seconds: 60))),
        ],
        {'mod1': check(1), 'mod2': check(2), 'mod3': check(3)},
        mods: ['mod1', 'mod2', 'mod3'],
      );

      expect(inRow('mod1', find.text("Couldn't update")), findsOneWidget);
      expect(t.widget<Text>(inRow('mod1', find.text("Couldn't update"))).style?.color, dark.badgeMissing.foreground);
      expect(inRow('mod1', find.text('Not enough space — 3.0 MB needed, 1.0 MB free. Nothing was changed.')),
          findsOneWidget);
      expect(inRow('mod1', find.text('Update')), findsOneWidget, reason: 'nothing was written, so it can be asked again');

      expect(inRow('mod2', find.text('Skipped · still on the 2026-08-12 file')), findsOneWidget);
      expect(inRow('mod2', find.text('Update')), findsOneWidget);

      expect(inRow('mod3', find.text('Download failed')), findsOneWidget);
      expect(inRow('mod3', find.text('GameBanana stopped sending the file. Nothing was changed.')), findsOneWidget,
          reason: 'no Try again is offered, so none is promised');
    });

    testWidgets("a job that failed for one mod reads each mod's own result", (t) async {
      final partial = updateJob(
        1,
        state: DownloadJobState.failed,
        mods: [baseOf('mod1', 1), baseOf('mod2', 1), baseOf('mod3', 1)],
        error: const UpdateFailure(UpdateFailureKind.writtenPartway),
      ).copyWith(modResults: [
        UpdateModResult.written(baseOf('mod1', 1)),
        const UpdateModResult(
          UpdateMod(modId: 'mod2', layer: DownloadKey.base(1)),
          UpdateModEnd.failed,
          failure: UpdateFailure(UpdateFailureKind.writtenPartway),
        ),
        UpdateModResult.skipped(baseOf('mod3', 1), UpdateSkipReason.beingWritten),
      ]);
      await pumpUpdates(t, [partial], {'mod1': check(1), 'mod2': check(1), 'mod3': check(1)},
          mods: ['mod1', 'mod2', 'mod3']);

      expect(inRow('mod1', find.text('Updated')), findsOneWidget);
      expect(inRow('mod1', find.textContaining('Nothing was changed')), findsNothing);
      expect(inRow('mod2', find.text("Couldn't update")), findsOneWidget);
      expect(inRow('mod3', find.text('Skipped · its folder was being changed')), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Clear finished'), findsNothing,
          reason: 'a failed job is taken off the list only by Remove from the list');
    });

    testWidgets('a halted job that landed reads Stopped with the reason, not as checking', (t) async {
      const halt = UpdateHalt(cause: UpdateFailure(UpdateFailureKind.snapshotFailed), bySeq: 9);
      await pumpUpdates(t, [updateJob(1, state: DownloadJobState.downloaded, halt: halt)], {'mod1': check(1)},
          mods: ['mod1']);
      expect(inRow('mod1', find.text('Stopped')), findsOneWidget);
      expect(inRow('mod1', find.text("Couldn't save the old file as a snapshot. Nothing was changed.")), findsOneWidget);
      expect(inRow('mod1', find.byType(ProgressTrack)), findsNothing);
    });

    testWidgets("a skip's reason is on the row only while a verdict or another job's removed mark keeps the row",
        (t) async {
      DownloadJob settled(int seq, UpdateSkipReason reason, {String? alongWith}) =>
          updateJob(seq, state: DownloadJobState.done).copyWith(
            outcome: JobOutcome.skipped,
            skipReason: reason,
            modResults: [UpdateModResult.skipped(baseOf('mod$seq', seq), reason, alongWith: alongWith)],
          );
      // Miyabi's job wrote mod3's layer too, so its write removed mod3's mark and keeps it.
      final miyabi = updateJob(9, state: DownloadJobState.done, mods: [baseOf('Miyabi', 3), baseOf('mod3', 3)]).copyWith(
        outcome: JobOutcome.updated,
        modResults: [UpdateModResult.written(baseOf('Miyabi', 3)), UpdateModResult.written(baseOf('mod3', 3))],
        report: UpdateReport(
          applied: const [],
          outcome: const GroupWriteOutcome(settledMarks: {'Miyabi', 'mod3'}, changed: true),
          removedMarks: {'mod3': check(3)},
        ),
      );
      await pumpUpdates(
        t,
        [
          miyabi,
          settled(1, UpdateSkipReason.ignoredMeanwhile),
          settled(2, UpdateSkipReason.alreadyUpdated),
          settled(3, UpdateSkipReason.alreadyUpdated, alongWith: 'Miyabi'),
          settled(4, UpdateSkipReason.ignoredMeanwhile),
        ],
        // A restore leaves the session's verdicts as they are, so mod1 and mod2 keep theirs after one brought back a
        // sidecar that dismisses or names the picked file. mod4 was ignored from the update dialog, which took its verdict.
        {'mod1': check(1), 'mod2': check(2)},
        mods: ['mod1', 'mod2', 'mod3', 'mod4', 'Miyabi'],
      );
      expect(inRow('mod1', find.text('Skipped · ignored meanwhile')), findsOneWidget);
      expect(inRow('mod2', find.text('Skipped · already updated')), findsOneWidget);
      expect(inRow('mod3', find.text('Skipped · already updated along with Miyabi')), findsOneWidget);
      expect(find.byKey(const ValueKey('mod4')), findsNothing, reason: 'its skip is read on the Downloads panel');
    });

    testWidgets('a pick that joins a downloading job counts on the run line', (t) async {
      final container =
          await pumpUpdates(t, [downloading(1)], {'mod1': check(1), 'mod2': check(1)}, mods: ['mod1', 'mod2']);
      expect(find.text('0 of 1 updated'), findsOneWidget);

      final job = container.read(downloadQueueProvider).single;
      container.read(downloadQueueProvider.notifier).enqueueUpdate(
            file: job.file,
            subject: 'mod2',
            task: UpdateTask(mods: [baseOf('mod2', 1)]),
          );
      await t.pump();
      expect(container.read(downloadQueueProvider).single.update!.mods, hasLength(2), reason: 'it joined the job');
      expect(find.text('0 of 2 updated'), findsOneWidget);
    });
  });
}
