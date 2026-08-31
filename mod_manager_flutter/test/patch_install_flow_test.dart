import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/l10n/app_localizations.dart';
import 'package:mod_manager_flutter/models/app_notification.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/gamebanana/gamebanana.dart';
import 'package:mod_manager_flutter/models/mod_companion.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/screens/dialogs/patch_install_flow.dart';
import 'package:mod_manager_flutter/screens/dialogs/patch_install_prompt.dart';
import 'package:mod_manager_flutter/services/backup/snapshot_service.dart';
import 'package:mod_manager_flutter/services/mod_metadata_repository.dart';
import 'package:mod_manager_flutter/services/mod_metadata_service.dart';
import 'package:mod_manager_flutter/services/origin_status.dart';
import 'package:mod_manager_flutter/services/patch_destination_ranking.dart';
import 'package:mod_manager_flutter/services/patch_detection.dart';
import 'package:mod_manager_flutter/services/patch_scan.dart';
import 'package:mod_manager_flutter/services/update_apply/update_applier.dart';
import 'package:path/path.dart' as p;

/// **The patch install, shared by both ways a mod gets into the library.**
///
/// The copy sits in the middle of it — the question has to be asked before, and
/// every write it leads to can only happen after — so this is two halves that
/// have to agree about the same folder. It went wrong once already by being
/// written twice, in two screens, and this file is mostly about the halves
/// lining up:
///
/// - a folder going *into* an existing mod must be taken out of the import, or
///   it lands twice;
/// - a folder whose write was refused must be left *in* it, or it is lost;
/// - nothing may be said about a mod the import did not actually create.
///
/// The other subject here is what the two entry points do **not** share: a
/// download from the Marketplace knows which mod page it came from, and a folder
/// dragged off a disk does not. The second one still installs; it just has no
/// identity to record.
class _FakeTagStore implements ModCharacterTagStore {
  final Map<String, String> tags = {};

  @override
  Map<String, String> get modCharacterTags => Map.of(tags);

  @override
  Future<bool> setModCharacterTag(String modId, String characterId) async {
    tags[modId] = characterId;
    return true;
  }

  @override
  Future<bool> removeModCharacterTag(String modId) async {
    tags.remove(modId);
    return true;
  }
}

class _FakeActivation implements ModActivationPort {
  final Set<String> active = {};

  @override
  Future<bool> isActive(String modName) async => active.contains(modName);

  @override
  Future<bool> activate(String modName) async => active.add(modName);

  @override
  Future<bool> deactivate(String modName) async => active.remove(modName);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppLocalizations loc;

  setUpAll(() async {
    loc = AppLocalizations(const Locale('en'));
    await loc.load();
  });

  late Directory tmp;
  late String modsPath;
  late Directory sources;
  late UpdateApplier applier;
  late Map<String, ModOrigin?> origins;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('zzz_patch_flow_');
    modsPath = p.join(tmp.path, 'mods');
    await Directory(modsPath).create(recursive: true);
    sources = Directory(p.join(tmp.path, 'extract'))..createSync();
    applier = UpdateApplier(
      snapshots: SnapshotService(rootPath: p.join(tmp.path, 'backups')),
      activation: _FakeActivation(),
    );
    origins = {};
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  void write(String root, String relative, String contents) {
    final file = File(p.join(root, relative.replaceAll('/', p.separator)));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(contents);
  }

  String? read(String root, String relative) {
    final file = File(p.join(root, relative.replaceAll('/', p.separator)));
    return file.existsSync() ? file.readAsStringSync() : null;
  }

  /// A mod already in the library, with whatever origin block it carries.
  String library(String name, Map<String, String> files, {ModOrigin? origin}) {
    for (final entry in files.entries) {
      write(p.join(modsPath, name), entry.key, entry.value);
    }
    origins[name] = origin;
    return name;
  }

  /// A folder an import is about to create, still in its temp directory.
  String incoming(String name, Map<String, String> files) {
    final root = p.join(sources.path, name);
    Directory(root).createSync(recursive: true);
    for (final entry in files.entries) {
      write(root, entry.key, entry.value);
    }
    return root;
  }

