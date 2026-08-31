import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/services/folder_contents.dart';
import 'package:mod_manager_flutter/services/ini_resources.dart';

/// **A measurement, not a rule.** How well filenames and character narrow the
/// "install this patch into which mod?" list, over a real library.
///
/// The destination picker offers the whole library, unranked. Two signals could
/// put the right folder first: the **filename fingerprint** (a patch names the
/// files it replaces, and a folder holding those names is a candidate) and the
/// **character** (a patch's mod page carries one; so does every library mod).
/// Neither may be built on before it is measured, because the failure mode is
/// invisible — a picker that confidently ranks the wrong folder first is worse
/// than one that ranks nothing.
///
/// Skipped unless `ZZZ_LIBRARY` points at a mods folder — one mod per
/// subdirectory. Optionally `ZZZ_CHARACTER_TAGS` points at the app's
/// `config.json`, whose `mod_character_tags` supplies the character signal.
///
/// ```
/// ZZZ_LIBRARY=~/XXMI\ Launcher/ZZMI/_Mods \
/// ZZZ_CHARACTER_TAGS=~/.local/share/zzz-mod-manager/config.json \
///   flutter test test/patch_destination_corpus_test.dart
/// ```
///
/// ## Where the ground truth comes from
///
/// A real corpus of patches paired with the mod each one patches does not exist
/// on any disk here, so the patches are **derived from the library itself**: for
/// mod X, the patch that would replace part of X. Two derivations, one per patch
/// kind the app recognises:
///
/// - an **`.ini` patch** ships X's `.ini` files and no content, so its
///   fingerprint is the resources those files reference;
/// - an **asset patch** ships a few of X's own asset files and no `.ini`, so its
///   fingerprint is those filenames.
///
/// The correct answer is X, and the question is where X lands among the other 70
/// folders.
///
/// **What that overstates and what it understates.** It overstates precision:
/// a derived patch's names come from the very copy of X on disk, while a real
/// patch author works from a version that may have renamed or restructured
/// things. It understates it too: a derived asset patch takes whichever files
/// this file picks, not the ones an author found worth replacing. What it
/// measures exactly, and what is actually in doubt, is **how far a filename
/// distinguishes one folder from another in a real library** — where mods for
/// one character are extracted by the same tool and therefore ship the same
/// names.
void main() {
  final root = Platform.environment['ZZZ_LIBRARY'];
  final tags = Platform.environment['ZZZ_CHARACTER_TAGS'];

  test(
    'how far filename and character narrow the destination list',
    () async {
      final mods = await _readLibrary(Directory(root!), _characters(tags));
      expect(mods, isNotEmpty, reason: 'library at $root held no mods');

      final iniCases = <_Case>[];
      final assetCases = <_Case>[];
      for (final subject in mods) {
        final ini = _iniPatchFingerprint(subject);
        if (ini.length >= _minFingerprint) {
          iniCases.add(_rank(subject, ini, mods, kind: 'ini'));
        }
        final asset = _assetPatchFingerprint(subject);
        if (asset.length >= _minFingerprint) {
          assetCases.add(_rank(subject, asset, mods, kind: 'asset'));
        }
      }

      _report(root, mods, 'ini patch (ships the .ini, no content)', iniCases);
      _report(root, mods, 'asset patch (ships a few files, no .ini)', assetCases);

      // The only invariant a measurement can carry: the scores are proportions,
      // and the subject was actually scored rather than skipped.
      for (final c in [...iniCases, ...assetCases]) {
        expect(c.subjectScore, inInclusiveRange(0.0, 1.0), reason: c.subject);
        expect(c.tiedAtTop, greaterThan(0), reason: c.subject);
      }
    },
    skip: root == null
        ? 'set ZZZ_LIBRARY to a mods folder to measure against it'
        : false,
  );
}

/// Below this a fingerprint is too thin to conclude anything from, and the case
/// is skipped rather than counted as a failure of the signal.
const int _minFingerprint = 2;

/// How many of its own files a derived asset patch ships.
///
/// Three, because that is the shape of the real pair the asset rule was written
/// from: GameBanana 605460 is one `.dds`, and a patch replacing a whole outfit
/// slot is a handful. Taken from evenly spaced positions in the sorted list so
/// the pick is deterministic and not all from one component.
const int _assetPatchFiles = 3;

class _LibraryMod {
  _LibraryMod(this.name, this.contents, this.character);

  final String name;
  final FolderContents contents;
  final String? character;

  /// Lower-cased basenames of every file in the folder.
  ///
  /// Basenames, because layouts differ between folders and a patch author ships
  /// files bare — the same reasoning `patch_placement.dart` is built on.
  late final Set<String> basenames = {
    for (final path in contents.files) _basename(path),
  };
}

