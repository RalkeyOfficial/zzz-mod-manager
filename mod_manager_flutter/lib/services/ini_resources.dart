/// What a mod's `.ini` files **ask the loader for**, as opposed to what the
/// keybind parser reads out of them.
///
/// `IniParserService` understands one thing — sections whose name looks like a
/// hotkey — because that is all the app has ever needed. This file answers a
/// different question that the update path depends on: *which files on disk does
/// this `.ini` expect to find?* A download whose `.ini` names resources it does
/// not ship cannot stand on its own, which is the definition of a patch (see
/// `services/patch_detection.dart`), and an `.ini` left behind by an upstream
/// rename is recognised by the resources it names still being present (see
/// `services/update_apply/stale_ini.dart`).
///
/// **Pure.** The caller reads the files; this only parses text. That is what
/// lets both uses be tested against fixture strings rather than a temp
/// directory, and it is the only reason the rules below are checkable at all.
///
/// ## A declaration is not a requirement
///
/// The rule that matters most here, and the one that was wrong first time. A
/// `[Resource…]` section carrying a `filename` **defines** a resource; the
/// loader only opens that file when something else **references** the section:
///
/// ```ini
/// Resource\ZZMI\Diffuse = ref ResourceMiyabiBodyADiffuse   ; the reference
///
/// [ResourceMiyabiBodyADiffuse]                              ; the definition
/// filename = MiyabiBodyADiffuse.dds
/// ```
///
/// A definition nobody references is **inert** — the file is never opened, so
/// its absence costs nothing. That is not an edge case: authors start from a
/// full character template and delete only the override sections they don't
/// need, leaving the resource definitions behind. Measured on a real, working
/// mod (`Miyabi Transfer Student`, GameBanana 700727): 31 sections declare a
/// `filename`, 29 are referenced and ship their file, and the 2 that are never
/// referenced are the only ones absent. Counting declarations rather than
/// references reported that mod — freshly downloaded, complete, working — as a
/// patch mod.
///
/// So only a **referenced** section's `filename` becomes a required file. The
/// patch test survives intact, and for the right reason: a patch `.ini` is a
/// *full replacement* for the mod's working `.ini`, so the sections it declares
/// are exactly the ones it references. That is the mechanism by which it
/// patches.
///
/// It also fails in the safe direction. A reference syntax this does not
/// recognise leaves its resource looking unreferenced, which drops it from the
/// required set — a **missed** warning rather than a false one, which is the
/// right way round for something shown over a live install.
///
/// ## Three more things this does not treat as a missing file
///
/// Each would otherwise make an ordinary mod look broken:
///
/// - **A section with no `filename` at all is a run-time buffer**, not a file.
///   3DMigoto's `[Resource…]` sections describe both, and the ones with
///   `type = Buffer` plus a `stride` are allocated in memory. Only a literal
///   `filename` names something on disk.
/// - **A value that is not a literal path cannot be checked.** `filename` may
///   carry a variable (`$\mymod\slot`) or a wildcard, and "we could not resolve
///   this" is not the same fact as "this file is absent". Unresolvable entries
///   are counted separately and never reported as missing.
/// - **Shaders are picked up by filename convention** from `ShaderFixes/` rather
///   than by reference, so they never appear here in the first place. Worth
///   stating because it is the one file class where a *leftover* can still be
///   live, which matters to the update path in the opposite direction.
///
/// Namespaces are read but do not affect a *path*. `namespace = …` renames
/// *sections* so that two mods can define `[ResourceBody]` without colliding;
/// it has no bearing on a `filename`, which is always relative to the `.ini`
/// that wrote it. It does affect how a section is **referenced** —
/// `ref \author\mod\ResourceBody` — so reference matching compares the last
/// `\`-separated segment.
library;

import 'package:path/path.dart' as p;

/// What kind of thing an `.ini` line pointed at.
enum IniReferenceKind {
  /// A `filename = …` — a file the loader will open.
  resource,

  /// An `include = …` — another `.ini`, which is also a file that must exist.
  include,

  /// An `include_recursive = …` — a *directory* of `.ini` files.
  includeDirectory,
}

/// One resolved pointer from an `.ini` to something on disk.
class IniReference {
  const IniReference({
    required this.path,
    required this.kind,
    required this.declaredIn,
  });

  /// Normalised, lower-cased, `/`-separated and relative to the **root of the
  /// folder being examined** — not to the `.ini` that declared it.
  final String path;

  final IniReferenceKind kind;

