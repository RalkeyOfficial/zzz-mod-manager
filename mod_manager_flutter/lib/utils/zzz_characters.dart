/// An agent's attribute, which colours the tile their portrait sits on.
///
/// Sub-attributes (Miyabi's Frost, Ye Shunguang's Honed Edge, Yixuan's Auric Ink) are recorded as the attribute they
/// belong to.
enum AgentAttribute { physical, fire, ice, electric, ether, wind, lumiflux }

/// An agent's combat role.
enum AgentSpecialty { attack, stun, anomaly, support, defense, rupture, armorer }

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

  /// One of the two protagonists, who don't fight.
  final bool isProxy;

  /// Null for the Proxies, and for an agent whose attribute is not announced yet.
  final AgentAttribute? attribute;

  /// Null for the Proxies.
  final AgentSpecialty? specialty;

  /// The official English name, shortened the way the game's own menus shorten it. A proper noun, so never
  /// translated.
  final String? faction;

  const CharacterData({
    required this.id,
    this.realName,
    this.briefName,
    this.asset,
    this.aliases = const [],
    this.isProxy = false,
    this.attribute,
    this.specialty,
    this.faction,
  });

  /// Name shown in the UI (brief name preferred).
  String get displayName => briefName ?? realName ?? id;

  /// The name the character list and a character's header show: the real name where it is the brief name made
  /// longer ("Ellen Joe", "Hoshimi Miyabi"), the brief name otherwise. A real name that doesn't contain the brief
  /// one ("Flora" for Seed) is what the character is called in the story, not what players call them.
  String get fullName {
    final real = realName;
    final brief = briefName;
    if (real == null || brief == null) return displayName;
    return real.toLowerCase().contains(brief.toLowerCase()) ? real : brief;
  }

  /// PNG basename in `assets/characters/` (defaults to [id]).
  String get assetName => asset ?? id;

  /// Distinct lowercase terms used to detect this character in text.
  List<String> get detectionTerms => <String>{
    if (briefName != null) briefName!.toLowerCase(),
    if (realName != null) realName!.toLowerCase(),
    ...aliases.map((a) => a.toLowerCase()),
  }.toList();
}

const _calydon = 'Sons of Calydon';
const _cisrt = 'Criminal Investigation Special Response Team';
const _hares = 'Cunning Hares';
const _belobog = 'Belobog Heavy Industries';
const _victoria = 'Victoria Housekeeping';
const _section6 = 'Section 6';
const _spook = 'Spook Shack';
const _krampus = 'Krampus Compliance Authority';
const _yunkui = 'Yunkui Summit';
const _obol = 'Obol Squad';
const _angels = 'Angels of Delusion';
const _lyra = 'Stars of Lyra';
const _mockingbird = 'Mockingbird';
const _external = 'External Strategy Department';
const _metropolitan = 'Metropolitan Order Division';
const _flint = 'Flint Workshop';
const _phaethon = 'Phaethon';
const _unknownRealm = 'Unknown Realm';

