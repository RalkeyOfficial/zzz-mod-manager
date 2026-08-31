import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/services/log/system_report.dart';
import 'package:mod_manager_flutter/services/platform_service_factory.dart';
import 'package:mod_manager_flutter/utils/process_probe.dart';

/// What the log says about the machine it is running on.
///
/// The parsing is pure, so the *Windows* shape is asserted here on Linux and the
/// distro parsing would be asserted on Windows — which is the only way either
/// half is ever tested at all, since neither platform can run the other's code.
void main() {
  group('parsing /etc/os-release', () {
    test('reads the two fields the header wants', () {
      // A real file, quotes and all.
      const contents = '''
NAME="CachyOS Linux"
PRETTY_NAME="CachyOS"
ID=cachyos
ID_LIKE=arch
BUILD_ID=rolling
ANSI_COLOR="38;2;23;147;209"
HOME_URL="https://cachyos.org/"
''';

      final fields = parseOsRelease(contents);

      expect(fields['PRETTY_NAME'], 'CachyOS');
      expect(fields['ID'], 'cachyos');
      expect(fields['NAME'], 'CachyOS Linux');
    });

    test('ignores comments and blank lines', () {
      expect(
        parseOsRelease('# a comment\n\nID=arch\n\n  # another\n'),
        {'ID': 'arch'},
      );
    });

    test('leaves an unquoted value alone and strips a quoted one', () {
      final fields = parseOsRelease("A=plain\nB=\"quoted\"\nC='single'");
      expect(fields, {'A': 'plain', 'B': 'quoted', 'C': 'single'});
    });

    test('survives a line that is not a pair at all', () {
      expect(parseOsRelease('nonsense\n=novalue\nID=arch'), {'ID': 'arch'});
    });

    test('a value containing = keeps the rest of itself', () {
      expect(parseOsRelease('ANSI_COLOR="38;2=1"')['ANSI_COLOR'], '38;2=1');
    });
  });

  group('reading a version out of whatever a tool prints', () {
    test('the three real shapes', () {
      expect(parseVersionToken('7-Zip 24.09 (x64) : Copyright (c) 1999-2024'),
          '24.09');
      expect(parseVersionToken('xdotool version 3.20211022.1'),
          '3.20211022.1');
      expect(parseVersionToken('ydotool v1.0.4'), '1.0.4');
    });

    test('an unrecognisable banner is no version, not an error', () {
      // Degrades to "present, version unknown", which is a different fact from
      // absent and has to stay distinguishable from it.
      expect(parseVersionToken('some tool, no numbers here'), isNull);
      expect(parseVersionToken(''), isNull);
    });

    test('a bare integer is not a version', () {
      // Otherwise an exit code or a copyright year becomes the version.
      expect(parseVersionToken('Copyright 2024'), isNull);
    });
  });

  group('the fields a tool contributes', () {
    test('a present tool says which version and where', () {
      expect(
        toolFields(const ToolStatus(
          name: '7-zip',
          state: ToolState.present,
          path: '/usr/bin/7z',
          version: '24.09',
          note: 'system',
        )),
        {
          'tool': '7-zip',
          'state': 'present',
          'version': '24.09',
          'path': '/usr/bin/7z',
          'via': 'system',
        },
      );
    });

    test('present but silent about its version says so explicitly', () {
      // Absent field would read as a caller who forgot; `unknown` is the fact.
      expect(
        toolFields(const ToolStatus(
          name: 'ydotool',
          state: ToolState.present,
          path: '/usr/bin/ydotool',
        ))['version'],
        'unknown',
      );
    });

    test('a missing tool carries no version at all', () {
      final fields = toolFields(const ToolStatus.missing('xdotool'));
      expect(fields['state'], 'missing');
      expect(fields.containsKey('version'), isFalse);
    });

    test('not applicable is its own answer, and explains itself', () {
      // A Windows log saying `xdotool: missing` sends every reader down a
      // dead end — F10 there goes through win32.
      final fields = toolFields(
        const ToolStatus.notApplicable('xdotool', note: 'win32 sends F10'),
      );

      expect(fields['state'], 'notApplicable');
      expect(fields['via'], 'win32 sends F10');
      expect(fields.containsKey('version'), isFalse);
    });
  });

  group('the environment line', () {
    test('a Linux machine names its distro and display server', () {
      expect(
        osFields(const OsDescription(
          name: 'linux',
          version: 'Linux 7.2.2-1-cachyos',
          distro: 'CachyOS',
          distroId: 'cachyos',
          displayServer: 'wayland',
          desktop: 'KDE',
        )),
        {
          'os': 'linux',
          'version': 'Linux 7.2.2-1-cachyos',
          'distro': 'CachyOS',
          'distro_id': 'cachyos',
          'display': 'wayland',
          'desktop': 'KDE',
        },
      );
    });

    test('a Windows machine simply has no distro to name', () {
      // Asserted from Linux, because it can never be asserted anywhere else.
      final fields = osFields(const OsDescription(
        name: 'windows',
        version: '"Windows 10 Pro" 10.0 (Build 19045)',
        displayServer: 'windows-dwm',
      ));

      expect(fields['os'], 'windows');
      expect(fields['display'], 'windows-dwm');
      expect(fields.containsKey('distro'), isFalse,
          reason: 'an empty distro field would look like a failed probe');
      expect(fields.containsKey('desktop'), isFalse);
    });
  });

  group('probing a real process', () {
    const probe = ProcessProbe(timeout: Duration(seconds: 5));

    test('a command that does not exist is null, not an exception', () async {
      expect(
        await probe.run('definitely-not-a-real-binary-xyz', const []),
        isNull,
      );
    });

    test('output comes back decoded', () async {
      final result = await probe.run('echo', const ['hello']);
      expect(result?.stdout.trim(), 'hello');
      expect(result?.exitCode, 0);
      expect(result?.timedOut, isFalse);
    });

    test('a non-zero exit still returns its output', () async {
      // `7z` with no arguments prints its banner and exits non-zero on some
      // builds; the version is in there regardless of what it returned.
      final result = await probe.run('sh', const ['-c', 'echo out; exit 3']);
      expect(result?.exitCode, 3);
      expect(result?.stdout.trim(), 'out');
    });

    test('a hanging command is killed rather than awaited forever', () async {
      final started = DateTime.now();

      final result = await probe.run(
        'sh',
        const ['-c', 'sleep 30'],
        timeout: const Duration(milliseconds: 300),
      );

      expect(result?.timedOut, isTrue);
      expect(
        DateTime.now().difference(started),
        lessThan(const Duration(seconds: 5)),
        reason: 'Process.run().timeout() would have left it running',
      );
    });

    test('a chatty command does not deadlock the drain', () async {
      // The classic: a child that fills the pipe buffer blocks on write and
      // never exits, so an undrained "timeout helper" hangs on it.
      final result = await probe.run(
        'sh',
        const ['-c', 'head -c 200000 /dev/zero | tr "\\0" "x"'],
        timeout: const Duration(seconds: 5),
      );

      expect(result, isNotNull);
      expect(result!.timedOut, isFalse);
      expect(result.exitCode, 0);
    });
  }, skip: Platform.isWindows ? 'posix shell commands' : false);

  group('this actual machine', () {
    test('describes itself without throwing or hanging', () async {
      final report = await PlatformServiceFactory.getInstance()
          .describeSystem()
          .timeout(const Duration(seconds: 20));

      expect(report.os.name, Platform.operatingSystem);
      expect(report.os.version, isNotEmpty);
      expect(report.tools, isNotEmpty);
      expect(
        report.tools.map((t) => t.name),
        contains('7-zip'),
        reason: 'the tool an archive import cannot do without',
      );
    });
  });
}
