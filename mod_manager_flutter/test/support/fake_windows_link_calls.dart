import 'dart:io';

import 'package:mod_manager_flutter/services/windows/windows_links.dart';
import 'package:mod_manager_flutter/services/windows/windows_paths.dart';

/// The Win32 link calls over a map of links, with switches for what Windows refuses.
class FakeWindowsLinkCalls implements WindowsLinkCalls {
  /// Each link by its path: its kind and the target it was made with.
  final links = <String, ({String kind, String target})>{};

  /// Off as without Developer Mode or admin rights: a symlink fails with [errorPrivilegeNotHeld].
  bool symlinks = true;

  /// The error a symlink fails with for another reason, such as a links folder on exFAT, or null when it doesn't.
  int? symlinkFailure;

  bool junctions = true;

  /// Drive roots that are network drives, such as `Z:\`.
  final networkDrives = <String>{};

  /// Mapped drive roots and the share each is mapped to, such as `Z:\` on `\\nas\share`.
  final mappedDrives = <String, String>{};

  /// Which other paths read as on a network drive, such as a library in a temp directory, which has no drive letter.
  bool Function(String path) onNetwork = (_) => false;

  final unreadable = <String>{};

  /// The next rename into each of these names fails, once.
  final renameFailsTo = <String>{};

  @override
  Future<bool> isLink(String path) async => links.containsKey(path);

  /// As Dart reads it: the stored `\??\` stripped, which leaves a network target as `UNC\…`.
  @override
  Future<String> readTarget(String linkPath) async {
    if (unreadable.contains(linkPath)) throw FileSystemException('unreadable', linkPath);
    final target = links[linkPath]!.target;
    return target.startsWith(r'\\') ? 'UNC\\${target.substring(2)}' : target;
  }

  @override
  Future<void> deleteLink(String linkPath) async => links.remove(linkPath);

  @override
  Future<void> renameLink(String from, String to) async {
    if (renameFailsTo.remove(to) || links.containsKey(to) || !links.containsKey(from)) {
      throw FileSystemException('could not rename', from);
    }
    links[to] = links.remove(from)!;
  }

  @override
  void createDirectorySymlink(String linkPath, String target) {
    if (!symlinks) throw FileSystemException('privilege not held', linkPath, const OSError('', errorPrivilegeNotHeld));
    final failure = symlinkFailure;
    if (failure != null) throw FileSystemException('could not make the symlink', linkPath, OSError('', failure));
    links[linkPath] = (kind: 'symlink', target: target);
  }

  @override
  void createJunction(String linkPath, String target) {
    if (!junctions) throw FileSystemException('could not make the junction', linkPath);
    links[linkPath] = (kind: 'junction', target: target);
  }

  @override
  String? networkPathOf(String driveRoot) => mappedDrives[driveRoot];

  @override
  bool isOnNetworkDrive(String path) {
    final root = driveRootOf(path);
    return onNetwork(path) || networkDrives.contains(root) || mappedDrives.containsKey(root);
  }
}
