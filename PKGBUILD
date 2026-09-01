# Maintainer: NotionMe <c.ubohyi.stanislav@student.uzhnu.edu.ua>
pkgname=zzz-mod-manager-git
pkgver=r6.967f969
pkgrel=1
pkgdesc="Modern mod manager for Zenless Zone Zero using Flutter"
arch=('x86_64')
url="https://github.com/NotionMe/Mod-manager"
license=('MIT')
depends=(
    'gtk3'
    'glib2'
    'libx11'
    # Extracting .rar and .7z mod archives, which is most of GameBanana.
    # `ArchiveService` shells out to 7z/7za/7zr; without it those mods cannot
    # be installed at all, only .zip.
    '7zip'
    # `xdg-open`, for "open mod page" and "open mod folder". url_launcher_linux
    # calls it too, so it is the mechanism on both paths.
    'xdg-utils'
)
# No optdepends. `xdotool`, `ydotool` and `wmctrl` were listed for an F10
# auto-reload feature that has been removed — see docs/mod-reload.md.
makedepends=(
    'git'
    'flutter'
    'clang'
    'cmake'
    'ninja'
    'pkgconf'
)
provides=('zzz-mod-manager')
conflicts=('zzz-mod-manager')
# The app's identity to the desktop. Must equal APPLICATION_ID in
# mod_manager_flutter/linux/CMakeLists.txt — see the icon install in package().
_appid='io.github.notionme.ZzzModManager'
source=("git+https://github.com/NotionMe/Mod-manager.git")
sha256sums=('SKIP')

pkgver() {
    cd "$srcdir/Mod-manager"
    printf "r%s.%s" "$(git rev-list --count HEAD)" "$(git rev-parse --short HEAD)"
}

prepare() {
    cd "$srcdir/Mod-manager/mod_manager_flutter"
    
    # Встановлюємо Flutter залежності
    export PUB_CACHE="$srcdir/pub_cache"
    flutter pub get
}

build() {
    cd "$srcdir/Mod-manager/mod_manager_flutter"
    
    # Експортуємо Flutter cache
    export PUB_CACHE="$srcdir/pub_cache"
    
    # Будуємо Flutter додаток для Linux
    flutter build linux --release
}

package() {
    cd "$srcdir/Mod-manager"
    
    # Створюємо директорії
    install -dm755 "$pkgdir/opt/zzz-mod-manager"
    install -dm755 "$pkgdir/usr/bin"
    install -dm755 "$pkgdir/usr/share/applications"
    install -dm755 "$pkgdir/usr/share/pixmaps"
    install -dm755 "$pkgdir/usr/share/icons/hicolor/256x256/apps"
    
    # Копіюємо Flutter build
    cp -r mod_manager_flutter/build/linux/x64/release/bundle/* "$pkgdir/opt/zzz-mod-manager/"
    
    # The icon, under the app id rather than the package name. A Wayland
    # compositor reads no icon from the window itself: it matches the surface's
    # app id to `<app id>.desktop` and takes `Icon=` from there, which resolves
    # through the icon theme. So the app id in linux/CMakeLists.txt, the desktop
    # entry's filename and this filename are one string in three places, and the
    # window loses its icon if they stop matching.
    install -Dm644 assets/icon.png \
        "$pkgdir/usr/share/icons/hicolor/256x256/apps/$_appid.png"
    install -Dm644 assets/icon.png "$pkgdir/usr/share/pixmaps/$_appid.png"
    
    # Примітка: mod_images тепер зберігаються в ~/.local/share/zzz-mod-manager/mod_images
    # Директорія буде створена автоматично при першому запуску застосунку
    
    # The desktop entry, installed from the tree rather than written here so it
    # is one file with one set of contents. Its **filename must be the app id**
    # — that is the string a Wayland compositor looks up.
    install -Dm644 "mod_manager_flutter/linux/packaging/$_appid.desktop" \
        "$pkgdir/usr/share/applications/$_appid.desktop"
    
    # Створюємо wrapper скрипт для легкого запуску
    cat > "$pkgdir/usr/bin/zzz-mod-manager" << 'EOF'
#!/bin/bash
cd /opt/zzz-mod-manager
exec ./mod_manager_flutter "$@"
EOF
    
    chmod +x "$pkgdir/usr/bin/zzz-mod-manager"
    
    # Встановлюємо права на виконання
    chmod +x "$pkgdir/opt/zzz-mod-manager/mod_manager_flutter"
    
    # Копіюємо документацію якщо є
    if [ -f "AUR_GUIDE.md" ]; then
        install -Dm644 AUR_GUIDE.md "$pkgdir/usr/share/doc/zzz-mod-manager/AUR_GUIDE.md"
    fi
    if [ -f "FLATPAK_GUIDE.md" ]; then
        install -Dm644 FLATPAK_GUIDE.md "$pkgdir/usr/share/doc/zzz-mod-manager/FLATPAK_GUIDE.md"
    fi
    
    # Копіюємо ліцензію якщо є
    if [ -f "LICENSE" ]; then
        install -Dm644 LICENSE "$pkgdir/usr/share/licenses/$pkgname/LICENSE"
    fi
}
