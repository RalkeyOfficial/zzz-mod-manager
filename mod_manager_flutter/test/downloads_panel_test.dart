import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/core/palette.dart';
import 'package:mod_manager_flutter/core/type_scale.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_file.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_image.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_mod.dart';
import 'package:mod_manager_flutter/screens/components/download_queue_host.dart';
import 'package:mod_manager_flutter/screens/components/downloads_button.dart';
import 'package:mod_manager_flutter/screens/components/downloads_panel.dart';
import 'package:mod_manager_flutter/screens/components/marketplace/gb_thumbnail.dart';
import 'package:mod_manager_flutter/screens/components/sidebar_nav_item.dart';
import 'package:mod_manager_flutter/screens/components/zenith_controls.dart';
import 'package:mod_manager_flutter/screens/dialogs/install_archive_flow.dart';
import 'package:mod_manager_flutter/services/download/download_exceptions.dart';
import 'package:mod_manager_flutter/services/download/download_handle.dart';
import 'package:mod_manager_flutter/services/download/download_job.dart';
import 'package:mod_manager_flutter/services/download/download_progress.dart';
import 'package:mod_manager_flutter/services/download/download_queue.dart';
import 'package:mod_manager_flutter/services/download/download_request.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

import 'support/library_override.dart';
import 'support/localized_harness.dart';

