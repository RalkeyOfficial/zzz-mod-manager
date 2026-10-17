# TODO

Work that is still to be done. Design rules and decisions live in [`docs/`](docs/README.md), never here: when an item is done, the line is removed, and anything worth keeping about it goes into the doc that owns its area.

## Fix

- [ ] **The resolve dialogs can show the files of the wrong mod page.** Picking a mod page loads its files (`_loadRecord` in both `resolve_origin_dialog.dart` and `companion_resolve_dialog.dart`). Pick page A, press Change while its files are still loading, and pick page B: A's answer can land last, so the file list shows A's files under B. The only guard is `mounted`. The fix: in both dialogs, drop any answer for a page that is no longer the current pick.
- [ ] **37 character portraits are WebP files named `.png`** (for example `alice.png` and `seth.png` in `mod_manager_flutter/assets/characters/`). They display fine, because Flutter reads what's in the file, not its extension, but the name lies about the format and newer portraits are real PNGs. They also come in many sizes, from 200×200 to 384×384. The fix: convert them to real PNGs at 256×278, the size most real PNGs use (`belle`, `orphie` and `wise` are real PNGs at other sizes).
- [ ] **`mod_manager_flutter/CLAUDE.md` has an outdated rule about character aliases.** It says to update the `characterAliases` map in two places in `mod_manager_service.dart` when adding a character. That map no longer exists: characters are recognised only through the roster in `utils/zzz_characters.dart`. The fix: rewrite the rule to say adding a character means adding it to the roster, with any aliases, plus its portrait.
- [ ] **Three old keybind guides in `mod_manager_flutter/` describe code that is gone.** `KEYBINDS_README.md`, `KEYBINDS_INTEGRATION_GUIDE.md` and `KEYBINDS_SUMMARY.md` still cover character-level keybinds, which were removed because keybinds belong to a mod. The fix: delete them, or fold anything still true into a doc.
- [ ] **The translation test misses keys that nothing uses any more.** `test/l10n_keys_test.dart` checks that every key the code uses exists in `en.json` and `uk.json`, but not the other way round, so a key left behind by deleted UI passes. Its header comment claims it catches those. The fix: add the reverse check, or correct the comment.
- [ ] **On Linux the app falls back to `7za` and `7zr`, which can't read `.rar` files.** `ArchiveService` (`archive_service.dart:533`) tries `7z`, `7za` and `7zr` on PATH, and the `PKGBUILD` comment names all three. Only `7z` handles every import, and the AUR package already depends on `7zip`, which ships it. The fix: drop `7za` and `7zr` from both.

## Build

- [ ] **Give the portable build its icon with nothing to install.** The app's toolkit (GTK 3) can't set a window icon on Wayland, so today the portable build needs a one-command setup that installs a desktop entry. The app could set the icon itself from `linux/runner/` through the `xdg_toplevel_icon_v1` protocol, and the setup step would go away. **Waiting on** a compositor here that supports the protocol, so it can be tested. Until then the desktop entry stays, and it remains the fallback afterwards. [`docs/desktop-integration.md`](docs/desktop-integration.md) §3 has the steps.
- [ ] **Warn when two enabled mods change the same character.** In Multi mode, two skins for one character can be on at once, and ZZMI loads both, so they fight over the same model. Single mode avoids it by switching the character's other skins off. The fix: mark the clash on the cards, or warn when the second one is switched on.
- [ ] **Profiles (undecided).** A profile is a named set of which mods are on across the whole library, such as "Story" or "Photos". Switching to one turns exactly that set on and everything else off, in one click. It would have its own sidebar tab with a page that lists the profiles. It saves only which mods are on, because a mod's in-game settings belong to ZZMI. It is only worth building if swapping between whole sets of mods is common enough that toggling them one by one gets tiresome.

## UI redesign

- [ ] **Redesign the whole UI from scratch.** Until then, layout and polish bugs are left alone, because a fix would be thrown away. These are waiting on it:
  - [ ] A marketplace file row overflows at 1.6× text scale, because the scan chip and the Download button can't shrink. Seen at 530px and 600px window widths.
  - [ ] Some elements look too large or too small at the app-wide 16px type scale, for example the Single/Multi toggle's label is too large for its box. Pick a text role per element during the redesign, never a `fontSize:` literal.
