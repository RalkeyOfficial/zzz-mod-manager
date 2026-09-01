#!/bin/sh
# Registers this copy of ZZZ Mod Manager with the desktop, for the current user.
#
# **The window's icon depends on this on Wayland.** A Wayland compositor reads no
# icon from the window itself — it takes the surface's app id, looks for
# `<app id>.desktop`, and reads `Icon=` from that. So an unregistered portable
# build gets a placeholder icon and an anonymous taskbar entry no matter what the
# app does at runtime. A package install (the AUR one) does this for you; a
# tarball you extracted anywhere cannot know its own path until it is run.
#
# **This does not put the app in your application launcher.** The entry is
# written with `NoDisplay=true`, which menus and launchers skip — it exists only
# so the compositor has something to match the window against. Pass --menu if you
# do want a launcher entry.
#
# Writes only under $HOME, needs no root, and prints what it wrote. Undo with
# --uninstall.
set -eu

APP_ID='io.github.notionme.ZzzModManager'
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# The bundle root: this script lives in packaging/ beside the executable.
BUNDLE=$(dirname -- "$HERE")

DESKTOP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
ICON_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/256x256/apps"

IN_MENU=no
if [ "${1:-}" = '--menu' ]; then
    IN_MENU=yes
    shift
fi

if [ "${1:-}" = '--uninstall' ]; then
    rm -f "$DESKTOP_DIR/$APP_ID.desktop" "$ICON_DIR/$APP_ID.png"
    echo "Removed $DESKTOP_DIR/$APP_ID.desktop"
    echo "Removed $ICON_DIR/$APP_ID.png"
    command -v update-desktop-database >/dev/null 2>&1 &&
        update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
    exit 0
fi

EXEC="$BUNDLE/mod_manager_flutter"
if [ ! -x "$EXEC" ]; then
    echo "No executable at $EXEC — run this from inside the extracted bundle." >&2
    exit 1
fi

mkdir -p "$DESKTOP_DIR" "$ICON_DIR"

# Exec is rewritten to this bundle's real path; everything else comes from the
# shipped entry, so there is one description of the app rather than two.
sed "s|^Exec=.*|Exec=\"$EXEC\" %U|" "$HERE/$APP_ID.desktop" \
    > "$DESKTOP_DIR/$APP_ID.desktop"

# Hidden from menus by default. The entry's job here is to be *found by app id*
# so the window gets an icon; appearing in the launcher is a separate thing, and
# a portable build you run from a folder has no business installing itself into
# the application list uninvited.
if [ "$IN_MENU" = 'no' ]; then
    printf 'NoDisplay=true\n' >> "$DESKTOP_DIR/$APP_ID.desktop"
fi
chmod 644 "$DESKTOP_DIR/$APP_ID.desktop"

# Under the app id, because that is the name `Icon=` resolves through the theme.
cp "$BUNDLE/data/flutter_assets/assets/icon.png" "$ICON_DIR/$APP_ID.png"
chmod 644 "$ICON_DIR/$APP_ID.png"

command -v update-desktop-database >/dev/null 2>&1 &&
    update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
command -v gtk-update-icon-cache >/dev/null 2>&1 &&
    gtk-update-icon-cache -qtf "${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor" 2>/dev/null || true

echo "Installed $DESKTOP_DIR/$APP_ID.desktop"
echo "Installed $ICON_DIR/$APP_ID.png"
if [ "$IN_MENU" = 'no' ]; then
    echo "Hidden from the application launcher (NoDisplay). Pass --menu to list it."
fi
echo "The app now has its icon and its own taskbar entry. Restart it if it is running."
