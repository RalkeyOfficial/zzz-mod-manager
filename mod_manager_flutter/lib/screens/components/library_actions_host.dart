import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/character_info.dart';
import '../../services/bulk_resolution.dart';
import '../../services/bulk_update_check.dart';
import '../../services/origin_write.dart';
import '../../services/update_check_run.dart';
import '../../utils/state_providers.dart';
import '../dialogs/bulk_resolution_dialog.dart';
import 'update_check_feedback.dart';

/// The update checks a press starts and that outlive the page it was pressed on: checking every mod or the ticked
/// ones, and the tracking screen that can follow a whole-library check or that the Updates page opens. It also
/// switches the character view's Updates filters off once the library has no updates left.
///
/// **Mounted above the page switcher**, like `DownloadQueueHost`. A check over a large library takes seconds, and
/// the Library page is rebuilt for every character and disposed on every page switch; a pass owned by it would
/// lose its results and its report the moment the user looked elsewhere. Below the `Navigator`, since the
/// resolution screen is a dialog.
///
/// [libraryCheckRunningProvider] says a pass is running, so every control that would start another is disabled.
class LibraryActionsHost extends ConsumerStatefulWidget {
  const LibraryActionsHost({
    super.key,
    required this.child,
    this.updateFetcher,
    this.updatesFetcher,
    this.originWriter,
  });

  final Widget child;

  /// Injected only by tests. Defaults to the shared GameBanana client, which a widget test must not be allowed to
  /// reach.
  final ModRecordFetcher? updateFetcher;

  /// Injected only by tests, for the same reason. The second phase — asking each flagged mod's release feed which
  /// files shipped together.
  final ModUpdatesFetcher? updatesFetcher;

  /// Injected only by tests — see [OriginWriter].
  final OriginWriter? originWriter;

  /// The host above [context]. Every page is under one.
  static LibraryActions of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_LibraryActionsScope>()!.actions;

  @override
  ConsumerState<LibraryActionsHost> createState() => _LibraryActionsHostState();
}

/// What a control below [LibraryActionsHost] can ask it to do.
abstract interface class LibraryActions {
  /// Checks every tracked mod for updates. With mods whose tracking the results let the user sort out, opens that
  /// screen; otherwise reports the outcome as a notification.
  Future<void> checkForUpdates();

  /// Checks only [mods], the All mods table's selection or the mods the Updates page's "Check them now" names, and
  /// reports the outcome as a notification. The tracking screen is the whole library's, opened by a whole-library
  /// check or from the Updates page, never by this.
  Future<void> checkMods(List<ModInfo> mods);

  /// Opens the "sort out mod tracking" screen, running the check first when there is nothing in hand to show.
  Future<void> sortOutTracking();
}

class _LibraryActionsScope extends InheritedWidget {
  const _LibraryActionsScope({required this.actions, required super.child});

  final LibraryActions actions;

  @override
  bool updateShouldNotify(_LibraryActionsScope old) => !identical(actions, old.actions);
}

