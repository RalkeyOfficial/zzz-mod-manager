/// **Installing a patch, for both of the ways a mod gets into the library.**
///
/// A download from the Marketplace and a folder dragged onto the window are the
/// same install once the files exist, and this is the part they share: ask where
/// a patch goes before anything is copied, then perform every write that answer
/// implies once the copy is done.
///
/// **It is two halves because the copy sits between them**, and they have to
/// agree about the same folder:
///
/// - a folder going *into* an existing mod must be taken out of the import, or
///   it lands twice;
/// - a folder whose write was refused must be left *in* it, or it is lost;
/// - nothing may be said or written about a mod the import did not create.
///
/// The one thing the two entry points do not share is the patch's own identity:
/// a Marketplace download knows which mod page and file it is, and a hand-
/// dragged folder has none. That changes what can be *recorded*, never what is
/// installed — see [PatchIdentity].
library;

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;

import '../../l10n/app_localizations.dart';
import '../../models/app_notification.dart';
import '../../models/character_info.dart';
import '../../models/gamebanana/gamebanana.dart';
import '../../models/mod_download.dart';
import '../../models/origin_enums.dart';
import '../../services/folder_contents.dart';
import '../../services/library_file_index.dart';
import '../../services/log/confirmations.dart';
import '../../services/patch_destination_ranking.dart';
import '../../services/patch_placement.dart';
import '../../services/patch_record.dart';
import '../../services/patch_scan.dart';
import '../../services/update_apply/update_applier.dart';
import '../../utils/zzz_characters.dart';
import 'apply_update_flow.dart';
import 'import_selection_dialog.dart';
import 'patch_install_prompt.dart';

/// The mods [plan] is about to create, in the shape the copy will create them.
///
/// A `separate` install makes one mod per folder, named after it; a `combined`
/// one makes a single mod whose subfolders are named after each source — the
/// same names `importMods` and `importCombinedMod` produce, which is what keeps
/// a pre-import answer and a post-import one about the same folder in agreement.
List<PlannedMod> plannedMods(ImportPlan plan, List<String> folders) =>
    plan.combine
        ? [
            PlannedMod(
              name: plan.combinedName,
              sources: {
                for (final dir in folders) dir: path.basename(dir),
              },
            ),
          ]
        : [
            for (final dir in folders)
              PlannedMod(name: path.basename(dir), sources: {dir: ''}),
          ];

/// The patch's **own** remote identity, for the installs that have one.
///
/// A Marketplace download knows exactly which mod page and file it is, and that
/// is what gets recorded against the mod it is written into. A folder dragged
/// off a disk has no page at all — so there is nothing to record, and a
/// companion cannot be written without one. The install is the same operation
/// either way; only the bookkeeping differs.
class PatchIdentity {
  const PatchIdentity({
    required this.modId,
    this.fileId,
    this.version,
    this.versionLabel,
    this.archiveMd5,
  });

  final int modId;
  final int? fileId;
  final String? version;
  final String? versionLabel;
  final String? archiveMd5;

  /// **At `exact` on both axes**, which this is the one route to for a layer the
  /// user did not identify by hand: every other one is somebody telling us about
  /// bytes they moved in themselves.
  ///
  /// No `role`: it is taken from the position the layer lands in, and the write
  /// that places it is what knows that.
  ModDownload get layer => ModDownload(
        modId: modId,
        modIdConfidence: OriginConfidence.exact,
        fileId: fileId,
        version: version,
        versionLabel: versionLabel,
        versionConfidence: OriginConfidence.exact,
        archiveMd5: archiveMd5,
      );
}

/// One patch write the install has worked out and not yet performed.
class PatchWrite {
  const PatchWrite({
    required this.into,
    required this.source,
    required this.incoming,
    required this.existing,
    required this.placement,
  });

  final InstallIntoMod into;
  final Directory source;
  final FolderContents incoming;
  final FolderContents existing;
  final PatchPlacement placement;
}

/// Why a patch could not be written into the mod that was chosen for it.
///
/// Told apart because they call for different things from the user.
enum PatchRefusal {
  /// Nothing in the patch matches anything in the target — almost certainly the
  /// wrong mod. A snapshot is not a reason to find out the expensive way.
  wrongMod,

