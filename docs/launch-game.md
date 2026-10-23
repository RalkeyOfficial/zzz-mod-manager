# Launch game

The sidebar's **Launch game** button starts the game through the XXMI Launcher, so a user who has just turned mods on doesn't have to find the launcher themselves. It sits in the ZZMI card, under the reminder to press F10 after changes. The app never presses F10 itself ([`mod-reload.md`](mod-reload.md)).

## What it starts

The XXMI Launcher, never the game's own exe. XXMI is what injects ZZMI into the game, so a game started any other way runs without mods.

The launcher sits next to ZZMI in every XXMI install: `<XXMI>/ZZMI` is the ZZMI folder and `<XXMI>/Resources/Bin/XXMI Launcher.exe` is the launcher. So with nothing chosen, the button starts the `XXMI Launcher.exe` beside the configured ZZMI folder (`xxmiLauncherBeside` in `services/shader_fixes/zzmi_layout.dart`). The folder names are matched in exact case, since XXMI's own installer writes them.

**Settings › Launch game with** shows the file that will start and can choose another, stored as `launch_target` ([`configuration.md`](configuration.md)). Reset clears it and goes back to the launcher beside ZZMI. A chosen file that has gone is reported as gone; the button never falls back to the other one behind the user's back.

A chosen path is kept exactly as picked: never resolved through a symlink and never normalised. XXMI finds its config and its importer folders from the path it was started with, and a setup that runs XXMI through a link inside the game folder depends on that path reaching it unchanged.

The first press, with nothing chosen and no launcher beside ZZMI, opens a file picker. The answer is saved and the game starts at once, so choosing is part of launching rather than a separate trip to Settings.

The app doesn't look for Heroic, Lutris, Steam or Bottles entries, and doesn't read the game folder from XXMI's config. Each of those would be a second copy of a setup the user already has, and every one of them ends in the same call: XXMI's exe with its arguments, in the game's Wine prefix. The app makes that call itself.

## Arguments

**Launch arguments** in Settings is one free text field, stored as `launch_arguments`. With the key absent it reads as `--nogui --xxmi ZZMI` (`AppConstants.defaultLaunchArguments`), so a user who never edited it follows any later change to the default. Reset removes the key.

- `--nogui` starts the game without XXMI's window, and XXMI exits a few seconds after the game is running.
- `--xxmi ZZMI` picks the Zenless Zone Zero importer. XXMI also saves it as its active importer.
- An empty field is kept as empty and opens XXMI's own window, from which the user starts the game.
- An argument XXMI doesn't know is passed on to the game.
- XXMI exits with code 0 whatever happened, so its exit code says nothing and is never waited on.
- An XXMI update that is due shows XXMI's own dialog before the game starts. That is XXMI's flow and the app stays out of it.

The field saves on Enter or when it loses focus. The value on screen is what the button uses, even before it is saved.

## Windows

The launcher is started with `ShellExecuteW`, with the arguments in `lpParameters` and the exe's own folder as the working directory. That is what a double-click does, which matters here:

- XXMI's manifest asks for administrator rights, so `Process.start` (CreateProcess) fails with error 740. `ShellExecuteW` shows the UAC prompt instead.
- The path is handed over as it is. A command line through `cmd /c start` would read `&`, `^` and `%` in a folder name such as `R&D`.

Windows refuses nothing by type: a `.lnk` or a `.bat` the user chose starts the way a double-click starts it, with the arguments passed along.

## Linux

XXMI is a Windows program, so the app runs it under Wine or Proton. XXMI starts the game inside its own prefix, so that has to be the prefix the game is installed and set up in. These settings say how, all shown only where `PlatformService.launchesThroughWine` is true:

- **Wine or Proton** (`wine_runner`): a menu of the builds on the machine, named the way Steam, Heroic and Lutris name them (`dwproton-11.0-5`), since people remember which version they use and not where it lives. System Wine is first and **Other file…** is last, for a build in a place the list doesn't look. Typing filters it. What is stored is the build's file, whose name says which kind it is.
- **Run Proton through umu-launcher** (`wine_use_umu`): shown for a Proton runner, on by default.
- **Wine prefix** (`wine_prefix`): a folder. Empty means the runner's own default prefix. Settings warns, without refusing, when the folder holds neither `drive_c` nor `pfx/drive_c`: a wrong prefix starts XXMI in a fresh Wine install where the game isn't, and nothing else would say so. For Wine, it also warns about a Proton prefix folder, with `drive_c` only under a real `pfx/`: Wine would build a new prefix at the top of the folder, so the prefix to choose is that `pfx` folder. The folder is checked again each time Settings opens, so a prefix a runner has filled since loses its warning.

