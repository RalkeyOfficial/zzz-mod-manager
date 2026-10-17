import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/screens/components/zzmi_folder_field.dart';
import 'package:path/path.dart' as p;

import 'support/localized_harness.dart';

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('zzz_zzmi_field_'));
  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  Future<TextEditingController> pumpField(WidgetTester tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await pumpLocalized(
      tester,
      ZzmiFolderField(
        controller: controller,
        builder: (onBrowse, status) => Column(
          children: [TextField(controller: controller), status],
        ),
      ),
    );
    expectBuilt(ZzmiFolderField);
    return controller;
  }

  /// Types [folder] in the real zone, where the debounce timer and the file reads
  /// it starts can complete, then builds the frame they produce.
  Future<void> enter(WidgetTester tester, TextEditingController controller, String folder) async {
    await tester.runAsync(() async {
      controller.text = folder;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pump();
  }

  testWidgets('a folder with d3dx.ini shows where links and shader fixes go', (tester) async {
    final zzmi = Directory(p.join(temp.path, 'ZZMI'))..createSync();
    File(p.join(zzmi.path, 'd3dx.ini')).writeAsStringSync('[Rendering]\n');
    Directory(p.join(zzmi.path, 'mods')).createSync();

    final controller = await pumpField(tester);
    await enter(tester, controller, zzmi.path);

    expect(
      find.text('Links go in ${p.join(zzmi.path, 'mods')} · '
          'Shader fixes go in ${p.join(zzmi.path, 'ShaderFixes')}'),
      findsOneWidget,
    );
    expect(find.textContaining('No d3dx.ini'), findsNothing);
  });

  testWidgets('a folder without d3dx.ini warns', (tester) async {
    final controller = await pumpField(tester);
    await enter(tester, controller, temp.path);

    expect(find.textContaining('No d3dx.ini in this folder'), findsOneWidget);
    expect(find.textContaining('Links go in'), findsNothing);
  });

  testWidgets('an empty field shows no status', (tester) async {
    await pumpField(tester);

    expect(find.textContaining('Links go in'), findsNothing);
    expect(find.textContaining('No d3dx.ini'), findsNothing);
  });
}
