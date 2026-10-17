@TestOn('linux')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/services/platform_service.dart';
import 'package:mod_manager_flutter/services/platform_service_linux.dart';
import 'package:path/path.dart' as p;

/// The answers Linux gives without starting anything: a missing file, and files it has no way to run.
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('launch_game_');
    addTearDown(() => dir.delete(recursive: true));
  });

  test('a file that is gone is reported as gone', () async {
    final outcome = await LinuxPlatformService().launchGame(p.join(dir.path, 'missing.desktop'));
    expect(outcome, LaunchOutcome.notFound);
  });

  test('a Windows program is not something Linux can start directly', () async {
    final exe = File(p.join(dir.path, 'XXMI Launcher.exe'))..writeAsStringSync('MZ');
    expect(await LinuxPlatformService().launchGame(exe.path), LaunchOutcome.unsupported);
  });

  test('a Windows program is refused even with an execute bit, as every file on an NTFS mount has', () async {
    for (final name in ['XXMI Launcher.exe', 'start.BAT', 'Game.lnk']) {
      final file = File(p.join(dir.path, name))..writeAsStringSync('MZ');
      await Process.run('chmod', ['+x', file.path]);
      expect((await file.stat()).mode & 0x49, isNot(0), reason: '$name has its execute bit');
      expect(await LinuxPlatformService().launchGame(file.path), LaunchOutcome.unsupported, reason: name);
    }
  });

  test('a script without the execute bit is refused rather than guessed at', () async {
    final script = File(p.join(dir.path, 'start.sh'))..writeAsStringSync('#!/bin/sh\n');
    expect(await LinuxPlatformService().launchGame(script.path), LaunchOutcome.unsupported);
  });
}
