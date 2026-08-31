import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/mod_companion.dart';
import 'package:mod_manager_flutter/models/mod_ingest.dart';
import 'package:mod_manager_flutter/models/mod_metadata.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';

void main() {
  group('confidence parsing fails safe', () {
    test('an unrecognised tier degrades to unknown, never to exact', () {
      // Load-bearing, not defensive style. A future build inventing a stronger
      // tier must never be read by this build as a claim it can act on: `exact`
      // is the one tier permitted to overwrite a user's files unattended.
      expect(OriginConfidence.parse('attested'), OriginConfidence.unknown);
      expect(OriginConfidence.parse('verified'), OriginConfidence.unknown);
      expect(OriginConfidence.parse('EXACT'), OriginConfidence.unknown,
          reason: 'the wire form is lowercase; anything else is not a match');
      expect(OriginConfidence.parse(null), OriginConfidence.unknown);
      expect(OriginConfidence.parse(42), OriginConfidence.unknown);
      expect(OriginConfidence.parse({'a': 1}), OriginConfidence.unknown);
    });

    test('known tiers round-trip', () {
      for (final tier in OriginConfidence.values) {
        expect(OriginConfidence.parse(tier.wire), tier);
      }
    });

    test('only exact permits an unattended overwrite', () {
      for (final tier in OriginConfidence.values) {
        expect(
          tier.allowsUnattendedUpdate,
          tier == OriginConfidence.exact,
          reason: 'tier ${tier.wire}',
        );
      }
    });
  });

  group('provenance parsing', () {
    test('defaults to the least-privileged source', () {
      expect(OriginProvenance.parse('something_new'),
          OriginProvenance.importedFolder);
      expect(OriginProvenance.parse(null), OriginProvenance.importedFolder);
    });

    test('known values round-trip', () {
      for (final source in OriginProvenance.values) {
        expect(OriginProvenance.parse(source.wire), source);
      }
    });
  });

  group('serialisation', () {
    test('round-trips every field', () {
      final origin = ModOrigin(
        source: 'gamebanana',
        modId: 531649,
        modIdConfidence: OriginConfidence.exact,
        fileId: 1491924,
        version: '7.7',
        versionLabel: 'Full Mod',
        versionConfidence: OriginConfidence.user,
        provenance: OriginProvenance.downloaded,
        ingest: const ModIngest(
          mode: IngestMode.combined,
          folders: ['Mod', 'Dependency'],
          siblingGroup: 'abc123',
        ),
        installedAt: DateTime.utc(2026, 8, 1, 12),
        installedAtIsProxy: true,
        baselineRemoteDate: DateTime.utc(2026, 7, 1),
        archiveMd5: '9e107d9d372bb6826bd81d3542a419d6',
        tracking: OriginTracking.off,
        remoteMissing: true,
      );

      final back = ModOrigin.fromJson(origin.toJson())!;

      expect(back.source, 'gamebanana');
      expect(back.modId, 531649);
      expect(back.modIdConfidence, OriginConfidence.exact);
      expect(back.fileId, 1491924);
      expect(back.version, '7.7');
      expect(back.versionLabel, 'Full Mod');
      expect(back.versionConfidence, OriginConfidence.user);
      expect(back.provenance, OriginProvenance.downloaded);
      expect(back.ingest!.mode, IngestMode.combined);
      expect(back.ingest!.folders, ['Mod', 'Dependency']);
      expect(back.ingest!.siblingGroup, 'abc123');
      expect(back.installedAt, DateTime.utc(2026, 8, 1, 12));
      expect(back.installedAtIsProxy, isTrue);
      expect(back.baselineRemoteDate, DateTime.utc(2026, 7, 1));
      expect(back.archiveMd5, '9e107d9d372bb6826bd81d3542a419d6');
      expect(back.tracking, OriginTracking.off);
      expect(back.remoteMissing, isTrue);
    });

    test('omits everything that equals its read-side default', () {
      // Absence already means "default" on read, so writing
      // "remote_missing": false into every sidecar adds noise to a file users
      // can open without adding information.
      final json = const ModOrigin(
        provenance: OriginProvenance.importedFolder,
      ).toJson();

      expect(json, {'provenance': 'imported_folder'});
      expect(json.containsKey('version_confidence'), isFalse);
      expect(json.containsKey('remote_missing'), isFalse);
      expect(json.containsKey('tracking'), isFalse);
      expect(json.containsKey('installed_at_is_proxy'), isFalse);
    });

    test('version and version_label stay distinct', () {
      // Conflating them would make two variants of one release look like two
      // different releases.
      final json = const ModOrigin(
        provenance: OriginProvenance.downloaded,
        version: '1.0',
        versionLabel: 'white hair ver',
      ).toJson();
      expect(json['version'], '1.0');
      expect(json['version_label'], 'white hair ver');
    });

    test('dates are stored as ISO-8601 UTC', () {
      final json = ModOrigin(
        provenance: OriginProvenance.downloaded,
        installedAt: DateTime.utc(2026, 8, 1, 12, 30),
      ).toJson();
      expect(json['installed_at'], '2026-08-01T12:30:00.000Z');
    });
  });

  group('fromJson never throws', () {
    // A sidecar travels with its mod folder, so one can arrive from a stranger
    // carrying anything at all. A cast that threw here would propagate into
    // ModMetadataService.read, which catches and returns null — and because
    // that method cannot tell "missing" from "corrupt", the sidecar would be
    // replaced wholesale on the next save, destroying the user's own
    // description, tags and images.
    test('for a non-object', () {
      expect(ModOrigin.fromJson('hello'), isNull);
      expect(ModOrigin.fromJson(42), isNull);
      expect(ModOrigin.fromJson(<String>['a']), isNull);
      expect(ModOrigin.fromJson(null), isNull);
    });

    test('for wrongly-typed scalars', () {
      final origin = ModOrigin.fromJson({
        'provenance': 'downloaded',
        'mod_id': <String, dynamic>{'nested': true},
        'file_id': true,
        'version': 42,
        'archive_md5': <String>[],
        'installed_at': 'not a date',
        'ingest': 'not an object',
      })!;

      expect(origin.provenance, OriginProvenance.downloaded);
      expect(origin.modId, isNull);
      expect(origin.fileId, isNull);
      expect(origin.version, isNull);
      expect(origin.archiveMd5, isNull);
      expect(origin.installedAt, isNull);
      expect(origin.ingest, isNull);
    });

    test('a stringly-typed id is tolerated rather than rejected', () {
      expect(ModOrigin.fromJson({'mod_id': '123'})!.modId, 123);
      expect(ModOrigin.fromJson({'mod_id': 'abc'})!.modId, isNull);
    });

    test('and the surrounding user data survives it', () {
      // The whole point: a garbage origin block must cost the user nothing.
      final meta = ModMetadata.fromJson({
        'schema_version': 1,
        'description': 'my notes',
        'tags': ['keep', 'these'],
        'origin': {'mod_id': 'not-an-int', 'provenance': 'nonsense'},
      });

      expect(meta.description, 'my notes');
      expect(meta.tags, ['keep', 'these']);
      expect(meta.origin, isNotNull);
      expect(meta.origin!.modId, isNull);
      expect(meta.origin!.provenance, OriginProvenance.importedFolder);
    });
  });

  group('ingest', () {
    test('a missing folders list is empty, not null', () {
      expect(ModIngest.fromJson({'mode': 'separate'})!.folders, isEmpty);
    });

    test('drops non-string folder entries', () {
      final ingest = ModIngest.fromJson({
        'mode': 'separate',
        'folders': ['Good', 42, null, '', 'Also good'],
      })!;
      expect(ingest.folders, ['Good', 'Also good']);
    });

    test('an empty ingest emits nothing but the mode', () {
      expect(const ModIngest().toJson(), {'mode': 'separate'});
      expect(const ModIngest().isEmpty, isTrue);
    });

    group('patch_shaped', () {
      // Knowable only at install — after the base mod's files are dragged in
      // around a patch, the folder is indistinguishable from an ordinary one.
      // So it has to survive the sidecar, or it is worth nothing.
      test('round-trips', () {
        const ingest = ModIngest(patchShaped: true);
        expect(ingest.toJson()['patch_shaped'], true);
        expect(ModIngest.fromJson(ingest.toJson())!.patchShaped, isTrue);
      });

      test('is absent from the json when false', () {
        // Every sidecar in existence lacks the key, and writing `false` into
        // all of them would be churn saying nothing.
        expect(const ModIngest().toJson().containsKey('patch_shaped'), isFalse);
        expect(ModIngest.fromJson({'mode': 'separate'})!.patchShaped, isFalse);
      });

      test('anything but true reads as false', () {
        for (final raw in [null, 'true', 1, 'yes']) {
          expect(
            ModIngest.fromJson({'mode': 'separate', 'patch_shaped': raw})!
                .patchShaped,
            isFalse,
            reason: '$raw',
          );
        }
      });

      test('is part of the value identity', () {
        // `ModOrigin` compares by value and the rescan guard depends on it, so
        // a flag it ignored would leave the card showing the old verdict.
        expect(const ModIngest(patchShaped: true),
            isNot(const ModIngest()));
        expect(const ModIngest(patchShaped: true).isEmpty, isFalse);
      });
    });

    /// **Which files in this folder came from the patch.**
    ///
    /// The one thing that makes a mixed folder rebuildable: to write a newer
    /// base into it and keep the patch, the app has to know which files are the
    /// patch's — and it cannot be derived afterwards, because a mixed folder
    /// looks exactly like an ordinary one. Recorded rather than re-downloaded so
    /// that a patch whose mod page has since gone does not take the folder with
    /// it.
    group('patch_files', () {
      test('round-trips', () {
        const ingest = ModIngest(patchFiles: ['Textures/Body.dds', 'fix.ini']);
        expect(ingest.toJson()['patch_files'], ['Textures/Body.dds', 'fix.ini']);
        expect(ModIngest.fromJson(ingest.toJson())!.patchFiles,
            ['Textures/Body.dds', 'fix.ini']);
      });

      test('keeps the spelling it was given', () {
        // On-disk spelling, because these paths open files. Lower-casing them
        // here would delete nothing on Linux and leave a second copy behind.
        const ingest = ModIngest(patchFiles: ['Textures/BodyA.dds']);
        expect(ModIngest.fromJson(ingest.toJson())!.patchFiles,
            ['Textures/BodyA.dds']);
      });

      test('is absent from the json when empty', () {
        expect(const ModIngest().toJson().containsKey('patch_files'), isFalse);
        expect(ModIngest.fromJson({'mode': 'separate'})!.patchFiles, isEmpty);
      });

      test('drops entries that are not usable paths', () {
        final ingest = ModIngest.fromJson({
          'mode': 'separate',
          'patch_files': ['Body.dds', 42, null, '', 'fix.ini'],
        })!;
        expect(ingest.patchFiles, ['Body.dds', 'fix.ini']);
      });

      test('anything but a list reads as empty', () {
        for (final raw in ['Body.dds', 42, true, <String, String>{}]) {
          expect(
            ModIngest.fromJson({'mode': 'separate', 'patch_files': raw})!
                .patchFiles,
            isEmpty,
            reason: '$raw',
          );
        }
      });

      test('is part of the value identity', () {
        expect(const ModIngest(patchFiles: ['a.dds']), isNot(const ModIngest()));
        expect(const ModIngest(patchFiles: ['a.dds']),
            isNot(const ModIngest(patchFiles: ['b.dds'])));
        expect(const ModIngest(patchFiles: ['a.dds']).isEmpty, isFalse);
      });

      test('survives an amendment that says nothing about it', () {
        // Every write to `ingest` rebuilds it, so a field left out of one is a
        // field erased by it — and this one cannot be recovered afterwards.
        const ingest = ModIngest(patchFiles: ['Body.dds']);
        expect(ingest.copyWith(patchShaped: true).patchFiles, ['Body.dds']);
      });
    });
  });

  group('companions', () {
    const base = ModCompanion(
      role: CompanionRole.base,
      modId: 111,
      modIdConfidence: OriginConfidence.user,
    );

    ModOrigin withCompanions(
      List<ModCompanion> companions, {
      int? modId = 222,
      bool patchShaped = false,
    }) =>
        ModOrigin(
          source: 'gamebanana',
          modId: modId,
          modIdConfidence: OriginConfidence.exact,
          provenance: OriginProvenance.downloaded,
          ingest: patchShaped ? const ModIngest(patchShaped: true) : null,
          companions: companions,
        );

    test('round-trip through the origin block', () {
      final back = ModOrigin.fromJson(withCompanions([base]).toJson())!;
      expect(back.companions, [base]);
    });

    test('an empty list is absent from the json', () {
      // Every sidecar in existence lacks the key. Writing "companions": []
      // into all of them is churn saying nothing.
      expect(
        withCompanions(const []).toJson().containsKey('companions'),
        isFalse,
      );
    });

    test('a companions value that is not a list is ignored', () {
      // Machine-owned garbage is dropped rather than round-tripped, and the
      // rest of the block must survive it — the same rule the whole sidecar
      // rests on.
      final origin = ModOrigin.fromJson({
        'provenance': 'downloaded',
        'mod_id': 222,
        'companions': 'the other one',
      })!;
      expect(origin.modId, 222);
      expect(origin.companions, isEmpty);
    });

    test('unusable entries are dropped and the usable ones survive', () {
      final origin = ModOrigin.fromJson({
        'provenance': 'downloaded',
        'mod_id': 222,
        'companions': [
          'not an object',
          {'role': 'base'}, // no id
          {'mod_id': 111}, // no role
          {'role': 'base', 'mod_id': 111},
          42,
        ],
      })!;
      expect(origin.companions.length, 1);
      expect(origin.companions.single.modId, 111);
    });

    test('a companion naming the primary is dropped', () {
      // Not a second thing in the folder — the same thing said twice. Keeping
      // it would make the check ask one page twice and report two verdicts for
      // one mod.
      final origin = ModOrigin.fromJson({
        'provenance': 'downloaded',
        'mod_id': 222,
        'companions': [
          {'role': 'base', 'mod_id': 222},
          {'role': 'base', 'mod_id': 111},
        ],
      })!;
      expect(origin.companions.map((c) => c.modId), [111]);
    });

    test('a repeated companion id keeps the first entry only', () {
      final origin = ModOrigin.fromJson({
        'provenance': 'downloaded',
        'mod_id': 222,
        'companions': [
          {'role': 'base', 'mod_id': 111, 'version': 'first'},
          {'role': 'patch', 'mod_id': 111, 'version': 'second'},
        ],
      })!;
      expect(origin.companions.length, 1);
      expect(origin.companions.single.version, 'first');
    });

    test('is part of the value identity, order-independently', () {
      // Part of it, because the rescan guard compares the whole block and a
      // companion added through the resolve dialog must reach the card.
      expect(withCompanions([base]), isNot(withCompanions(const [])));

      // Order-independently, because the list is a set of identities and
      // rewriting it in a different order is not a change the user can see.
      const other = ModCompanion(role: CompanionRole.patch, modId: 333);
      expect(withCompanions([base, other]), withCompanions([other, base]));
      expect(
        withCompanions([base, other]).hashCode,
        withCompanions([other, base]).hashCode,
      );
    });

    group('needsCompanion', () {
      test('a patch-shaped folder with no base named needs one', () {
        expect(withCompanions(const [], patchShaped: true).needsCompanion,
            isTrue);
      });

      test('naming the base answers it', () {
        expect(
          withCompanions([base], patchShaped: true).needsCompanion,
          isFalse,
        );
      });

      test('a companion in the other role does not answer it', () {
        // A folder recorded as holding a patch needs to know what that patch
        // applies to. Another patch is not that.
        expect(
          withCompanions(
            const [ModCompanion(role: CompanionRole.patch, modId: 333)],
            patchShaped: true,
          ).needsCompanion,
          isTrue,
        );
      });

      test('an ordinary folder never needs one', () {
        expect(withCompanions(const []).needsCompanion, isFalse);
        expect(withCompanions([base]).needsCompanion, isFalse);
      });
    });

    group('what survives a rewrite of the primary', () {
      test('boundTo keeps them — the folder\'s contents did not change', () {
        // Rebinding changes what we believe about the *primary*. A companion
        // is still a true statement about what else is in the folder.
        final rebound = withCompanions([base]).boundTo(
          modId: 333,
          confidence: OriginConfidence.user,
          source: 'gamebanana',
        );
        expect(rebound.companions, [base]);
      });

      test('boundTo onto a companion\'s own id collapses the two', () {
        // Otherwise the folder claims mod 111 twice, once in each role.
        final rebound = withCompanions([base]).boundTo(
          modId: 111,
          confidence: OriginConfidence.user,
          source: 'gamebanana',
        );
        expect(rebound.modId, 111);
        expect(rebound.companions, isEmpty);
      });

      test('updatedTo keeps them', () {
        // An update overwrites and touches nothing else, so the companion's
        // files are still there. They may now be inert — the update can
        // replace a patch's .ini — but "installed and possibly not applied"
        // is not "not installed", and the entry is the only record of what
        // the snapshot holds.
        final updated = withCompanions([base]).updatedTo(
          source: 'gamebanana',
          modId: 222,
          fileId: 9,
          installedAt: DateTime.utc(2026, 8, 30),
        );
        expect(updated.companions, [base]);
      });

      test('withUpdatesUndismissed keeps them', () {
        expect(withCompanions([base]).withUpdatesUndismissed().companions,
            [base]);
      });

      test('copyWith keeps them when not asked to change them', () {
        expect(withCompanions([base]).copyWith(version: '2').companions,
            [base]);
      });
    });

    group('withDismissal', () {
      final until = DateTime.utc(2026, 5, 5);

      test('a null subject means the folder\'s own releases', () {
        final block = withCompanions([base])
            .withDismissal(subject: null, until: until);
        expect(block.updatesDismissedUntil, until);
        expect(block.companions.single.updatesDismissedUntil, isNull);
      });

      test('a subject means that companion\'s, and only its', () {
        // The failure this exists to prevent: written onto the primary, a
        // companion's dismissal silences nothing — the check reads the
        // companion's own field — while stamping another mod's release date
        // onto this block, where it can silence a real finding.
        final block = withCompanions([base])
            .withDismissal(subject: 111, until: until);
        expect(block.updatesDismissedUntil, isNull);
        expect(block.companions.single.updatesDismissedUntil, until);
      });

      test('a null until lifts it from the same identity', () {
        final dismissed = withCompanions([base])
            .withDismissal(subject: 111, until: until);
        final lifted = dismissed.withDismissal(subject: 111, until: null);
        expect(lifted.companions.single.updatesDismissedUntil, isNull);
      });

      test('a subject this block no longer carries writes nothing', () {
        // The verdict was computed against a block that has since moved on —
        // the companion was renamed or removed. Falling back to the primary
        // would dismiss the wrong mod's releases.
        final block = withCompanions([base])
            .withDismissal(subject: 999, until: until);
        expect(block.updatesDismissedUntil, isNull);
        expect(block.companions, [base]);
      });
    });
  });

  group('allowsUnattendedUpdate', () {
    ModOrigin build({
      OriginConfidence modId = OriginConfidence.exact,
      OriginConfidence version = OriginConfidence.exact,
      OriginTracking tracking = OriginTracking.auto,
      bool remoteMissing = false,
    }) =>
        ModOrigin(
          provenance: OriginProvenance.downloaded,
          modIdConfidence: modId,
          versionConfidence: version,
          tracking: tracking,
          remoteMissing: remoteMissing,
        );

    test('needs BOTH axes exact', () {
      expect(build().allowsUnattendedUpdate, isTrue);
      // Knowing the mod but not which file is not enough to know what to
      // replace it with.
      expect(build(version: OriginConfidence.inferred).allowsUnattendedUpdate,
          isFalse);
      expect(build(modId: OriginConfidence.user).allowsUnattendedUpdate, isFalse);
    });

    test('is off when the user declared the mod local', () {
      expect(build(tracking: OriginTracking.off).allowsUnattendedUpdate, isFalse);
    });

    test('is off when the mod is gone upstream', () {
      expect(build(remoteMissing: true).allowsUnattendedUpdate, isFalse);
    });

    test('a hand-imported archive can still qualify', () {
      // Provenance is not the gate — confidence is. A checksum match and our
      // own download are the same epistemic state.
      const origin = ModOrigin(
        provenance: OriginProvenance.importedArchive,
        modIdConfidence: OriginConfidence.exact,
        versionConfidence: OriginConfidence.exact,
      );
      expect(origin.allowsUnattendedUpdate, isTrue);
      expect(origin.provenance.isOurDownload, isFalse);
    });
  });
}
