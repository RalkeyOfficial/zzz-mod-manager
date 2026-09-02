import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/mod_metadata.dart';
import 'package:mod_manager_flutter/services/mod_metadata_service.dart';
import 'package:mod_manager_flutter/services/mod_uid.dart';
import 'package:path/path.dart' as p;

/// **A mod folder's identity, which has to be the same string tomorrow.**
///
/// Real directories, because every claim here is about what is written into a
/// folder and read back out of it. The one property worth all of this is
/// stability across the events the app cannot see — a rename in a file manager
/// is not a hook, so anything filed under a folder's *name* is stranded
/// silently, and saved versions are where that costs gigabytes.
void main() {
  late Directory tmp;
  late ModUid uids;
  final sidecars = ModMetadataService();

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('zzz_mod_uid_');
    uids = ModUid();
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Directory modFolder(String name) =>
      Directory(p.join(tmp.path, name))..createSync(recursive: true);

  test('a folder with no uid is given one, and keeps it', () async {
    final mod = modFolder('Ellen');

    final first = await uids.ensure(mod);
    final second = await uids.ensure(mod);

    expect(first, isNotNull);
    expect(first, hasLength(32));
    expect(second, first, reason: 'asking twice must not re-identify the mod');
    expect(await uids.read(mod), first, reason: 'it is on disk, not in memory');
  });

  test('two folders never share one', () async {
    final a = await uids.ensure(modFolder('Ellen'));
    final b = await uids.ensure(modFolder('Miyabi'));

    expect(a, isNot(b));
  });

  test('a folder that has never needed one has none', () async {
    // Not an approximation: a mod with no uid cannot have anything filed under
    // one, so "no uid" and "no saved versions" are the same statement.
    expect(await uids.read(modFolder('Ellen')), isNull);
  });

  test('it survives the rename the app never sees', () async {
    // The whole point. No hook runs on a file-manager rename, so an identity
    // that lived in the folder *name* would be gone here.
    final mod = modFolder('Ellen');
    final uid = await uids.ensure(mod);

    final renamed = Directory(p.join(tmp.path, 'Ellen but better'));
    mod.renameSync(renamed.path);

    expect(await uids.read(renamed), uid);
  });

  test('it is kept when the sidecar is rewritten around it', () async {
    // The sidecar is read-modify-written by every metadata edit. A uid that did
    // not survive a description edit would strand the folder's saved versions
    // on the first edit after they were taken.
    final mod = modFolder('Ellen');
    final uid = await uids.ensure(mod);

    final onDisk = await sidecars.read(mod.path) ?? const ModMetadata();
    await sidecars.write(
      mod.path,
      onDisk.replaceUserFields(
        description: 'edited later',
        sourceUrl: null,
        tags: const ['x'],
        characterId: 'ellen',
        images: const [],
      ),
    );

    expect(await uids.read(mod), uid);
  });

  test('a folder that cannot be written gets no identity', () async {
    // A folder the app cannot modify is one the operation asking for a uid was
    // about to fail on anyway, so null is the honest answer rather than an
    // in-memory id nothing could ever find again.
    final mod = Directory(p.join(tmp.path, 'Never Existed'));

    expect(await uids.ensure(mod), isNull);
  });

  test('a copied folder carries the same uid, and nothing here notices',
      () async {
    // Filed, not fixed, and pinned so it is a known shape rather than a
    // surprise: both folders claim one history, and an update to either prunes
    // the other's. The scan is where this would have to be caught.
    final mod = modFolder('Ellen');
    final uid = await uids.ensure(mod);

    final copy = modFolder('Ellen copy');
    Directory(p.join(copy.path, '.zzz-mod-manager')).createSync();
    File(p.join(mod.path, '.zzz-mod-manager', 'metadata.json')).copySync(
      p.join(copy.path, '.zzz-mod-manager', 'metadata.json'),
    );

    expect(await uids.read(copy), uid);
  });
}
