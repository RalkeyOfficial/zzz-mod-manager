import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as path;
import 'package:url_launcher/url_launcher.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:win32/win32.dart' show SW_SHOWNORMAL, ShellExecute;
import '../utils/detached_starter.dart';
import '../utils/process_probe.dart';
import 'log/logger.dart';
import 'log/system_report.dart';
import 'platform_service.dart';
import 'windows/windows_links.dart';
import 'windows/windows_paths.dart';

/// Windows-специфічна реалізація PlatformService
/// The same two tags the Linux implementation uses, and the same event names
/// under them — so a Windows bug report and a Linux one are filtered the same
/// way, and only the `kind`/`tool` fields differ.
final Logger _log = Logger('platform');
final Logger _files = Logger('fileops');

/// [PlatformService.listDeadModLinks] on Windows, with each target read by [readTarget]. Dart reports every reparse
/// point, a junction as much as a symlink, as a [Link] in a listing that doesn't follow links, so a candidate is an
/// entry that lists as one, as on Linux.
Future<List<DeadModLink>> readWindowsDeadModLinks(
  String linksFolder, {
  required Future<String?> Function(String linkPath) readTarget,
}) =>
    readDeadModLinks(linksFolder, isLinkEntry: (entry) async => entry is Link, readTarget: readTarget);

class WindowsPlatformService implements PlatformService {
  /// [calls] is the seam a test replaces the Win32 calls through.
  WindowsPlatformService({WindowsLinkCalls calls = const WindowsLinkCalls()}) : _calls = calls;

  final WindowsLinkCalls _calls;

  @override
  Future<bool> createModLink(String sourcePath, String linkPath) async {
    // A link already of that name, live or dead, goes through the replace, which puts it back when the new one
    // can't be made.
    if (await isModLink(linkPath)) return replaceModLink(linkPath, sourcePath);
    try {
      // An empty folder in the way is removed; removeModLink refuses one with anything in it.
      if (await Directory(linkPath).exists() || await File(linkPath).exists()) {
        await removeModLink(linkPath);
      }

      final kind = await _makeLink(sourcePath, linkPath);
      _files.info('link created', fields: {
        'kind': kind,
        'link': linkPath,
        'target': sourcePath,
      });
      return true;
    } catch (error, stack) {
      _files.error('link failed', error: error, stack: stack, fields: {
        'link': linkPath,
        'target': sourcePath,
      });
      if (error is NetworkLinkRefused) rethrow;
      return false;
    }
  }

  /// Makes the link as a directory symlink, or as a junction where a symlink is refused for want of rights, and
  /// returns which. Throws when neither could be made, with the symlink's own error when it failed for another
  /// reason, which a junction would only hide.
  Future<String> _makeLink(String sourcePath, String linkPath) async {
    final target = _absolute(sourcePath);
    try {
      _calls.createDirectorySymlink(linkPath, _symlinkTarget(target));
      return 'symlink';
    } on FileSystemException catch (error) {
      if (error.osError?.errorCode != errorPrivilegeNotHeld) rethrow;
      // Expected without Developer Mode or admin rights, and the reason the
      // junction below exists — a warning rather than an error, because the
      // operation has not failed yet.
      _files.warning('symlink refused, falling back to a junction',
          error: error, fields: {'link': linkPath});
    }

    _makeJunction(linkPath, target);
    return 'junction';
  }

  /// [target] with a mapped network drive's letter replaced by the share it is mapped to, since the game, started
  /// elevated through the launcher, may not see the user's drive letters. Kept as it is when the share can't be
  /// read, which is logged.
  String _symlinkTarget(String target) {
    final root = driveRootOf(target);
    if (root == null || !_calls.isOnNetworkDrive(target)) return target;
    final remote = _calls.networkPathOf(root);
    if (remote == null) {
      _files.warning('mapped drive not read, linking by its letter', fields: {'target': target});
      return target;
    }
    return withNetworkRoot(target, remote);
  }

