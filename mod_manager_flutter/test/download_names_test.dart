import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_mod.dart';
import 'package:mod_manager_flutter/models/mod_download.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/mod_origin_seed.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/screens/dialogs/patch_install_flow.dart';
import 'package:mod_manager_flutter/services/download_names.dart';
import 'package:mod_manager_flutter/services/ingest_origin_builder.dart';
import 'package:mod_manager_flutter/services/origin_resolution.dart';
import 'package:mod_manager_flutter/services/origin_write.dart';

import 'package:mod_manager_flutter/utils/state_providers.dart';

import 'support/library_override.dart';
import 'support/origin_shorthand.dart';

/// `ModDownload.name`: a display copy of a mod page's title, saved with each layer so a folder lists its downloads
/// by name after a restart without a request (`docs/origin-tracking.md` §10).
void main() {
  /// The folder from the report: a patch installed as its own folder, with the mod it patches fetched in, so the
  /// folder carries the patch's archive name.
  ModOrigin stacked({String? baseName, String? patchName}) {
    final block = originFixture(
      modId: 564752,
      modIdConfidence: OriginConfidence.exact,
      fileId: 1350797,
      versionConfidence: OriginConfidence.exact,
      provenance: OriginProvenance.downloaded,
      patches: [patchFixture(modId: 564819, fileId: 1349673, versionConfidence: OriginConfidence.exact)],
    );
    return block.copyWith(downloads: [
      block.downloads[0].copyWith(name: baseName),
      block.downloads[1].copyWith(name: patchName),
    ]);
  }

  const pages = {
    564752: GbMod(idRow: 564752, name: 'Zhu-Yuan Black-Suit'),
    564819: GbMod(idRow: 564819, name: 'Zhu Yuan - Black-Suit edit'),
  };

  group('the field', () {
    test('round-trips through the sidecar', () {
      final layer = ModDownload.fromJson(
        const ModDownload(modId: 1, name: 'Ellen Swimsuit').toJson(),
        index: 0,
      );
      expect(layer?.name, 'Ellen Swimsuit');
    });

    test('is absent from the json when unknown', () {
      expect(const ModDownload(modId: 1).toJson().containsKey('name'), isFalse);
    });

    test('is part of equality, so a rescan publishes a changed name', () {
      expect(const ModDownload(modId: 1, name: 'A'), isNot(const ModDownload(modId: 1, name: 'B')));
    });

    test('a rebind to another mod clears it, or takes the new page title', () {
      const layer = ModDownload(modId: 1, name: 'Old mod');
      expect(layer.boundTo(modId: 2, confidence: OriginConfidence.user).name, isNull);
      expect(layer.boundTo(modId: 2, confidence: OriginConfidence.user, name: 'New mod').name, 'New mod');
      expect(layer.boundTo(modId: 1, confidence: OriginConfidence.user).name, 'Old mod');
    });

    test('an update keeps it while the mod is the same one', () {
      const layer = ModDownload(modId: 1, name: 'Ellen Swimsuit');
      expect(layer.updatedTo(modId: 1, fileId: 10).name, 'Ellen Swimsuit');
      expect(layer.updatedTo(modId: 2, fileId: 10).name, isNull);
      expect(layer.withUpdatesUndismissed().name, 'Ellen Swimsuit');
    });
  });

  group('written where the page is in hand', () {
    test('by a marketplace install', () {
      final origin = IngestOriginBuilder().separate(
        seed: const ModOriginSeed(provenance: OriginProvenance.downloaded, modId: 564819, name: 'Zhu Yuan - Black-Suit edit'),
        sourceFolder: '/x/zhuyuan_blacksuit_culture_edit_52313',
      );
      expect(origin.base?.name, 'Zhu Yuan - Black-Suit edit');
    });

    test('by a patch written into a mod', () {
      expect(const PatchIdentity(modId: 564819, name: 'Zhu Yuan - Black-Suit edit').layer.name, 'Zhu Yuan - Black-Suit edit');
    });

    test('by the tracking dialog binding a mod', () {
      expect(OriginResolution.bind(null, 564752, name: 'Zhu-Yuan Black-Suit').base?.name, 'Zhu-Yuan Black-Suit');
    });
  });

  group('withPageNames', () {
    test('names every layer a page is held for', () {
      final named = withPageNames(stacked(), pages);
      expect(named?.downloads.map((d) => d.name), ['Zhu-Yuan Black-Suit', 'Zhu Yuan - Black-Suit edit']);
    });

    test('rewrites a name the page has changed', () {
      final named = withPageNames(stacked(baseName: 'Old title', patchName: 'Zhu Yuan - Black-Suit edit'), pages);
      expect(named?.base?.name, 'Zhu-Yuan Black-Suit');
    });

    test('answers null when nothing changes, so no write happens', () {
      expect(
        withPageNames(stacked(baseName: 'Zhu-Yuan Black-Suit', patchName: 'Zhu Yuan - Black-Suit edit'), pages),
        isNull,
      );
      expect(withPageNames(stacked(), const {}), isNull);
    });

    test('ignores a page with no title, such as a gone one', () {
      expect(withPageNames(stacked(), const {564752: GbMod(idRow: 564752)}), isNull);
    });
  });

  group('rememberDownloadNames', () {
    ModInfo mod(String id, ModOrigin? origin) =>
        ModInfo(id: id, name: id, characterId: 'zhuyuan', isActive: false, origin: origin);

    test('writes only the sidecars whose names differ', () async {
      final writes = <String, ModOrigin?>{};
      final library = [
        mod('zhuyuan_blacksuit_culture_edit_52313', stacked()),
        mod('already', stacked(baseName: 'Zhu-Yuan Black-Suit', patchName: 'Zhu Yuan - Black-Suit edit')),
        mod('untracked', null),
      ];
      final wrote = await rememberDownloadNames(
        mods: library,
        pages: pages,
        write: (id, update) async {
          writes[id] = update(library.firstWhere((m) => m.id == id).origin);
          return OriginWriteResult.written;
        },
      );

      expect(wrote, isTrue);
      expect(writes.keys, ['zhuyuan_blacksuit_culture_edit_52313']);
      expect(writes.values.single?.patches.single.name, 'Zhu Yuan - Black-Suit edit');
    });

    test('a failed write is not a reason to stop', () async {
      final asked = <String>[];
      final wrote = await rememberDownloadNames(
        mods: [mod('a', stacked()), mod('b', stacked())],
        pages: pages,
        write: (id, _) async {
          asked.add(id);
          return OriginWriteResult.writeFailed;
        },
      );
      expect(wrote, isFalse);
      expect(asked, ['a', 'b']);
    });

    testWidgets("after a check, leaves a mod whose folder is being written", (tester) async {
      final container = ProviderContainer(overrides: [
        libraryOf([mod('a', stacked()), mod('b', stacked())]),
      ]);
      addTearDown(container.dispose);
      container.read(modWritesInProgressProvider.notifier).state = {'b'};
      late WidgetRef widgetRef;
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: Consumer(builder: (_, ref, _) {
          widgetRef = ref;
          return const SizedBox();
        }),
      ));

      final asked = <String>[];
      await rememberDownloadNamesFrom(widgetRef, pages, writer: (id, _) async {
        asked.add(id);
        return OriginWriteResult.declined;
      });

      expect(asked, ['a']);
    });
  });
}
