# Desktop integration

**Scope:** how the app presents itself *as a window* to the desktop it runs on —
its application id, its desktop entry, its icon, and its title bar. Everything
here is about the frame around the app rather than anything inside it.

What the app does with its own settings is [`configuration.md`](configuration.md);
what it records about the machine is [`logging.md`](logging.md).

---

## 1. One string in three places

```
mod_manager_flutter/linux/CMakeLists.txt       APPLICATION_ID
mod_manager_flutter/linux/packaging/<id>.desktop   the filename
usr/share/icons/hicolor/256x256/apps/<id>.png      the filename
```

All three are `io.github.notionme.ZzzModManager`. **If they stop matching, the
window loses its icon and its name in the taskbar**, and nothing in the app can
compensate, because the lookup happens entirely outside it.

The chain a Wayland compositor follows:

```
GTK surface  --app id-->  <app id>.desktop  --Icon=-->  icon theme  -->  the icon
```

`g_set_prgname(APPLICATION_ID)` in `linux/runner/my_application.cc` is what puts
the app id on the surface. It also becomes `WM_CLASS` on X11, which is why the
same value serves both backends.

## 2. Why an icon set in code is not enough

The two display servers take the icon from completely different places, and only
one of them will accept it from the application:

| | X11 | Wayland |
|---|---|---|
| Icon travels with the window | yes, `_NET_WM_ICON` | **no such thing** |
| What the taskbar reads | the window's own property | `Icon=` in `<app id>.desktop` |
| `gtk_window_set_icon()` helps | yes | no |

So on Wayland an **unregistered build cannot have an icon at all** — not because
of a bug, but because there is no protocol carrying one. A window with an app id
matching no installed desktop entry gets a placeholder icon and an anonymous
taskbar entry. This is the whole reason the desktop entry is part of the
deliverable rather than a packaging nicety.

`set_window_icon()` in `my_application.cc` covers both cases in one order:

1. **The icon theme, by app id** — the mechanism an installed build uses, and the
   one that scales to whatever size is asked for.
2. **The file beside the executable**, resolved from `/proc/self/exe` — for a
   portable build nobody installed. This helps X11 only, per the table above.

The second step reads `/proc/self/exe` rather than a relative path deliberately.
A relative path resolves only when the process happens to have been started from
inside its own bundle directory, which is true under `flutter run` and false for
every shipped build — an icon that appears in development and nowhere else.

## 3. The three ways the app gets installed

| | Desktop entry | Icon | Wayland icon works |
|---|---|---|---|
| AUR (`zzz-mod-manager-git`) | `PKGBUILD` installs it | hicolor, under the app id | yes |
| Portable tarball | `packaging/install-desktop-entry.sh`, run once by the user | same, under `$HOME` | after running the script |
| `flutter run -d linux` | none | none | no — X11 backend only |

The tarball cannot ship a ready-to-use entry: `Exec=` has to name wherever the
user extracted it, which is unknowable at build time. Hence a script, which
rewrites only that line and takes everything else from the shipped entry so there
is one description of the app rather than two. It writes under `$HOME`, needs no
root, and reverses with `--uninstall`.

**The portable entry is written `NoDisplay=true`**, so it does not appear in the
application launcher. Being *found by app id* and being *listed in a menu* are
separate things, and only the first is needed for an icon:

```
found by app id   : True                              <- the compositor can match the window
icon resolves to  : io.github.notionme.ZzzModManager  <- the icon still resolves
listed in launcher: False                             <- absent from the application list
```

A build someone extracted into a folder and ran has no business installing itself
into the application list uninvited; `--menu` asks for that explicitly. The
packaged build is listed normally — being in the menu is the point of installing
a package.

### `xdg-toplevel-icon-v1`, and why it is not used yet

Wayland did eventually grow a way for a client to set its own icon, so the
desktop entry is no longer the *only* mechanism in principle. `xdg_toplevel_icon_v1`
takes either a theme name or **raw pixel buffers**, and the buffer form needs no
installed file of any kind — exactly the portable case above.

It is not used here because of the toolkit, not the protocol:

| | implements `xdg_toplevel_icon` |
|---|---|
| GTK 3 (what Flutter's Linux embedder uses) | **no**, and it is in maintenance mode |
| GTK 4 | yes |
| Qt 6 Wayland client | no |
| KWin 6 | yes |

Reaching it would mean binding the global directly in `linux/runner/`: generate
the protocol code with `wayland-scanner` (a new `wayland-protocols` build
dependency), get the surface GTK made with `gdk_wayland_window_get_wl_surface()`,
and attach `wl_shm` buffers. That is worth doing when the desktop entry stops
being enough — it removes the one manual step the portable build has — but it
only helps on compositors new enough to advertise the global, so the entry stays
as the fallback either way.

Under `flutter run` the app is deliberately left unregistered — installing a
desktop entry as a side effect of a debug launch would put a development build in
the user's application menu.

## 4. The title bar is the window manager's

**The app draws no title bar and no window controls.** It keeps whatever its
desktop draws, on all three platforms.

A drawn title bar was tried, and the two ways of hiding the real one each fail,
measured on KDE/KWin 6 with GTK 3.24. They fail *differently*, which is the part
worth keeping:

| GTK configuration | Decoration the compositor adds | Resizable by an edge |
|---|---|---|
| `set_decorated(FALSE)` | **28px** | yes — that decoration is the grab edge |
| `set_titlebar(empty widget)` then `set_decorated(FALSE)` | 0px | **no** |
| decorated (what the app does) | 28px | yes |

- **`set_decorated(FALSE)` does not undecorate a Wayland window.** GTK announces
  client-side decoration only when it actually draws some, so the compositor adds
  a title bar of its own *above* the app's. Two bars on one window. On X11 the
  same call sets `_MOTIF_WM_HINTS` decorations=0, which is honoured — so the two
  backends disagree about what the window even is.
- **Actually undecorating it removes resize.** The `set_titlebar` row is a real
  one-line fix for the double bar, and it is a trap: neither GTK nor the
  compositor offers an edge to grab once the decoration is gone. A corner drag
  left such a window at exactly its starting size. Resize would have to be
  rebuilt in the app — eight invisible grab strips calling `startResizing` — to
  get back what the decoration was giving for free.

So the double bar and the resize edge came from the same 28px: the bug was also
the only reason the window could be resized on Wayland. Fixing one by hand would
have cost the other.

What the system title bar gives that a drawn one would each have to reimplement:
resize by any edge, double-click to maximise, the right-click window menu, the
user's chosen button order and side, and their decoration theme. It is also
shorter than the drawn one was — 28px against 45px — so the app gained content
height by dropping it.

**Consequences for anyone changing this:**

- Do not set `titleBarStyle: TitleBarStyle.hidden` in `WindowOptions`
  (`lib/main.dart`), and do not call `gtk_window_set_decorated(window, FALSE)`.
  Either one reintroduces the unresizable window.
- Anything that wants to live "in the title bar" has nowhere to go and belongs in
  the sidebar instead. `DownloadsButton` sits above the version badge for exactly
  this reason: a transfer outlives the tab that started it, so it cannot belong to
  one, and the sidebar is the only chrome the app still owns.
- `window_manager` is still a dependency and still used — window size, position,
  minimum size and the close hook. Only the decoration is no longer its business.
