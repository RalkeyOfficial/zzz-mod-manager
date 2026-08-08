import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/mod_metadata.dart';
import 'package:mod_manager_flutter/services/gamebanana/remote_mod_metadata.dart';
import 'package:mod_manager_flutter/services/metadata_autofill.dart';

/// The one rule this unit enforces: **fill absence, never displace.**
///
/// Worth unit-testing rather than clicking, because the failure mode is silent
/// and destructive in the same breath — a mod folder can arrive carrying the
/// author's own sidecar (`_copyDirectory` copies `.zzz-mod-manager/` wholesale
/// and `docs/metadata-schema.md` §2 keeps the user-facing half deliberately), so
/// "already set" routinely means "the author wrote this".
void main() {
  final remote = RemoteModMetadata(
    description: 'Remote description',
    tags: const ['Ellen: Chained school uniforms'],
    characterId: 'ellen',
    imageUrls: [Uri.parse('https://images.gamebanana.com/x/01.jpg')],
  );

  MetadataAutofillPlan planFor(ModMetadata existing, {String? shippedPreview}) =>
      planMetadataAutofill(
        existing: existing,
        remote: remote,
        shippedPreview: shippedPreview,
      );

  group('a bare sidecar', () {
    test('gets every field the mod page can supply', () {
      final plan = planFor(const ModMetadata());

      expect(plan.description, 'Remote description');
      expect(plan.tags, ['Ellen: Chained school uniforms']);
      expect(plan.characterId, 'ellen');
      expect(plan.imageUrls, hasLength(1));
      expect(plan.isEmpty, isFalse);
    });

    test('treats the runtime "unknown" placeholder as untagged', () {
      // It must never reach disk, but a caller may still hand it over.
      expect(planFor(const ModMetadata(characterId: 'unknown')).characterId,
          'ellen');
      expect(planFor(const ModMetadata(characterId: '')).characterId, 'ellen');
    });

    test('an empty description string counts as absent', () {
      expect(planFor(const ModMetadata(description: '')).description,
          'Remote description');
    });
  });

  group('a sidecar that already carries something', () {
    test('keeps the author\'s description', () {
      final plan = planFor(const ModMetadata(description: 'Author text'));
      expect(plan.description, isNull);
      // The other fields are still filled — this is per field, not all-or-nothing.
      expect(plan.characterId, 'ellen');
    });

    test('keeps a non-empty tag list wholesale, without merging', () {
      // A partial list is a curation. Merging remote tags into it would produce
      // a set nobody chose.
      final plan = planFor(const ModMetadata(tags: ['4k']));
      expect(plan.tags, isNull);
    });

    test('keeps an assigned character', () {
      expect(planFor(const ModMetadata(characterId: 'jane')).characterId, isNull);
    });

    test('fetches nothing when a gallery already exists', () {
      final plan = planFor(const ModMetadata(images: ['Preview.png']));
      expect(plan.imageUrls, isEmpty);
      expect(plan.shippedPreview, isNull);
    });

    test('is empty when nothing is missing', () {
      final plan = planFor(const ModMetadata(
        description: 'Author text',
        tags: ['4k'],
        characterId: 'jane',
        images: ['Preview.png'],
      ));
      expect(plan.isEmpty, isTrue);
    });
  });

  group('an author-shipped preview', () {
    test('stays at the front of the imported gallery', () {
      // Nothing local is lost and nothing local is demoted: the cover slot keeps
      // the image that came in the archive.
      final plan = planFor(const ModMetadata(), shippedPreview: 'Preview.png');
      expect(plan.shippedPreview, 'Preview.png');
      expect(plan.imageUrls, hasLength(1));
    });

    test('is not written on its own when there are no remote images', () {
      // The scan already falls back to it, so recording it would be a pointless
      // write — and one that freezes the gallery at a single entry.
      final plan = planMetadataAutofill(
        existing: const ModMetadata(),
        remote: const RemoteModMetadata(description: 'x'),
        shippedPreview: 'Preview.png',
      );
      expect(plan.shippedPreview, isNull);
      expect(plan.imageUrls, isEmpty);
      expect(plan.description, 'x');
    });
  });

  test('an empty remote contributes nothing', () {
    final plan = planMetadataAutofill(
      existing: const ModMetadata(),
      remote: const RemoteModMetadata(),
    );
    expect(plan.isEmpty, isTrue);
  });
}
