import 'package:flutter/services.dart';

/// Key combinations as a mod's `.ini` spells them (`docs/key-editing.md` §3): modifier tokens, then the key, such as
/// `ctrl alt VK_F1` or `shift 4`.

/// The 3DMigoto name for a modifier, in the order a combination writes them.
const List<String> _modifierOrder = ['ctrl', 'alt', 'shift', 'windows'];

/// What 3DMigoto accepts for each modifier, so `no_control` is read as `no_ctrl`.
const Map<String, String> _modifierAliases = {
  'ctrl': 'ctrl',
  'control': 'ctrl',
  'alt': 'alt',
  'shift': 'shift',
  'windows': 'windows',
  'win': 'windows',
};

/// The names 3DMigoto knows for keys that are not letters or digits, by what Flutter calls them.
final Map<LogicalKeyboardKey, String> _namedKeys = {
  for (var i = 0; i < 24; i++) _functionKeys[i]: 'VK_F${i + 1}',
  LogicalKeyboardKey.arrowUp: 'VK_UP',
  LogicalKeyboardKey.arrowDown: 'VK_DOWN',
  LogicalKeyboardKey.arrowLeft: 'VK_LEFT',
  LogicalKeyboardKey.arrowRight: 'VK_RIGHT',
  LogicalKeyboardKey.numpad0: 'VK_NUMPAD0',
  LogicalKeyboardKey.numpad1: 'VK_NUMPAD1',
  LogicalKeyboardKey.numpad2: 'VK_NUMPAD2',
  LogicalKeyboardKey.numpad3: 'VK_NUMPAD3',
  LogicalKeyboardKey.numpad4: 'VK_NUMPAD4',
  LogicalKeyboardKey.numpad5: 'VK_NUMPAD5',
  LogicalKeyboardKey.numpad6: 'VK_NUMPAD6',
  LogicalKeyboardKey.numpad7: 'VK_NUMPAD7',
  LogicalKeyboardKey.numpad8: 'VK_NUMPAD8',
  LogicalKeyboardKey.numpad9: 'VK_NUMPAD9',
  LogicalKeyboardKey.numpadMultiply: 'VK_MULTIPLY',
  LogicalKeyboardKey.numpadAdd: 'VK_ADD',
  LogicalKeyboardKey.numpadSubtract: 'VK_SUBTRACT',
  LogicalKeyboardKey.numpadDecimal: 'VK_DECIMAL',
  LogicalKeyboardKey.numpadDivide: 'VK_DIVIDE',
  LogicalKeyboardKey.numpadEnter: 'VK_RETURN',
  LogicalKeyboardKey.space: 'VK_SPACE',
  LogicalKeyboardKey.enter: 'VK_RETURN',
  LogicalKeyboardKey.tab: 'VK_TAB',
  LogicalKeyboardKey.backspace: 'VK_BACK',
  LogicalKeyboardKey.delete: 'VK_DELETE',
  LogicalKeyboardKey.insert: 'VK_INSERT',
  LogicalKeyboardKey.home: 'VK_HOME',
  LogicalKeyboardKey.end: 'VK_END',
  LogicalKeyboardKey.pageUp: 'VK_PRIOR',
  LogicalKeyboardKey.pageDown: 'VK_NEXT',
  LogicalKeyboardKey.capsLock: 'VK_CAPITAL',
  LogicalKeyboardKey.numLock: 'VK_NUMLOCK',
  LogicalKeyboardKey.scrollLock: 'VK_SCROLL',
  LogicalKeyboardKey.pause: 'VK_PAUSE',
  LogicalKeyboardKey.printScreen: 'VK_SNAPSHOT',
  LogicalKeyboardKey.semicolon: 'VK_OEM_1',
  LogicalKeyboardKey.equal: 'VK_OEM_PLUS',
  LogicalKeyboardKey.comma: 'VK_OEM_COMMA',
  LogicalKeyboardKey.minus: 'VK_OEM_MINUS',
  LogicalKeyboardKey.period: 'VK_OEM_PERIOD',
  LogicalKeyboardKey.slash: 'VK_OEM_2',
  LogicalKeyboardKey.backquote: 'VK_OEM_3',
  LogicalKeyboardKey.bracketLeft: 'VK_OEM_4',
  LogicalKeyboardKey.backslash: 'VK_OEM_5',
  LogicalKeyboardKey.bracketRight: 'VK_OEM_6',
  LogicalKeyboardKey.quote: 'VK_OEM_7',
};

final List<LogicalKeyboardKey> _functionKeys = [
  LogicalKeyboardKey.f1,
  LogicalKeyboardKey.f2,
  LogicalKeyboardKey.f3,
  LogicalKeyboardKey.f4,
  LogicalKeyboardKey.f5,
  LogicalKeyboardKey.f6,
  LogicalKeyboardKey.f7,
  LogicalKeyboardKey.f8,
  LogicalKeyboardKey.f9,
  LogicalKeyboardKey.f10,
  LogicalKeyboardKey.f11,
  LogicalKeyboardKey.f12,
  LogicalKeyboardKey.f13,
  LogicalKeyboardKey.f14,
  LogicalKeyboardKey.f15,
  LogicalKeyboardKey.f16,
  LogicalKeyboardKey.f17,
  LogicalKeyboardKey.f18,
  LogicalKeyboardKey.f19,
  LogicalKeyboardKey.f20,
  LogicalKeyboardKey.f21,
  LogicalKeyboardKey.f22,
  LogicalKeyboardKey.f23,
  LogicalKeyboardKey.f24,
];

