import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:url_launcher/url_launcher.dart';
import '../utils/command_arguments.dart';
import '../utils/detached_starter.dart';
import '../utils/df_output.dart';
import '../utils/process_probe.dart';
import 'log/logger.dart';
import 'log/system_report.dart';
import 'platform_service.dart';
import 'wine_runners.dart' as wine_runners;

final Logger _log = Logger('platform');
final Logger _files = Logger('fileops');

/// The wineserver a screen lock waits on once the game's runner has exited, empty for none, and the environment
/// naming the prefix it serves.
typedef PrefixServer = ({String server, Map<String, String> environment});

/// Linux-специфічна реалізація PlatformService
class LinuxPlatformService implements PlatformService {
  /// [environment] is the one umu-run inherits, read for umu's data folder; a test passes its own.
  LinuxPlatformService({Map<String, String>? environment}) : _environment = environment ?? Platform.environment;

  final Map<String, String> _environment;

  @override
  Future<bool> createModLink(String sourcePath, String linkPath) async {
    // A link already of that name, live or dead, is replaced in one step, so a failure leaves it as it was.
    if (await isModLink(linkPath)) return replaceModLink(linkPath, sourcePath);
    try {
      await Link(linkPath).create(sourcePath, recursive: false);
      _files.info('link created', fields: {
        'kind': 'symlink',
        'link': linkPath,
        'target': sourcePath,
      });
      return true;
    } catch (error, stack) {
      _files.error('link failed', error: error, stack: stack, fields: {
        'kind': 'symlink',
        'link': linkPath,
        'target': sourcePath,
      });
      return false;
    }
  }
  
  @override
  Future<bool> removeModLink(String linkPath) async {
    try {
      final isLink = await FileSystemEntity.isLink(linkPath);
      if (!isLink) {
        // Refused rather than failed: deleting a real folder because it was
        // mistaken for a link is the one outcome this app must never have.
        _files.warning('not a link, left alone', fields: {'path': linkPath});
        return false;
      }

      final target = await readModLinkTarget(linkPath);
      await Link(linkPath).delete();
      _files.info('link removed', fields: {'link': linkPath, 'target': target});
      return true;
    } catch (error, stack) {
      _files.error('link removal failed',
          error: error, stack: stack, fields: {'link': linkPath});
      return false;
    }
  }

  @override
  Future<bool> isModLink(String linkPath) async {
    try {
      return await FileSystemEntity.isLink(linkPath);
    } catch (e) {
      return false;
    }
  }

  @override
  Future<String?> readModLinkTarget(String linkPath) async {
    try {
      if (!await FileSystemEntity.isLink(linkPath)) return null;
      return normaliseLinkTarget(await Link(linkPath).target(), path.dirname(linkPath));
    } catch (_) {
      return null;
    }
  }

  /// Made under a temporary name beside the old link ([replacementLinkName]) and renamed over it, so the name always
  /// points somewhere: the rename replaces the old link in one step.
  @override
  Future<bool> replaceModLink(String linkPath, String newTarget) async {
    if (!await isModLink(linkPath)) {
      _files.warning('not a link, left alone', fields: {'path': linkPath});
      return false;
    }
    final previous = await readModLinkTarget(linkPath);
    if (previous == null) {
      _files.warning('link target unreadable, left alone', fields: {'path': linkPath});
      return false;
    }
    final temporary = Link(path.join(path.dirname(linkPath), replacementLinkName(path.basename(linkPath))));
    try {
      if (await FileSystemEntity.isLink(temporary.path)) await temporary.delete();
      await temporary.create(newTarget, recursive: false);
      await temporary.rename(linkPath);
      _files.info('link replaced', fields: {
        'kind': 'symlink',
        'link': linkPath,
        'from': previous,
        'target': newTarget,
      });
      return true;
    } catch (error, stack) {
      _files.error('link replace failed', error: error, stack: stack, fields: {
        'link': linkPath,
        'from': previous,
        'target': newTarget,
      });
      try {
        if (await FileSystemEntity.isLink(temporary.path)) await temporary.delete();
      } catch (error) {
        // The old link is untouched; only the temporary, which ZZMI and the app skip, is left beside it.
        _files.warning('temporary link left behind', error: error, fields: {'path': temporary.path});
      }
      return false;
    }
  }

  @override
  bool samePath(String a, String b) => pathsEqual(a, b);