  /// The `.ini` that carried the line, in the same normalised form.
  final String declaredIn;

  @override
  bool operator ==(Object other) =>
      other is IniReference &&
      other.path == path &&
      other.kind == kind &&
      other.declaredIn == declaredIn;

  @override
  int get hashCode => Object.hash(path, kind, declaredIn);

  @override
  String toString() => '$declaredIn → $path (${kind.name})';
}

/// Everything a folder's `.ini` files point at.
class IniReferences {
  const IniReferences({
    this.references = const <IniReference>[],
    this.unresolvable = 0,
    this.unreferenced = 0,
  });

  static const IniReferences none = IniReferences();

  final List<IniReference> references;

  /// How many `filename` / `include` values could not be reduced to a literal
  /// path (a variable or a wildcard). Kept as a count rather than dropped
  /// silently: it is the difference between "this mod references nothing" and
  /// "we could not read what it references", and only the first supports a
  /// conclusion.
  final int unresolvable;

  /// How many `[Resource…]` sections declared a `filename` that **nothing
  /// references**, and were therefore dropped.
  ///
  /// Kept because it is the difference between a mod that is complete and one
  /// that merely looks complete once the filter has run. It is also the number
  /// that made this rule necessary: a real, working mod had two, and counting
  /// them reported it as a patch.
  final int unreferenced;

  bool get isEmpty => references.isEmpty && unresolvable == 0;

  /// Every distinct path pointed at, whatever the kind.
  Set<String> get paths => {for (final ref in references) ref.path};

  /// The paths declared by one particular `.ini`.
  Set<String> pathsFrom(String iniPath) {
    final key = normalizeIniPath(iniPath);
    return {
      for (final ref in references)
        if (ref.declaredIn == key) ref.path,
    };
  }

  /// Which `.ini` files contributed at least one reference.
  Set<String> get declaringInis => {for (final ref in references) ref.declaredIn};
}

/// Parses every `.ini` in a folder at once.
///
/// [iniContents] maps each `.ini`'s path **relative to the folder root** to its
/// text. Collectively rather than one file at a time, and that is the rule
/// rather than a convenience: a mod may split its sections across several
/// `.ini` files, so asking "does *this* file ship what *it* references" of each
/// in isolation would report a perfectly ordinary two-file mod as broken. The
/// answer is only ever meaningful for the whole folder.
/// Two passes, and the second is the whole point: pass one records every
/// declaration *and* every section name that appears on the right-hand side of
/// some other line; pass two keeps only the declarations pass one saw
/// referenced. `include` and `include_recursive` skip the filter — an include
/// **is** its own reference.
///
/// The used-name set is gathered across the **whole folder**, not per file,
/// because a mod routinely declares its resources in one `.ini` and references
/// them from another.
IniReferences collectIniReferences(Map<String, String> iniContents) {
  final resources = <_Declaration>[];
  final includes = <IniReference>[];
  final used = <String>{};
  var unresolvable = 0;

  for (final entry in iniContents.entries) {
    final iniPath = normalizeIniPath(entry.key);
    final iniDir = p.url.dirname(iniPath);
    String? section;

    for (final line in entry.value.split(_lineBreak)) {
      final header = _sectionName(line);
      if (header != null) {
        section = header;
        continue;
      }
      final parsed = _parseLine(line);
      if (parsed == null) continue;
      final (key, value) = parsed;
      if (value.isEmpty) continue;

      final kind = switch (key) {
        'filename' => IniReferenceKind.resource,
        'include' => IniReferenceKind.include,
        'include_recursive' => IniReferenceKind.includeDirectory,
        _ => null,
      };
      if (kind == null) {
        // Every other line's value can name a section. `Resource\ZZMI\Diffuse =
        // ref ResourceBodyDiffuse`, `ps-t0 = ResourceFoo`, `this = ResourceFoo`
        // are all references, and rather than enumerate the syntaxes we take
        // every token — a stray word that happens to match a section name is
        // harmless, while a syntax we failed to list would silently drop a
        // resource that is genuinely required.
        used.addAll(_valueTokens(value));
        continue;
      }

      final resolved = _resolveAgainst(iniDir, value);
      if (resolved == null) {
        unresolvable++;
        continue;
      }
      final reference =
          IniReference(path: resolved, kind: kind, declaredIn: iniPath);
      if (kind == IniReferenceKind.resource) {
        resources.add(_Declaration(reference, section));
      } else {
        includes.add(reference);
      }
    }
  }

  final live = <IniReference>[];
  var unreferenced = 0;
  for (final declaration in resources) {
    // A `filename` outside any section has no name to be referenced by, so it
    // cannot be filtered — keep it rather than invent a reason to drop it.
    final name = declaration.section;
    if (name == null || used.contains(_sectionKey(name))) {
      live.add(declaration.reference);
    } else {
      unreferenced++;
    }
  }

  return IniReferences(
    references: [...live, ...includes],
    unresolvable: unresolvable,
    unreferenced: unreferenced,
  );
}

