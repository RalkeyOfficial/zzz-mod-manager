# Shader fixes — mods that replace the game's shaders

**Scope:** how a mod's shader replacement files reach ZZMI while the mod is on and leave when it is off.
Owns `services/shader_fixes/` (the folder lookup, the planner, the service), the ZZMI-root archive layout in `ArchiveService`,
and `screens/components/shader_fixes_notices.dart`.

Not in scope: shaders a mod loads by reference from its own `.ini` (`CustomShader`, `ShaderRegex`),
which live in the mod folder and are ordinary mod files ([`applying-updates.md`](applying-updates.md) §1).

---

## 1. How ZZMI finds a shader replacement

ZZMI is 3DMigoto, and 3DMigoto reads replacements from exactly one folder:
the `override_directory` named in `[Rendering]` of `d3dx.ini`, relative to the ZZMI root. ZZMI's own `d3dx.ini` sets it to `ShaderFixes`.

- **By exact filename, never by listing.** When the game creates a shader, the loader builds `<16-hex hash>-<vs|ps|cs|gs|hs|ds>` plus
  `_replace.bin`, `.bin`, `_replace.txt` or `.txt`, in that order, and opens it. Subfolders are never searched;
  they exist only as `#include` targets for the `.txt` files (JiggleForge ships `ShaderFixes/JiggleForgeRuntime/`).
- **Nothing in `Mods/` is a replacement.** `Mods/` is read for `.ini` files only, so a `ShaderFixes/` inside a mod folder is inert.
  That is what makes it a safe place to keep a mod's shader files while the mod is off.
- **A `.bin` is used only when its modification time equals its `.txt`'s.** Otherwise the `.txt` is compiled at runtime.
  A `.bin` with no `.txt` beside it is used as it is.
- **ZZMI writes into the folder itself.** With `cache_shaders = 1` it writes a `.bin` beside every `.txt` it compiles,
  and shader dumping writes `.txt` files. So not every file in the folder was put there by a person.
- **One file per hash.** Two mods replacing the same shader collide on one filename, and the last one copied wins.
- **A new replacement needs a game restart.** F10 reloads replacements that changed, but it picks up a newly added one only while hunting is on.
- **The ZZMI root is the parent of the links folder.** The links folder is ZZMI's `Mods/`, with `d3dx.ini` beside it.

## 2. What mods ship, and how an install lays it out

Measured 2026-09-26 from `_aArchiveFileTree` on every current file: all of Other/Misc (269 mods), UI (286), Bangboo Skins (49),
and a random 600 of the 4,993 Character Skins.

| Category | Mods with shader files | Shaders and an `.ini` in one archive | In separate files | Shaders only |
|---|---|---|---|---|
| Other/Misc | 27 | 26 | 1 | 0 |
| UI | 9 | 9 | 0 | 0 |
| Character Skins (sample) | 9 | 9 | 0 | 0 |
| Bangboo Skins | 0 | – | – | – |

**No shader fix ships without an `.ini`**, so a shader fix is part of a mod rather than a separate kind of thing:
one library folder, one switch, one update, one snapshot. The mod's shader files live in `<mod>/ShaderFixes/`.

Only a folder named `ShaderFixes` marks files for the shader folder. A hash-named file elsewhere in a mod,
such as Custom Loading Screen's `ps/a9d9418078d93839-ps_replace.txt`, is loaded by the mod's own `.ini` and stays an ordinary file.

Where the folder sits in an archive varies, and import (`ArchiveService._prepareDirectoriesForImport`) handles each:

| Archive layout | Seen in | Lands as |
|---|---|---|
| `<mod>/ShaderFixes/` | Vivian Summer | as it is |
| an `.ini` and `ShaderFixes/` at the root | Remove Character Screen Shadow | one mod named after the archive |
| `Mods/<mod>/` and `ShaderFixes/` | JiggleForge | `<mod>/ShaderFixes/` |
| an `.ini` directly in `Mods/`, and `ShaderFixes/` | No Outlines | one mod named after the archive |
| `ShaderFixes/` and a readme | Censor Remover | one mod holding only `ShaderFixes/` |
| several mods and one `ShaderFixes/` | multi-character effect packs | each mod, plus `<archive> ShaderFixes` as a mod of its own |

Beside several mods the shader files become their own mod rather than joining one, because nothing says which mod they belong to,
and a guess would tie one mod's switch to another's shaders. A shader-only folder counts as a mod: the import picker preselects it,
and it raises no "no `.ini`" warning.