  /// Stands in for the sidecar. Records the amendment each mod ends up with.
  Future<bool> amend(
    String modName,
    ModOrigin? Function(ModOrigin? current) update,
  ) async {
    origins[modName] = update(origins[modName]);
    return true;
  }

  const patchFromAPage = PatchIdentity(
    modId: 5100,
    fileId: 91000,
    version: '1.2',
    versionLabel: 'white hair ver',
    archiveMd5: 'abc123',
  );

  Future<PatchInstallDecision> decide({
    required List<String> folders,
    required Map<String, PatchDestination> answers,
  }) =>
      resolvePatchDestinations(
        scan: PlannedPatchScan(
          iniPatches: {for (final f in folders) p.basename(f)},
        ),
        destinations: answers,
        folders: folders,
        modsPath: modsPath,
      );

  /// Which library folder the prompt offers first.
  ///
  /// Composition over a real directory: the fingerprint comes out of the walk
  /// the patch verdict was reached on, the names out of the library on disk, and
  /// the author's requirement is matched against **recorded origins**. The
  /// ordering rule itself is `patch_destination_ranking_test.dart`.
  group('which folder a patch is offered', () {
    ModInfo mod(String name, {int? modId}) => ModInfo(
          id: name,
          name: name,
          characterId: 'ellen',
          isActive: false,
          origin: modId == null
              ? null
              : ModOrigin(
                  source: 'gamebanana',
                  modId: modId,
                  modIdConfidence: OriginConfidence.exact,
                  provenance: OriginProvenance.downloaded,
                ),
        );

    Future<List<DestinationRank>> rank(
      String patchFolder, {
      required List<ModInfo> library,
      List<GbRequirement> requirements = const <GbRequirement>[],
    }) async {
      final scan = await scanPlannedMods([
        PlannedMod(name: p.basename(patchFolder), sources: {patchFolder: ''}),
      ]);
      final ranked = await rankPatchDestinations(
        scan: scan,
        library: library,
        modsPath: modsPath,
        patchRequirements: requirements,
      );
      return ranked[p.basename(patchFolder)]!;
    }

    test('the folder holding the files the patch replaces comes first',
        () async {
      library('Ellen Bikini', {'ellen.ini': 'x', 'EllenHairADiffuse.dds': 'a'});
      library('Ellen School', {
        'ellen.ini': 'x',
        'Textures/EllenBodyADiffuse.dds': 'a',
        'EllenHairADiffuse.dds': 'a',
      });
      final patch = incoming('Ellen Fix', {
        'EllenBodyADiffuse.dds': 'new',
        'EllenHairADiffuse.dds': 'new',
      });

      final ranked = await rank(
        patch,
        library: [mod('Ellen Bikini'), mod('Ellen School')],
      );

      expect(ranked.first.modId, 'Ellen School');
      expect(ranked.first.matched, 2,
          reason: 'matched by name, wherever the folder keeps them');
      expect(ranked.last.matched, 1);
    });

    test('the mod the author linked leads, matching nothing at all', () async {
      library('Ellen School', {'ellen.ini': 'x', 'EllenBodyADiffuse.dds': 'a'});
      library('Ellen Bikini', {'ellen.ini': 'x'}, );
      final patch = incoming('Ellen Fix', {'EllenBodyADiffuse.dds': 'new'});

      final ranked = await rank(
        patch,
        library: [mod('Ellen School'), mod('Ellen Bikini', modId: 585282)],
        requirements: const [
          GbRequirement(
            label: 'Ellen Bikini',
            url: 'https://gamebanana.com/mods/585282',
          ),
        ],
      );

      expect(ranked.first.modId, 'Ellen Bikini');
      expect(ranked.first.requiredByAuthor, isTrue);
      expect(ranked.first.matched, 0);
    });

    test('an untracked folder can never answer for a requirement', () async {
      // Nothing on it says what it is, so nothing can match the author's link —
      // and it is still offered, like every other folder.
      library('Ellen School', {'ellen.ini': 'x', 'EllenBodyADiffuse.dds': 'a'});
      final patch = incoming('Ellen Fix', {'EllenBodyADiffuse.dds': 'new'});

      final ranked = await rank(
        patch,
        library: [mod('Ellen School')],
        requirements: const [
          GbRequirement(
            label: 'Some mod',
            url: 'https://gamebanana.com/mods/585282',
          ),
        ],
      );

      expect(ranked.single.requiredByAuthor, isFalse);
      expect(ranked.single.matched, 1);
    });

    test('a requirement that names no mod changes nothing', () async {
      library('Ellen School', {'ellen.ini': 'x', 'EllenBodyADiffuse.dds': 'a'});
      final patch = incoming('Ellen Fix', {'EllenBodyADiffuse.dds': 'new'});

      final ranked = await rank(
        patch,
        library: [mod('Ellen School', modId: 585282)],
        requirements: const [
          GbRequirement(
            label: 'XXMI',
            url: 'https://github.com/SpectrumQT/XXMI-Launcher',
          ),
        ],
      );

      expect(ranked.single.requiredByAuthor, isFalse);
    });

    test('a folder that is gone is offered with nothing said about it',
        () async {
      // The list must hold every folder the user can see, and a folder we could
      // not read is one we know nothing about rather than one to hide.
      final patch = incoming('Ellen Fix', {'EllenBodyADiffuse.dds': 'new'});

      final ranked = await rank(patch, library: [mod('Never Existed')]);

      expect(ranked.single.modId, 'Never Existed');
      expect(ranked.single.hasSignal, isFalse);
    });

    test('an empty library is not walked at all', () async {
      final patch = incoming('Ellen Fix', {'EllenBodyADiffuse.dds': 'new'});
      final scan = await scanPlannedMods([
        PlannedMod(name: 'Ellen Fix', sources: {patch: ''}),
      ]);

      final ranked = await rankPatchDestinations(
        scan: scan,
        library: const [],
        modsPath: modsPath,
      );

      expect(ranked, isEmpty);
    });
  });

