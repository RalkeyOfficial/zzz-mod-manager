import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/core/palette.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_file.dart';
import 'package:mod_manager_flutter/models/mod_download.dart';
import 'package:mod_manager_flutter/screens/components/downloads_panel.dart';
import 'package:mod_manager_flutter/screens/components/library_actions_host.dart';
import 'package:mod_manager_flutter/screens/updates/updates_page.dart';
import 'package:mod_manager_flutter/services/backup/snapshot_service.dart';
import 'package:mod_manager_flutter/services/download/download_job.dart';
import 'package:mod_manager_flutter/services/download/download_queue.dart';
import 'package:mod_manager_flutter/services/download/update_job.dart';
import 'package:mod_manager_flutter/services/origin_write.dart';
import 'package:mod_manager_flutter/services/update_apply/keybind_changes.dart';
import 'package:mod_manager_flutter/services/update_apply/update_applier.dart';
import 'package:mod_manager_flutter/services/update_apply/update_target.dart';
import 'package:mod_manager_flutter/services/update_apply/update_undo.dart';
import 'package:mod_manager_flutter/services/update_apply/update_write.dart';
import 'package:mod_manager_flutter/services/update_check.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

import 'support/all_mods_harness.dart';
import 'support/library_override.dart';
import 'support/localized_harness.dart';
import 'support/seeded_queue.dart';
import 'support/update_jobs.dart';

/// Every reason a press of Undo stores, with its words.
const _storedReasons = [
  (UpdateUndoProblem.snapshotGone, 'the snapshot was pruned'),
  (UpdateUndoProblem.folderGone, 'the folder was renamed or removed'),
  (UpdateUndoProblem.writtenSince, 'the folder changed since the update'),
  (UpdateUndoProblem.notRead, "the folder couldn't be read, so nothing was changed"),
  (UpdateUndoProblem.notSaved, "the folder couldn't be saved as a snapshot first, so nothing was changed"),
  (UpdateUndoProblem.recordNotRemoved, "the patch's files were already gone and its record couldn't be removed; no file was moved"),
  (UpdateUndoProblem.partWay, 'it stopped part-way and the folder is not as it was; History has its saved versions'),
];

