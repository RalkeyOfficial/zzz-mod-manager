import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:mod_manager_flutter/models/mod_ingest.dart';
import 'package:mod_manager_flutter/models/mod_metadata.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/services/origin_backfill.dart';
import 'package:mod_manager_flutter/utils/gamebanana_url.dart';
import 'package:mod_manager_flutter/utils/install_date_proxy.dart';

/// The offline backfill, split the way the code is: the decisions run with no
/// filesystem at all, and only the install-date proxy touches real files.
void main() {
  ModMetadata meta({String? sourceUrl, ModOrigin? origin}) =>
      ModMetadata(sourceUrl: sourceUrl, origin: origin);

  group('recoverableModId — the gate', () {
    test('recovers an id from a mod-page source_url', () {
      expect(
        OriginBackfill.recoverableModId(
          meta(sourceUrl: 'https://gamebanana.com/mods/531649'),
        ),
        531649,
      );
    });

    test('yields nothing when there is no source_url at all', () {
      expect(OriginBackfill.recoverableModId(meta()), isNull);
    });

    test('yields nothing for a url that is not a mod page', () {
      // The high-frequency real-world cases: a file link (a *different* id
      // space — reading one as the other binds the folder to an unrelated mod),
      // and a link to somewhere else entirely.
      for (final url in [
        'https://gamebanana.com/dl/1770600',
        'https://gamebanana.com/mods/cats/30305',
        'https://drive.google.com/file/d/abc',
        'not a url',
      ]) {
        expect(OriginBackfill.recoverableModId(meta(sourceUrl: url)), isNull,
            reason: url);
      }
    });

    test('a url parse never overrules exact or user confidence', () {
      // Those came from a download, a checksum match, or the user confirming
      // it in the resolve dialog — none of which came from this text field.
      for (final tier in [OriginConfidence.exact, OriginConfidence.user]) {
        expect(
          OriginBackfill.recoverableModId(meta(
            sourceUrl: 'https://gamebanana.com/mods/999',
            origin: ModOrigin(
              provenance: OriginProvenance.downloaded,
              modId: 111,
              modIdConfidence: tier,
            ),
          )),
          isNull,
          reason: tier.wire,
        );
      }
    });

    test('does nothing when the stored id already agrees with the url', () {
      expect(
        OriginBackfill.recoverableModId(meta(
          sourceUrl: 'https://gamebanana.com/mods/111',
          origin: const ModOrigin(
            provenance: OriginProvenance.importedFolder,
            modId: 111,
            modIdConfidence: OriginConfidence.inferred,
          ),
        )),
        isNull,
        reason: 'nothing to write means nothing written',
      );
    });

    test('leaves a marketplace install alone, now that it writes both', () {
      // An install records `mod_id` at `exact` *and* a canonical `source_url`.
      // The two agree by construction — which is exactly why the url is built
      // from the id rather than copied off the page — so the backfill has
      // nothing to say, and could not downgrade the tier even if it did.
      expect(
        OriginBackfill.recoverableModId(meta(
          sourceUrl: gameBananaModUrl(700727),
          origin: const ModOrigin(
            provenance: OriginProvenance.downloaded,
            modId: 700727,
            modIdConfidence: OriginConfidence.exact,
          ),
        )),
        isNull,
      );
    });

    test('a corrected url revises an id that came from the url', () {
      // The failure this guards: the user pastes the wrong mod page, a scan
      // binds the folder to it at `inferred`, and the user then fixes the url.
      // If the id could not follow the field it came from, correcting the
      // mistake would be a silent no-op with no other remedy available until
      // the resolve dialog ships.
      for (final tier in [
        OriginConfidence.inferred,
        OriginConfidence.assumedLatest,
        OriginConfidence.unknown,
      ]) {
        expect(
          OriginBackfill.recoverableModId(meta(
            sourceUrl: 'https://gamebanana.com/mods/222',
            origin: ModOrigin(
              provenance: OriginProvenance.importedFolder,
              modId: 111,
              modIdConfidence: tier,
            ),
          )),
          222,
          reason: tier.wire,
        );
      }
    });

    test('respects tracking: off — a local mod is never re-attached', () {
      // "Not from GameBanana / it's my own" is a decision the user made, and a
      // stale source_url is exactly why they might have made it.
      expect(
        OriginBackfill.recoverableModId(meta(
          sourceUrl: 'https://gamebanana.com/mods/531649',
          origin: const ModOrigin(
            provenance: OriginProvenance.importedArchive,
            tracking: OriginTracking.off,
          ),
        )),
        isNull,
      );
    });
  });

  group('merge — what gets written', () {
    final installedAt = DateTime.utc(2025, 3, 4, 5, 6);

    test('builds a fresh block at inferred confidence, version still unknown', () {
      final origin = OriginBackfill.merge(
        existing: null,
        modId: 531649,
        installedAt: installedAt,
      );

      expect(origin.source, 'gamebanana');
      expect(origin.modId, 531649);
      expect(origin.modIdConfidence, OriginConfidence.inferred);
      expect(origin.installedAt, installedAt);
      expect(origin.installedAtIsProxy, isTrue);

      // Identity and version are separate unknowns; the archive is gone, so
      // there is nothing local left to pin a version with.
      expect(origin.fileId, isNull);
      expect(origin.version, isNull);
      expect(origin.versionConfidence, OriginConfidence.unknown);

      // Least-privileged provenance: a legacy mod may have been downloaded by
      // an old build, imported, or hand-copied, and we cannot tell.
      expect(origin.provenance, OriginProvenance.importedFolder);
    });

    test('never claims a proxy date it did not supply', () {
      final origin = OriginBackfill.merge(
        existing: null,
        modId: 531649,
        installedAt: null,
      );
      expect(origin.installedAt, isNull);
      expect(origin.installedAtIsProxy, isFalse);
    });

    test('an observed install date beats a derived one', () {
      // A mod we downloaded, whose source_url the user later pasted in. The
      // recorded install moment is real; the proxy would be a downgrade.
      final observed = DateTime.utc(2026, 1, 1);
      final origin = OriginBackfill.merge(
        existing: ModOrigin(
          provenance: OriginProvenance.downloaded,
          installedAt: observed,
          archiveMd5: 'abc123',
          ingest: const ModIngest(folders: ['Ellen Swimsuit']),
        ),
        modId: 531649,
        installedAt: installedAt,
      );

      expect(origin.installedAt, observed);
      expect(origin.installedAtIsProxy, isFalse);
      // ...and the rest of the existing block is carried, not rebuilt.
      expect(origin.provenance, OriginProvenance.downloaded);
      expect(origin.archiveMd5, 'abc123');
      expect(origin.ingest?.folders, ['Ellen Swimsuit']);
      expect(origin.modId, 531649);
      expect(origin.modIdConfidence, OriginConfidence.inferred);
    });

    test('a rebind drops what described the old mod, but keeps the hash', () {
      final origin = OriginBackfill.merge(
        existing: ModOrigin(
          provenance: OriginProvenance.importedArchive,
          modId: 111,
          modIdConfidence: OriginConfidence.inferred,
          fileId: 555,
          version: '1.2',
          versionLabel: 'white hair ver',
          versionConfidence: OriginConfidence.inferred,
          baselineRemoteDate: DateTime.utc(2025, 1, 1),
          remoteMissing: true,
          archiveMd5: 'abc123',
        ),
        modId: 222,
        installedAt: installedAt,
      );

      expect(origin.modId, 222);
      // A file id and a version mean something only relative to one mod page;
      // carrying them over would assert that mod 222 ships mod 111's file.
      expect(origin.fileId, isNull);
      expect(origin.version, isNull);
      expect(origin.versionLabel, isNull);
      expect(origin.versionConfidence, OriginConfidence.unknown);
      expect(origin.baselineRemoteDate, isNull);
      expect(origin.remoteMissing, isFalse,
          reason: 'that was a fact about the mod we are no longer pointing at');

      // The hash survives: it describes the archive we extracted, not which
      // remote mod we currently believe it to be, so it can still be matched
      // against the *new* mod's published checksums.
      expect(origin.archiveMd5, 'abc123');
    });

    test('filling an absent id is not a rebind and keeps everything', () {
      final origin = OriginBackfill.merge(
        existing: const ModOrigin(
          provenance: OriginProvenance.importedArchive,
          fileId: 555,
          version: '1.2',
          versionConfidence: OriginConfidence.inferred,
        ),
        modId: 222,
        installedAt: installedAt,
      );

      expect(origin.modId, 222);
      expect(origin.fileId, 555);
      expect(origin.version, '1.2');
      expect(origin.versionConfidence, OriginConfidence.inferred);
    });

    test('a backfilled block can never drive an unattended update', () {
      // The whole point of `inferred`: it came from a free-form text field a
      // human typed, so it must be confirmed once before anything overwrites
      // files. Even a *version* somehow being exact must not unlock it.
      final origin = OriginBackfill.merge(
        existing: const ModOrigin(
          provenance: OriginProvenance.importedArchive,
          versionConfidence: OriginConfidence.exact,
        ),
        modId: 531649,
        installedAt: installedAt,
      );
      expect(origin.allowsUnattendedUpdate, isFalse);
    });
  });

  group('probeInstallDate', () {
    test('is the injection seam — nothing else here touches a filesystem', () async {
      const backfill = OriginBackfill(installDateProbe: _noDate);
      expect(await backfill.probeInstallDate('/nowhere'), isNull);
    });
  });

  group('oldestFileMtime — the install-date proxy', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('backfill_probe_'));
    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    File write(String relative, DateTime modified) {
      final file = File(path.join(tmp.path, relative))
        ..createSync(recursive: true)
        ..writeAsStringSync('x');
      file.setLastModifiedSync(modified);
      return file;
    }

    test('returns the oldest file, including from nested folders', () async {
      write('mod.ini', DateTime(2025, 6, 1));
      write(path.join('textures', 'body.dds'), DateTime(2024, 2, 3));
      write('README.txt', DateTime(2026, 1, 1));

      expect(await oldestFileMtime(tmp.path), DateTime(2024, 2, 3).toUtc());
    });

    test('ignores our own .zzz-mod-manager directory', () async {
      // The sidecar and any migrated image were written by us, often long after
      // the install. They cannot drag the minimum earlier — but a folder with
      // nothing else would otherwise report our own write time as an install
      // date, which is a confident-looking number that means nothing.
      write(path.join('.zzz-mod-manager', 'metadata.json'), DateTime(2020, 1, 1));
      write(path.join('.zzz-mod-manager', 'images', '01.png'), DateTime(2020, 1, 1));
      write('mod.ini', DateTime(2025, 6, 1));

      expect(await oldestFileMtime(tmp.path), DateTime(2025, 6, 1).toUtc());
    });

    test('returns null for a folder with nothing but our own bookkeeping', () async {
      write(path.join('.zzz-mod-manager', 'metadata.json'), DateTime(2020, 1, 1));
      expect(await oldestFileMtime(tmp.path), isNull);
    });

    test('returns null rather than throwing for a folder that is not there', () async {
      expect(await oldestFileMtime(path.join(tmp.path, 'gone')), isNull);
    });
  });
}

Future<DateTime?> _noDate(String _) async => null;
