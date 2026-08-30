import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/services/platform_service_linux.dart';
import 'package:mod_manager_flutter/services/platform_service_windows.dart';

/// Which 7-Zip build each portable package ships.
///
/// The names are load-bearing rather than cosmetic, and getting one wrong fails
/// in the least visible way: the app finds a binary, runs it, and it declines
/// the one format the bundle exists for.
void main() {
  test('neither platform ships a reduced-format build', () {
    // 7-Zip's own readme: "7za.exe - standalone console version of 7-Zip with
    // reduced formats support". The formats it drops include RAR — which is
    // most of GameBanana, and the entire reason for bundling anything.
    for (final names in [
      LinuxPlatformService().bundledSevenZipNames,
      WindowsPlatformService().bundledSevenZipNames,
    ]) {
      expect(names.any((n) => n.startsWith('7za')), isFalse,
          reason: '7za cannot read RAR: $names');
      expect(names, isNotEmpty);
    }
  });

  test('Linux prefers the statically linked build', () {
    // A portable tarball runs on whatever libstdc++ the target has, which is
    // exactly what a dynamic binary cannot promise.
    final names = LinuxPlatformService().bundledSevenZipNames;
    expect(names.first, '7zzs');
    expect(names, contains('7zz'));
  });

  test('Windows prefers 7z.exe, which needs 7z.dll beside it', () {
    final names = WindowsPlatformService().bundledSevenZipNames;
    expect(names.first, '7z.exe');
  });

  test('no name carries a directory, since they are joined onto one', () {
    for (final names in [
      LinuxPlatformService().bundledSevenZipNames,
      WindowsPlatformService().bundledSevenZipNames,
    ]) {
      for (final name in names) {
        expect(name, isNot(contains('/')));
        expect(name, isNot(contains(r'\')));
      }
    }
  });
}