Import keeps each file's time from the archive, and copying into the library keeps it too, so a shipped `.bin` stays valid (§1).
Zip entries written with `\` are split into folders, since a Windows filename cannot contain one.

## 3. Switching a mod on

`ModManagerService.activateMod` places the mod's shader files before it creates the link, so a refusal leaves the mod off.

- Every file under `<mod>/ShaderFixes/` is copied to the same relative path in the shader folder, subfolders included,
  and given the source's modification time.
- **All or nothing.** If any target already exists and this mod did not place it in this folder, nothing is copied.
  The enable fails with `ShaderPlacementRefused`, naming the mod that placed the file, or saying no mod did.
- What is already there comes from one listing of the folder, compared case-insensitively.
  Probing each name with `exists()` would miss a file that differs only in case on Linux, which ZZMI under Wine treats as the same file.
- **Asked before anything else changes.** The card toggle calls `checkActivation`, a dry run, before Single mode switches the character's other skins off,
  so a refused enable leaves the skin that was on still on.
- A record naming another mod for a file that is no longer there is stale and does not block.
- With no `d3dx.ini` beside the links folder there is nowhere trustworthy to copy to, so a mod with shader files is refused.
  Mods without any are unaffected.
- Copies, not links: a Windows file symlink needs Developer Mode, and ZZMI's `.bin` caches would be written through a link into the library.

## 4. Switching a mod off

`deactivateMod` removes the link, then the shader files. `deleteMod` does the same before deleting the folder.

- Removal works in the folder each file was placed in, which is not necessarily the one the links folder points at now.
- A placed file is deleted only while its md5 still matches what was copied. A file changed since is left in place and forgotten,
  after which it counts as not placed by the app.
- **The `.bin` beside a deleted `.txt` goes too**, whatever its bytes, unless another mod placed it.
  ZZMI writes that cache itself, and a lone `.bin` keeps the shader applied after the mod is off.
- Folders the deleted files were in are removed once empty. The shader folder itself never is.
- Nothing else is touched: ZZMI's `Sucrose.png`, shader dumps, and files copied in by hand stay.
- With the ZZMI folder missing, nothing is removed and the record is kept, so the files are taken out once it is back.

## 5. The record

`<appData>/shader_fixes.json` lists each placed file: the absolute shader folder it went into, its path relative to that folder,
the owning mod's uid, its folder name at the time, and the md5 copied. It is per-install state, so it lives in app data and never in the sidecar, which describes the mod and travels with it.

- Keyed by uid, so renaming a mod changes nothing. A duplicated mod folder shares its uid and therefore its placements ([`ModUid`](../mod_manager_flutter/lib/services/mod_uid.dart)):
  switching either copy off removes the shader files while the other copy is still on.
- Ownership counts only in the folder a file was placed in. Pointed at a second ZZMI install, a file of the same name there is not one the app placed.
- Paths compare case-insensitively, since ZZMI runs on Windows or under Wine.
- Written to a temporary file and renamed over. Unreadable reads as empty, so previously placed files block a conflicting enable instead of being overwritten.

## 6. Where it runs

Every way a mod is switched on or off goes through `activateMod` / `deactivateMod`: the card toggle, Single mode, clearing all mods,
and updates, reinstalls and patch installs, which switch an enabled mod off before writing and back on after (`ModActivationPort`).
A refusal on the way back on after an update leaves the mod off. The update result does not claim it was switched back on,
and the refusal is shown as the same notice the card toggle gives, since nobody pressed anything to be told.

`ShaderRestartNoticeHost`, mounted above the tabs, says once that the game needs a restart whenever placed files changed,
naming the mods. Changes arriving together, like an update's off-and-on, become one notice.

## 7. Known and not built

- **Files the user copied in by hand are never adopted.** They block a conflicting enable, with a message saying so.
- **Shader files in a folder with another name** ("PUT THESE IN SHADERFIXES") are imported as ordinary mod files.
  Import could offer to treat hash-named files no `.ini` references as shader files.
- **The XXMI Launcher renames some `.ini` files in the shader folder** on every launch (`help.ini`, `mouse.ini`, `upscale.ini`,
  `3dvision2sbs.ini` become `DISABLED_<name>`). A mod shipping one of those names leaves the renamed copy behind when switched off.
- Placed copies are not counted in the Storage tab; they live in the ZZMI folder, not the app's.
- Not verified on Windows.
