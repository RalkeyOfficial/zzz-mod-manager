import '../../models/gamebanana/gb_file.dart';

/// Why a file list did or did not yield a default download.
///
/// Carried out of [selectDefaultFile] so the UI can *say* why the user has to
/// choose, instead of presenting an inert download button with no explanation.
enum FileDefaultReason {
  /// Exactly one file is published — nothing to disambiguate.
  soleFile,

  /// Several files are published. Which one the user wants is genuinely unknown;
  /// see [selectDefaultFile] for why this is never guessed.
  ambiguous,

  /// The mod publishes no downloadable files at all (`_aFiles` was `[]`).
  noFiles,

  /// The response never carried a file list (`_aFiles` absent, i.e. null).
  /// Distinct from [noFiles]: this is "we didn't ask", not "there are none".
  notLoaded,
}

/// The outcome of the default-selection rule.
class FileDefault {
  const FileDefault(this.file, this.reason);

  /// The file to preselect, or null when the user must choose.
  final GbFile? file;

  final FileDefaultReason reason;

  bool get hasDefault => file != null;
}

/// Picks the file a mod's download button may preselect — **or nothing**.
///
/// The rule: preselect **only** when there is a single clear highest version and
/// no competing variants. When variants exist or the choice is ambiguous, do not
/// default; the user must pick. That protects against silently downloading a
/// demo, a patcher, or a different variant than the one the user was looking at.
///
/// ## Why there is no "highest version" branch
///
/// The rule reads as a conjunction, and its first half is **not computable from
/// what GameBanana publishes**, so the conjunction can never be satisfied by
/// more than one file. This is a property of the data, not a shortcut:
///
/// - `_sVersion` is free-form, not semver, and frequently absent
///   (`docs/gamebanana-api.md` §5). There is no ordering to take a maximum over.
/// - It is *routinely* null on every file of a mod, with the version written
///   into `_sDescription` instead — the field that is otherwise the **variant**
///   marker. One captured profile publishes ten files, all with
///   `_sVersion: null`, labelled "v3.4", "v3.3", "v3.2" … So version and variant
///   are not reliably separable per-file, and a rule that treated
///   `_sDescription` as a version would mistake "white hair ver" for a release.
/// - Upload date is no substitute. Another captured profile publishes, at once,
///   a "Main file" at 7.7, two utility patchers at 1.0, and three unversioned
///   *demo* archives. Newest-upload happens to be right there and would be wrong
///   the moment an author uploads a demo last.
///
/// Falling back to a guess is specifically what the plan forbids: a guess may
/// inform, never drive. So the honest implementation of "single clear highest
/// version" is "there is only one file".
///
/// Archived files are never candidates — they are superseded by definition, and
/// offering one as *the* default would install an old release on purpose.
FileDefault selectDefaultFile(List<GbFile>? files) {
  if (files == null) return const FileDefault(null, FileDefaultReason.notLoaded);

  final candidates = files.where((f) => !f.isArchived).toList();
  if (candidates.isEmpty) {
    return const FileDefault(null, FileDefaultReason.noFiles);
  }
  if (candidates.length == 1) {
    return FileDefault(candidates.first, FileDefaultReason.soleFile);
  }
  return const FileDefault(null, FileDefaultReason.ambiguous);
}

/// What a file row is **titled**: its filename.
///
/// This used to lead with the author's `_sDescription`, and that was wrong in a
/// way worth recording, because the reasoning behind it was not silly. The
/// argument was that the description is what distinguishes rows in practice —
/// and it often is. But it is free text, not a name: a real captured file
/// carries `Put it in the folder with the mod (replace it)`, which is an
/// *instruction*. Leading with it replaced the file's identity with commentary,
/// and the filename — the thing actually downloaded, and the only field
/// guaranteed to exist beside the id — disappeared from the UI entirely.
///
/// So the filename leads and [fileDisplayDetail] carries the rest underneath.
/// `_sVersion` is the fallback only because a file with neither is nameless.
///
/// Deliberately **not** presented as a version anywhere: `_sDescription` may be
/// "Main file", "white hair ver" or "v3.4", and the app cannot tell which.
String fileDisplayName(GbFile file) {
  final name = file.file?.trim();
  if (name != null && name.isNotEmpty) return name;
  final version = file.version?.trim();
  if (version != null && version.isNotEmpty) return version;
  return '#${file.idRow}';
}

/// The secondary line under [fileDisplayName] — the author's own description of
/// the file, with its version string when it has one.
///
/// Null when the author said nothing, so the caller renders no second line
/// rather than an empty one. Joined the same way the resolve dialog joins the
/// recorded pair, so `7.7 · Main file` reads identically wherever it appears.
///
/// Never folded into the title: these two carry different kinds of claim. The
/// title says *which file*, this says *what the author wants you to know about
/// it* — and the second is sometimes a sentence.
String? fileDisplayDetail(GbFile file) {
  final parts = [
    if (file.version?.trim() case final v? when v.isNotEmpty) v,
    if (file.description?.trim() case final d? when d.isNotEmpty) d,
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}