  @override
  Future<List<DeadModLink>> listDeadModLinks(String linksFolder) => readDeadModLinks(
        linksFolder,
        isLinkEntry: (entry) async => entry is Link,
        readTarget: readModLinkTarget,
      );

  @override
  String getAppDataPath() {
    final homeDir = Platform.environment['HOME'];
    if (homeDir == null) {
      throw Exception('HOME environment variable not found');
    }
    
    // Використовуємо XDG Base Directory Specification
    final xdgDataHome = Platform.environment['XDG_DATA_HOME'] ?? 
                        path.join(homeDir, '.local', 'share');
    
    return path.join(xdgDataHome, 'zzz-mod-manager');
  }
  
  @override
  Future<List<String>> findGameProcesses() async {
    try {
      final result = await Process.run('ps', ['aux']);
      final processes = <String>[];
      
      if (result.exitCode == 0) {
        final lines = result.stdout.toString().split('\n');
        for (final line in lines) {
          if (line.toLowerCase().contains('zenless') || 
              line.toLowerCase().contains('zzz') ||
              line.contains('ZenlessZoneZero.exe')) {
            processes.add(line.trim());
          }
        }
      }
      
      _log.debug('game processes', fields: {'found': processes.length});
      return processes;
    } catch (error, stack) {
      _log.warning('could not list processes', error: error, stack: stack);
      return [];
    }
  }
  
  @override
  String getDisplayServerType() {
    final sessionType = Platform.environment['XDG_SESSION_TYPE'];
    final waylandDisplay = Platform.environment['WAYLAND_DISPLAY'];
    final display = Platform.environment['DISPLAY'];
    
    if (sessionType == 'wayland' || waylandDisplay != null) {
      return 'wayland';
    } else if (display != null) {
      return 'x11';
    }
    
    return 'unknown';
  }
  
  @override
  Future<bool> openUrlInBrowser(String url) async {
    try {
      final uri = Uri.parse(url);
      final canOpen = await canLaunchUrl(uri);
      
      if (canOpen) {
        final result = await launchUrl(
          uri,
          mode: LaunchMode.externalApplication,
        );
        if (result) {
          _log.debug('browser opened', fields: {'via': 'url_launcher'});
          return true;
        }
      }

      final xdgResult = await Process.run('xdg-open', [url]);
      if (xdgResult.exitCode == 0) {
        _log.debug('browser opened', fields: {'via': 'xdg-open'});
        return true;
      }

      _log.warning('could not open browser', fields: {
        'url': url,
        'xdg_exit': xdgResult.exitCode,
      });
      return false;
    } catch (error, stack) {
      _log.warning('could not open browser',
          error: error, stack: stack, fields: {'url': url});
      return false;
    }
  }
  
  @override
  String? getSystemDownloadsPath() {
    try {
      final homeDir = Platform.environment['HOME'];
      if (homeDir == null) return null;
      
      final xdgDownloadDir = Platform.environment['XDG_DOWNLOAD_DIR'];
      if (xdgDownloadDir != null && xdgDownloadDir.isNotEmpty) {
        return xdgDownloadDir;
      }
      
      final downloadsDir = path.join(homeDir, 'Downloads');
      if (Directory(downloadsDir).existsSync()) {
        return downloadsDir;
      }
      
      final ukDownloadsDir = path.join(homeDir, 'Завантаження');
      if (Directory(ukDownloadsDir).existsSync()) {
        return ukDownloadsDir;
      }
      
      return downloadsDir;
    } catch (error, stack) {
      _log.warning('could not resolve the Downloads folder',
          error: error, stack: stack);
      return null;
    }
  }

  @override
  Future<bool> openFolderInFileManager(String folderPath) async {
    try {
      final result = await Process.run('xdg-open', [folderPath]);
      if (result.exitCode == 0) {
        _log.debug('folder opened', fields: {'path': folderPath});
        return true;
      }
      _log.warning('could not open folder', fields: {
        'path': folderPath,
        'exit': result.exitCode,
      });
      return false;
    } catch (error, stack) {
      _log.warning('could not open folder',
          error: error, stack: stack, fields: {'path': folderPath});
      return false;
    }
  }

  @override
  bool get launchesThroughWine => true;

  @override
  Future<List<WineRunner>> findWineRunners() async {
    final home = homeDirectoryPath;
    return home == null ? const [] : wine_runners.findWineRunners(home: home);
  }

