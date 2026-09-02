import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/core/constants.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/services/api_service.dart';
import 'package:mod_manager_flutter/services/backup/snapshot_service.dart';
import 'package:mod_manager_flutter/services/config_service.dart';
import 'package:mod_manager_flutter/services/mod_manager_service.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// **A whole library in a temp directory**, with the app's globals pointed at it.
///
/// What this exists for: the flows worth testing are the ones that *write* —
/// take a patch out, apply an update, rename a mod — and every one of them
/// reaches `ApiService`, which is static and builds a `ConfigService` over the
/// developer's real `<appData>/config.json` on first use. A widget test of one
/// of those dialogs would repoint the developer's library and rewrite their
/// active-mod list, so those dialogs were tested only as far down as the pure
/// planner, never as the thing the user presses.
///
/// **Everything here is the real service, over a directory this owns.** There is
/// no fake filesystem and no stubbed config, deliberately: what these flows do
/// is copy, delete and restore files, so a fake would replace the only part
/// worth trusting with an assertion that the fake was called. The substitution
/// is *where* the writes land, never *whether* they happen — which means a test
/// asserts against the bytes on disk, the same way the user finds out.
///
/// Three globals get redirected, and between them they cover the app's writes:
///
/// | Global | Redirected to |
/// |---|---|
/// | `ApiService`'s config + mod manager | [config] over `<root>/config.json` |
/// | `modManagerServiceProvider` | the same [service] instance |
/// | `snapshotServiceProvider` | [snapshots], rooted at `<root>/backups` |
///
/// ## Its own file helpers are synchronous, and that is not a style choice
///
/// A `testWidgets` body runs inside a **fake async** zone, which never turns the
/// real event loop — so `await File(...).writeAsString(...)` in a test body does
/// not complete, and the test hangs with no failure and no output. Only
/// [WidgetTester.runAsync] turns it.
///
/// So every helper here is `…Sync`, which works in either zone, and the two
/// places a test has to reach real production async code — the patch store and
/// the metadata repository — say so on the method. The flow under test is
/// reached with `tapWithIo`, which presses the button inside a `runAsync`.
///
/// Tear-down is registered by [create], so a test needs no `tearDown` of its
/// own. That is not a convenience: `ApiService`'s fields are static, so a
/// library left installed leaks into the next test in the same file, which then
/// writes into a deleted directory and fails somewhere else entirely.
class TempLibrary {
  TempLibrary._({
    required this.root,
    required this.mods,
    required this.saveMods,
    required this.config,
    required this.service,
    required this.snapshots,
  });

  /// The temp directory holding everything below. Deleted on tear-down.
  final Directory root;

  /// `<root>/mods` — the library. A mod is a folder directly inside it.
  final Directory mods;

  /// `<root>/saveMods` — where activation puts its links.
  final Directory saveMods;

  final ConfigService config;
  final ModManagerService service;
  final SnapshotService snapshots;

  /// Builds the library, installs it, and registers its tear-down.
  ///
  /// Call it from `setUp`, which runs outside the fake-async zone, or from
  /// inside a [WidgetTester.runAsync].
  static Future<TempLibrary> create({String prefix = 'zzz_library_'}) async {
    final root = Directory.systemTemp.createTempSync(prefix);
    final mods = Directory(p.join(root.path, 'mods'))..createSync();
    final saveMods = Directory(p.join(root.path, 'saveMods'))..createSync();

    SharedPreferences.setMockInitialValues({});
    final config = ConfigService(
      await SharedPreferences.getInstance(),
      configFile: File(p.join(root.path, 'config.json')),
    );
    await config.setPaths(mods.path, saveMods.path);

    final library = TempLibrary._(
      root: root,
      mods: mods,
      saveMods: saveMods,
      config: config,
      service: ModManagerService(config),
      snapshots: SnapshotService(rootPath: p.join(root.path, 'backups')),
    );

    ApiService.useLibraryForTests(config);
    addTearDown(() {
      ApiService.resetForTests();
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    return library;
  }

  /// The overrides a widget test mounts, for the two dependencies read through
  /// `ref` rather than through the static facade.
  List<Override> get overrides => [
        modManagerServiceProvider.overrideWith((ref) async => service),
        snapshotServiceProvider.overrideWithValue(snapshots),
      ];

  Directory modFolder(String modName) => Directory(p.join(mods.path, modName));

  /// A mod folder, created empty.
  Directory createMod(String modName) =>
      modFolder(modName)..createSync(recursive: true);

  /// Writes a file inside a mod, creating the folders above it.
  ///
  /// [relative] is `/`-separated in the spelling it should have on disk, which
  /// is the spelling a registry records and the one a removal deletes through.
  void write(String modName, String relative, String contents) {
    final file = _file(modName, relative);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(contents);
  }

  /// What is at [relative] inside a mod, or null when nothing is.
  String? read(String modName, String relative) {
    final file = _file(modName, relative);
    return file.existsSync() ? file.readAsStringSync() : null;
  }

  bool has(String modName, String relative) => _file(modName, relative).existsSync();

  /// Removes a mod's whole folder, for the case where the files a record names
  /// are no longer there.
  void deleteMod(String modName) {
    final folder = modFolder(modName);
    if (folder.existsSync()) folder.deleteSync(recursive: true);
  }

  /// Writes a mod's origin block **through the real repository**, so the sidecar
  /// on disk is the one the flow under test will read and rewrite.
  ///
  /// Async production code: call it inside a [WidgetTester.runAsync] from a
  /// widget test.
  Future<void> writeOrigin(String modName, ModOrigin origin) async {
    final written = await service.updateModOrigin(modName, (_) => origin);
    expect(written, isTrue, reason: 'the origin fixture did not reach $modName');
  }

  /// The origin block **as it is on disk now** — what a write is asserted
  /// against, rather than the in-memory value the caller passed in.
  ModOrigin? originOf(String modName) {
    final file = File(p.join(
      modFolder(modName).path,
      AppConstants.modMetadataDirName,
      AppConstants.modMetadataFileName,
    ));
    if (!file.existsSync()) return null;
    final json = jsonDecode(file.readAsStringSync());
    if (json is! Map<String, Object?>) return null;
    return ModOrigin.fromJson(json['origin']);
  }

  /// Which snapshots exist for a mod — the folder names, which is all "is there
  /// a way back?" needs.
  ///
  /// Resolved through the mod's **uid**, read off its sidecar, because that is
  /// how the store is keyed. A mod with no uid has never had a snapshot taken,
  /// so the empty answer is the true one rather than a lookup miss.
  List<String> snapshotsOf(String modName) {
    final uid = uidOf(modName);
    if (uid == null) return const [];
    final dir = Directory(p.join(snapshots.rootPath, uid));
    if (!dir.existsSync()) return const [];
    return [
      for (final entity in dir.listSync().whereType<Directory>())
        p.basename(entity.path),
    ]..sort();
  }

  /// The mod's identity as it stands on disk, or null if nothing has needed one.
  String? uidOf(String modName) {
    final file = File(p.join(
      modFolder(modName).path,
      AppConstants.modMetadataDirName,
      AppConstants.modMetadataFileName,
    ));
    if (!file.existsSync()) return null;
    final json = jsonDecode(file.readAsStringSync());
    return json is Map<String, Object?> ? json['uid'] as String? : null;
  }

  File _file(String modName, String relative) =>
      File(p.joinAll([modFolder(modName).path, ...relative.split('/')]));
}
