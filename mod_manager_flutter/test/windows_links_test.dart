import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/services/log/log_format.dart';
import 'package:mod_manager_flutter/services/log/log_level.dart';
import 'package:mod_manager_flutter/services/log/log_record.dart';
import 'package:mod_manager_flutter/services/log/log_sinks.dart';
import 'package:mod_manager_flutter/services/log/logger.dart';
import 'package:mod_manager_flutter/services/platform_service.dart';
import 'package:mod_manager_flutter/services/platform_service_linux.dart';
import 'package:mod_manager_flutter/services/platform_service_windows.dart';
import 'package:mod_manager_flutter/services/windows/reparse_points.dart';
import 'package:mod_manager_flutter/services/windows/windows_links.dart' show symlinkError;
import 'package:mod_manager_flutter/services/windows/windows_paths.dart';
import 'package:path/path.dart' as p;

import 'support/fake_windows_link_calls.dart';

/// The UTF-16 code units of [bytes] from [start], [length] bytes of them, read little-endian.
String _utf16At(Uint8List bytes, int start, int length) {
  final data = ByteData.sublistView(bytes);
  return String.fromCharCodes([for (var i = 0; i < length; i += 2) data.getUint16(start + i, Endian.little)]);
}

/// **The parts of the Windows links that need no Windows to check.** Making a junction can't run here, so what decides
/// it is pure and tested on its own, and replacing a link and putting it back run against fake Win32 calls.
void main() {

  group('the reparse data that makes a junction', () {
    const target = r'C:\ZZMI\Library\Ellen&Lycaon (100%)';
    const substitute = '\\??\\$target';

    test('lays out the header, the name offsets and lengths, and both names', () {
      final bytes = mountPointReparseBuffer(target);
      final data = ByteData.sublistView(bytes);

      expect(data.getUint32(0, Endian.little), ioReparseTagMountPoint);
      expect(data.getUint16(6, Endian.little), 0, reason: 'Reserved');

      final substituteOffset = data.getUint16(8, Endian.little);
      final substituteLength = data.getUint16(10, Endian.little);
      final printOffset = data.getUint16(12, Endian.little);
      final printLength = data.getUint16(14, Endian.little);
      expect(substituteOffset, 0);
      expect(substituteLength, substitute.length * 2);
      expect(printOffset, substituteLength + 2, reason: 'past the substitute name and its NUL');
      expect(printLength, target.length * 2);

      // The four offset and length fields, then both names with their NULs.
      final dataLength = 8 + substituteLength + 2 + printLength + 2;
      expect(data.getUint16(4, Endian.little), dataLength);
      expect(bytes.length, 8 + dataLength);

      const pathBuffer = 16;
      expect(_utf16At(bytes, pathBuffer + substituteOffset, substituteLength), substitute);
      expect(data.getUint16(pathBuffer + substituteOffset + substituteLength, Endian.little), 0);
      expect(_utf16At(bytes, pathBuffer + printOffset, printLength), target);
      expect(data.getUint16(pathBuffer + printOffset + printLength, Endian.little), 0);
    });

    test('a name outside the basic plane is counted in UTF-16 units', () {
      const wide = r'D:\Mods\Ellen 🦈';
      final bytes = mountPointReparseBuffer(wide);
      final data = ByteData.sublistView(bytes);
      expect(data.getUint16(14, Endian.little), wide.length * 2);
      expect(_utf16At(bytes, 16 + data.getUint16(12, Endian.little), data.getUint16(14, Endian.little)), wide);
    });

    test('a long-path prefix is dropped, since the substitute name has its own', () {
      final bytes = mountPointReparseBuffer('\\\\?\\$target');
      final data = ByteData.sublistView(bytes);
      expect(_utf16At(bytes, 16, data.getUint16(10, Endian.little)), substitute);
      expect(_utf16At(bytes, 16 + data.getUint16(12, Endian.little), data.getUint16(14, Endian.little)), target);
    });

    test('a target too long for one reparse point is refused', () {
      expect(() => mountPointReparseBuffer('C:\\${'a' * 5000}'), throwsArgumentError);
    });
  });

  group('the long-path form handed to Win32', () {
    test('a drive path takes \\\\?\\, normalised, since that form is taken literally', () {
      expect(longPathForm(r'C:\ZZMI\Mods\Ellen'), r'\\?\C:\ZZMI\Mods\Ellen');
      expect(longPathForm('C:/ZZMI/Mods/../Mods/Ellen'), r'\\?\C:\ZZMI\Mods\Ellen');
    });

    test('a path past 260 characters takes it as any other', () {
      final long = 'C:\\${'a' * 300}\\Ellen';
      expect(longPathForm(long), '\\\\?\\$long');
    });

    test('a network path takes \\\\?\\UNC\\ in place of its \\\\', () {
      expect(longPathForm(r'\\nas\mods\Ellen'), r'\\?\UNC\nas\mods\Ellen');
      expect(longPathForm('//nas/mods/Ellen'), r'\\?\UNC\nas\mods\Ellen');
    });

    test('a path already in that form, a device path or a relative one is left as it is', () {
      expect(longPathForm(r'\\?\C:\ZZMI\Mods\Ellen'), r'\\?\C:\ZZMI\Mods\Ellen');
      expect(longPathForm(r'\\?\UNC\nas\mods\Ellen'), r'\\?\UNC\nas\mods\Ellen');
      expect(longPathForm(r'\\.\C:'), r'\\.\C:');
      expect(longPathForm(r'Mods\Ellen'), r'Mods\Ellen');
    });
  });

  group('making a symlink', () {
    const unprivileged = 0x1 | 0x2; // SYMBOLIC_LINK_FLAG_DIRECTORY | SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE

    /// Runs [symlinkError] over a `CreateSymbolicLinkW` that fails with each of [errors] in turn, then succeeds, and
    /// expects it to report [error] after calls with [flags].
    void expectRun(List<int> errors, {required int? error, required List<int> flags}) {
      final called = <int>[];
      var last = 0;
      final reported = symlinkError((given) {
        called.add(given);
        if (called.length > errors.length) return 1;
        last = errors[called.length - 1];
        return 0;
      }, () => last);
      expect(reported, error);
      expect(called, flags);
    }

    test('is made with the unprivileged flag', () {
      expectRun([], error: null, flags: [unprivileged]);
    });

    test('tries again without the flag only when an old build refuses it', () {
      expectRun([87], error: null, flags: [unprivileged, 0x1]);
      expectRun([87, 1314], error: 1314, flags: [unprivileged, 0x1]);
    });

    test('reports any other first error as it is, with no second try', () {
      expectRun([5], error: 5, flags: [unprivileged]);
      expectRun([183], error: 183, flags: [unprivileged]);
      expectRun([1314], error: 1314, flags: [unprivileged]);
    });
  });

  group('the target a symlink is given', () {
    test('is plain when it fits, so the name shown has no \\\\?\\', () {
      expect(symlinkTargetForm(r'D:\Library\Ellen'), r'D:\Library\Ellen');
      expect(symlinkTargetForm(r'\\nas\mods\Ellen'), r'\\nas\mods\Ellen');
    });

    test('takes the long-path form only when it does not fit', () {
      final long = 'D:\\${'a' * 300}';
      expect(symlinkTargetForm(long), '\\\\?\\$long');
    });

    test('on a mapped drive, is the share in place of the letter', () {
      expect(withNetworkRoot(r'Z:\Library\Ellen', r'\\nas\share'), r'\\nas\share\Library\Ellen');
      expect(withNetworkRoot(r'\\?\Z:\Library\Ellen', r'\\nas\share'), r'\\nas\share\Library\Ellen');
      expect(withNetworkRoot(r'Z:\', r'\\nas\share'), r'\\nas\share');
      expect(withNetworkRoot(r'\\other\x', r'\\nas\share'), r'\\other\x');
    });
  });

  group('network paths', () {
    test('a \\\\server\\share path is one, plainly or in long-path form', () {
      expect(isUncPath(r'\\nas\mods\Ellen'), isTrue);
      expect(isUncPath('//nas/mods/Ellen'), isTrue);
      expect(isUncPath(r'\\?\UNC\nas\mods\Ellen'), isTrue);
      expect(isUncPath(r'\\?\unc\nas\mods\Ellen'), isTrue);
    });

    test('a drive path is not, in either form', () {
      expect(isUncPath(r'C:\ZZMI\Mods\Ellen'), isFalse);
      expect(isUncPath(r'\\?\C:\ZZMI\Mods\Ellen'), isFalse);
      expect(isUncPath(r'\\.\C:'), isFalse);
    });

    test('the drive root of a path is its letter and a backslash', () {
      expect(driveRootOf(r'Z:\Mods\Ellen'), r'Z:\');
      expect(driveRootOf('z:/Mods'), r'z:\');
      expect(driveRootOf(r'\\?\Z:\Mods\Ellen'), r'Z:\');
      expect(driveRootOf(r'\\nas\mods\Ellen'), isNull);
      expect(driveRootOf(r'Mods\Ellen'), isNull);
    });
  });

  group('reading a link target', () {
    test('a network target, which Dart reads as UNC\\…, is the \\\\ path it leads to', () {
      expect(windowsLinkTarget(r'UNC\nas\mods\Ellen', r'C:\ZZMI\Mods'), r'\\nas\mods\Ellen');
      expect(windowsLinkTarget(r'D:\Library\Ellen', r'C:\ZZMI\Mods'), r'D:\Library\Ellen');
      expect(windowsLinkTarget(r'..\Library\Ellen', r'C:\ZZMI\Mods'), r'C:\ZZMI\Library\Ellen');
    });
  });

  group('the links of the Windows platform', () {
    const link = r'C:\ZZMI\Mods\Ellen';
    late FakeWindowsLinkCalls calls;
    late WindowsPlatformService platform;
    late _Capture capture;

    setUp(() {
      calls = FakeWindowsLinkCalls();
      platform = WindowsPlatformService(calls: calls);
      capture = _Capture();
      Log.install(LogRouter(sinks: [capture]));
      addTearDown(() => Log.install(LogRouter()));
    });

    Iterable<String> messages() => capture.records.map((r) => r.message);

    test('a symlink to a network folder reads as the folder it leads to', () async {
      expect(await platform.createModLink(r'\\nas\mods\Ellen', link), isTrue);

      expect(calls.links[link], (kind: 'symlink', target: r'\\nas\mods\Ellen'));
      expect(await platform.readModLinkTarget(link), r'\\nas\mods\Ellen');
    });

    test('a link to a network folder is refused, not made as a junction, where a symlink is refused', () async {
      calls.symlinks = false;

      await expectLater(
        platform.createModLink(r'\\nas\mods\Ellen', link),
        throwsA(isA<NetworkLinkRefused>().having((r) => r.target, 'target', r'\\nas\mods\Ellen')),
      );

      expect(calls.links, isEmpty);
      expect(messages(), contains('link failed'));
    });

    test('a link to a mapped network drive is refused too', () async {
      calls.symlinks = false;
      calls.networkDrives.add(r'Z:\');

      await expectLater(platform.createModLink(r'Z:\Mods\Ellen', link), throwsA(isA<NetworkLinkRefused>()));

      expect(calls.links, isEmpty);
    });

    test('a link to a local folder is made as a junction where a symlink is refused', () async {
      calls.symlinks = false;

      expect(await platform.createModLink(r'D:\Library\Ellen', link), isTrue);

      expect(calls.links[link], (kind: 'junction', target: r'D:\Library\Ellen'));
    });

    test('replacing a link points it at the new folder, with nothing left under a temporary name', () async {
      calls.links[link] = (kind: 'symlink', target: r'D:\Old\Ellen');

      expect(await platform.replaceModLink(link, r'D:\New\Ellen'), isTrue);

      expect(calls.links, {link: (kind: 'symlink', target: r'D:\New\Ellen')});
      final replaced = capture.records.singleWhere((r) => r.message == 'link replaced');
      expect(replaced.fields['from'], r'D:\Old\Ellen');
    });

    test('a working symlink to a share, with Developer Mode turned off since, stays when its new link is refused',
        () async {
      calls.links[link] = (kind: 'symlink', target: r'\\nas\A\Ellen');
      calls.symlinks = false;

      await expectLater(platform.replaceModLink(link, r'\\nas\B\Ellen'), throwsA(isA<NetworkLinkRefused>()));

      expect(calls.links, {link: (kind: 'symlink', target: r'\\nas\A\Ellen')});
    });

    test('creating over a link of that name to a network folder leaves the old link untouched', () async {
      calls.symlinks = false;
      calls.links[link] = (kind: 'junction', target: r'D:\Old\Ellen');

      await expectLater(platform.createModLink(r'\\nas\mods\Ellen', link), throwsA(isA<NetworkLinkRefused>()));

      expect(calls.links, {link: (kind: 'junction', target: r'D:\Old\Ellen')});
    });

    test('a new link that cannot be made leaves the old one untouched', () async {
      calls.symlinks = false;
      calls.junctions = false;
      calls.links[link] = (kind: 'junction', target: r'D:\Old\Ellen');

      expect(await platform.replaceModLink(link, r'D:\New\Ellen'), isFalse);

      expect(calls.links, {link: (kind: 'junction', target: r'D:\Old\Ellen')});
    });

    test('a swap that fails partway renames the old link back', () async {
      calls.links[link] = (kind: 'junction', target: r'D:\Old\Ellen');
      calls.renameFailsTo.add(link);

      expect(await platform.replaceModLink(link, r'D:\New\Ellen'), isFalse);

      expect(calls.links, {link: (kind: 'junction', target: r'D:\Old\Ellen')});
      expect(messages(), containsAllInOrder(['link replace failed', 'link restored']));
    });

    test('a link left under a temporary name by a replace that stopped partway is cleared first', () async {
      String inMods(String name) => 'C:\\ZZMI\\Mods\\$name';
      calls.links[link] = (kind: 'junction', target: r'D:\Old\Ellen');
      calls.links[inMods(replacementLinkName('Ellen'))] = (kind: 'junction', target: r'D:\Stale\Ellen');
      calls.links[inMods(asideLinkName('Ellen'))] = (kind: 'junction', target: r'D:\Stale\Ellen');
      calls.links[inMods(replacementLinkName('Lucy'))] = (kind: 'junction', target: r'D:\Old\Lucy');

      expect(await platform.replaceModLink(link, r'D:\New\Ellen'), isTrue);

      expect(calls.links, {
        link: (kind: 'symlink', target: r'D:\New\Ellen'),
        inMods(replacementLinkName('Lucy')): (kind: 'junction', target: r'D:\Old\Lucy'),
      });
    });

    test('the temporary names start with DISABLED, so ZZMI never loads one left behind', () {
      expect(replacementLinkName('Ellen'), 'DISABLED.zzz-mod-manager.relink.Ellen');
      expect(asideLinkName('Ellen'), 'DISABLED.zzz-mod-manager.relink-old.Ellen');
      expect(isTemporaryLinkName(replacementLinkName('Ellen')), isTrue);
      expect(isTemporaryLinkName(asideLinkName('Ellen')), isTrue);
      expect(isTemporaryLinkName('Ellen'), isFalse);
      expect(isTemporaryLinkName('DISABLED_Ellen'), isFalse);
    });

    // ERROR_INVALID_FUNCTION, as on a links folder on exFAT; ERROR_ACCESS_DENIED; ERROR_ALREADY_EXISTS.
    for (final code in [1, 5, 183]) {
      test('a symlink that fails with error $code is not made as a junction, and that error is logged', () async {
        calls.symlinkFailure = code;

        expect(await platform.createModLink(r'\\nas\mods\Ellen', link), isFalse);
        expect(await platform.createModLink(r'D:\Library\Ellen', link), isFalse);

        expect(calls.links, isEmpty);
        expect(messages(), isNot(contains('symlink refused, falling back to a junction')));
        final failed = capture.records.where((r) => r.message == 'link failed');
        expect(failed, hasLength(2));
        expect(failed.map((r) => (r.error as FileSystemException).osError?.errorCode), [code, code]);
      });
    }

    test('a symlink to a mapped drive leads to its share, and reads as the same folder', () async {
      calls.mappedDrives[r'Z:\'] = r'\\nas\share';

      expect(await platform.createModLink(r'Z:\Library\Ellen', link), isTrue);

      expect(calls.links[link], (kind: 'symlink', target: r'\\nas\share\Library\Ellen'));
      final target = await platform.readModLinkTarget(link);
      expect(platform.samePath(target!, r'Z:\Library\Ellen'), isTrue);
      expect(platform.samePath(target, r'Y:\Library\Ellen'), isFalse);
    });

    test('a mapped drive whose share cannot be read is linked by its letter, and that is logged', () async {
      calls.networkDrives.add(r'Z:\');

      expect(await platform.createModLink(r'Z:\Library\Ellen', link), isTrue);

      expect(calls.links[link], (kind: 'symlink', target: r'Z:\Library\Ellen'));
      expect(messages(), contains('mapped drive not read, linking by its letter'));
    });

    test('a link whose target cannot be read is left alone, and the log says so', () async {
      calls.links[link] = (kind: 'junction', target: r'D:\Old\Ellen');
      calls.unreadable.add(link);

      expect(await platform.replaceModLink(link, r'D:\New\Ellen'), isFalse);

      expect(calls.links[link], (kind: 'junction', target: r'D:\Old\Ellen'));
      expect(messages(), contains('link target unreadable, left alone'));
      expect(messages(), isNot(contains('not a link, left alone')));
    });

    test('a name that is no link is left alone as one', () async {
      expect(await platform.replaceModLink(link, r'D:\New\Ellen'), isFalse);

      expect(messages(), contains('not a link, left alone'));
    });
  });

  group('the dead links in a listing', () {
    late Directory links;

    setUp(() {
      links = Directory.systemTemp.createTempSync('zzz_windows_links_');
      addTearDown(() => links.deleteSync(recursive: true));
    });

    test('keeps a dead link, and not a live link, a plain folder or a file', () async {
      final live = Directory(p.join(links.path, '..', '${p.basename(links.path)}_target'))..createSync();
      addTearDown(() => live.deleteSync());
      Link(p.join(links.path, 'Live')).createSync(live.path);
      Link(p.join(links.path, 'Unplugged')).createSync('/media/drive/Unplugged');
      Directory(p.join(links.path, 'Plain Folder')).createSync();
      File(p.join(links.path, 'notes.txt')).writeAsStringSync('');

      final dead = await readWindowsDeadModLinks(links.path, readTarget: LinuxPlatformService().readModLinkTarget);

      expect(dead, [const DeadModLink(name: 'Unplugged', target: '/media/drive/Unplugged')]);
    });

    test('leaves out a dead link a replace left under a temporary name', () async {
      Link(p.join(links.path, replacementLinkName('Unplugged'))).createSync('/media/drive/Unplugged');
      Link(p.join(links.path, asideLinkName('Unplugged'))).createSync('/media/drive/Unplugged');

      final dead = await readWindowsDeadModLinks(links.path, readTarget: LinuxPlatformService().readModLinkTarget);

      expect(dead, isEmpty);
    });
  });
}

class _Capture extends LogSink {
  final records = <LogRecord>[];

  @override
  LogFormat get format => LogFormat.file;

  @override
  LogLevel get threshold => LogLevel.debug;

  @override
  void write(LogRecord record, String line) => records.add(record);
}
