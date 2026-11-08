import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/services/platform_service.dart';
import 'package:mod_manager_flutter/services/platform_service_linux.dart';

/// `gio trash`: the arguments it is given, and what each way it can end means (`docs/deleting-mods.md` §2).
void main() {
  late List<List<String>> calls;

  LinuxPlatformService service(Future<ProcessResult> Function(String, List<String>) run) =>
      LinuxPlatformService(runProcess: (exe, args) {
        calls.add([exe, ...args]);
        return run(exe, args);
      });

  setUp(() => calls = []);

  test('asks gio to trash the path, with no shell and `--` before it', () async {
    final result = await service((_, _) async => ProcessResult(1, 0, '', '')).moveToTrash('/lib/Winter Maid; rm -rf');

    expect(result, TrashResult.trashed);
    expect(calls, [
      ['gio', 'trash', '--', '/lib/Winter Maid; rm -rf'],
    ]);
  });

  test('a path that starts with a dash is not read as an option', () async {
    await service((_, _) async => ProcessResult(1, 0, '', '')).moveToTrash('-rf');

    expect(calls.single, ['gio', 'trash', '--', '-rf']);
  });

  test('a non-zero exit, such as a drive with no trash, is unavailable, and its message is not read', () async {
    final result = await service(
      (_, _) async => ProcessResult(1, 1, '', 'gio: Impossible de mettre à la corbeille : pas de corbeille'),
    ).moveToTrash('/mnt/usb/Winter Maid');

    expect(result, TrashResult.unavailable);
  });

  test('no gio on the machine is unavailable', () async {
    final result = await service((_, _) async => throw const ProcessException('gio', ['trash'], 'not found', 2))
        .moveToTrash('/lib/Winter Maid');

    expect(result, TrashResult.unavailable);
  });

  test('anything else it throws is unavailable too, and never escapes', () async {
    final result = await service((_, _) async => throw StateError('boom')).moveToTrash('/lib/Winter Maid');

    expect(result, TrashResult.unavailable);
  });
}
