/// What machine this is, as data.
///
/// The header of a log file is the half a bug report is actually answered from:
/// "it does not extract" and "it does not extract, and 7-Zip is absent" are
/// different tickets. Gathering it is `system_probe.dart`; **this file is the
/// shape and the rendering**, pure, so that the *Windows* header can be asserted
/// from a Linux test and vice versa.
library;

/// Whether a tool is here, absent, or has no meaning on this platform.
///
/// The third state is not pedantry. Without it a Windows log reads
/// `xdotool: missing` — and a reader who does not know that Windows sends F10
/// through win32 will chase it as the cause.
enum ToolState {
  present,
  missing,

  /// Not part of how this platform works at all.
  notApplicable,
}

class ToolStatus {
  const ToolStatus({
    required this.name,
    required this.state,
    this.path,
    this.version,
    this.note,
  });

  const ToolStatus.missing(this.name)
      : state = ToolState.missing,
        path = null,
        version = null,
        note = null;

  const ToolStatus.notApplicable(this.name, {this.note})
      : state = ToolState.notApplicable,
        path = null,
        version = null;

  final String name;
  final ToolState state;

  /// Where it was found. Censored on the way out like every other path.
  final String? path;

  /// Null when the tool is present but would not say — an unrecognised banner,
  /// or a version flag it does not have. That is *present, version unknown*,
  /// which is a different fact from absent.
  final String? version;

  /// How it got here: `bundled`, `system`, `win32`.
  final String? note;
}

class OsDescription {
  const OsDescription({
    required this.name,
    required this.version,
    this.distro,
    this.distroId,
    this.displayServer,
    this.desktop,
  });

  /// `linux` / `windows`.
  final String name;

  /// `Platform.operatingSystemVersion` — on Linux this is already the full
  /// kernel string, and on Windows the build. Free, and no process needed.
  final String version;

  /// `PRETTY_NAME` from `/etc/os-release`. Null on Windows, where there is no
  /// such thing.
  final String? distro;

  /// `ID` from the same file — `arch`, `ubuntu`, `fedora`. The machine-readable
  /// half, worth keeping separately because [distro] is a marketing string.
  final String? distroId;

  /// `wayland`, `x11`, `windows-dwm`.
  final String? displayServer;

  /// `XDG_CURRENT_DESKTOP`, where there is one.
  final String? desktop;
}

/// Everything the probe found, ready to be logged.
class SystemReport {
  const SystemReport({required this.os, this.tools = const <ToolStatus>[]});

  final OsDescription os;
  final List<ToolStatus> tools;
}

/// The fields of the `environment` line.
///
/// A map rather than a string so the log formatter owns quoting and the
/// redactor owns censoring — the same route every other record takes.
Map<String, Object?> osFields(OsDescription os) => <String, Object?>{
      'os': os.name,
      'version': os.version,
      if (os.distro != null) 'distro': os.distro,
      if (os.distroId != null) 'distro_id': os.distroId,
      if (os.displayServer != null) 'display': os.displayServer,
      if (os.desktop != null) 'desktop': os.desktop,
    };

/// The fields of one `tool` line.
Map<String, Object?> toolFields(ToolStatus tool) => <String, Object?>{
      'tool': tool.name,
      'state': tool.state.name,
      // `unknown` rather than an absent key: "present but would not say which
      // version" is a fact, and an absent field reads as a caller who forgot.
      if (tool.state == ToolState.present) 'version': tool.version ?? 'unknown',
      if (tool.path != null) 'path': tool.path,
      if (tool.note != null) 'via': tool.note,
    };

/// `KEY=value` lines, quotes stripped, comments and blanks ignored.
///
/// `/etc/os-release` is a shell fragment by specification, and the values that
/// matter are routinely quoted (`PRETTY_NAME="CachyOS Linux"`) while the ones
/// beside them are not (`ID=cachyos`). Pure, so the distro logic is testable on
/// a machine that has no `/etc/os-release` at all.
Map<String, String> parseOsRelease(String contents) {
  final out = <String, String>{};
  for (final raw in contents.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final split = line.indexOf('=');
    if (split <= 0) continue;
    final key = line.substring(0, split).trim();
    var value = line.substring(split + 1).trim();
    if (value.length >= 2 &&
        ((value.startsWith('"') && value.endsWith('"')) ||
            (value.startsWith("'") && value.endsWith("'")))) {
      value = value.substring(1, value.length - 1);
    }
    if (key.isNotEmpty) out[key] = value;
  }
  return out;
}
