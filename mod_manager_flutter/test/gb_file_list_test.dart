import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/core/palette.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_file.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_mod.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_page.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/screens/components/marketplace/gb_file_list.dart';
import 'package:mod_manager_flutter/services/installed_mods_index.dart';

import 'support/fixtures.dart';
import 'support/localized_harness.dart';
import 'support/origin_shorthand.dart';

/// The mod detail screen's file list, and specifically what it claims about the
/// local library.
///
/// The claims are the risky part, not the layout. "You installed this file" and
/// "these bytes are identical to a file you installed" are different statements
/// resting on different evidence, and an md5 match is a **matching key** — never
/// an integrity or authenticity claim. Collapsing the two, or dressing either as
/// verification, is the failure this file guards against.
void main() {
  GbFile file(int id, {String? md5, String label = 'Main file'}) =>
      GbFile(idRow: id, file: 'mod-$id.zip', description: label, md5Checksum: md5);

  Future<void> pumpList(
    WidgetTester tester, {
    required List<GbFile>? files,
    List<GbFile> archived = const [],
    bool showArchived = false,
    Set<int> picked = const {},
    ValueChanged<GbFile>? onToggle,
    VoidCallback? onToggleArchived,
    InstalledModsIndex? installed,
    Size surfaceSize = const Size(900, 700),
    double textScale = 1.0,
    Brightness brightness = Brightness.dark,
    DateTime? now,
  }) async {
    await pumpLocalized(
      tester,
      MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
        child: SingleChildScrollView(
          child: GbFileList(
            files: files,
            archivedFiles: archived,
            showArchived: showArchived,
            picked: picked,
            onToggle: onToggle ?? (_) {},
            onToggleArchived: onToggleArchived ?? () {},
            now: now,
            matchInstalled: installed == null
                ? null
                : (f) => installed.matchFile(fileId: f.idRow, md5: f.md5Checksum),
          ),
        ),
      ),
      surfaceSize: surfaceSize,
      brightness: brightness,
    );
    expectBuilt(GbFileList);
  }

  /// A library holding one mod, described the way the origin block would.
  InstalledModsIndex library({
    String folder = 'Ellen Swimsuit',
    int? fileId,
    String? archiveMd5,
  }) {
    return InstalledModsIndex.fromMods([
      ModInfoStub.mod(folder, fileId: fileId, archiveMd5: archiveMd5),
    ]);
  }

  testWidgets('says nothing when no library snapshot was supplied',
      (tester) async {
    // Every caller that has no library — tests, and any future embedding — gets
    // silence rather than a default claim.
    await pumpList(tester, files: [file(1)]);
    expect(find.text('installed'), findsNothing);
    expect(find.text('you have this'), findsNothing);
  });

  testWidgets('marks the exact file that was installed', (tester) async {
    await pumpList(
      tester,
      files: [file(1), file(2, label: 'Patch')],
      installed: library(fileId: 2),
    );
    expect(find.text('installed'), findsOneWidget);
    expect(
      find.byTooltip('This is the file you installed as Ellen Swimsuit'),
      findsOneWidget,
    );
  });

  testWidgets('words a hash match as bytes, not as an installation',
      (tester) async {
    // The distinction is load-bearing: we never recorded this file id, so the
    // honest statement is that the archive was byte-identical to it.
    await pumpList(
      tester,
      files: [file(1, md5: 'd41d8cd98f00b204e9800998ecf8427e')],
      installed: library(archiveMd5: 'd41d8cd98f00b204e9800998ecf8427e'),
    );
    expect(find.text('you have this'), findsOneWidget);
    expect(find.text('installed'), findsNothing);
    expect(
      find.byTooltip(
        'Byte-identical to the archive you installed as Ellen Swimsuit',
      ),
      findsOneWidget,
    );
  });

  testWidgets('a mod in the library says nothing about its other files',
      (tester) async {
    // The mod-level "in library" answer lives on the card and in the detail
    // header. Letting it leak down to every row would tell the user they have
    // three files when they have one.
    await pumpList(
      tester,
      files: [file(1), file(2), file(3)],
      installed: library(fileId: 2),
    );
    expect(find.text('installed'), findsOneWidget);
  });

  testWidgets('an archived file can be the one you hold', (tester) async {
    // The case a banked hash is best at: an old install matches a *superseded*
    // file more often than the current one, and that is exactly the "you have an
    // old one" verdict that would otherwise stay unknown.
    await pumpList(
      tester,
      files: [file(9, label: 'Current')],
      archived: [file(4, md5: 'abc', label: 'v1.0')],
      showArchived: true,
      installed: library(archiveMd5: 'abc'),
    );
    expect(find.text('you have this'), findsOneWidget);
  });

  testWidgets('an archived match stays hidden while archived files are',
      (tester) async {
    await pumpList(
      tester,
      files: [file(9, label: 'Current')],
      archived: [file(4, md5: 'abc', label: 'v1.0')],
      installed: library(archiveMd5: 'abc'),
    );
    expect(find.text('you have this'), findsNothing);
  });

  testWidgets('a row carrying every chip survives a scaled-up narrow window',
      (tester) async {
    // Worst case: an archived row that is *also* the one you hold, with a long filename and a scan result that is
    // not clean, at the side panel's width in a minimum-size window (800px minus the sidebar, the gutters and the
    // panel's padding), at a 1.4× OS text scale. The chips sit on a line of their own under the file's text and
    // wrap there, so only the filename gives way, with an ellipsis.
    await pumpList(
      tester,
      files: const [],
      archived: [
        GbFile(
          idRow: 4,
          file: 'a-rather-long-archive-filename-v1.0.zip',
          description: 'Full Mod, white hair variant',
          md5Checksum: 'abc',
          filesize: 214 * 1024 * 1024,
          avResult: 'suspicious',
          isArchived: true,
        ),
      ],
      showArchived: true,
      installed: library(archiveMd5: 'abc'),
      textScale: 1.4,
      surfaceSize: const Size(480, 900),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('you have this'), findsOneWidget);
    expect(find.text('older'), findsOneWidget);
    expect(find.text('suspicious'), findsOneWidget);
  });

  group('picking', () {
    final three = [
      GbFile(idRow: 1, file: 'a.zip', description: 'Full dress', dateAdded: DateTime.utc(2026, 10, 16)),
      GbFile(idRow: 2, file: 'b.7z', dateAdded: DateTime.utc(2026, 9, 30)),
      const GbFile(idRow: 3, file: 'c.zip'),
    ];

    BoxDecoration pickBox(WidgetTester tester, int fileId) => tester
        .widgetList<Container>(
          find.descendant(of: find.byKey(ValueKey('file_$fileId')), matching: find.byType(Container)),
        )
        .map((c) => c.decoration)
        .whereType<BoxDecoration>()
        .firstWhere((d) => d.borderRadius == BorderRadius.circular(5));

    testWidgets('a picked row fills its check with the accent; the others stay empty', (tester) async {
      await pumpList(tester, files: three, picked: {2});
      final palette = ZenithPalette.dark(AccentChoice.violet);

      expect(pickBox(tester, 2).color, palette.accent);
      expect(
        find.descendant(of: find.byKey(const ValueKey('file_2')), matching: find.byIcon(Icons.check_rounded)),
        findsOneWidget,
      );
      expect(pickBox(tester, 1).color, isNull);
      expect((pickBox(tester, 1).border as Border).top.color, palette.check);
      final ground = tester
          .widget<Material>(find.descendant(of: find.byKey(const ValueKey('file_2')), matching: find.byType(Material)).first)
          .color;
      expect(ground, isNot(palette.field), reason: 'a picked row is washed with the accent');
    });

    testWidgets('pressing a row hands it to onToggle', (tester) async {
      final toggled = <int>[];
      await pumpList(tester, files: three, onToggle: (f) => toggled.add(f.idRow));
      await tester.tap(find.byKey(const ValueKey('file_3')));
      await tester.tap(find.byKey(const ValueKey('file_1')));
      expect(toggled, [3, 1]);
    });

    testWidgets('the second line quotes the variant and says how long ago it was uploaded', (tester) async {
      await pumpList(tester, files: three, now: DateTime.utc(2026, 10, 21));
      expect(find.text('“Full dress” · uploaded 5 days ago'), findsOneWidget);
      expect(find.text('no variant text · uploaded 3 weeks ago'), findsOneWidget);
      expect(find.text('no variant text'), findsOneWidget, reason: 'a file with no date has no age');
    });

    testWidgets('a clean scan says nothing, any other result is shown', (tester) async {
      await pumpList(tester, files: const [
        GbFile(idRow: 1, file: 'a.zip', avResult: 'clean'),
        GbFile(idRow: 2, file: 'b.zip', avResult: 'infected'),
      ]);
      expect(find.text('clean'), findsNothing);
      expect(find.text('infected'), findsOneWidget);
    });

    testWidgets('the size is the file\'s, in mono at the right', (tester) async {
      await pumpList(tester, files: const [GbFile(idRow: 1, file: 'a.zip', filesize: 214 * 1024 * 1024)]);
      final size = tester.widget<Text>(find.text('214 MB'));
      expect(size.style?.fontFamily, 'Geist Mono');
      expect(tester.getTopRight(find.text('214 MB')).dx, greaterThan(tester.getTopRight(find.text('a.zip')).dx));
    });

    testWidgets('older files wait behind a counted link', (tester) async {
      var toggled = 0;
      await pumpList(
        tester,
        files: three,
        archived: const [GbFile(idRow: 9, file: 'old.zip', isArchived: true)],
        onToggleArchived: () => toggled++,
      );
      expect(find.text('old.zip'), findsNothing);
      await tester.tap(find.text('Show 1 older file'));
      expect(toggled, 1);
    });

    testWidgets('a picked older file is listed while the others are hidden', (tester) async {
      await pumpList(
        tester,
        files: three,
        archived: const [
          GbFile(idRow: 9, file: 'old.zip', isArchived: true),
          GbFile(idRow: 8, file: 'older.zip', isArchived: true),
        ],
        picked: const {9},
      );
      expect(find.text('old.zip'), findsOneWidget);
      expect(find.text('older.zip'), findsNothing);
      expect(find.text('Show 1 older file'), findsOneWidget, reason: 'counts only the files it would reveal');
    });

    testWidgets('the link is gone while every older file is picked and listed', (tester) async {
      await pumpList(
        tester,
        files: three,
        archived: const [GbFile(idRow: 9, file: 'old.zip', isArchived: true)],
        picked: const {9},
      );
      expect(find.text('old.zip'), findsOneWidget);
      expect(find.textContaining('older file'), findsNothing);
    });

    test('nothing is picked when a captured mod publishes several current files, the one when it publishes one', () {
      final several = GbMod.fromJson(parseObject(loadGbFixture('mod_profile_rated')))!;
      expect(several.files!.length, greaterThan(1));
      expect(defaultPickedFiles(several.files), isEmpty);

      final one = GbMod.fromJson(parseObject(loadGbFixture('mod_profile_asset_patch')))!;
      expect(one.files, hasLength(1));
      expect(defaultPickedFiles(one.files), {one.files!.single.idRow});
    });
  });

  testWidgets('never dresses a match as verified', (tester) async {
    // md5 is cryptographically broken and is here only because GameBanana
    // publishes it. A match sets a label and skips no check, which is harmless
    // *only* while nothing renders it as trust.
    await pumpList(
      tester,
      files: [file(1, md5: 'abc')],
      installed: library(archiveMd5: 'abc'),
    );
    for (final forbidden in ['verified', 'Verified', 'trusted', 'safe']) {
      expect(find.textContaining(forbidden), findsNothing);
    }
  });

  group('naming a file', () {
    testWidgets('the filename titles the row and the author label sits under it',
        (tester) async {
      // Reported from real data. Mod 674675 publishes
      // `seed_extra_toenails_texture.zip` described as "Put it in the folder
      // with the mod (replace it)" — an *instruction*, which used to stand in
      // the title where the filename belonged, leaving the filename nowhere on
      // screen at all.
      await pumpList(tester, files: [
        const GbFile(
          idRow: 1697000,
          file: 'seed_extra_toenails_texture.zip',
          description: 'Put it in the folder with the mod (replace it)',
        ),
      ]);

      expect(find.text('seed_extra_toenails_texture.zip'), findsOneWidget);
      expect(
        find.text('“Put it in the folder with the mod (replace it)”'),
        findsOneWidget,
      );
    });

    testWidgets('the version joins the label rather than the title',
        (tester) async {
      await pumpList(tester, files: [
        const GbFile(idRow: 1, file: 'v77.zip', version: '7.7',
            description: 'Main file'),
      ]);

      expect(find.text('v77.zip'), findsOneWidget);
      expect(find.text('“7.7 · Main file”'), findsOneWidget);
    });

    testWidgets('a file the author said nothing about says so rather than drawing a blank line', (tester) async {
      await pumpList(tester, files: [
        const GbFile(idRow: 1, file: 'exce_-_seed.zip'),
      ]);

      expect(find.text('exce_-_seed.zip'), findsOneWidget);
      expect(find.text('no variant text'), findsOneWidget);
      expect(find.text(''), findsNothing);
      expect(find.text('“”'), findsNothing);
    });
  });
}

/// Builds the `ModInfo` shape the index reads, without dragging the whole runtime
/// view into every test body.
class ModInfoStub {
  static ModInfo mod(String name, {int? fileId, String? archiveMd5}) => ModInfo(
        id: name,
        name: name,
        characterId: 'unknown',
        isActive: false,
        origin: originFixture(
          provenance: OriginProvenance.downloaded,
          source: 'gamebanana',
          modId: 700727,
          modIdConfidence: OriginConfidence.exact,
          fileId: fileId,
          archiveMd5: archiveMd5,
        ),
      );
}