  group('what the answers mean for the copy', () {
    test('a folder going into an existing mod is taken out of the import',
        () async {
      // Otherwise it lands twice: once written over the mod the user picked,
      // and once as a new mod folder of its own.
      library('Ellen', {'ellen.ini': 'x', 'Body.dds': 'v1'});
      final folder = incoming('Ellen Fix', {'Body.dds': 'v2'});

      final decision = await decide(
        folders: [folder],
        answers: {
          'Ellen Fix': const InstallIntoMod(modId: 'Ellen', modName: 'Ellen'),
        },
      );

      expect(decision.writes.keys, ['Ellen Fix']);
      expect(decision.excludes(folder), isTrue);
      expect(decision.refused, isEmpty);
    });

    test('a folder whose write is refused stays in the import', () async {
      // **Resolved before anything is removed**, so a target the placement
      // cannot settle still has a way back: the download becomes an ordinary
      // new mod rather than being lost.
      library('Ellen', {'ellen.ini': 'x', 'Body.dds': 'v1'});
      final folder = incoming('Some Other Fix', {'Totally Unrelated.dds': 'x'});

      final decision = await decide(
        folders: [folder],
        answers: {
          'Some Other Fix':
              const InstallIntoMod(modId: 'Ellen', modName: 'Ellen'),
        },
      );

      expect(decision.writes, isEmpty);
      expect(decision.excludes(folder), isFalse);
      expect(decision.refused[PatchRefusal.wrongMod], ['Ellen']);
    });

    test('a mod folder holding its own files twice is refused, not asked about',
        () async {
      // No install path creates that shape — the import picker settles
      // separate-or-combined before anything is copied — so the folder was
      // assembled by hand and is what needs sorting out.
      library('Ellen', {
        'sfw/Body.dds': 'v1',
        'nsfw/Body.dds': 'v1',
      });
      final folder = incoming('Ellen Fix', {'Body.dds': 'v2'});

      final decision = await decide(
        folders: [folder],
        answers: {
          'Ellen Fix': const InstallIntoMod(modId: 'Ellen', modName: 'Ellen'),
        },
      );

      expect(decision.refused[PatchRefusal.brokenMod], ['Ellen']);
      expect(decision.excludes(folder), isFalse);
    });

    test('a mod deleted between the question and the answer is refused',
        () async {
      final folder = incoming('Ellen Fix', {'Body.dds': 'v2'});

      final decision = await decide(
        folders: [folder],
        answers: {
          'Ellen Fix': const InstallIntoMod(modId: 'Gone', modName: 'Gone'),
        },
      );

      expect(decision.refused[PatchRefusal.goneMod], ['Gone']);
    });

    test('naming what a patch applies to keeps it in the import', () async {
      // The other destination: its own folder, plus an answer about which mod
      // it patches. Nothing is written over anything.
      final folder = incoming('Ellen Fix', {'fix.ini': 'x'});

      final decision = await decide(
        folders: [folder],
        answers: {
          'Ellen Fix': const InstallAsNewMod(
            base: ModCompanion(
              role: CompanionRole.base,
              modId: 7100,
              modIdConfidence: OriginConfidence.user,
            ),
            baseName: 'Ellen Swimsuit',
          ),
        },
      );

      expect(decision.writes, isEmpty);
      expect(decision.excludes(folder), isFalse);
      expect(decision.namedBases['Ellen Fix']!.modId, 7100);
    });
  });

