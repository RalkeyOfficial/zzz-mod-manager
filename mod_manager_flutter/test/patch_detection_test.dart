import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/services/ini_resources.dart';
import 'package:mod_manager_flutter/services/patch_detection.dart';

void main() {
  PatchAssessment assess(
    Map<String, String> inis, {
    Set<String> files = const {},
    Set<String> directories = const {},
  }) =>
      assessPatchShape(
        references: collectIniReferences(inis),
        files: files,
        directories: directories,
        hasIni: inis.isNotEmpty,
      );

  /// A mod `.ini` in the shape 3DMigoto actually uses: an override that
  /// references resources, and the resource sections themselves. Anything
  /// simpler would test the "declaration outside any section" fallback rather
  /// than the rule.
  String modIni(Map<String, String> resources) {
    final buffer = StringBuffer('[TextureOverrideBody]\nhash = 1234abcd\n');
    var i = 0;
    for (final section in resources.keys) {
      buffer.writeln('ps-t${i++} = $section');
    }
    for (final entry in resources.entries) {
      buffer.writeln('\n[${entry.key}]\nfilename = ${entry.value}');
    }
    return buffer.toString();
  }

  test('a complete mod ships everything its .ini opens', () {
    final result = assess(
      {'ellen.ini': modIni({'ResB': 'Body.dds', 'ResH': 'Hair.dds'})},
      files: {'ellen.ini', 'body.dds', 'hair.dds'},
    );
    expect(result.looksLikePatch, isFalse);
    expect(result.missing, isEmpty);
    expect(result.required, 2);
    expect(result.presentResources, 2);
  });

  test('a patch names the mod it expects and ships none of it', () {
    final result = assess(
      {'ellen.ini': modIni({'ResB': 'Body.dds', 'ResH': 'Hair.dds'})},
      files: {'ellen.ini'},
    );
    expect(result.looksLikePatch, isTrue);
    expect(result.missing, ['body.dds', 'hair.dds']);
    expect(result.presentResources, 0);
  });

  test('a patch may be several .ini files including each other', () {
    // `Nicole Casual Wear (Updated Ini's 3.0)`, the only real patch in the
    // measured corpus: 5.8 KB, five `.ini` files, no content. An include that
    // resolves is structure, not content, so it must not count as a resource.
    final result = assess(
      {
        'master.ini': 'include = body/part.ini',
        'body/part.ini': modIni({'ResB': 'Body.dds'}),
      },
      files: {'master.ini', 'body/part.ini'},
    );
    expect(result.looksLikePatch, isTrue);
    expect(result.presentResources, 0);
  });

  group('the reference filter', () {
    test('an unreferenced declaration is not a requirement', () {
      // The bug this was built for: a working mod whose template left two
      // resource sections behind that nothing asks for.
      final result = assess(
        {
          'm.ini': '''
[TextureOverrideBody]
ps-t0 = ResourceBody

[ResourceBody]
filename = Body.dds

[ResourceFaceADiffuse]
filename = FaceADiffuse.dds
''',
        },
        files: {'m.ini', 'body.dds'},
      );
      expect(result.looksLikePatch, isFalse);
      expect(result.required, 1);
      expect(result.unreferenced, 1);
    });

    test('a patch keeps its references, so the filter does not save it', () {
      // A patch .ini is a *full replacement* for the mod's working .ini, so the
      // sections it declares are exactly the ones it refs. That is the
      // mechanism by which it patches, and it is why the filter cannot hide it.
      final result = assess(
        {'m.ini': modIni({'R1': 'A.dds', 'R2': 'B.dds', 'R3': 'C.dds'})},
        files: {'m.ini'},
      );
      expect(result.looksLikePatch, isTrue);
      expect(result.unreferenced, 0);
    });
  });

  group('a partial mod is not a patch, however much it is missing', () {
    test('shipping one of ten referenced files is enough to clear it', () {
      // `Remielle combat wings replaced` in miniature: the extraction tool's
      // `.ini` covers the whole character, the author replaced one component.
      // Measured at 8 of 36 on the real mod.
      final result = assess(
        {
          'm.ini': modIni({
            for (var i = 0; i < 10; i++) 'R$i': 'file$i.dds',
          }),
        },
        files: {'m.ini', 'file0.dds'},
      );
      expect(result.missing.length, 9);
      expect(result.presentResources, 1);
      expect(result.looksLikePatch, isFalse);
    });

    test('a ratio cannot separate these — the populations overlap entirely', () {
      // Recorded as a test because "require most of it to be missing" is the
      // obvious next idea and was measured and rejected: the false positives
      // sat at 0%, 2%, 18%, 22%, 32% and 92% of references present, which is
      // the whole range. A download that ships *nothing* is the only fact that
      // separates them.
      final barelyThere = assess(
        {'m.ini': modIni({for (var i = 0; i < 50; i++) 'R$i': 'f$i.dds'})},
        files: {'m.ini', 'f0.dds'},
      );
      expect(barelyThere.presentResources, 1);
      expect(barelyThere.looksLikePatch, isFalse,
          reason: '2% present is an ordinary partial mod, not a patch');
    });

    test('two duplicate references to one file count once', () {
      final result = assess(
        {'m.ini': modIni({'R1': 'A.dds', 'R2': 'A.dds', 'R3': 'B.dds'})},
        files: {'m.ini', 'b.dds'},
      );
      expect(result.required, 2);
      expect(result.presentResources, 1);
    });
  });

  test('buffers do not make a complete mod look like a patch', () {
    final result = assess(
      {
        'm.ini': '''
[TextureOverrideBody]
vb0 = ResourceBodyPosition
ps-t0 = ResourceBodyDiffuse

[ResourceBodyPosition]
type = Buffer
stride = 40

[ResourceBodyDiffuse]
filename = Body.dds
''',
      },
      files: {'m.ini', 'body.dds'},
    );
    expect(result.looksLikePatch, isFalse);
  });

  test('an unresolvable path is counted, never reported missing', () {
    final result = assess(
      {
        'm.ini': '[O]\nps-t0 = R\n\n[R]\n'
            r'filename = $\ns\slot.dds',
      },
      files: {'m.ini'},
    );
    expect(result.looksLikePatch, isFalse);
    expect(result.unresolvable, 1);
    expect(result.required, 0);
  });

  test('include_recursive is satisfied by a directory, not a file', () {
    expect(
      assess(
        {'m.ini': 'include_recursive = parts'},
        files: {'m.ini'},
        directories: {'parts'},
      ).looksLikePatch,
      isFalse,
    );
    expect(
      assess({'m.ini': 'include_recursive = parts'}, files: {'m.ini'})
          .looksLikePatch,
      isTrue,
    );
  });

  test('a folder with no .ini concludes nothing', () {
    final result = assess(const {}, files: {'readme.txt'});
    expect(result.hasIni, isFalse);
    expect(result.looksLikePatch, isFalse);
  });

  test('the real mod that produced the false positive now passes', () {
    // Miyabi Transfer Student (GameBanana 700727), v1.2 — the exact archive
    // that was reported as "expects 2 file(s) it doesn't include" while being a
    // complete, working mod. Two of its 31 resource declarations are
    // unreferenced, and once they are dropped nothing is missing at all.
    final ini = File('test/fixtures/ini/miyabi_student.ini').readAsStringSync();
    const shipped = {
      'miyabi.ini',
      'miyabibodya.ib', 'miyabibodyadiffuse.dds', 'miyabibodyalightmap.dds',
      'miyabibodyamaterialmap.dds', 'miyabibodyanormalmap.dds',
      'miyabibodyblend.buf', 'miyabibodyposition.buf', 'miyabibodytexcoord.buf',
      'miyabihaira.ib', 'miyabihairadiffuse.dds', 'miyabihairalightmap.dds',
      'miyabihairamaterialmap.dds', 'miyabihairanormalmap.dds',
      'miyabihairb.ib', 'miyabihairbdiffuse.dds', 'miyabihairblend.buf',
      'miyabihairblightmap.dds', 'miyabihairbmaterialmap.dds',
      'miyabihairbnormalmap.dds', 'miyabihairposition.buf',
      'miyabihairtexcoord.buf',
      'miyabilegsa.ib', 'miyabilegsadiffuse.dds', 'miyabilegsalightmap.dds',
      'miyabilegsamaterialmap.dds', 'miyabilegsanormalmap.dds',
      'miyabilegsblend.buf', 'miyabilegsposition.buf', 'miyabilegstexcoord.buf',
    };

    final result = assess({'Miyabi.ini': ini}, files: shipped);

    expect(result.unreferenced, 2);
    expect(result.missing, isEmpty);
    expect(result.looksLikePatch, isFalse);
  });
}
