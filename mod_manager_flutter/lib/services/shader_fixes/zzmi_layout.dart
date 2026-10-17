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
Future<String?> findShaderFolder(String saveModsPath) =>
    shaderFolderIn(p.dirname(p.normalize(saveModsPath)));

/// The shader folder named by the `d3dx.ini` in [zzmiRoot], or null when the root
/// holds no readable `d3dx.ini` (`docs/shader-fixes.md` §1).
Future<String?> shaderFolderIn(String zzmiRoot) async {
  final root = p.normalize(zzmiRoot);
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

/// The ZZMI folder a picked folder stands for: [picked] itself when it holds
/// `d3dx.ini`, its parent when [picked] is a `mods` folder beside one (the links
/// folder itself), its `ZZMI/` child when that holds one (the XXMI Launcher's
/// folder), and null otherwise.
Future<String?> resolveZzmiFolder(String picked) async {
  final root = p.normalize(picked);
  if (await File(p.join(root, 'd3dx.ini')).exists()) return root;
  final parent = p.dirname(root);
  if (p.basename(root).toLowerCase() == 'mods' &&
      await File(p.join(parent, 'd3dx.ini')).exists()) {
    return parent;
  }
  final nested = p.join(root, 'ZZMI');
  if (await File(p.join(nested, 'd3dx.ini')).exists()) return nested;
  return null;
}

/// The links folder inside [zzmiRoot]: its existing child named `mods` in any
/// case, or `<root>/Mods` when there is none.
///
/// Case is ignored because ZZMI under Wine sees a case-insensitive disk while
/// Linux does not. An exact `Mods` wins when both spellings exist. Synchronous,
/// since `ConfigService` works it out while loading (`docs/shader-fixes.md` §1).
String linksFolderIn(String zzmiRoot) {
  final root = p.normalize(zzmiRoot);
  final exact = p.join(root, 'Mods');
  try {
    String? other;
    for (final entity in Directory(root).listSync(followLinks: false)) {
      if (entity is! Directory) continue;
      final name = p.basename(entity.path);
      if (name == 'Mods') return exact;
      if (name.toLowerCase() == 'mods') other ??= entity.path;
    }
    return other ?? exact;
  } on FileSystemException {
    return exact;
  }
}

final RegExp _replacementName =
    RegExp(r'^[0-9a-f]{16}-(vs|ps|cs|gs|hs|ds)(_replace)?\.(txt|bin)$', caseSensitive: false);

/// Whether [fileName] is a name 3DMigoto opens as a shader replacement: a 16-hex hash,
/// the shader stage, an optional `_replace`, and `.txt` or `.bin` (`docs/shader-fixes.md` §1).
bool isShaderReplacementName(String fileName) => _replacementName.hasMatch(fileName);

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
