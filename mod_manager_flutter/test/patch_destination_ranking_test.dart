import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/services/folder_contents.dart';
import 'package:mod_manager_flutter/services/patch_destination_ranking.dart';

FolderContents _folder({
  Set<String> files = const <String>{},
  Map<String, String> inis = const <String, String>{},
}) {
  final all = {...files, ...inis.keys};
  return FolderContents(
    files: all,
    iniPaths: inis.keys.toSet(),
    iniContents: inis,
    actualPaths: {for (final path in all) path: path},
  );
}

void main() {
  group('destinationFingerprint', () {
    test('an .ini patch names the resources it references', () {
      final fingerprint = destinationFingerprint(_folder(
        inis: {
          'patch.ini': '''
[TextureOverrideBody]
ps-t0 = ref ResourceBody

[ResourceBody]
filename = Textures\\EllenBodyADiffuse.dds

[TextureOverrideHair]
ps-t0 = ref ResourceHair

[ResourceHair]
filename = EllenHairADiffuse.dds
''',
        },
      ));

      expect(fingerprint, {'ellenbodyadiffuse.dds', 'ellenhairadiffuse.dds'});
    });

    test('an include is the patch\'s own structure, not a file to match on', () {
      final fingerprint = destinationFingerprint(_folder(
        inis: {
          'patch.ini': '''
include = shared.ini

[TextureOverrideBody]
ps-t0 = ref ResourceBody

[ResourceBody]
filename = EllenBodyADiffuse.dds
''',
          'shared.ini': '',
        },
      ));

      expect(fingerprint, {'ellenbodyadiffuse.dds'});
    });

    test('an asset patch names the files it ships', () {
      final fingerprint = destinationFingerprint(_folder(
        files: {'ellenbodyadiffuse.dds', 'ellenbody.buf'},
      ));

      expect(fingerprint, {'ellenbodyadiffuse.dds', 'ellenbody.buf'});
    });

    test('a screenshot beside an asset patch is not a file to match on', () {
      final fingerprint = destinationFingerprint(_folder(
        files: {'ellenbodyadiffuse.dds', 'preview.png', 'readme.txt'},
      ));

      expect(fingerprint, {'ellenbodyadiffuse.dds'});
    });

    test('nothing to go on comes back empty rather than guessing', () {
      expect(destinationFingerprint(_folder()), isEmpty);
      expect(
        destinationFingerprint(_folder(files: {'readme.txt', 'preview.png'})),
        isEmpty,
      );
    });
  });

  group('rankDestinations', () {
    test('holding more of the patch\'s files ranks higher', () {
      final ranked = rankDestinations(
        fingerprint: {'body.dds', 'hair.dds', 'legs.dds'},
        libraryFiles: {
          'few': {'body.dds'},
          'all': {'body.dds', 'hair.dds', 'legs.dds'},
          'some': {'body.dds', 'hair.dds'},
        },
      );

      expect([for (final rank in ranked) rank.modId], ['all', 'some', 'few']);
      expect(ranked.first.matched, 3);
      expect(ranked.first.share, 1.0);
    });

    test('a file is matched by name wherever the folder keeps it', () {
      final ranked = rankDestinations(
        fingerprint: {'body.dds'},
        libraryFiles: {
          'nested': {'textures/deep/Body.dds'},
          'empty': {'other.dds'},
        },
      );

      expect(ranked.first.modId, 'nested');
      expect(ranked.first.matched, 1);
    });

    test('every folder comes back, including the ones matching nothing', () {
      final ranked = rankDestinations(
        fingerprint: {'body.dds'},
        libraryFiles: {
          'match': {'body.dds'},
          'nothing': {'unrelated.dds'},
          'also nothing': {'other.buf'},
        },
      );

      expect(ranked.length, 3);
      expect(
        [for (final rank in ranked) rank.modId],
        containsAll(['match', 'nothing', 'also nothing']),
      );
      expect(ranked.where((rank) => rank.hasSignal).length, 1);
    });

    test('the folder the author named leads, even matching nothing', () {
      final ranked = rankDestinations(
        fingerprint: {'body.dds'},
        libraryFiles: {
          'best match': {'body.dds'},
          'named by the author': {'unrelated.dds'},
        },
        requiredMods: {'named by the author'},
      );

      expect(ranked.first.modId, 'named by the author');
      expect(ranked.first.requiredByAuthor, isTrue);
      expect(ranked.first.matched, 0);
      expect(ranked.first.hasSignal, isTrue);
      expect(ranked[1].modId, 'best match');
    });

    test('equal standing keeps the order it was given in', () {
      final ranked = rankDestinations(
        fingerprint: {'body.dds'},
        libraryFiles: {
          'anby': {'body.dds'},
          'belle': {'body.dds'},
          'caesar': {'body.dds'},
        },
      );

      expect(
        [for (final rank in ranked) rank.modId],
        ['anby', 'belle', 'caesar'],
      );
    });

    test('nothing to rank on leaves the list exactly as it was', () {
      final ranked = rankDestinations(
        fingerprint: const <String>{},
        libraryFiles: {
          'anby': {'body.dds'},
          'belle': {'hair.dds'},
        },
      );

      expect([for (final rank in ranked) rank.modId], ['anby', 'belle']);
      expect(ranked.every((rank) => rank.share == 0), isTrue);
      expect(ranked.every((rank) => rank.hasSignal), isFalse);
    });

    test('two copies of one name in a folder count once', () {
      final ranked = rankDestinations(
        fingerprint: {'body.dds'},
        libraryFiles: {
          'twice': {'sfw/body.dds', 'nsfw/body.dds'},
        },
      );

      expect(ranked.single.matched, 1);
      expect(ranked.single.share, 1.0);
    });
  });
}
