import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/services/ini_resources.dart';
import 'package:mod_manager_flutter/services/update_apply/stale_ini.dart';

void main() {
  /// [existingFiles] defaults to "the folder has everything its `.ini` files
  /// name", which is what every case below except the template one assumes.
  StaleIniAssessment assess({
    required Map<String, String> existing,
    required Map<String, String> incomingInis,
    required Set<String> incomingFiles,
    Set<String>? existingFiles,
  }) {
    final references = collectIniReferences(existing);
    return assessStaleInis(
      existingReferences: references,
      existingInis: existing.keys.map(normalizeIniPath).toSet(),
      existingFiles: existingFiles ?? references.paths,
      incomingInis: incomingInis.keys.map(normalizeIniPath).toSet(),
      incomingFiles: incomingFiles,
    );
  }

  test('an upstream rename leaves a stale .ini describing the new content', () {
    final result = assess(
      existing: {'ellen.ini': 'filename = Body.dds\nfilename = Hair.dds'},
      incomingInis: {'ellen_v2.ini': 'filename = Body.dds\nfilename = Hair.dds'},
      incomingFiles: {'ellen_v2.ini', 'body.dds', 'hair.dds'},
    );
    expect(result.stale.map((s) => s.path), ['ellen.ini']);
    expect(result.stale.single.sharedResources, 2);
    expect(result.keptUndecidable, isEmpty);
  });

  test('a hand-merged second mod is left alone, not offered for deletion', () {
    // The correction this rule exists for. "Any .ini we did not just write is a
    // leftover" would offer to delete this one by default — the same
    // destruction overwrite was chosen to prevent, with a dialog in front of it.
    final result = assess(
      existing: {
        'ellen.ini': 'filename = Body.dds',
        'lycaon.ini': 'filename = LycaonBody.dds',
      },
      incomingInis: {'ellen_v2.ini': 'filename = Body.dds'},
      incomingFiles: {'ellen_v2.ini', 'body.dds'},
    );
    expect(result.stale.map((s) => s.path), ['ellen.ini']);
    expect(result.keptUndecidable, ['lycaon.ini']);
  });

  test('an .ini the write overwrites is not a leftover at all', () {
    final result = assess(
      existing: {'ellen.ini': 'filename = Body.dds'},
      incomingInis: {'ellen.ini': 'filename = Body.dds'},
      incomingFiles: {'ellen.ini', 'body.dds'},
    );
    expect(result.isEmpty, isTrue);
  });

  test('a patch .ini shares the mod filename, so it never reaches here', () {
    // Stated as a test because it is the reason this prompt is occasional
    // rather than routine.
    final result = assess(
      existing: {'ellen.ini': 'filename = Body.dds'},
      incomingInis: {'ellen.ini': 'filename = Body.dds\nfilename = Fix.dds'},
      incomingFiles: {'ellen.ini', 'body.dds', 'fix.dds'},
    );
    expect(result.stale, isEmpty);
  });

  test('an .ini naming nothing checkable is kept without asking', () {
    final result = assess(
      existing: {'notes.ini': r'filename = $\ns\slot.dds'},
      incomingInis: {'ellen.ini': 'filename = Body.dds'},
      incomingFiles: {'ellen.ini', 'body.dds'},
    );
    expect(result.stale, isEmpty);
    expect(result.keptUndecidable, ['notes.ini']);
  });

  test('partial overlap is not enough — every reference must be supplied', () {
    final result = assess(
      existing: {'old.ini': 'filename = Body.dds\nfilename = Extra.dds'},
      incomingInis: {'new.ini': 'filename = Body.dds'},
      incomingFiles: {'new.ini', 'body.dds'},
    );
    expect(result.stale, isEmpty);
    expect(result.keptUndecidable, ['old.ini']);
  });

  test('a template .ini is judged on what the folder actually has', () {
    // The measured shape: a ZZZ extraction tool emits an `.ini` covering every
    // component of the character, and the author ships only the one they
    // replaced — 8 of 36 files on the real mod this came from. Comparing
    // against the whole reference list would find the 28 never-present ones
    // absent from the incoming download too and conclude "not stale", quietly
    // leaving a renamed duplicate `.ini` in the folder.
    final result = assess(
      existing: {
        'wings.ini': 'filename = Wings.dds\n'
            'filename = Jets1.dds\n'
            'filename = Jets2.dds',
      },
      existingFiles: {'wings.dds'},
      incomingInis: {'wings_v2.ini': 'filename = Wings.dds'},
      incomingFiles: {'wings_v2.ini', 'wings.dds'},
    );
    expect(result.stale.map((s) => s.path), ['wings.ini']);
    expect(result.stale.single.sharedResources, 1);
  });

  test('the same rule reads in reverse for a rollback', () {
    // Restoring an old version orphans the .ini the newer one added; it is stale
    // exactly when the snapshot carries everything it names.
    final result = assess(
      existing: {'ellen_v2.ini': 'filename = Body.dds'},
      incomingInis: {'ellen.ini': 'filename = Body.dds'},
      incomingFiles: {'ellen.ini', 'body.dds'},
    );
    expect(result.stale.map((s) => s.path), ['ellen_v2.ini']);
  });
}