  @override
  Future<LaunchResult> launchGame(
    LaunchRequest request, {
    DetachedStarter starter = const DetachedStarter(),
    ProcessProbe probe = const ProcessProbe(),
  }) async {
    final target = request.executable;
    final fields = {
      'target': target,
      'runner': request.runner,
      'prefix': request.prefix,
      'umu': request.useUmu,
      'arguments': request.arguments,
    };
    try {
      final file = File(target);
      if (!await file.exists()) return const LaunchResult(LaunchOutcome.notFound);

      final ext = path.extension(target).toLowerCase();
      final workingDirectory = path.dirname(target);
      final int pid;
      final PrefixServer prefix;
      Future<bool?>? containerDns;
      if (ext == '.exe') {
        if (request.runner.isNotEmpty && !await File(request.runner).exists()) {
          _log.warning('wine runner missing', fields: fields);
          return LaunchResult(LaunchOutcome.runnerMissing, program: request.runner);
        }
        if (WineRunner.isProton(request.runner) && !request.useUmu && request.prefix.isEmpty) {
          _log.warning('proton has no prefix', fields: fields);
          return const LaunchResult(LaunchOutcome.prefixRequired);
        }
        final command = wineCommand(request, home: homeDirectoryPath ?? '');
        try {
          pid = await starter.start(
            command.executable,
            command.arguments,
            workingDirectory: workingDirectory,
            environment: command.environment,
          );
        } on ProcessException catch (error, stack) {
          _log.warning('wine runner missing', error: error, stack: stack, fields: fields);
          return LaunchResult(LaunchOutcome.runnerMissing, program: command.executable);
        }
        // Beside the game, after it has started, so the answer can only add a warning.
        if (WineRunner.isProton(request.runner) && request.useUmu) {
          containerDns = containerDnsWorks(request.runner, probe: probe, environment: _environment);
        }
        prefix = prefixServer(request);
      } else if (_unstartableTypes.contains(ext) || !await _isExecutable(file)) {
        // Windows files are refused by name, since NTFS and exFAT mounts mark every file executable.
        _log.warning('game target not startable', fields: fields);
        return const LaunchResult(LaunchOutcome.unsupported);
      } else {
        // A script the user chose for a setup the runner settings can't express: it gets the arguments as they are.
        pid = await starter.start(target, splitCommandArguments(request.arguments), workingDirectory: workingDirectory);
        prefix = (server: '', environment: const {});
      }
      fields['awake'] = await _keepAwake(starter, pid, prefix, workingDirectory: workingDirectory);
      _log.info('game launched', fields: fields);
      return LaunchResult(LaunchOutcome.started, containerDns: containerDns);
    } catch (error, stack) {
      _log.warning('could not launch game', error: error, stack: stack, fields: fields);
      return const LaunchResult(LaunchOutcome.failed);
    }
  }

  /// The program, arguments and environment that run [request]'s `.exe` under Wine or Proton.
  ///
  /// Proton starts directly the way Heroic starts it with UMU disabled, outside the Steam runtime umu-run wraps it
  /// in, or through umu-run when [LaunchRequest.useUmu] is on. [home] finds Steam for Proton's
  /// `STEAM_COMPAT_CLIENT_INSTALL_PATH`. The exe path goes in as stored, so a link in it reaches XXMI unresolved.
  /// Paths are built in POSIX style whatever the host, since the command is only ever a Linux one.
  /// See `docs/launch-game.md`.
  @visibleForTesting
  static ({String executable, List<String> arguments, Map<String, String> environment}) wineCommand(
    LaunchRequest request, {
    required String home,
  }) {
    final arguments = [request.executable, ...splitCommandArguments(request.arguments)];
    final runner = request.runner;
    if (WineRunner.isProton(runner) && !request.useUmu) {
      return (
        executable: runner,
        arguments: ['waitforexitandrun', ...arguments],
        environment: {
          'STEAM_COMPAT_DATA_PATH': request.prefix,
          'STEAM_COMPAT_CLIENT_INSTALL_PATH': path.posix.join(home, '.steam', 'steam'),
          'STEAM_COMPAT_INSTALL_PATH': path.posix.dirname(request.executable),
          // Proton's protonfixes needs a game id. Without one it reads the digits out of the prefix path, and a
          // path with none, such as Heroic's `Prefixes/HoyoPlay`, stops Proton before anything starts. 0 is the
          // id Heroic passes: no game-specific fixes.
          'SteamAppId': '0',
          'SteamGameId': '0',
        },
      );
    }
    final environment = {if (request.prefix.isNotEmpty) 'WINEPREFIX': request.prefix};
    if (runner.isEmpty) return (executable: 'wine', arguments: arguments, environment: environment);
    if (WineRunner.isProton(runner)) {
      environment['PROTONPATH'] = path.posix.dirname(runner);
      // Picks umu-protonfixes' Zenless Zone Zero fix, which runs the game with the steam.exe its anti-cheat needs.
      environment['GAMEID'] = 'umu-zenlesszonezero';
      return (executable: 'umu-run', arguments: arguments, environment: environment);
    }
    return (executable: runner, arguments: arguments, environment: environment);
  }

