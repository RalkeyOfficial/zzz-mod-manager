import 'dart:io';

import 'package:path/path.dart' as p;

/// Where ZZMI reads shader replacements from, found from the links folder.
///
/// The links folder is ZZMI's `Mods/`, so its parent is the ZZMI root, which holds
/// `d3dx.ini`. That file names the shader folder in `[Rendering] override_directory`,
/// relative to the root. The loader opens files there by exact name and never looks
/// inside `Mods/`, which is why a mod's shader files have to be copied out to it
/// (`docs/shader-fixes.md` §1).
///
/// Returns null when there is no `d3dx.ini` beside the links folder: the folder is
/// then not a ZZMI `Mods/`, and there is nowhere trustworthy to put a shader file.
Future<String?> findShaderFolder(String saveModsPath) async {
  final root = p.dirname(p.normalize(saveModsPath));
  final ini = File(p.join(root, 'd3dx.ini'));
  if (!await ini.exists()) return null;
  final String contents;
  try {
    contents = await ini.readAsString();
  } on FileSystemException {
    return null;
  }
  final folder = overrideDirectoryFrom(contents);
  return p.isAbsolute(folder) ? folder : p.normalize(p.join(root, folder));
}

/// The `override_directory` value in `[Rendering]`, or 3DMigoto's default.
///
/// Backslashes become the platform separator, since ZZMI's own files are written
/// for Windows and the app also runs on Linux.
String overrideDirectoryFrom(String d3dxIni) {
  const fallback = 'ShaderFixes';
  var inRendering = false;
  for (final raw in d3dxIni.split(RegExp(r'\r\n|\r|\n'))) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith(';')) continue;
    if (line.startsWith('[') && line.endsWith(']')) {
      inRendering = line.substring(1, line.length - 1).trim().toLowerCase() == 'rendering';
      continue;
    }
    if (!inRendering) continue;
    final eq = line.indexOf('=');
    if (eq < 0) continue;
    if (line.substring(0, eq).trim().toLowerCase() != 'override_directory') continue;
    final value = line.substring(eq + 1).trim();
    if (value.isEmpty) return fallback;
    return value.replaceAll(r'\', p.separator);
  }
  return fallback;
}
