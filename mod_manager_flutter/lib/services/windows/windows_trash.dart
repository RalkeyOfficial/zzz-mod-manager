/// Sending a folder to the Recycle Bin through `SHFileOperationW`. Windows only; nothing here is called on Linux.
/// See `docs/deleting-mods.md` §2.
library;

import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import '../platform_service.dart' show TrashResult;

/// The flags of the delete: into the Recycle Bin, a prompt from Windows when the folder would be destroyed instead
/// (a drive with no bin, a folder too large for it), and no progress or error windows. `FOF_NOCONFIRMATION` is left
/// off so that prompt shows.
const int recycleFlags = FOF_ALLOWUNDO | FOF_WANTNUKEWARNING | FOF_SILENT | FOF_NOERRORUI;

/// What `SHFileOperationW` returned: [code] is its result, zero for success, and [aborted] is `fAnyOperationsAborted`,
/// which is set when the user cancelled a prompt.
typedef RecycleCallResult = ({int code, bool aborted});

/// [path] as `SHFileOperationW` reads a source: backslashes only, and a list that ends in two NUL characters, one
/// after the path and one for the list.
String recycleSource(String path) => '${path.replaceAll('/', r'\')}\u0000';

/// [TrashResult] for what the call returned. Only a clean zero is [TrashResult.trashed]: Windows asks about anything
/// it would destroy, so a refusal or a cancelled prompt is [TrashResult.failed] and never offers a permanent delete.
TrashResult trashResultOf(RecycleCallResult result) =>
    result.code == 0 && !result.aborted ? TrashResult.trashed : TrashResult.failed;

/// The Win32 call that recycles, behind a class so the flags and the results are tested against a fake.
class WindowsTrashCalls {
  const WindowsTrashCalls();

  /// Moves the folder [path] to the Recycle Bin, off the UI isolate, since a folder crossing drives blocks.
  Future<RecycleCallResult> recycle(String path) => Isolate.run(() => recycleSync(path));
}

/// The call itself, top-level so [Isolate.run] can take it whole.
RecycleCallResult recycleSync(String path) => using((arena) {
  final operation = arena<SHFILEOPSTRUCT>();
  final from = recycleSource(path).toNativeUtf16(allocator: arena);
  operation.ref
    ..hwnd = 0
    ..wFunc = FO_DELETE
    ..pFrom = from
    ..pTo = nullptr
    ..fFlags = recycleFlags
    ..fAnyOperationsAborted = 0
    ..hNameMappings = nullptr
    ..lpszProgressTitle = nullptr;
  final code = SHFileOperation(operation);
  return (code: code, aborted: operation.ref.fAnyOperationsAborted != 0);
});
