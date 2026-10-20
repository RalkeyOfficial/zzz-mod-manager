import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../utils/detached_starter.dart';
import '../utils/process_probe.dart';
import 'log/logger.dart';
import 'log/system_report.dart';
import 'wine_runners.dart';

export 'wine_runners.dart' show WineRunner, WineRunnerKind, WineRunnerSource;

final Logger _log = Logger('platform');

/// What happened when the app tried to start the game.
enum LaunchOutcome {
  started,

  /// The launcher file is gone.
  notFound,

  /// This platform cannot start that kind of file, such as a `.desktop` shortcut, which can't take arguments.
  unsupported,

  /// The Wine or Proton that runs the launcher couldn't be started: missing from PATH, or the chosen file is gone.
  runnerMissing,

  /// Proton started without umu-launcher has no prefix to run in: it has no default of its own.
  prefixRequired,

  /// Starting it threw.
  failed,
}

/// The [outcome] of a launch, and for [LaunchOutcome.runnerMissing] the [program] that couldn't be run.
class LaunchResult {
  const LaunchResult(this.outcome, {this.program, this.containerDns});

  final LaunchOutcome outcome;
  final String? program;

  /// For a game started through umu-run, whether a name can be looked up inside its container, known a moment after
  /// the start. False means the game's anti-cheat will close the game; null, or no future, means no verdict.
  final Future<bool?>? containerDns;
}

/// What the Launch game button starts and how. See `docs/launch-game.md`.
class LaunchRequest {
  const LaunchRequest({
    required this.executable,
    required this.arguments,
    this.runner = '',
    this.prefix = '',
    this.useUmu = false,
  });

  /// The XXMI Launcher, or the file chosen instead, exactly as stored.
  final String executable;

  /// The arguments as typed: one string, split into words only where the platform needs a list.
  final String arguments;

  /// Linux only: the Wine binary or Proton script, empty for `wine` from PATH.
  final String runner;

  /// Linux only: the Wine prefix, empty for the runner's own default.
  final String prefix;

  /// Linux only: whether a Proton runner starts through umu-launcher rather than directly.
  final bool useUmu;
}

/// A link in ZZMI's mods folder whose target folder is missing.
@immutable
class DeadModLink {
  const DeadModLink({required this.name, this.target});

  /// The link's own name, which is the mod folder's name.
  final String name;

  /// Where it points, or null when that can't be read.
  final String? target;

  @override
  bool operator ==(Object other) => other is DeadModLink && other.name == name && other.target == target;

  @override
  int get hashCode => Object.hash(name, target);
}

/// A link to [target], a folder on a network share or drive, refused because only a symlink can lead there and this
/// system refused one: on Windows, one without Developer Mode, where the app's fallback, a junction, leads only to a
/// local folder. Nothing was left at [link] that was not there before.
class NetworkLinkRefused implements Exception {
  const NetworkLinkRefused(this.link, this.target);
  final String link;
  final String target;

  @override
  String toString() => 'a link to a network folder needs a symlink, and one was refused: $link -> $target';
}

/// What every temporary name a link replace uses in ZZMI's Mods folder starts with. `DISABLED` because ZZMI's
/// `exclude_recursive = DISABLED*` then never loads one a replace left behind; the rest because no mod is named so.
const String temporaryLinkPrefix = 'DISABLED.zzz-mod-manager.';

/// The temporary name the new link for [name] is made under before it takes [name]'s place.
String replacementLinkName(String name) => '${temporaryLinkPrefix}relink.$name';

/// The temporary name the old link of [name] is moved aside to while the new one takes its place (Windows).
String asideLinkName(String name) => '${temporaryLinkPrefix}relink-old.$name';

/// Whether [name], an entry of ZZMI's Mods folder, is one of the temporary names above, which no reader of that
/// folder takes for a mod.
bool isTemporaryLinkName(String name) =>
    name.startsWith('${temporaryLinkPrefix}relink.') || name.startsWith('${temporaryLinkPrefix}relink-old.');

