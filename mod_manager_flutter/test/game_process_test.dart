import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/services/platform_service.dart';

/// What counts as the game running: a process of `ZenlessZoneZero.exe`, and nothing that merely says `zzz` or names
/// the file in passing.
void main() {
  group('a process on Linux', () {
    test('is the game when its program, or the file Wine was given, is ZenlessZoneZero.exe', () {
      expect(commandRunsGame('Z:\\home\\al\\Games\\ZenlessZoneZero Game\\ZenlessZoneZero.exe\u0000-popupwindow'), isTrue);
      expect(commandRunsGame('C:\\Games\\ZenlessZoneZero.exe\u0000'), isTrue);
      expect(commandRunsGame('wine\u0000/home/al/Games/ZenlessZoneZero Game/ZenlessZoneZero.exe\u0000-popupwindow'), isTrue);
      expect(commandRunsGame('Z:\\Games\\zenlesszonezero.EXE'), isTrue, reason: 'the case is Windows\'s to choose');
    });

    test('is not the game when it only mentions the file', () {
      expect(commandRunsGame('less\u0000/home/al/ZenlessZoneZero.exe.log'), isFalse);
      expect(commandRunsGame('grep\u0000ZenlessZoneZero.exe\u0000/proc'), isFalse);
      expect(commandRunsGame('nano\u0000/home/al/Games/notes about ZenlessZoneZero.exe.txt'), isFalse);
      expect(commandRunsGame('/usr/bin/code\u0000--goto\u0000/x/ZenlessZoneZero.exe:1'), isFalse);
    });

    test('is not the game when it is the app or anything else with zzz in its name', () {
      expect(commandRunsGame('/usr/bin/zzz-mod-manager'), isFalse);
      expect(commandRunsGame('/opt/zzz-mod-manager-git/mod_manager_flutter\u0000'), isFalse);
      expect(commandRunsGame('/home/al/Games/zzz-prefix/umu-run\u0000'), isFalse);
      expect(commandRunsGame(''), isFalse);
    });
  });

  group('tasklist on Windows', () {
    test('has a row for the game', () {
      expect(tasklistShowsGame('\r\nZenlessZoneZero.exe          14882 Console   1  7,102,340 K\r\n'), isTrue);
    });

    test('has none when nothing matches, in any language', () {
      expect(tasklistShowsGame('INFO: No tasks are running which match the specified criteria.'), isFalse);
      expect(tasklistShowsGame('ІНФОРМАЦІЯ: немає запущених завдань, що відповідають вказаним критеріям.'), isFalse);
      expect(tasklistShowsGame(''), isFalse);
    });
  });
}
