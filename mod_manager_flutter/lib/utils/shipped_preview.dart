import 'dart:io';

import 'package:path/path.dart' as path;

import '../core/constants.dart';

/// Finds an image the **mod author shipped inside the archive** — `Preview.png`
/// and friends, at the root of the mod folder.
///
/// Two callers need the same answer, which is why this is not a private helper
/// on either of them:
///
/// - the scan (`ModManagerService._buildModInfo`) falls back to it when the
///   sidecar's `images` array yields nothing, so a mod that never had its
///   metadata edited still shows a cover;
/// - the marketplace's metadata autofill checks for it before importing a remote
///   gallery, so an author's own preview keeps the cover slot instead of being
///   displaced by a screenshot off the mod page.
///
/// Returns an **absolute** path, or null when the folder has none. Rare in
/// practice — 1 of 16 mods in a real library ships one — which is precisely why
/// the autofill is worth having.
Future<String?> findShippedPreview(String modFolder) async {
  for (final name in AppConstants.imageFileNames) {
    final file = File(path.join(modFolder, name));
    if (await file.exists()) return file.path;
  }
  return null;
}