  /// The target holds its own files **twice** (`sfw/body.dds` beside
  /// `nsfw/body.dds`). No install path creates that shape: the import picker
  /// settles separate-or-combined before anything is copied. So it was
  /// assembled by hand outside that flow, and a patch written blind into a
  /// folder that is already wrong makes it worse rather than better — the
  /// folder is what needs sorting out, not this install.
  brokenMod,

  /// The chosen folder is not there any more.
  goneMod,
}

/// Everything the patch question settled, before anything is copied.
class PatchInstallDecision {
  const PatchInstallDecision({
    required this.scan,
    this.destinations = const <String, PatchDestination>{},
    this.writes = const <String, PatchWrite>{},
    this.refused = const <PatchRefusal, List<String>>{},
  });

  /// What both patch rules concluded about the mods this import will create.
  final PlannedPatchScan scan;

  /// What the user answered, per planned mod name. Empty when nothing was asked.
  final Map<String, PatchDestination> destinations;

  /// The writes to perform after the copy, per planned mod name.
  final Map<String, PatchWrite> writes;

  final Map<PatchRefusal, List<String>> refused;

  /// Whether [folder] must be left out of the import — its contents are going
  /// into a mod that already exists, so no new folder is created for it.
  bool excludes(String folder) => writes.containsKey(path.basename(folder));

  /// What the user said each new folder patches, where they said. Only the
  /// new-folder destination has one; the other answer *is* the destination.
  Map<String, ModDownload> get namedBases => <String, ModDownload>{
        for (final entry in destinations.entries)
          if (entry.value case InstallAsNewMod(base: final base?))
            entry.key: base,
      };
}

/// Fetches the mod a patch applies to and writes it into that patch's folder,
/// **base first, then the patch back on top**. True when the folder now holds
/// both.
///
/// A seam because the download needs a context and a progress dialog, and this
/// file's job is to decide *what* happens rather than to run it. Absent means
/// naming the base only records it — the behaviour before an install existed.
typedef BaseInstaller = Future<bool> Function(
  String modName,
  ModDownload base,
  GbFile file,
);

/// Raises the destination prompt. A seam so the phases can be tested without
/// driving a modal.
typedef PatchDestinationPrompt = Future<Map<String, PatchDestination>?>
    Function(
  BuildContext context, {
  required List<PatchInstallSubject> subjects,
  required List<ModInfo> library,
  bool combined,
});