  group('the writes, after the copy', () {
    test('the patch is written where the mod keeps its files', () async {
      // The mod keeps its textures in a subfolder and the patch ships at the
      // root. Written at the root it lands *beside* the mod instead of over
      // it — every reference still resolves to the original and nothing
      // changes in the game, with no error anywhere.
      library('Ellen', {'ellen.ini': 'x', 'Textures/Body.dds': 'v1'});
      final folder = incoming('Ellen Fix', {'Body.dds': 'v2'});
      final decision = await decide(
        folders: [folder],
        answers: {
          'Ellen Fix': const InstallIntoMod(modId: 'Ellen', modName: 'Ellen'),
        },
      );

      final lines = await applyPatchInstall(
        loc,
        decision: decision,
        importedMods: const [],
        modsPath: modsPath,
        applier: applier,
        amend: amend,
        patch: patchFromAPage,
      );

      expect(read(p.join(modsPath, 'Ellen'), 'Textures/Body.dds'), 'v2');
      expect(read(p.join(modsPath, 'Ellen'), 'Body.dds'), isNull,
          reason: 'the patch never adds a second copy beside the real one');
      expect(lines.map((l) => l.title), contains(loc.t('mods.snackbar.patch_applied_title')));
    });

    test('a mod page download is recorded against the mod it went into',
        () async {
      library('Ellen', {'ellen.ini': 'x', 'Body.dds': 'v1'},
          origin: const ModOrigin(
            provenance: OriginProvenance.downloaded,
            source: 'gamebanana',
            modId: 4001,
            modIdConfidence: OriginConfidence.exact,
          ));
      final folder = incoming('Ellen Fix', {'Body.dds': 'v2'});
      final decision = await decide(
        folders: [folder],
        answers: {
          'Ellen Fix': const InstallIntoMod(modId: 'Ellen', modName: 'Ellen'),
        },
      );

      await applyPatchInstall(
        loc,
        decision: decision,
        importedMods: const [],
        modsPath: modsPath,
        applier: applier,
        amend: amend,
        patch: patchFromAPage,
      );

      final origin = origins['Ellen']!;
      expect(origin.modId, 4001,
          reason: 'the folder is still the base mod — that is what its origin '
              'says and what it mostly is');
      expect(origin.ingest?.patchShaped ?? false, isFalse,
          reason: 'the mirror-image mistake: that flag says the folder *is* a '
              'patch missing its base, which is the opposite of this');
      expect(origin.needsCompanion, isFalse,
          reason: 'nothing about this folder is unanswered');
      final companion = origin.companionOfRole(CompanionRole.patch)!;
      expect(companion.modId, 5100);
      expect(companion.modIdConfidence, OriginConfidence.exact,
          reason: 'the one path to exact on a companion: we performed this '
              'download and know precisely what it was');
      expect(companion.version, '1.2');
      expect(companion.archiveMd5, 'abc123');
    });

    test('a folder dragged off a disk is installed with nothing recorded',
        () async {
      // It has no mod page, so there is no second identity to record — and a
      // companion must name one. The files still go in, the copy is still
      // saved first, and the mod keeps saying exactly what it said before.
      const was = ModOrigin(
        provenance: OriginProvenance.downloaded,
        source: 'gamebanana',
        modId: 4001,
        modIdConfidence: OriginConfidence.exact,
      );
      library('Ellen', {'ellen.ini': 'x', 'Body.dds': 'v1'}, origin: was);
      final folder = incoming('Ellen Fix', {'Body.dds': 'v2'});
      final decision = await decide(
        folders: [folder],
        answers: {
          'Ellen Fix': const InstallIntoMod(modId: 'Ellen', modName: 'Ellen'),
        },
      );

      final lines = await applyPatchInstall(
        loc,
        decision: decision,
        importedMods: const [],
        modsPath: modsPath,
        applier: applier,
        amend: amend,
      );

      expect(read(p.join(modsPath, 'Ellen'), 'Body.dds'), 'v2',
          reason: 'the install itself is the same operation either way');
      expect(origins['Ellen'], was,
          reason: 'no invented identity, and nothing quietly rewritten');
      expect(lines.map((l) => l.title),
          contains(loc.t('mods.snackbar.patch_applied_title')));
    });

    test('an untracked mod can still be patched', () async {
      // Most of a library that predates origin tracking has no block at all.
      library('Hand Copied', {'mod.ini': 'x', 'Body.dds': 'v1'});
      final folder = incoming('Fix', {'Body.dds': 'v2'});
      final decision = await decide(
        folders: [folder],
        answers: {
          'Fix': const InstallIntoMod(
              modId: 'Hand Copied', modName: 'Hand Copied'),
        },
      );

      await applyPatchInstall(
        loc,
        decision: decision,
        importedMods: const [],
        modsPath: modsPath,
        applier: applier,
        amend: amend,
        patch: patchFromAPage,
      );

      expect(read(p.join(modsPath, 'Hand Copied'), 'Body.dds'), 'v2');
      expect(origins['Hand Copied']!.companionOfRole(CompanionRole.patch),
          isNotNull,
          reason: 'a block is created for it — the patch is a fact about the '
              'folder whether or not the folder was tracked');
    });

    test('a new patch folder is marked, and the base named where it was given',
        () async {
      // The write that outlives the warning: a patch folder is legible exactly
      // once, before the user drags the base mod's files in around it.
      origins['Ellen Fix'] =
          const ModOrigin(provenance: OriginProvenance.importedFolder);
      origins['Some Patch'] =
          const ModOrigin(provenance: OriginProvenance.importedFolder);

      final decision = PatchInstallDecision(
        scan: const PlannedPatchScan(iniPatches: {'Ellen Fix', 'Some Patch'}),
        destinations: const {
          'Ellen Fix': InstallAsNewMod(
            base: ModCompanion(
              role: CompanionRole.base,
              modId: 7100,
              modIdConfidence: OriginConfidence.user,
            ),
            baseName: 'Ellen Swimsuit',
          ),
        },
      );

      await applyPatchInstall(
        loc,
        decision: decision,
        importedMods: const ['Ellen Fix', 'Some Patch'],
        modsPath: modsPath,
        applier: applier,
        amend: amend,
      );

      expect(origins['Ellen Fix']!.ingest!.patchShaped, isTrue);
      expect(origins['Ellen Fix']!.needsCompanion, isFalse,
          reason: 'they just said what it patches');
      expect(origins['Some Patch']!.ingest!.patchShaped, isTrue);
      expect(origins['Some Patch']!.needsCompanion, isTrue,
          reason: 'nobody said, so the question is still open');
    });

    test('the mark reaches the sidecar in a form the card reads', () async {
      // Through the **real** repository and read back off the filesystem, not
      // from the object that was written: the point of the mark is that it is
      // there for a scan weeks later, and a fake amender cannot show that.
      final repository = ModMetadataRepository(
        _FakeTagStore(),
        modsPath: () => modsPath,
        legacyImagesPath: () => p.join(tmp.path, 'legacy'),
      );
      write(p.join(modsPath, 'Ellen Fix'), 'fix.ini',
          '[TextureOverrideBody]\nps-t0 = R\n\n[R]\nfilename = Body.dds\n');
      await repository.recordOrigin(
        'Ellen Fix',
        const ModOrigin(
          provenance: OriginProvenance.downloaded,
          source: 'gamebanana',
          modId: 5100,
          modIdConfidence: OriginConfidence.exact,
          fileId: 91000,
          versionConfidence: OriginConfidence.exact,
        ),
      );

      await applyPatchInstall(
        loc,
        decision: const PatchInstallDecision(
          scan: PlannedPatchScan(iniPatches: {'Ellen Fix'}),
        ),
        importedMods: const ['Ellen Fix'],
        modsPath: modsPath,
        applier: applier,
        amend: repository.updateOrigin,
      );

      final sidecar =
          await ModMetadataService().read(p.join(modsPath, 'Ellen Fix'));
      final origin = sidecar!.origin!;
      expect(origin.ingest!.patchShaped, isTrue);
      expect(origin.needsCompanion, isTrue);
      expect(modOriginStatus(origin), ModOriginStatus.secondIdentityUnknown,
          reason: 'the amber mark on the card, and its own sentence');
      expect(modNeedsAttention(origin), isTrue,
          reason: 'and it is counted, because naming the base clears it');
    });

    /// **Naming the base is an instruction to install it**, not a note about it.
    /// A folder holding only a patch does nothing in the game, so recording the
    /// answer and stopping there left the user exactly where they started.
    group('the base the user named', () {
      const base = ModCompanion(
        role: CompanionRole.base,
        modId: 7100,
        modIdConfidence: OriginConfidence.user,
      );
      final file = GbFile.fromJson(const {
        '_idRow': 91000,
        '_sFile': 'ellen_swimsuit.zip',
      });

      PatchInstallDecision decisionFor(PatchDestination destination) =>
          PatchInstallDecision(
            scan: const PlannedPatchScan(iniPatches: {'Ellen Fix'}),
            destinations: {'Ellen Fix': destination},
          );

      test('it is fetched and written into that patch\'s folder', () async {
        origins['Ellen Fix'] =
            const ModOrigin(provenance: OriginProvenance.importedFolder);
        final asked = <String>[];

        final lines = await applyPatchInstall(
          loc,
          decision: decisionFor(
            InstallAsNewMod(base: base, baseName: 'Ellen', baseFile: file),
          ),
          importedMods: const ['Ellen Fix'],
          modsPath: modsPath,
          applier: applier,
          amend: amend,
          installBase: (modName, named, chosen) async {
            asked.add('$modName:${named.modId}:${chosen.idRow}');
            return true;
          },
        );

        expect(asked, ['Ellen Fix:7100:91000']);
        expect(lines, isEmpty,
            reason: 'the folder works now, so there is nothing to warn about');
      });

      test('the answer is recorded before the download starts', () async {
        // A cancelled or failed fetch has to leave the answer the user gave.
        // Written afterwards, it would be lost with the download.
        origins['Ellen Fix'] =
            const ModOrigin(provenance: OriginProvenance.importedFolder);

        final lines = await applyPatchInstall(
          loc,
          decision: decisionFor(
            InstallAsNewMod(base: base, baseName: 'Ellen', baseFile: file),
          ),
          importedMods: const ['Ellen Fix'],
          modsPath: modsPath,
          applier: applier,
          amend: amend,
          installBase: (modName, named, chosen) async => false,
        );

        expect(origins['Ellen Fix']!.companionOfRole(CompanionRole.base), base,
            reason: 'they said what it patches, and that stands');
        expect(origins['Ellen Fix']!.ingest!.patchShaped, isTrue);
        expect(lines.single.title, loc.t('mods.snackbar.import_patch_title'),
            reason: 'and the folder still does not work, so it still says so');
      });

      test('an answer with no file to install fetches nothing', () async {
        // "I don't know which file" names the mod and stops there — there is
        // nothing to install, and the newest is a guess this must not make.
        origins['Ellen Fix'] =
            const ModOrigin(provenance: OriginProvenance.importedFolder);
        var called = false;

        await applyPatchInstall(
          loc,
          decision: decisionFor(
            const InstallAsNewMod(base: base, baseName: 'Ellen'),
          ),
          importedMods: const ['Ellen Fix'],
          modsPath: modsPath,
          applier: applier,
          amend: amend,
          installBase: (modName, named, chosen) async {
            called = true;
            return true;
          },
        );

        expect(called, isFalse);
        expect(origins['Ellen Fix']!.companionOfRole(CompanionRole.base), base);
      });

      test('a mod the import never created is not fetched for', () async {
        var called = false;

        await applyPatchInstall(
          loc,
          decision: decisionFor(
            InstallAsNewMod(base: base, baseName: 'Ellen', baseFile: file),
          ),
          importedMods: const [],
          modsPath: modsPath,
          applier: applier,
          amend: amend,
          installBase: (modName, named, chosen) async {
            called = true;
            return true;
          },
        );

        expect(called, isFalse);
      });
    });

    test('nothing is said or written about a mod the import did not create',
        () async {
      // A folder that already existed is skipped rather than replaced, so it
      // is not there to be marked — and a warning naming it would point at
      // somebody else's mod.
      origins['Ellen Fix'] =
          const ModOrigin(provenance: OriginProvenance.importedFolder);

      final lines = await applyPatchInstall(
        loc,
        decision: const PatchInstallDecision(
          scan: PlannedPatchScan(iniPatches: {'Ellen Fix'}),
        ),
        importedMods: const [],
        modsPath: modsPath,
        applier: applier,
        amend: amend,
      );

      expect(origins['Ellen Fix']!.ingest?.patchShaped ?? false, isFalse);
      expect(lines, isEmpty);
    });
  });

