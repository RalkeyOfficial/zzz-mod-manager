import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../l10n/app_localizations.dart';
import '../../models/character_info.dart';
import '../../models/install_result.dart';
import '../../services/api_service.dart';
import '../../services/download/download_job.dart';
import '../../services/download/download_queue.dart';
import '../../services/download/queue_policy.dart';
import '../../services/download/update_job.dart';
import '../../services/log/confirmations.dart';
import '../../services/log/logger.dart';
import '../../services/patch_scan.dart';
import '../../services/platform_service.dart';
import '../../services/shader_fixes/shader_fixes_service.dart';
import '../../services/update_apply/update_run_stages.dart';
import '../../services/update_apply/update_write.dart' show UpdateReport;
import '../../utils/marketplace_providers.dart';
import '../../utils/notification_actions.dart';
import '../../utils/notifications.dart';
import '../../utils/state_providers.dart';
import '../dialogs/archive_password_dialog.dart';
import '../dialogs/import_selection_dialog.dart' show ImportFolderChoice, pickUpdateFolders;
import '../dialogs/install_archive_flow.dart';
import '../dialogs/patch_install_flow.dart' show patchWindowNames, preparePatchQuestion;
import '../dialogs/patch_install_prompt.dart' show PatchInstallSubject, PatchKind;
import '../dialogs/patch_modal.dart';
import '../dialogs/unrecorded_patch_dialog.dart';
import 'install_result_feedback.dart';
import 'network_link_notice.dart';
import 'resolve/resolve_fragments.dart' show formatResolveDate;
import 'shader_fixes_notices.dart';
import 'update_run_words.dart';

final Logger _log = Logger('install');
final Logger _updateLog = Logger('update');

/// What an update deck's Working card says.
typedef _UpdateCardSaid = ({String title, String body, String? characterId, double? progress});

/// Turns a mod on, as `ApiService.enableMod`: the dry run, then the mods in [switchOff], then the mod. False when a
/// link could not be made or removed. A test substitutes its own so no link is made.
typedef ModEnabler = Future<bool> Function(
  String modId, {
  Iterable<String> switchOff,
  bool Function(String other)? whileWritten,
});

/// The deck every download's card is dealt into, so downloads running at once take one slot of the stack.
const String kDownloadsDeck = 'downloads';

/// The deck an update run's Working cards are dealt into, a slot of its own beside the downloads' (`docs/update-runs.md` §5).
const String kUpdatesDeck = 'updates';

/// The key every finished update's Done card is counted on, "3 mods updated".
const String kUpdatesDoneRepeat = 'update-run-done';

/// The key every update whose file went on top of its mod as a patch is counted on, "Patch added to 3 mods".
const String kUpdatesPatchRepeat = 'update-run-patch';

/// Returns once no bulk action of the All mods table is running. An enable in the middle of one could break a
/// character's One at a time, which the bulk action is setting mod by mod; the Library's switches are greyed out
/// for the same reason.
Future<void> bulkActionEnded(ProviderContainer container) async {
  if (!container.read(allModsBulkRunningProvider)) return;
  final ended = Completer<void>();
  final subscription = container.listen<bool>(allModsBulkRunningProvider, (_, running) {
    if (!running && !ended.isCompleted) ended.complete();
  });
  try {
    await ended.future;
  } finally {
    subscription.close();
  }
}

/// Turns each of [modIds], new mods an install or an import just created, on: in turn, as the library's switch does,
/// so a character's One at a time applies to them as to any enable, and after a running bulk action of the All mods
/// table has ended. Answers the mods that could not be turned on, which stay installed and off; an enable refused for
/// its shader files or a network folder says why instead, as the Library does. Never throws: the install is done
/// whatever this comes to.
Future<List<String>> turnOnNewMods(
  BuildContext context,
  List<String> modIds, {
  ModEnabler enabler = ApiService.enableMod,
}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final loc = context.loc;
  final notify = context.notify;
  final library = container.read(libraryProvider.notifier);
  final leftOff = <String>[];
  // Every mod this has come to a conclusion about, so a throw part-way leaves the rest named as left off.
  final settled = <String>{};
  try {
    await bulkActionEnded(container);
    // The new folders are not in the library until it is read again.
    await library.rescan();
    for (final modId in modIds) {
      await container.read(libraryTogglesProvider.notifier).run(modId, () async {
        settled.add(modId);
        final mods = container.read(modsProvider);
        final mod = mods.where((m) => m.id == modId).firstOrNull;
        if (mod == null) {
          leftOff.add(modId);
          return;
        }
        if (mod.isActive) return;
        final switchOff = modsToSwitchOff(
          mods,
          mod,
          container.read(oneAtATimeProvider),
          beingWritten: container.read(modWritesInProgressProvider),
          agentsDefault: container.read(oneAtATimeDefaultProvider),
        );
        try {
          final done = await enabler(
            modId,
            switchOff: switchOff,
            whileWritten: (other) => turnOffDuringWrite(container, other),
          );
          if (!done) {
            leftOff.add(modId);
            return;
          }
        } on ShaderPlacementRefused catch (refusal) {
          reportShaderRefusal(loc, notify, refusal, characterId: mod.characterId, container: container);
          return;
        } on NetworkLinkRefused {
          reportNetworkLinkRefused(loc, notify, [mod.name], characterId: mod.characterId);
          return;
        } catch (error) {
          _log.warning('mod not turned on after install', error: error, fields: {'mod': modId});
          leftOff.add(modId);
          return;
        }
        // The next mod's One at a time has to see this one on.
        library.put([
          for (final m in container.read(modsProvider))
            if (m.id == modId)
              m.copyWith(isActive: true)
            else if (switchOff.contains(m.id))
              m.copyWith(isActive: false)
            else
              m,
        ]);
      });
    }
  } catch (error, stack) {
    _log.error('new mods not turned on after install', error: error, stack: stack, fields: {'mods': modIds});
    leftOff.addAll(modIds.where((m) => !settled.contains(m)));
  }
  return leftOff;
}

/// What the patch window shows for an update's question about [mod]'s patch-shaped file, [pick] of [job].
/// A test substitutes its own, so it can hold the ranking.
typedef UpdatePatchQuestioner = Future<PatchUpdateContext> Function(
  ProviderContainer container,
  DownloadJob job,
  ModInfo mod,
  UpdateMod pick,
  UpdatePatchFinding finding,
);

