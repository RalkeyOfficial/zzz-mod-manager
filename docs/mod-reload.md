# Reloading mods in the running game

**The app does not do this. Press F10 in the game.**

This file exists so the feature is not built a third time. It was built, it
never worked, and this is what was measured before it was removed.

> Scope: why pressing F10 for the user is not attempted. Creating and removing
> the links a reload would pick up is
> [`app-architecture.md`](app-architecture.md).

---

## 1. There is no signal file

3DMigoto does not watch its mods folder. Nothing written there — no
`.reload_signal`, no `.mod_timestamp`, no touched file — makes it re-read
anything. The only trigger is the `reload_fixes` hotkey, which XXMI ships bound
as:

```ini
reload_fixes = no_modifiers VK_F10
```

So the whole feature reduces to one act: get an F10 keypress into the game's own
window.

## 2. What was measured

On KDE Wayland (CachyOS), with the game running under Proton and **KWin itself
asked which window had keyboard focus** — via a KWin script over D-Bus, because
every X-side answer turned out to be unreliable:

| Step | Result |
|---|---|
| `xdotool` finds the game window, on Wayland too | **works** — the game is an XWayland client either way |
| `xdotool windowactivate` gives it real keyboard focus | **works** — KWin confirms the active window changed |
| `xdotool key F10` (XTEST) with that focus confirmed | **never arrives** — 0 of 6+ presses |
| `xdotool key --window <id> F10` (XSendEvent) | never arrives |
| `ydotool` (`/dev/uinput`, via `ydotoold`) with that focus confirmed | arrives **sometimes** |
| a **physical** F10 with that same programmatic focus | works every time |

Two bugs were found and fixed along the way, and neither was sufficient:

- **`KEY_F10` is event code 68; the code sent was 67, which is `KEY_F9`.**
  `ydotool` speaks event codes, not keysym names. So even a correctly configured
  Wayland machine pressed the wrong key — indistinguishable, from outside, from
  the key not arriving.
- **A failed window search fell through to a blind `xdotool key F10`** and
  returned success. The window holding focus when someone clicks *Reload* is the
  mod manager, so the key went into this app; and a blind press cannot fail, so
  it could only ever be reported as success. Every press, on every machine, said
  *"Mods reloaded — F10 was sent to the running game"*.

With both fixed, the app still did not land a press reliably. A physical key in
the identical state always works, so the gap is between an injected key and a
real one — not focus, which was verified.

## 3. Why it was not worth continuing

To see whether a mod changed you have to look at the game. Once you are looking
at the game it has focus, and F10 is under your finger. The feature buys **one
keystroke**, and charges for it with:

- two external tools (`xdotool`, plus `ydotool` on Wayland);
- a background daemon (`ydotoold`) and access to `/dev/uinput`;
- focus stealing on every mod toggle, since a key only reaches a focused window;
- a success message that cannot be verified — with the shipped ZZMI defaults
  (`hunting = 0`, `show_warnings = 0`, `[Logging] calls = 0`) a reload writes
  nothing and prints nothing, so nothing outside the game can confirm one.

That last point is the structural one. Even a working implementation could only
honestly claim *a key was sent*, never *mods were reloaded*.

## 4. If it is ever rebuilt

Two things it must not do, both of which the removed version did:

- **Never press a key that was not aimed at a located window.** A blind press
  goes to the mod manager and reports success.
- **Never claim a reload.** The strongest true claim is that a key was
  delivered.

And one thing to check first: whether an injected key can reach a Proton game at
all on the target compositor. That is the question the table in §2 answers with
"not reliably", and it is the one that decides whether anything else is worth
writing.
