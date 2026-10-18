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

  File write(String name, {bool executable = false, String contents = 'MZ'}) {
    final file = File(p.join(dir.path, name))..writeAsStringSync(contents);
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

    final call = starter.calls.first;
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

  test('a runner that cannot be run, such as umu-run not installed, is named, and no lock starts', () async {
    final exe = write('XXMI Launcher.exe');
    final proton = write('proton', executable: true);
    starter.missing = {'umu-run'};
    final result = await launch(exe.path, runner: proton.path, useUmu: true);

    expect(result.outcome, LaunchOutcome.runnerMissing);
    expect(result.program, 'umu-run');
    expect(starter.calls, isEmpty);
  });

  test('Proton started directly runs the proton script in the prefix', () async {
    final exe = write('XXMI Launcher.exe');
    final proton = write('proton', executable: true);
    expect((await launch(exe.path, runner: proton.path, prefix: '/prefixes/HoyoPlay')).outcome, LaunchOutcome.started);

    final call = starter.calls.first;
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

    final call = starter.calls.first;
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

  test("the real starter returns the started program's own process id, not that of the fork that detaches it", () async {
    // What the screen locks rest on: they watch this id until the runner exits.
    final pid = await const DetachedStarter().start('sleep', const ['5'], workingDirectory: dir.path);
    addTearDown(() => Process.killPid(pid));
    expect(File('/proc/$pid/comm').readAsStringSync().trim(), 'sleep');
  });

  group('keeping the screen awake', () {
    // The game is the first call, pid 1000; every call after it is a lock holder.
    List<_Call> locks() => starter.calls.skip(1).toList();

    List<String> watching(String server) => ['sh', '-c', LinuxPlatformService.awakeScript, 'sh', '1000', server];

    // The watcher a lock holder runs: its last six arguments.
    List<String> watcher(_Call lock) => lock.arguments.sublist(lock.arguments.length - 6);

    test("logind's idle lock, GNOME's idle lock and the freedesktop power and screen locks start beside the game", () async {
      final exe = write('XXMI Launcher.exe');
      await launch(exe.path);

      expect(locks().map((call) => call.executable), ['systemd-inhibit', 'gnome-session-inhibit', 'kde-inhibit']);
      expect(locks()[0].arguments, containsAllInOrder(['--what=idle', '--who=Zenith', '--why=Playing Zenless Zone Zero']));
      expect(locks()[1].arguments, containsAllInOrder(['--inhibit', 'idle']));
      expect(locks()[2].arguments, containsAllInOrder(['--power', '--screenSaver']));
    });

    test("under wine each lock waits for the game's runner, then for the prefix's wineserver", () async {
      final exe = write('XXMI Launcher.exe');
      await launch(exe.path, prefix: '/prefixes/zzz');

      for (final lock in locks()) {
        expect(watcher(lock), watching('wineserver'), reason: lock.executable);
        expect(lock.environment, {'WINEPREFIX': '/prefixes/zzz'}, reason: lock.executable);
        expect(lock.workingDirectory, dir.path, reason: lock.executable);
      }
    });

    test('a wine build waits on the wineserver beside it', () async {
      final exe = write('XXMI Launcher.exe');
      final wine = write('wine', executable: true);
      await launch(exe.path, runner: wine.path);

      expect(watcher(locks().first), watching(p.join(dir.path, 'wineserver')));
      expect(locks().first.environment, isEmpty);
    });

    test("Proton started directly waits on its own wineserver, in the prefix's pfx folder", () async {
      final exe = write('XXMI Launcher.exe');
      final proton = write('proton', executable: true);
      await launch(exe.path, runner: proton.path, prefix: '/prefixes/HoyoPlay');

      expect(watcher(locks().first), watching(p.join(dir.path, 'files', 'bin', 'wineserver')));
      expect(locks().first.environment, {'WINEPREFIX': '/prefixes/HoyoPlay/pfx'});
    });

    test('umu-run lasts as long as the game, so there is no wineserver to wait on', () async {
      final exe = write('XXMI Launcher.exe');
      final proton = write('proton', executable: true);
      await launch(exe.path, runner: proton.path, prefix: '/prefixes/HoyoPlay', useUmu: true);

      expect(locks(), hasLength(3));
      expect(watcher(locks().first), watching(''));
      expect(locks().first.environment, isEmpty);
    });

    test('a script gets the locks too, waiting only for the script', () async {
      final script = write('start.sh', executable: true);
      await launch(script.path);

      expect(locks(), hasLength(3));
      expect(watcher(locks().first), watching(''));
    });

    test('with no lock holder installed the game still starts', () async {
      final exe = write('XXMI Launcher.exe');
      starter.missing = {for (final lock in LinuxPlatformService.awakeLocks) lock.first};

      expect((await launch(exe.path)).outcome, LaunchOutcome.started);
      expect(starter.calls.single.executable, 'wine');
    });

    group('the watcher', () {
      late String called;

      // A wineserver that writes down its arguments.
      setUp(() {
        called = p.join(dir.path, 'called');
        write('wineserver', executable: true, contents: '#!/bin/sh\necho "\$@" > "$called"\n');
      });

      Future<int> exitedPid() async {
        final exited = await Process.start('true', const []);
        await exited.exitCode;
        return exited.pid;
      }

      Future<ProcessResult> watch(int pid, String server, {Map<String, String>? environment}) =>
          Process.run('sh', ['-c', LinuxPlatformService.awakeScript, 'sh', '$pid', server], environment: environment);

      test('runs the wineserver with -w once the runner has exited', () async {
        final result = await watch(await exitedPid(), p.join(dir.path, 'wineserver'));

        expect(result.exitCode, 0, reason: '${result.stderr}');
        expect(File(called).readAsStringSync().trim(), '-w');
      });

      test('waits while the runner runs', () async {
        // Up to one 5-second poll.
        final runner = await Process.start('sleep', const ['30']);
        addTearDown(runner.kill);
        final watcher = watch(runner.pid, p.join(dir.path, 'wineserver'));

        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(File(called).existsSync(), isFalse);

        runner.kill();
        await runner.exitCode;
        expect((await watcher).exitCode, 0);
        expect(File(called).readAsStringSync().trim(), '-w');
      });

      test('falls back to the wineserver on PATH when the one given is no file, as for a wrapper script', () async {
        final result = await watch(
          await exitedPid(),
          p.join(dir.path, 'bin', 'wineserver'),
          environment: {'PATH': '${dir.path}:${Platform.environment['PATH']}'},
        );

        expect(result.exitCode, 0, reason: '${result.stderr}');
        expect(File(called).readAsStringSync().trim(), '-w');
      });

      test('ends once the runner has exited when there is no wineserver', () async {
        final result = await watch(await exitedPid(), '');

        expect(result.exitCode, 0, reason: '${result.stderr}');
        expect(File(called).existsSync(), isFalse);
      });
    });
  });
}

typedef _Call = ({String executable, List<String> arguments, String workingDirectory, Map<String, String> environment});

class _RecordingStarter implements DetachedStarter {
  final calls = <_Call>[];

  /// Programs that throw as if not installed.
  Set<String> missing = {};

  @override
  Future<int> start(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    Map<String, String> environment = const {},
  }) async {
    if (missing.contains(executable)) throw ProcessException(executable, arguments, 'No such file or directory', 2);
    final pid = 1000 + calls.length;
    calls.add((executable: executable, arguments: arguments, workingDirectory: workingDirectory, environment: environment));
    return pid;
  }
}
