/// Модель для зберігання інформації про keybind
class KeybindInfo {
  final String section; // Назва секції (напр. keySwap, KeyUP)
  final Map<String, String> keys; // Ключі та їх значення

  KeybindInfo({
    required this.section,
    required this.keys,
  });

  /// Отримує значення клавіші з секції (поле 'key', незалежно від регістру).
  /// INI files may write either `key =` or `Key =`, so look it up case-insensitively.
  String? get keyValue {
    for (final entry in keys.entries) {
      if (entry.key.toLowerCase() == 'key') return entry.value;
    }
    return null;
  }

  /// User-friendly form of [keyValue] with the Windows `VK_` prefix stripped
  /// (e.g. `ctrl no_shift VK_UP` -> `ctrl no_shift UP`). Display only — the
  /// edit popup still uses the raw [keyValue] for accuracy.
  String? get displayKeyValue {
    final value = keyValue;
    return value == null ? null : formatForDisplay(value);
  }

  /// Strips the `VK_` virtual-key prefix from every token for display
  /// (e.g. `VK_UP` -> `UP`, `VK_F1` -> `F1`). Modifiers pass through unchanged.
  static String formatForDisplay(String value) {
    return value
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .map((t) => t.toUpperCase().startsWith('VK_') ? t.substring(3) : t)
        .join(' ');
  }

  /// Отримує красиву назву секції (без префіксу Key)
  String get displayName {
    if (section.toLowerCase().startsWith('key')) {
      return section.substring(3);
    }
    return section;
  }

  factory KeybindInfo.fromJson(Map<String, dynamic> json) {
    return KeybindInfo(
      section: json['section'] as String,
      keys: Map<String, String>.from(json['keys'] as Map),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'section': section,
      'keys': keys,
    };
  }

  KeybindInfo copyWith({
    String? section,
    Map<String, String>? keys,
  }) {
    return KeybindInfo(
      section: section ?? this.section,
      keys: keys ?? this.keys,
    );
  }

  /// Value equality, and it is load-bearing rather than tidiness.
  ///
  /// These are re-parsed from `.ini` on **every** library scan, so each scan
  /// produces fresh instances describing identical bindings. Without this,
  /// `modGroupsChanged` comparing them would see two different objects every
  /// time and report a change on every scan — which is why that guard used to
  /// skip keybinds entirely, and why editing a hotkey then left the grid
  /// showing the old one.
  ///
  /// Compared **order-independently on [keys]**, and [hashCode] has to agree:
  /// the map is a `LinkedHashMap` whose order follows the order lines appear in
  /// the file, which is not something a binding's identity should depend on.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is KeybindInfo &&
          other.section == section &&
          _sameEntries(other.keys, keys);

  @override
  int get hashCode => Object.hash(
        section,
        Object.hashAllUnordered(
          [for (final e in keys.entries) Object.hash(e.key, e.value)],
        ),
      );

  static bool _sameEntries(Map<String, String> a, Map<String, String> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      // A missing key and a key holding null are the same answer here, because
      // the map's values are non-nullable.
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }
}

/// Модель для зберігання всіх keybinds з INI файлу
class CharacterKeybinds {
  final String characterId;
  final List<KeybindInfo> keybinds;
  final String? iniFilePath;

  CharacterKeybinds({
    required this.characterId,
    required this.keybinds,
    this.iniFilePath,
  });

  factory CharacterKeybinds.fromJson(Map<String, dynamic> json) {
    return CharacterKeybinds(
      characterId: json['character_id'] as String,
      keybinds: (json['keybinds'] as List)
          .map((e) => KeybindInfo.fromJson(e as Map<String, dynamic>))
          .toList(),
      iniFilePath: json['ini_file_path'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'character_id': characterId,
      'keybinds': keybinds.map((e) => e.toJson()).toList(),
      'ini_file_path': iniFilePath,
    };
  }

  CharacterKeybinds copyWith({
    String? characterId,
    List<KeybindInfo>? keybinds,
    String? iniFilePath,
  }) {
    return CharacterKeybinds(
      characterId: characterId ?? this.characterId,
      keybinds: keybinds ?? this.keybinds,
      iniFilePath: iniFilePath ?? this.iniFilePath,
    );
  }
}