class _Case {
  _Case({
    required this.kind,
    required this.subject,
    required this.character,
    required this.fingerprint,
    required this.subjectScore,
    required this.topScore,
    required this.tiedAtTop,
    required this.subjectInTopTie,
    required this.rank,
    required this.sameCharacterInTopTie,
    required this.runnerUp,
    required this.runnerUpScore,
  });

  final String kind;
  final String subject;
  final String? character;
  final int fingerprint;

  final double subjectScore;
  final double topScore;

  /// How many folders share the top score — the length of the list the user
  /// would still have to choose from if the ranking were trusted.
  final int tiedAtTop;
  final bool subjectInTopTie;

  /// Worst-case 1-based position of the correct answer: everything scoring
  /// higher, plus its whole tie.
  final int rank;

  /// The top tie narrowed to the subject's character, when it has one.
  final int? sameCharacterInTopTie;

  /// The best-scoring folder that is not the subject, for reading the margin.
  final String runnerUp;

  /// What that folder scored — **the target-not-installed number.**
  ///
  /// Finding a patch before the mod it patches is an ordinary way round, so the
  /// right answer is often not in the library at all. This is what the list
  /// would confidently put first in that case, and it is the reason a ranking
  /// may inform but never preselect.
  final double runnerUpScore;
}