class _LibraryActionsHostState extends ConsumerState<LibraryActionsHost> implements LibraryActions {
  @override
  Widget build(BuildContext context) {
    // The character view's Updates filters switch themselves off once the library has none left, rather than leaving
    // the grid filtered to nothing with a control the user has to work out they need to press. Here because the last
    // update is as often dealt with from the All mods table, while the character view is disposed.
    //
    // Keyed on the **library**, not on the view-scoped count: on that this would fire merely because the user picked
    // a character with no updates of its own, and the filter would evaporate whenever they looked somewhere else.
    //
    // Deferred a frame because a listener can fire *during* the rebuild its own change triggered, and Riverpod
    // refuses a provider write in that window.
    ref.listen(libraryHasUpdatesProvider, (_, hasUpdates) {
      if (hasUpdates) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final grid = ref.read(modGridFilterProvider.notifier);
        if (grid.state == ModGridFilter.updates) grid.state = ModGridFilter.all;
        final list = ref.read(characterListFilterProvider.notifier);
        if (list.state == CharacterListFilter.updates) list.state = CharacterListFilter.all;
      });
    });
    return _LibraryActionsScope(actions: this, child: widget.child);
  }

  @override
  Future<void> checkForUpdates() => _runUpdateCheck(ref.read(bulkUpdateCheckPlanProvider));

  @override
  Future<void> checkMods(List<ModInfo> mods) => _runUpdateCheck(planBulkUpdateCheck(mods), wholeLibrary: false);

  /// [onDemand] is "sort out mod tracking" running the check first: the screen then opens for untracked mods too, since the user asked for it.
  /// A check of part of the library ([wholeLibrary] false) only reports, and doesn't count as the library checked.
  Future<void> _runUpdateCheck(BulkUpdateCheckPlan plan, {bool onDemand = false, bool wholeLibrary = true}) async {
    final running = ref.read(libraryCheckRunningProvider.notifier);
    if (running.state || !plan.hasWork) return;
    running.state = true;
    final progress = ref.read(libraryCheckProgressProvider.notifier);
    final checks = ref.read(modUpdateChecksProvider.notifier);
    final BulkUpdateCheckOutcome outcome;
    try {
      // Shared with the opt-in startup check, so the two cannot disagree about
      // the cache or about what a pass leaves behind.
      outcome = await runLibraryUpdateCheck(
        plan: plan,
        client: ref.read(gameBananaClientProvider),
        fetch: widget.updateFetcher,
        fetchUpdates: widget.updatesFetcher,
        onProgress: (reached) => progress.state = reached,
      );
      // Before the progress is cleared, so a mod the check reached never reads unchecked in between.
      checks.state = mergedChecks(checks.state, outcome);
    } finally {
      // Cleared **before** the results screen opens, not after it closes. The
      // spinner reports the request, and the request is over — leaving it
      // turning behind a modal the user is reading says the app is still
      // working, and disables the control they would press next.
      // Unconditional: the controller outlives this host, and a flag left set would disable every check.
      progress.state = const {};
      running.state = false;
    }
    if (!mounted) return;
    if (wholeLibrary) {
      final records = ref.read(modUpdateRecordsProvider.notifier);
      records.state = mergedRecords(records.state, outcome);
      if (outcome.abortedBy == null) ref.read(libraryCheckedAtProvider.notifier).state = DateTime.now();
    } else {
      // A record there means the library was checked, and the tracking screen would call every other mod unreached.
      // A page the whole check already holds is refreshed there too.
      keepModPages(ref, outcome.records);
    }
    // Before the results screen, whose own writes go to the same sidecars.
    await rememberDownloadNamesFrom(ref, outcome.records, writer: widget.originWriter);
    if (!mounted) return;
    if (!wholeLibrary) {
      showUpdateCheckOutcome(context, outcome);
      return;
    }

    // The results screen opens by itself only when it has something to ask — otherwise a modal stands between the
    // user and the badges they pressed for. It states the summary itself when it does open, so a notification is
    // never raised behind it. Untracked mods alone do not count as something to ask here, or a library that keeps
    // some would get a modal after every check.
    final resolution = ref.read(bulkResolutionPlanProvider);
    if (!(onDemand ? resolution.listsAnything : resolution.hasWork)) {
      showUpdateCheckOutcome(context, outcome);
      return;
    }
    await _showResolution(
      resolution,
      // The pass's own tally of what it could not reach, plus the pages it found gone: more precise than the plan's
      // count, which takes in any tracked mod with no record in hand. A union of folder ids, so a folder whose base
      // page is gone and whose patch was not reached counts once.
      unreachable: {...outcome.failed, ...resolution.goneIds}.length,
    );
  }

  /// Untracked mods open the screen on their own, with no check at all when nothing is tracked:
  /// their rows need no mod page, and the Updates page's buttons must never end in a notice that leaves them out.
  @override
  Future<void> sortOutTracking() async {
    if (ref.read(libraryCheckRunningProvider)) return;
    final checkPlan = ref.read(bulkUpdateCheckPlanProvider);
    final resolution = ref.read(bulkResolutionPlanProvider);
    final inHand = ref.read(modUpdateRecordsProvider).isNotEmpty;
    final showable = resolution.hasWork || (inHand && resolution.untracked.isNotEmpty);
    if (!showable && checkPlan.hasWork) {
      await _runUpdateCheck(checkPlan, onDemand: true);
      return;
    }
    if (!resolution.listsAnything) return;
    // Not zero: a mod with no record in hand is one this screen cannot cover, and dropping it makes the dialog
    // under-report on the door that exists to reopen it. With no records at all nothing was looked up, so there is
    // nothing to report as unreached.
    await _showResolution(resolution, unreachable: inHand ? resolution.unreachable : 0);
  }

  /// The update count is read **library-wide** rather than taken from whichever
  /// door opened the screen, so one sentence in one dialog cannot mean "in your
  /// library" or "on this character" depending on how it was reached.
  Future<void> _showResolution(BulkResolutionPlan plan, {required int unreachable}) async {
    final wrote = await showBulkResolutionDialog(
      context,
      plan,
      updatesFound: ref.read(libraryUpdateCountProvider),
      unreachable: unreachable,
      writer: widget.originWriter ?? originWriterFor(ref.read(modManagerServiceProvider.future)),
      reader: (modName) => originReaderFor(ref.read(modManagerServiceProvider.future))(modName),
    );
    // Only on a write: the plan is derived from the records and the library, so
    // a run that changed nothing leaves nothing stale behind. The status badges
    // are drawn from `ModInfo.origin`, which only a scan refreshes.
    if (wrote && mounted) await ref.read(libraryProvider.notifier).rescan();
  }
}
