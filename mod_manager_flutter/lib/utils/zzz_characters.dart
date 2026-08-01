/// The Zenless Zone Zero character roster — the single source of truth.
///
/// To add a character, add one [CharacterData] entry below (kept alphabetical by
/// display name). Everything else — sidebar, grouping, the edit-dialog picker
/// and folder auto-detection — is derived from this list.
class CharacterData {
  /// Stable internal key. It is what gets stored in a mod's metadata, so it
  /// must never change once shipped. Also the asset filename unless [asset]
  /// overrides it.
  final String id;

  /// Full / in-world name. Secondary identification (e.g. GameBanana names mods
  /// by real name). May be null when only a brief name is known.
  final String? realName;

  /// Short, common name — the primary way players refer to the character and
  /// the main thing shown in the UI. May be null when only a real name exists.
  final String? briefName;

  /// PNG basename in `assets/characters/`. Defaults to [id]; set only when the
  /// file name differs.
  final String? asset;

  /// Extra lowercase terms (besides the names) used to auto-detect this
  /// character from a folder/file name — e.g. no-space variants.
  final List<String> aliases;

  const CharacterData({
    required this.id,
    this.realName,
    this.briefName,
    this.asset,
    this.aliases = const [],
  });

  /// Name shown in the UI (brief name preferred).
  String get displayName => briefName ?? realName ?? id;

  /// PNG basename in `assets/characters/` (defaults to [id]).
  String get assetName => asset ?? id;

  /// Distinct lowercase terms used to detect this character in text.
  List<String> get detectionTerms => <String>{
    if (briefName != null) briefName!.toLowerCase(),
    if (realName != null) realName!.toLowerCase(),
    ...aliases.map((a) => a.toLowerCase()),
  }.toList();
}

