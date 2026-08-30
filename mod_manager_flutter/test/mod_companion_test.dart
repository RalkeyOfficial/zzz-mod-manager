import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/mod_companion.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';

/// A second remote identity in one mod folder.
///
/// The type carries one rule that everything else rests on: **an entry that
/// cannot say what it is, is dropped rather than guessed at.** A companion
/// decides which extra mod page the update check asks about, so a corrupt or
/// forward-dated entry read optimistically would point the check at a page
/// nobody chose.
void main() {
  group('role', () {
    test('known roles round-trip', () {
      for (final role in CompanionRole.values) {
        expect(CompanionRole.parse(role.wire), role);
      }
    });

    test('an unknown role is null, never a default', () {
      // Deliberately *not* "degrade to base". Role says what this download is
      // relative to the folder's primary, and a future build inventing a third
      // value must not have it read as one of the two this build acts on.
      expect(CompanionRole.parse('sibling'), isNull);
      expect(CompanionRole.parse('BASE'), isNull,
          reason: 'the wire form is lowercase; anything else is not a match');
      expect(CompanionRole.parse(null), isNull);
      expect(CompanionRole.parse(42), isNull);
      expect(CompanionRole.parse({'a': 1}), isNull);
    });
  });

  group('serialisation', () {
    test('round-trips every field', () {
      const companion = ModCompanion(
        role: CompanionRole.base,
        modId: 111,
        modIdConfidence: OriginConfidence.user,
        fileId: 1490003,
        version: '2.1',
        versionLabel: 'Main file',
        versionConfidence: OriginConfidence.user,
        archiveMd5: '9e107d9d372bb6826bd81d3542a419d6',
        remoteMissing: true,
      );

      final back = ModCompanion.fromJson(companion.toJson())!;

      expect(back.role, CompanionRole.base);
      expect(back.modId, 111);
      expect(back.modIdConfidence, OriginConfidence.user);
      expect(back.fileId, 1490003);
      expect(back.version, '2.1');
      expect(back.versionLabel, 'Main file');
      expect(back.versionConfidence, OriginConfidence.user);
      expect(back.archiveMd5, '9e107d9d372bb6826bd81d3542a419d6');
      expect(back.remoteMissing, isTrue);
    });

    test('the dates round-trip as ISO-8601 UTC', () {
      final companion = ModCompanion(
        role: CompanionRole.patch,
        modId: 222,
        baselineRemoteDate: DateTime.utc(2026, 7, 1),
        updatesDismissedUntil: DateTime.utc(2026, 8, 1, 12, 30),
      );
      final json = companion.toJson();
      expect(json['baseline_remote_date'], '2026-07-01T00:00:00.000Z');
      expect(json['updates_dismissed_until'], '2026-08-01T12:30:00.000Z');

      final back = ModCompanion.fromJson(json)!;
      expect(back.baselineRemoteDate, DateTime.utc(2026, 7, 1));
      expect(back.updatesDismissedUntil, DateTime.utc(2026, 8, 1, 12, 30));
    });

    test('omits everything that equals its read-side default', () {
      // Absence already means "default" on read. Every sidecar in existence
      // lacks this key entirely, and the ones that gain it should read as two
      // lines rather than twelve mostly-null ones.
      expect(
        const ModCompanion(role: CompanionRole.base, modId: 111).toJson(),
        {'role': 'base', 'mod_id': 111},
      );
    });
  });

  group('fromJson never throws, and drops what it cannot use', () {
    test('for a non-object', () {
      expect(ModCompanion.fromJson('hello'), isNull);
      expect(ModCompanion.fromJson(42), isNull);
      expect(ModCompanion.fromJson(<String>['a']), isNull);
      expect(ModCompanion.fromJson(null), isNull);
    });

    test('an entry with no usable mod id is nothing', () {
      // "A companion with no identity is nothing" — there is no page to ask.
      expect(ModCompanion.fromJson({'role': 'base'}), isNull);
      expect(ModCompanion.fromJson({'role': 'base', 'mod_id': 'abc'}), isNull);
      expect(
        ModCompanion.fromJson({'role': 'base', 'mod_id': <String, int>{}}),
        isNull,
      );
    });

    test('a stringly-typed id is tolerated, as it is on the primary', () {
      // A sidecar is a public interchange format and can arrive hand-edited;
      // refusing this loudly would cost the user the entry.
      expect(ModCompanion.fromJson({'role': 'base', 'mod_id': '111'})!.modId,
          111);
    });

    test('an entry with no usable role is dropped, not defaulted', () {
      expect(ModCompanion.fromJson({'mod_id': 111}), isNull);
      expect(ModCompanion.fromJson({'role': 'sibling', 'mod_id': 111}), isNull);
    });

    test('wrongly-typed scalars degrade to absence, keeping the entry', () {
      // The identity is intact, so the entry is still worth having — the
      // check can ask the page and the resolve dialog can fill the rest in.
      final companion = ModCompanion.fromJson({
        'role': 'patch',
        'mod_id': 222,
        'file_id': true,
        'version': 42,
        'archive_md5': <String>[],
        'baseline_remote_date': 'not a date',
        'remote_missing': 'yes',
      })!;

      expect(companion.modId, 222);
      expect(companion.fileId, isNull);
      expect(companion.version, isNull);
      expect(companion.archiveMd5, isNull);
      expect(companion.baselineRemoteDate, isNull);
      expect(companion.remoteMissing, isFalse,
          reason: 'anything but true is false, as it is on the primary block');
    });

    test('an unrecognised confidence degrades to unknown, never upward', () {
      final companion = ModCompanion.fromJson({
        'role': 'base',
        'mod_id': 111,
        'mod_id_confidence': 'attested',
        'version_confidence': 'verified',
      })!;
      expect(companion.modIdConfidence, OriginConfidence.unknown);
      expect(companion.versionConfidence, OriginConfidence.unknown);
    });

    test('a nested companions list is dropped', () {
      // One level, no tree. A companion describes a download in this folder;
      // it does not get to describe a folder of its own.
      final json = {
        'role': 'base',
        'mod_id': 111,
        'companions': [
          {'role': 'patch', 'mod_id': 999},
        ],
      };
      expect(ModCompanion.fromJson(json), isNotNull);
      expect(ModCompanion.fromJson(json)!.toJson().containsKey('companions'),
          isFalse);
    });
  });

  group('value identity', () {
    test('covers every field', () {
      const base = ModCompanion(role: CompanionRole.base, modId: 111);
      expect(base, const ModCompanion(role: CompanionRole.base, modId: 111));

      // The rescan guard compares the whole origin block, so a field left out
      // here is a card that keeps rendering its old verdict after a write.
      expect(base, isNot(const ModCompanion(role: CompanionRole.patch, modId: 111)));
      expect(base, isNot(const ModCompanion(role: CompanionRole.base, modId: 222)));
      expect(
        base,
        isNot(const ModCompanion(
          role: CompanionRole.base,
          modId: 111,
          modIdConfidence: OriginConfidence.user,
        )),
      );
      expect(
        base,
        isNot(const ModCompanion(
            role: CompanionRole.base, modId: 111, fileId: 5)),
      );
      expect(
        base,
        isNot(const ModCompanion(
            role: CompanionRole.base, modId: 111, version: '2')),
      );
      expect(
        base,
        isNot(const ModCompanion(
            role: CompanionRole.base, modId: 111, versionLabel: 'Main')),
      );
      expect(
        base,
        isNot(const ModCompanion(
          role: CompanionRole.base,
          modId: 111,
          versionConfidence: OriginConfidence.user,
        )),
      );
      expect(
        base,
        isNot(const ModCompanion(
            role: CompanionRole.base, modId: 111, archiveMd5: 'a')),
      );
      expect(
        base,
        isNot(const ModCompanion(
            role: CompanionRole.base, modId: 111, remoteMissing: true)),
      );
      expect(
        base,
        isNot(ModCompanion(
          role: CompanionRole.base,
          modId: 111,
          baselineRemoteDate: DateTime.utc(2026),
        )),
      );
      expect(
        base,
        isNot(ModCompanion(
          role: CompanionRole.base,
          modId: 111,
          updatesDismissedUntil: DateTime.utc(2026),
        )),
      );
    });

    test('equal values hash equally', () {
      expect(
        const ModCompanion(role: CompanionRole.base, modId: 111).hashCode,
        const ModCompanion(role: CompanionRole.base, modId: 111).hashCode,
      );
    });
  });
}
