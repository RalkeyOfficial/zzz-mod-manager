import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/services/platform_service.dart';
import 'package:mod_manager_flutter/services/platform_service_windows.dart';
import 'package:mod_manager_flutter/services/windows/windows_trash.dart';
import 'package:win32/win32.dart';

/// The Recycle Bin call, run against a fake on Linux: its flags, its path, and how its results are read. Not yet run
/// on Windows (`docs/deleting-mods.md` §2).
class _FakeTrashCalls implements WindowsTrashCalls {
  _FakeTrashCalls(this.result);

  RecycleCallResult result;
  final paths = <String>[];

  @override
  Future<RecycleCallResult> recycle(String path) async {
    paths.add(path);
    return result;
  }
}

void main() {
  test('goes to the Recycle Bin, asks about anything it would destroy, and shows no progress or error window', () {
    expect(recycleFlags, FOF_ALLOWUNDO | FOF_WANTNUKEWARNING | FOF_SILENT | FOF_NOERRORUI);
    expect(recycleFlags & FOF_NOCONFIRMATION, 0, reason: 'Windows keeps its own prompt');
    expect(recycleFlags & FOF_ALLOWUNDO, isNonZero, reason: 'without it the folder is deleted for good');
  });

  group('the path', () {
    test('ends in the two NUL characters a file list does', () {
      final path = recycleSource(r'C:\Mods\Winter Maid');

      expect(path, '${r'C:\Mods\Winter Maid'}\u0000');
      // toNativeUtf16 adds the second.
    });

    test('has backslashes only', () {
      expect(recycleSource('C:/Mods/Winter Maid'), '${r'C:\Mods\Winter Maid'}\u0000');
    });
  });

  group('the result', () {
    test('only a clean zero is trashed', () {
      expect(trashResultOf((code: 0, aborted: false)), TrashResult.trashed);
    });

    test('a cancelled prompt is failed, though the call returned zero', () {
      expect(trashResultOf((code: 0, aborted: true)), TrashResult.failed);
    });

    test('an error code is failed: a file in use, or a path over 260 characters', () {
      expect(trashResultOf((code: 0x20, aborted: false)), TrashResult.failed);
      expect(trashResultOf((code: 0x7C, aborted: false)), TrashResult.failed);
    });
  });

  group('the platform service', () {
    test('hands the folder over as it is, and answers with the result', () async {
      final calls = _FakeTrashCalls((code: 0, aborted: false));
      final service = WindowsPlatformService(trash: calls);

      expect(await service.moveToTrash(r'C:\Mods\Winter Maid'), TrashResult.trashed);
      expect(calls.paths, [r'C:\Mods\Winter Maid']);
    });

    test('a long path that the call refuses is failed, not worked around', () async {
      final long = 'C:\\Mods\\${'a' * 300}';
      final calls = _FakeTrashCalls((code: 0x7C, aborted: false));

      expect(await WindowsPlatformService(trash: calls).moveToTrash(long), TrashResult.failed);
      expect(calls.paths, [long], reason: 'no \\\\?\\ form, which SHFileOperationW does not take');
    });

    test('a call that throws is failed, and never reaches the caller', () async {
      final service = WindowsPlatformService(trash: _ThrowingTrashCalls());

      expect(await service.moveToTrash(r'C:\Mods\Winter Maid'), TrashResult.failed);
    });
  });
}

class _ThrowingTrashCalls implements WindowsTrashCalls {
  @override
  Future<RecycleCallResult> recycle(String path) async => throw StateError('no shell32');
}
