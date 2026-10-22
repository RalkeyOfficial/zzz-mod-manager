import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../../models/gamebanana/gamebanana.dart';
import '../../../services/download/download_job.dart';
import '../../../services/download/download_queue.dart';
import '../../../services/download/queue_policy.dart';
import '../../../services/gamebanana/file_selection.dart';
import '../../../services/gamebanana/remote_mod_metadata.dart';
import '../../../services/log/logger.dart';
import '../../../utils/marketplace_providers.dart';
import '../../../utils/notification_actions.dart';
import '../../../utils/notifications.dart';
import '../../../utils/state_providers.dart';
import '../../../utils/zzz_characters.dart';

final Logger _log = Logger('install');

/// A card's or the carousel's Install, for a mod whose enrichment names one current file: fetches the mod page, then
/// queues [file] as an install, for the GameBanana category's character, Unassigned when it maps to none, and with
/// the Turn on after installing setting.
///
/// The mod page is what the install fills the description and the gallery from, and a listing record carries
/// neither. The card shows Queued meanwhile ([marketplacePendingInstallsProvider]).
///
/// Runs on the app's [container], never on the screen's `State`: the fetch takes a moment and the user may switch
/// pages in it, and the press must still queue its file. Only the fallback, opening the mod page, needs the screen:
/// when the page can't be fetched, or no longer names [file] as its one current file, the mod page opens over the
/// page the card is on if [screenMounted] says Browse is still on screen and its pages are as they were at the press.
/// Otherwise nothing happens, since the card's own button is still there to press again.
Future<void> installSoleFile(
  ProviderContainer container,
  AppLocalizations loc, {
  required int modId,
  required GbFile file,
  required bool Function() screenMounted,
}) async {
  final pending = container.read(marketplacePendingInstallsProvider.notifier);
  if (pending.state.contains(modId)) return;
  pending.state = {...pending.state, modId};
  final pagesAtPress = container.read(marketplaceRoutesProvider);
  GbMod? mod;
  try {
    mod = await container.read(modProfileProvider(modId).future);
  } on GbException {
    // The client has logged the request that failed.
  } on Object catch (error) {
    _log.warning('mod page did not load for an install', error: error, fields: {'mod_id': modId});
  } finally {
    pending.state = {...pending.state}..remove(modId);
  }

  // The card's rule again, on the page itself: the files may have changed since the listing was enriched, and a
  // file is never picked for the user.
  final current = mod == null ? null : selectDefaultFile(mod.allFiles).file;
  if (mod == null || current == null || current.idRow != file.idRow) {
    if (screenMounted() && listEquals(container.read(marketplaceRoutesProvider), pagesAtPress)) {
      container.read(marketplaceRoutesProvider.notifier).open(MarketplaceModRoute(modId));
    }
    return;
  }
  enqueueMarketplaceFile(
    container,
    loc,
    mod,
    current,
    DownloadIntent.install,
    // Unassigned for a category that maps to no character, as the mod page would show it.
    characterId: RemoteModMetadata.fromMod(mod).characterId ?? unknownCharacterId,
    turnOn: container.read(marketplaceTurnOnAfterInstallProvider),
  );
}

/// Hands one file of one mod to the download queue.
///
/// This is where remote identity reaches the origin block: the mod id, file id, version and variant label are all
/// known here, before a single byte is fetched, so the block lands at `exact`, the tier only a download or a
/// checksum match earns. See `docs/origin-tracking.md` §2.
///
/// [characterId] is the character the install files the new mods under, as the mod page shows it, Unassigned
/// included, and [turnOn] whether it turns them on; both travel with the job, fixed at the press, or taken over by
/// the press that resumes a paused one.
///
/// It does not wait, and it does not own what happens next: the install that follows belongs to
/// `DownloadQueueHost`, mounted above the pages. The mod page travels with the job.
void enqueueMarketplaceFile(
  ProviderContainer container,
  AppLocalizations loc,
  GbMod mod,
  GbFile file,
  DownloadIntent intent, {
  required String? characterId,
  bool turnOn = false,
}) {
  final subject = mod.name ?? file.file ?? loc.t('marketplace.unknown_file');

  // Asked before enqueuing rather than inferred from what comes back: a freshly admitted job is started the same
  // turn, so "did it come back queued?" answers a question about the concurrency cap, not about whether this file
  // was already being fetched. A paused job for the file is not a duplicate: the press resumes it with this press's
  // intent, character and Turn on, and its card coming back is the acknowledgement.
  final existing = activeJobForFile(container.read(downloadQueueProvider), file.idRow);
  final duplicate = existing != null && existing.state != DownloadJobState.paused;

  final job = container
      .read(downloadQueueProvider.notifier)
      .enqueue(
        file: file,
        subject: subject,
        characterId: characterId,
        mod: mod,
        intent: intent,
        turnOn: intent == DownloadIntent.install && turnOn,
      );

  final notify = container.read(notificationsProvider.notifier);
  if (job.state == DownloadJobState.failed) {
    // The one way enqueuing fails outright: a file whose download url will not parse. It is already a failed row in
    // the panel; this is what the user standing at the button sees.
    notify.error(
      loc.t('marketplace.download_failed_title'),
      body: subject,
      characterId: characterId,
      actions: [openDownloadsAction(loc, container)],
    );
    return;
  }
  // A successful enqueue says nothing here. `DownloadQueueHost` raises a Working progress notification the same
  // turn, and that card is the acknowledgement.
  //
  // The exception is a press that changes nothing. The card is already up and its count does not move, so without
  // this the button reads as broken.
  if (duplicate) {
    notify.note(
      loc.t('marketplace.download_already_queued_title'),
      body: subject,
      characterId: characterId,
      actions: [openDownloadsAction(loc, container)],
    );
  }
}