/// [UpdatePatchQuestioner]: the library ranked by the file's own names, and what its `.ini` asks for that it does not carry.
Future<PatchUpdateContext> updatePatchQuestion(
  ProviderContainer container,
  DownloadJob job,
  ModInfo mod,
  UpdateMod pick,
  UpdatePatchFinding finding,
) async {
  final library = container.read(modsProvider);
  final modsPath = await _updateModsPath();
  PatchInstallSubject? scanned;
  if (modsPath != null) {
    final scan = await scanPlannedMods([
      PlannedMod(
        name: mod.name,
        sources: {for (final source in finding.sources) source: finding.sources.length == 1 ? '' : p.basename(source)},
      ),
    ]);
    final question = await preparePatchQuestion(
      scan: scan,
      combined: false,
      modsPath: modsPath,
      patchModId: pick.layer.modId,
      patchFileId: job.file.idRow,
      library: library,
    );
    scanned = question.subjects.firstOrNull;
  }
  return PatchUpdateContext(
    mod: mod,
    library: library,
    source: PatchSource(fileName: job.file.file ?? job.result?.requestedName ?? job.subject, bytes: job.file.filesize),
    // Without the library folder there is nothing to rank by, so the stage's own finding is listed unranked.
    subject: scanned ??
        PatchInstallSubject(
          modName: mod.name,
          patchModId: pick.layer.modId,
          patchFileId: job.file.idRow,
          kind: PatchKind.references,
          missingFiles: patchWindowNames(finding.missing),
        ),
  );
}

/// The library folder the run writes into, or null when it cannot be read.
Future<String?> _updateModsPath() async {
  try {
    return await updateLibraryFolder();
  } catch (error) {
    _updateLog.warning('library folder not read for an update question', error: error);
    return null;
  }
}

/// The way from a panel row to the questions [DownloadQueueHost] asks.
///
/// The host asks from its own context, which is below the `Navigator` and outlives the panel; the panel is a route
/// of its own and cannot reach that context, so the host lends the two calls here while it is mounted. Without a
/// host both do nothing.
final downloadQuestionsProvider = Provider<DownloadQuestions>((ref) => DownloadQuestions());

class DownloadQuestions {
  Future<void> Function(int seq)? _answer;
  Future<void> Function(int seq)? _updateAnyway;
  void Function(int seq)? _openModPage;
  int Function()? _countInHand;

  /// How many update questions a press is answering, from the press until the answer or Skip is stored.
  @visibleForTesting
  int get questionsInHand => _countInHand?.call() ?? 0;

  /// The waiting job's own button: Enter password, Install anyway, Pick folders… or Choose…, and an update row's Answer.
  /// Opens the question's window, and the ones after it in the same sitting.
  Future<void> answer(int seq) => _answer?.call(seq) ?? Future<void>.value();

  /// Update anyway, on the panel row of an update whose folder holds a patch nothing records: answered on the row, with no window.
  Future<void> updateAnyway(int seq) => _updateAnyway?.call(seq) ?? Future<void>.value();

  /// Open mod page: the job's mod page in Browse, the job still waiting.
  void openModPage(int seq) => _openModPage?.call(seq);
}

/// Finishes what the download queue starts, and reports it while it runs.
///
/// The queue moves bytes and stops; everything after — unpacking, importing,
/// saying what is happening — needs localized strings and can raise a dialog,
/// and a `Notifier` has neither. This is the half that has both.
///
/// **Where it is mounted is the whole design.** It wraps the tab switcher rather
/// than living inside a tab, because the tabs are keyed `AnimatedSwitcher`
/// children with no keep-alive and are therefore *disposed* when the user moves
/// between them — so an install owned by a tab dies on the first tab switch,
/// silently, with the archive already downloaded.
///
/// It must also sit **below** the `Navigator`: `showDialog` needs one as an
/// ancestor, so unlike `NotificationHost` this cannot go in
/// `MaterialApp.builder`.
///
/// **One install at a time**, and an install never opens a window by itself.
/// Where it needs the user it stops, the job waits in the panel and frees the
/// slot, and the question is asked only when the user presses the row's button
/// ([DownloadQuestions]), from this host's context.
class DownloadQueueHost extends ConsumerStatefulWidget {
  const DownloadQueueHost({
    super.key,
    required this.child,
    this.installer = runArchiveInstall,
    this.asker = answerInstallQuestion,
    this.enabler = ApiService.enableMod,
    this.updatePreparer = prepareUpdateJob,
    this.updateWriter = writeUpdateJob,
    this.patchQuestioner = updatePatchQuestion,
  });

  final Widget child;

  /// Seam for tests. Production is [updatePatchQuestion], what the patch window of an update's question shows.
  final UpdatePatchQuestioner patchQuestioner;

  /// Seam for tests. Production is [prepareUpdateJob], an update job's unpack and preview.
  final UpdatePreparer updatePreparer;

  /// Seam for tests. Production is [writeUpdateJob], an update job's write.
  final UpdateWriter updateWriter;

  /// Seam for tests. Production is [runArchiveInstall].
  final ArchiveInstaller installer;

  /// Seam for tests. Production is [answerInstallQuestion].
  final InstallQuestionAsker asker;

  /// Seam for tests. Production is `ApiService.enableMod`, the path every enable from the library takes.
  final ModEnabler enabler;

  @override
  ConsumerState<DownloadQueueHost> createState() => _DownloadQueueHostState();
}

class _DownloadQueueHostState extends ConsumerState<DownloadQueueHost> {
  /// Whether a drain loop is already running. The guard, not a queue of its own:
  /// the loop re-reads the list every turn, so anything that arrives while it is
  /// working is picked up by the next iteration rather than needing to be
  /// remembered.
  bool _draining = false;

  /// Whether the update unpack lane's loop is running, the same guard as [_draining].
  bool _unpacking = false;

  /// Whether a question's dialog is open, so a second press does not stack another.
  bool _answering = false;

  /// The update questions a press is answering, by the job's `seq` and the question's number (`UpdateWait.asking`).
  final Set<(int, int)> _inHand = {};

  /// Each download's Working card, by the job's `seq`, from the moment it is
  /// raised until its result takes the card over or the job leaves the queue.
  /// A card the user hid stays here, so its result still arrives.
  final Map<int, NotificationHandle> _cards = {};

  /// The one Needs you card for every waiting download, and the downloads it was last told about, in the order they started waiting.
  NotificationHandle? _needsYou;
  List<int> _waiting = const <int>[];

  /// The update deck's Working cards, oldest first: the first is the deck's front, so it shows the job furthest along.
  final List<NotificationHandle> _updateCards = [];

  /// What each of [_updateCards] was last told, so a card is rewritten only when what it says changed.
  final List<_UpdateCardSaid> _updateCardsSaid = [];

  /// Each update job's state when the queue was last read, so its result is told once, as it ends.
  /// Null until the first read, which tells nothing about the jobs already ended.
  Map<int, DownloadJobState>? _updateStates;

  /// The Error card of a halted run, and the halt it is about.
  NotificationHandle? _haltCard;
  UpdateHalt? _halt;

  late final DownloadQuestions _questions;

