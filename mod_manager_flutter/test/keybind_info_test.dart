import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/keybind_info.dart';

void main() {
  group('KeybindInfo.keyValue (case-insensitive lookup)', () {
    test('resolves lowercase "key"', () {
      final kb = KeybindInfo(section: 'KeySwap', keys: {'key': 'ctrl VK_UP'});
      expect(kb.keyValue, 'ctrl VK_UP');
    });

    test('resolves capitalised "Key" (the bug: was dropped before)', () {
      final kb = KeybindInfo(section: 'KeySwap0', keys: {'Key': 'alt VK_UP'});
      expect(kb.keyValue, 'alt VK_UP');
    });

    test('all four sections from the bug report resolve a key value', () {
      final keybinds = [
        KeybindInfo(section: 'KeySwapBody', keys: {'key': 'ctrl shift no_alt VK_UP'}),
        KeybindInfo(section: 'KeySwap', keys: {'key': 'ctrl no_shift no_alt VK_UP'}),
        KeybindInfo(section: 'KeySwap0', keys: {'Key': 'no_ctrl no_shift alt VK_UP'}),
        KeybindInfo(section: 'KeySwap1', keys: {'Key': 'ctrl no_shift no_alt VK_DOWN'}),
      ];
      final valid = keybinds.where((kb) => kb.keyValue != null && kb.keyValue!.isNotEmpty);
      expect(valid.length, 4);
    });

    test('returns null when no key field is present', () {
      final kb = KeybindInfo(section: 'KeySwap', keys: {'condition': r'$active == 1'});
      expect(kb.keyValue, isNull);
    });
  });

  group('VK_ display formatting (read-only)', () {
    test('strips VK_ from key tokens, leaves modifiers', () {
      expect(KeybindInfo.formatForDisplay('ctrl shift no_alt VK_UP'),
          'ctrl shift no_alt UP');
      expect(KeybindInfo.formatForDisplay('VK_F1'), 'F1');
    });

    test('displayKeyValue strips VK_; keyValue stays raw', () {
      final kb = KeybindInfo(section: 'KeySwap', keys: {'Key': 'alt VK_DOWN'});
      expect(kb.displayKeyValue, 'alt DOWN');
      expect(kb.keyValue, 'alt VK_DOWN');
    });
  });

  group('value equality', () {
    // Load-bearing rather than tidiness: these are re-parsed from `.ini` on
    // every library scan, so `modGroupsChanged` compares two fresh instances
    // describing identical bindings. Without `==` that guard saw a change every
    // scan, which is why it skipped keybinds — and why editing a hotkey then
    // left the grid showing the old one.
    KeybindInfo bind(Map<String, String> keys) =>
        KeybindInfo(section: 'KeySwap', keys: keys);

    test('two separately-built bindings with the same content are equal', () {
      expect(bind({'key': 'VK_F7'}), bind({'key': 'VK_F7'}));
      expect(bind({'key': 'VK_F7'}).hashCode, bind({'key': 'VK_F7'}).hashCode);
    });

    test('a different key value is not equal', () {
      expect(bind({'key': 'VK_F7'}), isNot(bind({'key': 'VK_F9'})));
    });

    test('a different section is not equal', () {
      expect(
        KeybindInfo(section: 'KeySwap', keys: const {'key': 'VK_F7'}),
        isNot(KeybindInfo(section: 'KeyUp', keys: const {'key': 'VK_F7'})),
      );
    });

    test('an extra or missing entry is not equal', () {
      expect(bind({'key': 'VK_F7'}),
          isNot(bind({'key': 'VK_F7', 'type': 'cycle'})));
    });

    test('entry order does not affect identity', () {
      // The map is a `LinkedHashMap` ordered by where the lines happen to sit
      // in the file, which is not part of what a binding *is*. `hashCode` has
      // to agree with that or the two disagree inside a Set or a Map.
      final a = bind({'key': 'VK_F7', 'type': 'cycle'});
      final b = bind({'type': 'cycle', 'key': 'VK_F7'});
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect({a, b}, hasLength(1));
    });

    test('a same-length map with a different key name is not equal', () {
      // The comparison walks one map and looks each entry up in the other, so
      // equal lengths alone must not be enough.
      expect(bind({'key': 'VK_F7'}), isNot(bind({'back': 'VK_F7'})));
    });
  });
}
