import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/services/import_review.dart';

/// The import review's rules, with no dialog and no library on disk (`docs/importing-mods.md` §2 to §4).
void main() {
  ImportItem item(
    String name, {
    String? id,
    String? guess,
    String? picked,
    OnClash choice = OnClash.update,
  }) => ImportItem(
    id: id ?? name,
    sources: ['/drop/$name'],
    label: name,
    kind: ImportSourceKind.folder,
    name: name,
    guessedCharacter: guess,
    pickedCharacter: picked,
    choice: choice,
  );

  ExistingMod existing(String id, {String character = 'ellen', bool busy = false}) =>
      ExistingMod(id: id, characterId: character, busy: busy);

  group('the character', () {
    test('is the guess until the user picks one, and the pick wins', () {
      final guessed = evaluateImport([item('A', guess: 'ellen')], const []);
      expect(guessed.rows.single.character, 'ellen');

      final picked = evaluateImport([item('A', guess: 'ellen', picked: 'cat_ui')], const []);
      expect(picked.rows.single.character, 'cat_ui');
    });

    test('is missing when nothing says, which stops the import and names the row', () {
      final review = evaluateImport([item('Shark'), item('Hood', guess: 'ellen'), item('Fin')], const []);

      expect(review.canImport, isFalse);
      expect(review.blocked!.kind, BlockedKind.character);
      expect(review.blocked!.name, 'Shark');
      expect(review.blocked!.more, 1);
    });

    test('Unassigned is an answer', () {
      final review = evaluateImport([item('A', picked: 'unknown')], const []);

      expect(review.canImport, isTrue);
    });
  });

  group('the name', () {
    test('an empty or invalid name stops the import, and the row is named by its source when it is empty', () {
      const blank = ImportItem(
        id: 'x',
        sources: ['/drop/folder_x'],
        label: 'folder_x',
        kind: ImportSourceKind.folder,
        name: '  ',
        guessedCharacter: 'ellen',
      );
      final empty = evaluateImport([blank], const []);
      expect(empty.rows.single.problem, NameProblem.empty);
      expect(empty.blocked!.kind, BlockedKind.name);
      expect(empty.blocked!.name, 'folder_x');

      for (final bad in ['a/b', r'a\b', 'a:b', '.hidden', '__x', 'what?']) {
        final review = evaluateImport([item(bad, guess: 'ellen')], const []);
        expect(review.rows.single.problem, NameProblem.invalid, reason: bad);
        expect(review.canImport, isFalse, reason: bad);
      }
    });

    test('two rows that end up in one folder are twins, ignoring letter case', () {
      final review = evaluateImport([
        item('Same', id: 'a', guess: 'ellen'),
        item('same', id: 'b', guess: 'ellen'),
        item('Other', guess: 'ellen'),
      ], const []);

      expect(review.rows.map((r) => r.problem), [NameProblem.twin, NameProblem.twin, null]);
      expect(review.canImport, isFalse);
    });
  });

  group('a mod the library already has', () {
    test('is found library-wide whatever its character, and ignoring letter case', () {
      final review = evaluateImport([item('winter maid', guess: 'nicole')], [existing('Winter Maid')]);

      final row = review.rows.single;
      expect(row.clashes, isTrue);
      expect(row.existing!.id, 'Winter Maid');
    });

    test('where the library holds Foo and foo, each name matches its own folder', () {
      final library = [existing('Foo', character: 'ellen'), existing('foo', character: 'nicole')];

      final review = evaluateImport([item('foo', id: 'a'), item('Foo', id: 'b')], library);

      expect(review.rows[0].existing!.characterId, 'nicole');
      expect(review.rows[0].finalName, 'foo');
      expect(review.rows[1].existing!.characterId, 'ellen');
      expect(review.rows[1].finalName, 'Foo');
    });

    test('where the library holds Foo and foo, a third spelling matches neither rather than the wrong one', () {
      final library = [existing('Foo'), existing('foo')];

      final review = evaluateImport([item('FOO', guess: 'ellen')], library);

      expect(review.rows.single.clashes, isFalse);
      expect(review.rows.single.finalName, 'FOO');
    });

    test('Update it is the default and takes the existing mod\'s folder and character', () {
      final review = evaluateImport([item('winter maid', guess: 'nicole')], [existing('Winter Maid')]);

      final row = review.rows.single;
      expect(row.updates, isTrue);
      expect(row.finalName, 'Winter Maid', reason: 'the folder keeps the spelling it has');
      expect(row.character, 'ellen', reason: 'a guess from the name never moves a mod');
    });

    test('a character the user picked beats the existing mod\'s', () {
      final review = evaluateImport([item('Winter Maid', picked: 'cat_ui')], [existing('Winter Maid')]);

      expect(review.rows.single.character, 'cat_ui');
    });

    test('Keep both takes the first free Name (n), in the library and among the rows', () {
      final review = evaluateImport(
        [
          item('Maid', id: 'a', guess: 'ellen', choice: OnClash.keepBoth),
          item('Maid', id: 'b', guess: 'ellen', choice: OnClash.keepBoth),
        ],
        [existing('Maid'), existing('Maid (2)')],
      );

      expect(review.rows.map((r) => r.finalName), ['Maid (3)', 'Maid (4)']);
      expect(review.rows.map((r) => r.problem), [null, null]);
      expect(review.canImport, isTrue);
    });

    test('Keep both does not take a name another row types for itself', () {
      final review = evaluateImport(
        [
          item('Maid', id: 'a', guess: 'ellen', choice: OnClash.keepBoth),
          item('Maid (2)', id: 'b', guess: 'ellen'),
        ],
        [existing('Maid')],
      );

      expect(review.rows.map((r) => r.finalName), ['Maid (3)', 'Maid (2)']);
    });

    test('two rows set to Update it for one mod are twins; one of each is not', () {
      final both = evaluateImport(
        [item('Maid', id: 'a'), item('Maid', id: 'b')],
        [existing('Maid')],
      );
      expect(both.rows.map((r) => r.problem), [NameProblem.twin, NameProblem.twin]);

      final mixed = evaluateImport(
        [item('Maid', id: 'a'), item('Maid', id: 'b', choice: OnClash.keepBoth)],
        [existing('Maid')],
      );
      expect(mixed.rows.map((r) => r.problem), [null, null]);
      expect(mixed.rows.map((r) => r.finalName), ['Maid', 'Maid (2)']);
    });

    test('a mod whose folder is being written cannot be updated, so the row keeps both', () {
      final review = evaluateImport([item('Maid', guess: 'ellen')], [existing('Maid', busy: true)]);

      final row = review.rows.single;
      expect(row.updateBlocked, isTrue);
      expect(row.updates, isFalse);
      expect(row.choice, OnClash.keepBoth);
      expect(row.finalName, 'Maid (2)');
    });

    test('a name that no longer matches is a plain new mod, whatever was chosen before', () {
      final review = evaluateImport([item('Maid 2', guess: 'ellen')], [existing('Maid')]);

      expect(review.rows.single.clashes, isFalse);
      expect(review.rows.single.finalName, 'Maid 2');
    });
  });

  group('whether the import may go ahead', () {
    test('a character stops it before a name does, and the count of the rest is given', () {
      final review = evaluateImport([
        item('a/b', id: '1', guess: 'ellen'),
        item('Fine', id: '2'),
        item('Also', id: '3'),
      ], const []);

      expect(review.blocked!.kind, BlockedKind.character);
      expect(review.blocked!.name, 'Fine');
      expect(review.blocked!.more, 1);
    });

    test('with nothing wrong it can import, and with no rows it cannot', () {
      expect(evaluateImport([item('A', guess: 'ellen')], const []).canImport, isTrue);
      expect(evaluateImport(const [], const []).canImport, isFalse);
    });

    test('a pick is forgotten when the choice changes', () {
      final picked = item('Maid', picked: 'cat_ui');

      expect(picked.copyWith(choice: OnClash.keepBoth, clearPick: true).pickedCharacter, isNull);
      expect(picked.copyWith(choice: OnClash.keepBoth).pickedCharacter, 'cat_ui');
    });
  });
}