/// [raw], a link's target as stored, as an absolute normalised path in [context]'s style: a relative target is
/// resolved against [linkFolder], and a Windows `\??\` or `\\?\` prefix is stripped, with `UNC\` after it read as
/// the `\\` of a network path.
String normaliseLinkTarget(String raw, String linkFolder, {p.Context? context}) {
  final paths = context ?? p.context;
  var target = raw;
  if (paths.style == p.Style.windows && (target.startsWith(r'\??\') || target.startsWith(r'\\?\'))) {
    target = target.substring(4);
    if (target.toUpperCase().startsWith(r'UNC\')) target = '\\\\${target.substring(4)}';
  }
  return paths.normalize(paths.isAbsolute(target) ? target : paths.join(linkFolder, target));
}

/// Whether [a] and [b] name the same path once normalised in [context]'s style, ignoring case when [ignoreCase].
bool pathsEqual(String a, String b, {bool ignoreCase = false, p.Context? context}) {
  final paths = context ?? p.context;
  final x = paths.normalize(a);
  final y = paths.normalize(b);
  return ignoreCase ? x.toLowerCase() == y.toLowerCase() : x == y;
}

/// Lists [linksFolder] and keeps the entries [isLinkEntry] calls links and whose target can't be found, each with
/// its target as [readTarget] reads it. Shared by both platforms, which differ only in how a link shows up in a
/// listing and how its target is read.
Future<List<DeadModLink>> readDeadModLinks(
  String linksFolder, {
  required Future<bool> Function(FileSystemEntity entry) isLinkEntry,
  required Future<String?> Function(String linkPath) readTarget,
}) async {
  final dead = <DeadModLink>[];
  try {
    await for (final entry in Directory(linksFolder).list(followLinks: false)) {
      final name = p.basename(entry.path);
      if (name.startsWith('.') || isTemporaryLinkName(name)) continue;
      if (!await isLinkEntry(entry)) continue;
      // Follows the link, so a link to a missing folder reads as not found.
      if (await FileSystemEntity.type(entry.path) != FileSystemEntityType.notFound) continue;
      dead.add(DeadModLink(name: name, target: await readTarget(entry.path)));
    }
  } on PathNotFoundException {
    // No links folder yet: nothing is linked, so nothing is missing.
    return const [];
  } catch (e) {
    // A folder that can't be read, such as one the user can't open, shows no rows, so the reason goes to the log.
    _log.warning('could not list the links folder', error: e, fields: {'folder': linksFolder});
    return const [];
  }
  dead.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return dead;
}

/// Абстрактний клас для платформно-специфічних операцій
///
/// **There is deliberately nothing here for reloading mods in the running
/// game.** Pressing F10 for the user was tried and removed — see
/// [`docs/mod-reload.md`](../../../docs/mod-reload.md) for what was measured and
/// why it loses. Press F10 in the game.
abstract class PlatformService {
  /// Makes the link at [linkPath] to [sourcePath], a symlink, or a junction on Windows where a symlink is refused.
  /// A link already at [linkPath] is changed through [replaceModLink], so one that can't be made leaves it as it was.
  /// Throws only [NetworkLinkRefused], so the user can be told why; any other failure is false.
  Future<bool> createModLink(String sourcePath, String linkPath);
  
  /// Видаляє symbolic link або його аналог
  Future<bool> removeModLink(String linkPath);
  
  /// Перевіряє чи є шлях symbolic link
  Future<bool> isModLink(String linkPath);

  /// Where the link at [linkPath] points, as an absolute normalised path ([normaliseLinkTarget]), or null when it is
  /// not a link or its target can't be read. Never throws.
  Future<String?> readModLinkTarget(String linkPath);

  /// Points the existing link at [linkPath] at [newTarget], logging the change on one line. False when it is not a
  /// link or the change failed; a failed change leaves the link pointing where it did, unless putting it back failed
  /// too, which is logged. Throws only [NetworkLinkRefused], after putting the old link back.
  Future<bool> replaceModLink(String linkPath, String newTarget);

  /// Whether [a] and [b] name the same path on this platform's filesystem ([pathsEqual]).
  bool samePath(String a, String b);

  /// The links directly in [linksFolder] whose target isn't there, such as a mod folder on an unplugged drive.
  ///
  /// Read only: such a link is never removed, since it works again the moment its folder is back
  /// (`docs/library-screen.md` §16). Empty when the folder can't be listed. Never throws.
  Future<List<DeadModLink>> listDeadModLinks(String linksFolder);

  /// Отримує шлях до директорії даних додатку
  String getAppDataPath();
  
  /// Знаходить процеси гри
  Future<List<String>> findGameProcesses();
  
  /// Визначає тип дисплейного сервера (для Linux)
  String getDisplayServerType() => 'unknown';
  
  /// Відкриває URL у зовнішньому браузері
  Future<bool> openUrlInBrowser(String url);
  
  /// Отримує шлях до системної Downloads директорії користувача
  String? getSystemDownloadsPath();

  /// Відкриває вказану папку у файловому менеджері системи
  Future<bool> openFolderInFileManager(String folderPath);

  /// Starts the launcher [request] names, with its arguments, and returns without waiting for it.
  ///
  /// Linux runs an `.exe` under Wine or Proton and an executable script directly; Windows starts what a double-click
  /// would. [starter] is the seam a test records the command through; Windows starts through the shell and ignores
  /// it. [probe] runs the check of name lookups inside umu-run's container, which only Linux has. See
  /// `docs/launch-game.md`.
  Future<LaunchResult> launchGame(
    LaunchRequest request, {
    DetachedStarter starter = const DetachedStarter(),
    ProcessProbe probe = const ProcessProbe(),
  });

  /// Whether Launch game runs the launcher under Wine or Proton, so Settings shows where to find them.
  bool get launchesThroughWine;

  /// The Wine and Proton builds Settings offers to run the launcher with; empty where [launchesThroughWine] is false.
  Future<List<WineRunner>> findWineRunners();

  /// Reads rich-text HTML from the system clipboard, or null when the
  /// clipboard holds no HTML (or the platform tool needed to read it is
  /// unavailable). Used to paste formatted text as markdown.
  Future<String?> getClipboardHtml();

  /// Filenames to look for when hunting a **bundled** 7-Zip beside the app's
  /// own executable, most preferred first.
  ///
  /// A bundled copy is how the portable builds — the Linux tarball and the
  /// Windows installer — guarantee an extractor without a package manager. The
  /// AUR package does not need one: it declares `7zip` and lets pacman keep it
  /// current, which vendoring would undo.
  List<String> get bundledSevenZipNames;

  /// The account name this app is running as, or null when the environment
  /// does not say.
  ///
  /// **For censoring it out of the log, and nothing else.** Reading the
  /// environment only — no process is spawned — because this is asked during
  /// logger bootstrap, before the Flutter binding exists, and must not be able
  /// to block or throw. It must never be *logged*; see `docs/logging.md`.
  String? get osUserName;

  /// Everything the log header reports about this machine that costs a process
  /// or a file read.
  ///
  /// **One method returning one struct, rather than a getter per fact.** The two
  /// platforms differ in *which questions exist*: there is no distro and no
  /// display server on Windows, and each platform finds its extractor its own
  /// way. A pile of nullable getters would push "is this meaningful here?" back
  /// to the caller and invite a `Platform.isWindows` at the call site, which is
  /// the rule this exists to protect.
  ///
  /// Never throws, and every probe is bounded: a header is a nice-to-have and
  /// must not be able to delay or break a launch.
  Future<SystemReport> describeSystem({ProcessProbe probe});

  /// The user's home directory, or null when the environment does not say.
  ///
  /// Same purpose and the same constraint as [osUserName]: every app-owned path
  /// begins with this, so it is what turns `/home/someone/.local/share/…` into
  /// `~/.local/share/…` on the way to a log line.
  String? get homeDirectoryPath;

  /// Free bytes on the volume holding [forPath], or **null when that cannot be
  /// asked** — the path does not exist, the tool is missing, the call failed.
  ///
  /// Here rather than at the call site because Dart exposes no portable free
  /// space API at all, and the two platforms answer by completely different
  /// means: Linux reads it out of `df`, Windows asks `kernel32` directly.
  ///
  /// **Null is a real answer and means "do not check".** Its one caller refuses
  /// a download that provably will not fit, and a refusal is worse than a
  /// failure when the number behind it is a guess — so an unknown free space
  /// lets the transfer run and fail honestly if it must.
  ///
  /// Never throws, and bounded like every other probe here: a preflight must
  /// not be able to hang the thing it is checking.
  Future<int?> freeSpaceBytes(String forPath, {ProcessProbe probe});
}