/// All ZZZ characters, alphabetical by display name.
const List<CharacterData> zzzCharactersData = [
  CharacterData(id: 'alice', realName: 'Alice Thymefield', briefName: 'Alice'),
  CharacterData(id: 'anby', realName: 'Anby Demara', briefName: 'Anby'),
  CharacterData(id: 'anton', realName: 'Anton Ivanov', briefName: 'Anton'),
  CharacterData(id: 'aria', briefName: 'Aria'),
  CharacterData(
    id: 'astra',
    briefName: 'Astra Yao',
    aliases: ['astra', 'astrayao'],
  ),
  CharacterData(id: 'banyue', briefName: 'Banyue'),
  CharacterData(id: 'belle', briefName: 'Belle'),
  CharacterData(
    id: 'ben',
    realName: 'Ben Bigger',
    briefName: 'Ben',
    aliases: ['bigger'],
  ),
  CharacterData(
    id: 'billy',
    realName: 'Billy Kid',
    briefName: 'Billy',
    asset: 'billy_herinkton',
    aliases: ['billyherinkton'],
  ),
  CharacterData(id: 'burnice', realName: 'Burnice White', briefName: 'Burnice'),
  CharacterData(id: 'caesar', realName: 'Caesar King', briefName: 'Caesar'),
  CharacterData(id: 'cissia', briefName: 'Cissia'),
  CharacterData(id: 'corin', realName: 'Corin Wickes', briefName: 'Corin'),
  CharacterData(id: 'dialyn', briefName: 'Dialyn'),
  CharacterData(id: 'ellen', realName: 'Ellen Joe', briefName: 'Ellen'),
  CharacterData(
    id: 'evelyn',
    realName: 'Evelyn Chevalier',
    briefName: 'Evelyn',
  ),
  CharacterData(id: 'grace', realName: 'Grace Howard', briefName: 'Grace'),
  CharacterData(
    id: 'harumasa',
    realName: 'Asaba Harumasa',
    briefName: 'Harumasa',
  ),
  CharacterData(id: 'hugo', realName: 'Hugo Vlad', briefName: 'Hugo'),
  CharacterData(
    id: 'jane',
    realName: 'Jane Doe',
    briefName: 'Jane',
    aliases: ['janedoe'],
  ),
  CharacterData(id: 'jufufu', briefName: 'Ju Fufu', aliases: ['jufufu']),
  CharacterData(id: 'koleda', realName: 'Koleda Belobog', briefName: 'Koleda'),
  CharacterData(id: 'lighter', briefName: 'Lighter'),
  CharacterData(id: 'lucia', realName: 'Lucia Elowen', briefName: 'Lucia'),
  CharacterData(id: 'lucy', realName: 'Luciana de Montefio', briefName: 'Lucy'),
  CharacterData(
    id: 'lycaon',
    realName: 'Von Lycaon',
    briefName: 'Lycaon',
    aliases: ['vonlycaon'],
  ),
  CharacterData(id: 'manato', realName: 'Komano Manato', briefName: 'Manato'),
  CharacterData(id: 'miyabi', realName: 'Hoshimi Miyabi', briefName: 'Miyabi'),
  CharacterData(
    id: 'nangongyu',
    briefName: 'Nangong Yu',
    aliases: ['nangongyu'],
  ),
  CharacterData(
    id: 'nekomata',
    realName: 'Nekomiya Mana',
    briefName: 'Nekomata',
  ),
  CharacterData(id: 'nicole', realName: 'Nicole Demara', briefName: 'Nicole'),
  CharacterData(id: 'norma', realName: 'Norma Hollowell', briefName: 'Norma'),
  CharacterData(
    id: 'orphie',
    realName: 'Orpheus Magnusson',
    briefName: 'Orphie & Magus',
    aliases: ['orphie', 'orphie magus', 'orphiemagus', 'magus'],
  ),
  CharacterData(id: 'panyinhu', briefName: 'Pan Yinhu', aliases: ['panyinhu']),
  CharacterData(id: 'piper', realName: 'Piper Wheel', briefName: 'Piper'),
  CharacterData(id: 'promeia', briefName: 'Promeia'),
  CharacterData(
    id: 'pulchra',
    realName: 'Pulchra Fellini',
    briefName: 'Pulchra',
  ),
  CharacterData(id: 'pyrois', briefName: 'Pyrois'),
  CharacterData(
    id: 'qingyi',
    realName: '01 Neo-Genesis VI',
    briefName: 'Qingyi',
  ),
  CharacterData(
    id: 'remielle',
    realName: 'Remielle Dan',
    briefName: 'Remielle',
  ),
  CharacterData(
    id: 'rina',
    realName: 'Alexandrina Sebastiane',
    briefName: 'Rina',
    aliases: ['alexandrina'],
  ),
  CharacterData(id: 'seed', realName: 'Flora', briefName: 'Seed'),
  CharacterData(id: 'seth', realName: 'Seth Lowell', briefName: 'Seth'),
  CharacterData(
    id: 'sigrid',
    realName: "Sigrid de L'Azur",
    briefName: 'Sigrid',
  ),
  CharacterData(
    id: 'solder0anby',
    realName: 'Soldier 0 - Anby Demara',
    briefName: 'Soldier 0 - Anby',
    aliases: ['solder0anby', 'soldier0', 'soldier 0', 'sanby', 'anbys'],
  ),
  CharacterData(
    id: 'solder11',
    realName: 'Harin',
    briefName: 'Soldier 11',
    aliases: ['solder11', 'soldier11'],
  ),
  CharacterData(id: 'soukaku', briefName: 'Soukaku'),
  CharacterData(
    id: 'starlightbilly',
    realName: 'Starlight - Billy Kid',
    briefName: 'Starlight - Billy',
    aliases: ['starlightbilly', 'starlight billy'],
  ),
  CharacterData(id: 'sunna', briefName: 'Sunna'),
  CharacterData(id: 'trigger', briefName: 'Trigger'),
  CharacterData(id: 'velina', realName: 'Velina Airgid', briefName: 'Velina'),
  CharacterData(id: 'vivian', realName: 'Vivian Banshee', briefName: 'Vivian'),
  CharacterData(id: 'wise', briefName: 'Wise'),
  CharacterData(
    id: 'yanagi',
    realName: 'Tsukishiro Yanagi',
    briefName: 'Yanagi',
  ),
  CharacterData(
    id: 'yeshunguang',
    briefName: 'Ye Shunguang',
    aliases: ['yeshunguang'],
  ),
  CharacterData(
    id: 'yidhari',
    realName: 'Yidhari Murphy',
    briefName: 'Yidhari',
  ),
  CharacterData(id: 'yixuan', briefName: 'Yixuan'),
  CharacterData(id: 'yuzuha', realName: 'Ukinami Yuzuha', briefName: 'Yuzuha'),
  CharacterData(id: 'zhao', briefName: 'Zhao'),
  CharacterData(id: 'zhuyuan', briefName: 'Zhu Yuan', aliases: ['zhuyuan']),
];