  /// The programs that each hold a lock against the screen turning off and the computer going to sleep on its own
  /// while [awakeScript] runs: logind's, GNOME's, and the freedesktop ones Plasma's power manager reads. One that
  /// isn't installed, or whose desktop isn't running, holds nothing. See `docs/launch-game.md`.
  @visibleForTesting
  static const List<List<String>> awakeLocks = [
    ['systemd-inhibit', '--what=idle', '--who=Zenith', '--why=Playing Zenless Zone Zero'],
    ['gnome-session-inhibit', '--app-id', 'Zenith', '--reason', 'Playing Zenless Zone Zero', '--inhibit', 'idle'],
    ['kde-inhibit', '--power', '--screenSaver'],
  ];

  /// Waits for the runner, process `$1`, to exit, then for the prefix's wineserver: `$2`, or the one on PATH when `$2`
  /// isn't an executable file, since any version waits on the same lock. An empty `$2` waits for nothing more.
  @visibleForTesting
  static const String awakeScript =
      r'while kill -0 "$1" 2>/dev/null; do sleep 5; done; [ -z "$2" ] || { [ -x "$2" ] && exec "$2" -w; exec wineserver -w; }';

  /// The wineserver [awakeScript] waits on once the runner has exited, and the prefix it serves. Wine and Proton
  /// started directly return when XXMI does, a few seconds into the game, while the game runs on in the prefix.
  /// umu-run lasts as long as the game, so it has none.
  @visibleForTesting
  static PrefixServer prefixServer(LaunchRequest request) {
    final runner = request.runner;
    if (WineRunner.isProton(runner)) {
      if (request.useUmu) return (server: '', environment: const {});
      return (
        server: path.posix.join(path.posix.dirname(runner), 'files', 'bin', 'wineserver'),
        environment: {'WINEPREFIX': path.posix.join(request.prefix, 'pfx')},
      );
    }
    final environment = {if (request.prefix.isNotEmpty) 'WINEPREFIX': request.prefix};
    if (runner.isEmpty) return (server: 'wineserver', environment: environment);
    return (server: path.posix.join(path.posix.dirname(runner), 'wineserver'), environment: environment);
  }

  /// Starts each of [awakeLocks] beside the game and returns the ones that started. The game is already running, so
  /// nothing here changes the launch's outcome.
  static Future<List<String>> _keepAwake(
    DetachedStarter starter,
    int pid,
    PrefixServer prefix, {
    required String workingDirectory,
  }) async {
    final started = <String>[];
    for (final lock in awakeLocks) {
      try {
        await starter.start(
          lock.first,
          [...lock.skip(1), 'sh', '-c', awakeScript, 'sh', '$pid', prefix.server],
          workingDirectory: workingDirectory,
          environment: prefix.environment,
        );
        started.add(lock.first);
      } on ProcessException {
        // Not installed.
      } catch (error, stack) {
        _log.warning('screen lock not started', error: error, stack: stack, fields: {'program': lock.first});
      }
    }
    return started;
  }

  /// A name the game itself looks up as it starts.
  @visibleForTesting
  static const String containerDnsHost = 'sdk.hoyoverse.com';

  /// Room for a first nameserver that doesn't answer, which glibc waits 5 seconds on for each query.
  @visibleForTesting
  static const Duration containerDnsTimeout = Duration(seconds: 20);

  /// The Steam Linux Runtime folder in umu's data folder for each `require_tool_appid` a Proton build's
  /// `toolmanifest.vdf` can name: umu's own table, `RUNTIME_VERSIONS` in its `umu_runtime.py`.
  @visibleForTesting
  static const Map<String, String> umuRuntimes = {
    '1391110': 'steamrt2',
    '1628350': 'steamrt3',
    '4183110': 'steamrt4',
    '4185400': 'steamrt4-arm64',
  };

