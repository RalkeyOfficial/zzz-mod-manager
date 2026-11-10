import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../models/character_info.dart';
import '../../models/gamebanana/gamebanana.dart';
import '../../models/mod_download.dart';
import '../../services/log/logger.dart';
import '../../utils/notifications.dart';
import '../../utils/state_providers.dart';
import 'apply_update_flow.dart';
import 'update_modal.dart';

final Logger _log = Logger('update');

/// Writes one picked file over one mod, as [applyModUpdate] does. The seam is for tests.
typedef ModUpdater =
    Future<UpdateFlowOutcome> Function(
      BuildContext context,
      WidgetRef ref, {
      required ModInfo mod,
      required DownloadKey? subject,
      required GbFile file,
      required List<GbFile> published,
      UpdateRunPosition? run,
    });

/// What a pick's turn finds.
enum _Turn {
  /// The mod is there, free and still has its update: it runs.
  run,

  /// The mod left the library.
  gone,

  /// The mod's folder is being written.
  busy,

  /// Its mark is gone: an update of another mod from the same archive wrote this folder.
  settled,

  /// Its update was ignored while the run went.
  ignored,
}

_Turn _turnOf(ProviderContainer container, UpdatePick pick) {
  if (!container.read(modsProvider).any((mod) => mod.id == pick.modId)) return _Turn.gone;
  if (container.read(modWritesInProgressProvider).contains(pick.modId)) return _Turn.busy;
  final check = container.read(modUpdateChecksProvider)[pick.modId];
  if (check == null || (!check.hasUpdate && !check.dismissed)) return _Turn.settled;
  return check.hasUpdate ? _Turn.run : _Turn.ignored;
}

/// Updates the mods [picks] names, one after another in list order, each through the flow a single update runs: its
/// download wait, the folder question when the layout is unknown or changed, the archive's password, the confirmation,
/// the write and the result.
///
/// **Nothing is prefetched, combined or unattended.** An archive's layout and patch facts exist only once it has been
/// downloaded and unpacked, so each update is asked about when its turn comes, with the user at the screen.
///
/// - A mod gone from the library is skipped without a word. One whose folder is being written, or whose update was
///   ignored while the run went, is skipped with a Note. One whose mark an earlier update settled, because both came
///   from one archive and the first's confirmation listed this one, is skipped with a Note too: it is already written.
/// - Declining anywhere (the download's Cancel, a closed folder question or confirmation, an archive password left
///   unanswered) ends the run, with a Note saying how far it got. A failure is its own error card and the run goes on.
/// - A result offers Next only while a later pick can still run.
/// - The run stops before the next mod when [context] has gone: the entry in progress finishes, since a write begun
///   after its confirmation always does.
///
/// The count in "N of total updated" is the mods whose update was written, with the ones written along with another
/// mod of their archive. One rescan after the last entry. A clean run raises no card, since each write already showed
/// its result.
Future<void> runModUpdates(
  BuildContext context,
  WidgetRef ref,
  List<UpdatePick> picks, {
  ModUpdater update = applyModUpdate,
}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final notify = context.notify;
  final loc = context.loc;
  var done = 0;
  var stopped = false;

  ModInfo? modOf(String id) {
    for (final mod in container.read(modsProvider)) {
      if (mod.id == id) return mod;
    }
    return null;
  }

  bool markSettled(String id) => container.read(modUpdateChecksProvider)[id]?.hasUpdate != true;

  void skipped(ModInfo mod, String title, String body) =>
      notify.note(title, body: body, characterId: mod.characterId);

  for (final (index, pick) in picks.indexed) {
    if (!context.mounted) {
      stopped = true;
      break;
    }
    final turn = _turnOf(container, pick);
    final mod = modOf(pick.modId);
    switch (turn) {
      case _Turn.gone:
        _log.info('update skipped, the mod is gone', fields: {'mod': pick.modId});
        continue;
      case _Turn.busy:
        skipped(
          mod!,
          loc.t('mods.update_bulk.run_busy_title'),
          loc.t('mods.update_bulk.run_busy_body', params: {'mod': mod.name}),
        );
        continue;
      case _Turn.settled:
        skipped(
          mod!,
          loc.t('mods.update_bulk.run_skipped_title'),
          loc.t('mods.update_bulk.run_skipped_body', params: {'mod': mod.name}),
        );
        done++;
        continue;
      case _Turn.ignored:
        skipped(
          mod!,
          loc.t('mods.update_bulk.run_ignored_title'),
          loc.t('mods.update_bulk.run_ignored_body', params: {'mod': mod.name}),
        );
        continue;
      case _Turn.run:
        break;
    }

    final outcome = await update(
      context,
      ref,
      mod: mod!,
      subject: pick.subject,
      file: pick.file,
      published: pick.published,
      run: UpdateRunPosition(
        index: index + 1,
        total: picks.length,
        laterCanRun: () => picks.skip(index + 1).any((later) => _turnOf(container, later) == _Turn.run),
      ),
    );
    _log.info('update in a run ended', fields: {'mod': mod.id, 'outcome': outcome.name});
    // Written is not enough: an archive's other mods can be written while this one, unticked, is left as it was.
    if (outcome == UpdateFlowOutcome.written && markSettled(mod.id)) done++;
    if (outcome.stopsRun) {
      stopped = true;
      break;
    }
  }

  await container.read(libraryProvider.notifier).rescan();
  if (stopped) {
    notify.note(
      loc.t('mods.update_bulk.run_stopped_title'),
      body: loc.plural(
        'mods.update_bulk.run_stopped_body',
        picks.length,
        params: {'done': '$done', 'total': '${picks.length}'},
      ),
    );
  }
}