/// All ZZZ characters, alphabetical by display name.
const List<CharacterData> zzzCharactersData = [
  CharacterData(
    id: 'alice',
    realName: 'Alice Thymefield',
    briefName: 'Alice',
    attribute: AgentAttribute.physical,
    specialty: AgentSpecialty.anomaly,
    faction: _spook,
  ),
  CharacterData(
    id: 'anby',
    realName: 'Anby Demara',
    briefName: 'Anby',
    attribute: AgentAttribute.electric,
    specialty: AgentSpecialty.stun,
    faction: _hares,
  ),
  CharacterData(
    id: 'anton',
    realName: 'Anton Ivanov',
    briefName: 'Anton',
    attribute: AgentAttribute.electric,
    specialty: AgentSpecialty.attack,
    faction: _belobog,
  ),
  CharacterData(
    id: 'aria',
    briefName: 'Aria',
    attribute: AgentAttribute.ether,
    specialty: AgentSpecialty.anomaly,
    faction: _angels,
  ),
  CharacterData(
    id: 'astra',
    briefName: 'Astra Yao',
    aliases: ['astra', 'astrayao'],
    attribute: AgentAttribute.ether,
    specialty: AgentSpecialty.support,
    faction: _lyra,
  ),
  CharacterData(
    id: 'banyue',
    briefName: 'Banyue',
    attribute: AgentAttribute.fire,
    specialty: AgentSpecialty.rupture,
    faction: _krampus,
  ),
  CharacterData(id: 'belle', briefName: 'Belle', isProxy: true, faction: _phaethon),
  CharacterData(
    id: 'ben',
    realName: 'Ben Bigger',
    briefName: 'Ben',
    aliases: ['bigger'],
    attribute: AgentAttribute.fire,
    specialty: AgentSpecialty.defense,
    faction: _belobog,
  ),
  CharacterData(
    id: 'billy',
    realName: 'Billy Kid',
    briefName: 'Billy',
    asset: 'billy_herinkton',
    aliases: ['billyherinkton'],
    attribute: AgentAttribute.physical,
    specialty: AgentSpecialty.attack,
    faction: _hares,
  ),
  CharacterData(
    id: 'burnice',
    realName: 'Burnice White',
    briefName: 'Burnice',
    attribute: AgentAttribute.fire,
    specialty: AgentSpecialty.anomaly,
    faction: _calydon,
  ),
  CharacterData(
    id: 'caesar',
    realName: 'Caesar King',
    briefName: 'Caesar',
    attribute: AgentAttribute.physical,
    specialty: AgentSpecialty.defense,
    faction: _calydon,
  ),
  CharacterData(
    id: 'cissia',
    briefName: 'Cissia',
    attribute: AgentAttribute.electric,
    specialty: AgentSpecialty.attack,
    faction: _metropolitan,
  ),
  CharacterData(
    id: 'claret',
    realName: 'Claret Flint',
    briefName: 'Claret',
    attribute: AgentAttribute.electric,
    specialty: AgentSpecialty.armorer,
    faction: _flint,
  ),
  CharacterData(
    id: 'corin',
    realName: 'Corin Wickes',
    briefName: 'Corin',
    attribute: AgentAttribute.physical,
    specialty: AgentSpecialty.attack,
    faction: _victoria,
  ),
  CharacterData(
    id: 'dialyn',
    briefName: 'Dialyn',
    attribute: AgentAttribute.physical,
    specialty: AgentSpecialty.stun,
    faction: _krampus,
  ),
  CharacterData(
    id: 'ellen',
    realName: 'Ellen Joe',
    briefName: 'Ellen',
    attribute: AgentAttribute.ice,
    specialty: AgentSpecialty.attack,
    faction: _victoria,
  ),
  CharacterData(
    id: 'evelyn',
    realName: 'Evelyn Chevalier',
    briefName: 'Evelyn',
    attribute: AgentAttribute.fire,
    specialty: AgentSpecialty.attack,
    faction: _lyra,
  ),
  CharacterData(
    id: 'grace',
    realName: 'Grace Howard',
    briefName: 'Grace',
    attribute: AgentAttribute.electric,
    specialty: AgentSpecialty.anomaly,
    faction: _belobog,
  ),
  CharacterData(
    id: 'harumasa',
    realName: 'Asaba Harumasa',
    briefName: 'Harumasa',
    attribute: AgentAttribute.electric,
    specialty: AgentSpecialty.attack,
    faction: _section6,
  ),
  CharacterData(
    id: 'hugo',
    realName: 'Hugo Vlad',
    briefName: 'Hugo',
    attribute: AgentAttribute.ice,
    specialty: AgentSpecialty.attack,
    faction: _mockingbird,
  ),
  CharacterData(
    id: 'jane',
    realName: 'Jane Doe',
    briefName: 'Jane',
    aliases: ['janedoe'],
    attribute: AgentAttribute.physical,
    specialty: AgentSpecialty.anomaly,
    faction: _cisrt,
  ),
  CharacterData(
    id: 'jufufu',
    briefName: 'Ju Fufu',
    aliases: ['jufufu'],
    attribute: AgentAttribute.fire,
    specialty: AgentSpecialty.stun,
    faction: _yunkui,
  ),
  CharacterData(
    id: 'kafka',
    briefName: 'Kafka',
    attribute: AgentAttribute.electric,
    specialty: AgentSpecialty.anomaly,
    faction: _unknownRealm,
  ),
  CharacterData(
    id: 'koleda',
    realName: 'Koleda Belobog',
    briefName: 'Koleda',
    attribute: AgentAttribute.fire,
    specialty: AgentSpecialty.stun,
    faction: _belobog,
  ),
  CharacterData(
    id: 'lighter',
    briefName: 'Lighter',
    attribute: AgentAttribute.fire,
    specialty: AgentSpecialty.stun,
    faction: _calydon,
  ),
  CharacterData(
    id: 'lucia',
    realName: 'Lucia Elowen',
    briefName: 'Lucia',
    attribute: AgentAttribute.ether,
    specialty: AgentSpecialty.support,
    faction: _spook,
  ),
  CharacterData(
    id: 'lucy',
    realName: 'Luciana de Montefio',
    briefName: 'Lucy',
    attribute: AgentAttribute.fire,
    specialty: AgentSpecialty.support,
    faction: _calydon,
  ),
  CharacterData(
    id: 'lycaon',
    realName: 'Von Lycaon',
    briefName: 'Lycaon',
    aliases: ['vonlycaon'],
    attribute: AgentAttribute.ice,
    specialty: AgentSpecialty.stun,
    faction: _victoria,
  ),
  CharacterData(
    id: 'manato',
    realName: 'Komano Manato',
    briefName: 'Manato',
    attribute: AgentAttribute.fire,
    specialty: AgentSpecialty.rupture,
    faction: _spook,
  ),
  CharacterData(
    id: 'miyabi',
    realName: 'Hoshimi Miyabi',
    briefName: 'Miyabi',
    attribute: AgentAttribute.ice,
    specialty: AgentSpecialty.anomaly,
    faction: _section6,
  ),
  CharacterData(
    id: 'nangongyu',
    briefName: 'Nangong Yu',
    aliases: ['nangongyu'],
    attribute: AgentAttribute.ether,
    specialty: AgentSpecialty.stun,
    faction: _angels,
  ),
  CharacterData(
    id: 'nekomata',
    realName: 'Nekomiya Mana',
    briefName: 'Nekomata',
    attribute: AgentAttribute.physical,
    specialty: AgentSpecialty.attack,
    faction: _hares,
  ),
  CharacterData(
    id: 'nicole',
    realName: 'Nicole Demara',
    briefName: 'Nicole',
    attribute: AgentAttribute.ether,
    specialty: AgentSpecialty.support,
    faction: _hares,
  ),
  CharacterData(
    id: 'norma',
    realName: 'Norma Hollowell',
    briefName: 'Norma',
    attribute: AgentAttribute.fire,
    specialty: AgentSpecialty.stun,
    faction: _external,
  ),
  CharacterData(
    id: 'orphie',
    realName: 'Orpheus Magnusson',
    briefName: 'Orphie & Magus',
    aliases: ['orphie', 'orphie magus', 'orphiemagus', 'magus'],
    attribute: AgentAttribute.fire,
    specialty: AgentSpecialty.attack,
    faction: _obol,
  ),
  CharacterData(
    id: 'panyinhu',
    briefName: 'Pan Yinhu',
    aliases: ['panyinhu'],
    attribute: AgentAttribute.physical,
    specialty: AgentSpecialty.defense,
    faction: _yunkui,
  ),
  CharacterData(
    id: 'phoenix',
    realName: 'Phoenix Reffaella',
    briefName: 'Phoenix',
    attribute: AgentAttribute.fire,
    specialty: AgentSpecialty.anomaly,
    faction: _krampus,
  ),
  CharacterData(
    id: 'piper',
    realName: 'Piper Wheel',
    briefName: 'Piper',
    attribute: AgentAttribute.physical,
    specialty: AgentSpecialty.anomaly,
    faction: _calydon,
  ),
  CharacterData(
    id: 'promeia',
    briefName: 'Promeia',
    attribute: AgentAttribute.ice,
    specialty: AgentSpecialty.anomaly,
    faction: _krampus,
  ),
  CharacterData(
    id: 'pulchra',
    realName: 'Pulchra Fellini',
    briefName: 'Pulchra',
    attribute: AgentAttribute.physical,
    specialty: AgentSpecialty.stun,
    faction: _calydon,
  ),
  CharacterData(
    id: 'pyrois',
    briefName: 'Pyrois',
    attribute: AgentAttribute.ether,
    specialty: AgentSpecialty.attack,
    faction: _phaethon,
  ),
  CharacterData(
    id: 'qingyi',
    realName: '01 Neo-Genesis VI',
    briefName: 'Qingyi',
    attribute: AgentAttribute.electric,
    specialty: AgentSpecialty.stun,
    faction: _cisrt,
  ),
  CharacterData(
    id: 'remielle',
    realName: 'Remielle Dan',
    briefName: 'Remielle',
    attribute: AgentAttribute.lumiflux,
    specialty: AgentSpecialty.anomaly,
    faction: 'Covenant of Dayat',
  ),
  CharacterData(
    id: 'rina',
    realName: 'Alexandrina Sebastiane',
    briefName: 'Rina',
    aliases: ['alexandrina'],
    attribute: AgentAttribute.electric,
    specialty: AgentSpecialty.support,
    faction: _victoria,
  ),
  CharacterData(
    id: 'robin',
    briefName: 'Robin',
    attribute: AgentAttribute.ether,
    specialty: AgentSpecialty.defense,
    faction: _unknownRealm,
  ),
  CharacterData(
    id: 'roxy',
    realName: 'Roxy Ifrita Pryce',
    briefName: 'Roxy',
    attribute: AgentAttribute.wind,
    specialty: AgentSpecialty.stun,
    faction: _flint,
  ),
  CharacterData(
    id: 'seed',
    realName: 'Flora',
    briefName: 'Seed',
    attribute: AgentAttribute.electric,
    specialty: AgentSpecialty.attack,
    faction: _obol,
  ),
  CharacterData(
    id: 'seth',
    realName: 'Seth Lowell',
    briefName: 'Seth',
    attribute: AgentAttribute.electric,
    specialty: AgentSpecialty.defense,
    faction: _cisrt,
  ),
  CharacterData(
    id: 'severian',
    realName: 'Severian Lowell',
    briefName: 'Severian',
    attribute: AgentAttribute.wind,
    specialty: AgentSpecialty.attack,
    faction: _metropolitan,
  ),
  CharacterData(
    id: 'sigrid',
    realName: "Sigrid de L'Azur",
    briefName: 'Sigrid',
    attribute: AgentAttribute.ice,
    specialty: AgentSpecialty.attack,
    faction: 'Airspace Patrol Department',
  ),
  CharacterData(
    id: 'solder0anby',
    realName: 'Soldier 0 - Anby Demara',
    briefName: 'Soldier 0 - Anby',
    aliases: ['solder0anby', 'soldier0', 'soldier 0', 'sanby', 'anbys'],
    attribute: AgentAttribute.electric,
    specialty: AgentSpecialty.attack,
    faction: 'Silver Squad',
  ),
  CharacterData(
    id: 'solder11',
    realName: 'Harin',
    briefName: 'Soldier 11',
    aliases: ['solder11', 'soldier11'],
    attribute: AgentAttribute.fire,
    specialty: AgentSpecialty.attack,
    faction: _obol,
  ),
  CharacterData(
    id: 'soukaku',
    briefName: 'Soukaku',
    attribute: AgentAttribute.ice,
    specialty: AgentSpecialty.support,
    faction: _section6,
  ),
  CharacterData(
    id: 'starlightbilly',
    realName: 'Starlight - Billy Kid',
    briefName: 'Starlight - Billy',
    aliases: ['starlightbilly', 'starlight billy'],
    attribute: AgentAttribute.physical,
    specialty: AgentSpecialty.rupture,
    faction: _hares,
  ),
  CharacterData(
    id: 'sunna',
    briefName: 'Sunna',
    attribute: AgentAttribute.physical,
    specialty: AgentSpecialty.support,
    faction: _angels,
  ),
  CharacterData(
    id: 'sunbringer',
    briefName: 'Sunbringer',
    specialty: AgentSpecialty.armorer,
    faction: 'Roscaelifer',
  ),
  CharacterData(
    id: 'trigger',
    briefName: 'Trigger',
    attribute: AgentAttribute.electric,
    specialty: AgentSpecialty.stun,
    faction: _obol,
  ),
  CharacterData(
    id: 'velina',
    realName: 'Velina Airgid',
    briefName: 'Velina',
    attribute: AgentAttribute.wind,
    specialty: AgentSpecialty.anomaly,
    faction: _external,
  ),
  CharacterData(
    id: 'vivian',
    realName: 'Vivian Banshee',
    briefName: 'Vivian',
    attribute: AgentAttribute.ether,
    specialty: AgentSpecialty.anomaly,
    faction: _mockingbird,
  ),
  CharacterData(id: 'wise', briefName: 'Wise', isProxy: true, faction: _phaethon),
  CharacterData(
    id: 'yanagi',
    realName: 'Tsukishiro Yanagi',
    briefName: 'Yanagi',
    attribute: AgentAttribute.electric,
    specialty: AgentSpecialty.anomaly,
    faction: _section6,
  ),
  CharacterData(
    id: 'yeshunguang',
    briefName: 'Ye Shunguang',
    aliases: ['yeshunguang'],
    attribute: AgentAttribute.physical,
    specialty: AgentSpecialty.attack,
    faction: _yunkui,
  ),
  CharacterData(
    id: 'yidhari',
    realName: 'Yidhari Murphy',
    briefName: 'Yidhari',
    attribute: AgentAttribute.ice,
    specialty: AgentSpecialty.rupture,
    faction: _spook,
  ),
  CharacterData(
    id: 'yixuan',
    briefName: 'Yixuan',
    attribute: AgentAttribute.ether,
    specialty: AgentSpecialty.rupture,
    faction: _yunkui,
  ),
  CharacterData(
    id: 'yuzuha',
    realName: 'Ukinami Yuzuha',
    briefName: 'Yuzuha',
    attribute: AgentAttribute.physical,
    specialty: AgentSpecialty.support,
    faction: _spook,
  ),
  CharacterData(
    id: 'zhao',
    briefName: 'Zhao',
    attribute: AgentAttribute.ice,
    specialty: AgentSpecialty.defense,
    faction: _krampus,
  ),
  CharacterData(
    id: 'zhuyuan',
    briefName: 'Zhu Yuan',
    aliases: ['zhuyuan'],
    attribute: AgentAttribute.ether,
    specialty: AgentSpecialty.attack,
    faction: _cisrt,
  ),
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

/// Up to two capitals for a tile with no portrait: the first letters of the first two words, or the first two
/// letters of a single word. "Ellen Joe" is EJ, "Qingyi" QI, "Soldier 0 - Anby" S0.
String nameInitials(String name) {
  final words = name.split(RegExp(r'[\s\-–&]+')).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return '?';
  if (words.length == 1) {
    final word = words.single;
    return word.substring(0, word.length < 2 ? word.length : 2).toUpperCase();
  }
  return '${words[0][0]}${words[1][0]}'.toUpperCase();
}

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
