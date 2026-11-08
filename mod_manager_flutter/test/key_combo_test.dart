import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/services/key_combo.dart';

/// **A recorded key is written the way 3DMigoto spells it** (`docs/key-editing.md` §3).
void main() {
  String? record(
    LogicalKeyboardKey key, {
    PhysicalKeyboardKey? physical,
    bool ctrl = false,
    bool alt = false,
    bool shift = false,
    bool windows = false,
    String? previous,
  }) => recordCombo(
    key: key,
    physical: physical,
    ctrl: ctrl,
    alt: alt,
    shift: shift,
    windows: windows,
    previous: previous,
  );

  group('the key names', () {
    test('letters and digits are the bare lower-case character', () {
      expect(record(LogicalKeyboardKey.keyH), 'h');
      expect(record(LogicalKeyboardKey.digit4), '4');
    });

    test('function, arrow, numpad and editing keys are the VK_ names', () {
      expect(record(LogicalKeyboardKey.f1), 'VK_F1');
      expect(record(LogicalKeyboardKey.f24), 'VK_F24');
      expect(record(LogicalKeyboardKey.arrowUp), 'VK_UP');
      expect(record(LogicalKeyboardKey.numpad7), 'VK_NUMPAD7');
      expect(record(LogicalKeyboardKey.numpadAdd), 'VK_ADD');
      expect(record(LogicalKeyboardKey.space), 'VK_SPACE');
      expect(record(LogicalKeyboardKey.enter), 'VK_RETURN');
      expect(record(LogicalKeyboardKey.tab), 'VK_TAB');
      expect(record(LogicalKeyboardKey.backspace), 'VK_BACK');
      expect(record(LogicalKeyboardKey.pageUp), 'VK_PRIOR');
      expect(record(LogicalKeyboardKey.pageDown), 'VK_NEXT');
    });

    test('punctuation is the VK_OEM_ set', () {
      expect(record(LogicalKeyboardKey.semicolon), 'VK_OEM_1');
      expect(record(LogicalKeyboardKey.equal), 'VK_OEM_PLUS');
      expect(record(LogicalKeyboardKey.minus), 'VK_OEM_MINUS');
      expect(record(LogicalKeyboardKey.bracketLeft), 'VK_OEM_4');
      expect(record(LogicalKeyboardKey.quote), 'VK_OEM_7');
    });

    test('a digit pressed with Shift is found by its position', () {
      // The logical key is the shifted character, which has no name.
      expect(record(LogicalKeyboardKey.exclamation, physical: PhysicalKeyboardKey.digit1, shift: true), 'shift 1');
      expect(record(LogicalKeyboardKey.exclamation), isNull);
    });

    test('a key with no name is refused', () {
      expect(record(LogicalKeyboardKey.mediaPlay), isNull);
      expect(record(LogicalKeyboardKey.escape), isNull);
    });

    test('a modifier is not a key', () {
      expect(isModifierKey(LogicalKeyboardKey.controlLeft), isTrue);
      expect(isModifierKey(LogicalKeyboardKey.metaRight), isTrue);
      expect(isModifierKey(LogicalKeyboardKey.keyA), isFalse);
    });
  });

  group('the modifiers', () {
    test('come first, in the order ctrl, alt, shift, windows', () {
      expect(
        record(LogicalKeyboardKey.digit1, windows: true, shift: true, alt: true, ctrl: true),
        'ctrl alt shift windows 1',
      );
      expect(record(LogicalKeyboardKey.f5, shift: true, ctrl: true), 'ctrl shift VK_F5');
    });

    test('the no_ tokens of the old value stay', () {
      expect(
        record(LogicalKeyboardKey.digit1, ctrl: true, previous: 'ctrl no_shift no_alt VK_UP'),
        'ctrl no_shift no_alt 1',
      );
      expect(record(LogicalKeyboardKey.digit1, previous: 'no_ctrl no_alt VK_UP'), 'no_ctrl no_alt 1');
    });

    test('a held modifier replaces its no_ token', () {
      expect(record(LogicalKeyboardKey.digit1, shift: true, previous: 'ctrl no_shift VK_UP'), 'shift 1');
      expect(record(LogicalKeyboardKey.digit1, alt: true, previous: 'NO_ALT 2'), 'alt 1');
    });

    test('no_modifiers is dropped when any modifier is held, and kept when none is', () {
      expect(record(LogicalKeyboardKey.digit1, ctrl: true, previous: 'no_modifiers VK_UP'), 'ctrl 1');
      expect(record(LogicalKeyboardKey.digit1, previous: 'no_modifiers VK_UP'), 'no_modifiers 1');
    });

    test('the aliases of a modifier count as it', () {
      expect(record(LogicalKeyboardKey.digit1, ctrl: true, previous: 'no_control 2'), 'ctrl 1');
      expect(record(LogicalKeyboardKey.digit1, windows: true, previous: 'no_win 2'), 'windows 1');
    });
  });

  group('comparing and showing', () {
    test('the same combination in any spelling is equal', () {
      expect(sameCombo('CTRL VK_F1', 'ctrl f1'), isTrue);
      expect(sameCombo('VK_F1 ctrl', 'ctrl VK_F1'), isTrue);
      expect(sameCombo('control 1', 'ctrl 1'), isTrue);
      expect(sameCombo('ctrl 1', 'alt 1'), isFalse);
      expect(sameCombo('ctrl no_shift 1', 'ctrl 1'), isFalse);
    });

    test('the keycaps drop VK_ and the no_ tokens and capitalise', () {
      expect(keyCaps('ctrl no_shift VK_UP'), ['Ctrl', 'UP']);
      expect(keyCaps('alt 1'), ['Alt', '1']);
      expect(keyCaps('h'), ['H']);
      expect(keyCaps('VK_F1'), ['F1']);
      expect(keyCaps(''), isEmpty);
    });

    test('what is recorded reads back as the same keycaps', () {
      final combo = record(LogicalKeyboardKey.arrowDown, ctrl: true, alt: true)!;

      expect(keyCaps(combo), ['Ctrl', 'Alt', 'DOWN']);
      expect(sameCombo(combo, 'alt ctrl VK_DOWN'), isTrue);
    });
  });
}
