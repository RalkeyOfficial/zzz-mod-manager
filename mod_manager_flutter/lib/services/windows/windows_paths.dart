import 'package:path/path.dart' as p;

import '../platform_service.dart' show normaliseLinkTarget;

/// [path], an absolute Windows path, in the form that lifts the 260-character limit on what a Win32 call takes:
/// `\\?\C:\…` for a drive path and `\\?\UNC\server\share\…` for a network one. Normalised first, since that form
/// is taken literally. A path already in that form, a device path or a relative one is returned as it is.
String longPathForm(String path) {
  if (path.startsWith(r'\\?\') || path.startsWith(r'\\.\')) return path;
  // normalize keeps a `//` root as it is written.
  final normal = p.windows.normalize(path.replaceAll('/', r'\'));
  if (isUncPath(normal)) return '\\\\?\\UNC\\${normal.substring(2)}';
  if (driveRootOf(normal) != null) return '\\\\?\\$normal';
  return path;
}

/// The longest folder path Win32 takes without the long-path form: `MAX_PATH`, less room for an 8.3 file name.
const int maxPlainFolderPath = 248;

/// [target] as a symlink is given it: plain when it fits, so the name `dir` and Explorer show is the plain path, and
/// in its long-path form ([longPathForm]) only when it doesn't.
String symlinkTargetForm(String target) => target.length < maxPlainFolderPath ? target : longPathForm(target);

/// [path], on a mapped network drive, with its drive root replaced by [remote], the share the drive is mapped to,
/// such as `Z:\Mods\Ellen` on `\\nas\share` as `\\nas\share\Mods\Ellen`. A path with no drive root is returned as it
/// is.
String withNetworkRoot(String path, String remote) {
  final plain = path.startsWith(r'\\?\') ? path.substring(4) : path;
  if (driveRootOf(plain) == null) return path;
  return p.windows.normalize('$remote${plain.substring(2)}'.replaceAll('/', r'\'));
}

/// Whether [path] is a network path, `\\server\share\…`, plainly or in long-path form.
bool isUncPath(String path) {
  if (path.toUpperCase().startsWith(r'\\?\UNC\')) return true;
  if (path.startsWith(r'\\?\') || path.startsWith(r'\\.\')) return false;
  return path.startsWith(r'\\') || path.startsWith('//');
}

/// The root of the drive [path] is on, such as `C:\`, plainly or in long-path form, or null when it names none.
String? driveRootOf(String path) {
  final plain = path.startsWith(r'\\?\') ? path.substring(4) : path;
  final match = RegExp(r'^[A-Za-z]:(?=[\\/]|$)').firstMatch(plain);
  return match == null ? null : '${match[0]}\\';
}

/// [raw], a link target as Dart's `Link.target` reports it on Windows, as an absolute normalised path. Dart strips
/// the `\??\` of the stored name itself, which leaves a network target as `UNC\server\share\…`, read here as
/// `\\server\share\…`.
String windowsLinkTarget(String raw, String linkFolder) {
  final target = raw.toUpperCase().startsWith(r'UNC\') ? '\\\\${raw.substring(4)}' : raw;
  return normaliseLinkTarget(target, linkFolder, context: p.windows);
}