/// The keys that carry a digit or punctuation mark, by position. With Shift held Flutter reports the shifted
/// character as the logical key, which has no name here, so these answer for it.
final Map<PhysicalKeyboardKey, String> _positionKeys = {
  PhysicalKeyboardKey.digit0: '0',
  PhysicalKeyboardKey.digit1: '1',
  PhysicalKeyboardKey.digit2: '2',
  PhysicalKeyboardKey.digit3: '3',
  PhysicalKeyboardKey.digit4: '4',
  PhysicalKeyboardKey.digit5: '5',
  PhysicalKeyboardKey.digit6: '6',
  PhysicalKeyboardKey.digit7: '7',
  PhysicalKeyboardKey.digit8: '8',
  PhysicalKeyboardKey.digit9: '9',
  PhysicalKeyboardKey.semicolon: 'VK_OEM_1',
  PhysicalKeyboardKey.equal: 'VK_OEM_PLUS',
  PhysicalKeyboardKey.comma: 'VK_OEM_COMMA',
  PhysicalKeyboardKey.minus: 'VK_OEM_MINUS',
  PhysicalKeyboardKey.period: 'VK_OEM_PERIOD',
  PhysicalKeyboardKey.slash: 'VK_OEM_2',
  PhysicalKeyboardKey.backquote: 'VK_OEM_3',
  PhysicalKeyboardKey.bracketLeft: 'VK_OEM_4',
  PhysicalKeyboardKey.backslash: 'VK_OEM_5',
  PhysicalKeyboardKey.bracketRight: 'VK_OEM_6',
  PhysicalKeyboardKey.quote: 'VK_OEM_7',
};

final Set<LogicalKeyboardKey> _modifierKeys = {
  LogicalKeyboardKey.control,
  LogicalKeyboardKey.controlLeft,
  LogicalKeyboardKey.controlRight,
  LogicalKeyboardKey.alt,
  LogicalKeyboardKey.altLeft,
  LogicalKeyboardKey.altRight,
  LogicalKeyboardKey.shift,
  LogicalKeyboardKey.shiftLeft,
  LogicalKeyboardKey.shiftRight,
  LogicalKeyboardKey.meta,
  LogicalKeyboardKey.metaLeft,
  LogicalKeyboardKey.metaRight,
  LogicalKeyboardKey.altGraph,
};

/// Whether [key] is a modifier, which records nothing on its own.
bool isModifierKey(LogicalKeyboardKey key) => _modifierKeys.contains(key);

/// The name 3DMigoto knows [key] by, or null when it has none the app writes. [physical] is looked at only for a
/// digit or punctuation key whose logical key is not one (Shift held, or a layout that puts it elsewhere).
String? iniKeyName(LogicalKeyboardKey key, {PhysicalKeyboardKey? physical}) {
  final id = key.keyId;
  // Letters and digits are their own character, in lower case.
  if (id >= 0x30 && id <= 0x39 || id >= 0x61 && id <= 0x7a) return String.fromCharCode(id);
  if (id >= 0x41 && id <= 0x5a) return String.fromCharCode(id + 0x20);
  return _namedKeys[key] ?? (physical == null ? null : _positionKeys[physical]);
}

/// The combination to write when [key] goes down with the given modifiers held, or null when the key has no name.
///
/// [previous] is the value being replaced. Its `no_` tokens say which modifier must not be held and cannot be
/// recorded, so they stay, except where the new combination holds that modifier.
String? recordCombo({
  required LogicalKeyboardKey key,
  PhysicalKeyboardKey? physical,
  bool ctrl = false,
  bool alt = false,
  bool shift = false,
  bool windows = false,
  String? previous,
}) {
  final name = iniKeyName(key, physical: physical);
  if (name == null) return null;
  final held = <String>{if (ctrl) 'ctrl', if (alt) 'alt', if (shift) 'shift', if (windows) 'windows'};
  final kept = <String>[];
  for (final token in (previous ?? '').split(RegExp(r'\s+'))) {
    final lower = token.toLowerCase();
    if (!lower.startsWith('no_')) continue;
    final modifier = lower.substring(3);
    if (modifier == 'modifiers') {
      if (held.isEmpty) kept.add(token);
    } else if (!held.contains(_modifierAliases[modifier])) {
      kept.add(token);
    }
  }
  return [
    for (final m in _modifierOrder)
      if (held.contains(m)) m,
    ...kept,
    name,
  ].join(' ');
}

/// [raw] reduced to what makes two spellings the same combination: lower case, no `VK_`, modifier aliases folded,
/// tokens in a fixed order.
String normalizeCombo(String raw) {
  final tokens = <String>[];
  for (final token in raw.split(RegExp(r'\s+'))) {
    if (token.isEmpty) continue;
    var lower = token.toLowerCase();
    if (lower.startsWith('vk_')) lower = lower.substring(3);
    if (lower.startsWith('no_')) {
      lower = 'no_${_modifierAliases[lower.substring(3)] ?? lower.substring(3)}';
    } else {
      lower = _modifierAliases[lower] ?? lower;
    }
    tokens.add(lower);
  }
  return (tokens..sort()).join(' ');
}

/// Whether [a] and [b] are the same combination, however they are spelled.
bool sameCombo(String a, String b) => normalizeCombo(a) == normalizeCombo(b);

/// The keycaps for a combination: `VK_` dropped, the first letter upper-cased, and the `no_` tokens left out, since
/// they name a modifier that must not be held and so are nothing to press.
List<String> keyCaps(String raw) => [
  for (var token in raw.split(RegExp(r'\s+')))
    if (token.isNotEmpty && !token.toLowerCase().startsWith('no_'))
      _cap(token.toLowerCase().startsWith('vk_') ? token.substring(3) : token),
];

String _cap(String token) => token.length == 1 ? token.toUpperCase() : '${token[0].toUpperCase()}${token.substring(1)}';