  /// The runtime folder the Proton build whose `toolmanifest.vdf` reads [manifest] runs in, or null for none umu knows.
  @visibleForTesting
  static String? umuRuntimeFolder(String manifest) {
    final appid = RegExp(r'"require_tool_appid"\s+"(\d+)"').firstMatch(manifest)?.group(1);
    return appid == null ? null : umuRuntimes[appid];
  }

  /// umu's data folder, picked from [environment] the way umu picks it, or null with no home folder.
  @visibleForTesting
  static String? umuDataPath(Map<String, String> environment) {
    String? nonEmpty(String name) => (environment[name]?.isNotEmpty ?? false) ? environment[name] : null;
    final folders = nonEmpty('UMU_FOLDERS_PATH');
    if (folders != null) return path.posix.join(folders, 'umu');
    final home = nonEmpty('HOME');
    final dataHome =
        environment['container'] == 'flatpak' ? nonEmpty('HOST_XDG_DATA_HOME') : nonEmpty('XDG_DATA_HOME');
    if (dataHome != null) return path.posix.join(dataHome, 'umu');
    return home == null ? null : path.posix.join(home, '.local', 'share', 'umu');
  }

  /// Looks up [containerDnsHost] inside the runtime at [runtimePath], the container umu-run starts Proton in.
  @visibleForTesting
  static ({String executable, List<String> arguments}) containerDnsCommand(String runtimePath) => (
    executable: path.posix.join(runtimePath, '_v2-entry-point'),
    arguments: const ['--verb=waitforexitandrun', '--', 'getent', 'hosts', containerDnsHost],
  );

  /// True when the lookup printed an address; false when getent found no name (exit code 2) or it ran out of time;
  /// null when the container couldn't start or failed some other way.
  @visibleForTesting
  static bool? containerDnsVerdict(ProbeResult? result) {
    if (result == null) return null;
    if (result.timedOut) return false;
    if (result.exitCode == 0 && result.stdout.trim().isNotEmpty) return true;
    if (result.exitCode == 2) return false;
    return null;
  }

  /// Whether a name can be looked up inside the container umu-run starts the Proton script [proton] in. Null, with
  /// no check, for a build umu runs without a known runtime or one not downloaded yet. Never throws. See
  /// `docs/launch-game.md`.
  @visibleForTesting
  static Future<bool?> containerDnsWorks(
    String proton, {
    required ProcessProbe probe,
    required Map<String, String> environment,
  }) async {
    try {
      final manifest = File(path.join(path.dirname(proton), 'toolmanifest.vdf'));
      final runtime = await manifest.exists() ? umuRuntimeFolder(await manifest.readAsString()) : null;
      final data = umuDataPath(environment);
      if (runtime == null || data == null) {
        _log.info('container dns check skipped', fields: {'reason': 'no runtime', 'manifest': manifest.path});
        return null;
      }
      final command = containerDnsCommand(path.join(data, runtime));
      if (!await File(command.executable).exists()) {
        _log.info('container dns check skipped', fields: {'reason': 'runtime missing', 'entry_point': command.executable});
        return null;
      }
      final result = await probe.run(command.executable, command.arguments, timeout: containerDnsTimeout);
      final verdict = containerDnsVerdict(result);
      final fields = {
        'runtime': runtime,
        'exit': result?.exitCode,
        'timed_out': result?.timedOut,
        if (verdict == null) 'stderr': result?.stderr.trim(),
      };
      switch (verdict) {
        case true:
          _log.info('container dns works', fields: fields);
        case false:
          _log.warning('container dns failed', fields: fields);
        case null:
          _log.warning('container dns check gave no verdict', fields: fields);
      }
      return verdict;
    } catch (error, stack) {
      _log.warning('container dns check gave no verdict', error: error, stack: stack, fields: {'proton': proton});
      return null;
    }
  }

  /// Files Linux can't start: Windows types, and a `.desktop` shortcut, which can't take arguments.
  static const Set<String> _unstartableTypes = {'.bat', '.cmd', '.lnk', '.msi', '.desktop'};

  static Future<bool> _isExecutable(File file) async {
    final mode = (await file.stat()).mode;
    // Any of the owner, group or other execute bits.
    return mode & 0x49 != 0;
  }

  /// Channel backed by the GTK clipboard reader in the Linux runner
  /// (`linux/runner/my_application.cc`).
  static const MethodChannel _clipboardChannel =
      MethodChannel('mod_manager/clipboard');