/// What the finished rows of an update run say and offer (`docs/update-runs.md` §5, §8, §10): Undo while the rule offers it,
/// the plain row when it does not, "Couldn't undo" with its reason, the undone row, the snapshot date, the files removed,
/// the hotkey list, the folders left out, and a line for each mod of a shared archive on the Downloads panel.
void main() {
  final aug = DateTime.utc(2026, 8, 12);

  ModInfo mod(String id) => ModInfo(id: id, name: id, characterId: 'ellen', isActive: false, uid: 'uid-$id');

  UpdateCheck check(int remoteId) => UpdateCheck(
        outcome: UpdateOutcome.updateAvailable,
        installedFile: GbFile(idRow: 1, file: 'old$remoteId.zip', dateAdded: aug),
        newerFiles: [GbFile(idRow: 2, file: 'new$remoteId.zip', dateAdded: DateTime.utc(2026, 10, 1))],
        subject: DownloadKey.base(remoteId),
      );

  UpdateUndoRecord record(String folder) => UpdateUndoRecord(
        folderId: folder,
        snapshot: ModSnapshot(
          modName: folder,
          modUid: 'uid-$folder',
          id: 's-$folder',
          takenAt: aug,
          sizeBytes: 1,
          directory: Directory('/nonexistent/$folder'),
        ),
        writesStarted: 1,
      );

  /// What the write did to [folder]: [dropped] files removed and the Swap key moved from F7 to F8.
  AppliedUpdate applied(String folder, {int dropped = 2}) => AppliedUpdate(
        mod: mod(folder),
        result: UpdateApplyResult(
          snapshot: null,
          filesWritten: 3,
          reactivated: false,
          droppedFiles: [for (var i = 0; i < dropped; i++) 'old$i.dds'],
          keybindChanges: const [
            KeybindChange(section: 'KeySwap', displayName: 'Swap', before: 'F7', after: 'F8', kind: KeybindChangeKind.rebound),
          ],
        ),
      );

  /// mod1's job, written, with what its write did and left for Undo; [result] in place of plain "written".
  DownloadJob written({UpdateModResult? result}) => updateJob(1, state: DownloadJobState.done).copyWith(
        outcome: JobOutcome.updated,
        finishedAt: aug,
        modResults: [result ?? UpdateModResult.written(baseOf('mod1', 1))],
        report: UpdateReport(
          applied: [applied('mod1')],
          outcome: const GroupWriteOutcome(settledMarks: {'mod1'}, changed: true),
          removedMarks: {'mod1': check(1)},
          undo: {'mod1': record('mod1')},
          leftOut: const ['Previews'],
        ),
      );

  final elsewhereResult = UpdateModResult.skipped(baseOf('mod1', 1), UpdateSkipReason.patchAddedElsewhere, patchedInto: 'mod2');

  /// mod1's job, whose file went into mod2's folder as a patch that changed a key there; [takenOut] when Undo takes it out.
  DownloadJob elsewhere({bool takenOut = false, UpdateModResult? result}) {
    final placement = applied('mod2', dropped: 0);
    final undo = record('mod2');
    return updateJob(1, state: DownloadJobState.done).copyWith(
      outcome: JobOutcome.skipped,
      skipReason: UpdateSkipReason.patchAddedElsewhere,
      finishedAt: aug,
      modResults: [result ?? elsewhereResult],
      report: UpdateReport(
        applied: [placement],
        outcome: const GroupWriteOutcome(settledMarks: {}, changed: true),
        placed: {'mod1': placement},
        undo: {
          'mod1': takenOut
              ? UpdateUndoRecord(
                  folderId: 'mod2', snapshot: undo.snapshot, writesStarted: 1, takeOut: const DownloadKey.patch(1))
              : undo,
        },
      ),
    );
  }

  /// A job of mod1 and mod3, both answered "add it to mod2": mod1's file went in, and mod3 was skipped, as mod2 was already changed by it.
  DownloadJob oneFolderTwice() {
    final mods = [baseOf('mod1', 1), baseOf('mod3', 1)];
    final placement = applied('mod2', dropped: 0);
    return updateJob(1, state: DownloadJobState.done, mods: mods).copyWith(
      outcome: JobOutcome.skipped,
      skipReason: UpdateSkipReason.patchAddedElsewhere,
      finishedAt: aug,
      modResults: [
        UpdateModResult.skipped(mods[0], UpdateSkipReason.patchAddedElsewhere, patchedInto: 'mod2'),
        UpdateModResult.skipped(mods[1], UpdateSkipReason.changedByThisUpdate, alongWith: 'mod2'),
      ],
      report: UpdateReport(
        applied: [placement],
        outcome: const GroupWriteOutcome(settledMarks: {}, changed: true),
        placed: {'mod1': placement},
        undo: {'mod1': record('mod2')},
      ),
    );
  }

  /// A job of Miyabi and Ellen, both answered with Ellen's folder: Miyabi's placement went first,
  /// so Ellen's own was skipped; with [partWay], Miyabi's stopped part-way.
  DownloadJob ownFolderTaken({bool partWay = false}) {
    final mods = [baseOf('Miyabi', 1), baseOf('Ellen', 2)];
    final placement = applied('Ellen', dropped: 0);
    const failure = UpdateFailure(UpdateFailureKind.writtenPartway);
    return updateJob(1, state: partWay ? DownloadJobState.failed : DownloadJobState.done, mods: mods, error: partWay ? failure : null)
        .copyWith(
      outcome: partWay ? null : JobOutcome.skipped,
      skipReason: partWay ? null : UpdateSkipReason.patchAddedElsewhere,
      finishedAt: aug,
      modResults: [
        partWay
            ? UpdateModResult(mods[0], UpdateModEnd.failed, failure: failure)
            : UpdateModResult.skipped(mods[0], UpdateSkipReason.patchAddedElsewhere, patchedInto: 'Ellen'),
        UpdateModResult.skipped(mods[1], UpdateSkipReason.changedByThisUpdate,
            alongWith: 'Ellen', changedBy: (modId: 'Miyabi', partWay: partWay)),
      ],
      report: partWay
          ? null
          : UpdateReport(
              applied: [placement],
              outcome: const GroupWriteOutcome(settledMarks: {}, changed: true),
              placed: {'Miyabi': placement},
              undo: {'Miyabi': record('Ellen')},
            ),
    );
  }

  /// A container with [jobs] in the queue and the rule answering [offered] for the mods it offers Undo for, and why not for the rest.
  ProviderContainer seeded(
    List<DownloadJob> jobs, {
    required List<String> library,
    Set<String> offered = const {},
    UpdateUndoProblem otherwise = UpdateUndoProblem.writtenSince,
  }) {
    final container = ProviderContainer(overrides: [
      downloadQueueProvider.overrideWith(() => SeededQueue(jobs)),
      libraryOf([for (final id in library) mod(id)]),
      updateUndoProvider.overrideWith((ref, key) => offered.contains(key.modId) ? null : otherwise),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  group("the Updates page's finished row", () {
    Future<void> pumpUpdates(WidgetTester t, ProviderContainer container, Map<String, UpdateCheck> checks) async {
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
    }

    Finder inRow(String mod, Finder finder) => find.descendant(
          of: find.ancestor(of: find.text(mod), matching: find.byKey(ValueKey(mod))),
          matching: finder,
        );

    testWidgets('Updated · Undo, the snapshot date, the files removed, the hotkeys changed and the folders left out', (t) async {
      await pumpUpdates(t, seeded([written()], library: ['mod1'], offered: {'mod1'}), const {});

      expect(inRow('mod1', find.text('Updated ·')), findsOneWidget);
      expect(inRow('mod1', find.text('Undo')), findsOneWidget);
      expect(inRow('mod1', find.text('the 2026-08-12 file is a snapshot')), findsOneWidget);
      expect(inRow('mod1', find.text('2 old files removed')), findsOneWidget);
      expect(inRow('mod1', find.text('1 hotkey changed')), findsOneWidget);
      expect(inRow('mod1', find.text('not installed from the file: Previews')), findsOneWidget);
      expect(inRow('mod1', find.text('Update')), findsNothing, reason: 'the write took the update');
    });

    testWidgets('"N hotkeys changed" opens the list of each key as it was and as it is', (t) async {
      await pumpUpdates(t, seeded([written()], library: ['mod1'], offered: {'mod1'}), const {});

      await t.tap(find.text('1 hotkey changed'));
      await t.pumpAndSettle();
      expect(find.text('mod1'), findsWidgets, reason: 'the list names the mod');
      expect(find.text('Swap'), findsOneWidget);
      expect(find.text('F7'), findsOneWidget);
      expect(find.text('F8'), findsOneWidget);
      await t.tap(find.widgetWithText(FilledButton, 'Close'));
      await t.pumpAndSettle();
      expect(find.text('Swap'), findsNothing);
    });

    testWidgets('Undo not offered: the plain Updated row, its detail still there', (t) async {
      await pumpUpdates(t, seeded([written()], library: ['mod1']), const {});

      expect(inRow('mod1', find.text('Updated')), findsOneWidget);
      expect(inRow('mod1', find.text('Undo')), findsNothing);
      expect(inRow('mod1', find.text('the 2026-08-12 file is a snapshot')), findsOneWidget);
    });

    for (final (problem, words) in _storedReasons) {
      testWidgets("Couldn't undo says why, ${problem.name}, offers no Undo and keeps what the write did", (t) async {
        final job = written(result: UpdateModResult.written(baseOf('mod1', 1)).withUndo(problem: problem));
        await pumpUpdates(t, seeded([job], library: ['mod1'], otherwise: problem), const {});
        expect(inRow('mod1', find.text("Couldn't undo")), findsOneWidget);
        expect(inRow('mod1', find.text(words)), findsOneWidget);
        expect(inRow('mod1', find.text('Undo')), findsNothing);
        expect(inRow('mod1', find.text('the 2026-08-12 file is a snapshot')), findsOneWidget);
        expect(inRow('mod1', find.text('2 old files removed')), findsOneWidget);
        expect(inRow('mod1', find.text('1 hotkey changed')), findsOneWidget);
      });
    }

    testWidgets("Couldn't undo is in the danger colour, as on the panel", (t) async {
      final job = written(result: UpdateModResult.written(baseOf('mod1', 1)).withUndo(problem: UpdateUndoProblem.snapshotGone));
      await pumpUpdates(t, seeded([job], library: ['mod1']), const {});
      final label = t.widget<Text>(inRow('mod1', find.text("Couldn't undo")));
      expect(label.style?.color, ZenithPalette.of(t.element(find.byType(UpdatesPage))).badgeMissing.foreground);
    });

    testWidgets('an undone row stays, back on the old file, with Update and Ignore as its mark came back', (t) async {
      final job = written(result: UpdateModResult.written(baseOf('mod1', 1)).withUndo(undone: true)).copyWith(outcome: JobOutcome.undone);
      await pumpUpdates(t, seeded([job], library: ['mod1'], otherwise: UpdateUndoProblem.nothingToUndo), {'mod1': check(1)});

      expect(inRow('mod1', find.text('Undone')), findsOneWidget);
      expect(inRow('mod1', find.text('back on the 2026-08-12 file')), findsOneWidget);
      expect(inRow('mod1', find.text('Undo')), findsNothing);
      expect(inRow('mod1', find.text('Update')), findsOneWidget);
      expect(inRow('mod1', find.text('Ignore')), findsOneWidget);
      expect(inRow('mod1', find.text('2 old files removed')), findsNothing, reason: 'what Undo took back is not said');
    });

    testWidgets('a patch put into another mod offers its Undo on the row of the mod it was for', (t) async {
      final job = updateJob(1, state: DownloadJobState.done).copyWith(
        outcome: JobOutcome.skipped,
        skipReason: UpdateSkipReason.patchAddedElsewhere,
        modResults: [UpdateModResult.skipped(baseOf('mod1', 1), UpdateSkipReason.patchAddedElsewhere, patchedInto: 'mod2')],
        report: UpdateReport(
          applied: [applied('mod2', dropped: 0)],
          outcome: const GroupWriteOutcome(settledMarks: {}, changed: true),
          undo: {'mod1': record('mod2')},
        ),
      );
      await pumpUpdates(t, seeded([job], library: ['mod1', 'mod2'], offered: {'mod1'}), {'mod1': check(1)});

      expect(inRow('mod1', find.text('Skipped · patch added to mod2 ·')), findsOneWidget);
      expect(inRow('mod1', find.text('Undo')), findsOneWidget);
      expect(inRow('mod1', find.text('Update')), findsOneWidget, reason: 'it keeps its update, as a skip does');
    });

    testWidgets('a second placement into a folder the job changed: skipped with the folder named, no detail, no Undo, its update kept',
        (t) async {
      await pumpUpdates(
        t,
        seeded([oneFolderTwice()], library: ['mod1', 'mod2', 'mod3'], offered: {'mod1'}, otherwise: UpdateUndoProblem.nothingToUndo),
        {'mod1': check(1), 'mod3': check(1)},
      );

      expect(inRow('mod3', find.textContaining('Skipped · mod2 was already changed by this update')), findsOneWidget);
      expect(inRow('mod3', find.text('Undo')), findsNothing);
      expect(inRow('mod3', find.text('1 hotkey changed')), findsNothing);
      expect(inRow('mod3', find.text('Update')), findsOneWidget);
      expect(inRow('mod3', find.text('Ignore')), findsOneWidget);
      expect(inRow('mod1', find.text('Skipped · patch added to mod2 ·')), findsOneWidget);
      expect(inRow('mod1', find.text('Undo')), findsOneWidget);
      expect(inRow('mod1', find.text('1 hotkey changed')), findsOneWidget);
    });

    testWidgets("a placement on top of a mod skipped because another mod's patch went into its folder first says whose", (t) async {
      await pumpUpdates(
        t,
        seeded([ownFolderTaken()], library: ['Miyabi', 'Ellen'], offered: {'Miyabi'}, otherwise: UpdateUndoProblem.nothingToUndo),
        {'Miyabi': check(1), 'Ellen': check(2)},
      );

      expect(inRow('Ellen', find.textContaining("Skipped · Miyabi's patch went into this folder first")), findsOneWidget);
      expect(inRow('Ellen', find.textContaining('was already changed by this update')), findsNothing);
      expect(inRow('Ellen', find.text('Undo')), findsNothing);
      expect(inRow('Ellen', find.text('Update')), findsOneWidget);
      expect(inRow('Miyabi', find.text('Skipped · patch added to Ellen ·')), findsOneWidget);
    });

    testWidgets("when that patch stopped part-way, the mod's row says it left its folder part-way", (t) async {
      await pumpUpdates(
        t,
        seeded([ownFolderTaken(partWay: true)], library: ['Miyabi', 'Ellen'], otherwise: UpdateUndoProblem.nothingToUndo),
        {'Miyabi': check(1), 'Ellen': check(2)},
      );

      expect(inRow('Ellen', find.textContaining("Skipped · Miyabi's patch left this folder part-way")), findsOneWidget);
      expect(inRow('Ellen', find.textContaining('was already changed by this update')), findsNothing);
    });

    testWidgets('a patch put into another mod shows the hotkeys it changed there, and the list names that mod', (t) async {
      await pumpUpdates(t, seeded([elsewhere()], library: ['mod1', 'mod2'], offered: {'mod1'}), {'mod1': check(1)});

      expect(inRow('mod1', find.text('1 hotkey changed')), findsOneWidget);
      expect(inRow('mod1', find.textContaining('is a snapshot')), findsNothing, reason: "mod1's own file was not replaced");
      await t.tap(inRow('mod1', find.text('1 hotkey changed')));
      await t.pumpAndSettle();
      expect(find.descendant(of: find.byType(Dialog), matching: find.text('mod2')), findsOneWidget);
    });

    testWidgets('a patch taken back out of another mod reads that it came out of it, not that the mod is back on its old file',
        (t) async {
      final undone = elsewhere(takenOut: true, result: elsewhereResult.withUndo(undone: true));
      await pumpUpdates(t, seeded([undone], library: ['mod1', 'mod2']), {'mod1': check(1)});

      expect(inRow('mod1', find.text('Undone')), findsOneWidget);
      expect(inRow('mod1', find.text('the patch came out of mod2')), findsOneWidget);
      expect(inRow('mod1', find.textContaining('back on')), findsNothing);
    });

    testWidgets('the file the mod held, undated: "the old file is a snapshot"', (t) async {
      final undated = written().copyWith(
        report: (written().report! as UpdateReport).copyWith(removedMarks: {
          'mod1': UpdateCheck(
            outcome: UpdateOutcome.updateAvailable,
            installedFile: GbFile(idRow: 1, file: 'old1.zip'),
            subject: const DownloadKey.base(1),
          ),
        }),
      );
      await pumpUpdates(t, seeded([undated], library: ['mod1'], offered: {'mod1'}), const {});
      expect(inRow('mod1', find.text('the old file is a snapshot')), findsOneWidget);
    });

    testWidgets('Patch added has no snapshot line: it replaced no file', (t) async {
      final patched = written(result: UpdateModResult.written(baseOf('mod1', 1), patchedInto: 'mod1'))
          .copyWith(outcome: JobOutcome.patchAdded);
      await pumpUpdates(t, seeded([patched], library: ['mod1'], offered: {'mod1'}), const {});
      expect(inRow('mod1', find.text('Patch added ·')), findsOneWidget);
      expect(inRow('mod1', find.textContaining('is a snapshot')), findsNothing);
      expect(inRow('mod1', find.text('2 old files removed')), findsOneWidget);
    });
  });

  group("the Downloads panel's Finished row", () {
    Future<void> pumpPanel(WidgetTester t, ProviderContainer container) async {
      await pumpLocalized(
        t,
        Align(
          alignment: Alignment.centerRight,
          child: SizedBox(width: DownloadsPanel.width, height: 1000, child: DownloadsPanel(clock: () => aug)),
        ),
        container: container,
        surfaceSize: const Size(1200, 1100),
        settle: false,
      );
      expectBuilt(DownloadsPanel);
    }

    testWidgets('Undo where Show was, beside "Updated · the 12 Aug file is a snapshot" and its detail', (t) async {
      await pumpPanel(t, seeded([written()], library: ['mod1'], offered: {'mod1'}));

      expect(find.textContaining('Updated · the 2026-08-12 file is a snapshot'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Undo'), findsOneWidget);
      expect(find.text('Show'), findsNothing);
      expect(find.text('2 old files removed'), findsOneWidget);
      expect(find.text('1 hotkey changed'), findsOneWidget);
      expect(find.text('not installed from the file: Previews'), findsOneWidget);
    });

    testWidgets('no Undo when the rule does not offer it', (t) async {
      await pumpPanel(t, seeded([written()], library: ['mod1']));
      expect(find.textContaining('Updated · the 2026-08-12 file is a snapshot'), findsOneWidget);
      expect(find.text('Undo'), findsNothing);
    });

    testWidgets('an undone row says it is back on the old file', (t) async {
      final undone = written(result: UpdateModResult.written(baseOf('mod1', 1)).withUndo(undone: true));
      await pumpPanel(t, seeded([undone.copyWith(outcome: JobOutcome.undone)], library: ['mod1']));
      expect(find.textContaining('Undone · back on the 2026-08-12 file'), findsOneWidget);
      expect(find.text('2 old files removed'), findsNothing);
    });

    for (final (problem, words) in _storedReasons) {
      testWidgets("a press that did nothing says Couldn't undo with why, ${problem.name}, and keeps what the write did", (t) async {
        final refused = written(result: UpdateModResult.written(baseOf('mod1', 1)).withUndo(problem: problem));
        await pumpPanel(t, seeded([refused], library: ['mod1']));
        expect(find.textContaining("Couldn't undo · $words"), findsOneWidget);
        expect(find.text('the 2026-08-12 file is a snapshot'), findsOneWidget);
        expect(find.text('2 old files removed'), findsOneWidget);
        expect(find.text('1 hotkey changed'), findsOneWidget);
      });
    }

    testWidgets("Couldn't undo is in the danger colour, as on the Updates page's row", (t) async {
      final refused = written(result: UpdateModResult.written(baseOf('mod1', 1)).withUndo(problem: UpdateUndoProblem.snapshotGone));
      await pumpPanel(t, seeded([refused], library: ['mod1']));
      final line = t.widget<Text>(find.textContaining("Couldn't undo"));
      final spans = (line.textSpan! as TextSpan).children!.cast<TextSpan>();
      final span = spans.singleWhere((s) => s.text?.startsWith("Couldn't undo") ?? false);
      expect(span.style?.color, ZenithPalette.of(t.element(find.byType(DownloadsPanel))).badgeMissing.foreground);
    });

    testWidgets('a patch put into another mod: its line, the hotkeys it changed there, and Undo', (t) async {
      await pumpPanel(t, seeded([elsewhere()], library: ['mod1', 'mod2'], offered: {'mod1'}));
      expect(find.textContaining('Skipped · patch added to mod2'), findsOneWidget);
      expect(find.text('1 hotkey changed'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Undo'), findsOneWidget);
    });

    testWidgets('a second placement into a folder the job changed has its own line, naming the folder, with no Undo', (t) async {
      await pumpPanel(t, seeded([oneFolderTwice()], library: ['mod1', 'mod2', 'mod3'], offered: {'mod1'}));
      expect(find.textContaining('mod1: Skipped · patch added to mod2'), findsOneWidget);
      expect(find.textContaining('mod3: Skipped · mod2 was already changed by this update'), findsOneWidget);
      expect(find.text('1 hotkey changed'), findsOneWidget, reason: "mod1's placement alone");
      expect(find.widgetWithText(TextButton, 'Undo'), findsOneWidget, reason: "mod1's own");
    });

    testWidgets("a placement on top of a mod skipped because another mod's patch went into its folder first: the mod's line says whose",
        (t) async {
      await pumpPanel(t, seeded([ownFolderTaken()], library: ['Miyabi', 'Ellen'], offered: {'Miyabi'}));
      expect(find.text('Miyabi: Skipped · patch added to Ellen'), findsOneWidget);
      expect(find.text("Ellen: Skipped · Miyabi's patch went into this folder first"), findsOneWidget);
    });

    testWidgets("when that patch stopped part-way, the failed row's line for the mod says it left the folder part-way", (t) async {
      await pumpPanel(t, seeded([ownFolderTaken(partWay: true)], library: ['Miyabi', 'Ellen']));
      expect(find.text('NEEDS YOUR ATTENTION · 1'), findsOneWidget);
      expect(find.text("Ellen: Skipped · Miyabi's patch left this folder part-way"), findsOneWidget);
    });

    testWidgets('a patch taken back out of another mod reads that it came out of it', (t) async {
      final undone = elsewhere(takenOut: true, result: elsewhereResult.withUndo(undone: true));
      await pumpPanel(t, seeded([undone], library: ['mod1', 'mod2']));
      expect(find.textContaining('Undone · the patch came out of mod2'), findsOneWidget);
    });

    testWidgets("the archive's folders no written folder took are said once for a job of several mods", (t) async {
      final mods = [baseOf('Ellen', 1), baseOf('Nicole', 1)];
      final job = updateJob(1, state: DownloadJobState.done, mods: mods).copyWith(
        outcome: JobOutcome.updated,
        finishedAt: aug,
        modResults: [UpdateModResult.written(mods[0]), UpdateModResult.written(mods[1])],
        report: UpdateReport(
          applied: [applied('Ellen'), applied('Nicole')],
          outcome: const GroupWriteOutcome(settledMarks: {'Ellen', 'Nicole'}, changed: true),
          removedMarks: {'Ellen': check(1), 'Nicole': check(1)},
          leftOut: const ['Previews'],
        ),
      );
      await pumpPanel(t, seeded([job], library: ['Ellen', 'Nicole']));
      expect(find.text('not installed from the file: Previews'), findsOneWidget);
      expect(find.text('2 old files removed'), findsNWidgets(2), reason: "each mod's own detail stays on its line");
    });

    testWidgets('a job of several mods has a line for each, with its own skip reason and its own Undo, and no Undo for all',
        (t) async {
      final mods = [baseOf('Ellen', 1), baseOf('Miyabi', 1), baseOf('Nicole', 1)];
      final job = updateJob(1, state: DownloadJobState.done, mods: mods).copyWith(
        outcome: JobOutcome.updated,
        finishedAt: aug,
        modResults: [
          UpdateModResult.written(mods[0]),
          UpdateModResult.skipped(mods[1], UpdateSkipReason.beingWritten),
          UpdateModResult.written(mods[2]).withUndo(undone: true),
        ],
        report: UpdateReport(
          applied: [applied('Ellen'), applied('Nicole')],
          outcome: const GroupWriteOutcome(settledMarks: {'Ellen', 'Nicole'}, changed: true),
          removedMarks: {'Ellen': check(1), 'Nicole': check(1)},
          undo: {'Ellen': record('Ellen'), 'Nicole': record('Nicole')},
        ),
      );
      await pumpPanel(t, seeded([job], library: ['Ellen', 'Miyabi', 'Nicole'], offered: {'Ellen'}));

      expect(find.text('Ellen: Updated · the 2026-08-12 file is a snapshot'), findsOneWidget);
      expect(find.text('Miyabi: Skipped · its folder was being changed'), findsOneWidget);
      expect(find.text('Nicole: Undone · back on the 2026-08-12 file'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Undo'), findsOneWidget, reason: "Ellen's own; Nicole's is taken back");
      expect(find.widgetWithText(OutlinedButton, 'Undo'), findsNothing, reason: 'no Undo for the whole job');
    });

    testWidgets("a failed job of several mods says what came of each, a skip inside it included", (t) async {
      final mods = [baseOf('Ellen', 1), baseOf('Miyabi', 1)];
      const failure = UpdateFailure(UpdateFailureKind.refused);
      final job = updateJob(1, state: DownloadJobState.failed, mods: mods, error: failure).copyWith(
        modResults: [
          UpdateModResult(mods[0], UpdateModEnd.refused, failure: failure),
          UpdateModResult.skipped(mods[1], UpdateSkipReason.ignoredMeanwhile),
        ],
      );
      await pumpPanel(t, seeded([job], library: ['Ellen', 'Miyabi']));

      expect(find.text('NEEDS YOUR ATTENTION · 1'), findsOneWidget);
      expect(find.text("Ellen: Couldn't update · This file can't be written into this mod. Nothing was changed."), findsOneWidget);
      expect(find.text('Miyabi: Skipped · ignored meanwhile'), findsOneWidget);
    });
  });
}