  @override
  void initState() {
    super.initState();
    _questions = ref.read(downloadQuestionsProvider)
      .._answer = _answer
      .._updateAnyway = _updateAnyway
      .._openModPage = _openModPage
      .._countInHand = (() => _inHand.length);
    // Reconcile with whatever the queue already holds, rather than waiting for
    // the next change. Nothing is in flight on a cold start, but a hot reload
    // rebuilds this host under a live queue, and reacting only to changes would
    // leave a running download with no card and an already-downloaded job with
    // nothing to install it.
    //
    // **After the frame, not during it.** Both calls below write to providers,
    // and Riverpod refuses that while the widget tree is building.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final jobs = ref.read(downloadQueueProvider);
      _syncCards(jobs);
      unawaited(_drain());
      unawaited(_drainUnpacks());
    });
  }

  @override
  void dispose() {
    if (_questions._answer == _answer) {
      _questions
        .._answer = null
        .._updateAnyway = null
        .._openModPage = null
        .._countInHand = null;
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Every list change, not just an arrival: a transfer finishing, a retry, a
    // cancel and every progress tick all change what there is to do and what
    // there is to say.
    ref.listen<List<DownloadJob>>(downloadQueueProvider, (_, jobs) {
      _syncCards(jobs);
      unawaited(_drain());
      unawaited(_drainUnpacks());
    });
    return widget.child;
  }

  // ── Saying what is happening ───────────────────────────────────────────────

  /// Keeps one Working card per download in step with the queue, its bar the
  /// download's own share and a sweep while its size is unknown.
  ///
  /// **One card per download, dealt into one deck.** Every card joins the
  /// [kDownloadsDeck] deck, which the stack draws as one slot: the front card in
  /// full, "2 more downloading" under it, and the others' edges above it. So a
  /// five-mod queue never takes every visible slot and folds an error under
  /// "+N more", and one download looks the same as several.
  ///
  /// A card is raised when its download becomes active and updated from then
  /// on, so hiding it holds: a card re-raised on the next progress tick would
  /// ignore the user. A hidden card still takes its result, which comes back as
  /// a card. Each download's result takes its own card over the moment it
  /// lands, without waiting for the rest of the queue.
  ///
  /// A paused download has no card, since its spinner and bar would claim work that is not happening, and Resume
  /// raises it again as a download becoming active. A waiting download is on the Needs you card instead, and an
  /// update download's card goes once its bytes are handed over, since the update flow reports it.
  /// An update run's jobs have a deck of their own ([_syncUpdates]).
  void _syncCards(List<DownloadJob> jobs) {
    _reportFailedTransfers(jobs);
    _syncNeedsYou(jobs);
    _scheduleUpdateSync();

    final active = {
      for (final job in jobs)
        if (job.state.isActive &&
            !job.isUpdate &&
            job.state != DownloadJobState.paused &&
            job.state != DownloadJobState.waiting &&
            job.state != DownloadJobState.updating)
          job.seq: job,
    };
    // Gone without a result: cancelled, cleared, paused, or handed to the flow
    // that owns it, which reports it itself.
    for (final seq in [..._cards.keys]) {
      if (!active.containsKey(seq)) _cards.remove(seq)!.dismiss();
    }

    final loc = context.loc;
    final notify = context.notify;
    for (final job in active.values) {
      final title = _loneTitle(loc, job);
      final body = _loneBody(loc, job);
      final fraction = aggregateProgress([job]).fraction;
      final card = _cards[job.seq];
      if (card == null) {
        _cards[job.seq] = notify.working(
          title,
          body: body,
          characterId: job.characterId,
          progress: fraction,
          deck: NotificationDeck(
            kDownloadsDeck,
            more: (count) => loc.plural('downloads.deck_more', count,
                params: {'count': '$count'}),
          ),
        );
      } else {
        card.update(
          title: title,
          body: body,
          progress: fraction,
          clearProgress: fraction == null,
        );
      }
    }
  }

  /// Keeps the one Needs you card in step with the waiting downloads (`notifications.md` §4).
  ///
  /// A download starting to wait is news: its Working card turns into the Needs you card, which leaves the deck and
  /// moves to the newest place, and the card that said it before goes. A hidden Working card comes back this way,
  /// since hiding the progress never hides what comes of it, and so does a Needs you card the user closed. A download
  /// leaving the wait only changes the card's text, and the card goes once nothing waits.
  ///
  /// Its Answer opens the window of the question that has waited longest and leaves the card up, since a window closed without an answer leaves the question waiting.
  /// Open Downloads stays beside it.
  void _syncNeedsYou(List<DownloadJob> jobs) {
    final waiting = [for (final job in jobs) if (job.state == DownloadJobState.waiting) job];
    final seqs = {for (final job in waiting) job.seq};
    final joined = seqs.difference(_waiting.toSet());
    _waiting = [for (final seq in _waiting) if (seqs.contains(seq)) seq, for (final job in waiting) if (joined.contains(job.seq)) job.seq];

    if (waiting.isEmpty) {
      _needsYou?.dismiss();
      _needsYou = null;
      return;
    }

    final loc = context.loc;
    final one = waiting.length == 1 ? waiting.single : null;
    final title = one != null
        ? loc.t('downloads.needs_you')
        : loc.plural('downloads.needs_you_many', waiting.length, params: {'count': '${waiting.length}'});
    final body = one?.subject ?? subjectList(loc, [for (final job in waiting) job.subject]);
    final characterId = one?.characterId;
    // About the list rather than one mod, so both stay with several.
    final container = ProviderScope.containerOf(context, listen: false);
    final openDownloads = openDownloadsAction(loc, container);
    final actions = [
      NotificationAction(loc.t('notifications.actions.answer'), () {
        if (_waiting.isEmpty) return;
        final oldest = container.read(downloadQueueProvider).where((j) => j.seq == _waiting.first).firstOrNull;
        // The already-installed question has no window: its two answers are its row's buttons, which the panel shows.
        if (oldest?.wait?.question == InstallQuestion.alreadyInstalled) return openDownloads.onPressed();
        unawaited(_answer(_waiting.first));
      }, closes: false),
      openDownloads,
    ];

    if (joined.isEmpty) {
      _needsYou?.update(
        title: title,
        body: body,
        characterId: characterId,
        clearCharacterId: characterId == null,
      );
      return;
    }

    final newest = waiting.lastWhere((job) => joined.contains(job.seq));
    final previous = _needsYou;
    final card = _cards.remove(newest.seq);
    if (card != null) {
      card.update(
        kind: NotificationKind.needsYou,
        title: title,
        body: body,
        characterId: characterId,
        clearCharacterId: characterId == null,
        actions: actions,
      );
      _needsYou = card;
    } else {
      _needsYou = context.notify.needsYou(title, body: body, characterId: characterId, actions: actions);
    }
    if (previous != null && previous.id != _needsYou!.id) previous.dismiss();
  }

  /// A transfer that failed gets a card of its own, since the panel row is
  /// otherwise the only place it is said. The download's card becomes it, and
  /// leaves the deck as its own card.
  ///
  /// Install failures are reported where the install ran, a download the
  /// update flow owns is reported by that flow, and one that failed as it was
  /// queued, which never had a card, by the button that queued it.
  void _reportFailedTransfers(List<DownloadJob> jobs) {
    for (final job in jobs) {
      if (job.state != DownloadJobState.failed ||
          job.error is InstallFailure ||
          job.intent == DownloadIntent.callerHandles ||
          !_cards.containsKey(job.seq)) {
        continue;
      }
      final loc = context.loc;
      final container = ProviderScope.containerOf(context, listen: false);
      final actions = [
        if (rowActions(job, jobs).contains(DownloadRowAction.retry))
          retryAction(loc,
              () => container.read(downloadQueueProvider.notifier).retry(job.seq)),
        openDownloadsAction(loc, container),
      ];
      _takeCardFor(job)!.update(
        kind: NotificationKind.error,
        title: loc.t('downloads.failed_title'),
        body: job.subject,
        characterId: job.characterId,
        clearCharacterId: job.characterId == null,
        actions: actions,
      );
    }
  }

  /// [job]'s card, handed over to its result. The host lets go of it, so the
  /// job leaving the queue does not dismiss the result.
  NotificationHandle? _takeCardFor(DownloadJob job) => _cards.remove(job.seq);

  /// Whether [_syncUpdates] is due, once the change that called for it has finished.
  bool _updateSyncDue = false;

  /// Runs [_syncUpdates] after the queue's change in hand has finished: settling a job ends it and then attaches what
  /// came of its mods in two steps, and its result is told from both.
  void _scheduleUpdateSync() {
    if (_updateSyncDue) return;
    _updateSyncDue = true;
    scheduleMicrotask(() {
      _updateSyncDue = false;
      if (mounted) _syncUpdates(ref.read(downloadQueueProvider));
    });
  }

  /// Keeps an update run's cards in step with its jobs (`docs/update-runs.md` §5).
  ///
  /// **One deck of Working cards**, one card per job at work, the front card the job furthest along
  /// ([updatesInOrderOfWork]) and "2 more updating" under it. The cards are not each tied to a job: the oldest takes
  /// the furthest-along job's words, so the front stays the furthest along whatever order the jobs started in.
  ///
  /// A job that ends tells its result once: the mods it updated are counted on one Done card, "3 mods updated", whose Show opens the Downloads panel,
  /// the mods whose file went on top as a patch on another, "Patch added to 2 mods", and each mod that failed has an Error card of its own.
  /// A skip says nothing, since the user pressed it or the row says why.
  /// A halt is one Error card that stays until it is closed, in place of the failure that caused it. A question is on the Needs you card ([_syncNeedsYou]).
  void _syncUpdates(List<DownloadJob> jobs) {
    final loc = context.loc;
    final notify = context.notify;
    final container = ProviderScope.containerOf(context, listen: false);
    final halt = currentHalt(jobs);

    final before = _updateStates;
    _updateStates = {for (final job in jobs) if (job.isUpdate) job.seq: job.state};
    if (before != null) {
      for (final job in jobs) {
        if (!job.isUpdate || !job.isTerminal) continue;
        final was = before[job.seq];
        if (was != null && was.isTerminal) continue;
        _reportUpdateEnd(job, loc, notify, container, halt: halt ?? _halt);
      }
    }

    if (!identical(halt, _halt)) {
      _haltCard?.dismiss();
      _haltCard = halt == null ? null : _raiseHalt(halt, jobs, loc, notify, container);
      _halt = halt;
    }

    final working = updatesInOrderOfWork(jobs);
    while (_updateCards.length > working.length) {
      _updateCards.removeLast().dismiss();
      _updateCardsSaid.removeLast();
    }
    // Uncapped: a long run deals more cards than the stack's backstop keeps, and a dropped card cannot be updated.
    final deck = NotificationDeck(
      kUpdatesDeck,
      more: (count) => loc.plural('downloads.update.deck_more', count, params: {'count': '$count'}),
      uncapped: true,
    );
    for (final (i, job) in working.indexed) {
      final phase = updatePhaseOf(job) ?? const UpdateChecking();
      final said = (
        title: loc.t('downloads.update.card_title', params: {'mod': job.subject}),
        body: updateCardBody(loc, job, phase),
        characterId: job.characterId,
        progress: _updateCardProgress(job, phase),
      );
      if (i < _updateCards.length) {
        // A tick of a download that is not on this card changes nothing it says.
        if (_updateCardsSaid[i] == said) continue;
        _updateCardsSaid[i] = said;
        _updateCards[i].update(
          title: said.title,
          body: said.body,
          characterId: said.characterId,
          clearCharacterId: said.characterId == null,
          progress: said.progress,
          clearProgress: said.progress == null,
        );
      } else {
        _updateCardsSaid.add(said);
        _updateCards.add(notify.working(said.title,
            body: said.body, characterId: said.characterId, progress: said.progress, deck: deck));
      }
    }
  }

  /// What came of an ended update job, told once: its updated mods on the counted Done card,
  /// its patches put on top on their own counted Done card, and an Error card for each mod that failed. The failure of the mod that halted the run ([halt]) is told by the halt's card instead.
  void _reportUpdateEnd(
    DownloadJob job,
    AppLocalizations loc,
    NotificationCenter notify,
    ProviderContainer container, {
    required UpdateHalt? halt,
  }) {
    final library = {for (final mod in container.read(modsProvider)) mod.id: mod};
    String nameOf(String modId) => _updateModName(library[modId], job, modId);
    final report = job.report is UpdateReport ? job.report! as UpdateReport : null;

    // A patch put on top replaced no file, so it is told apart from an update: its own card, counted on its own.
    final written = [for (final r in job.modResults) if (r.end == UpdateModEnd.written && !r.patchAdded) r.mod.modId];
    final patched = [for (final r in job.modResults) if (r.patchAdded) r.mod.modId];
    // About the list the mods are all in, so the card keeps it when it counts several.
    final show = [openDownloadsAction(loc, container, label: loc.t('downloads.show'))];
    // One Done card for [mods], counted on [repeat] with the other jobs' cards of its kind.
    void done(List<String> mods, String repeat, {required String title, required String body, required String many}) {
      if (mods.isEmpty || job.outcome == JobOutcome.undone) return;
      notify.done(
        loc.t(title, params: {'mod': nameOf(mods.first)}),
        body: body,
        characterId: library[mods.first]?.characterId ?? job.characterId,
        actions: show,
        repeat: NotificationRepeat(
          repeat,
          subjects: [for (final id in mods) nameOf(id)],
          title: (count) => loc.plural(many, count, params: {'count': '$count'}),
          countedActions: show,
        ),
      );
    }

    done(
      patched,
      kUpdatesPatchRepeat,
      title: 'downloads.update.patch_done_title',
      body: loc.t('downloads.update.patch_done_body'),
      many: 'downloads.update.patch_done_many',
    );
    final heldDate = written.length == 1 ? report?.removedMarks[written.single]?.installedFile?.dateAdded : null;
    done(
      written,
      kUpdatesDoneRepeat,
      title: 'downloads.update.done_title',
      body: heldDate == null
          ? loc.t('downloads.update.done_body_undated')
          : loc.t('downloads.update.done_body', params: {'date': formatResolveDate(heldDate)}),
      many: 'downloads.update.done_many',
    );

    final failed = [
      for (final r in job.modResults)
        if (r.end == UpdateModEnd.failed || r.end == UpdateModEnd.refused) (r.mod.modId, r.failure ?? job.error),
    ];
    // A transfer fails the whole job before any mod has a result, so every mod of it failed.
    final failures = failed.isEmpty && job.state == DownloadJobState.failed
        ? [for (final mod in job.update!.mods) (mod.modId, job.error)]
        : failed;
    for (final (modId, failure) in failures) {
      // The halt's card stands in for the one mod whose failure caused it; the job's other mods have their own, the
      // same failure included when it covered the whole job.
      if (halt != null && halt.bySeq == job.seq && halt.modId == modId && identical(failure, halt.cause)) continue;
      notify.error(
        loc.t('downloads.update.failed_title', params: {'mod': nameOf(modId)}),
        body: updateFailureText(loc, failure, keptIn: job.archive?.parent.path),
        characterId: library[modId]?.characterId ?? job.characterId,
        actions: [openDownloadsAction(loc, container)],
      );
    }
  }

  /// "Updates stopped": which mod stopped the run and why. An Error card, which stays until it is closed.
  NotificationHandle _raiseHalt(
    UpdateHalt halt,
    List<DownloadJob> jobs,
    AppLocalizations loc,
    NotificationCenter notify,
    ProviderContainer container,
  ) {
    final by = jobs.where((job) => job.seq == halt.bySeq).firstOrNull;
    final modId = halt.modId;
    final mod = modId == null ? null : container.read(modsProvider).where((m) => m.id == modId).firstOrNull;
    final name = mod?.name ?? halt.modName ?? modId;
    final reason = updateFailureText(loc, halt.cause, keptIn: by?.archive?.parent.path);
    return notify.error(
      loc.t('downloads.update.halt_title'),
      body: name == null ? reason : loc.t('downloads.update.halt_body', params: {'mod': name, 'reason': reason}),
      characterId: mod?.characterId ?? by?.characterId,
      actions: [openDownloadsAction(loc, container)],
    );
  }

  /// [modId]'s name, a mod of [job]: the library's, else the name it had when the job was made, else its folder id.
  static String _updateModName(ModInfo? mod, DownloadJob job, String modId) =>
      mod?.name ??
      job.update?.modIn(modId)?.name ??
      (modId == job.update?.primary.modId ? job.subject : modId);

  /// A download's share, an empty bar for a job in line or held by the halt, and a sweep for the unpack and the write,
  /// which report no share.
  static double? _updateCardProgress(DownloadJob job, UpdatePhase phase) => switch (phase) {
        UpdateConnecting() || UpdateDownloading() => job.progress?.fraction ?? 0,
        UpdateInLine() || UpdateStopped() => 0,
        _ => null,
      };

  /// `Installing Victorian Ballgown`, or `Downloading …` for a download that
  /// installs nothing here: one kept as an archive, or one the update flow
  /// writes. The mod stays in the title while the line under it moves on.
  static String _loneTitle(AppLocalizations loc, DownloadJob job) =>
      loc.t(
        job.intent == DownloadIntent.install
            ? 'downloads.lone_title_installing'
            : 'downloads.lone_title_downloading',
        params: {'mod': job.subject},
      );

  /// Where the one download is: `Waiting for a free slot`,
  /// `Downloading · 64.0 MB of 214.0 MB`, then `Unpacking`. The bar shows
  /// the share.
  static String _loneBody(AppLocalizations loc, DownloadJob job) {
    switch (job.state) {
      case DownloadJobState.queued:
        return loc.t('downloads.queued');
      case DownloadJobState.running:
        if ((job.progress?.received ?? 0) == 0) return loc.t('downloads.connecting');
        return downloadingStageText(loc, job);
      default:
        return loc.t('downloads.stage_unpacking');
    }
  }

  // ── Asking ─────────────────────────────────────────────────────────────────

  Future<void> _answer(int seq) async {
    if (!mounted) return;
    final queue = ref.read(downloadQueueProvider.notifier);
    final job = ref.read(downloadQueueProvider).where((j) => j.seq == seq).firstOrNull;
    if (job == null || job.state != DownloadJobState.waiting) return;
    if (job.isUpdate) return _answerUpdate(job);
    if (_answering) return;

    _answering = true;
    try {
      final answer = await widget.asker(context, ref, job);
      switch (answer) {
        case AnswerGiven(:final prepared, :final password):
          queue.markAnswered(seq, prepared: prepared, password: password);
        case AnswerKept(:final wait, :final prepared):
          queue.keepWaiting(seq, wait, prepared: prepared);
        case AnswerDeclined():
          await queue.decline(seq);
        case AnswerOpenModPage():
          _openModPage(seq);
      }
    } catch (error, stack) {
      // The job keeps waiting, so the question can be asked again.
      _log.error('install question failed', error: error, stack: stack, fields: {'download': job.subject});
    } finally {
      _answering = false;
    }
  }

  /// Update anyway, from the panel row of an update whose folder holds a patch nothing records: the question answered without its window,
  /// and the questions after it asked in the same sitting. An open window does not hold it back, since it opens none.
  Future<void> _updateAnyway(int seq) async {
    if (!mounted) return;
    final job = ref.read(downloadQueueProvider).where((j) => j.seq == seq).firstOrNull;
    if (job == null || job.state != DownloadJobState.waiting || job.updateWait?.question != UpdateQuestionKind.unrecordedPatch) {
      return;
    }
    await _answerUpdate(job, updateAnyway: true);
  }

  /// How long an answered update may take to come back with its next question and still have it asked in the same sitting.
  /// The answered job goes ahead of the jobs that have not waited, so this is the unpack in flight, if any, and a preview.
  static const Duration _sameSitting = Duration(seconds: 20);

  /// An update's question, from this host's context, answered through `DownloadQueue.answerUpdate` (`docs/update-runs.md` §6):
  /// the archive's password, which of the archive's folders is the mod (the folders window), a download shaped like a patch (the patch window),
  /// and a patch nothing records in the folder (a small question). Each opens only its own window.
  ///
  /// Closing a window leaves the question waiting; only Skip ends it, for the mod the question is about ([skipUpdateQuestion]).
  /// An answer sends the job back in line, and a question it comes back with soon is asked in the same sitting, as an install's are:
  /// Pick folders is followed by the patch scan of that selection.
  /// A question about a mod no longer in the library, or whose update was ignored or written by something else while it waited, opens nothing and skips that mod.
  /// [updateAnyway] answers the first question, an unrecorded patch, without its window.
  ///
  /// One window is open at a time: [_answering] is held only while a window is open, whose answer is stored as it closes ([_inWindow]).
  /// The reads before a window and the wait for the answered job are not under it, so the other questions can be answered meanwhile.
  /// A question whose window comes to open while another is open, the job's next one included, waits for its own Answer.
  /// A question is [_inHand] from the press until its answer or Skip is stored, so another press for it does nothing meanwhile.
  Future<void> _answerUpdate(DownloadJob job, {bool updateAnyway = false}) async {
    var current = job;
    var direct = updateAnyway;
    while (mounted && current.updateWait != null) {
      final question = (current.seq, current.updateWait!.asking);
      if (!_inHand.add(question)) return;
      bool answered;
      try {
        answered = await _askUpdate(current, updateAnyway: direct);
      } catch (error, stack) {
        // The job keeps waiting, so the question can be asked again.
        _updateLog.error('update question failed', error: error, stack: stack, fields: {'download': current.subject});
        return;
      } finally {
        _inHand.remove(question);
      }
      direct = false;
      if (!answered || !mounted) return;
      final next = await _askedAgain(current.seq);
      if (next == null) return;
      current = next;
    }
  }

  /// Asks [job]'s question. True when it was answered and the job went back in line, false when it was closed, skipped or left for the mod page,
  /// or when its window did not open.
  /// An answer or a Skip is stored only for the question the window was opened for: one skipped or answered meanwhile refuses it, and nothing is said or logged.
  Future<bool> _askUpdate(DownloadJob job, {bool updateAnyway = false}) async {
    final wait = job.updateWait;
    if (wait == null) return false;
    final container = ProviderScope.containerOf(context, listen: false);
    final queue = container.read(downloadQueueProvider.notifier);
    final loc = context.loc;
    final kept = job.updateKept;
    final task = job.update!;
    final aboutId = wait.modId ?? task.primary.modId;
    final pick = task.modIn(aboutId) ?? task.primary;
    final library = ref.read(modsProvider);
    final mod = pickedModIn(library, pick);

    // Nothing is left to answer for, so the question ends as its write would have.
    final leftOut = await modsLeftOutOrAnswered(container, job);
    if (!mounted) return false;
    if (wait.question == UpdateQuestionKind.password) {
      if (task.mods.every((m) => leftOut.containsKey(m.modId))) {
        await queue.skipUpdate(
          job.seq,
          reason: leftOut[task.primary.modId]!.skipReason!,
          asking: wait.asking,
          results: leftOut.values.toList(),
        );
        return false;
      }
    } else if (mod == null) {
      await skipUpdateQuestion(container, job, reason: missingPickReason(library, pick));
      return false;
    } else if (leftOut[aboutId] case final result?) {
      await skipUpdateQuestion(container, job, reason: result.skipReason!);
      return false;
    }

    switch (wait.question) {
      case UpdateQuestionKind.password:
        final (:opened, :answer) = await _inWindow(
          job.seq,
          wait.asking,
          () => showArchivePasswordDialog(
            context,
            modName: job.subject,
            failed: wait.passwordFailed,
            declineLabel: loc.t('downloads.update.skip'),
            confirmLabel: loc.t('downloads.update.password_confirm'),
          ),
        );
        if (!opened) return false;
        switch (answer) {
          case PasswordGiven(:final password):
            return queue.answerUpdate(job.seq, asking: wait.asking, password: password);
          case PasswordDeclined():
            // Skip logs itself as the declined question.
            await queue.skipUpdate(job.seq, asking: wait.asking);
          case PasswordOpenModPage():
            _updateLog.info('update question left for the mod page',
                fields: {'download': job.subject, 'question': wait.question.name});
            _openModPage(job.seq);
          case null:
            logConfirmation('update.password', accepted: false, subject: job.subject, dismissed: true);
        }
        return false;

      case UpdateQuestionKind.folders:
        final question = kept?.foldersQuestion;
        if (kept == null || question == null || mod == null) return false;
        final modsPath = await _updateModsPath();
        if (!mounted) return false;
        final (:opened, answer: picked) = await _inWindow(
          job.seq,
          wait.asking,
          () => pickUpdateFolders(
            context,
            mod: mod,
            choices: [for (final choice in question.choices) ImportFolderChoice(path: choice.path, name: choice.name)],
            modsPath: modsPath,
            archiveName: job.file.file ?? job.result?.requestedName,
            heldFileDate: container.read(modUpdateChecksProvider)[mod.id]?.installedFile?.dateAdded,
          ),
        );
        if (!opened) return false;
        final chosen = picked?.folders;
        return _settle(
          container,
          job,
          'update.layout',
          subject: mod.id,
          closed: picked == null,
          store: chosen == null
              ? null
              : () => queue.answerUpdate(job.seq, asking: wait.asking, prepared: kept.withPickedFolders(chosen)),
          fields: {
            'problem': question.problem.name,
            if (chosen != null) 'folders': [for (final folder in chosen) p.basename(folder)],
          },
        );

      case UpdateQuestionKind.patchShaped:
        final finding = kept?.patchQuestion;
        if (kept == null || finding == null || mod == null) return false;
        // Asked before the library is ranked as well, so a question whose window could not open ranks nothing.
        if (!_mayOpen(job.seq, wait.asking)) return false;
        final question = await widget.patchQuestioner(container, job, mod, pick, finding);
        if (!mounted) return false;
        final (:opened, :answer) = await _inWindow(job.seq, wait.asking, () => showUpdatePatchModal(context, question));
        if (!opened) return false;
        final into = answer?.modId;
        return _settle(
          container,
          job,
          'update.patch',
          subject: mod.id,
          closed: answer == null,
          store: into == null
              ? null
              : () => queue.answerUpdate(job.seq, asking: wait.asking, prepared: kept.withAnswer(aboutId, PlaceAsPatch(into))),
          fields: {if (into != null) 'into': into, if (into != null) 'on_top': into == mod.id},
        );

      case UpdateQuestionKind.unrecordedPatch:
        if (kept == null || mod == null) return false;
        final UnrecordedPatchAnswer? answer;
        if (updateAnyway) {
          answer = UnrecordedPatchAnswer.updateAnyway;
        } else {
          final shown = await _inWindow(job.seq, wait.asking, () => showUnrecordedPatchDialog(context, mod: mod));
          if (!shown.opened) return false;
          answer = shown.answer;
        }
        return _settle(
          container,
          job,
          'update.unrecorded_patch',
          subject: mod.id,
          closed: answer == null,
          store: answer == UnrecordedPatchAnswer.updateAnyway
              ? () => queue.answerUpdate(job.seq, asking: wait.asking, prepared: kept.withAnswer(aboutId, const UpdateAnyway()))
              : null,
        );
    }
  }

  /// Stores what [job]'s question came to and logs it as the confirmation [action] about [subject].
  /// [closed] is the window closed without an answer; otherwise [store] stores the answer, false when the queue refused it, and without one it is the window's Skip.
  /// An answer or a Skip the queue refused, since its question was skipped or answered meanwhile, logs nothing. True when an answer was stored.
  Future<bool> _settle(
    ProviderContainer container,
    DownloadJob job,
    String action, {
    required String subject,
    required bool closed,
    bool Function()? store,
    Map<String, Object?> fields = const <String, Object?>{},
  }) async {
    if (closed) {
      logConfirmation(action, accepted: false, subject: subject, dismissed: true, fields: fields);
      return false;
    }
    final stored = store?.call() ?? false;
    final taken = store == null ? await skipUpdateQuestion(container, job) : stored;
    if (taken) logConfirmation(action, accepted: stored, subject: subject, fields: fields);
    return stored;
  }

  /// Whether a window may open for the question numbered [asking] of the job [seq]:
  /// no other window is open, and the job still waits on that question.
  bool _mayOpen(int seq, int asking) {
    if (!mounted || _answering) return false;
    final job = ref.read(downloadQueueProvider).where((j) => j.seq == seq).firstOrNull;
    return job != null && job.waitsOnUpdate(asking);
  }

  /// Opens a window for the question numbered [asking] of the job [seq], and gives what it came to,
  /// unless it may not open ([_mayOpen]), which is asked again here since the question may have been skipped or answered while the window was read: then [opened] is false.
  /// [_answering] is held while the window is open.
  Future<({bool opened, T? answer})> _inWindow<T>(int seq, int asking, Future<T?> Function() open) async {
    if (!_mayOpen(seq, asking)) return (opened: false, answer: null);
    _answering = true;
    try {
      return (opened: true, answer: await open());
    } finally {
      _answering = false;
    }
  }

  /// Once an answered update leaves the unpack lane: the job when it came back waiting on another question, and null when it went on,
  /// ended, or took longer than [_sameSitting].
  Future<DownloadJob?> _askedAgain(int seq) async {
    final done = Completer<DownloadJob?>();
    void check(List<DownloadJob> jobs) {
      if (done.isCompleted) return;
      final job = jobs.where((j) => j.seq == seq).firstOrNull;
      final inLine = job != null &&
          (job.state == DownloadJobState.downloaded ||
              (job.state == DownloadJobState.updating && job.updateStep == UpdateStep.unpacking));
      if (inLine) return;
      done.complete(job?.state == DownloadJobState.waiting ? job : null);
    }

    final subscription = ref.listenManual<List<DownloadJob>>(downloadQueueProvider, (_, jobs) => check(jobs));
    check(ref.read(downloadQueueProvider));
    try {
      return await done.future.timeout(_sameSitting, onTimeout: () => null);
    } finally {
      subscription.close();
    }
  }

  /// Open mod page: the job's mod page in Browse, the job still waiting. An update's is the page of the layer it is for.
  void _openModPage(int seq) {
    if (!mounted) return;
    final job = ref.read(downloadQueueProvider).where((j) => j.seq == seq).firstOrNull;
    final modId = job?.mod?.idRow ?? job?.update?.primary.layer.modId;
    if (modId == null) return;
    ref.read(downloadsPanelCloseRequestProvider.notifier).state++;
    ref.read(marketplaceOpenModProvider.notifier).state = modId;
    ref.read(destinationProvider.notifier).state = AppDestination.browse;
  }

  // ── Finishing the work ─────────────────────────────────────────────────────

  /// The install chain: one Browse install or one update write at a time.
  Future<void> _drain() => _lane(
        running: () => _draining,
        mark: (on) => _draining = on,
        // Claim-and-mark in one call: as two steps a rebuild between them could hand the same job to a second pass.
        claim: (queue) => queue.claimNextForHost(),
        run: (job) => job.isUpdate ? _writeUpdate(job) : _handle(job),
      );

  /// The update unpack lane, beside the install chain: it unpacks and previews the next update while one is written.
  Future<void> _drainUnpacks() => _lane(
        running: () => _unpacking,
        mark: (on) => _unpacking = on,
        claim: (queue) => queue.claimNextUpdateUnpack(),
        run: (job) => _runStage(
          job,
          (container) => widget.updatePreparer(container, job),
          failure: UpdateFailureKind.other,
        ),
      );

  /// One lane's loop: a job at a time, while the host is mounted and the queue has one to claim.
  /// One loop per lane at a time, guarded by [running];
  /// it re-reads the list every turn, so anything that arrives while it works is picked up by the next turn rather than needing to be remembered.
  Future<void> _lane({
    required bool Function() running,
    required void Function(bool on) mark,
    required DownloadJob? Function(DownloadQueue queue) claim,
    required Future<void> Function(DownloadJob job) run,
  }) async {
    if (running()) return;
    mark(true);
    try {
      while (mounted) {
        final job = claim(ref.read(downloadQueueProvider.notifier));
        if (job == null) return;
        await run(job);
      }
    } finally {
      mark(false);
    }
  }

  /// Runs one stage of an update job and settles the job from it, through the app's container as an install does,
  /// since a job left in its stage would hold the lane for good. A stage that throws is a failure of [failure].
  Future<void> _runStage(
    DownloadJob job,
    Future<UpdateStageResult> Function(ProviderContainer container) stage, {
    required UpdateFailureKind failure,
  }) async {
    final container = ProviderScope.containerOf(context, listen: false);
    UpdateStageResult result;
    try {
      result = await stage(container);
    } catch (error, stack) {
      _updateLog.error('update stage failed', error: error, stack: stack, fields: {'download': job.subject});
      result = UpdateStageFailed(UpdateFailure(failure, cause: error));
    }
    container.read(downloadQueueProvider.notifier).settleUpdate(job.seq, result);
  }

  /// Writes an update job ([DownloadQueueHost.updateWriter]).
  /// A folder of the job that is being written by something else (a restore, Edit info, a patch) is not written and not waited for,
  /// so an update never lands over a restore pressed while it queued;
  /// a job whose every folder is being written is skipped whole.
  /// A write that throws is [UpdateFailureKind.writeInterrupted], since how far it got is not known.
  Future<void> _writeUpdate(DownloadJob job) {
    final container = ProviderScope.containerOf(context, listen: false);
    final task = job.update!;
    final busy = container.read(modWritesInProgressProvider).intersection(task.folders);
    if (busy.length == task.folders.length) {
      _updateLog.info('update skipped, its folder is being written', fields: {'mods': busy.toList()});
      container.read(downloadQueueProvider.notifier).settleUpdate(
            job.seq,
            UpdateStageSkipped(
              UpdateSkipReason.beingWritten,
              results: [for (final mod in task.mods) UpdateModResult.skipped(mod, UpdateSkipReason.beingWritten)],
            ),
          );
      return Future<void>.value();
    }
    return _runStage(
      job,
      (container) => widget.updateWriter(container, job, skip: busy),
      failure: UpdateFailureKind.writeInterrupted,
    );
  }

  Future<void> _handle(DownloadJob job) async {
    // Taken while mounted, as [_drain] only calls this then: the install's end settles the job through them even if
    // the host is gone by the time it comes.
    final container = ProviderScope.containerOf(context, listen: false);
    final loc = context.loc;
    final queue = ref.read(downloadQueueProvider.notifier);
    final archive = job.archive;
    if (archive == null) {
      // Only reachable through a bug: nothing reaches `downloaded` without a
      // result. Failing loudly in the panel beats leaving a row that never
      // moves again.
      queue.markFailed(job.seq, StateError('downloaded job with no archive'));
      return;
    }

    if (job.intent == DownloadIntent.keepArchive) {
      // A file the user cannot see arriving in a folder they would have to go
      // and look at — the case the notification rules keep a *success* message
      // for. The body is the path because the path is the whole point.
      final title = loc.t('marketplace.download_saved_title');
      final actions = [openFolderAction(loc, context.notify, archive.parent.path)];
      final card = _takeCardFor(job);
      if (card != null) {
        card.update(
          kind: NotificationKind.done,
          title: title,
          body: archive.path,
          characterId: job.characterId,
          clearCharacterId: job.characterId == null,
          actions: actions,
        );
      } else {
        context.notify.done(title,
            body: archive.path, characterId: job.characterId, actions: actions);
      }
      queue.markDone(job.seq, outcome: JobOutcome.saved);
      return;
    }

    if (job.mod == null) {
      queue.markFailed(job.seq, StateError('install job with no mod page'));
      return;
    }

    InstallStep step;
    try {
      step = await widget.installer(context, ref, job);
    } catch (error) {
      // Taken before the queue changes, or the job leaving it dismisses it.
      final card = _takeCardFor(job);
      queue.markFailed(job.seq, InstallFailure('$error'));
      if (!mounted) {
        // Nothing is left to turn the Working card into its result, so it goes rather than spinning on.
        card?.dismiss();
        return;
      }
      // The mod is new; nothing was updated — so not the update flow's wording.
      final title = loc.t('marketplace.install_failed_title');
      // The panel's row holds what the install said went wrong.
      final actions = [
        openDownloadsAction(loc, ProviderScope.containerOf(context, listen: false)),
      ];
      if (card != null) {
        card.update(
          kind: NotificationKind.error,
          title: title,
          body: job.subject,
          characterId: job.characterId,
          clearCharacterId: job.characterId == null,
          actions: actions,
        );
      } else {
        context.notify.error(title,
            body: job.subject, characterId: job.characterId, actions: actions);
      }
      return;
    }

    switch (step) {
      case InstallWaits(:final wait, :final prepared):
        // The slot frees with this; the Needs you card takes the download's card.
        queue.markWaiting(job.seq, wait, prepared: prepared, unpacked: prepared.folders);
        return;
      case InstallEnds(:final result):
        await _report(job, result, container: container, loc: loc);
    }
  }

  /// Settles [job] from what its install came to, through [container] and [loc] rather than this host's `ref` and
  /// `context`: the queue outlives the host, and a job left `installing` would hold the install slot and the
  /// Storage reclaim's gate for good. Only what needs the host is skipped once it is gone, Turn on after installing
  /// and the result's card, which leaves new mods installed and off; the job's Working card is dismissed instead.
  Future<void> _report(
    DownloadJob job,
    InstallResult installed, {
    required ProviderContainer container,
    required AppLocalizations loc,
  }) async {
    final queue = container.read(downloadQueueProvider.notifier);
    var result = installed;
    if (mounted && job.turnOn && result.mods.isNotEmpty) {
      result = await _turnOn(result);
    }
    if (mounted) {
      showInstallResult(
        context,
        result,
        into: _takeCardFor(job),
        characterId: job.characterId,
      );
    } else {
      // Nothing is left to turn the Working card into the result, so it goes rather than spinning on.
      _takeCardFor(job)?.dismiss();
    }

    // The library just changed, and both the Library's grid and the
    // marketplace's "in library" badges are drawn from it. Invalidate rather
    // than patch: the mod folder's final name is decided by the import (dedup,
    // the combined-name dialog), so re-reading is the only way to be right
    // about it.
    container.invalidate(libraryProvider);

    if (result.mods.isNotEmpty) {
      queue.markDone(
        job.seq,
        outcome: JobOutcome.installed,
        installed: result.mods,
        filedUnder: result.characterId ?? job.characterId,
      );
    } else if (result.failureKind == NotificationKind.error) {
      queue.markFailed(
        job.seq,
        InstallFailure(
          result.failure?.title ?? loc.t('downloads.failed_install'),
        ),
      );
    } else if (result.failure != null) {
      // An install that put nothing in: every folder already existed (a note),
      // or the archive held no mod folder (a warning). Nothing to retry and
      // nothing failed.
      queue.markDone(job.seq, outcome: JobOutcome.nothingInstalled, headline: result.failure!.title);
    } else {
      queue.markGone(job.seq);
    }
  }

  /// Turns each new mod of [result] on, for an install whose page had Turn on after installing set: in turn, as the
  /// library's switch does, so a character's One at a time applies to them as to any enable, and after a running
  /// bulk action of the All mods table has ended. A mod that can't be turned on stays installed and off, and the
  /// result carries a warning naming it; an enable refused for its shader files or a network folder says why instead,
  /// as the Library does. Never throws: the install is done whatever this comes to.
  Future<InstallResult> _turnOn(InstallResult result) async {
    final loc = context.loc;
    final leftOff = await turnOnNewMods(context, result.mods, enabler: widget.enabler);
    if (leftOff.isEmpty) return result;
    return InstallResult.success(
      result.mods,
      warnings: [
        ...result.warnings,
        NotificationLines(loc.t('marketplace.turn_on_failed_title'), leftOff.join(', ')),
      ],
      characterId: result.characterId,
    );
  }
}