  group('what the user is told', () {
    List<NotificationLines> linesFor(PatchInstallDecision decision,
            {List<String> imported = const []}) =>
        patchInstallLines(loc,
            decision: decision, importedMods: imported, patchedInto: const {},
            writeFailures: const []);

    test('a patch nobody answered for is pinned', () async {
      // The mod does not work until the user puts the mod it patches in with
      // it, and eight seconds is not long enough to find that out.
      final lines = linesFor(
        const PatchInstallDecision(
          scan: PlannedPatchScan(iniPatches: {'Ellen Fix'}),
        ),
        imported: ['Ellen Fix'],
      );

      expect(lines.single.title, loc.t('mods.snackbar.import_patch_title'));
      expect(lines.single.body, contains('Ellen Fix'));
      expect(lines.single.pinned, isTrue);
    });

    test('naming the base is not the same as having it', () async {
      // **The warning is silenced by a folder that works, not by an answer about
      // it.** Naming the base used to suppress this on its own — and the folder
      // still did nothing in the game, with the one sentence that would have
      // said so now gone.
      final lines = linesFor(
        const PatchInstallDecision(
          scan: PlannedPatchScan(iniPatches: {'Ellen Fix'}),
          destinations: {
            'Ellen Fix': InstallAsNewMod(
              base: ModCompanion(
                role: CompanionRole.base,
                modId: 7100,
                modIdConfidence: OriginConfidence.user,
              ),
            ),
          },
        ),
        imported: ['Ellen Fix'],
      );

      expect(lines.single.title, loc.t('mods.snackbar.import_patch_title'),
          reason: 'nothing was installed, so there is as much left to do as '
              'if they had said nothing');
    });

    test('a base that was actually installed says nothing', () async {
      // The folder holds both downloads now. There is nothing to act on, and a
      // pinned card saying otherwise is wrong rather than merely noisy.
      final lines = patchInstallLines(
        loc,
        decision: const PatchInstallDecision(
          scan: PlannedPatchScan(iniPatches: {'Ellen Fix'}),
        ),
        importedMods: const ['Ellen Fix'],
        patchedInto: const {},
        writeFailures: const [],
        completed: const {'Ellen Fix'},
      );

      expect(lines, isEmpty);
    });

    test('an asset patch whose base arrived says nothing either', () async {
      final lines = patchInstallLines(
        loc,
        decision: const PatchInstallDecision(
          scan: PlannedPatchScan(
            assetPatches: {'Retexture': AssetPatchAssessment(assets: 1)},
          ),
        ),
        importedMods: const ['Retexture'],
        patchedInto: const {},
        writeFailures: const [],
        completed: const {'Retexture'},
      );

      expect(lines, isEmpty);
    });

    test('an asset-only patch is named separately and pinned too', () async {
      // Different evidence: this download brought content nothing can load,
      // rather than asking for content it did not bring.
      final lines = linesFor(
        const PatchInstallDecision(
          scan: PlannedPatchScan(
            assetPatches: {'Retexture': AssetPatchAssessment(assets: 1)},
          ),
        ),
        imported: ['Retexture'],
      );

      expect(
          lines.single.title, loc.t('mods.snackbar.import_asset_patch_title'));
      expect(lines.single.pinned, isTrue);
    });

    test('a folder that is simply not a mod is not pinned', () async {
      // "May be incomplete" describes a `previews` folder installed on its
      // own. There is nothing for the user to finish, so it can time out.
      final lines = linesFor(
        const PatchInstallDecision(
          scan: PlannedPatchScan(incomplete: {'previews'}),
        ),
        imported: ['previews'],
      );

      expect(lines.single.title, loc.t('mods.snackbar.import_no_ini_title'));
      expect(lines.single.pinned, isFalse);
    });

    test('each refusal says which of the two it was', () async {
      // They ask different things of the user: one is "you picked the wrong
      // mod", the other is "that mod's folder needs sorting out".
      final wrong = patchInstallLines(loc,
          decision: const PatchInstallDecision(
            scan: PlannedPatchScan(),
            refused: {PatchRefusal.wrongMod: ['Ellen']},
          ),
          importedMods: const ['Ellen Fix'],
          patchedInto: const {},
          writeFailures: const []);
      final broken = patchInstallLines(loc,
          decision: const PatchInstallDecision(
            scan: PlannedPatchScan(),
            refused: {PatchRefusal.brokenMod: ['Ellen']},
          ),
          importedMods: const ['Ellen Fix'],
          patchedInto: const {},
          writeFailures: const []);

      expect(wrong.single.title, loc.t('mods.snackbar.patch_wrong_mod_title'));
      expect(broken.single.title, loc.t('mods.snackbar.patch_broken_mod_title'));
      expect(wrong.single.title, isNot(broken.single.title));
      expect(wrong.single.pinned, isTrue);
      expect(broken.single.pinned, isTrue);
    });

    test('a change with no card to look at reports its success', () async {
      // The patch went into somebody else's folder, so there is no new mod to
      // see — and the one thing they need to know is that a copy was saved.
      final lines = patchInstallLines(loc,
          decision: const PatchInstallDecision(scan: PlannedPatchScan()),
          importedMods: const [],
          patchedInto: const {
            'Ellen Fix': InstallIntoMod(modId: 'Ellen', modName: 'Ellen'),
          },
          writeFailures: const []);

      expect(lines.single.title, loc.t('mods.snackbar.patch_applied_title'));
      expect(lines.single.body, contains('Ellen'));
      expect(lines.single.pinned, isFalse);
    });

    test('a write that failed is pinned', () async {
      final lines = patchInstallLines(loc,
          decision: const PatchInstallDecision(scan: PlannedPatchScan()),
          importedMods: const [],
          patchedInto: const {},
          writeFailures: const ['Ellen']);

      expect(
          lines.single.title, loc.t('mods.snackbar.patch_write_failed_title'));
      expect(lines.single.pinned, isTrue);
    });
  });
}