/// **Phase one: both patch rules, and the question they raise, before the copy.**
///
/// The answer exists as soon as the folders do, and asking here is the whole
/// difference between offering a destination and warning about a folder the user
/// then has to go and find again.
///
/// Returns **null when the user declined the install** — a patch with nothing to
/// patch is a folder they may well not want, and this is the last point at which
/// nothing has been written.
///
/// [patchModId] is the download's own mod page, when it has one. It is refused
/// as an answer to "what does this patch?" — a folder cannot patch itself — and
/// a hand-dragged folder simply has none.
///
/// [patchRequirements] is what that page's author declared it needs. A
/// requirement linking a mod page is sometimes the mod being patched, and where
/// the library holds that mod it goes to the top of the destinations with the
/// author's own words on it. It is never an answer — see [GbRequirement].
Future<PatchInstallDecision?> decidePatchInstall(
  BuildContext context, {
  required ImportPlan plan,
  required List<String> folders,
  required String modsPath,
  required List<ModInfo> library,
  int? patchModId,
  List<GbRequirement> patchRequirements = const <GbRequirement>[],
  PatchDestinationPrompt prompt = showPatchInstallPrompt,
}) async {
  // Scoped by the import picker, which is what decides where one resulting mod
  // ends and the next begins: judged folder by folder, an ordinary mod that
  // ships its textures in one folder and its `.ini` in another reads as a patch.
  final scan = await scanPlannedMods(plannedMods(plan, folders));
  if (scan.patchShaped.isEmpty) return PatchInstallDecision(scan: scan);

  // Only where a library destination is on offer at all: a combined install
  // does not get that choice, so the walk would have no reader.
  final ranked = plan.combine
      ? const <String, List<DestinationRank>>{}
      : await rankPatchDestinations(
          scan: scan,
          library: library,
          modsPath: modsPath,
          patchRequirements: patchRequirements,
        );

  // **Unable to ask is not the same as declined.** The scan is disk I/O and the
  // caller's context can be gone by the time it finishes. Answering "no
  // destinations" installs every folder as an ordinary mod, which is what would
  // have happened without the prompt at all; cancelling would throw away a
  // download because a tab was switched.
  if (!context.mounted) return PatchInstallDecision(scan: scan);

  final answered = await prompt(
    context,
    subjects: [
      for (final name in scan.patchShaped)
        PatchInstallSubject(
          modName: name,
          patchModId: patchModId,
          kind: scan.assetPatches.containsKey(name)
              ? PatchKind.assets
              : PatchKind.references,
          destinations: ranked[name] ?? const <DestinationRank>[],
        ),
    ],
    library: library,
    combined: plan.combine,
  );
  if (answered == null) {
    logConfirmation('patch.install',
        accepted: false, subject: scan.patchShaped.join(', '));
    return null;
  }

  // Per subject, with where it went and how the ranking had placed that folder
  // — the only evidence that will ever accumulate about whether the ordering in
  // `docs/patch-destinations.md` is worth having.
  for (final entry in answered.entries) {
    final into = entry.value;
    final order = ranked[entry.key] ?? const <DestinationRank>[];
    logConfirmation('patch.destination',
        accepted: true,
        subject: entry.key,
        fields: {
          'destination': into is InstallIntoMod ? into.modName : 'new folder',
          if (into is InstallIntoMod)
            'rank_of_choice':
                order.indexWhere((r) => r.modId == into.modId) + 1,
          if (into is InstallAsNewMod) 'base_named': into.base != null,
        });
  }

  return resolvePatchDestinations(
    scan: scan,
    destinations: answered,
    folders: folders,
    modsPath: modsPath,
  );
}

/// Puts each patch's likeliest destinations first, per patch-shaped mod.
///
/// Composition only: the walk is `library_file_index.dart`, the order is
/// `patch_destination_ranking.dart`, and the one judgement made here is that a
/// **library folder** answers for an author's requirement when that folder's
/// recorded origin is the mod the author linked. An untracked folder can never
/// match one, which is correct — nothing says what it is.
///
/// Runs before the prompt opens rather than inside it, so the dialog stays a
/// widget that renders what it is given.
Future<Map<String, List<DestinationRank>>> rankPatchDestinations({
  required PlannedPatchScan scan,
  required List<ModInfo> library,
  required String modsPath,
  List<GbRequirement> patchRequirements = const <GbRequirement>[],
}) async {
  if (library.isEmpty || scan.patchShaped.isEmpty) {
    return const <String, List<DestinationRank>>{};
  }

  final names = await readLibraryFileNames(
    modIds: [for (final mod in library) mod.id],
    modsPath: modsPath,
  );

  final declared = <int>{
    for (final requirement in patchRequirements)
      if (requirement.modId != null) requirement.modId!,
  };
  final required = <String>{
    for (final mod in library)
      // **Any layer the folder holds**, not only what it is: a mod the patch's
      // page names is "already installed" whether it sits at the bottom of some
      // folder or was written into one.
      if (mod.origin?.trackable
              .any((download) => declared.contains(download.modId)) ??
          false)
        mod.id,
  };

  return <String, List<DestinationRank>>{
    for (final name in scan.patchShaped)
      name: rankDestinations(
        fingerprint: destinationFingerprint(
          scan.contents[name] ?? FolderContents.empty,
        ),
        libraryFiles: names,
        requiredMods: required,
      ),
  };
}

