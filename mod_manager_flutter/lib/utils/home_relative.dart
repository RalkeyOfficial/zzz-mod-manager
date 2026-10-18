import 'package:path/path.dart' as p;

/// `~/Games/ZZMI` rather than the full home path, the way a path reads in a terminal. Only a path inside [home] is
/// shortened, so `/home/alice` stays whole when home is `/home/al`. [style] defaults to this platform's paths.
String homeRelative(String path, {required String? home, p.Context? style}) {
  final paths = style ?? p.context;
  if (home == null || home.isEmpty) return path;
  if (paths.equals(home, path)) return '~';
  if (!paths.isWithin(home, path)) return path;
  return '~${paths.separator}${paths.relative(path, from: home)}';
}
