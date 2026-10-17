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

An installed icon is a copy, so a new `assets/icon.png` reaches no machine that
already has the entry. Because the runner prefers the icon theme over the bundled
file, even `flutter run` keeps showing the installed one. Run the script again
after changing the icon. KWin also holds a window's icon in memory by name for as
long as it runs, so on KDE the new one appears only after logging in again.

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

## 4. The app draws its own title bar

**`ZenithTitleBar` (`lib/screens/shell/title_bar.dart`) is the window's only
title bar**: the logo, the ZENITH wordmark, and minimise, maximise and close. It
is mounted in `MaterialApp.builder`, above every page, because the first-run
screen and the loading spinner need it as much as the main screen does. Dragging
it moves the window, a double-click maximises or restores, and a right-click
opens the desktop's window menu.

### The hazard: hiding a title bar on Wayland can take the resize edge with it

GTK draws a window's shadow and its resize border only while the window is
*decorated*, and on Wayland it tells the compositor who decorates through the
KDE server-decoration protocol: client-side only when it draws some. Two ways of
hiding the system bar were measured on KDE/KWin 6 with GTK 3.24, and each fails:

| GTK configuration | Decoration the compositor adds | Resizable by an edge |
|---|---|---|
| `set_decorated(FALSE)` | **28px** | yes, by that decoration |
| `set_titlebar(empty widget)` then `set_decorated(FALSE)` | 0px | **no** |
| `set_titlebar(header bar)`, bar hidden, still decorated (what the app does) | 0px | yes, by GTK's border |

- **`set_decorated(FALSE)` does not undecorate a Wayland window on KDE.** GTK
  announces server-side decoration, so KWin adds a title bar of its own above the
  app's: two bars on one window. GNOME's mutter has no server-side decorations at
  all, so the same call leaves a bare window with no shadow and no edge. On X11
  the call sets `_MOTIF_WM_HINTS` decorations=0, which is honoured.
- **Undecorating removes resize.** With the decoration gone, neither GTK nor the
  compositor offers an edge to grab. A corner drag left such a window at exactly
  its starting size.

The runner (`linux/runner/my_application.cc`) does neither. It sets a
`GtkHeaderBar` as the window's titlebar and hides it, and never undecorates the
window. A titlebar widget makes the window client-decorated whether or not the
widget is visible, so GTK keeps drawing the shadow and the resize border outside
the visible frame and tells KWin it decorates itself; Flutter paints the whole
visible area. `TitleBarStyle.hidden` in `WindowOptions` is safe on Linux *only
because the header bar exists*: `window_manager` then hides the bar, and without
one it falls back to `set_decorated(FALSE)`. `test/desktop_entry_test.dart` pins
both halves.

On Windows, `TitleBarStyle.hidden` removes the caption and keeps the native
border on the left, right and bottom, but not the top. The title bar covers the
top edge with a 4px strip that calls `startResizing`.

### What still differs from a system title bar

Measured on KDE/KWin 6 Wayland:

- **A resize trails the cursor slightly.** GTK draws the frame, so the frame and
  the content move together at Flutter's pace, where KWin used to move its own
  frame and leave only the content behind. A release or profile build lags a
  little and was accepted. A debug build (`flutter run`) lags far more, so judge
  resize smoothness on a profile build.

Not yet measured:

- **The button order and side are the app's**, not the desktop's
  (`gtk-decoration-layout` is not read), and GNOME's own default of a close button
  only is not followed.
- **KDE draws GTK's shadow rather than Breeze's**, and KWin's border size setting
  does not apply.
- **The top corners are square** where the desktop rounds its own windows.
- **Windows 11's Snap Layouts flyout does not open** on hovering maximise. That
  needs the runner to answer `WM_NCHITTEST` with `HTMAXBUTTON` over the button;
  Win+Z still opens it. Windows 10 shows a 1px light line along the top.
- **X11 without a compositor** gets a thin frame inside the window and no shadow.
- Not yet run on Windows at all.

**Consequences for anyone changing this:**

- Never call `gtk_window_set_decorated(window, FALSE)`, and never remove the
  runner's header bar. Either one brings back the double bar on KDE and the
  unresizable window everywhere.
- `window_manager` drives the window from Dart: size, position, minimum size,
  dragging, maximise, the window menu and the close hook.