  /// [path] with a mapped network drive's letter replaced by its share, as [_symlinkTarget] makes it, so a link made
  /// to the share and a library path that uses the letter compare as one.
  String _comparable(String path) {
    final root = driveRootOf(path);
    if (root == null) return path;
    try {
      if (!_calls.isOnNetworkDrive(path)) return path;
      final remote = _calls.networkPathOf(root);
      return remote == null ? path : withNetworkRoot(path, remote);
    } catch (_) {
      return path;
    }
  }

  /// A junction needs no rights beyond writing the folder, but leads only to a local folder: one made to a network
  /// folder is dead, so that is refused with nothing made ([NetworkLinkRefused]). Throws when it can't be made.
  void _makeJunction(String linkPath, String target) {
    if (isUncPath(target) || _calls.isOnNetworkDrive(target)) throw NetworkLinkRefused(linkPath, target);
    _calls.createJunction(linkPath, target);
  }

  /// [target] as an absolute normalised Windows path.
  String _absolute(String target) =>
      path.windows.normalize(path.windows.isAbsolute(target) ? target : path.absolute(target));

  /// Made under a temporary name beside the old link first ([replacementLinkName], as on Linux), so a new link that
  /// can't be made leaves the old one untouched. A link can't be renamed over another on Windows, so the old one is
  /// then renamed aside ([asideLinkName]), the new one into its name, and the old one deleted; a rename that fails puts the old one back by
  /// renaming it, never by making it again. A new link refused for leading to a network folder throws
  /// [NetworkLinkRefused]. Not yet run on Windows.
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
    final fields = {'link': linkPath, 'from': previous, 'target': newTarget};
    final folder = path.windows.dirname(linkPath);
    final name = path.windows.basename(linkPath);
    final fresh = path.windows.join(folder, replacementLinkName(name));
    final aside = path.windows.join(folder, asideLinkName(name));

    final String kind;
    try {
      // Left by a replace that stopped partway. Only these exact names, and only links.
      await _clearTemporary(fresh);
      await _clearTemporary(aside);
      kind = await _makeLink(newTarget, fresh);
    } catch (error, stack) {
      _files.error('link replace failed', error: error, stack: stack, fields: fields);
      if (error is NetworkLinkRefused) rethrow;
      return false;
    }