| Runner setting | Program started | Arguments before the exe | Environment added |
|---|---|---|---|
| empty | `wine`, from PATH | | `WINEPREFIX` when a prefix is set |
| a file named `proton`, umu off | that `proton` script | `waitforexitandrun` | `STEAM_COMPAT_DATA_PATH` (the prefix), `STEAM_COMPAT_CLIENT_INSTALL_PATH=~/.steam/steam`, `STEAM_COMPAT_INSTALL_PATH` (the exe's folder), `SteamAppId=0` and `SteamGameId=0` |
| a file named `proton`, umu on | `umu-run` | | `PROTONPATH` (the folder holding `proton`), `GAMEID=umu-zenlesszonezero`, `WINEPREFIX` when set |
| any other file | that file, as a wine binary | | `WINEPREFIX` when set |

The menu is filled by `findWineRunners` (`services/wine_runners.dart`), looked for again each time Settings opens:

| Kind | Where | Source shown |
|---|---|---|
| Proton (`<build>/proton`) | `compatibilitytools.d` in `~/.local/share/Steam`, `~/.steam/root`, `~/.steam/steam` and Flatpak Steam's data folder | Steam |
| Proton | `steamapps/common/Proton*` in every library `libraryfolders.vdf` lists | Steam |
| Proton | `/usr/share/steam/compatibilitytools.d`, where distro packages install it | System |
| Proton | `~/.config/heroic/tools/proton` and Flatpak Heroic's | Heroic |
| Proton | `~/.local/share/lutris/runners/proton` | Lutris |
| Wine (`<build>/bin/wine`) | `~/.config/heroic/tools/wine` and Flatpak Heroic's, `~/.local/share/lutris/runners/wine`, `~/.local/share/bottles/runners` | Heroic, Lutris, Bottles |

Flatpak Heroic downloads the same release builds as native Heroic, and they run on the host. The runners of Bottles from Flathub are left out: they rely on libraries the Bottles runtime supplies, so they may not run on a bare host. A build reached by two paths, as `~/.steam/root` usually links to `~/.local/share/Steam`, is listed once. The list is Proton first, then Wine, each in name order with version numbers compared as numbers. A stored runner the scan didn't find is still listed, named by its build folder.

The arguments are always `["<exe>", ...the launch arguments]`, the working directory is the exe's own folder (`Resources/Bin`, as XXMI's own shortcut uses), and the app's environment is inherited.

Proton runs through umu-run by default. umu-run starts it inside the Steam Linux Runtime container its build asks for, sniper for Proton 10 and steamrt4 for Proton 11, so the game gets the libraries the build is made for rather than the system's. That is how Steam runs Proton, what Heroic and Lutris do by default, and the only setup GE-Proton supports.

The game id umu-run is given, `umu-zenlesszonezero`, is what lets the game start. Under umu, GE-Proton and the builds based on it start the game through `umu.exe` instead of Proton's `steam.exe`, and the game's anti-cheat (`mhypbase`) crashes on that a second after starting, with XXMI's hooks already in place. The id makes umu-protonfixes apply its fix for the game: `UMU_USE_STEAM=1`, which goes back to `steam.exe`, along with `WINE_DISABLE_VULKAN_OPWR=1` and the game's drive. With it the game runs with mods. The fix ships in GE-Proton 10, dwproton, Proton-CachyOS and UMU-Proton; GE-Proton 7 and 8 don't have it.

umu-run has to be installed: `umu-launcher` on Arch, the packages from its GitHub releases elsewhere. Its first run needs internet and downloads the runtime into `~/.local/share/umu`, about 195 MB for sniper and 165 MB for steamrt4. Every run after that asks Valve's server for a runtime update and waits for one that is out, and runs offline once a runtime is there. Inside the container only the home folder, `/mnt`, `/media`, `/run/media`, `/opt` and `/srv` are visible, so a game or a mods library anywhere else, such as `/games`, is missing there, and links into it most likely load nothing. That last part is not yet tried.

