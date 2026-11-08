import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;

import '../../l10n/app_localizations.dart';
import '../../models/app_notification.dart';
import '../../models/mod_origin_seed.dart';
import '../../services/import_result.dart';
import '../../services/import_review.dart';
import '../../services/ingest_origin_builder.dart';
import '../../services/log/logger.dart';
import '../../services/mod_manager_service.dart' show ModManagerService;
import '../../services/update_apply/local_update.dart';
import '../../services/update_apply/mod_activation_port.dart';
import '../../services/update_apply/update_applier.dart';
import '../../utils/state_providers.dart';
import '../components/import_failure_message.dart';
import 'apply_update_flow.dart' show updateFailureMessage;

final Logger _log = Logger('update.apply');

/// Writes the dropped folders of the rows set to Update it into the mods they matched, one after another
/// (`docs/importing-mods.md` §5). Answers the names of the mods that were updated and a card for each that was not.
///
/// Reads providers through [container], since the write outlives the page. A failure does not stop the rest: each mod
/// has its own snapshot and its own copy.
///
/// Whether a mod is busy is read again right before its write, not only when the review opened: a row whose mod is
/// being written then is skipped and named, and the files it would have written are not imported.
Future<({List<String> updated, List<NotificationLines> failures})> updateFromDropped({
  required ProviderContainer container,
  required AppLocalizations loc,
  required ModManagerService service,
  required String? modsPath,
  required List<ImportRow> rows,
  required Map<String, ModOriginSeed> originSeeds,
}) async {
  final updated = <String>[];
  final failures = <NotificationLines>[];
  if (rows.isEmpty) return (updated: updated, failures: failures);
  if (modsPath == null) {
    failures.add(importFailureMessage(loc, ImportFailure.libraryNotConfigured, container: container));
    return (updated: updated, failures: failures);
  }

  final snapshots = container.read(snapshotServiceProvider);
  final applier = UpdateApplier(
    snapshots: snapshots,
    activation: ModManagerActivationPort(service, leaveOff: (m) => leftOffAfterWrite(container, m)),
  );
  for (final row in rows) {
    final target = row.existing!.id;
    final mod = container.read(modsProvider).where((m) => m.id == target).firstOrNull;
    if (mod == null) {
      _log.warning('a mod to update is gone', fields: {'mod': target});
      failures.add(
        NotificationLines(
          loc.t('mods.update_apply.mod_missing_title'),
          loc.t('mods.update_apply.mod_missing', params: {'mod': target}),
          kind: NotificationKind.error,
        ),
      );
      continue;
    }
    final combined = row.item.kind == ImportSourceKind.combined;
    final seed = combined
        ? IngestOriginBuilder.combineSeeds(row.item.sources.map((folder) => originSeeds[folder]))
        : originSeeds[row.item.sources.single] ?? ModOriginSeed.importedFolder;
    // Nothing between this read and `whileWritingMod` awaits, so no other write can slip in.
    if (container.read(modWritesInProgressProvider).contains(mod.id)) {
      _log.warning('a mod to update is being written', fields: {'mod': mod.id});
      failures.add(
        NotificationLines(
          loc.t('mods.import.update_skipped_title'),
          loc.t('mods.import.update_skipped_body', params: {'mod': mod.name}),
          kind: NotificationKind.error,
        ),
      );
      continue;
    }
    final outcome = await whileWritingMod(
      container,
      mod.id,
      () => applyLocalUpdate(
        applier: applier,
        amend: service.updateModOrigin,
        mod: mod,
        modsPath: modsPath,
        folders: {for (final folder in row.item.sources) folder: combined ? path.basename(folder) : ''},
        seed: seed,
      ),
    );
    // Whether the write landed or not: a failed copy may have changed the folder part-way.
    service.invalidateKeybinds(mod.id);
    if (outcome.write.snapshot != null) {
      container.invalidate(modBackupsProvider);
      await snapshots.prune();
    }
    if (!outcome.success) {
      failures.add(updateFailureMessage(loc, outcome.write, mod));
      continue;
    }
    // A verdict names the folder's layers and its file, and both just changed.
    forgetUpdateCheck(container, mod.id);
    // Only a character the user changed in the row: a guess never moves a mod.
    final character = row.character;
    if (character != null && character != mod.characterId) {
      await service.setModCharacter(mod.id, character);
    }
    updated.add(mod.name);
  }
  return (updated: updated, failures: failures);
}