    try {
      await _calls.renameLink(linkPath, aside);
    } catch (error, stack) {
      _files.error('link replace failed', error: error, stack: stack, fields: fields);
      await _clearTemporary(fresh);
      return false;
    }
    try {
      await _calls.renameLink(fresh, linkPath);
    } catch (error, stack) {
      _files.error('link replace failed', error: error, stack: stack, fields: fields);
      try {
        await _calls.renameLink(aside, linkPath);
        _files.info('link restored', fields: {'link': linkPath, 'target': previous});
      } catch (error, stack) {
        // The old link is kept under the temporary name beside it, and the mod it points at reads off.
        _files.error('link restore failed', error: error, stack: stack, fields: {'link': linkPath, 'kept': aside});
      }
      await _clearTemporary(fresh);
      return false;
    }
    await _clearTemporary(aside);
    _files.info('link replaced', fields: {'kind': kind, ...fields});
    return true;
  }

  /// Removes the link at [linkPath], a temporary name of [replaceModLink], when there is one. Logs what it can't
  /// remove and never throws.
  Future<void> _clearTemporary(String linkPath) async {
    try {
      if (await _calls.isLink(linkPath)) await _calls.deleteLink(linkPath);
    } catch (error) {
      _files.warning('temporary link left behind', error: error, fields: {'path': linkPath});
    }
  }

  @override
  Future<bool> removeModLink(String linkPath) async {
    try {
      // Перевіряємо чи це link/junction
      final isLink = await isModLink(linkPath);
      if (!isLink) {
        // Можливо це звичайна директорія, видаляємо її
        final dir = Directory(linkPath);
        if (await dir.exists()) {
          // Non-recursive on purpose: this succeeds only for an empty
          // directory, so a real mod folder mistaken for a link is refused by
          // the filesystem rather than deleted.
          await dir.delete(recursive: false);
          _files.info('empty directory removed', fields: {'path': linkPath});
          return true;
        }
        return false;
      }

      // Для junction/symlink використовуємо Link
      final link = Link(linkPath);
      if (await link.exists()) {
        final target = await readModLinkTarget(linkPath);
        await _calls.deleteLink(linkPath);
        _files.info('link removed', fields: {'link': linkPath, 'target': target});
        return true;
      }

      return false;
    } catch (error, stack) {
      _files.error('link removal failed',
          error: error, stack: stack, fields: {'link': linkPath});
      return false;
    }
  }
  
  /// Not yet run on Windows.
  @override
  Future<List<DeadModLink>> listDeadModLinks(String linksFolder) =>
      readWindowsDeadModLinks(linksFolder, readTarget: readModLinkTarget);

  /// Not yet run on Windows.
  @override
  Future<String?> readModLinkTarget(String linkPath) async {
    try {
      if (!await isModLink(linkPath)) return null;
      return windowsLinkTarget(await _calls.readTarget(linkPath), path.windows.dirname(linkPath));
    } catch (_) {
      return null;
    }
  }

  /// NTFS ignores case, so two spellings of one folder are the same path, and so are a mapped drive's letter and its
  /// share.
  @override
  bool samePath(String a, String b) =>
      pathsEqual(_comparable(a), _comparable(b), ignoreCase: true, context: path.windows);

  @override
  Future<bool> isModLink(String linkPath) async {
    try {
      return await _calls.isLink(linkPath);
    } catch (e) {
      return false;
    }
  }
  
  @override
  String getAppDataPath() {
    final appData = Platform.environment['APPDATA'];
    if (appData == null) {
      // Fallback на USERPROFILE\AppData\Roaming
      final userProfile = Platform.environment['USERPROFILE'];
      if (userProfile == null) {
        throw Exception('APPDATA and USERPROFILE environment variables not found');
      }
      return path.join(userProfile, 'AppData', 'Roaming', 'zzz-mod-manager');
    }
    
    return path.join(appData, 'zzz-mod-manager');
  }
  
  @override
  Future<List<String>> findGameProcesses() async {
    try {
      // Використовуємо tasklist для пошуку процесів
      final result = await Process.run('tasklist', ['/FI', 'IMAGENAME eq ZenlessZoneZero.exe']);
      final processes = <String>[];
      
      if (result.exitCode == 0) {
        final lines = result.stdout.toString().split('\n');
        for (final line in lines) {
          if (line.toLowerCase().contains('zenless') || 
              line.toLowerCase().contains('zzz')) {
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
    // Windows завжди використовує DWM (Desktop Window Manager)
    return 'windows-dwm';
  }
  
  @override
  Future<bool> openUrlInBrowser(String url) async {
    try {
      final uri = Uri.parse(url);
      final result = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (result) {
        _log.debug('browser opened', fields: {'via': 'url_launcher'});
        return true;
      }

      _log.warning('could not open browser', fields: {'url': url});
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
      final userProfile = Platform.environment['USERPROFILE'];
      if (userProfile == null) return null;
      
      return path.join(userProfile, 'Downloads');
    } catch (error, stack) {
      _log.warning('could not resolve the Downloads folder',
          error: error, stack: stack);
      return null;
    }
  }

  @override
  Future<bool> openFolderInFileManager(String folderPath) async {
    try {
      // ShellExecute hands the path over as it is: explorer.exe given it as an argument reads a comma in it as a
      // separator, and may open another folder. Anything at or below 32 is an error code.
      final result = using((arena) => ShellExecute(
            0,
            'open'.toNativeUtf16(allocator: arena),
            folderPath.toNativeUtf16(allocator: arena),
            nullptr,
            nullptr,
            SW_SHOWNORMAL,
          ));
      if (result <= 32) {
        _log.warning('could not open folder', fields: {'path': folderPath, 'code': result});
        return false;
      }
      _log.debug('folder opened', fields: {'path': folderPath});
      return true;
    } catch (error, stack) {
      _log.warning('could not open folder',
          error: error, stack: stack, fields: {'path': folderPath});
      return false;
    }
  }

  @override
  bool get launchesThroughWine => false;

  @override
  Future<List<WineRunner>> findWineRunners() async => const [];

  @override
  Future<LaunchResult> launchGame(LaunchRequest request, {DetachedStarter starter = const DetachedStarter()}) async {
    final target = request.executable;
    final fields = {'target': target, 'arguments': request.arguments};
    Pointer<Utf16>? file;
    Pointer<Utf16>? parameters;
    Pointer<Utf16>? directory;
    try {
      if (!await File(target).exists()) return const LaunchResult(LaunchOutcome.notFound);
      // ShellExecute is what a double-click does, so the XXMI Launcher's UAC prompt shows, and a .lnk shortcut and a
      // .bat work too. The path is handed over as it is, with no command line to read `&` or `%` in it.
      final shell32 = DynamicLibrary.open('shell32.dll');
      final shellExecuteW = shell32.lookupFunction<
          IntPtr Function(IntPtr, Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>, Int32),
          int Function(int, Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>, int)>('ShellExecuteW');

      file = target.toNativeUtf16();
      final arguments = request.arguments.trim();
      if (arguments.isNotEmpty) parameters = arguments.toNativeUtf16();
      directory = path.dirname(target).toNativeUtf16();
      const showNormal = 1;
      // A null verb is the file's default action. Anything at or below 32 is an error code.
      final result = shellExecuteW(0, nullptr, file, parameters ?? nullptr, directory, showNormal);
      if (result <= 32) {
        _log.warning('could not launch game', fields: {...fields, 'code': result});
        return const LaunchResult(LaunchOutcome.failed);
      }
      _log.info('game launched', fields: fields);
      return const LaunchResult(LaunchOutcome.started);
    } catch (error, stack) {
      _log.warning('could not launch game', error: error, stack: stack, fields: fields);
      return const LaunchResult(LaunchOutcome.failed);
    } finally {
      if (file != null) malloc.free(file);
      if (parameters != null) malloc.free(parameters);
      if (directory != null) malloc.free(directory);
    }
  }

  /// **`7z.exe`, which needs `7z.dll` beside it** — deliberately not `7za.exe`.
  /// 7-Zip's own readme calls that one "reduced formats support", and the
  /// formats it drops include RAR, which is the whole reason for bundling
  /// anything. `7zz.exe` is the newer single-file equivalent if it ever ships.
  @override
  List<String> get bundledSevenZipNames => const ['7z.exe', '7zz.exe'];

  /// Windows has no distro and no display server, so those fields are absent
  /// rather than empty.
  @override
  Future<SystemReport> describeSystem({
    ProcessProbe probe = const ProcessProbe(),
  }) async {
    return SystemReport(
      os: OsDescription(
        name: Platform.operatingSystem,
        // Already the build string on Windows; no `wmic`, no `systeminfo`.
        version: Platform.operatingSystemVersion,
        displayServer: getDisplayServerType(),
      ),
      tools: [await _describeSevenZip(probe)],
    );
  }

  /// `where 7z` first, then the install locations the extractor already knows
  /// about, so the header agrees with what an extraction would actually use.
  Future<ToolStatus> _describeSevenZip(ProcessProbe probe) async {
    String? found;
    final located = await probe.run('where', ['7z']);
    if (located != null && located.exitCode == 0) {
      final first = located.stdout
          .split(RegExp(r'[\r\n]+'))
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty);
      if (first.isNotEmpty) found = first.first;
    }

    found ??= await _firstExisting([
      for (final root in [
        Platform.environment['ProgramFiles'],
        Platform.environment['ProgramFiles(x86)'],
      ])
        if (root != null && root.isNotEmpty) '$root\\7-Zip\\7z.exe',
    ]);

    if (found == null) return const ToolStatus.missing('7-zip');

    // No arguments: `7z` prints its banner and may exit non-zero doing it.
    final version = await probe.run(found, const []);
    return ToolStatus(
      name: '7-zip',
      state: ToolState.present,
      path: found,
      version: version == null ? null : parseVersionToken(version.output),
      note: 'system',
    );
  }

  Future<String?> _firstExisting(List<String> candidates) async {
    for (final candidate in candidates) {
      try {
        if (await File(candidate).exists()) return candidate;
      } catch (_) {
        // An unreadable drive is not a reason to fail a header.
      }
    }
    return null;
  }

  @override
  String? get osUserName => Platform.environment['USERNAME'];

  /// `USERPROFILE` — `C:\Users\<name>`, the prefix of both the library paths a
  /// user picks and `%APPDATA%`, which is why censoring it covers nearly every
  /// path that reaches a log line.
  @override
  String? get homeDirectoryPath => Platform.environment['USERPROFILE'];

  @override
  Future<String?> getClipboardHtml() async {
    try {
      final raw = await Pasteboard.html;
      if (raw == null || raw.isEmpty) return null;
      return _extractCfHtmlFragment(raw);
    } catch (error) {
      // Paste-as-markdown falls back to plain text; not worth a stack.
      _log.debug('no HTML on the clipboard', fields: {'reason': '$error'});
      return null;
    }
  }

  /// The Windows "HTML Format" clipboard payload wraps the markup in a header
  /// (Version/StartHTML/StartFragment/…). Return just the fragment markup so
  /// the HTML→markdown converter doesn't choke on the header lines.
  String? _extractCfHtmlFragment(String cfHtml) {
    const startMarker = '<!--StartFragment-->';
    const endMarker = '<!--EndFragment-->';
    final start = cfHtml.indexOf(startMarker);
    final end = cfHtml.indexOf(endMarker);
    if (start != -1 && end != -1 && end > start) {
      final frag = cfHtml.substring(start + startMarker.length, end).trim();
      if (frag.isNotEmpty) return frag;
    }
    // No fragment markers — drop the header by starting at the first tag.
    final firstTag = cfHtml.indexOf('<');
    if (firstTag != -1) {
      final body = cfHtml.substring(firstTag).trim();
      if (body.isNotEmpty) return body;
    }
    return null;
  }

  /// `GetDiskFreeSpaceExW`, through FFI rather than a process.
  ///
  /// **There is no `df` on Windows and no supported command that answers this.**
  /// `wmic` is removed from current Windows, and `dir` prints the number as
  /// localized prose that a parser would have to read in whatever language the
  /// user's console is set to. PowerShell would answer, at half a second of
  /// process startup per question — paid before every download in a queue.
  ///
  /// The **first** out-parameter is the one to read: free bytes *available to
  /// the caller*, which is what a disk quota reduces and what the write will
  /// actually be allowed to use. `lpTotalNumberOfFreeBytes` ignores quotas and
  /// would promise room that a write cannot have.
  ///
  /// Any failure is null, including a path that does not exist yet.
  @override
  Future<int?> freeSpaceBytes(
    String forPath, {
    ProcessProbe probe = const ProcessProbe(),
  }) async {
    Pointer<Utf16>? directory;
    Pointer<Uint64>? free;
    try {
      final kernel32 = DynamicLibrary.open('kernel32.dll');
      final getDiskFreeSpaceExW = kernel32.lookupFunction<
          Int32 Function(Pointer<Utf16>, Pointer<Uint64>, Pointer<Uint64>,
              Pointer<Uint64>),
          int Function(Pointer<Utf16>, Pointer<Uint64>, Pointer<Uint64>,
              Pointer<Uint64>)>('GetDiskFreeSpaceExW');

      directory = forPath.toNativeUtf16();
      free = calloc<Uint64>();
      final ok = getDiskFreeSpaceExW(directory, free, nullptr, nullptr);
      if (ok == 0) return null;
      return free.value;
    } catch (error) {
      _log.debug('could not read free space', fields: {'reason': '$error'});
      return null;
    } finally {
      if (directory != null) calloc.free(directory);
      if (free != null) calloc.free(free);
    }
  }
}