Switched off, Proton starts directly, with the command Heroic runs when UMU is disabled for a game: nothing to install, no network and every folder visible, but on the system's libraries. It always starts the game through `steam.exe`, so it doesn't need the game's fix. Started directly from the app is not yet confirmed.

Started directly, Proton builds that bundle protonfixes, as GE-Proton, dwproton and CachyOS's do, need a game id. Without `UMU_ID`, `SteamAppId` or `SteamGameId`, protonfixes reads the last run of digits out of `STEAM_COMPAT_DATA_PATH`, and a prefix path with no digits, such as Heroic's `Prefixes/HoyoPlay`, raises an error that stops Proton before XXMI starts. The id passed is `0`, as Heroic passes it: no game-specific fixes.

Started directly, Proton has no default prefix and expects a Steam compat-data folder, with the prefix in its `pfx/` child. Prefixes umu has run in, which by default includes Heroic's for Proton games, have a `pfx` link back to the folder itself; Steam's, and Heroic's with UMU off, have a real `pfx/`. Both work. A plain prefix, with `drive_c` and no `pfx`, as Wine and Lutris make it, would get a second prefix built inside it, so Settings warns about that layout while umu is off, and the button refuses to start Proton directly with no prefix at all. umu-run takes either layout. It has a default prefix of its own, `~/Games/umu/umu-zenlesszonezero`, but the game isn't set up there, so the game's prefix still has to be chosen. When umu-run, wine or the proton script can't be run, the start fails and the button says which program it couldn't run.

A prefix is upgraded to whatever Wine or Proton version last ran in it. Starting XXMI with a different runner than the game's own launcher uses will do that to the game's prefix, so the runner should be the same one.

The launch arguments are split into words without a shell:

- whitespace separates words;
- `'…'` is literal;
- inside `"…"`, only `\"` and `\\` are escapes;
- outside quotes, a backslash escapes the next character;
- `""` is one empty word, and an unclosed quote runs to the end;
- there is no `$` expansion.

A chosen file that isn't an `.exe` is the way out for a setup these settings can't express, such as gamescope or a Flatpak runner. An executable script runs directly from its own folder with the split arguments and no Wine environment. A `.desktop` file is refused, because `gio launch` can't pass arguments and they would be silently dropped. So are `.bat`, `.cmd`, `.lnk` and `.msi`, whatever their mode: an NTFS or exFAT mount, which a dual-booting player is likely to have, marks every file executable. A file without the execute bit is refused too.

## When the game closes itself under umu

The symptom: through umu-run the game's window opens and closes about a second later, while Proton started directly runs it. `driverError.log` in the game folder reads `initDriver Failed: Error [4,643,0]`.

The game's anti-cheat, `mhypbase`, looks up a name on the network as it starts. When the lookup works, it runs without its kernel driver, as it does under Proton started directly. When the lookup fails, it loads its kernel driver `HoYoKProtect.sys`, which Wine can't load (`ZwLoadDriver failed to create driver …\HoYoProtect: c0000355` in a Proton log), and the game exits.

Name lookups that work on the desktop can fail inside the Steam Linux Runtime container umu-run starts Proton in:

- The container's glibc asks the nameservers in `/etc/resolv.conf` itself. It has no `nss-resolve`, through which most desktop distributions ask systemd-resolved, so the host's own lookups say nothing about the container's.
- glibc uses only the first three `nameserver` lines.

So DNS inside the container is dead when the first three nameservers in `/etc/resolv.conf` don't answer. Two ways seen together on one machine: a systemd-resolved drop-in with `DNS=127.0.0.1` and `DNSStubListener=no`, left behind by a DNS filter that is no longer installed, so nothing listens there; and a VPN, Mullvad, that blocks the router's DNS on the local network. With the stub listener off, `/etc/resolv.conf` lists resolved's servers in an order that can change: with that same drop-in in place, a restart of systemd-resolved moved the VPN's `8.8.8.8` from fourth to second, and lookups worked again. So one setup can work one day and fail the next. The container's version makes no difference: sniper and steamrt4 both fail, in every version tried.

The check, with `steamrt3` in place of `steamrt4` for a Proton 10 build:

```
~/.local/share/umu/steamrt4/_v2-entry-point --verb=waitforexitandrun -- getent hosts sdk.hoyoverse.com
```