/// A `filename` and the section that declared it, before the reference filter.
class _Declaration {
  const _Declaration(this.reference, this.section);
  final IniReference reference;
  final String? section;
}

/// `[Name]` → `Name`, or null.
String? _sectionName(String raw) {
  final line = raw.trim();
  if (!line.startsWith('[') || !line.endsWith(']')) return null;
  final name = line.substring(1, line.length - 1).trim();
  return name.isEmpty ? null : name;
}

/// The words a value could be naming a section with.
///
/// Split on whitespace, commas and `=`; quotes stripped; **last `\`-separated
/// segment taken**, because a namespaced reference is written
/// `ref \author\mod\ResourceBody` while the section is declared as
/// `[ResourceBody]`.
Iterable<String> _valueTokens(String value) sync* {
  for (final raw in value.split(RegExp(r'[\s,=]+'))) {
    final token = raw.replaceAll('"', '').split(r'\').last.trim();
    if (token.isEmpty) continue;
    yield _sectionKey(token);
  }
}

/// Section names compare case-insensitively, like everything else 3DMigoto
/// reads.
String _sectionKey(String name) => name.split(r'\').last.trim().toLowerCase();

/// A `key = value` pair with the key lower-cased, or null for anything else.
///
/// Section headers, comments and blank lines all fall out here. Comments may
/// also *follow* a value (`filename = a.dds ; the good one`), which is why the
/// value is cut at the first `;` — a trailing comment folded into the path would
/// make every commented line unresolvable.
(String, String)? _parseLine(String raw) {
  var line = raw.trim();
  if (line.isEmpty) return null;
  if (line.startsWith(';') || line.startsWith('#')) return null;
  if (line.startsWith('[')) return null;
  final eq = line.indexOf('=');
  if (eq <= 0) return null;
  final key = line.substring(0, eq).trim().toLowerCase();
  var value = line.substring(eq + 1);
  final comment = value.indexOf(';');
  if (comment >= 0) value = value.substring(0, comment);
  return (key, value.trim());
}

/// Resolves an `.ini`'s value against the directory that `.ini` lives in, or
/// null when it is not a literal path.
///
/// Null covers three cases and they are all "we cannot check this", never "this
/// is missing": a 3DMigoto variable (`$\ns\slot`), a wildcard, and a path that
/// climbs out of the folder entirely. The last one is the same refusal
/// `ArchiveService._sanitizeArchivePath` makes about archive members, for the
/// same reason.
String? _resolveAgainst(String iniDir, String value) {
  if (value.contains(r'$') || value.contains('*') || value.contains('?')) {
    return null;
  }
  final slashed = value.replaceAll(r'\', '/').trim();
  if (slashed.isEmpty) return null;
  // An absolute path in a mod `.ini` is either a mistake or a machine-specific
  // reference; either way it says nothing about this folder's contents.
  if (slashed.startsWith('/') || RegExp(r'^[a-zA-Z]:').hasMatch(slashed)) {
    return null;
  }
  final joined = iniDir == '.' || iniDir.isEmpty
      ? slashed
      : p.url.join(iniDir, slashed);
  final normalized = p.url.normalize(joined);
  if (normalized.startsWith('..')) return null;
  return normalized.toLowerCase();
}

/// The one spelling every path in this file and its callers is compared in:
/// `/`-separated, lower-cased, no leading `./`.
///
/// Case-insensitive on **every** platform, deliberately. 3DMigoto is a Windows
/// loader and its paths are case-insensitive there, so authors write `Body.dds`
/// against `body.dds` freely; comparing case-sensitively on Linux would report
/// those as missing files and call an ordinary mod a patch.
String normalizeIniPath(String value) {
  final slashed = value.replaceAll(r'\', '/').trim();
  return p.url.normalize(slashed).toLowerCase();
}

/// CRLF as well as LF: mod `.ini` files are written on Windows far more often
/// than not, and a stray `\r` left on the end of a value turns every path into
/// one that does not exist.
final RegExp _lineBreak = RegExp(r'\r\n|\r|\n');