/// The Downloads panel and the sidebar row that opens it (`docs/downloads.md` §13 and §14).
void main() {
  const mib = 1024 * 1024;
  final dark = ZenithPalette.dark(AccentChoice.violet);
  final now = DateTime(2026, 10, 22, 12);
  var nextSeq = 0;

  setUp(() => nextSeq = 0);

  DownloadJob job({
    DownloadJobState state = DownloadJobState.running,
    DownloadIntent intent = DownloadIntent.install,
    String? subject,
    DownloadProgress? progress,
    Object? error,
    GbMod? mod,
    String? characterId,
    InstallWait? wait,
    InstallStage? installStage,
    UpdateStep? updateStep,
    JobOutcome? outcome,
    List<String> installed = const [],
    String? filedUnder,
    String? headline,
    DateTime? finishedAt,
    bool resumed = false,
    int? size,
    DateTime? fileDate,
    DownloadResult? result,
    String? fileName,
    String? variant,
  }) {
    final seq = ++nextSeq;
    return DownloadJob(
      seq: seq,
      request: DownloadRequest(url: Uri.parse('https://gamebanana.com/dl/$seq'), expectedSize: size),
      intent: intent,
      subject: subject ?? 'Mod $seq',
      file: GbFile(idRow: seq, filesize: size, dateAdded: fileDate, file: fileName, description: variant),
      mod: mod,
      characterId: characterId,
      state: state,
      progress: progress,
      error: error,
      wait: wait,
      installStage: installStage,
      updateStep: updateStep,
      outcome: outcome,
      installed: installed,
      filedUnder: filedUnder,
      headline: headline,
      finishedAt: finishedAt,
      resumed: resumed,
      result: result,
    );
  }

  late _RecordingQuestions questions;

  ProviderContainer seeded(List<DownloadJob> jobs, {List<ModInfo> library = const []}) {
    questions = _RecordingQuestions();
    final container = ProviderContainer(
      overrides: [
        downloadQueueProvider.overrideWith(() => _RecordingQueue(jobs)),
        downloadQuestionsProvider.overrideWithValue(questions),
        libraryOf(library),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  List<String> calls(ProviderContainer container) =>
      (container.read(downloadQueueProvider.notifier) as _RecordingQueue).calls;

  Future<void> pumpPanel(
    WidgetTester t,
    ProviderContainer container, {
    ModEnabler? enabler,
    Future<bool> Function(String folder)? folderOpener,
    DateTime Function()? clock,
    Brightness brightness = Brightness.dark,
    bool settle = false,
  }) async {
    await pumpLocalized(
      t,
      Align(
        alignment: Alignment.centerRight,
        child: SizedBox(
          width: DownloadsPanel.width,
          height: 760,
          child: DownloadsPanel(
            enabler: enabler ?? (id, {switchOff = const [], whileWritten}) async => true,
            folderOpener: folderOpener,
            clock: clock ?? () => now,
          ),
        ),
      ),
      container: container,
      brightness: brightness,
      settle: settle,
    );
    expectBuilt(DownloadsPanel);
  }

  /// The row box a text sits in.
  BoxDecoration rowBox(WidgetTester t, String text) => t
      .widget<Container>(find
          .ancestor(
            of: find.text(text),
            matching: find.byWidgetPredicate((w) =>
                w is Container &&
                w.decoration is BoxDecoration &&
                (w.decoration! as BoxDecoration).borderRadius == BorderRadius.circular(12)),
          )
          .first)
      .decoration! as BoxDecoration;

  Color? colorOf(WidgetTester t, String text) => t.widget<Text>(find.text(text)).style?.color;

  group('groups', () {
    testWidgets('come in their order under their labels, an empty one left out', (t) async {
      final container = seeded([
        job(subject: 'Finished one', state: DownloadJobState.done, outcome: JobOutcome.nothingInstalled, headline: 'Already in your library'),
        job(subject: 'Queued one', state: DownloadJobState.queued),
        job(subject: 'Running one'),
        job(subject: 'Asking one', state: DownloadJobState.waiting, wait: const InstallWait(InstallQuestion.patch)),
      ]);
      await pumpPanel(t, container);

      final labels = ['NEEDS YOUR ATTENTION · 1', 'IN PROGRESS', 'WAITING', 'FINISHED'];
      final tops = [for (final l in labels) t.getTopLeft(find.text(l)).dy];
      expect(tops, orderedEquals([...tops]..sort()));
      expect(t.getTopLeft(find.text('Asking one')).dy, lessThan(tops[1]));
      expect(t.getTopLeft(find.text('Queued one')).dy, inInclusiveRange(tops[2], tops[3]));
      // The attention label is amber; the others are the caption grey.
      expect(colorOf(t, labels[0]), dark.attentionTile.foreground);
      expect(colorOf(t, labels[1]), dark.text3);

      final only = seeded([job(subject: 'Alone')]);
      await pumpPanel(t, only);
      expect(find.text('IN PROGRESS'), findsOneWidget);
      expect(find.text('WAITING'), findsNothing);
      expect(find.text('FINISHED'), findsNothing);
      expect(find.textContaining('NEEDS YOUR ATTENTION'), findsNothing);
    });

    testWidgets('a paused download and a resumed one stay in In progress, where they were', (t) async {
      final container = seeded([
        job(subject: 'First'),
        job(subject: 'Held', state: DownloadJobState.paused),
        job(subject: 'Resumed', state: DownloadJobState.queued, resumed: true),
        job(subject: 'Queued', state: DownloadJobState.queued),
      ]);
      await pumpPanel(t, container);

      final waiting = t.getTopLeft(find.text('WAITING')).dy;
      final ys = [for (final n in ['First', 'Held', 'Resumed']) t.getTopLeft(find.text(n)).dy];
      expect(ys, orderedEquals([...ys]..sort()));
      expect(ys.last, lessThan(waiting));
      expect(t.getTopLeft(find.text('Queued')).dy, greaterThan(waiting));
    });

    testWidgets('Finished is newest first', (t) async {
      final container = seeded([
        job(subject: 'Older', state: DownloadJobState.done, outcome: JobOutcome.saved, finishedAt: now.subtract(const Duration(hours: 1))),
        job(subject: 'Newer', state: DownloadJobState.done, outcome: JobOutcome.saved, finishedAt: now.subtract(const Duration(minutes: 1))),
      ]);
      await pumpPanel(t, container);
      expect(t.getTopLeft(find.text('Newer')).dy, lessThan(t.getTopLeft(find.text('Older')).dy));
    });

    testWidgets('an empty list says so, and the footer is always there', (t) async {
      await pumpPanel(t, seeded(const []));
      expect(find.text('Nothing is downloading.'), findsOneWidget);
      expect(find.text("Archives are deleted once they're installed."), findsOneWidget);
      expect(find.text('Clear finished'), findsNothing);
    });
  });

  group('in progress', () {
    testWidgets('a running download says its bytes, rate and agent, with Pause and Cancel', (t) async {
      final container = seeded([
        job(
          subject: 'Victorian Ballgown',
          characterId: 'ellen',
          progress: const DownloadProgress(
            state: DownloadState.downloading,
            received: 133 * mib,
            total: 214 * mib,
            bytesPerSecond: 4.1 * mib,
          ),
        ),
      ]);
      await pumpPanel(t, container);

      expect(find.text('133 MB of 214 MB · 4.1 MB/s · for Ellen Joe'), findsOneWidget);
      expect(find.text('62%'), findsOneWidget);
      expect(t.widget<Text>(find.text('62%')).style?.fontFamily, 'Geist Mono');
      // The bar is filled to the share, 6px tall, in the accent.
      final fill = t.widget<FractionallySizedBox>(find.byType(FractionallySizedBox));
      expect(fill.widthFactor, closeTo(133 / 214, 0.001));
      expect(t.getSize(find.ancestor(of: find.byType(FractionallySizedBox), matching: find.byType(SizedBox)).first).height, 6);

      await t.tap(find.byTooltip('Pause'));
      await t.tap(find.byTooltip('Cancel'));
      expect(calls(container), ['pause 1', 'cancel 1']);
    });

    testWidgets("leads with the mod page's image on the agent's element tile, else the misc tile", (t) async {
      const image = GbImage(baseUrl: 'https://images.gamebanana.com/img/ss/mods', file: 'cover.jpg');
      final container = seeded([
        job(subject: 'Pictured', characterId: 'ellen', mod: const GbMod(idRow: 7, images: [image])),
        job(subject: 'Plain', characterId: 'cat_misc'),
      ]);
      await pumpPanel(t, container);

      final thumb = t.widget<GbThumbnail>(find.byType(GbThumbnail));
      expect(thumb.image, image);
      expect((thumb.placeholder! as DottedGround).ground, dark.groundFor(ElementTone.ice));
      expect(t.getSize(find.byType(GbThumbnail)), const Size(56, 42));

      final plain = find.descendant(
        of: find.ancestor(of: find.text('Plain'), matching: find.byType(Row)).last,
        matching: find.byType(DottedGround),
      );
      expect(t.widget<DottedGround>(plain).ground, dark.groundFor(ElementTone.neutral));
    });

    testWidgets('names no one for a category, and says Connecting before the first byte', (t) async {
      final container = seeded([
        job(
          subject: 'Hats',
          characterId: 'cat_misc',
          progress: const DownloadProgress(state: DownloadState.downloading, received: 1 * mib, total: 2 * mib),
        ),
        job(subject: 'Starting'),
      ]);
      await pumpPanel(t, container);
      expect(find.text('1.0 MB of 2.0 MB'), findsOneWidget);
      expect(find.text('Connecting...'), findsOneWidget);
    });

    testWidgets('a paused one says so, its bar dimmed, with Resume and Cancel', (t) async {
      final container = seeded([
        job(
          state: DownloadJobState.paused,
          progress: const DownloadProgress(state: DownloadState.downloading, received: 133 * mib, total: 214 * mib),
        ),
      ]);
      await pumpPanel(t, container);

      expect(find.text('Paused · 133 MB of 214 MB'), findsOneWidget);
      final fill = t.widget<DecoratedBox>(
        find.descendant(of: find.byType(FractionallySizedBox), matching: find.byType(DecoratedBox)),
      );
      expect((fill.decoration as BoxDecoration).color, dark.accent.withValues(alpha: 0.4));
      expect(find.byTooltip('Pause'), findsNothing);

      await t.tap(find.byTooltip('Resume'));
      await t.tap(find.byTooltip('Cancel'));
      expect(calls(container), ['resume 1', 'cancel 1']);
    });

    testWidgets('a landed one installs after the current one, and can still be cancelled', (t) async {
      final container = seeded([job(state: DownloadJobState.downloaded, size: 214 * mib)]);
      await pumpPanel(t, container);
      expect(find.text('214 MB · installs after the current one'), findsOneWidget);
      await t.tap(find.byTooltip('Cancel'));
      expect(calls(container), ['cancel 1']);
    });

    testWidgets('an install says Unpacking, then Installing, with no control', (t) async {
      final container = seeded([
        job(subject: 'A', state: DownloadJobState.installing, installStage: InstallStage.unpacking),
        job(subject: 'B', state: DownloadJobState.installing, installStage: InstallStage.installing),
      ]);
      await pumpPanel(t, container);
      expect(find.text('Unpacking'), findsOneWidget);
      expect(find.text('Installing'), findsOneWidget);
      // Only the header's close button.
      expect(find.byType(IconButton), findsOneWidget);
      expect(find.byType(FractionallySizedBox), findsNothing);
    });

    testWidgets('an update says Updating and its step, with no control', (t) async {
      final date = DateTime(2026, 10, 1);
      final container = seeded([
        job(subject: 'Unpacking', state: DownloadJobState.updating, updateStep: UpdateStep.unpacking, fileDate: date),
        job(subject: 'Confirming', state: DownloadJobState.updating, updateStep: UpdateStep.confirming, fileDate: date),
        job(subject: 'Writing', state: DownloadJobState.updating, updateStep: UpdateStep.writing, fileDate: date),
      ]);
      await pumpPanel(t, container);
      expect(find.text('Updating'), findsNWidgets(3));
      expect(find.text('Unpacking the file from 2026-10-01 · old one kept as a snapshot'), findsOneWidget);
      expect(find.text('Waiting for you to confirm'), findsOneWidget);
      expect(find.text('Writing the file from 2026-10-01 · old one kept as a snapshot'), findsOneWidget);
      expect(find.byType(IconButton), findsOneWidget);
    });
  });

  group('waiting', () {
    testWidgets('a queued download says when it starts, dimmed, with Remove from queue', (t) async {
      final container = seeded([
        job(subject: 'Racing Suit', state: DownloadJobState.queued, size: 156 * mib),
        job(subject: 'Unsized', state: DownloadJobState.queued),
      ]);
      await pumpPanel(t, container);

      expect(find.text('156 MB · starts after the current download'), findsOneWidget);
      expect(find.text('Waiting for a free slot'), findsOneWidget);
      final opacity = t.widget<Opacity>(find.ancestor(of: find.text('Racing Suit'), matching: find.byType(Opacity)));
      expect(opacity.opacity, 0.75);

      await t.tap(find.byTooltip('Remove from queue').first);
      expect(calls(container), ['cancel 1']);
    });
  });

  group('needs your attention', () {
    testWidgets('a patch row is amber, with its link tile, Choose… and Don\'t install', (t) async {
      final container = seeded([
        job(subject: 'Stocking Fix', state: DownloadJobState.waiting, wait: const InstallWait(InstallQuestion.patch)),
      ]);
      await pumpPanel(t, container);

      const line = 'Looks like a patch for another mod. Choose what it should patch.';
      expect(colorOf(t, line), dark.attention.foreground);
      final box = rowBox(t, 'Stocking Fix');
      expect(box.color, dark.attention.background);
      expect((box.border! as Border).left.color, dark.attention.border);

      final icon = t.widget<Icon>(find.byIcon(Icons.link_rounded));
      expect(icon.color, dark.attentionTile.foreground);
      final tile = find.ancestor(of: find.byIcon(Icons.link_rounded), matching: find.byType(Container)).first;
      expect(t.getSize(tile), const Size(56, 42));
      expect((t.widget<Container>(tile).decoration! as BoxDecoration).color, dark.attentionTile.background);

      await t.tap(find.text('Choose…'));
      await t.tap(find.text("Don't install"));
      expect(questions.calls, ['answer 1']);
      expect(calls(container), ['decline 1']);
    });

    testWidgets('each question has its icon and its button', (t) async {
      final container = seeded([
        job(subject: 'Folders', state: DownloadJobState.waiting, wait: const InstallWait(InstallQuestion.severalFolders, folderCount: 3)),
        job(subject: 'Twice', state: DownloadJobState.waiting, wait: const InstallWait(InstallQuestion.alreadyInstalled, installedAs: ['Ellen Swimsuit'])),
        job(subject: 'Locked', state: DownloadJobState.waiting, wait: const InstallWait(InstallQuestion.password), mod: const GbMod(idRow: 7)),
      ]);
      await pumpPanel(t, container);

      expect(find.text('The archive has 3 folders. Pick which to install and how.'), findsOneWidget);
      expect(find.text('This archive is byte-identical to the one you installed as Ellen Swimsuit.'), findsOneWidget);
      expect(find.text('The archive asks for a password. Authors usually put it in the mod description.'), findsOneWidget);
      expect(find.byIcon(Icons.folder_outlined), findsOneWidget);
      expect(find.byIcon(Icons.copy_rounded), findsOneWidget);
      expect(find.byIcon(Icons.lock_outline_rounded), findsOneWidget);
      expect(find.text('NEEDS YOUR ATTENTION · 3'), findsOneWidget);
      // Don't install is the password dialog's; the row offers the mod page instead.
      expect(find.text("Don't install"), findsNWidgets(2));

      await t.tap(find.text('Pick folders…'));
      await t.tap(find.text('Install anyway'));
      await t.tap(find.text('Enter password'));
      // The third row's buttons sit under the footer at this height until scrolled to.
      await t.ensureVisible(find.text('Open mod page'));
      await t.pump();
      await t.tap(find.text('Open mod page'));
      expect(questions.calls, ['answer 1', 'answer 2', 'answer 3', 'openModPage 3']);
    });
  });

  group('finished', () {
    final ellen = ModInfo(id: 'Ellen Maid', name: 'Ellen Maid', characterId: 'ellen', isActive: false);

    testWidgets('an install of one mod reads its character from the library, offers Turn on, then Show', (t) async {
      final enabled = <String>[];
      final container = seeded(
        [
          job(
            subject: 'Bangboo Party Hats',
            state: DownloadJobState.done,
            outcome: JobOutcome.installed,
            installed: const ['Ellen Maid'],
            finishedAt: now.subtract(const Duration(minutes: 9)),
          ),
        ],
        library: [ellen],
      );
      await pumpPanel(t, container, enabler: (id, {switchOff = const [], whileWritten}) async {
        enabled.add(id);
        return true;
      });

      expect(find.text('Installed · Ellen Joe · 9 minutes ago'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Turn on'), findsOneWidget);

      await t.tap(find.text('Turn on'));
      await t.pumpAndSettle();
      expect(enabled, ['Ellen Maid']);
      expect(find.text('Turn on'), findsNothing);
      expect(find.widgetWithText(OutlinedButton, 'Show'), findsOneWidget);

      await t.tap(find.text('Show'));
      await t.pumpAndSettle();
      expect(container.read(selectedModIdProvider), 'Ellen Maid');
      expect(container.read(destinationProvider), AppDestination.characters);
    });

    testWidgets('Turn on pressed during a bulk action waits for it to end', (t) async {
      final enabled = <String>[];
      final container = seeded(
        [job(state: DownloadJobState.done, outcome: JobOutcome.installed, installed: const ['Ellen Maid'])],
        library: [ellen],
      );
      container.read(allModsBulkRunningProvider.notifier).state = true;
      await pumpPanel(t, container, enabler: (id, {switchOff = const [], whileWritten}) async {
        enabled.add(id);
        return true;
      });

      await t.tap(find.text('Turn on'));
      await t.pumpAndSettle();
      expect(enabled, isEmpty, reason: "the bulk action is setting One at a time, as it greys the Library's switches");

      container.read(allModsBulkRunningProvider.notifier).state = false;
      await t.pumpAndSettle();
      expect(enabled, ['Ellen Maid']);
    });

    testWidgets('an unassigned mod is filed under Unassigned, and the age moves on each minute', (t) async {
      var clock = now;
      final container = seeded([
        job(
          state: DownloadJobState.done,
          outcome: JobOutcome.installed,
          installed: const ['Hats'],
          filedUnder: 'unknown',
          finishedAt: now.subtract(const Duration(minutes: 9)),
        ),
      ]);
      await pumpPanel(t, container, clock: () => clock);
      expect(find.text('Installed · Unassigned · 9 minutes ago'), findsOneWidget);

      clock = clock.add(const Duration(minutes: 1));
      await t.pump(const Duration(minutes: 1));
      expect(find.text('Installed · Unassigned · 10 minutes ago'), findsOneWidget);
    });

    testWidgets('an update, several folders, a saved archive and nothing installed each say what they came to', (t) async {
      final opened = <String>[];
      final archive = File('/tmp/zzz-downloads/mod.zip');
      final container = seeded([
        job(
          subject: 'Winter Maid Uniform',
          state: DownloadJobState.done,
          outcome: JobOutcome.updated,
          installed: const ['Ellen Maid'],
          filedUnder: 'ellen',
          fileDate: DateTime(2026, 9, 28),
          finishedAt: now.subtract(const Duration(minutes: 2)),
        ),
        job(
          subject: 'Pack',
          state: DownloadJobState.done,
          outcome: JobOutcome.installed,
          installed: const ['A', 'B', 'C'],
          filedUnder: 'ellen',
          finishedAt: now.subtract(const Duration(minutes: 3)),
        ),
        job(
          subject: 'Kept',
          intent: DownloadIntent.keepArchive,
          state: DownloadJobState.done,
          outcome: JobOutcome.saved,
          result: DownloadResult(file: archive, totalBytes: 1),
          finishedAt: now.subtract(const Duration(minutes: 4)),
        ),
        job(
          subject: 'Nothing',
          state: DownloadJobState.done,
          outcome: JobOutcome.nothingInstalled,
          headline: 'Already in your library',
          finishedAt: now.subtract(const Duration(minutes: 5)),
        ),
      ], library: [ellen]);
      await pumpPanel(t, container, folderOpener: (folder) async {
        opened.add(folder);
        return true;
      });

      expect(find.text('Updated to the file from 2026-09-28 · Ellen Joe · 2 minutes ago'), findsOneWidget);
      expect(find.text('3 mods installed · Ellen Joe · 3 minutes ago'), findsOneWidget);
      expect(find.text("Saved to the app's downloads folder · 4 minutes ago"), findsOneWidget);
      expect(find.text('Already in your library'), findsOneWidget);
      // Show for the update and the saved archive; none for several folders or nothing installed.
      expect(find.text('Show'), findsNWidgets(2));

      await t.tap(find.text('Show').last);
      await t.pumpAndSettle();
      expect(opened, [archive.parent.path]);
    });

    testWidgets('a failure is red, with Try again where a retry can help, else Dismiss', (t) async {
      final container = seeded([
        job(subject: 'Stalled', state: DownloadJobState.failed, error: const DownloadStalledException('no data', stallTimeout: Duration(seconds: 60))),
        job(subject: 'Broken', state: DownloadJobState.failed, error: const InstallFailure("Couldn't extract the archive")),
      ]);
      await pumpPanel(t, container);

      expect(colorOf(t, 'Stopped responding — try again to resume'), dark.redText);
      expect(colorOf(t, "Couldn't extract the archive"), dark.redText);

      await t.tap(find.widgetWithText(OutlinedButton, 'Try again'));
      await t.tap(find.byTooltip('Remove from the list'));
      expect(calls(container)..sort(), ['remove 2', 'retry 1']);
    });

    testWidgets('Clear finished takes the finished rows and leaves the rest, and goes with them', (t) async {
      final container = seeded([
        job(subject: 'Done', state: DownloadJobState.done, outcome: JobOutcome.saved),
        job(subject: 'Going'),
      ]);
      await pumpPanel(t, container);

      await t.tap(find.text('Clear finished'));
      await t.pump();
      expect(find.text('Done'), findsNothing);
      expect(find.text('Going'), findsOneWidget);
      expect(find.text('Clear finished'), findsNothing);
    });

    testWidgets('a long mod name is trimmed, not overflowed', (t) async {
      final container = seeded([job(subject: 'A' * 400, state: DownloadJobState.queued)]);
      await pumpPanel(t, container);
      expect(t.takeException(), isNull);
    });
  });

  group('which file', () {
    testWidgets('every row names its file under the mod, its variant text quoted beside it in grey', (t) async {
      final type = ZenithType.of;
      final container = seeded([
        job(
          subject: 'Asking',
          state: DownloadJobState.waiting,
          wait: const InstallWait(InstallQuestion.patch),
          fileName: 'StockingFix_v2.zip',
          variant: 'for the maid outfit',
        ),
        job(subject: 'Victorian Ballgown', fileName: 'VictorianBallgown_v1.2.zip', variant: 'Full dress'),
        job(
          subject: 'Shark Hoodie Recolor',
          state: DownloadJobState.updating,
          intent: DownloadIntent.callerHandles,
          fileName: 'SharkHoodie_Blue_1Oct.zip',
          variant: 'blue',
        ),
        job(subject: 'Victorian Ballgown', state: DownloadJobState.queued, fileName: 'Ballgown_Black.7z', variant: 'black ver.'),
        job(subject: 'Plain', state: DownloadJobState.queued, fileName: 'RacingSuit_Belle.zip'),
        job(
          subject: 'Finished',
          state: DownloadJobState.done,
          outcome: JobOutcome.saved,
          finishedAt: now,
          fileName: 'WinterMaid_v1.4.zip',
          variant: 'standard',
        ),
        job(subject: 'Broken', state: DownloadJobState.failed, error: Exception('x'), finishedAt: now, fileName: 'Broken.zip'),
      ]);
      await pumpPanel(t, container);

      final rows = {
        'Asking': ('StockingFix_v2.zip', '“for the maid outfit”'),
        'Shark Hoodie Recolor': ('SharkHoodie_Blue_1Oct.zip', '“blue”'),
        'Finished': ('WinterMaid_v1.4.zip', '“standard”'),
        'Plain': ('RacingSuit_Belle.zip', null),
        'Broken': ('Broken.zip', null),
      };
      for (final MapEntry(key: subject, value: (fileName, variant)) in rows.entries) {
        final name = t.getRect(find.text(subject));
        final file = t.getRect(find.text(fileName));
        expect(file.top, greaterThanOrEqualTo(name.bottom), reason: '$fileName under $subject');
        expect(file.left, name.left, reason: '$fileName lines up with $subject');
        if (variant != null) {
          final quoted = t.getRect(find.text(variant));
          expect(quoted.left, greaterThan(file.right), reason: '$variant beside $fileName');
          expect(quoted.top, lessThan(file.bottom), reason: '$variant on the same line');
        }
      }

      // The two Victorian Ballgown rows read apart by their file.
      expect(find.text('Victorian Ballgown'), findsNWidgets(2));
      expect(find.text('“Full dress”'), findsOneWidget);
      expect(find.text('“black ver.”'), findsOneWidget);

      final fileStyle = t.widget<Text>(find.text('VictorianBallgown_v1.2.zip')).style!;
      final mono = type(t.element(find.text('VictorianBallgown_v1.2.zip'))).monoSmall;
      expect(fileStyle.fontFamily, mono.fontFamily);
      expect(fileStyle.fontSize, 11);
      expect(fileStyle.color, dark.text2);
      final variantStyle = t.widget<Text>(find.text('“Full dress”')).style!;
      expect(variantStyle.fontSize, 12);
      expect(variantStyle.color, dark.text3);
    });

    testWidgets('a long file name gives way to the variant text, and nothing overflows', (t) async {
      final container = seeded([
        job(subject: 'Long', fileName: '${'VeryLongFileName' * 20}.zip', variant: 'the variant'),
        job(subject: 'Longer', fileName: 'short.zip', variant: 'variant ' * 40),
      ]);
      await pumpPanel(t, container);
      expect(t.takeException(), isNull);
      expect(t.getRect(find.text('“the variant”')).width, greaterThan(40), reason: 'the variant keeps its text');
      expect(t.getRect(find.text('short.zip')).width, greaterThan(40), reason: 'a long variant leaves the name room');
    });
  });

  group('the route', () {
    Future<void> pumpRow(WidgetTester t, ProviderContainer container, {Widget? beside, Size size = const Size(1200, 800)}) async {
      await pumpLocalized(
        t,
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [const SizedBox(width: 196, child: DownloadsNavItem()), ?beside],
        ),
        container: container,
        surfaceSize: size,
      );
      expectBuilt(DownloadsNavItem);
    }

    testWidgets('the sidebar row opens it at the right edge, 440 wide, and the scrim closes it', (t) async {
      final container = seeded([job(subject: 'Kept', state: DownloadJobState.done, outcome: JobOutcome.saved)]);
      await pumpRow(t, container);

      await t.tap(find.byType(SidebarNavItem));
      await t.pumpAndSettle();
      expect(find.byType(DownloadsPanel), findsOneWidget);
      expect(t.getSize(find.byType(DownloadsPanel)).width, 440);
      expect(t.getTopRight(find.byType(DownloadsPanel)).dx, 1200);
      expect(t.widget<SidebarNavItem>(find.byType(SidebarNavItem)).selected, isTrue);
      final palette = ZenithPalette.of(t.element(find.byType(DownloadsPanel)));
      final scrim = t.widget<ModalBarrier>(find.byType(ModalBarrier).last);
      expect(scrim.color, palette.downloadsScrim, reason: "the artboard's scrim, not the dialogs' overlay");
      final shadow = t
          .widget<Container>(find.descendant(of: find.byType(DownloadsPanel), matching: find.byType(Container)).first)
          .decoration! as BoxDecoration;
      expect(shadow.boxShadow!.single.color, palette.downloadsShadow);

      await t.tapAt(const Offset(400, 400));
      await t.pumpAndSettle();
      expect(find.byType(DownloadsPanel), findsNothing);
      expect(t.widget<SidebarNavItem>(find.byType(SidebarNavItem)).selected, isFalse);
    });

    testWidgets('is never wider than the window', (t) async {
      await pumpRow(t, seeded(const []), size: const Size(400, 600));
      await t.tap(find.byType(SidebarNavItem));
      await t.pumpAndSettle();
      expect(t.getSize(find.byType(DownloadsPanel)).width, 400);
    });

    testWidgets('closes on its ×, on Escape and on the close request', (t) async {
      final container = seeded(const []);
      await pumpRow(t, container);

      Future<void> open() async {
        container.read(downloadsPanelRequestProvider.notifier).state++;
        await t.pumpAndSettle();
        expect(find.byType(DownloadsPanel), findsOneWidget);
      }

      await open();
      await t.tap(find.byTooltip('Close downloads'));
      await t.pumpAndSettle();
      expect(find.byType(DownloadsPanel), findsNothing);

      await open();
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(find.byType(DownloadsPanel), findsNothing);

      await open();
      container.read(downloadsPanelCloseRequestProvider.notifier).state++;
      await t.pumpAndSettle();
      expect(find.byType(DownloadsPanel), findsNothing);
    });

    testWidgets("a card's Open Downloads opens it above a dialog", (t) async {
      final container = seeded(const []);
      await pumpRow(
        t,
        container,
        beside: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(context: context, builder: (_) => const AlertDialog(content: Text('A dialog'))),
            child: const Text('Open a dialog'),
          ),
        ),
      );
      await t.tap(find.text('Open a dialog'));
      await t.pumpAndSettle();
      expect(find.text('A dialog'), findsOneWidget);

      container.read(downloadsPanelRequestProvider.notifier).state++;
      await t.pumpAndSettle();
      expect(find.byTooltip('Close downloads').hitTestable(), findsOneWidget);

      // Closed by the request while it is on top of the dialog, the dialog is still there.
      container.read(downloadsPanelCloseRequestProvider.notifier).state++;
      await t.pumpAndSettle();
      expect(find.byType(DownloadsPanel), findsNothing);
      expect(find.text('A dialog').hitTestable(), findsOneWidget);
    });

    testWidgets("a row's question opens its dialog above the panel", (t) async {
      final container = seeded([
        job(subject: 'Locked', state: DownloadJobState.waiting, wait: const InstallWait(InstallQuestion.password)),
      ]);
      // The real host, so the dialog opens from its context as it does in the app.
      final host = ProviderContainer(
        parent: container,
        overrides: [downloadQuestionsProvider.overrideWith((ref) => DownloadQuestions())],
      );
      addTearDown(host.dispose);
      await pumpLocalized(
        t,
        DownloadQueueHost(
          asker: (context, ref, job) async {
            await showDialog<void>(context: context, builder: (_) => const AlertDialog(content: Text('Asked')));
            return AnswerKept(job.wait!);
          },
          child: const SizedBox(width: 196, child: DownloadsNavItem()),
        ),
        container: host,
      );
      expectBuilt(DownloadsNavItem);

      host.read(downloadsPanelRequestProvider.notifier).state++;
      await t.pumpAndSettle();
      await t.tap(find.text('Enter password'));
      await t.pumpAndSettle();

      expect(find.text('Asked').hitTestable(), findsOneWidget);
      expect(find.byTooltip('Close downloads').hitTestable(), findsNothing);

      // Escape closes the dialog and leaves the panel.
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(find.text('Asked'), findsNothing);
      expect(find.byTooltip('Close downloads').hitTestable(), findsOneWidget);
    });
  });

  group('the sidebar badge', () {
    Future<void> pumpItem(WidgetTester t, ProviderContainer container, {Brightness brightness = Brightness.dark}) async {
      await pumpLocalized(
        t,
        const Center(child: SizedBox(width: 196, child: DownloadsNavItem())),
        container: container,
        brightness: brightness,
      );
      expectBuilt(DownloadsNavItem);
      // The row's arrow never changes.
      expect(find.byIcon(Icons.download_rounded), findsOneWidget);
    }

    BoxDecoration pill(WidgetTester t) => t
        .widget<Container>(find.descendant(of: find.byType(SidebarBadge), matching: find.byType(Container)))
        .decoration! as BoxDecoration;

    testWidgets('waiting downloads are an amber pill with a triangle, over the running count', (t) async {
      final container = seeded([
        job(state: DownloadJobState.waiting, wait: const InstallWait(InstallQuestion.patch)),
        job(state: DownloadJobState.waiting, wait: const InstallWait(InstallQuestion.patch)),
        job(state: DownloadJobState.queued),
      ]);
      await pumpItem(t, container);

      expect(pill(t).color, dark.badgeUpdate.background);
      final triangle = t.widget<Icon>(find.byIcon(Icons.warning_amber_rounded));
      expect(triangle.size, 12);
      expect(triangle.color, dark.badgeUpdate.foreground);
      expect(colorOf(t, '2'), dark.badgeUpdate.foreground);
      expect(find.byTooltip('2 downloads need your attention'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('2 downloads need your attention')), findsOneWidget);
      expect(find.text('1'), findsNothing);
    });

    testWidgets('the waiting count is counted in Ukrainian too', (t) async {
      final container = seeded([job(state: DownloadJobState.waiting, wait: const InstallWait(InstallQuestion.patch))]);
      await pumpLocalized(
        t,
        const Center(child: SizedBox(width: 196, child: DownloadsNavItem())),
        container: container,
        locale: const Locale('uk'),
      );
      expect(find.byTooltip('1 завантаження потребує вашої уваги'), findsOneWidget);
    });

    testWidgets('downloads in progress or waiting for a slot, paused included, are a plain count', (t) async {
      final container = seeded([
        job(state: DownloadJobState.running),
        job(state: DownloadJobState.paused),
        job(state: DownloadJobState.queued),
        job(state: DownloadJobState.failed, error: const DownloadNetworkException('offline')),
        job(state: DownloadJobState.done),
      ]);
      await pumpItem(t, container);

      expect(find.byType(SidebarBadge), findsNothing);
      expect(find.text('3'), findsOneWidget);
      expect(colorOf(t, '3'), dark.text3);
      expect(t.widget<Text>(find.text('3')).style?.fontFamily, 'Geist Mono');
    });

    testWidgets('failed rows with nothing else going are a red pill with a circled cross', (t) async {
      final container = seeded([
        job(state: DownloadJobState.failed, error: const DownloadNetworkException('offline')),
        job(state: DownloadJobState.done),
      ]);
      await pumpItem(t, container, brightness: Brightness.light);

      final light = ZenithPalette.light(AccentChoice.violet);
      expect(pill(t).color, light.badgeMissing.background);
      final cross = t.widget<Icon>(find.byIcon(Icons.highlight_off_rounded));
      expect(cross.size, 12);
      expect(cross.color, light.badgeMissing.foreground);
      expect(find.byTooltip('1 download failed'), findsOneWidget);
    });

    testWidgets('nothing in flight and nothing failed is no badge at all', (t) async {
      await pumpItem(t, seeded([job(state: DownloadJobState.done)]));
      expect(find.byType(SidebarBadge), findsNothing);
      expect(find.text('1'), findsNothing);
      expect(find.text('0'), findsNothing);
    });
  });
}

/// A queue that starts with rows already in it, and records the calls the rows make.
///
/// The real one only reaches these states by running downloads, and a widget test that had to fetch something to
/// render a failed row would be testing the transport.
class _RecordingQueue extends DownloadQueue {
  _RecordingQueue(this._seed);

  final List<DownloadJob> _seed;
  final List<String> calls = [];

  @override
  List<DownloadJob> build() {
    super.build();
    return _seed;
  }

  @override
  Future<void> pause(int seq) async => calls.add('pause $seq');

  @override
  void resume(int seq) => calls.add('resume $seq');

  @override
  Future<void> cancel(int seq) async => calls.add('cancel $seq');

  @override
  Future<void> decline(int seq) async => calls.add('decline $seq');

  @override
  void retry(int seq) => calls.add('retry $seq');

  @override
  void remove(int seq) => calls.add('remove $seq');
}

class _RecordingQuestions extends DownloadQuestions {
  final List<String> calls = [];

  @override
  Future<void> answer(int seq) async => calls.add('answer $seq');

  @override
  void openModPage(int seq) => calls.add('openModPage $seq');
}
