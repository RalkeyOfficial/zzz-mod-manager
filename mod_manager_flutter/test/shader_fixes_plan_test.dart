import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/services/shader_fixes/shader_fixes_plan.dart';
import 'package:mod_manager_flutter/services/shader_fixes/zzmi_layout.dart';

void main() {
  const ours = 'uid-ours';
  const theirs = 'uid-theirs';
  const txt = '1f6ab42231416fdb-vs_replace.txt';
  const bin = '1f6ab42231416fdb-vs_replace.bin';

  const folder = '/zzmi/ShaderFixes';

  ShaderEntry entry(String path, List<String> holders,
          {String md5 = 'm', String mod = 'Mod', String inFolder = folder, bool external = false}) =>
      ShaderEntry(
        folder: inFolder,
        path: path,
        md5: md5,
        holders: {for (final uid in holders) uid: mod},
        external: external,
      );

  ShaderPlacementPlan place(List<ShaderSource> sources,
          {Map<String, String?> onDisk = const {}, List<ShaderEntry> record = const []}) =>
      planShaderPlacement(
        uid: ours,
        mod: 'Ours',
        folder: folder,
        sources: sources,
        onDisk: onDisk,
        record: ShaderFixesRecord(record),
      );

  group('placing', () {
    test('free targets are all copied', () {
      final plan = place(const [ShaderSource(txt, 'a'), ShaderSource('JiggleForgeRuntime/motion.hlsl', 'b')]);
      expect((plan as ShaderCopyPlan).copy, hasLength(2));
      expect(plan.held, isEmpty);
    });

    test('different bytes another mod placed refuse the whole enable and name it', () {
      final plan = place(
        const [ShaderSource(txt, 'a'), ShaderSource('other-ps_replace.txt', 'b')],
        onDisk: {txt: 'theirs'},
        record: [entry(txt, [theirs], md5: 'theirs', mod: 'No Outlines')],
      );
      final conflicts = (plan as ShaderRefusedPlan).conflicts;
      expect(conflicts.single.path, txt);
      expect(conflicts.single.owner, 'No Outlines');
    });

    test('different bytes the app does not know refuse, with no owner', () {
      final plan = place(const [ShaderSource(txt, 'a')], onDisk: {txt: 'hand-copied'});
      expect((plan as ShaderRefusedPlan).conflicts.single.owner, isNull);
    });

    test('identical bytes the app does not know are adopted as external, not copied', () {
      final plan = place(const [ShaderSource(txt, 'a'), ShaderSource(bin, 'b')], onDisk: {txt: 'a'});
      plan as ShaderCopyPlan;
      expect(plan.copy.map((c) => c.source.path), [bin]);
      expect(plan.adopted, 1);
      expect(plan.held.single.external, isTrue);
      expect(plan.held.single.holders, {ours: 'Ours'});
    });

    test("identical bytes another mod placed are joined, and stay that mod's", () {
      final plan = place(
        const [ShaderSource(txt, 'a')],
        onDisk: {txt: 'a'},
        record: [entry(txt, [theirs], md5: 'a', mod: 'Theirs')],
      );
      plan as ShaderCopyPlan;
      expect(plan.copy, isEmpty);
      expect(plan.adopted, 0);
      expect(plan.held.single.holders, {theirs: 'Theirs', ours: 'Ours'});
      expect(plan.held.single.external, isFalse);
    });

    test('a target differing only in case is the same file', () {
      final plan = place(const [ShaderSource('1F6AB42231416FDB-vs_replace.txt', 'a')], onDisk: {txt: 'other'});
      expect(plan, isA<ShaderRefusedPlan>());
    });

    test("this mod's own earlier version is overwritten", () {
      final plan = place(
        const [ShaderSource(txt, 'new')],
        onDisk: {txt: 'old'},
        record: [entry(txt, [ours], md5: 'old')],
      );
      expect((plan as ShaderCopyPlan).copy.single.source.path, txt);
    });

    test("this mod's own earlier version, edited since, refuses", () {
      final plan = place(
        const [ShaderSource(txt, 'new')],
        onDisk: {txt: 'edited'},
        record: [entry(txt, [ours], md5: 'old')],
      );
      expect((plan as ShaderRefusedPlan).conflicts.single.owner, isNull);
    });

    test('a file this mod placed in another shader folder is not its own here', () {
      final plan = place(
        const [ShaderSource(txt, 'a')],
        onDisk: {txt: 'm'},
        record: [entry(txt, [ours], inFolder: '/other/ShaderFixes')],
      );
      expect((plan as ShaderRefusedPlan).conflicts.single.owner, isNull);
    });

    test('a record naming another mod for a file that is gone does not block, and needed other bytes', () {
      final plan = place(const [ShaderSource(txt, 'a')], record: [entry(txt, [theirs])]);
      expect((plan as ShaderCopyPlan).copy.single.entry.holders, {ours: 'Ours'});
    });

    test('a file gone from under holders that needed the same bytes is copied back, still theirs too', () {
      final plan = place(const [ShaderSource(txt, 'a')], record: [entry(txt, [theirs], md5: 'a', mod: 'Theirs')]);
      expect((plan as ShaderCopyPlan).copy.single.entry.holders, {theirs: 'Theirs', ours: 'Ours'});
    });

    test('a known file the user replaced with identical bytes is joined as external', () {
      final plan = place(
        const [ShaderSource(txt, 'a')],
        onDisk: {txt: 'a'},
        record: [entry(txt, [theirs], md5: 'b', mod: 'Theirs')],
      );
      final held = (plan as ShaderCopyPlan).held.single;
      expect(held.external, isTrue);
      expect(held.holders, {theirs: 'Theirs', ours: 'Ours'});
      expect(plan.adopted, 0);
    });

    test('an entry with no holders is nobody\'s own older version', () {
      final plan = place(const [ShaderSource(txt, 'new')], onDisk: {txt: 'old'}, record: [entry(txt, [], md5: 'old')]);
      expect(plan, isA<ShaderRefusedPlan>());
    });
  });

  group('removing', () {
    ShaderRemovalPlan remove(List<ShaderEntry> record, Map<String, String?> onDisk) =>
        planShaderRemoval(uid: ours, folder: folder, record: ShaderFixesRecord(record), onDisk: onDisk);

    test('only entries in the folder being cleaned are considered', () {
      final plan = remove([entry(txt, [ours], md5: 'a', inFolder: '/other/ShaderFixes')], {txt: 'a'});
      expect(plan.delete, isEmpty);
      expect(plan.forget, isEmpty);
      expect(plan.forgetOnDelete, isEmpty);
    });

    test('a file still as placed is deleted, and forgotten once it is gone', () {
      final plan = remove([entry(txt, [ours], md5: 'a')], {txt: 'a'});
      expect(plan.delete, [txt]);
      expect(plan.changed, isEmpty);
      expect(plan.forget, isEmpty);
      expect(plan.forgetOnDelete.keys, [txt]);
    });

    test('a file changed since it was placed is left in place', () {
      final plan = remove([entry(txt, [ours], md5: 'a')], {txt: 'edited'});
      expect(plan.delete, isEmpty);
      expect(plan.changed, [txt]);
      expect(plan.forget.map((e) => e.path), [txt]);
    });

    test('a file already gone is only forgotten', () {
      final plan = remove([entry(txt, [ours])], const {});
      expect(plan.delete, isEmpty);
      expect(plan.forget.map((e) => e.path), [txt]);
    });

    test('a file another mod still holds stays, held by that mod alone', () {
      final plan = remove([entry(txt, [ours, theirs], md5: 'a')], {txt: 'a'});
      expect(plan.delete, isEmpty);
      expect(plan.forget, isEmpty);
      expect(plan.update.single.holders.keys, [theirs]);
    });

    test('a file that was already there stays, and is forgotten', () {
      final plan = remove([entry(txt, [ours], md5: 'a', external: true)], {txt: 'a'});
      expect(plan.delete, isEmpty);
      expect(plan.forget.map((e) => e.path), [txt]);
    });

    test("ZZMI's cache beside a removed source goes too, since it would keep the shader applied", () {
      final plan = remove([entry(txt, [ours], md5: 'a')], {txt: 'a', bin: 'cache'});
      expect(plan.delete, [txt, bin]);
    });

    test('a shipped .bin that ZZMI rewrote still goes with its source', () {
      final plan = remove(
        [entry(txt, [ours], md5: 'a'), entry(bin, [ours], md5: 'shipped')],
        {txt: 'a', bin: 'recompiled'},
      );
      expect(plan.delete, unorderedEquals([txt, bin]));
      expect(plan.changed, isEmpty);
      expect(plan.forget, isEmpty);
      expect(plan.forgetOnDelete.keys, unorderedEquals([txt, bin]));
    });

    test("another mod's .bin is not touched", () {
      final plan = remove([entry(txt, [ours], md5: 'a'), entry(bin, [theirs])], {txt: 'a', bin: 'm'});
      expect(plan.delete, [txt]);
    });

    test('a .bin that was already there is not touched', () {
      final plan = remove(
        [entry(txt, [ours], md5: 'a'), entry(bin, [ours], md5: 'b', external: true)],
        {txt: 'a', bin: 'b'},
      );
      expect(plan.delete, [txt]);
    });

    test('a source another mod still holds keeps its cache', () {
      final plan = remove([entry(txt, [ours, theirs], md5: 'a')], {txt: 'a', bin: 'cache'});
      expect(plan.delete, isEmpty);
    });

    test("an edited source keeps its cache, since the shader stays on", () {
      final plan = remove([entry(txt, [ours], md5: 'a')], {txt: 'edited', bin: 'cache'});
      expect(plan.delete, isEmpty);
    });
  });

  test('the record survives a round trip and reads garbage as empty', () {
    final record = ShaderFixesRecord([entry(txt, [ours], md5: 'a', mod: 'Jiggle', external: true)]);
    final back = ShaderFixesRecord.fromJson(record.toJson());
    expect(back.at(folder, txt)?.holders, {ours: 'Jiggle'});
    expect(back.at(folder, txt)?.external, isTrue);
    expect(back.at(folder, txt)?.md5, 'a');
    expect(ShaderFixesRecord.fromJson('nonsense').entries, isEmpty);
    expect(ShaderFixesRecord.fromJson({'files': [3, {'path': 'x'}]}).entries, isEmpty);
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
