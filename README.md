# ZZZ Mod Manager

> Modern mod manager for Zenless Zone Zero with symbolic link management

[🇺🇦 Українська версія](./README.uk.md)

![License](https://img.shields.io/badge/license-MIT-blue.svg)
![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20Windows-lightgrey.svg)
![Flutter](https://img.shields.io/badge/Flutter-3.8.1+-02569B.svg)

## 📋 Table of Contents

- [Overview](#overview)
- [Features](#features)
- [Screenshots](#screenshots)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [F10 Auto-Reload](#f10-auto-reload)
- [Usage](#usage)
- [Configuration](#configuration)
- [Building from Source](#building-from-source)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)
- [License](#license)

## 🎯 Overview

ZZZ Mod Manager is a modern, user-friendly mod manager for Zenless Zone Zero built with Flutter. It provides a clean interface for managing character mods using symbolic links, making it easy to enable/disable mods without moving files around.

The application uses symbolic links to manage mods, which means:
- ✅ No file copying - instant mod activation/deactivation
- ✅ Saves disk space
- ✅ Original mod files remain untouched in their location
- ✅ Safe and reversible operations

## ✨ Features

### Core Features

- **🎮 Mod Management**: Easy enable/disable mods with a single click
- **👥 Category-based Organization**: Organize mods by character or by non-character categories (UI, Texture, Audio, Misc)
- **🏷️ Auto-Tagging**: Automatic character detection from folder and `.ini` names
- **📦 Multiple Import Methods**:
  - Drag & Drop folders
  - Paste paths with Ctrl+V
  - File picker dialog
- **🔄 Single/Multi Mode**: Enable single or multiple mods per character
- **🎨 Modern UI**: Clean Material Design 3 interface
- **🌓 Dark/Light Theme**: Automatic theme switching
- **⚡ F10 Auto-Reload**: Automatically send F10 to game when activating mods
- **🧹 Auto-Cleanup**: Removes orphaned symbolic links and tags

### Advanced Features

- **📊 Mod Status Display**: Visual indication of active/inactive mods
- **🖼️ Character Avatars**: 60 character portraits included
- **🔍 Smart Tag Detection**: Recognizes all ZZZ characters
- **💾 Persistent Settings**: Saves your preferences and active mods
- **🪟 Window Management**: Customizable window size and position
- **📱 Responsive Design**: Adapts to different screen sizes

### Organization & Editing

- **🔎 Search, Sort & Filter**: Search by name, sort (Default / Name A–Z / Z–A, remembered across launches), filter by tags (match any/all), and show favorites only
- **🗃️ Grouped View**: The ALL view groups mods into collapsible per-category sections
- **📝 Mod Metadata**: Per-mod description, tags, and a clickable source link (e.g. GameBanana)
- **🖼️ Image Gallery**: Multiple images per mod (paste or add files, set a cover)
- **🔍 Details View**: A read-only dialog with a mod's images, category, description, tags, source link, and keybinds
- **⌨️ Keybinds**: View and edit a mod's keybinds parsed from its `.ini`
- **✏️ Rename**: Rename a mod from within the app
- **⭐ Favorites**: Star mods and filter to favorites
- **🛒 Marketplace**: Browse and download mods from GameBanana in-app

### Platform

- **🐧 Linux** and **🪟 Windows**

## 📸 Screenshots

*(The application features a modern dark/light theme interface with character cards, mod listings, and easy-to-use controls)*

## 📥 Installation

### Method 1: AUR (Arch Linux)

```bash
# Using yay
yay -S zzz-mod-manager-git

# Using paru
paru -S zzz-mod-manager-git

# Manual installation
git clone https://aur.archlinux.org/zzz-mod-manager-git.git
cd zzz-mod-manager-git
makepkg -si
```

### Method 2: Manual Installation

1. **Install dependencies**:
```bash
sudo pacman -S flutter gtk3 glib2 libx11
```

2. **Clone the repository**:
```bash
git clone https://github.com/NotionMe/Mod-manager.git
cd Mod-manager/mod_manager_flutter
```

3. **Install Flutter dependencies**:
```bash
flutter pub get
```

4. **Build the application**:
```bash
flutter build linux --release
```

5. **Run the application**:
```bash
./build/linux/x64/release/bundle/mod_manager_flutter
```

## 🚀 Quick Start

### First Launch - Welcome Screen

When you launch the application for the first time, you'll see a **Welcome Screen** that guides you through initial setup:

#### Step 1: Choose Your Language
- Select between **English** or **Українська** (Ukrainian)
- The interface will immediately switch to your chosen language

#### Step 2: Configure Directories
You need to configure two directories:

**1. Mods Folder (Link/Target Directory)**
- This is where 3DMigoto/XXMI loads mods **FROM**
- Usually located at: `XXMI-Launcher/ZZMI/Mods` or similar
- Example paths:
  - `/mnt/games/HoYoPlay/games/XXMI-Launcher/ZZMI/Mods`
  - `C:\Games\XXMI-Launcher\ZZMI\Mods` (Windows)
- **What happens here**: Active mod symbolic links are created in this folder

**2. SaveMods Folder (Storage/Library Directory)**
- This is where you **STORE** your downloaded mods collection
- Can be anywhere on your system
- Example paths:
  - `/home/user/MyZZZMods`
  - `D:\ZZZ_Mod_Collection`
- **What happens here**: Your original mod folders are kept safely here

**💡 How it works:**
```
SaveMods Folder (Your Library)     →     Mods Folder (Active Mods)
├── Ellen_BeachOutfit/             →     [symlink] → Ellen_BeachOutfit/
├── Miyabi_Kimono/                        (inactive, no link)
├── Burnice_Casual/                →     [symlink] → Burnice_Casual/
└── Jane_SchoolGirl/                      (inactive, no link)
```
- Activating a mod = Creating a symbolic link from Mods folder → SaveMods folder
- Deactivating a mod = Removing the symbolic link
- Your original files in SaveMods stay untouched! ✅

#### Step 3: Ready!
- Click **Finish** to complete setup
- You'll see the main screen and can start managing mods

### After Initial Setup

1. **Import mods**:
   - Use Drag & Drop to add mod folders to your SaveMods directory
   - Or press Ctrl+V to paste paths
   - Or click the "+" card to use file picker
   - The app will automatically detect character names from folder names

2. **Activate mods**:
   - Click on a mod card to enable/disable it
   - Enabled mods get a symbolic link created in your Mods folder
   - Use Single/Multi toggle to choose activation mode
   - Press F10 in game (or use auto-reload feature)

3. **Organize by characters**:
   - Click on character avatars to filter mods
   - Drag and drop mods between characters
   - The app auto-tags mods based on folder names

### Understanding the Two Folders

#### 📁 SaveMods Folder (Your Library)
- **Purpose**: Permanent storage for ALL your mods
- **Location**: Anywhere you want (external drive, separate partition, etc.)
- **Contents**: All downloaded mods, organized as you like
- **Safety**: Your original files never change
- **Example structure**:
  ```
  /home/user/MyZZZMods/
  ├── Ellen_BeachOutfit/
  │   ├── EllenBeach.ini
  │   ├── textures/
  │   └── ...
  ├── Miyabi_Kimono/
  │   ├── MiyabiKimono.ini
  │   └── ...
  └── Burnice_Casual/
      └── ...
  ```

#### 🔗 Mods Folder (Active Mods - Links Only)
- **Purpose**: Where 3DMigoto loads mods FROM during gameplay
- **Location**: Inside your XXMI/3DMigoto installation
- **Contents**: Symbolic links ONLY (no actual files)
- **Managed by**: This mod manager (don't manually edit!)
- **Example structure**:
  ```
  /path/to/XXMI-Launcher/ZZMI/Mods/
  ├── Ellen_BeachOutfit → /home/user/MyZZZMods/Ellen_BeachOutfit/
  ├── Burnice_Casual → /home/user/MyZZZMods/Burnice_Casual/
  └── (links to active mods only)
  ```

**Why this system?**
- ✅ No file duplication - saves disk space
- ✅ Instant enable/disable - just create/remove links
- ✅ Safe - original files never modified
- ✅ Organized - keep your library separate from active mods
- ✅ Flexible - move your SaveMods folder anywhere without breaking anything

## ⚡ F10 Auto-Reload

3DMigoto reloads mods when F10 is pressed **inside the game's own window** — it
does not watch the mods folder, so nothing you change on disk is picked up until
that key arrives. The mod manager does it for you: it finds the game's window,
brings it to the front, and presses F10.

### Setup (one-time)

```bash
# Arch/CachyOS
sudo pacman -S xdotool

# Ubuntu/Debian
sudo apt install xdotool
```

That is the whole setup, on **both X11 and Wayland**. The game runs through
Proton, so its window is an X11 window on either session — `ydotool`, the `input`
group and a systemd service are not needed and cannot help, because `ydotool`
has no way to find a window.

Then check that `d3dx.ini` in your ZZMI folder still has 3DMigoto's default
binding:

```ini
reload_fixes = no_modifiers VK_F10
```

### How to Use

- **Reload mods** in the Mods tab presses F10 whenever you ask for it.
- **Automatic mod reload** in Settings presses it after every activate and
  deactivate.

Either way **the game comes to the front**, because a key only reaches the window
that has focus.

### Troubleshooting F10

The app names the step that failed, and the log file records the same thing
(Settings → Diagnostics → Log files):

| What you see | What to do |
|---|---|
| **The game isn't running** | Launch Zenless Zone Zero and leave its window open, not minimized |
| **xdotool isn't installed** | Run the install command above |
| **F10 couldn't be sent** | The game would not come to the front — check it is not minimized |
| **F10 sent**, but nothing changed in game | Check `reload_fixes = no_modifiers VK_F10` in `d3dx.ini` |

The last row is the one to read twice: *F10 sent* means the key reached the game,
not that 3DMigoto reloaded. Nothing outside the game can see whether it did.

## 📖 Usage

### Adding Mods

#### Method 1: Drag & Drop
1. Open your file manager
2. Select one or more mod folders
3. Drag them into the mod manager window
4. Wait for import to complete

#### Method 2: Paste (Ctrl+V)
1. Copy a mod folder path (Ctrl+C in file manager)
2. Switch to mod manager
3. Press Ctrl+V
4. Wait for import to complete

#### Method 3: File Picker
1. Click the "+" card at the end of the mod list
2. Browse and select mod folders
3. Click "Select Folder"

### Managing Mods

#### Single Mode vs Multi Mode

- **Single Mode**: Only one mod can be active per character
  - Automatically deactivates other mods when enabling one
  - Best for character replacements

- **Multi Mode**: Multiple mods can be active per character
  - Enable as many mods as you want
  - Best for accessories, weapons, effects

#### Activating/Deactivating Mods

1. Click on a mod card to toggle its status
2. A mod's on/off state is shown by a toggle on its card
3. The symbolic link is created/removed automatically
4. F10 is sent automatically (if configured)

**Right-click a mod** for more actions: Details, Edit, Rename, Add image, Open source page, Edit keybinds, favorite/unfavorite, and activate/deactivate.

### Character Tags

Tags help organize mods by character. The system automatically detects characters from folder names:

- `Ellen_School_Girl` → Tagged as "Ellen" ✅
- `miyabi_winter_outfit` → Tagged as "Miyabi" ✅
- `Burnice-Casual` → Tagged as "Burnice" ✅

**Manual assignment**: right-click a mod → **Edit** and pick a character or a non-character category (UI, Texture, Audio, Misc) from the searchable picker. You can also drag a mod onto a category in the top bar.

**Bulk auto-tagging**: Go to Settings → Auto-tagging → "Tag all mods" to automatically tag all untagged mods.

### Filtering Mods

- Click a category in the top bar to show only its mods, or **All** to show everything grouped into collapsible per-category sections
- Use the toolbar above the grid to **search** by name, **sort** (Default / Name A–Z / Z–A), **filter by tags** (match any or all), or show **favorites only**

## ⚙️ Configuration

Configuration is stored in: `~/.local/share/zzz-mod-manager/config.json`

### Settings Panel

Access via the ⚙️ button:

- **Mods Path**: Where active mods are loaded from
- **SaveMods Path**: Where your mod library is stored
- **Theme**: Dark/Light/Auto
- **Language**: English/Ukrainian
- **Auto-tagging**: Enable/disable automatic character detection

### Advanced Configuration

You can manually edit `config.json`:

```json
{
  "mods_path": "/path/to/3DMigoto/Mods",
  "save_mods_path": "/path/to/3DMigoto/SaveMods",
  "active_mods": ["mod1", "mod2"],
  "theme": "dark-blue",
  "language": "en",
  "mod_character_tags": {
    "mod_folder_name": "character_id"
  },
  "first_run": false
}
```

## 🔨 Building from Source

### Prerequisites

- Flutter SDK 3.8.1 or higher
- Linux (tested on Arch Linux)
- GTK 3
- GLib 2
- libX11

### Build Steps

```bash
# Clone the repository
git clone https://github.com/NotionMe/Mod-manager.git
cd Mod-manager/mod_manager_flutter

# Get dependencies
flutter pub get

# Run in development mode
flutter run -d linux

# Build release version
flutter build linux --release

# The executable will be in:
# build/linux/x64/release/bundle/mod_manager_flutter
```

### Windows

Windows is supported (`flutter build windows --release`). See
[BUILD_WINDOWS_GUIDE.md](./BUILD_WINDOWS_GUIDE.md) for the full build, installer,
and portable-package steps.

### Build AUR Package

```bash
cd /path/to/Mod-manager
makepkg -si
```

## 🐛 Troubleshooting

### Mods Not Showing Up

1. **Check paths in Settings**:
   - Verify Mods Path points to the correct directory
   - Verify SaveMods Path contains your mods

2. **Check folder structure**:
   - Mods should be in individual folders
   - Each folder should contain mod files (INI, DDS, etc.)

3. **Restart the application**:
   - Sometimes a restart helps refresh the mod list

### Mods Not Activating in Game

1. **Verify 3DMigoto is working**:
   - Check if other mods work
   - Look for the 3DMigoto overlay (usually top-left)

2. **Check symbolic links**:
   ```bash
   ls -la /path/to/Mods/
   # Look for symbolic links (shown with ->)
   ```

3. **Press F10 in game**:
   - 3DMigoto needs F10 to reload mods
   - Use the auto-reload feature for convenience

### F10 Auto-Reload Not Working

1. Verify xdotool is installed: `which xdotool` — the same answer on X11 and
   Wayland
2. Check the game window can be found: `xdotool search --onlyvisible --name Zenless`
3. Ensure the game window is not minimized
4. Read the newest file in Settings → Diagnostics → Log files for the reason

### Application Crashes

1. **Check logs**:
   ```bash
   journalctl -xe
   ```

2. **Run from terminal** to see errors:
   ```bash
   zzz-mod-manager
   ```

3. **Clear config** (backup first!):
   ```bash
   mv ~/.local/share/zzz-mod-manager/config.json ~/.local/share/zzz-mod-manager/config.json.bak
   ```

### Permission Issues

```bash
# Ensure you have write permissions to mod directories
chmod -R u+w /path/to/Mods
chmod -R u+w /path/to/SaveMods
```

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

### How to Contribute

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

### Development Guidelines

- Follow Dart/Flutter best practices
- Maintain the existing code style
- Add comments for complex logic
- Test your changes thoroughly
- Update documentation as needed

## 📝 License

This project is licensed under the MIT License - see the LICENSE file for details.

## 🙏 Acknowledgments

- Built with [Flutter](https://flutter.dev/)
- Icons and assets from the Zenless Zone Zero community
- Thanks to all contributors and users

## 📞 Support

- **Issues**: [GitHub Issues](https://github.com/NotionMe/Mod-manager/issues)
- **Discussions**: [GitHub Discussions](https://github.com/NotionMe/Mod-manager/discussions)
- **Email**: c.ubohyi.stanislav@student.uzhnu.edu.ua

## 🔗 Links

- [GitHub Repository](https://github.com/NotionMe/Mod-manager)
- [AUR Package](https://aur.archlinux.org/packages/zzz-mod-manager-git)
- [Zenless Zone Zero](https://zenless.hoyoverse.com/)

---

**Enjoy modding!** 🎮✨
