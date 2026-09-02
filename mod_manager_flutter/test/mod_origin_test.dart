import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/installed_file.dart';
import 'package:mod_manager_flutter/models/mod_download.dart';
import 'package:mod_manager_flutter/models/mod_ingest.dart';
import 'package:mod_manager_flutter/models/mod_metadata.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';

/// **The sidecar's machine-owned half, and the shape of a mod folder.**
///
/// A folder is a stack of downloads written bottom-up. Most of what this file
/// pins is defensive: a sidecar travels with its mod folder, so one can arrive
/// from a stranger carrying anything at all — and a parse that threw here would
/// have the file treated as absent and **replaced wholesale on the next save**,
/// destroying the user's own description, tags and images.
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

  /// **Position is the truth; the tag is a check on it.**
  group('the role tag', () {
    test('is written from the position, whatever it was given', () {
      // A caller cannot put a `base` above the bottom by asking for one: the
      // write that places a layer sets the role, and every path that reorders
      // re-derives it.
      final origin = ModOrigin(
        provenance: OriginProvenance.downloaded,
        downloads: const [
          ModDownload(modId: 1),
          // Deliberately mislabelled.
          ModDownload(role: DownloadRole.base, modId: 2),
        ],
      ).withLayerOnTop(const ModDownload(modId: 3));

      expect(origin.downloads.map((d) => d.role),
          [DownloadRole.base, DownloadRole.patch, DownloadRole.patch]);
    });

    test('a stored tag that disagrees with its index loses', () {
      // The reason it is stored at all: a sidecar is a file people open and
      // share, and a hand edit that reordered the list would otherwise change
      // what every entry means in silence. The mismatch is logged, not obeyed.
      final origin = ModOrigin.fromJson({
        'provenance': 'downloaded',
        'downloads': [
          {'role': 'patch', 'mod_id': 1},
          {'role': 'base', 'mod_id': 2},
        ],
      })!;

      expect(origin.downloads.map((d) => d.role),
          [DownloadRole.base, DownloadRole.patch]);
      expect(origin.base!.modId, 1);
    });

    test('an unrecognised tag is not obeyed either', () {
      final origin = ModOrigin.fromJson({
        'provenance': 'downloaded',
        'downloads': [
          {'role': 'sideways', 'mod_id': 1},
        ],
      })!;

      expect(origin.base!.role, DownloadRole.base);
    });

    test('round-trips for a stack written by this build', () {
      final origin = ModOrigin(
        provenance: OriginProvenance.downloaded,
        downloads: const [
          ModDownload(modId: 1),
          ModDownload(role: DownloadRole.patch, modId: 2),
        ],
      );

      expect(ModOrigin.fromJson(origin.toJson()), origin);
    });
  });

  group('serialisation', () {
    final full = ModOrigin(
      source: 'gamebanana',
      provenance: OriginProvenance.downloaded,
      ingest: const ModIngest(
        mode: IngestMode.combined,
        folders: ['Mod', 'Dependency'],
        siblingGroup: 'abc123',
        patchShaped: true,
        patchFiles: ['Body.dds'],
      ),
      installedAt: DateTime.utc(2026, 8, 9, 12, 30),
      installedAtIsProxy: true,
      tracking: OriginTracking.off,
      downloads: const [
        ModDownload(
          modId: 700727,
          modIdConfidence: OriginConfidence.user,
          fileId: 1428172,
          version: '3.0',
          versionLabel: 'white hair ver',
          versionConfidence: OriginConfidence.exact,
          archiveMd5: '9e107d9d372bb6826bd81d3542a419d6',
          baselineRemoteDate: null,
          remoteMissing: true,
          updatesDismissedUntil: null,
          files: [InstalledFile(path: 'Ellen.ini', bytes: 12)],
        ),
        ModDownload(
          role: DownloadRole.patch,
          modId: 605460,
          modIdConfidence: OriginConfidence.exact,
          fileId: 1473174,
          versionConfidence: OriginConfidence.exact,
          baselineRemoteDate: null,
          files: [
            InstalledFile(path: 'Body.dds', role: InstalledFileRole.replaced),
          ],
        ),
      ],
    );

    test('round-trips every field', () {
      // Exhaustive on purpose: the rescan guard compares the whole block, so a
      // field that did not survive the trip is a card that keeps its old
      // verdict after a write that succeeded.
      expect(ModOrigin.fromJson(full.toJson()), full);
    });

    test('omits everything that equals its read-side default', () {
      // Absence already means "default" on read, so writing them would add
      // noise to a file users can open without adding information.
      final json = ModOrigin(
        provenance: OriginProvenance.importedFolder,
        downloads: const [ModDownload(modId: 1)],
      ).toJson();

      expect(json.keys, ['provenance', 'downloads']);
      expect((json['downloads'] as List).single, {'role': 'base', 'mod_id': 1});
    });

    test('an empty stack is absent rather than an empty list', () {
      // A block that records only how the folder got here is a real state —
      // every mod the offline backfill could derive nothing about — and `[]`
      // adds nothing to it.
      final json =
          const ModOrigin(provenance: OriginProvenance.importedFolder).toJson();
      expect(json.containsKey('downloads'), isFalse);
      expect(ModOrigin.fromJson(json)!.downloads, isEmpty);
    });

    test('version and version_label stay distinct', () {
      // Conflating them makes two variants of one release look like two
      // releases, which is the mistake the update check exists to avoid.
      final back = ModOrigin.fromJson(ModOrigin(
        provenance: OriginProvenance.downloaded,
        downloads: const [
          ModDownload(modId: 1, version: '3.0', versionLabel: 'white hair ver'),
        ],
      ).toJson())!;

      expect(back.base!.version, '3.0');
      expect(back.base!.versionLabel, 'white hair ver');
    });

    test('dates are stored as ISO-8601 UTC', () {
      final json = ModOrigin(
        provenance: OriginProvenance.downloaded,
        installedAt: DateTime.utc(2026, 1, 2, 3, 4, 5),
        downloads: [
          ModDownload(
            modId: 1,
            baselineRemoteDate: DateTime.utc(2026, 2, 3),
            updatesDismissedUntil: DateTime.utc(2026, 3, 4),
          ),
        ],
      ).toJson();

      expect(json['installed_at'], '2026-01-02T03:04:05.000Z');
      final layer = (json['downloads'] as List).single as Map;
      expect(layer['baseline_remote_date'], '2026-02-03T00:00:00.000Z');
      expect(layer['updates_dismissed_until'], '2026-03-04T00:00:00.000Z');
    });
  });

  group('fromJson never throws', () {
    test('for a non-object', () {
      for (final raw in ['nonsense', 42, true, <int>[1], null]) {
        expect(ModOrigin.fromJson(raw), isNull, reason: '$raw');
      }
    });

    test('for wrongly-typed scalars', () {
      final origin = ModOrigin.fromJson({
        'source': 42,
        'provenance': <String>[],
        'installed_at': 12345,
        'installed_at_is_proxy': 'yes',
        'tracking': <String, String>{},
        'ingest': 'not an object',
        'downloads': {'not': 'a list'},
      })!;

      expect(origin.source, isNull);
      expect(origin.provenance, OriginProvenance.importedFolder);
      expect(origin.installedAt, isNull);
      expect(origin.installedAtIsProxy, isFalse);
      expect(origin.tracking, OriginTracking.auto);
      expect(origin.ingest, isNull);
      expect(origin.downloads, isEmpty);
    });

    test('a stringly-typed id is tolerated rather than rejected', () {
      // A hand-edited or foreign sidecar may hold the string form, and
      // refusing it loudly would cost the user their file.
      final origin = ModOrigin.fromJson({
        'provenance': 'downloaded',
        'downloads': [
          {'mod_id': '700727', 'file_id': ' 1428172 '},
        ],
      })!;

      expect(origin.base!.modId, 700727);
      expect(origin.base!.fileId, 1428172);
    });

    test('and the surrounding user data survives it', () {
      // The whole point. `ModMetadata.fromJson` must not lose a description
      // because the machine-owned half was garbage.
      final metadata = ModMetadata.fromJson({
        'description': 'mine',
        'tags': ['a'],
        'origin': 'nonsense',
      });

      expect(metadata.description, 'mine');
      expect(metadata.tags, ['a']);
      expect(metadata.origin, isNull);
    });
  });

  group('the stack', () {
    ModOrigin stack(List<ModDownload> downloads) => ModOrigin(
          provenance: OriginProvenance.downloaded,
          downloads: downloads,
        );

    test('base is the bottom and patches are everything above it', () {
      final origin = stack(const [
        ModDownload(modId: 1),
        ModDownload(role: DownloadRole.patch, modId: 2),
        ModDownload(role: DownloadRole.patch, modId: 3),
      ]);

      expect(origin.base!.modId, 1);
      expect(origin.patches.map((d) => d.modId), [2, 3]);
      expect(origin.isMixed, isTrue);
    });

    test('an empty stack has no base and is not mixed', () {
      final origin = stack(const []);
      expect(origin.base, isNull);
      expect(origin.patches, isEmpty);
      expect(origin.isMixed, isFalse);
      expect(origin.hasIdentity, isFalse);
    });

    test('a layer is found and addressed by its own id', () {
      final origin = stack(const [
        ModDownload(modId: 1),
        ModDownload(role: DownloadRole.patch, modId: 2),
      ]);

      expect(origin.downloadOf(2)!.role, DownloadRole.patch);
      expect(origin.indexOf(2), 1);
      expect(origin.indexOf(999), -1);
      expect(origin.downloadOf(999), isNull);
    });

    test('only layers that name a page are trackable', () {
      final origin = stack(const [
        ModDownload(modId: 1),
        ModDownload(role: DownloadRole.patch),
      ]);

      expect(origin.trackable.map((d) => d.modId), [1]);
    });

    test('a repeated mod id keeps the lower layer', () {
      // Kept, the second would have the check ask one page twice and report two
      // verdicts for one folder — and the lower one is the one whose files the
      // upper would have overwritten.
      final origin = ModOrigin.fromJson({
        'provenance': 'downloaded',
        'downloads': [
          {'mod_id': 1, 'file_id': 10},
          {'mod_id': 1, 'file_id': 20},
        ],
      })!;

      expect(origin.downloads, hasLength(1));
      expect(origin.base!.fileId, 10);
    });

    test('a layer that knows nothing is kept, because its position is a fact',
        () {
      // The one rule here that would be wrong in the old shape: a companion
      // with no identity was worthless, because a companion *was* an identity.
      // Dropping this one would renumber everything above it, turning a patch
      // into the thing it was written over.
      final origin = ModOrigin.fromJson({
        'provenance': 'downloaded',
        'downloads': [
          <String, Object?>{},
          {'mod_id': 2},
        ],
      })!;

      expect(origin.downloads, hasLength(2));
      expect(origin.base!.hasIdentity, isFalse);
      expect(origin.patches.single.modId, 2);
    });

    test('an entry that is not an object at all is dropped', () {
      final origin = ModOrigin.fromJson({
        'provenance': 'downloaded',
        'downloads': [
          'nonsense',
          {'mod_id': 2},
        ],
      })!;

      expect(origin.downloads.map((d) => d.modId), [2]);
    });

    test('order is part of the value identity', () {
      // Unlike the set it replaced: order is meaning now, so two layers swapped
      // is a different folder and the rescan guard has to say so.
      final one = stack(const [
        ModDownload(modId: 1),
        ModDownload(role: DownloadRole.patch, modId: 2),
      ]);
      final other = stack(const [
        ModDownload(modId: 2),
        ModDownload(role: DownloadRole.patch, modId: 1),
      ]);

      expect(one, isNot(other));
    });
  });

  group('writing to the stack', () {
    ModOrigin patchFolder() => ModOrigin(
          provenance: OriginProvenance.downloaded,
          ingest: const ModIngest(patchShaped: true),
          downloads: const [ModDownload(modId: 605460)],
        );

    test('withBaseInserted puts the named mod underneath', () {
      final named = patchFolder().withBaseInserted(const ModDownload(
        modId: 585282,
        modIdConfidence: OriginConfidence.user,
      ));

      expect(named.downloads.map((d) => d.modId), [585282, 605460]);
      expect(named.downloads.map((d) => d.role),
          [DownloadRole.base, DownloadRole.patch]);
    });

    test('the flag records the ingest and the depth answers the question', () {
      // `patch_shaped` says what was taken in, which never stops being true; a
      // second layer says somebody has since named what it applies to. Writing
      // the answer into the flag would make it unrecoverable, and undoing a
      // wrong answer has to stay possible.
      final folder = patchFolder();
      expect(folder.needsBase, isTrue);

      final named = folder.withBaseInserted(const ModDownload(modId: 585282));
      expect(named.ingest!.patchShaped, isTrue, reason: 'still what it was');
      expect(named.needsBase, isFalse, reason: 'but no longer being asked');

      // And removing the base asks again.
      expect(named.withoutDownload(585282).needsBase, isTrue);
    });

    test('an empty stack gains a layer for the folder\'s own download', () {
      // Without it the record would read as "this folder is that mod", which
      // is the one thing it is not.
      final named = ModOrigin(
        provenance: OriginProvenance.importedFolder,
        ingest: const ModIngest(patchShaped: true),
      ).withBaseInserted(const ModDownload(modId: 585282));

      expect(named.downloads, hasLength(2));
      expect(named.base!.modId, 585282);
      expect(named.patches.single.hasIdentity, isFalse);
      expect(named.needsBase, isFalse);
    });

    test('withLayerOnTop replaces a layer naming the same mod', () {
      // One folder can hold two different patches, and re-applying the same one
      // must not list it twice.
      final once = patchFolder().withLayerOnTop(const ModDownload(
        modId: 700,
        version: '1.0',
      ));
      final twice = once.withLayerOnTop(const ModDownload(
        modId: 700,
        version: '1.1',
      ));

      expect(twice.downloads.map((d) => d.modId), [605460, 700]);
      expect(twice.patches.single.version, '1.1');
    });

    test('a layer with no id is always additive', () {
      // There is nothing to match it against, and two hand-dragged patches in
      // one folder is a real shape.
      const unnamed = ModDownload(files: [InstalledFile(path: 'a.dds')]);
      final twice =
          patchFolder().withLayerOnTop(unnamed).withLayerOnTop(unnamed);

      expect(twice.downloads, hasLength(3));
    });

    test('withDownload amends one layer and moves nothing', () {
      final origin = patchFolder().withLayerOnTop(const ModDownload(modId: 700));
      final amended =
          origin.withDownload(605460, (d) => d.copyWith(fileId: 42));

      expect(amended.downloads.map((d) => d.modId), [605460, 700]);
      expect(amended.base!.fileId, 42);
      expect(amended.patches.single.fileId, isNull);
    });

    test('withBase creates a layer when the stack is empty', () {
      // The write for anything that resolves what the folder *is* — the
      // backfill and the resolve dialog — where an empty stack is ordinary.
      final origin = const ModOrigin(
        provenance: OriginProvenance.importedFolder,
      ).withBase((d) => d.copyWith(modId: 555));

      expect(origin.base!.modId, 555);
      expect(origin.base!.role, DownloadRole.base);
    });

    test('withoutDownload re-derives the roles of what is left', () {
      final origin = ModOrigin(
        provenance: OriginProvenance.downloaded,
        downloads: const [
          ModDownload(modId: 1),
          ModDownload(role: DownloadRole.patch, modId: 2),
        ],
      );

      final left = origin.withoutDownload(1);
      expect(left.downloads.single.modId, 2);
      expect(left.downloads.single.role, DownloadRole.base,
          reason: 'it is the bottom of what is left, so it says so');
    });

    group('withDismissal', () {
      ModOrigin folder() => ModOrigin(
            provenance: OriginProvenance.downloaded,
            downloads: const [
              ModDownload(modId: 1),
              ModDownload(role: DownloadRole.patch, modId: 2),
            ],
          );

      test('lands on the layer it names and no other', () {
        // A dismissal is a statement about one page's releases. Applied to the
        // wrong layer it silences nothing and stamps another mod's release date
        // where it can hide a finding nobody dismissed.
        final until = DateTime.utc(2026, 5, 1);
        final amended = folder().withDismissal(subject: 2, until: until);

        expect(amended.downloadOf(2)!.updatesDismissedUntil, until);
        expect(amended.base!.updatesDismissedUntil, isNull);
      });

      test('a null cutoff is the undo', () {
        final amended = folder()
            .withDismissal(subject: 2, until: DateTime.utc(2026))
            .withDismissal(subject: 2, until: null);

        expect(amended.downloadOf(2)!.updatesDismissedUntil, isNull);
      });

      test('a subject this block no longer carries changes nothing', () {
        // Falling back to another layer would dismiss the wrong mod's
        // releases, and a verdict computed against a block that has since moved
        // on is exactly when that happens.
        final origin = folder();
        expect(origin.withDismissal(subject: 999, until: DateTime.utc(2026)),
            origin);
      });
    });
  });

  /// **Reading a sidecar written in the flat shape.**
  ///
  /// Identity on the block itself plus a `companions` list with roles relative
  /// to it. The shape never shipped — 2.2.2 predates the whole origin block —
  /// so the only sidecars in it were written by development builds, and this is
  /// a read-side migration with no version bump: the next save emits a stack.
  group('the flat shape migrates to a stack', () {
    test('a folder with one download becomes a one-deep stack', () {
      final origin = ModOrigin.fromJson({
        'source': 'gamebanana',
        'provenance': 'downloaded',
        'mod_id': 585282,
        'mod_id_confidence': 'exact',
        'file_id': 1433843,
        'version': '1.2',
        'version_label': 'Main file',
        'version_confidence': 'exact',
        'archive_md5': 'abc',
        'remote_missing': true,
        'installed_at': '2026-01-01T00:00:00.000Z',
      })!;

      expect(origin.downloads, hasLength(1));
      final base = origin.base!;
      expect(base.modId, 585282);
      expect(base.modIdConfidence, OriginConfidence.exact);
      expect(base.fileId, 1433843);
      expect(base.version, '1.2');
      expect(base.versionLabel, 'Main file');
      expect(base.versionConfidence, OriginConfidence.exact);
      expect(base.archiveMd5, 'abc');
      expect(base.remoteMissing, isTrue);
      // The folder's own facts stay on the folder.
      expect(origin.installedAt, DateTime.utc(2026));
      expect(origin.source, 'gamebanana');
    });

    test('a base companion goes underneath the block\'s own identity', () {
      // The flat shape's own fields were the *patch* in this ordering, and the
      // companion was the mod it patched. As a stack the base is at the bottom.
      final origin = ModOrigin.fromJson({
        'provenance': 'downloaded',
        'mod_id': 605460,
        'companions': [
          {'role': 'base', 'mod_id': 585282, 'mod_id_confidence': 'user'},
        ],
      })!;

      expect(origin.downloads.map((d) => d.modId), [585282, 605460]);
      expect(origin.base!.modIdConfidence, OriginConfidence.user);
      expect(origin.patches.single.role, DownloadRole.patch);
    });

    test('a patch companion goes on top', () {
      final origin = ModOrigin.fromJson({
        'provenance': 'downloaded',
        'mod_id': 585282,
        'companions': [
          {'role': 'patch', 'mod_id': 605460, 'mod_id_confidence': 'exact'},
        ],
      })!;

      expect(origin.downloads.map((d) => d.modId), [585282, 605460]);
    });

    test('the two orderings of one folder migrate to the same stack', () {
      // **The asymmetry the stack removed**, checked at the seam where it still
      // exists. Same two mods, mirror-image records, one answer.
      final patchPrimary = ModOrigin.fromJson({
        'provenance': 'downloaded',
        'mod_id': 605460,
        'companions': [
          {'role': 'base', 'mod_id': 585282},
        ],
      })!;
      final modPrimary = ModOrigin.fromJson({
        'provenance': 'downloaded',
        'mod_id': 585282,
        'companions': [
          {'role': 'patch', 'mod_id': 605460},
        ],
      })!;

      expect(patchPrimary.downloads.map((d) => d.modId),
          modPrimary.downloads.map((d) => d.modId));
    });

    test('the ingest file list moves to the layer that wrote it', () {
      final origin = ModOrigin.fromJson({
        'provenance': 'downloaded',
        'mod_id': 585282,
        'ingest': {
          'mode': 'separate',
          'folders': ['Ellen'],
          'patch_files': ['Body.dds'],
          'files': [
            {'path': 'Ellen.ini', 'role': 'added', 'bytes': 12},
          ],
        },
      })!;

      expect(origin.base!.files.single.path, 'Ellen.ini');
      expect(origin.base!.files.single.bytes, 12);
      // `patch_files` stays on the folder: it is the flat compatibility list.
      expect(origin.ingest!.patchFiles, ['Body.dds']);
    });

    test('a companion naming the block\'s own mod is dropped', () {
      // The same thing said twice. Kept, it would have the check ask one page
      // twice and report two verdicts for one folder.
      final origin = ModOrigin.fromJson({
        'provenance': 'downloaded',
        'mod_id': 585282,
        'companions': [
          {'role': 'patch', 'mod_id': 585282},
        ],
      })!;

      expect(origin.downloads, hasLength(1));
    });

    test('a block with nothing in it migrates to an empty stack', () {
      // Every mod the offline backfill could derive nothing about.
      final origin = ModOrigin.fromJson({'provenance': 'imported_folder'})!;
      expect(origin.downloads, isEmpty);
      expect(origin.hasIdentity, isFalse);
    });

    test('a `downloads` key wins outright', () {
      // A sidecar this build wrote is never re-migrated, so a stale `mod_id`
      // left beside the stack cannot resurrect itself.
      final origin = ModOrigin.fromJson({
        'provenance': 'downloaded',
        'mod_id': 999,
        'downloads': [
          {'role': 'base', 'mod_id': 1},
        ],
      })!;

      expect(origin.downloads.map((d) => d.modId), [1]);
    });

    test('the next write emits the stack and drops the flat keys', () {
      final json = ModOrigin.fromJson({
        'provenance': 'downloaded',
        'mod_id': 585282,
        'companions': [
          {'role': 'patch', 'mod_id': 605460},
        ],
      })!
          .toJson();

      expect(json.containsKey('mod_id'), isFalse);
      expect(json.containsKey('companions'), isFalse);
      expect((json['downloads'] as List), hasLength(2));
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
        expect(const ModIngest(patchShaped: true), isNot(const ModIngest()));
        expect(const ModIngest(patchShaped: true).isEmpty, isFalse);
      });
    });

    /// **The flat patch-file list, kept for compatibility.**
    ///
    /// The authority is each layer's own `files`; this is the derived union an
    /// already-released build can still read. It stays a `string[]` permanently:
    /// that build filters the key to strings, so per-download objects there
    /// would read as *no* patch files and the next base update would flatten
    /// the patch away.
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

      test('the ingest carries no per-file record of its own', () {
        // Those belong to the layer that wrote them. Pinned so nothing puts a
        // per-download field back on a per-folder record.
        expect(
          const ModIngest(patchFiles: ['a.dds']).toJson().keys,
          ['mode', 'patch_files'],
        );
      });
    });
  });

  group('allowsUnattendedUpdate', () {
    ModOrigin origin({
      OriginConfidence modIdConfidence = OriginConfidence.exact,
      OriginConfidence versionConfidence = OriginConfidence.exact,
      OriginTracking tracking = OriginTracking.auto,
      bool remoteMissing = false,
      OriginProvenance provenance = OriginProvenance.downloaded,
    }) =>
        ModOrigin(
          provenance: provenance,
          tracking: tracking,
          downloads: [
            ModDownload(
              modId: 1,
              modIdConfidence: modIdConfidence,
              versionConfidence: versionConfidence,
              remoteMissing: remoteMissing,
            ),
          ],
        );

    test('needs BOTH axes exact', () {
      // Knowing the mod but not the file is not enough to know what would
      // replace it.
      expect(origin().allowsUnattendedUpdate, isTrue);
      expect(
        origin(modIdConfidence: OriginConfidence.user).allowsUnattendedUpdate,
        isFalse,
      );
      expect(
        origin(versionConfidence: OriginConfidence.user)
            .allowsUnattendedUpdate,
        isFalse,
      );
    });

    test('is off when the user declared the mod local', () {
      expect(
        origin(tracking: OriginTracking.off).allowsUnattendedUpdate,
        isFalse,
      );
    });

    test('is off when the mod is gone upstream', () {
      expect(origin(remoteMissing: true).allowsUnattendedUpdate, isFalse);
    });

    test('a hand-imported archive can still qualify', () {
      // Provenance is not the gate; confidence is. A banked hash matching a
      // published checksum is exact-grade knowledge about a folder nobody
      // downloaded through the app.
      expect(
        origin(provenance: OriginProvenance.importedArchive)
            .allowsUnattendedUpdate,
        isTrue,
      );
    });

    test('is off for a folder with no stack at all', () {
      expect(
        const ModOrigin(provenance: OriginProvenance.downloaded)
            .allowsUnattendedUpdate,
        isFalse,
      );
    });
  });
}
