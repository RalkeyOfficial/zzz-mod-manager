import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/services/api_service.dart';
import 'package:mod_manager_flutter/services/mod_manager_service.dart';
import 'package:mod_manager_flutter/services/shader_fixes/shader_fixes_service.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';
import 'package:path/path.dart' as p;

import 'support/origin_shorthand.dart';
import 'support/temp_library.dart';

/// **The library belongs to no screen.**
///
/// Every test here reads it from a bare container — no widget, no Library page, no
/// `State` alive anywhere. That is the property being pinned: the pages are keyed
/// children of a switcher with no keep-alive, so a library owned by the Library
/// page's `State` is unreachable and unrefreshable for as long as the user is
/// looking at anything else, which is when installs happen.
void main() {
  late TempLibrary temp;

  setUp(() async {
    temp = await TempLibrary.create(prefix: 'zzz_library_provider_');
  });

  /// A mod folder with one `.ini`, which is enough for the scan to see it.
  void installMod(String name) {
    temp.createMod(name);
    temp.write(name, '$name.ini', '[TextureOverrideBody]\nps-t0 = R\n');
  }

  ProviderContainer container() {
    final container = ProviderContainer(overrides: temp.overrides);
    addTearDown(container.dispose);
    return container;
  }

  /// A container over the temp library whose walks [held] can stop midway.
  ({ProviderContainer ref, _HeldWalkService held}) heldContainer() {
    final held = _HeldWalkService(
      temp.config,
      shaderFixes: ShaderFixesService(recordPath: p.join(temp.root.path, 'shader_fixes.json')),
      snapshots: temp.snapshots,
    );
    ApiService.useLibraryForTests(temp.config, service: held);
    final container = ProviderContainer(overrides: [
      modManagerServiceProvider.overrideWith((ref) async => held),
      snapshotServiceProvider.overrideWithValue(temp.snapshots),
    ]);
    addTearDown(container.dispose);
    return (ref: container, held: held);
  }

  List<String> ids(ProviderContainer ref) => [for (final m in ref.read(modsProvider)) m.id];

  test('the first read scans the library, with nothing mounted', () async {
    installMod('Ellen School');
    installMod('Miyabi Kimono');

    final mods = await container().read(libraryProvider.future);

    expect(mods.map((m) => m.id), containsAll(['Ellen School', 'Miyabi Kimono']));
  });

  test('a rescan picks up a mod installed since', () async {
    installMod('Ellen School');
    final ref = container();
    await ref.read(libraryProvider.future);

    installMod('Miyabi Kimono');
    await ref.read(libraryProvider.notifier).rescan();

    expect(ref.read(modsProvider).map((m) => m.id), contains('Miyabi Kimono'));
  });

  test('a rescan that finds nothing new keeps the list it has', () async {
    // What stops the grid being torn down and rebuilt by a rescan that finds one
    // mod changed, or none, as most do.
    installMod('Ellen School');
    final ref = container();
    final before = await ref.read(libraryProvider.future);

    await ref.read(libraryProvider.notifier).rescan();

    expect(ref.read(modsProvider), same(before),
        reason: 'an unchanged rescan must not publish a new list');
  });

  test('a change to one mod does publish a new list', () async {
    installMod('Ellen School');
    final ref = container();
    final before = await ref.read(libraryProvider.future);

    installMod('Miyabi Kimono');
    await ref.read(libraryProvider.notifier).rescan();

    expect(ref.read(modsProvider), isNot(same(before)));
  });

  test('the installed index answers from the same scan', () async {
    // Derived rather than scanning again: the marketplace's "in library" badges
    // and the Library's grid are two views of one read, so they cannot
    // disagree about what is installed.
    installMod('Ellen School');
    await temp.writeOrigin(
      'Ellen School',
      originFixture(
        modId: 4242,
        modIdConfidence: OriginConfidence.exact,
        provenance: OriginProvenance.downloaded,
      ),
    );
    final ref = container();

    final index = await ref.read(installedModsIndexProvider.future);

    expect(index.installsOfMod(4242), ['Ellen School']);
  });

  test('a mod deleted outside the app is gone after a rescan', () async {
    installMod('Ellen School');
    final ref = container();
    await ref.read(libraryProvider.future);

    temp.deleteMod('Ellen School');
    await ref.read(libraryProvider.notifier).rescan();

    expect(ref.read(modsProvider), isEmpty);
  });

  test('a rescan asked for during the first scan joins it', () async {
    // **The launch ordering.** Something above the tabs reads the library —
    // `LaunchUpdateCheckHost` does, through the bulk check's plan — which starts
    // the first scan; the Library page then mounts and asks for one before that has
    // landed. Two walks of the same folder at the same moment produce one
    // answer, and the second publish tears the grid down to rebuild it
    // identically.
    installMod('Ellen School');
    final ref = container();

    final published = <List<ModInfo>>[];
    ref.listen<AsyncValue<List<ModInfo>>>(libraryProvider, (_, next) {
      final mods = next.valueOrNull;
      if (mods != null) published.add(mods);
    });

    ref.read(libraryProvider);
    await ref.read(libraryProvider.notifier).rescan();

    expect(published, hasLength(1), reason: 'one scan, one answer');
  });

  test('a rescan does not return before the library is readable', () async {
    // What the Library page does next is build its groups from `valueOrNull`, so a
    // rescan that returns while the state is still loading paints an empty grid
    // and then rebuilds it a frame later.
    installMod('Ellen School');
    final ref = container();

    ref.read(libraryProvider);
    await ref.read(libraryProvider.notifier).rescan();

    expect(ref.read(modsProvider), isNotEmpty);
  });

  /// Waited out rather than awaited: the point is what a read does when it lands *after* an edit, and
  /// `libraryProvider.future` already answers with the edit. A scan of this library is ~5 ms.
  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 250));

  /// Renames Ellen School as the app does: the folder on disk, then the list it knows.
  void rename(ProviderContainer ref) {
    temp.modFolder('Ellen School').renameSync(temp.modFolder('Renamed').path);
    ref.read(libraryProvider.notifier).put([
      ModInfo(id: 'Renamed', name: 'Renamed', characterId: 'ellen', isActive: false),
    ]);
  }

  test("the first scan's answer is not published over an edit made while it walked", () async {
    // A rename or a delete knows exactly what it did. The scan that was already
    // walking the folder when it happened is the older answer, whichever of the
    // two finishes last.
    installMod('Ellen School');
    final (:ref, :held) = heldContainer();
    final hold = held.holdNextWalk();

    ref.read(libraryProvider);
    await hold.listed;
    rename(ref);
    hold.release();
    await settle();

    expect(ids(ref), ['Renamed']);
  });

  test('an edit made while the library is read again keeps what the invalidate came for', () async {
    // A press waiting on an install is let go when the install ends, just before the install invalidates the
    // library: the edit's list predates the install, and the read the invalidate started walked before the edit.
    installMod('Ellen School');
    final (:ref, :held) = heldContainer();
    await ref.read(libraryProvider.future);

    installMod('Miyabi Kimono');
    final hold = held.holdNextWalk();
    ref.invalidate(libraryProvider);
    ref.read(libraryProvider);
    await hold.listed;
    rename(ref);
    hold.release();
    await settle();

    expect(ids(ref), unorderedEquals(['Renamed', 'Miyabi Kimono']));
  });

  test('an edit made during a rescan survives it', () async {
    // A card's switch pressed as the window gains focus: the focus rescan read the mod before the toggle.
    installMod('Ellen School');
    final (:ref, :held) = heldContainer();
    await ref.read(libraryProvider.future);

    final hold = held.holdNextWalk();
    final scan = ref.read(libraryProvider.notifier).rescan();
    await hold.listed;
    rename(ref);
    hold.release();
    await scan;

    expect(ids(ref), ['Renamed']);
  });

  test('a rescan whose walk an edit overtook reads the folder once more', () async {
    // The edit is newer than the walk, and the walk after it sees whatever else changed beside it.
    installMod('Ellen School');
    final (:ref, :held) = heldContainer();
    await ref.read(libraryProvider.future);

    final hold = held.holdNextWalk();
    final scan = ref.read(libraryProvider.notifier).rescan();
    await hold.listed;
    ref.read(libraryProvider.notifier).put(const []);
    installMod('Miyabi Kimono');
    hold.release();
    await scan;

    expect(ids(ref), containsAll(['Ellen School', 'Miyabi Kimono']));
  });

  test('a rescan whose walks two edits overtook in turn still publishes what the folder holds', () async {
    installMod('Ellen School');
    final (:ref, :held) = heldContainer();
    await ref.read(libraryProvider.future);

    final first = held.holdNextWalk();
    final scan = ref.read(libraryProvider.notifier).rescan();
    await first.listed;
    ref.read(libraryProvider.notifier).put(const []);
    installMod('Miyabi Kimono');
    final second = held.holdNextWalk();
    first.release();
    await second.listed;
    ref.read(libraryProvider.notifier).put(const []);
    installMod('Yanagi Office');
    second.release();
    await scan;

    expect(ids(ref), unorderedEquals(['Ellen School', 'Miyabi Kimono', 'Yanagi Office']));
  });

  test('a rescan that joins a running one sees a change made after that one read the folder', () async {
    // A bulk Enable's rescan while the focus scan is midway: the focus scan read the folder before the links changed.
    installMod('Ellen School');
    final (:ref, :held) = heldContainer();
    await ref.read(libraryProvider.future);

    final hold = held.holdNextWalk();
    final focus = ref.read(libraryProvider.notifier).rescan();
    await hold.listed;
    installMod('Miyabi Kimono');
    final joined = ref.read(libraryProvider.notifier).rescan();
    hold.release();
    await joined;

    expect(ids(ref), containsAll(['Ellen School', 'Miyabi Kimono']));
    await focus;
  });

  test('a failed walk an edit overtook leaves the edit in place', () async {
    installMod('Ellen School');
    final (:ref, :held) = heldContainer();
    await ref.read(libraryProvider.future);

    final hold = held.holdNextWalk(fail: true);
    final scan = ref.read(libraryProvider.notifier).rescan();
    await hold.listed;
    rename(ref);
    hold.release();
    await scan;

    expect(ref.read(libraryProvider).hasError, isFalse);
    expect(ids(ref), ['Renamed']);
  });

  test('a rescan running when the library is invalidated does not undo the read after it', () async {
    // An install finishing while the focus scan is midway: the install invalidates the library, whose new read sees
    // the new mod, and the focus scan read the folder before the install wrote it.
    installMod('Ellen School');
    final (:ref, :held) = heldContainer();
    await ref.read(libraryProvider.future);

    final hold = held.holdNextWalk();
    final focus = ref.read(libraryProvider.notifier).rescan();
    await hold.listed;
    installMod('Miyabi Kimono');
    ref.invalidate(libraryProvider);
    await ref.read(libraryProvider.future);
    hold.release();
    await focus;

    expect(ids(ref), containsAll(['Ellen School', 'Miyabi Kimono']));
  });

  test('every rescan is counted, one that finds nothing new too', () async {
    // What the Folder missing rows re-read on.
    installMod('Ellen School');
    final ref = container();
    await ref.read(libraryProvider.future);
    final before = ref.read(libraryScansProvider);

    await ref.read(libraryProvider.notifier).rescan();

    expect(ref.read(libraryScansProvider), before + 1);
  });

  test('put replaces the library without touching the disk', () async {
    // The seam the targeted editorial actions use: a rename knows exactly what
    // it did, so it says so rather than paying for a walk of every folder.
    installMod('Ellen School');
    final ref = container();
    await ref.read(libraryProvider.future);

    ref.read(libraryProvider.notifier).put([
      ModInfo(
        id: 'Renamed',
        name: 'Renamed',
        characterId: 'ellen',
        isActive: false,
      ),
    ]);

    expect(ref.read(modsProvider).single.id, 'Renamed');
    expect(temp.modFolder('Ellen School').existsSync(), isTrue,
        reason: 'put is an in-memory publish, not a write');
  });
}

/// The library's service, with a walk that can be held after it has read the folder and before it answers.
class _HeldWalkService extends ModManagerService {
  _HeldWalkService(super.config, {super.shaderFixes, super.snapshots});

  _Hold? _next;

  /// Holds the next walk; [fail] makes it throw once released.
  _Hold holdNextWalk({bool fail = false}) => _next = _Hold(fail);

  @override
  Future<List<ModInfo>> getModsInfo() async {
    final mods = await super.getModsInfo();
    final hold = _next;
    if (hold == null) return mods;
    _next = null;
    hold._listed.complete();
    await hold._released.future;
    if (hold.fail) throw const FileSystemException('the library folder went away');
    return mods;
  }
}

class _Hold {
  _Hold(this.fail);

  final bool fail;
  final _listed = Completer<void>();
  final _released = Completer<void>();

  /// Completes once the held walk has read the folder.
  Future<void> get listed => _listed.future;

  void release() => _released.complete();
}
