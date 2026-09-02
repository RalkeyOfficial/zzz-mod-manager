import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/screens/dialogs/duplicate_archive_dialog.dart';
import 'package:mod_manager_flutter/screens/dialogs/import_selection_dialog.dart';
import 'package:mod_manager_flutter/screens/dialogs/patch_install_flow.dart';
import 'package:mod_manager_flutter/screens/dialogs/patch_install_prompt.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';
import 'package:path/path.dart' as p;

import 'support/localized_harness.dart';
import 'support/origin_shorthand.dart';
import 'support/temp_library.dart';

/// **What a modal shows is read when it opens.**
///
/// The rule exists because the library is not where it looks like it is.
/// `modsProvider` derives from `charactersProvider`, which only `ModsScreen`
/// writes — and that screen is a keyed child of a switcher with no keep-alive,
/// so it is **disposed** while the marketplace is open. Anything that takes the
/// library from the widget tree there is holding a list as old as the user's
/// last visit to the Mods tab, and every install since is missing from it.
///
/// That is not a hypothetical: the patch destination prompt offered every folder
/// in the library except the mod installed a minute earlier — the one the patch
/// was for. So each modal that answers a question **about the library** reads it
/// at the moment it asks, and each of those reads is asserted here against a mod
/// that exists on disk and in no provider.
///
/// A stale read is invisible in a normal test, which is the reason for this
/// file: every one of these would pass just as happily against the cached list,
/// because a test that populates a provider and then reads it back proves
/// nothing about freshness. The fixture is the assertion — the mod is written
/// **after** the container is built and never announced to anyone.
void main() {
  const knownArchive = 'd41d8cd98f00b204e9800998ecf8427e';

  late TempLibrary temp;

  setUp(() async {
    temp = await TempLibrary.create(prefix: 'zzz_modal_freshness_');
  });

  /// An `.ini` that names a file, for building a folder that references more
  /// than it carries.
  String modIni(String filename) =>
      '[TextureOverrideBody]\nps-t0 = R\n\n[R]\nfilename = $filename\n';

  /// A mod in the library **on disk only**. Nothing is told about it: no scan
  /// runs, no provider is written, no rescan is triggered. This is the state the
  /// library is in a second after an install from the marketplace.
  void installedSinceTheTabWasOpen(String name, {String? archiveMd5}) {
    temp.createMod(name);
    temp.write(name, 'ellen.ini', modIni('Textures/Body.dds'));
    temp.write(name, 'Textures/Body.dds', 'the base');
    if (archiveMd5 != null) {
      temp.write(
        name,
        '.zzz-mod-manager/metadata.json',
        _sidecar(originFixture(
          modId: 100,
          modIdConfidence: OriginConfidence.exact,
          provenance: OriginProvenance.downloaded,
          archiveMd5: archiveMd5,
        )),
      );
    }
  }

  group('the patch destination prompt', () {
    /// A patch, still in the extraction directory: it has an `.ini` and does
    /// not carry what that `.ini` names, which is what makes it patch-shaped.
    String patchFolder(String name) {
      final root = Directory(p.join(temp.root.path, 'extract', name))
        ..createSync(recursive: true);
      File(p.join(root.path, 'patch.ini'))
          .writeAsStringSync(modIni('Textures/Body.dds'));
      return root.path;
    }

    /// Runs the decision with a prompt that only records what it was handed,
    /// then declines — the question here is what the user would have been
    /// shown, not what they picked.
    Future<List<String>> offeredFolders(WidgetTester tester) async {
      final folder = patchFolder('Ellen Fix');
      List<ModInfo>? offered;

      await pumpLocalized(
        tester,
        Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              await decidePatchInstall(
                context,
                plan: ImportPlan(
                  folders: [folder],
                  combine: false,
                  combinedName: 'Ellen Fix',
                ),
                folders: [folder],
                modsPath: temp.mods.path,
                prompt: (
                  context, {
                  required List<PatchInstallSubject> subjects,
                  required List<ModInfo> library,
                  bool combined = false,
                }) async {
                  offered = library;
                  return null;
                },
              );
            },
            child: const Text('install'),
          ),
        ),
        overrides: temp.overrides,
      );
      expectBuilt(ElevatedButton);
      await tapWithIo(tester, find.text('install'));

      expect(offered, isNotNull, reason: 'the prompt was never raised');
      return [for (final mod in offered!) mod.id];
    }

    testWidgets('offers a mod installed since the Mods tab was last open',
        (tester) async {
      // The reported bug, in one line: install the base, install its patch
      // without leaving the marketplace, and the base is not in the list.
      installedSinceTheTabWasOpen('Ellen School');

      expect(await offeredFolders(tester), contains('Ellen School'));
    });

    testWidgets('offers a mod nothing has ever scanned', (tester) async {
      // The stronger version, and the one a launch hits: the Mods tab has never
      // been opened, so the cached list is not merely old but empty — and the
      // prompt would not have offered a destination at all.
      installedSinceTheTabWasOpen('Ellen Bikini');
      installedSinceTheTabWasOpen('Ellen School');

      final offered = await offeredFolders(tester);
      expect(offered, containsAll(<String>['Ellen Bikini', 'Ellen School']));
    });

    testWidgets('does not offer a folder that has since been deleted',
        (tester) async {
      // Freshness in the direction that is worse to get wrong. Being offered a
      // folder that is gone means picking a destination the write then cannot
      // reach, and the reason the duplicate gate below invalidates first.
      installedSinceTheTabWasOpen('Ellen School');
      temp.deleteMod('Ellen School');

      expect(await offeredFolders(tester), isEmpty);
    });
  });

  group('the duplicate-archive gate', () {
    /// The gate, asked after the library has already been read once — the way
    /// the marketplace reads it when it opens, before any of this session's
    /// installs existed.
    Future<void> ask(WidgetTester tester, {required String md5}) async {
      await pumpLocalized(
        tester,
        Consumer(
          builder: (context, ref, _) => ElevatedButton(
            onPressed: () async {
              // Primes the cache with the library as it is *now*, which is what
              // opening the marketplace does.
              await ref.read(installedModsIndexProvider.future);
              installedSinceTheTabWasOpen('Ellen School',
                  archiveMd5: knownArchive);
              await confirmArchiveNotDuplicate(context, ref, md5);
            },
            child: const Text('install'),
          ),
        ),
        overrides: temp.overrides,
      );
      expectBuilt(ElevatedButton);
      await tapWithIo(tester, find.text('install'));
    }

    testWidgets('notices an archive installed since it last looked',
        (tester) async {
      await ask(tester, md5: knownArchive);

      expect(find.text('You already have this archive'), findsOneWidget,
          reason: 'the snapshot is invalidated before the check, so an install '
              'from earlier in this session counts');
    });

    testWidgets('and still says nothing about an archive it has not seen',
        (tester) async {
      await ask(tester, md5: 'ffffffffffffffffffffffffffffffff');

      expect(find.text('You already have this archive'), findsNothing);
    });
  });
}

/// The sidecar, written straight to disk rather than through the repository.
///
/// [TempLibrary.writeOrigin] is the usual way and it is **async**, which a
/// widget-test body cannot await: the fake-async zone never turns the real
/// event loop, so the write would never complete. The point of these fixtures
/// is that they land with nothing running, so they are synchronous throughout.
String _sidecar(ModOrigin origin) =>
    jsonEncode({'schema_version': 3, 'origin': origin.toJson()});