  /// `7zzs` is 7-Zip's **statically linked** Linux build and what the portable
  /// tarball ships — the target distro's libstdc++ is unknown, and a dynamic
  /// binary is what breaks on the older ones a portable build exists to serve.
  /// `7zz` is the same thing dynamically linked. `7za` is deliberately absent:
  /// it is the reduced-format build and cannot read RAR.
  @override
  List<String> get bundledSevenZipNames => const ['7zzs', '7zz'];

  /// Distro from `/etc/os-release`, display server from the environment, and a
  /// version out of each tool that will give one.
  ///
  /// The kernel costs nothing: `Platform.operatingSystemVersion` on Linux is
  /// already the full `uname` string, so no process is spawned for it.
  @override
  Future<SystemReport> describeSystem({
    ProcessProbe probe = const ProcessProbe(),
  }) async {
    String? distro;
    String? distroId;
    try {
      final release = File('/etc/os-release');
      if (await release.exists()) {
        final fields = parseOsRelease(await release.readAsString());
        distro = fields['PRETTY_NAME'] ?? fields['NAME'];
        distroId = fields['ID'];
      }
    } catch (_) {
      // A distro that does not ship the file, or one we cannot read. The rest
      // of the header is still worth having.
    }

    return SystemReport(
      os: OsDescription(
        name: Platform.operatingSystem,
        version: Platform.operatingSystemVersion,
        distro: distro,
        distroId: distroId,
        displayServer: getDisplayServerType(),
        desktop: Platform.environment['XDG_CURRENT_DESKTOP'],
      ),
      tools: [
        await _describeTool('7-zip', const ['7z', '7za', '7zr'], probe,
            versionArguments: const []),
        // 7-Zip alone: it is the only external tool the app runs. `xdotool`,
        // `ydotool` and `wmctrl` were probed for years for a mod-reload feature
        // that no longer exists, which put `missing` warnings in every log that
        // read like a cause and were not one.
      ],
    );
  }

  /// Looks for each of [commands] on `PATH`, then asks the first one it finds
  /// for a version.
  ///
  /// `7z` with no arguments prints its banner and **exits non-zero** on some
  /// builds, so the exit code is ignored and only the output is read — the
  /// question here is "what version", and a tool that answered it has answered
  /// it whatever it then returned.
  Future<ToolStatus> _describeTool(
    String name,
    List<String> commands,
    ProcessProbe probe, {
    List<String> versionArguments = const ['--version'],
  }) async {
    for (final command in commands) {
      final located = await probe.run('which', [command]);
      final path = located?.stdout.trim();
      if (located == null || located.exitCode != 0 || path == null || path.isEmpty) {
        continue;
      }
      final version = await probe.run(path, versionArguments);
      return ToolStatus(
        name: name,
        state: ToolState.present,
        path: path.split('\n').first.trim(),
        version: version == null ? null : parseVersionToken(version.output),
        note: 'system',
      );
    }
    return ToolStatus.missing(name);
  }

  /// `USER`, falling back to `LOGNAME` — the second is what a login shell sets
  /// and the first is what most desktop sessions set; a container or a systemd
  /// unit may set neither, hence nullable.
  @override
  String? get osUserName =>
      Platform.environment['USER'] ?? Platform.environment['LOGNAME'];

  @override
  String? get homeDirectoryPath => Platform.environment['HOME'];

  @override
  Future<String?> getClipboardHtml() async {
    // Read the clipboard's text/html target straight from the GTK clipboard
    // (the same way native apps do) — no external CLI tool required.
    try {
      final html =
          await _clipboardChannel.invokeMethod<String>('getClipboardHtml');
      if (html != null && html.trim().isNotEmpty) return html;
    } catch (error) {
      // Paste-as-markdown falls back to plain text; not worth a stack.
      _log.debug('no HTML on the clipboard', fields: {'reason': '$error'});
    }
    return null;
  }

  /// `df -kP`, which every Linux carries: GNU coreutils, busybox and toybox all
  /// implement the POSIX flags, where `--output=avail` is coreutils-only.
  @override
  Future<int?> freeSpaceBytes(
    String forPath, {
    ProcessProbe probe = const ProcessProbe(),
  }) async {
    final result = await probe.run('df', ['-kP', forPath]);
    if (result == null || result.timedOut || result.exitCode != 0) return null;
    // Two lines for one path, so this cannot happen — and a cut listing would
    // answer with some other volume's free space, which is worth one check.
    if (result.truncated) return null;
    return parseDfAvailableBytes(result.stdout);
  }
}
