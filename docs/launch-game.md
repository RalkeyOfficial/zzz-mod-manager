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

## What the button reports

`PlatformService.launchGame` answers with a `LaunchOutcome`, and the button reports only a failure: a game that starts is its own feedback ([`notifications.md`](notifications.md)).

| Outcome | Shown |
|---|---|
| `started` | nothing |
| `notFound` | error: the launcher is gone, with its path |
| `unsupported` | warning: can't start this file, and what to choose instead |
| `runnerMissing` | error: couldn't run Wine or Proton, with the program it tried |
| `prefixRequired` | warning: Proton started directly needs a prefix, and where to choose one |
| `failed` | error: couldn't start the game, with the file name |

The process is started detached and never waited on: the app has no business holding the game's lifetime, and closing the app must not take the game with it.

## Not done

- Detecting whether the game is already running before starting it again. `PlatformService.findGameProcesses` would answer that, but its match on `zzz` also catches the app's own `zzz-mod-manager` folder.
- Not yet run on Windows. A declined UAC prompt most likely reports `failed`.