/// What the answers mean for the copy that is about to run.
///
/// Every write is resolved **before** any folder is taken out of the import, so
/// a target the placement cannot settle still has a way back: the download
/// becomes an ordinary new mod rather than being lost to a refusal.
Future<PatchInstallDecision> resolvePatchDestinations({
  required PlannedPatchScan scan,
  required Map<String, PatchDestination> destinations,
  required List<String> folders,
  required String modsPath,
}) async {
  final sourceOfPlanned = <String, String>{
    for (final dir in folders) path.basename(dir): dir,
  };

  final writes = <String, PatchWrite>{};
  final refused = <PatchRefusal, List<String>>{};
  for (final entry in destinations.entries) {
    if (entry.value is! InstallIntoMod) continue;
    final into = entry.value as InstallIntoMod;
    final source = sourceOfPlanned[entry.key];
    if (source == null) continue;

    final outcome = await _planPatchWrite(
      source: Directory(source),
      modsPath: modsPath,
      into: into,
    );
    if (outcome.write case final write?) {
      writes[entry.key] = write;
    } else {
      refused.putIfAbsent(outcome.refusal!, () => <String>[]).add(into.modName);
    }
  }

  return PatchInstallDecision(
    scan: scan,
    destinations: destinations,
    writes: writes,
    refused: refused,
  );
}

/// Works out where a patch's files would land, or **why they cannot**.
Future<({PatchWrite? write, PatchRefusal? refusal})> _planPatchWrite({
  required Directory source,
  required String modsPath,
  required InstallIntoMod into,
}) async {
  final target = Directory(path.join(modsPath, into.modId));
  if (!await target.exists()) {
    return (write: null, refusal: PatchRefusal.goneMod);
  }

  final incoming = await readFolderContents(source);
  final existing = await readFolderContents(target);
  final placement = resolvePatchPlacement(
    incoming: incoming.files,
    target: existing.files,
  );
  if (placement.needsChoice) {
    return (write: null, refusal: PatchRefusal.brokenMod);
  }
  if (placement.matchedNothing) {
    return (write: null, refusal: PatchRefusal.wrongMod);
  }

  return (
    write: PatchWrite(
      into: into,
      source: source,
      incoming: incoming,
      existing: existing,
      placement: placement,
    ),
    refusal: null,
  );
}

/// **Phase two: every write the answers imply, once the copy has run.**
///
/// Two kinds, and they act on different mods. A patch going into an existing mod
/// is written **update-shaped** — deactivate, snapshot, place, reactivate —
/// because it overwrites a folder the user is already using and the snapshot is
/// the only way back. A patch that became a folder of its own is only *marked*,
/// which is the one thing that outlives the warning.
///
/// Returns what to tell the user, in the order it should be told.
Future<List<NotificationLines>> applyPatchInstall(
  AppLocalizations loc, {
  required PatchInstallDecision decision,
  required Iterable<String> importedMods,
  required String modsPath,
  required UpdateApplier applier,
  required OriginAmender amend,
  PatchIdentity? patch,
  BaseInstaller? installBase,
}) async {
  final patchedInto = <String, InstallIntoMod>{};
  final writeFailures = <String>[];

  for (final entry in decision.writes.entries) {
    final write = entry.value;
    final result = await applier.applyPatchInto(
      modName: write.into.modId,
      modFolder: Directory(path.join(modsPath, write.into.modId)),
      source: write.source,
      incoming: write.incoming,
      existing: write.existing,
      placement: write.placement,
      // Keys the store of displaced base files. Null for a folder dragged off a
      // disk, which has no page and so nothing to key one by.
      patchModId: patch?.modId,
    );
    if (!result.success) {
      writeFailures.add(write.into.modName);
      continue;
    }
    patchedInto[entry.key] = write.into;

    // **On the target, and only when there is something to name.** The folder
    // is still the base mod — that is what its `origin` says and what it mostly
    // is — and the patch is the second thing in it. A hand-dragged folder has
    // no mod page, so there is no second identity to record and nothing is
    // written rather than something invented.
    if (patch case final identity?) {
      await amend(
        write.into.modId,
        // **With the files it actually wrote.** The paths are the target's, not
        // the ones the archive shipped, and the copy is the only thing that
        // knows them — every rule that puts this patch back, or takes it out,
        // reads this list.
        (current) => withAppliedPatch(
          current,
          identity.layer.copyWith(files: result.writtenFiles),
        ),
      );
    }
  }

  // The scan ran against what the install *planned*, and a folder that already
  // existed was skipped rather than replaced — so nothing may be said or
  // written about a mod that is not actually here.
  final imported = importedMods.toSet();
  final namedBases = decision.namedBases;
  for (final name in decision.scan.patchShaped) {
    if (!imported.contains(name)) continue;
    await amend(
      name,
      (current) => withPatchShape(current, base: namedBases[name]),
    );
  }

  // **Recorded first, then fetched.** The companion is written at `user` before
  // the download starts, so a cancelled or failed install leaves the answer the
  // user gave rather than nothing; a successful one upgrades that entry to
  // `exact` on its way past.
  final completed = <String>{};
  if (installBase != null) {
    for (final entry in decision.destinations.entries) {
      if (!imported.contains(entry.key)) continue;
      if (entry.value
          case InstallAsNewMod(base: final base?, baseFile: final file?)) {
        if (await installBase(entry.key, base, file)) completed.add(entry.key);
      }
    }
  }

  return patchInstallLines(
    loc,
    decision: decision,
    importedMods: importedMods,
    patchedInto: patchedInto,
    writeFailures: writeFailures,
    completed: completed,
  );
}

