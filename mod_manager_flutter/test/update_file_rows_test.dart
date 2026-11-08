import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/core/palette.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_file.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_update.dart';
import 'package:mod_manager_flutter/screens/components/latest_update_post.dart';
import 'package:mod_manager_flutter/screens/components/update_file_rows.dart';
import 'package:mod_manager_flutter/screens/components/zenith_controls.dart';
import 'package:mod_manager_flutter/screens/dialogs/reinstall_dialog.dart';

import 'support/localized_harness.dart';

void main() {
  final file = GbFile(
    idRow: 1,
    file: 'SharkHoodie_v2.1.7z',
    description: 'Hood up',
    filesize: 142 * 1024 * 1024,
    dateAdded: DateTime.utc(2026, 10, 1, 12),
  );

  Future<void> pumpRows(WidgetTester tester, List<Widget> rows, {Size surface = const Size(640, 600)}) async {
    await pumpLocalized(
      tester,
      Material(child: Center(child: SizedBox(width: surface.width - 40, child: FileRadioGroup(label: 'Newer', rows: rows)))),
      surfaceSize: surface,
    );
    expectBuilt(FileRadioGroup);
  }

  testWidgets('a row names the file, its variant, its date and its size, and a tap picks it', (tester) async {
    var taps = 0;
    await pumpRows(tester, [FileRadioRow(file: file, selected: false, onTap: () => taps++)]);

    expect(find.text('SharkHoodie_v2.1.7z'), findsOneWidget);
    expect(find.text('Hood up'), findsOneWidget);
    expect(find.text('uploaded 2026-10-01'), findsOneWidget);
    expect(find.text('142 MB'), findsOneWidget);

    await tester.tap(find.text('SharkHoodie_v2.1.7z'));
    expect(taps, 1);
  });

  testWidgets('only the selected row takes the picked ground, and it says it is checked', (tester) async {
    await pumpRows(tester, [
      FileRadioRow(file: file, selected: true, onTap: () {}),
      FileRadioRow(file: GbFile(idRow: 2, file: 'Other.7z'), selected: false, onTap: () {}),
    ]);
    final palette = ZenithPalette.of(tester.element(find.byType(FileRadioGroup)));

    Color? groundOf(String name) => tester
        .widget<Material>(find.ancestor(of: find.text(name), matching: find.byType(Material)).first)
        .color;
    expect(groundOf('SharkHoodie_v2.1.7z'), palette.rowPicked);
    expect(groundOf('Other.7z'), Colors.transparent);

    final handle = tester.ensureSemantics();
    await tester.pump();
    expect(
      tester.getSemantics(find.byType(FileRadioRow).first),
      isSemantics(hasCheckedState: true, isChecked: true, isInMutuallyExclusiveGroup: true),
    );
    expect(
      tester.getSemantics(find.byType(FileRadioRow).last),
      isSemantics(hasCheckedState: true, isChecked: false, isInMutuallyExclusiveGroup: true),
    );
    handle.dispose();
  });

  testWidgets('a file with no variant text says so in italics, and a long one wraps instead of overflowing', (tester) async {
    final long = GbFile(
      idRow: 3,
      file: 'PastelBurnice_NoJacket.zip',
      description: 'No jacket version, for people who asked in the comments. Use this instead of the main file, '
          'not together with it!',
      filesize: 118 * 1024 * 1024,
      dateAdded: DateTime.utc(2026, 10, 1),
    );
    await pumpRows(tester, [
      FileRadioRow(file: GbFile(idRow: 4, file: 'Plain.zip'), selected: false, onTap: () {}),
      FileRadioRow(file: long, selected: false, onTap: () {}),
    ], surface: const Size(420, 600));

    final none = tester.widget<Text>(find.text('no variant text'));
    expect(none.style?.fontStyle, FontStyle.italic);
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.textContaining('No jacket version')).height, greaterThan(30));
  });

  testWidgets('a row with no onTap is not pressable', (tester) async {
    await pumpRows(tester, [FileRadioRow(file: file, selected: false, onTap: null)]);

    expect(tester.widget<InkWell>(find.byType(InkWell)).onTap, isNull);
  });

  testWidgets('a screen reader hears the suggestion chip and the size with the name, not only the name and the date',
      (tester) async {
    await pumpLocalized(
      tester,
      Material(
        child: Builder(
          builder: (context) => FileRadioGroup(
            label: 'Newer',
            rows: [
              FileRadioRow(
                file: file,
                selected: true,
                onTap: () {},
                chip: ZenithBadge(label: 'matches your variant', tone: ZenithPalette.of(context).badgeInfo, small: true),
              ),
              FileRadioRow(file: file, selected: false, onTap: () {}),
            ],
          ),
        ),
      ),
    );
    final handle = tester.ensureSemantics();
    await tester.pump();

    expect(
      tester.getSemantics(find.byType(FileRadioRow).first).label,
      'SharkHoodie_v2.1.7z, matches your variant, Hood up, uploaded 2026-10-01, 142 MB',
    );
    expect(
      tester.getSemantics(find.byType(FileRadioRow).last).label,
      'SharkHoodie_v2.1.7z, Hood up, uploaded 2026-10-01, 142 MB',
    );
    handle.dispose();
  });

  testWidgets('the reinstall card and the update row say the same words about one file', (tester) async {
    final versioned = GbFile(
      idRow: 9,
      file: 'Shark_v3.zip',
      version: '3.0',
      description: 'Hood up',
      filesize: 2 * 1024 * 1024,
      dateAdded: DateTime.utc(2026, 10, 1),
    );
    final mod = ModInfo(id: 'Shark', name: 'Shark', characterId: 'ellen', isActive: false);

    await pumpLocalized(tester, Material(child: FileRadioGroup(label: 'Newer', rows: [FileRadioRow(file: versioned, selected: false, onTap: () {})])));
    expect(find.text('3.0 · Hood up'), findsOneWidget);

    await pumpLocalized(tester, ReinstallDialog(mod: mod, file: versioned));
    expect(find.textContaining('Shark_v3.zip · 3.0 · Hood up · uploaded 2026-10-01 · 2.0 MB', findRichText: true), findsOneWidget);
  });

  test('the latest post is the newest one that says something, and not one older than the file in use', () {
    final old = GbUpdate(idRow: 1, name: 'v1', dateAdded: DateTime.utc(2026, 1, 1), text: '<p>old</p>');
    final upload = GbUpdate(idRow: 2, dateAdded: DateTime.utc(2026, 9, 1));
    final news = GbUpdate(idRow: 3, name: 'v2', dateAdded: DateTime.utc(2026, 8, 1), text: '<p>new</p>');

    expect(latestUpdatePost([old, upload, news])?.idRow, 3, reason: 'a file upload with no text is not news');
    expect(latestUpdatePost([old], since: DateTime.utc(2026, 2, 1)), isNull);
    expect(latestUpdatePost([old, news], since: DateTime.utc(2026, 2, 1))?.idRow, 3);
    expect(latestUpdatePost(null), isNull);
  });

  test('a post with no date is not news against a file with one, and is still the latest when there is nothing to compare', () {
    final dateless = GbUpdate(idRow: 5, name: 'v0', text: '<p>who knows when</p>');
    final dated = GbUpdate(idRow: 6, name: 'v2', dateAdded: DateTime.utc(2026, 8, 1), text: '<p>new</p>');

    expect(latestUpdatePost([dateless], since: DateTime.utc(2026, 2, 1)), isNull);
    expect(latestUpdatePost([dateless, dated], since: DateTime.utc(2026, 2, 1))?.idRow, 6);
    expect(latestUpdatePost([dateless])?.idRow, 5, reason: 'with no date to compare against the newest post is shown');
  });
}
