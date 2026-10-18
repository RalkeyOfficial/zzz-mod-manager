import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/services/platform_service.dart';
import 'package:mod_manager_flutter/services/platform_service_linux.dart';

/// The command Linux builds to run the XXMI Launcher under Wine or Proton. Pure, so it runs on any OS.
void main() {
  const exe = '/mnt/Game/XXMI Launcher/Resources/Bin/XXMI Launcher.exe';
  const arguments = '--nogui --xxmi ZZMI';
  const proton = '/steam/compatibilitytools.d/dwproton-11.0-5/proton';
  const home = '/home/al';

  ({String executable, List<String> arguments, Map<String, String> environment}) command(LaunchRequest request) =>
      LinuxPlatformService.wineCommand(request, home: home);

  test('with no runner chosen, wine from PATH runs the launcher', () {
    final wine = command(const LaunchRequest(executable: exe, arguments: arguments));
    expect(wine.executable, 'wine');
    expect(wine.arguments, [exe, '--nogui', '--xxmi', 'ZZMI']);
    expect(wine.environment, isEmpty);
  });

  test('a proton file starts directly, the way Heroic starts it with UMU disabled', () {
    final direct = command(
      const LaunchRequest(executable: exe, arguments: arguments, runner: proton, prefix: '/prefixes/HoyoPlay'),
    );
    expect(direct.executable, proton);
    expect(direct.arguments, ['waitforexitandrun', exe, '--nogui', '--xxmi', 'ZZMI']);
    expect(direct.environment, {
      'STEAM_COMPAT_DATA_PATH': '/prefixes/HoyoPlay',
      'STEAM_COMPAT_CLIENT_INSTALL_PATH': '/home/al/.steam/steam',
      'STEAM_COMPAT_INSTALL_PATH': '/mnt/Game/XXMI Launcher/Resources/Bin',
      // Without a game id protonfixes reads digits out of the prefix path, and `HoyoPlay` has none.
      'SteamAppId': '0',
      'SteamGameId': '0',
    });
  });

  test('with umu-launcher on, a proton file runs through umu-run with its folder as PROTONPATH', () {
    final umu = command(
      const LaunchRequest(
        executable: exe,
        arguments: arguments,
        runner: proton,
        prefix: '/prefixes/HoyoPlay',
        useUmu: true,
      ),
    );
    expect(umu.executable, 'umu-run');
    expect(umu.arguments, [exe, '--nogui', '--xxmi', 'ZZMI']);
    expect(umu.environment, {
      'WINEPREFIX': '/prefixes/HoyoPlay',
      'PROTONPATH': '/steam/compatibilitytools.d/dwproton-11.0-5',
      'GAMEID': 'umu-zenlesszonezero',
    });
  });

  test('any other runner file is a wine binary, given the prefix', () {
    final wine = command(
      const LaunchRequest(executable: exe, arguments: '', runner: '/opt/wine-ge/bin/wine64', prefix: '/prefixes/zzz'),
    );
    expect(wine.executable, '/opt/wine-ge/bin/wine64');
    expect(wine.arguments, [exe]);
    expect(wine.environment, {'WINEPREFIX': '/prefixes/zzz'});
  });

  test('the exe path stays one argument, spaces and links as written', () {
    const linked = '/mnt/Game/XXMI Launcher/../XXMI Launcher/Resources/Bin/XXMI Launcher.exe';
    final wine = command(const LaunchRequest(executable: linked, arguments: '"a b"'));
    expect(wine.arguments, [linked, 'a b']);
  });
}