/// The refusals as **headlines**, for a report that has somewhere better than a
/// notification to put them.
///
/// The drag/drop import ends in a dialog of its own, and a dialog that says
/// "Imported successfully" over an install that did not do what it was told is
/// the one thing it must not say. So it lists these, while the cards carry the
/// full explanation and what to do about it — two copies of one paragraph on
/// screen at once is clutter, and the short form is what a heading needs.
List<String> patchRefusalHeadlines(
  AppLocalizations loc,
  Map<PatchRefusal, List<String>> refused,
) =>
    [
      for (final entry in refused.entries)
        loc.t('mods.dialog.import_refused_line', params: {
          'reason': loc.t(switch (entry.key) {
            PatchRefusal.wrongMod => 'mods.snackbar.patch_wrong_mod_title',
            PatchRefusal.brokenMod => 'mods.snackbar.patch_broken_mod_title',
            PatchRefusal.goneMod => 'mods.snackbar.patch_gone_mod_title',
          }),
          'mods': entry.value.join(', '),
        }),
    ];

/// The [BaseInstaller] both import paths use: fetch the mod a patch applies to
/// and write it into that patch's folder, then place the patch back on top.
///
/// **The patch is everything in the folder**, because the import has just created
/// it and put nothing else there. That is what lets this reuse the ordinary
/// update flow — the folder is set aside, the base is written as any download is,
/// and the patch goes back onto its layout.
///
/// No confirmation: the user answered this in the prompt a moment ago, and asking
/// again is asking twice. A cancelled download is not a failure of anything — the
/// patch stays installed and the base stays recorded, exactly as before this
/// existed.
Future<bool> installNamedBase(
  BuildContext context,
  WidgetRef ref, {
  required String modName,
  required String modsPath,
  required ModDownload base,
  required GbFile file,
  String? characterId,
}) async {
  final folder = Directory(path.join(modsPath, modName));
  final contents = await readFolderContents(folder);
  if (contents.files.isEmpty) return false;
  // The download needs a progress dialog and this context is gone. Reporting
  // "not installed" is honest — nothing was — and leaves the warning standing.
  if (!context.mounted) return false;

  return applyUpdateFlow(
    context,
    ref,
    // The folder exists and its sidecar is written, but nothing has rescanned
    // yet — so this is assembled from what the install already knows rather than
    // read back. Only the id, the name and the portrait are used.
    mod: ModInfo(
      id: modName,
      name: modName,
      characterId: characterId ?? unknownCharacterId,
      isActive: false,
    ),
    // Non-null by construction: this runs only for a base the user named off a
    // mod page, and naming one is what produces the id.
    remoteModId: base.modId!,
    file: file,
    // On-disk spelling: these paths open files.
    patchFiles: contents.actualPaths.values.toList(),
    asCompanion: true,
    confirm: false,
  );
}

