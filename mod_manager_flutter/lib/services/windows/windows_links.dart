/// Making and reading the links in the game's mods folder through the Win32 API, with no shell in between: a path
/// is handed over as it is, so `&`, `^` or `%` in a folder name are only characters of the name.
/// Windows only; nothing here is called on Linux.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import '../log/logger.dart';
import 'reparse_points.dart';
import 'windows_paths.dart';

final Logger _files = Logger('fileops');

/// A [FileSystemException] for a failed call on [path], carrying the error the call left.
FileSystemException _failure(String message, String path) => FileSystemException(message, path, OSError('', GetLastError()));

/// The error a symlink fails with for want of rights: on Windows without Developer Mode or admin rights.
const int errorPrivilegeNotHeld = ERROR_PRIVILEGE_NOT_HELD;

/// The error making a directory symlink through [create], `CreateSymbolicLinkW` given its flags, ends in, read by
/// [lastError], or null when it is made. Windows 10 before build 14972 refuses the unprivileged flag with
/// `ERROR_INVALID_PARAMETER`, so only that is tried once more without it, as dart:io's `Link.create` does; any other
/// error is the one reported, so a symlink failing for another reason never reads as wanting Developer Mode.
int? symlinkError(int Function(int flags) create, int Function() lastError) {
  if (create(SYMBOLIC_LINK_FLAG_DIRECTORY | SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE) != 0) return null;
  final first = lastError();
  if (first != ERROR_INVALID_PARAMETER) return first;
  if (create(SYMBOLIC_LINK_FLAG_DIRECTORY) != 0) return null;
  return lastError();
}

/// The calls that make, read, move and remove the links, behind one class so the logic that replaces a link can run
/// against a fake. Each path handed to Win32 goes in its long-path form ([longPathForm]).
class WindowsLinkCalls {
  const WindowsLinkCalls();

  /// Dart reports every reparse point but a Unix socket as a link when not following links, so a junction is one as
  /// much as a symlink.
  Future<bool> isLink(String path) => FileSystemEntity.isLink(path);

  /// The target as Dart reads it: the stored name with its `\??\` stripped ([windowsLinkTarget]).
  Future<String> readTarget(String linkPath) => Link(linkPath).target();

  Future<void> deleteLink(String linkPath) => Link(linkPath).delete();

  /// Moves the link at [from] itself, never what it leads to, to [to], a name that must be free.
  Future<void> renameLink(String from, String to) => Link(from).rename(to);

  /// Makes a directory symlink at [linkPath] to [target], an absolute path, whether [target] exists or not. Throws a
  /// [FileSystemException] when it can't, carrying [errorPrivilegeNotHeld] without Developer Mode or admin rights.
  /// [target] goes in plainly where it fits ([symlinkTargetForm]), since the symlink keeps it as the name shown.
  void createDirectorySymlink(String linkPath, String target) {
    using((arena) {
      final link = longPathForm(linkPath).toNativeUtf16(allocator: arena);
      final to = symlinkTargetForm(target).toNativeUtf16(allocator: arena);
      final error = symlinkError((flags) => CreateSymbolicLink(link, to, flags), GetLastError);
      if (error != null) throw FileSystemException('could not make the symlink', linkPath, OSError('', error));
    });
  }

  /// Makes a junction at [linkPath] to [target], an absolute local path, whether [target] exists or not: an empty
  /// folder whose reparse point is set to a [mountPointReparseBuffer]. Throws a [FileSystemException] when it can't,
  /// with nothing left at [linkPath] unless removing the folder failed too, which is logged.
  void createJunction(String linkPath, String target) {
    final buffer = mountPointReparseBuffer(target);
    using((arena) {
      final link = longPathForm(linkPath).toNativeUtf16(allocator: arena);
      if (CreateDirectory(link, nullptr) == 0) throw _failure('could not make the junction folder', linkPath);
      var made = false;
      try {
        final handle = CreateFile(
          link,
          GENERIC_WRITE,
          FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
          nullptr,
          OPEN_EXISTING,
          FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS,
          0,
        );
        if (handle == INVALID_HANDLE_VALUE) throw _failure('could not open the junction folder', linkPath);
        try {
          final data = arena<Uint8>(buffer.length);
          data.asTypedList(buffer.length).setAll(0, buffer);
          final returned = arena<Uint32>();
          final set = DeviceIoControl(handle, FSCTL_SET_REPARSE_POINT, data, buffer.length, nullptr, 0, returned, nullptr);
          if (set == 0) throw _failure('could not make the junction', linkPath);
          made = true;
        } finally {
          CloseHandle(handle);
        }
      } finally {
        if (!made && RemoveDirectory(link) == 0) {
          // An empty folder is left at the link's name, and the mod of that name reads off.
          _files.warning('junction folder left behind', error: OSError('', GetLastError()), fields: {'path': linkPath});
        }
      }
    });
  }

  /// The share the drive at [driveRoot], such as `Z:\`, is mapped to, such as `\\nas\share`, by `WNetGetConnectionW`,
  /// or null when it is no mapped drive or the call fails.
  String? networkPathOf(String driveRoot) {
    final mpr = DynamicLibrary.open('mpr.dll');
    final getConnection = mpr.lookupFunction<Uint32 Function(Pointer<Utf16>, Pointer<Utf16>, Pointer<Uint32>),
        int Function(Pointer<Utf16>, Pointer<Utf16>, Pointer<Uint32>)>('WNetGetConnectionW');
    return using((arena) {
      // The local name is the letter and colon, with no backslash.
      final local = driveRoot.substring(0, 2).toNativeUtf16(allocator: arena);
      final length = arena<Uint32>()..value = MAX_PATH;
      var remote = arena<Uint16>(length.value).cast<Utf16>();
      var result = getConnection(local, remote, length);
      if (result == ERROR_MORE_DATA) {
        remote = arena<Uint16>(length.value).cast<Utf16>();
        result = getConnection(local, remote, length);
      }
      return result == NO_ERROR ? remote.toDartString() : null;
    });
  }

  /// Whether [path] is on a mapped network drive, by `GetDriveTypeW` on its drive root. False for a path with no
  /// drive letter.
  bool isOnNetworkDrive(String path) {
    final root = driveRootOf(path);
    if (root == null) return false;
    return using((arena) => GetDriveType(root.toNativeUtf16(allocator: arena)) == DRIVE_REMOTE);
  }
}
