import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/keybind_info.dart';
import 'package:mod_manager_flutter/screens/dialogs/keybinds_dialog.dart';
import 'package:mod_manager_flutter/services/ini_files_stamp.dart';
import 'package:mod_manager_flutter/services/ini_parser_service.dart';
import 'package:mod_manager_flutter/services/log/log_format.dart';
import 'package:mod_manager_flutter/services/log/log_level.dart';
import 'package:mod_manager_flutter/services/log/log_record.dart';
import 'package:mod_manager_flutter/services/log/log_sinks.dart';
import 'package:mod_manager_flutter/services/log/logger.dart';
import 'package:path/path.dart' as p;

import 'support/temp_library.dart';

/// **A mod's keys are read from the `.ini` files ZZMI loads, and follow those
/// files however they change.**
///
/// The cached keys are reused only while the folder's stamp is equal to the one
/// they were parsed under and settled, so an edit made outside the app, or a
/// Restore that puts back an older modification time, shows on the next read.
void main() {
  late TempLibrary library;

  setUp(() async {
    library = await TempLibrary.create(prefix: 'zzz_keybind_cache_');
  });

  String ini(String key) => '[KeySwap]\nkey = $key\n';

  File iniFile(String mod, String relative) =>
      File(p.joinAll([library.modFolder(mod).path, ...relative.split('/')]));

  /// Writes [contents] and sets the modification time to [age] ago, far enough
  /// back that the read which follows counts as settled.
  void writeAged(String mod, String relative, String contents, Duration age) {
    library.write(mod, relative, contents);
    iniFile(mod, relative).setLastModifiedSync(DateTime.now().subtract(age));
  }

  Future<List<String?>> keysOf(String mod) async {
    final keybinds = await library.service.getModKeybinds(mod);
    return [for (final KeybindInfo bind in keybinds!) bind.keyValue];
  }

  group('a changed .ini shows its new keys on the next read', () {
    test('rewritten with a newer modification time', () async {
      writeAged('Ellen', 'mod.ini', ini('VK_1'), const Duration(hours: 2));
      expect(await keysOf('Ellen'), ['VK_1']);

      writeAged('Ellen', 'mod.ini', ini('VK_F10'), const Duration(hours: 1));
      expect(await keysOf('Ellen'), ['VK_F10']);
    });

    test(
      'rewritten with an older modification time, as a Restore does',
      () async {
        writeAged('Ellen', 'mod.ini', ini('VK_1'), const Duration(hours: 1));
        expect(await keysOf('Ellen'), ['VK_1']);

        writeAged('Ellen', 'mod.ini', ini('VK_2'), const Duration(days: 30));
        expect(await keysOf('Ellen'), ['VK_2']);
      },
    );

    test('a same-size edit within 2 seconds of the read', () async {
      library.write('Ellen', 'mod.ini', ini('VK_1'));
      expect(await keysOf('Ellen'), ['VK_1']);

      library.write('Ellen', 'mod.ini', ini('VK_2'));
      expect(await keysOf('Ellen'), ['VK_2']);
    });
  });

  group('the 2-second rule', () {
    test('an unchanged settled folder reuses its parsed keys', () async {
      writeAged('Ellen', 'mod.ini', ini('VK_1'), const Duration(hours: 1));
      final first = await library.service.getModKeybinds('Ellen');
      final second = await library.service.getModKeybinds('Ellen');
      expect(identical(first, second), isTrue);
    });

    test(
      'a file modified within 2 seconds of the read is parsed again',
      () async {
        library.write('Ellen', 'mod.ini', ini('VK_1'));
        final first = await library.service.getModKeybinds('Ellen');
        final second = await library.service.getModKeybinds('Ellen');
        expect(identical(first, second), isFalse);
      },
    );

    test(
      'a stamp is settled only once every file is 2 seconds from the read',
      () async {
        library.write('Ellen', 'mod.ini', ini('VK_1'));
        final folder = library.modFolder('Ellen').path;
        expect((await IniFilesStamp.take(folder))!.settled, isFalse);

        iniFile(
          'Ellen',
          'mod.ini',
        ).setLastModifiedSync(DateTime.now().add(const Duration(seconds: 1)));
        expect((await IniFilesStamp.take(folder))!.settled, isFalse);

        iniFile('Ellen', 'mod.ini').setLastModifiedSync(
          DateTime.now().subtract(const Duration(seconds: 10)),
        );
        expect((await IniFilesStamp.take(folder))!.settled, isTrue);
      },
    );

    test('a missing folder has no stamp, and logs nothing', () async {
      final capture = _Capture();
      Log.install(LogRouter(sinks: [capture]));
      addTearDown(() => Log.install(LogRouter()));

      expect(
        await IniFilesStamp.take(library.modFolder('Nobody').path),
        isNull,
      );
      expect(capture.records, isEmpty);
    });

    test(
      'a folder that cannot be listed has no stamp, and says why at warning',
      () async {
        library.write('Ellen', 'mod.ini', ini('VK_1'));
        final folder = library.modFolder('Ellen').path;
        await Process.run('chmod', ['000', folder]);
        addTearDown(() => Process.run('chmod', ['755', folder]));
        try {
          Directory(folder).listSync();
          markTestSkipped('chmod does not stop reads for this user');
          return;
        } on FileSystemException {
          // Unreadable, as the test needs.
        }
        final capture = _Capture();
        Log.install(LogRouter(sinks: [capture]));
        addTearDown(() => Log.install(LogRouter()));

        expect(await IniFilesStamp.take(folder), isNull);
        // Every return to the window takes the stamp again; the folder is named once.
        expect(await IniFilesStamp.take(folder), isNull);

        final warning = capture.records.single;
        expect(warning.level, LogLevel.warning);
        expect(warning.fields['folder'], folder);
        expect(warning.error, isA<FileSystemException>());
      },
    );
  });

  group('only the files ZZMI loads', () {
    setUp(() {
      library.write('Ellen', 'mod.ini', '[KeySwap]\nkey = VK_1\n');
      library.write('Ellen', 'DISABLED_x.ini', '[KeyA]\nkey = VK_2\n');
      library.write('Ellen', 'disabled_lower.ini', '[KeyB]\nkey = VK_3\n');
      library.write(
        'Ellen',
        'DISABLED folder/inner.ini',
        '[KeyC]\nkey = VK_4\n',
      );
      library.write('Ellen', 'parts/DISABLED_part.ini', '[KeyD]\nkey = VK_5\n');
      library.write('Ellen', 'desktop.ini', '[KeyE]\nkey = VK_6\n');
      library.write('Ellen', 'Desktop.INI', '[KeyF]\nkey = VK_7\n');
      library.write(
        'Ellen',
        '.zzz-mod-manager/stray.ini',
        '[KeyG]\nkey = VK_8\n',
      );
    });

    test('contribute keys', () async {
      expect(await keysOf('Ellen'), ['VK_1']);
    });

    test('are the only files listed', () async {
      final found = await IniParserService().findIniFiles(
        library.modFolder('Ellen').path,
      );
      expect(found, [iniFile('Ellen', 'mod.ini').path]);
    });
  });

  test(
    'findIniFiles returns the files sorted by their path in the mod',
    () async {
      for (final relative in ['b.ini', 'a/z.ini', 'a.ini', 'C/c.ini']) {
        library.write('Ellen', relative, ini('VK_1'));
      }
      final folder = library.modFolder('Ellen').path;
      final found = await IniParserService().findIniFiles(folder);
      expect(
        [
          for (final file in found)
            p.split(p.relative(file, from: folder)).join('/'),
        ],
        ['C/c.ini', 'a.ini', 'a/z.ini', 'b.ini'],
      );
    },
  );

  test('a same-named mod in another library shows its own keys', () async {
    writeAged('Ellen', 'mod.ini', ini('VK_1'), const Duration(hours: 1));
    expect(await keysOf('Ellen'), ['VK_1']);

    final other = Directory(p.join(library.root.path, 'other library'))
      ..createSync();
    final otherIni = File(p.join(other.path, 'Ellen', 'mod.ini'))
      ..createSync(recursive: true);
    otherIni
      ..writeAsStringSync(ini('VK_9'))
      ..setLastModifiedSync(iniFile('Ellen', 'mod.ini').lastModifiedSync());
    await library.config.setPaths(other.path, library.root.path);

    expect(await keysOf('Ellen'), ['VK_9']);
  });

  group('Change keys', () {
    test('never writes into a DISABLED file', () async {
      library.write('Ellen', 'DISABLED_old.ini', ini('VK_1'));
      library.write('Ellen', 'DISABLED/inner.ini', ini('VK_1'));
      library.write('Ellen', 'mod.ini', ini('VK_1'));

      final result = await writeKeybind(
        library.modFolder('Ellen').path,
        'KeySwap',
        'VK_F5',
      );

      expect(result, KeybindWrite.written);
      expect(library.read('Ellen', 'mod.ini'), ini('VK_F5'));
      expect(library.read('Ellen', 'DISABLED_old.ini'), ini('VK_1'));
      expect(library.read('Ellen', 'DISABLED/inner.ini'), ini('VK_1'));
    });

    test('finds no section when only a DISABLED file has it', () async {
      library.write('Ellen', 'DISABLED_old.ini', ini('VK_1'));
      library.write('Ellen', 'mod.ini', '[TextureOverride]\nhash = 1\n');

      final result = await writeKeybind(
        library.modFolder('Ellen').path,
        'KeySwap',
        'VK_F5',
      );

      expect(result, KeybindWrite.sectionNotFound);
      expect(library.read('Ellen', 'DISABLED_old.ini'), ini('VK_1'));
    });

    test('finds no .ini when every one is DISABLED', () async {
      library.write('Ellen', 'DISABLED_old.ini', ini('VK_1'));

      final result = await writeKeybind(
        library.modFolder('Ellen').path,
        'KeySwap',
        'VK_F5',
      );

      expect(result, KeybindWrite.noIniFiles);
      expect(library.read('Ellen', 'DISABLED_old.ini'), ini('VK_1'));
    });

    test('writes the first file in sorted order', () async {
      library.write('Ellen', 'b.ini', ini('VK_1'));
      library.write('Ellen', 'a.ini', ini('VK_1'));

      await writeKeybind(library.modFolder('Ellen').path, 'KeySwap', 'VK_F5');

      expect(library.read('Ellen', 'a.ini'), ini('VK_F5'));
      expect(library.read('Ellen', 'b.ini'), ini('VK_1'));
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
