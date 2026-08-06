import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_file.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/screens/components/marketplace/gb_file_list.dart';
import 'package:mod_manager_flutter/services/installed_mods_index.dart';

import 'support/localized_harness.dart';

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
    required List<GbFile> files,
    List<GbFile> archived = const [],
    bool showArchived = false,
    InstalledModsIndex? installed,
    Size surfaceSize = const Size(900, 700),
    double textScale = 1.0,
  }) async {
    await pumpLocalized(
      tester,
      MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
        child: GbFileList(
          files: files,
          archivedFiles: archived,
          showArchived: showArchived,
          onToggleArchived: () {},
          onDownload: (_) {},
          matchInstalled: installed == null
              ? null
              : (f) => installed.matchFile(fileId: f.idRow, md5: f.md5Checksum),
        ),
      ),
      surfaceSize: surfaceSize,
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
    // The regression this file caught while being written. Worst case: an
    // archived row that is *also* the one you hold, with a long filename and a
    // scan result, at roughly the width the file list gets in a minimum-size
    // window (800px minus the sidebar and padding), at a 1.6× OS text scale.
    //
    // A second chip broke this at **1.3×** while the row was a `Row`: chip labels
    // are three words with nothing to ellipsise, so the filename was the only
    // thing that could give way, and once it had shrunk to nothing the row
    // overflowed. As a `Wrap` the chips move to a second line instead. 1.6 rather
    // than 2.0 deliberately — at 2.0 the row's *outer* layout (scan-result chip
    // plus download button) overflows on its own, with or without any of this.
    await pumpList(
      tester,
      files: const [],
      archived: [
        GbFile(
          idRow: 4,
          file: 'a-rather-long-archive-filename-v1.0.zip',
          description: 'Full Mod, white hair variant',
          md5Checksum: 'abc',
          avResult: 'clean',
          isArchived: true,
        ),
      ],
      showArchived: true,
      installed: library(archiveMd5: 'abc'),
      textScale: 1.6,
      surfaceSize: const Size(530, 900),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('you have this'), findsOneWidget);
    expect(find.text('older'), findsOneWidget);
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
}

/// Builds the `ModInfo` shape the index reads, without dragging the whole runtime
/// view into every test body.
class ModInfoStub {
  static ModInfo mod(String name, {int? fileId, String? archiveMd5}) => ModInfo(
        id: name,
        name: name,
        characterId: 'unknown',
        isActive: false,
        origin: ModOrigin(
          provenance: OriginProvenance.downloaded,
          source: 'gamebanana',
          modId: 700727,
          modIdConfidence: OriginConfidence.exact,
          fileId: fileId,
          archiveMd5: archiveMd5,
        ),
      );
}
