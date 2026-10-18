@TestOn('linux')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/services/platform_service.dart';
import 'package:mod_manager_flutter/services/platform_service_linux.dart';
import 'package:mod_manager_flutter/utils/detached_starter.dart';
import 'package:path/path.dart' as p;

/// What Linux starts for each kind of file, seen through a starter that records instead of starting.
void main() {
  late Directory dir;
  late _RecordingStarter starter;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('launch_game_');
    addTearDown(() => dir.delete(recursive: true));
    starter = _RecordingStarter();
  });

  File write(String name, {bool executable = false}) {
    final file = File(p.join(dir.path, name))..writeAsStringSync('MZ');
    if (executable) Process.runSync('chmod', ['+x', file.path]);
    return file;
  }

  Future<LaunchResult> launch(
    String path, {
    String arguments = '--nogui --xxmi ZZMI',
    String runner = '',
    String prefix = '',
    bool useUmu = false,
  }) => LinuxPlatformService().launchGame(
    LaunchRequest(executable: path, arguments: arguments, runner: runner, prefix: prefix, useUmu: useUmu),
    starter: starter,
  );

  test('a file that is gone is reported as gone', () async {
    expect((await launch(p.join(dir.path, 'XXMI Launcher.exe'))).outcome, LaunchOutcome.notFound);
    expect(starter.calls, isEmpty);
  });

  test("the XXMI Launcher runs under wine from its own folder, with the arguments", () async {
    final exe = write('XXMI Launcher.exe');
    expect((await launch(exe.path)).outcome, LaunchOutcome.started);

    final call = starter.calls.single;
    expect(call.executable, 'wine');
    expect(call.arguments, [exe.path, '--nogui', '--xxmi', 'ZZMI']);
    expect(call.workingDirectory, dir.path);
  });

  test('a runner file that is gone is named, and nothing starts', () async {
    final exe = write('XXMI Launcher.exe');
    final missing = p.join(dir.path, 'proton');
    final result = await launch(exe.path, runner: missing);

    expect(result.outcome, LaunchOutcome.runnerMissing);
    expect(result.program, missing);
    expect(starter.calls, isEmpty);
  });

  test('a runner that cannot be run, such as umu-run not installed, is named', () async {
    final exe = write('XXMI Launcher.exe');
    final proton = write('proton', executable: true);
    starter.fails = true;
    final result = await launch(exe.path, runner: proton.path, useUmu: true);

    expect(result.outcome, LaunchOutcome.runnerMissing);
    expect(result.program, 'umu-run');
  });

  test('Proton started directly runs the proton script in the prefix', () async {
    final exe = write('XXMI Launcher.exe');
    final proton = write('proton', executable: true);
    expect((await launch(exe.path, runner: proton.path, prefix: '/prefixes/HoyoPlay')).outcome, LaunchOutcome.started);

    final call = starter.calls.single;
    expect(call.executable, proton.path);
    expect(call.arguments.take(2), ['waitforexitandrun', exe.path]);
    expect(call.environment['STEAM_COMPAT_DATA_PATH'], '/prefixes/HoyoPlay');
  });

  test('Proton started directly without a prefix asks for one, and nothing starts', () async {
    final exe = write('XXMI Launcher.exe');
    final proton = write('proton', executable: true);
    expect((await launch(exe.path, runner: proton.path)).outcome, LaunchOutcome.prefixRequired);
    expect(starter.calls, isEmpty);
  });

  test('an executable script runs directly with the arguments and no Wine', () async {
    final script = write('start.sh', executable: true);
    expect((await launch(script.path, arguments: '-a "b c"')).outcome, LaunchOutcome.started);

    final call = starter.calls.single;
    expect(call.executable, script.path);
    expect(call.arguments, ['-a', 'b c']);
    expect(call.environment, isEmpty);
  });

  test('a shortcut or Windows script is refused even with an execute bit, as on an NTFS mount', () async {
    for (final name in ['Game.desktop', 'start.BAT', 'Game.lnk']) {
      final file = write(name, executable: true);
      expect((await file.stat()).mode & 0x49, isNot(0), reason: '$name has its execute bit');
      expect((await launch(file.path)).outcome, LaunchOutcome.unsupported, reason: name);
    }
    expect(starter.calls, isEmpty);
  });

  test('a script without the execute bit is refused rather than guessed at', () async {
    expect((await launch(write('start.sh').path)).outcome, LaunchOutcome.unsupported);
  });

  test('the real starter reports a program that is not there as a ProcessException', () async {
    // What runnerMissing rests on: a detached start of a missing program throws instead of failing silently.
    await expectLater(
      const DetachedStarter().start('zenith-no-such-program', const [], workingDirectory: dir.path),
      throwsA(isA<ProcessException>()),
    );
  });
}

class _RecordingStarter implements DetachedStarter {
  final calls = <({String executable, List<String> arguments, String workingDirectory, Map<String, String> environment})>[];
  bool fails = false;

  @override
  Future<void> start(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    Map<String, String> environment = const {},
  }) async {
    if (fails) throw ProcessException(executable, arguments, 'No such file or directory', 2);
    calls.add((executable: executable, arguments: arguments, workingDirectory: workingDirectory, environment: environment));
  }
}
