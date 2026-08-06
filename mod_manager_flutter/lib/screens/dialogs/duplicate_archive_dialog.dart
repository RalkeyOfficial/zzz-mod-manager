import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../utils/state_providers.dart';

/// The gate every ingest path runs before installing an archive: **false means
/// don't install it.**
///
/// True when the archive's hash is new to the library, when there is no hash to
/// check (null-or-exact — a miss costs nothing and teaches nothing), or when the
/// user chose to install a known duplicate anyway.
///
/// Shared so the check cannot drift between the marketplace and the mods tab, and
/// so both get the same freshness guarantee: the library snapshot is invalidated
/// first, because a stale one would name a folder the user has since deleted —
/// and being told you already own something you don't is worse than not being
/// told at all. One extra scan per import, single-digit milliseconds, against an
/// operation that just unpacked an archive.
///
/// Worth knowing what this can and cannot catch. It matches only archives *this
/// build* ingested, since the hash is banked at ingest and cannot be recovered
/// afterwards — a zip is not reproducible from its extracted files. So it finds
/// nothing at all in a library that predates the origin block, and it never
/// matches a re-zipped copy of the same mod: any repack changes the md5 even when
/// the contents are identical. A bonus fast path, never load-bearing.
Future<bool> confirmArchiveNotDuplicate(
  BuildContext context,
  WidgetRef ref,
  String? archiveMd5,
) async {
  if (archiveMd5 == null) return true;

  ref.invalidate(installedModsIndexProvider);
  final index = await ref.read(installedModsIndexProvider.future);
  final installedAs = index.installsOfArchive(archiveMd5);
  if (installedAs.isEmpty) return true;

  if (!context.mounted) return false;
  return confirmDuplicateArchive(context, installedAs);
}

/// Asks whether to install an archive that is byte-identical to one already in
/// the library. Returns true to go ahead.
///
/// Shared by both ingest paths — the marketplace install and the mods tab's
/// drag-drop / file-picker import — so the two cannot word the same fact
/// differently.
///
/// **The wording is the whole point.** A hash match is a *matching key*, never an
/// integrity or authenticity claim: it says these bytes are the bytes you already
/// unpacked, and nothing about whether either copy is safe or intact. So this says
/// "byte-identical to", and there is no checkmark, no shield, and no "verified".
///
/// Installing anyway is a legitimate choice, which is why this is a question and
/// not a refusal: the same archive genuinely can become a second mod folder, and
/// re-installing is how a user repairs one they broke.
Future<bool> confirmDuplicateArchive(
  BuildContext context,
  List<String> installedAs,
) async {
  final loc = context.loc;
  final answer = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(loc.t('marketplace.duplicate_archive_title')),
      content: Text(
        loc.t(
          'marketplace.duplicate_archive_message',
          params: {'mods': installedAs.join(', ')},
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(loc.t('marketplace.duplicate_archive_skip')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(loc.t('marketplace.duplicate_archive_install')),
        ),
      ],
    ),
  );
  // A dismissed dialog is not consent.
  return answer ?? false;
}
