import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/services/shader_fixes/shader_fixes_plan.dart';
import 'package:mod_manager_flutter/services/shader_fixes/zzmi_layout.dart';

void main() {
  const ours = 'uid-ours';
  const theirs = 'uid-theirs';
  const txt = '1f6ab42231416fdb-vs_replace.txt';
  const bin = '1f6ab42231416fdb-vs_replace.bin';

  const folder = '/zzmi/ShaderFixes';

  ShaderPlacement placed(String path, String uid,
          {String md5 = 'm', String mod = 'Mod', String inFolder = folder}) =>
      ShaderPlacement(folder: inFolder, path: path, uid: uid, mod: mod, md5: md5);

  group('placing', () {
    test('free targets are all copied', () {
      final plan = planShaderPlacement(
        uid: ours,
        folder: folder,
        sources: const [ShaderSource(txt, 'a'), ShaderSource('JiggleForgeRuntime/motion.hlsl', 'b')],
        existing: const {},
        record: ShaderFixesRecord(),
      );
      expect((plan as ShaderCopyPlan).sources, hasLength(2));
    });

    test("a target another mod placed refuses the whole enable and names it", () {
      final plan = planShaderPlacement(
        uid: ours,
        folder: folder,
        sources: const [ShaderSource(txt, 'a'), ShaderSource('other-ps_replace.txt', 'b')],
        existing: {ShaderFixesRecord.keyOf(txt)},
        record: ShaderFixesRecord([placed(txt, theirs, mod: 'No Outlines')]),
      );
      final conflicts = (plan as ShaderRefusedPlan).conflicts;
      expect(conflicts.single.path, txt);
      expect(conflicts.single.owner, 'No Outlines');
    });

    test('a file the app did not place refuses, with no owner', () {
      final plan = planShaderPlacement(
        uid: ours,
        folder: folder,
        sources: const [ShaderSource(txt, 'a')],
        existing: {ShaderFixesRecord.keyOf(txt)},
        record: ShaderFixesRecord(),
      );
      expect((plan as ShaderRefusedPlan).conflicts.single.owner, isNull);
    });

    test('a target differing only in case is the same file', () {
      final plan = planShaderPlacement(
        uid: ours,
        folder: folder,
        sources: const [ShaderSource('1F6AB42231416FDB-vs_replace.txt', 'a')],
        existing: {ShaderFixesRecord.keyOf(txt)},
        record: ShaderFixesRecord(),
      );
      expect(plan, isA<ShaderRefusedPlan>());
    });

    test("this mod's own earlier placement is overwritten", () {
      final plan = planShaderPlacement(
        uid: ours,
        folder: folder,
        sources: const [ShaderSource(txt, 'new')],
        existing: {ShaderFixesRecord.keyOf(txt)},
        record: ShaderFixesRecord([placed(txt, ours, md5: 'old')]),
      );
      expect(plan, isA<ShaderCopyPlan>());
    });

    test('a file this mod placed in another shader folder is not its own here', () {
      final plan = planShaderPlacement(
        uid: ours,
        folder: folder,
        sources: const [ShaderSource(txt, 'a')],
        existing: {ShaderFixesRecord.keyOf(txt)},
        record: ShaderFixesRecord([placed(txt, ours, inFolder: '/other/ShaderFixes')]),
      );
      expect((plan as ShaderRefusedPlan).conflicts.single.owner, isNull);
    });

    test('a record naming another mod for a file that is gone does not block', () {
      final plan = planShaderPlacement(
        uid: ours,
        folder: folder,
        sources: const [ShaderSource(txt, 'a')],
        existing: const {},
        record: ShaderFixesRecord([placed(txt, theirs)]),
      );
      expect(plan, isA<ShaderCopyPlan>());
    });
  });

  group('removing', () {
    test('only placements in the folder being cleaned are considered', () {
      final plan = planShaderRemoval(
        uid: ours,
        folder: folder,
        record: ShaderFixesRecord([placed(txt, ours, md5: 'a', inFolder: '/other/ShaderFixes')]),
        onDisk: {ShaderFixesRecord.keyOf(txt): 'a'},
      );
      expect(plan.delete, isEmpty);
      expect(plan.forget, isEmpty);
    });

    test('a file still as placed is deleted and forgotten', () {
      final plan = planShaderRemoval(
        uid: ours,
        folder: folder,
        record: ShaderFixesRecord([placed(txt, ours, md5: 'a')]),
        onDisk: {ShaderFixesRecord.keyOf(txt): 'a'},
      );
      expect(plan.delete, [txt]);
      expect(plan.changed, isEmpty);
      expect(plan.forget.map((f) => f.path), [txt]);
    });

    test('a file changed since it was placed is left in place', () {
      final plan = planShaderRemoval(
        uid: ours,
        folder: folder,
        record: ShaderFixesRecord([placed(txt, ours, md5: 'a')]),
        onDisk: {ShaderFixesRecord.keyOf(txt): 'edited'},
      );
      expect(plan.delete, isEmpty);
      expect(plan.changed, [txt]);
      expect(plan.forget.map((f) => f.path), [txt]);
    });

    test('a file already gone is only forgotten', () {
      final plan = planShaderRemoval(
        uid: ours,
        folder: folder,
        record: ShaderFixesRecord([placed(txt, ours)]),
        onDisk: const {},
      );
      expect(plan.delete, isEmpty);
      expect(plan.forget.map((f) => f.path), [txt]);
    });

    test("ZZMI's cache beside a removed source goes too, since it would keep the shader applied", () {
      final plan = planShaderRemoval(
        uid: ours,
        folder: folder,
        record: ShaderFixesRecord([placed(txt, ours, md5: 'a')]),
        onDisk: {ShaderFixesRecord.keyOf(txt): 'a', ShaderFixesRecord.keyOf(bin): 'cache'},
      );
      expect(plan.delete, [txt, bin]);
    });

    test('a shipped .bin that ZZMI rewrote still goes with its source', () {
      final plan = planShaderRemoval(
        uid: ours,
        folder: folder,
        record: ShaderFixesRecord([placed(txt, ours, md5: 'a'), placed(bin, ours, md5: 'shipped')]),
        onDisk: {ShaderFixesRecord.keyOf(txt): 'a', ShaderFixesRecord.keyOf(bin): 'recompiled'},
      );
      expect(plan.delete, unorderedEquals([txt, bin]));
      expect(plan.changed, isEmpty);
    });

    test("another mod's .bin is not touched", () {
      final plan = planShaderRemoval(
        uid: ours,
        folder: folder,
        record: ShaderFixesRecord([placed(txt, ours, md5: 'a'), placed(bin, theirs)]),
        onDisk: {ShaderFixesRecord.keyOf(txt): 'a', ShaderFixesRecord.keyOf(bin): 'm'},
      );
      expect(plan.delete, [txt]);
    });

    test("an edited source keeps its cache, since the shader stays on", () {
      final plan = planShaderRemoval(
        uid: ours,
        folder: folder,
        record: ShaderFixesRecord([placed(txt, ours, md5: 'a')]),
        onDisk: {ShaderFixesRecord.keyOf(txt): 'edited', ShaderFixesRecord.keyOf(bin): 'cache'},
      );
      expect(plan.delete, isEmpty);
    });
  });

  test('the record survives a round trip and reads garbage as empty', () {
    final record = ShaderFixesRecord([placed(txt, ours, md5: 'a', mod: 'Jiggle')]);
    final back = ShaderFixesRecord.fromJson(record.toJson());
    expect(back.at(folder, txt)?.uid, ours);
    expect(back.at(folder, txt)?.mod, 'Jiggle');
    expect(ShaderFixesRecord.fromJson('nonsense').placements, isEmpty);
    expect(ShaderFixesRecord.fromJson({'files': [3, {'path': 'x'}]}).placements, isEmpty);
  });

  group('the shader folder named in d3dx.ini', () {
    test('defaults to ShaderFixes', () {
      expect(overrideDirectoryFrom('[Loader]\ntarget = ZenlessZoneZero.exe\n'), 'ShaderFixes');
    });

    test('reads override_directory from [Rendering] only', () {
      const ini = '[Loader]\noverride_directory = Wrong\n'
          '[Rendering]\n; override_directory = Commented\n'
          'OVERRIDE_DIRECTORY = MyShaders\r\n';
      expect(overrideDirectoryFrom(ini), 'MyShaders');
    });
  });
}