/// What an install says about the patches it found, in the order it says it.
///
/// **Only what the user has to act on**, and each as its own card rather than
/// more text under the success: a mod that arrived broken must not read like a
/// mod that arrived.
List<NotificationLines> patchInstallLines(
  AppLocalizations loc, {
  required PatchInstallDecision decision,
  required Iterable<String> importedMods,
  required Map<String, InstallIntoMod> patchedInto,
  required List<String> writeFailures,

  /// Mods whose base was actually fetched and written in, so the folder works
  /// and there is nothing left to warn about.
  Set<String> completed = const <String>{},
}) {
  final imported = importedMods.toSet();
  final scan = decision.scan;
  // **Silenced by a folder that works, never by an answer about it.** Naming the
  // base suppressed this warning on its own, and the folder still did nothing in
  // the game — with the one sentence that would have said so now gone. Named but
  // not installed (no file they could pick, or a download they cancelled) leaves
  // exactly as much for the user to do as saying nothing did.
  final iniPatches = [
    for (final name in scan.iniPatches)
      if (imported.contains(name) && !completed.contains(name)) name,
  ];

  return <NotificationLines>[
    // **A change the user cannot see reports its success.** The patch went into
    // somebody else's folder, so there is no new card to look at — and the one
    // thing they need to know is that a copy was saved first.
    for (final into in patchedInto.values)
      NotificationLines(
        loc.t('mods.snackbar.patch_applied_title'),
        loc.t('mods.snackbar.patch_applied_body',
            params: {'mod': into.modName}),
      ),
    if (writeFailures.isNotEmpty)
      NotificationLines(
        loc.t('mods.snackbar.patch_write_failed_title'),
        loc.t('mods.snackbar.patch_write_failed_body',
            params: {'mods': writeFailures.join(', ')}),
        pinned: true,
      ),
    // Each refusal names its own cause, because they ask different things of
    // the user: one is "you picked the wrong mod", the other is "that mod's
    // folder needs sorting out". Both explain a folder the user did not ask
    // for — the download became an ordinary new mod rather than being lost.
    if (decision.refused[PatchRefusal.wrongMod] case final mods?)
      NotificationLines(
        loc.t('mods.snackbar.patch_wrong_mod_title'),
        loc.t('mods.snackbar.patch_wrong_mod_body',
            params: {'mods': mods.join(', ')}),
        pinned: true,
      ),
    if (decision.refused[PatchRefusal.brokenMod] case final mods?)
      NotificationLines(
        loc.t('mods.snackbar.patch_broken_mod_title'),
        loc.t('mods.snackbar.patch_broken_mod_body',
            params: {'mods': mods.join(', ')}),
        pinned: true,
      ),
    if (decision.refused[PatchRefusal.goneMod] case final mods?)
      NotificationLines(
        loc.t('mods.snackbar.patch_gone_mod_title'),
        loc.t('mods.snackbar.patch_gone_mod_body',
            params: {'mods': mods.join(', ')}),
      ),
    // Not pinned: this one describes a folder that is not a mod at all — a
    // `previews` folder installed on its own — where there is nothing to finish.
    if (scan.incomplete.where(imported.contains) case final mods
        when mods.isNotEmpty)
      NotificationLines(
        loc.t('mods.snackbar.import_no_ini_title'),
        loc.t('mods.snackbar.import_no_ini_body',
            params: {'mods': mods.join(', ')}),
      ),
    // **Only the ones nobody answered for.** A patch whose base mod the user
    // just named in a modal has been told about already, and its card carries
    // the mark; a pinned card repeating it is nagging.
    if (iniPatches.isNotEmpty)
      NotificationLines(
        loc.t('mods.snackbar.import_patch_title'),
        loc.t('mods.snackbar.import_patch_body',
            params: {'mods': iniPatches.join(', ')}),
        // The install warnings that must not time out: the mod does not work
        // until the user acts, and this card is raised beside the success line
        // they were actually waiting for.
        pinned: true,
      ),
    // Named separately from the `.ini` case because the evidence is different:
    // this download brought content nothing can load, rather than asking for
    // content it did not bring.
    for (final name in scan.assetPatches.keys)
      if (imported.contains(name) && !completed.contains(name))
        NotificationLines(
          loc.t('mods.snackbar.import_asset_patch_title'),
          loc.t('mods.snackbar.import_asset_patch_body',
              params: {'mod': name}),
          pinned: true,
        ),
  ];
}
