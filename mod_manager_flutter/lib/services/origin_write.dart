import '../models/mod_origin.dart';

/// How an amendment of a mod's origin block ended.
enum OriginWriteResult {
  written,

  /// The transform answered null against the block as it is on disk, so nothing was written.
  declined,

  folderMissing,
  writeFailed;

  bool get ok => this == OriginWriteResult.written;
}

/// Amends one mod's origin block, handing [update] the block as it is on disk.
/// Production is the library service's `updateModOrigin`, reached through `modManagerServiceProvider`;
/// tests inject one so a widget never reaches the developer's own library.
typedef OriginWriter = Future<OriginWriteResult> Function(
  String modName,
  ModOrigin? Function(ModOrigin? current) update,
);

/// Reads one mod's origin block as it is on disk now.
/// Production is the library service's `readModOrigin`; tests inject one for the same reason as [OriginWriter].
typedef OriginReader = Future<ModOrigin?> Function(String modName);
