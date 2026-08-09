import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/services/ini_resources.dart';

/// Fixtures, not mocks: every string below is the shape 3DMigoto `.ini` files
/// actually take, including the ones that make a working mod *look* broken.
///
/// The last group is a whole real `.ini`, captured from the mod that proved the
/// original rule wrong.
void main() {
  Set<String> pathsOf(Map<String, String> inis) =>
      collectIniReferences(inis).paths;

  group('a declaration is only a requirement once something references it', () {
    test('a referenced section names a file the mod must ship', () {
      final refs = collectIniReferences({
        'ellen.ini': '''
[TextureOverrideBody]
hash = 1234abcd
Resource\\ZZMI\\Diffuse = ref ResourceBodyDiffuse

[ResourceBodyDiffuse]
filename = Body.dds
''',
      });
      expect(refs.paths, {'body.dds'});
      expect(refs.unreferenced, 0);
      expect(refs.references.single.kind, IniReferenceKind.resource);
      expect(refs.references.single.declaredIn, 'ellen.ini');
    });

    test('a section nothing references is inert and is dropped', () {
      // The bug this rule exists for. Authors start from a full character
      // template and delete only the override sections they don't need, leaving
      // the resource *definitions* behind. The loader never opens a resource
      // nothing asks for, so the file's absence costs nothing.
      final refs = collectIniReferences({
        'ellen.ini': '''
[TextureOverrideBody]
Resource\\ZZMI\\Diffuse = ref ResourceBodyDiffuse

[ResourceBodyDiffuse]
filename = Body.dds

[ResourceFaceADiffuse]
filename = FaceADiffuse.dds
''',
      });
      expect(refs.paths, {'body.dds'});
      expect(refs.unreferenced, 1);
    });

    test('a direct slot assignment counts as a reference', () {
      // `ps-t0 = ResourceFoo` and `this = ResourceFoo` are references too, so
      // the match is on any token of any value rather than on a list of
      // recognised syntaxes — a syntax left off that list would silently drop a
      // resource that really is required.
      expect(
        pathsOf({
          'm.ini': '''
[TextureOverrideHair]
ps-t0 = ResourceHairDiffuse

[ResourceHairDiffuse]
filename = Hair.dds
''',
        }),
        {'hair.dds'},
      );
    });

    test('a namespaced reference matches the section it names', () {
      // `namespace = …` renames sections so two mods can both define
      // `[ResourceBody]`; the reference is then written with the namespace on
      // the front, while the declaration still is not.
      expect(
        pathsOf({
          'm.ini': '''
namespace = author\\ellen

[TextureOverrideBody]
Resource\\ZZMI\\Diffuse = ref \\author\\ellen\\ResourceBody

[ResourceBody]
filename = Body.dds
''',
        }),
        {'body.dds'},
      );
    });

    test('a reference in one .ini reaches a declaration in another', () {
      // The whole reason `collectIniReferences` takes a map. Splitting
      // overrides and resources across files is ordinary, and filtering each
      // file against only its own references would drop every resource in the
      // mod.
      final refs = collectIniReferences({
        'overrides.ini': '[TextureOverrideBody]\nthis = ResourceBody',
        'resources.ini': '[ResourceBody]\nfilename = Body.dds',
      });
      expect(refs.paths, {'body.dds'});
      expect(refs.unreferenced, 0);
      expect(refs.declaringInis, {'resources.ini'});
    });

    test('references are matched case-insensitively', () {
      expect(
        pathsOf({
          'm.ini': '[Override]\nthis = resourcebody\n\n[ResourceBody]\n'
              'filename = Body.dds',
        }),
        {'body.dds'},
      );
    });

    test('an include is its own reference and skips the filter', () {
      final refs = collectIniReferences({
        'main.ini': '''
include = parts/hair.ini
include_recursive = parts
''',
      });
      expect(
        refs.references.map((r) => (r.path, r.kind)).toSet(),
        {
          ('parts/hair.ini', IniReferenceKind.include),
          ('parts', IniReferenceKind.includeDirectory),
        },
      );
      expect(refs.unreferenced, 0);
    });
  });

  group('resource paths', () {
    /// Every case below needs a live section, so this wraps one.
    Map<String, String> live(String iniPath, String filename) => {
          iniPath: '[Override]\nthis = ResourceX\n\n[ResourceX]\n'
              'filename = $filename',
        };

    test('a section with no filename is a run-time buffer, not a file', () {
      // The single most available false positive: every 3DMigoto mod has
      // several of these, and counting them would call every mod a patch.
      final refs = collectIniReferences({
        'ellen.ini': '''
[ResourceBodyPosition]
type = Buffer
stride = 40

[ResourceBodyIB]
type = Buffer
format = DXGI_FORMAT_R32_UINT
''',
      });
      expect(refs.references, isEmpty);
      expect(refs.unresolvable, 0);
      expect(refs.unreferenced, 0);
    });

    test('paths resolve against the .ini that declared them', () {
      expect(pathsOf(live('inner/mod.ini', 'tex/Body.dds')),
          {'inner/tex/body.dds'});
    });

    test('backslashes and case are normalised', () {
      expect(pathsOf(live('Mod.INI', r'Textures\Body.DDS')),
          {'textures/body.dds'});
    });

    test('a trailing comment is not part of the path', () {
      expect(pathsOf(live('m.ini', 'Body.dds ; the good one')), {'body.dds'});
    });

    test('CRLF line endings do not leave a stray return on the path', () {
      expect(
        pathsOf({
          'm.ini': '[Override]\r\nthis = ResourceX\r\n\r\n[ResourceX]\r\n'
              'filename = Body.dds\r\n',
        }),
        {'body.dds'},
      );
    });

    test('pathsFrom answers per .ini', () {
      final refs = collectIniReferences({
        'a.ini': '[O]\nthis = R1\n\n[R1]\nfilename = A.dds',
        'b.ini': '[O2]\nthis = R2\n\n[R2]\nfilename = B.dds',
      });
      expect(refs.pathsFrom('a.ini'), {'a.dds'});
      expect(refs.pathsFrom('B.INI'), {'b.dds'});
    });
  });

  group('what cannot be checked is not called missing', () {
    Map<String, String> live(String filename) => {
          'm.ini': '[Override]\nthis = ResourceX\n\n[ResourceX]\n'
              'filename = $filename',
        };

    test('a variable in the path is unresolvable, not a reference', () {
      final refs = collectIniReferences(live(r'$\author\ellen\slot.dds'));
      expect(refs.references, isEmpty);
      expect(refs.unresolvable, 1);
    });

    test('a wildcard is unresolvable', () {
      final refs = collectIniReferences(live('tex/*.dds'));
      expect(refs.references, isEmpty);
      expect(refs.unresolvable, 1);
    });

    test('an absolute path says nothing about this folder', () {
      final refs = collectIniReferences(live(r'C:\mods\other\Body.dds'));
      expect(refs.references, isEmpty);
      expect(refs.unresolvable, 1);
    });

    test('a path climbing out of the folder is refused', () {
      final refs = collectIniReferences({
        'inner/m.ini': '[O]\nthis = R\n\n[R]\n'
            'filename = ../../elsewhere/Body.dds',
      });
      expect(refs.references, isEmpty);
      expect(refs.unresolvable, 1);
    });
  });

  group('a real .ini — Miyabi Transfer Student (GameBanana 700727)', () {
    /// The mod that proved the original rule wrong. Freshly downloaded,
    /// complete, working — and reported as a patch, because two of its 31
    /// resource declarations name textures it does not ship and nothing
    /// references either of them.
    late String text;
    late IniReferences refs;

    setUpAll(() {
      text = File('test/fixtures/ini/miyabi_student.ini').readAsStringSync();
      refs = collectIniReferences({'Miyabi.ini': text});
    });

    test('29 of its 31 resource declarations are referenced', () {
      expect(refs.references.length, 29);
      expect(refs.unreferenced, 2);
    });

    test('the two it drops are the two it does not ship', () {
      // Named explicitly rather than counted: these are the exact strings that
      // produced "this download expects 2 file(s) it doesn't include" over a
      // mod that was fine.
      expect(refs.paths, isNot(contains('miyabifaceadiffuse.dds')));
      expect(refs.paths, isNot(contains('miyabiglowmap.dds')));
      expect(text, contains('[ResourceMiyabiFaceADiffuse]'));
      expect(text, contains('[ResourceMiyabiGlowMap]'));
    });

    test('the buffers it allocates in memory are not counted as files', () {
      expect(refs.paths, isNot(contains('resourcecreditinfo')));
      expect(
        refs.paths.where((p) => p.endsWith('.buf')).length,
        9,
        reason: 'the .buf entries that do carry a filename are still files',
      );
    });
  });
}