It prints addresses when DNS works inside the container and nothing when it doesn't. The way out is either to make the first nameservers in `/etc/resolv.conf` answer, which for systemd-resolved means its stub listener on `127.0.0.53`, or to switch umu off in Settings.

Launch game runs this check itself every time it starts the game through umu-run. It runs beside the game, once the game has started, so it never delays or stops the launch, and it takes about 0.4 seconds once the runtime is downloaded. When the lookup finds no name, getent's exit code 2, or takes longer than 20 seconds, a warning says DNS doesn't work inside umu-launcher, that the game's anti-cheat will close the game, and to fix the system's DNS or turn umu-launcher off in Settings. The warning stays until it is closed, since the user is looking at the game when it arrives. A lookup that works shows nothing. The 20 seconds leave room for a first nameserver that doesn't answer, which glibc waits 5 seconds on for each query.

The runtime is the one umu runs the Proton build in: the `require_tool_appid` in the `toolmanifest.vdf` beside the build's `proton` script, with umu's own table (`RUNTIME_VERSIONS` in its `umu_runtime.py`) naming the folder, such as `1628350` for `steamrt3` and `4183110` for `steamrt4`. umu's data folder is found the way umu finds it: `$UMU_FOLDERS_PATH/umu`, else `$XDG_DATA_HOME/umu` (`$HOST_XDG_DATA_HOME` inside a Flatpak), else `~/.local/share/umu`.

Nothing is shown, and the check is skipped or gives no verdict, when the build has no manifest or names a runtime umu doesn't know, when the runtime's `_v2-entry-point` isn't there yet, as on umu's first run while it downloads the runtime, or when the container can't start or fails with any other exit code. Wine, Proton started directly and a chosen script are never checked. Every verdict is logged with the runtime and getent's exit code.

Not the cause, each tested by a launch that still failed: the game id umu-run is given, `umu-0` and Steam's `umu-4162040` alike; the fix's `WINE_DISABLE_VULKAN_OPWR=1`; the `lsteamclient=d` override umu adds; the variables the container sets; its `os-release`. `UMU_NO_RUNTIME=1` doesn't take Proton out of the container, so a failure with it set doesn't rule the container out.

Not known: which name the anti-cheat looks up, and so whether a DNS filter that blocks HoYoverse's domains stops the game under Proton started directly too. That is not yet tried.

## Keeping the screen awake

On Linux, a game started from the button keeps the screen on, and keeps the computer from going to sleep on its own, for as long as the game runs, even after the app is closed. A desktop decides the user is idle from the keyboard, mouse and touch alone, so during controller play the screen would turn off, and Plasma's default of sleeping after 15 minutes on AC would put the computer to sleep mid-game. Sleep the user asks for, from the menu or by closing a laptop's lid, still works.

Each desktop reads a different lock, so the app starts three programs, each holding one (`awakeLocks` in `services/platform_service_linux.dart`):

| Program | Lock | Read by |
|---|---|---|
| `systemd-inhibit --what=idle --who=Zenith --why="Playing Zenless Zone Zero"` | logind's `idle` | Plasma, for the screen only; Hyprland's hypridle, which then runs none of its idle actions, sleep included |
| `gnome-session-inhibit --app-id Zenith --reason "Playing Zenless Zone Zero" --inhibit idle` | GNOME's session `idle` | GNOME, for both: gsd-power drops its sleep timer while the session may not go idle. GNOME reads no logind lock |
| `kde-inhibit --power --screenSaver` | `org.freedesktop.PowerManagement.Inhibit` and `org.freedesktop.ScreenSaver.Inhibit` | Plasma's power manager: the power lock is the one its automatic sleep checks, and the screen lock covers a Plasma without logind. Plasma lists it as "Running Script" with `sh` as the reason, since `kde-inhibit` sets its own label |

A program that isn't installed is skipped, and a lock no running desktop reads holds nothing. `gnome-session-inhibit` with no GNOME session exits at once.

Plasma's power manager splits the two: a logind `idle` lock and the screensaver lock stop only dimming, turning off and locking the screen, and its automatic sleep checks a separate lock, which the power lock or a logind `sleep` lock sets.

The programs start after the game, beside it rather than around it, so no lock can change the launch. Wrapped around the game, a missing umu-run would fail inside the lock program, out of the app's sight, and the button couldn't say which program it couldn't run. A `systemd-inhibit` that can't reach logind also exits without starting its command at all. The programs are detached like the game, so closing the app doesn't end them.

