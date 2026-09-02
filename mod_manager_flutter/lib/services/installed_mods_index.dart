import '../models/character_info.dart';
import '../models/origin_enums.dart';

/// What the local library says about one remote mod or file.
///
/// Pure: built from an already-scanned mod list and answers questions in memory.
/// No filesystem, no network, no widgets — the marketplace asks it "do I already
/// have this?" while rendering, so it has to be a lookup rather than a fetch.
///
/// **Three keys, because they answer three different questions.** The locked
/// rule is to badge on mod identity while marking rows on file identity
/// (`docs/origin-tracking.md` §9):
///
/// - `mod_id` — "this mod is in your library", possibly as a different file. Two
///   skins of one GameBanana page are two folders, and that is the common case
///   rather than an edge one (observed twice in a real 23-mod library), so every
///   lookup returns *all* matching folders rather than the first.
/// - `file_id` — "this exact file is what you have installed".
/// - `archive_md5` — "the archive you installed is byte-identical to this
///   published file". A **matching key only**, never an integrity claim; see
///   `services/archive_hash.dart`.
///
/// What that means in practice today, measured against a real library: every one
/// of its 23 mods carries a `mod_id` (recovered offline from `source_url`), and
/// **none** carries a `file_id` or an `archive_md5` — the archive is deleted
/// after extraction, so nothing local survives to match a published checksum.
/// So the mod-level answer works for a legacy library from the first launch,
/// while the file-level ones stay empty until mods are installed by a build that
/// records them, or until the resolve flow fills them in. Don't build anything
/// that assumes file-level knowledge is available.
class InstalledModsIndex {
  const InstalledModsIndex._(this._byModId, this._byFileId, this._byArchiveMd5);

  /// The answer for "the library hasn't loaded yet": nothing is known to be
  /// installed. Deliberately the same shape as a real empty library, so a
  /// caller that forgets to handle loading renders no badge rather than a wrong
  /// one.
  static const InstalledModsIndex empty =
      InstalledModsIndex._(<int, List<String>>{}, <int, List<String>>{},
          <String, List<String>>{});

  final Map<int, List<String>> _byModId;
  final Map<int, List<String>> _byFileId;
  final Map<String, List<String>> _byArchiveMd5;

  /// Indexes an already-scanned library.
  ///
  /// Two rules worth knowing:
  ///
  /// - A mod at `tracking: "off"` is left out of the **identity** indexes. That
  ///   setting is the user saying "not from GameBanana / it's my own", and a
  ///   stale `source_url` is exactly why they might have said it — so a mod id
  ///   still sitting in that block must not put an "in your library" badge on
  ///   somebody else's mod page. Its archive hash is still indexed: a hash is a
  ///   fact about bytes on disk, not a claim about which remote mod they are.
  /// - Folder lists are sorted case-insensitively, so what the UI shows doesn't
  ///   depend on the order the filesystem happened to enumerate the library in.
  factory InstalledModsIndex.fromMods(Iterable<ModInfo> mods) {
    final byModId = <int, List<String>>{};
    final byFileId = <int, List<String>>{};
    final byArchiveMd5 = <String, List<String>>{};

    for (final mod in mods) {
      final origin = mod.origin;
      if (origin == null) continue;

      // **Every download in the folder counts as installed**, and this is the
      // one place a mixed folder is a straight gain rather than a cost: a
      // patched folder really does hold both mods' files, and before this the
      // mod that was not the folder's headline showed no badge on its own page
      // at all. One folder legitimately appears under several ids.
      //
      // Inside the `tracking: "off"` guard on purpose — the switch is about the
      // folder, which is exactly why no layer carries one of its own.
      if (origin.tracking != OriginTracking.off) {
        for (final download in origin.downloads) {
          if (download.modId case final modId?) {
            byModId.putIfAbsent(modId, () => <String>[]).add(mod.id);
          }
          if (download.fileId case final fileId?) {
            byFileId.putIfAbsent(fileId, () => <String>[]).add(mod.id);
          }
        }
      }

      // **Every layer's archive, not only the bottom one's.** The hash answers
      // "have I installed this archive before", and a patch's archive is one the
      // user can pick again from the same file list.
      for (final download in origin.downloads) {
        if (normalizeArchiveMd5(download.archiveMd5) case final md5?) {
          byArchiveMd5.putIfAbsent(md5, () => <String>[]).add(mod.id);
        }
      }
    }

    for (final folders in [
      ...byModId.values,
      ...byFileId.values,
      ...byArchiveMd5.values,
    ]) {
      folders.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    }

    return InstalledModsIndex._(byModId, byFileId, byArchiveMd5);
  }

  /// Folder names installed from remote mod [modId] — empty when none are.
  List<String> installsOfMod(int modId) =>
      _byModId[modId] ?? const <String>[];

  /// Whether remote mod [modId] is in the library at all, as any file.
  bool hasMod(int modId) => _byModId.containsKey(modId);

  /// Folder names whose banked archive hash is [md5]. The purely local dedup
  /// question: "have I unpacked this exact archive before?"
  List<String> installsOfArchive(String? md5) {
    final key = normalizeArchiveMd5(md5);
    if (key == null) return const <String>[];
    return _byArchiveMd5[key] ?? const <String>[];
  }

  /// Whether one published file is already installed, and on what evidence.
  ///
  /// File id first, then the archive hash: both are exact, but the file id is a
  /// direct record of what we installed while the hash is a statement about
  /// bytes that has to be phrased more carefully in the UI. Reporting the
  /// stronger of the two keeps that wording honest without hiding a match.
  InstalledFileMatch matchFile({required int fileId, String? md5}) {
    if (_byFileId[fileId] case final folders?) {
      return InstalledFileMatch(InstalledFileEvidence.fileId, folders);
    }
    final byHash = installsOfArchive(md5);
    if (byHash.isNotEmpty) {
      return InstalledFileMatch(InstalledFileEvidence.archiveHash, byHash);
    }
    return InstalledFileMatch.none;
  }

  /// Lower-cased and trimmed, or null when there is nothing usable.
  ///
  /// GameBanana publishes `_sMd5Checksum` lower-case and so does our own
  /// hasher, but a sidecar is a public interchange format that can arrive
  /// hand-edited — and a case mismatch would silently turn every hash lookup
  /// into a miss, which looks exactly like "no match" and would never be
  /// noticed.
  static String? normalizeArchiveMd5(String? md5) {
    if (md5 == null) return null;
    final trimmed = md5.trim().toLowerCase();
    return trimmed.isEmpty ? null : trimmed;
  }
}

/// How the library knows about a remote file.
enum InstalledFileEvidence {
  /// Nothing local claims it.
  none,

  /// A mod folder records this exact `file_id` — we installed this file.
  fileId,

  /// A mod folder's banked archive md5 equals the checksum published for this
  /// file: byte-identical, and nothing stronger. Never render it as "verified".
  archiveHash,
}

/// The outcome of [InstalledModsIndex.matchFile].
class InstalledFileMatch {
  const InstalledFileMatch(this.evidence, this.folders);

  static const InstalledFileMatch none =
      InstalledFileMatch(InstalledFileEvidence.none, <String>[]);

  final InstalledFileEvidence evidence;

  /// The mod folders that matched, sorted. Empty exactly when [evidence] is
  /// [InstalledFileEvidence.none].
  final List<String> folders;

  bool get isInstalled => evidence != InstalledFileEvidence.none;
}
