# Launch game

The sidebar's **Launch game** button starts the game, so a user who has just turned mods on doesn't have to find the
launcher themselves. It sits in the ZZMI card, under the reminder to press F10 after changes. The app never presses
F10 itself ([`mod-reload.md`](mod-reload.md)).

## What it starts

One file the user picks, stored in `config.json` as `launch_target` ([`configuration.md`](configuration.md)). The app
doesn't search for the game or the XXMI Launcher, because there is no install it could safely assume. On Linux the
game runs under Wine, Proton, Lutris, Steam or Heroic, and the thing that starts it is whatever shortcut that tool made.
On Windows the launcher can live anywhere.

The first press, with nothing chosen, opens a file picker. The answer is saved and the game starts at once, so choosing
is part of launching rather than a separate trip to Settings. **Settings › Launch game with** shows the chosen file and
changes it.

## How each platform starts it

`PlatformService.launchGame` answers with a `LaunchOutcome`, and the button reports only a failure: a game that starts
is its own feedback ([`notifications.md`](notifications.md)).

| Platform | Starts | Refuses |
|---|---|---|
| Linux | a `.desktop` shortcut, through `gio launch`; any other file with an execute bit, run from its own folder | a Windows file (`.exe`, `.bat`, `.cmd`, `.lnk`, `.msi`) whatever its mode, and a file without the execute bit, as `unsupported` |
| Windows | anything a double-click would, through `ShellExecuteW` with the file's own folder as the working directory: an `.exe` with its UAC prompt, a `.lnk` shortcut, a `.bat` | nothing by type |

A Linux `.exe` is refused rather than handed to Wine. Which Wine prefix, runner and environment the game needs is exactly what the user's own launcher already knows, and a guess would start the launcher in the wrong prefix with no error to show for it.
The refusal names the file and says to choose its `.desktop` shortcut or a script instead.
A Windows file is refused by its extension before its mode is read: an NTFS or exFAT mount, which a dual-booting player is likely to have, marks every file executable, and with Wine registered through binfmt an `.exe` would run in Wine's default prefix.

On Windows the path goes to `ShellExecuteW` as it is. A command line through `cmd /c start` would read `&`, `^` and `%` in a folder name such as `R&D`, and starting an `.exe` with `Process.start` fails outright on a launcher whose manifest asks for administrator rights.

The process is started detached and never waited on: the app has no business holding the game's lifetime, and closing
the app must not take the game with it.

## Not done

- Detecting whether the game is already running before starting it again. `PlatformService.findGameProcesses` can answer that.
- Starting through a `steam://` URL. A Steam shortcut's `.desktop` file covers the same case through `gio launch`.
- Not yet run on Windows.
