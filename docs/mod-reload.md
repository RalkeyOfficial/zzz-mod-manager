# Making the game pick up a mod change

Reference for the **F10 reload**: how a key reaches 3DMigoto inside the running
game, what the app may claim about it, and why the tool it needs is the same on
X11 and Wayland.

> Scope: getting a *running* game to notice that the links in its mods folder
> changed. Creating and removing those links is
> [`app-architecture.md`](app-architecture.md); what the resulting card says is
> [`notifications.md`](notifications.md).

Related: [`logging.md`](logging.md) for the lines this writes.

---

## 1. There is no signal file

3DMigoto does not watch its mods folder. Nothing in the folder — no
`.reload_signal`, no `.mod_timestamp`, no touched file — makes it re-read
anything. **The only trigger is the `reload_fixes` hotkey**, bound in `d3dx.ini`
and shipped by XXMI as:

```ini
reload_fixes = no_modifiers VK_F10
```

So the whole feature is one act: press F10 inside the game's own window.

## 2. F10 goes to the game's window, or nowhere

A key press has a destination, and the destination is whatever holds focus.
When the user clicks *Reload mods*, the window holding focus **is the mod
manager** — so a press that is not aimed lands in this app and reloads nothing.

Two rules follow, and both are enforced rather than remembered
(`test/f10_reload_test.dart`):

- **The window is found first.** No window, no key press — the result is
  `F10Outcome.gameNotFound`, which is also the ordinary answer when the game is
  simply closed.
- **The game is brought forward, and the activation is confirmed.** A compositor
  may refuse an activation request from a background application, and the
  request itself reports nothing about that. So the app re-reads which window is
  active and only presses the key once the answer is the game's window.

A consequence worth stating plainly, because it is visible: **sending F10 brings
the game to the front.** That is not a side effect to be engineered away — it is
the mechanism. With automatic reload on, every toggle raises the game.

## 3. A synthetic key is not a key

**Linux: `xdotool key F10`, never `xdotool key --window <id> F10`.**

The targeted form looks better — it names the window, so it should not need
focus — and it does not work. `--window` sends an `XSendEvent`, which arrives at
the client flagged as synthetic. Wine does not fold synthetic events into the
keyboard state it reports through `GetAsyncKeyState`, and `GetAsyncKeyState` is
what 3DMigoto polls from its present hook to read hotkeys. The press is
therefore delivered, accepted, and ignored.

The untargeted form goes through XTEST, which the X server delivers as a real
event to the focused window — hence §2's insistence on focus.

**Windows: `SendInput`, never `PostMessage`.** The same fact from the other side.
A posted `WM_KEYDOWN` reaches the window's message queue and returns success
without touching keyboard state, so `GetAsyncKeyState` never sees it. `SendInput`
takes the path a real key takes, which again requires the window to be in the
foreground first. **Not verified on Windows** — the reasoning is 3DMigoto's, and
the Linux half of it is verified; the win32 path has not been run.

## 4. `xdotool` on Wayland too, not `ydotool`

The game runs under Proton, so **its window is an X11 window** — an XWayland
client — however the session is composited. `xdotool` finds it, activates it and
presses into it on a Wayland desktop exactly as on X11. Verified on KDE Wayland
(CachyOS): `xdotool search --onlyvisible --name Zenless` returns the window, and
an activation from a background application is confirmed active within 100 ms.

`ydotool` is not the Wayland answer and is not used. It writes to `/dev/uinput`,
so it can press a key — but it **cannot see windows at all**, and "is the game
there?" is the question that has to come first. Sending people to install it
(along with the `input` group and a systemd unit) asked for setup that could not
have helped.

So the dependency is `xdotool` on both display servers, and that is the single
tool the *Check xdotool* button in Settings reports on.

## 5. What the app may claim

**Never "mods reloaded".** Whether 3DMigoto acted is not observable from outside
the game: with the shipped ZZMI defaults — `hunting = 0`, `show_warnings = 0`,
`[Logging] calls = 0` — a reload writes nothing to disk and prints nothing on
screen. The strongest honest claim is that the key was delivered to a located,
focused game window, and that is what `F10Outcome.sent` means and what the
notification says.

Each failure names itself, because each needs something different from the
person reading it:

| Outcome | What the user is told | What it asks of them |
|---|---|---|
| `sent` | F10 sent | nothing |
| `gameNotFound` | the game isn't running | start the game |
| `toolMissing` | xdotool isn't installed | install a package |
| `sendFailed` | F10 couldn't be sent | the game would not come forward |

A single bool cannot carry that, which is why `sendF10ToGame` returns
`F10Result`.

**An automatic reload reports only to the log.** It follows a toggle the user
just made and can say nothing that toggle did not; a card per switch — most often
saying the game is not running — would make the setting not worth leaving on.

## 6. Every process call is bounded

The reload runs four short commands, and all of them go through
[`ProcessProbe`](../mod_manager_flutter/lib/utils/process_probe.dart): `which`,
`search`, `windowactivate`, `getactivewindow`, `key`. An `xdotool` talking to a
display server that has stopped answering is precisely the hang that helper
exists to prevent, and a reload press must not be able to wedge the app.