/// All character ids, in roster (display) order.
List<String> get zzzCharacterIds =>
    zzzCharactersData.map((c) => c.id).toList(growable: false);

final Map<String, CharacterData> _charactersById = {
  for (final c in zzzCharactersData) c.id: c,
};

/// Superseded character ids (typo corrections, renames) mapped to their current
/// id, so mods already tagged under the old id keep resolving to the character.
const Map<String, String> _legacyCharacterIds = {
  'quinqiy': 'qingyi', // corrected misspelling of Qingyi's id
};

/// Normalises a possibly-legacy stored character id to the current roster id.
String canonicalCharacterId(String id) =>
    _legacyCharacterIds[id.toLowerCase()] ?? id;

/// The placeholder id meaning "no character assigned".
///
/// It is a **runtime/display convention only** — `_buildModInfo()` substitutes
/// it so the UI always has a string to work with. It must never reach disk:
/// "no character" is stored as *absence*, in the sidecar and in `config.json`
/// alike (see `docs/metadata-schema.md` §2). Normalise with
/// [storedCharacterId] before persisting anything.
const String unknownCharacterId = 'unknown';

/// True when [id] means "untagged" — null, empty, or [unknownCharacterId].
bool isUnassignedCharacterId(String? id) =>
    id == null || id.isEmpty || id == unknownCharacterId;

/// Normalises a character id **for storage**, collapsing every "untagged"
/// spelling to null so the placeholder never round-trips onto disk.
String? storedCharacterId(String? id) => isUnassignedCharacterId(id) ? null : id;

/// The character with this id, or null if unknown.
CharacterData? characterById(String id) =>
    _charactersById[canonicalCharacterId(id).toLowerCase()];

/// Display name for a character id (falls back to the id itself).
String getCharacterDisplayName(String id) =>
    characterById(id)?.displayName ?? id;

/// Asset (PNG) basename for a character id (falls back to the id itself).
String getCharacterAssetName(String id) => characterById(id)?.assetName ?? id;

/// Real/full name for a character id, or null.
String? getCharacterRealName(String id) => characterById(id)?.realName;

/// Detects a character id from arbitrary text (a folder name, `.ini` contents,
/// a sub-folder name), or null if nothing matches.
///
/// The most specific (longest) term is tried first so that, e.g.,
/// "Soldier 0 - Anby" resolves to Soldier 0 rather than Anby, and "Lucia" to
/// Lucia rather than Lucy. A whole-word pass runs before a looser substring
/// pass for precision.
String? detectCharacterId(String text) {
  final lower = text.toLowerCase();

  final terms = <MapEntry<String, String>>[]; // term -> character id
  for (final c in zzzCharactersData) {
    for (final term in c.detectionTerms) {
      if (term.isNotEmpty) terms.add(MapEntry(term, c.id));
    }
  }
  terms.sort((a, b) => b.key.length.compareTo(a.key.length));

  for (final t in terms) {
    final pattern = RegExp(
      '\\b${RegExp.escape(t.key)}\\b',
      caseSensitive: false,
    );
    if (pattern.hasMatch(lower)) return t.value;
  }
  for (final t in terms) {
    if (lower.contains(t.key)) return t.value;
  }
  return null;
}