Future<List<_LibraryMod>> _readLibrary(
  Directory root,
  Map<String, String> characters,
) async {
  final mods = <_LibraryMod>[];
  for (final entity in root.listSync()..sort(_byPath)) {
    if (entity is! Directory) continue;
    final name = _basename(entity.path.replaceAll(r'\', '/'), lower: false);
    final contents = await readFolderContents(entity);
    if (contents.files.isEmpty) continue;
    mods.add(_LibraryMod(name, contents, characters[name]));
  }
  return mods;
}

int _byPath(FileSystemEntity a, FileSystemEntity b) =>
    a.path.compareTo(b.path);

/// `mod_character_tags` out of the app's own config, so the measurement uses
/// the tags the app would actually rank on rather than a fresh detection.
Map<String, String> _characters(String? configPath) {
  if (configPath == null) return const <String, String>{};
  try {
    final json = jsonDecode(File(configPath).readAsStringSync());
    final tags = (json as Map)['mod_character_tags'];
    if (tags is! Map) return const <String, String>{};
    return {
      for (final entry in tags.entries)
        entry.key.toString(): entry.value.toString(),
    };
  } catch (_) {
    return const <String, String>{};
  }
}

/// What an `.ini`-only patch derived from [mod] would name: the resources its
/// `.ini` files reference.
///
/// Includes are dropped — one `.ini` including another is the patch's own
/// structure, not a file it expects to find in the folder it lands in. Same
/// exclusion `PatchAssessment.presentResources` makes.
Set<String> _iniPatchFingerprint(_LibraryMod mod) {
  if (!mod.contents.hasIni) return const <String>{};
  return {
    for (final ref in mod.contents.references.references)
      if (ref.kind == IniReferenceKind.resource) _basename(ref.path),
  };
}

/// What an asset-only patch derived from [mod] would ship: [_assetPatchFiles]
/// of its game assets, evenly spaced through the sorted list.
Set<String> _assetPatchFingerprint(_LibraryMod mod) {
  final assets = [
    for (final path in mod.contents.files)
      if (_isAsset(path)) _basename(path),
  ]..sort();
  if (assets.isEmpty) return const <String>{};
  if (assets.length <= _assetPatchFiles) return assets.toSet();
  final step = assets.length / _assetPatchFiles;
  return {
    for (var i = 0; i < _assetPatchFiles; i++) assets[(i * step).floor()],
  };
}

const Set<String> _assetExtensions = <String>{'.dds', '.buf', '.ib', '.vb'};

bool _isAsset(String path) {
  final dot = path.lastIndexOf('.');
  return dot >= 0 && _assetExtensions.contains(path.substring(dot));
}

/// Scores every folder in [mods] against [fingerprint] and locates [subject].
///
/// The score is the share of the fingerprint the folder holds — the plainest
/// reading of "this folder has the files this patch replaces". Deliberately not
/// weighted or tuned: a signal that needs tuning to look good on the library it
/// was tuned against has not been measured.
_Case _rank(
  _LibraryMod subject,
  Set<String> fingerprint,
  List<_LibraryMod> mods, {
  required String kind,
}) {
  final scores = <String, double>{};
  for (final mod in mods) {
    var hits = 0;
    for (final name in fingerprint) {
      if (mod.basenames.contains(name)) hits++;
    }
    scores[mod.name] = hits / fingerprint.length;
  }

  final subjectScore = scores[subject.name]!;
  final topScore = scores.values.reduce((a, b) => a > b ? a : b);
  bool at(double score, double of) => (score - of).abs() < 1e-9;

  final tied = [
    for (final entry in scores.entries)
      if (at(entry.value, topScore)) entry.key,
  ];
  final above = scores.values.where((s) => s > subjectScore + 1e-9).length;
  final sharing = scores.values.where((s) => at(s, subjectScore)).length;

  var runnerUp = '—';
  var best = -1.0;
  for (final entry in scores.entries) {
    if (entry.key == subject.name) continue;
    if (entry.value > best) {
      best = entry.value;
      runnerUp = '${entry.key} ${_pct(entry.value)}';
    }
  }

  final character = subject.character;
  return _Case(
    kind: kind,
    subject: subject.name,
    character: character,
    fingerprint: fingerprint.length,
    subjectScore: subjectScore,
    topScore: topScore,
    tiedAtTop: tied.length,
    subjectInTopTie: at(subjectScore, topScore),
    rank: above + sharing,
    sameCharacterInTopTie: character == null
        ? null
        : tied
            .where((name) => _characterOf(name, mods) == character)
            .length,
    runnerUp: runnerUp,
    runnerUpScore: best < 0 ? 0 : best,
  );
}

String? _characterOf(String name, List<_LibraryMod> mods) =>
    mods.firstWhere((mod) => mod.name == name).character;

void _report(
  String? root,
  List<_LibraryMod> mods,
  String heading,
  List<_Case> cases,
) {
  final tagged = mods.where((mod) => mod.character != null).length;
  _print('');
  _print('== $heading');
  _print('library: ${mods.length} folders, $tagged tagged with a character '
      '(at $root)');
  if (cases.isEmpty) {
    _print('no case had a fingerprint of $_minFingerprint or more; '
        'nothing measured');
    return;
  }

  for (final c in cases) {
    _print('  ${c.subjectInTopTie ? "top " : "MISS"} '
        'rank ${c.rank.toString().padLeft(2)}/${mods.length} '
        'tie ${c.tiedAtTop.toString().padLeft(2)}'
        '${c.sameCharacterInTopTie == null ? "" : " (${c.sameCharacterInTopTie} same character)"}'
        ' fp ${c.fingerprint.toString().padLeft(3)}'
        ' self ${_pct(c.subjectScore)} top ${_pct(c.topScore)}'
        ' | ${c.subject} → runner-up ${c.runnerUp}');
  }

  final unique = cases.where((c) => c.subjectInTopTie && c.tiedAtTop == 1);
  final inTie = cases.where((c) => c.subjectInTopTie);
  final topThree = cases.where((c) => c.rank <= 3);
  final ties = [for (final c in cases) c.tiedAtTop]..sort();
  final characterTies = [
    for (final c in cases)
      if (c.sameCharacterInTopTie != null) c.sameCharacterInTopTie!,
  ]..sort();

  _print('  ---');
  _print('  cases ${cases.length}'
      ' | correct answer alone at the top ${unique.length}'
      ' | in the top tie ${inTie.length}'
      ' | within worst-case rank 3 ${topThree.length}');
  _print('  top-tie size: median ${_median(ties)}, worst ${ties.last}'
      '${characterTies.isEmpty ? "" : "; narrowed to its character: median ${_median(characterTies)}, worst ${characterTies.last}"}');

  // With the subject taken out of the library — a patch found before the mod it
  // patches — this is what the ranking would offer instead.
  final perfect = cases.where((c) => c.runnerUpScore > 1 - 1e-9);
  final strong = cases.where((c) => c.runnerUpScore >= 0.9);
  final quiet = cases.where((c) => c.runnerUpScore < 0.5);
  _print('  target not installed: a wrong folder still scores 100% in '
      '${perfect.length}/${cases.length} cases, 90%+ in ${strong.length}, '
      'under 50% in ${quiet.length}');
}

String _pct(double value) => '${(value * 100).round()}%'.padLeft(4);

String _median(List<int> sorted) => sorted.isEmpty
    ? '—'
    : sorted[sorted.length ~/ 2].toString();

String _basename(String path, {bool lower = true}) {
  final cut = path.lastIndexOf('/');
  final name = cut < 0 ? path : path.substring(cut + 1);
  return lower ? name.toLowerCase() : name;
}

void _print(String line) {
  // ignore: avoid_print
  print(line);
}
