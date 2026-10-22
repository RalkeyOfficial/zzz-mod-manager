/// Reading an archive's unpacked size out of `7z l -slt`.
///
/// Pure and separate for the same reason [parseDfAvailableBytes] is
/// (`df_output.dart`): the number decides whether an install is refused, and
/// the process call around it cannot be tested without a real archive.
library;

/// The total unpacked size named by `7z l -slt`, or null if the output says
/// nothing usable.
///
/// `-slt` prints one block per entry, which is what makes this parseable at all
/// — the default table is column-aligned prose with a localized summary line:
///
/// ```
/// Path = mod/body.dds
/// Folder = -
/// Size = 5592448
/// Packed Size = 4194304
/// ```
///
/// **`Size` and nothing else.** `Packed Size` is what the archive holds, which
/// is the number that is already on disk rather than the one about to be
/// written; the header block's `Physical Size` is the archive file itself. Both
/// are excluded by anchoring the match at the start of the line.
///
/// Directory entries carry `Size = 0` or none at all, so they contribute
/// nothing — correct, since a directory costs no meaningful space.
///
/// Returns null rather than 0 for output with no entries: an archive whose
/// listing could not be read is unknown, and unknown means "do not check". A
/// genuinely empty archive is also unknown by this rule, which costs nothing —
/// there is no space question about unpacking nothing.
int? parseSevenZipUnpackedBytes(String output) {
  final pattern = RegExp(r'^Size = (\d+)\s*$', multiLine: true);

  var total = 0;
  var found = false;
  for (final match in pattern.allMatches(output)) {
    final size = int.tryParse(match.group(1)!);
    if (size == null) continue;
    found = true;
    total += size;
  }

  return found ? total : null;
}

/// Whether `7z l -slt` names any entry `Encrypted = +`, which is how an archive
/// whose files are encrypted lists without a password. A field rather than a
/// message, so nothing depends on 7-Zip's English.
bool sevenZipListsEncryptedEntries(String output) =>
    RegExp(r'^Encrypted = \+\s*$', multiLine: true).hasMatch(output);