Each program runs the same watcher (`awakeScript`), a fixed `sh -c` script that receives the runner's process id and the wineserver's path as arguments, so no path is ever pasted into its text. It checks every 5 seconds whether the runner's process is still there, then waits for the prefix's `wineserver -w` where there is one, and the lock ends with it. Wine returns when XXMI exits, a few seconds into the game, and so does Proton started directly: `waitforexitandrun` waits for the prefix before it starts XXMI, not after. The game keeps running in the prefix, and `wineserver -w` returns once the last program in it has exited, so anything else running in that prefix, such as a launcher in the tray, keeps the lock too. umu-run lasts as long as the game, so the watcher waits only for it. A chosen script is watched the same way, and its lock lasts as long as the script: a script that runs Wine itself and returns when XXMI does keeps the lock only for those first seconds.

| Runner | wineserver waited on | Prefix it serves |
|---|---|---|
| empty | `wineserver`, from PATH | `WINEPREFIX` when a prefix is set |
| any other wine file | the `wineserver` beside it, else the one on PATH | `WINEPREFIX` when a prefix is set |
| a file named `proton`, umu off | `files/bin/wineserver` in the Proton build, else the one on PATH | `<prefix>/pfx` |
| a file named `proton`, umu on, or a script | none | |

`wineserver -w` waits only on the prefix's server lock file, so a wineserver of another version works, and it returns at once when no server is running. That is why the one on PATH stands in for a runner with none beside it, such as a wrapper script or a link to a build kept elsewhere. A lock ends up to 5 seconds after the game, plus the few seconds Wine keeps an empty prefix's server.

Measured on Plasma 6.8, through umu-run with dwproton 11: XXMI exits within 9 seconds of the launch while umu-run and the game run on, and Plasma counts both its screen and its automatic sleep as blocked from about 5 seconds after the locks are taken, the delay before it takes a new lock into account. When the game closes, umu-run, the watchers and every lock are gone within one 5-second poll; 3 seconds in the run measured. What other desktops read comes from their source and is not tried, and neither is Wine or Proton started directly.

Not used:
- A lock the app holds over D-Bus itself, which is how Heroic does it through Electron: it ends when the app closes, and the game is meant to outlive the app.
- logind's `sleep` lock, which every desktop's automatic sleep would meet: logind then also refuses sleep the user asks for, from the menu or a laptop's lid.
- KWin's game controller plugin, which counts controller input as activity. Whenever it decides no app is using the controller, it also makes the controller a mouse and keyboard on the desktop, and it decides that from the controller's `/dev/input/event*` device, while the game under Proton reads `/dev/hidraw*`.

## What the button reports

`PlatformService.launchGame` answers with a `LaunchOutcome`, and the button reports only a failure: a game that starts is its own feedback ([`notifications.md`](notifications.md)).
While the launcher is being started the button shows it working, once the start has taken 200 ms, and ignores a press, so a slow Proton start can't be started twice. The question for a launcher before it and the container's check after it are not part of that.

| Outcome | Shown |
|---|---|
| `started` | nothing |
| `notFound` | error: the launcher is gone, with its path |
| `unsupported` | error: can't start this file, and what to choose instead |
| `runnerMissing` | error: couldn't run Wine or Proton, with the program it tried |
| `prefixRequired` | error: Proton started directly needs a prefix, and where to choose one |
| `failed` | error: couldn't start the game, with the file name |

A game started through umu-run also has its container checked for name lookups, and when they fail a warning that stays until closed follows a moment after the start ([When the game closes itself under umu](#when-the-game-closes-itself-under-umu)). `LaunchResult.containerDns` carries that verdict, and the button waits for it only after the launch is done.

The process is started detached and never waited on: the app has no business holding the game's lifetime, and closing the app must not take the game with it.

## Not done

- Detecting whether the game is already running before starting it again. `PlatformService.findGameProcesses` would answer that, but its match on `zzz` also catches the app's own `zzz-mod-manager` folder.
- Not yet run on Windows. A declined UAC prompt most likely reports `failed`.
- No lock on Windows. Whether the game holds one itself is not checked.
- No lock where the idle daemon honours only Wayland's idle-inhibit protocol, such as sway's swayidle: that protocol needs a window of the app's own. XFCE, Cinnamon, MATE and others get one only where one of the three programs is installed and the desktop reads its lock.
