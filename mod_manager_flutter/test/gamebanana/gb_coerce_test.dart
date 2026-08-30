import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_coerce.dart';

/// The coercion helpers absorb GameBanana's wire-format quirks. They are pure
/// functions with no network and no UI, which makes them exactly the kind of
/// thing that has to be tested — a wrong answer here is silent and
/// surfaces much later as bad update verdicts.
void main() {
  group('gbInt', () {
    test('reads plain ints', () => expect(gbInt(42), 42));

    test('reads the string form', () {
      // `_nStatus` arrives as "0" despite the `_n` prefix, so any numeric
      // field is treated as possibly stringly-typed.
      expect(gbInt('0'), 0);
      expect(gbInt('19567'), 19567);
      expect(gbInt(' 12 '), 12);
    });

    test('returns null for junk rather than throwing', () {
      expect(gbInt(null), isNull);
      expect(gbInt('abc'), isNull);
      expect(gbInt(<String>[]), isNull);
    });
  });

  group('gbBool', () {
    test('reads bools, numbers and strings', () {
      expect(gbBool(true), isTrue);
      expect(gbBool(false), isFalse);
      expect(gbBool(1), isTrue);
      expect(gbBool(0), isFalse);
      expect(gbBool('1'), isTrue);
      expect(gbBool('true'), isTrue);
      expect(gbBool('0'), isFalse);
      expect(gbBool(''), isFalse);
    });

    test('falls back to orElse for anything unrecognised', () {
      expect(gbBool(null), isFalse);
      expect(gbBool(null, orElse: true), isTrue);
      expect(gbBool('maybe', orElse: true), isTrue);
    });
  });

  group('gbTimestamp', () {
    test('converts unix seconds to UTC', () {
      final result = gbTimestamp(1722287660);
      expect(result, isNotNull);
      expect(result!.isUtc, isTrue);
      expect(result.millisecondsSinceEpoch, 1722287660 * 1000);
    });

    test('treats 0 as "never", NOT as 1970', () {
      // The single most consequential coercion in the layer. Returning the
      // epoch would make every never-updated mod look ancient to the update
      // comparator, i.e. permanently "possibly outdated".
      expect(gbTimestamp(0), isNull);
      expect(gbTimestamp('0'), isNull);
    });

    test('returns null for missing or unparseable values', () {
      expect(gbTimestamp(null), isNull);
      expect(gbTimestamp('not a date'), isNull);
    });
  });

  group('gbString', () {
    test('trims', () => expect(gbString('  hi  '), 'hi'));

    test('collapses empty to null', () {
      // An empty `_sVersion` means "no version", not "the version is ''".
      expect(gbString(''), isNull);
      expect(gbString('   '), isNull);
    });

    test('returns null for non-strings', () {
      expect(gbString(null), isNull);
      expect(gbString(7), isNull);
    });
  });

  group('gbObjects / gbObject', () {
    test('reads a list of objects and skips non-objects', () {
      expect(gbObjects([
        {'a': 1},
        'nope',
        {'b': 2},
      ]), hasLength(2));
    });

    test('a missing collection is an empty list, never an error', () {
      expect(gbObjects(null), isEmpty);
      expect(gbObjects('nope'), isEmpty);
    });

    test('gbObject reads a nested object or null', () {
      expect(gbObject({'a': 1}), {'a': 1});
      expect(gbObject(null), isNull);
      expect(gbObject(<String>[]), isNull);
    });
  });

  group('gbTags', () {
    test('reads the flattened strings a listing sends', () {
      expect(gbTags(['cheongsam: ellen', 'Software Used: Blender']),
          ['cheongsam: ellen', 'Software Used: Blender']);
    });

    test('reads the objects a ProfilePage sends, flattened the same way', () {
      // The shape difference between the two endpoints is the whole reason this
      // helper exists: reading only the string form left a profile's tags empty,
      // silently, because both captured profile fixtures happen to have none.
      expect(
        gbTags([
          {'_sTitle': 'Software Used', '_sValue': 'Blender'},
          {'_sTitle': 'Ellen', '_sValue': 'Chained school uniforms'},
        ]),
        ['Software Used: Blender', 'Ellen: Chained school uniforms'],
      );
    });

    test('tolerates a half-filled pair, and drops an empty one', () {
      expect(gbTags([{'_sTitle': 'Ellen'}]), ['Ellen']);
      expect(gbTags([{'_sValue': 'swimsuit'}]), ['swimsuit']);
      expect(gbTags([{'_sTitle': '', '_sValue': null}]), isEmpty);
      expect(gbTags([<String, dynamic>{}]), isEmpty);
    });

    test('drops empties and non-strings', () {
      expect(gbTags(['a', '', null, 3, '  b  ']), ['a', 'b']);
      expect(gbTags(null), isEmpty);
    });
  });

  group('gbStringMap', () {
    test('reads a code -> label map, as _aContentRatings arrives', () {
      expect(gbStringMap({'sa': 'Skimpy Attire'}), {'sa': 'Skimpy Attire'});
    });

    test('null (an unrated mod) is an empty map', () {
      expect(gbStringMap(null), isEmpty);
      expect(gbStringMap(<String>[]), isEmpty);
    });
  });
}
