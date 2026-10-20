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
- **The user picks the ZZMI root.** Settings ask for the ZZMI folder, the one holding `d3dx.ini`, and the links folder is its `Mods/` ([`configuration.md`](configuration.md#picking-the-zzmi-folder)).

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

A folder named `ShaderFixes` marks files for the shader folder, and so does a **shader folder under another name**, such as Move Agents in Menu's `PUT THESE IN SHADERFIXES`.
A folder is one when all four hold:

- its name contains "shader", in any case;
- it directly holds a shader replacement file, named as in §1: a 16-hex hash, the stage, an optional `_replace`, and `.txt` or `.bin` (`isShaderReplacementName`);
- it directly holds no `.ini`, since a folder that does is a mod;
- no `.ini` refers to a path inside it: one in the mod, or anywhere in the archive for a folder at its root. Paths compare case-insensitively.

Measured 2026-10-16 from `_aArchiveFileTree` on 1,224 mods (1,892 files): 50 folders other than `ShaderFixes` hold shader replacement files.
2 of them have "shader" in the name, both meant for ZZMI, and no `.ini` refers into either.
The other 48 include folders the mod's own `.ini` loads, such as Custom Loading Screen's `ps/a9d9418078d93839-ps_replace.txt`, `vs/`, `other/vs`, `res/`, `Living/` and `LayeringSolution/`; none has "shader" in its name, so all stay ordinary files.
ReShade folders named `Shaders` or `reshade-shaders` hold no replacement file and stay ordinary too.
The name is what tells the two kinds apart, and the `.ini` check keeps a folder a mod loads from itself ordinary even when it is called "shaders".
Nothing is asked. In the import picker, a mod whose shader files came this way names the folder they came from.

Shader replacement files and every subfolder move to `<mod>/ShaderFixes/`, subfolders because they are `#include` targets, and renaming keeps each file's time.
Any other file, such as a readme, stays in the mod under the folder's own name and never reaches `ShaderFixes/`: placement is all or nothing on differing bytes (§3), so two mods each placing a `readme.txt` there could never both be on.
No readme was found inside any shader folder or `ShaderFixes/` in the measurement.
A mod that already has a `ShaderFixes/` keeps the other folder as ordinary files, and of several such folders in one mod only the first by name moves, so two sets are never merged.

Where the folder sits in an archive varies, and import (`ArchiveService._prepareDirectoriesForImport`, then `_moveShaderFoldersIn` over every mod it produced) handles each:

| Archive layout | Seen in | Lands as |
|---|---|---|
| `<mod>/ShaderFixes/` | Vivian Summer | as it is |
| an `.ini` and `ShaderFixes/` at the root | Remove Character Screen Shadow | one mod named after the archive |
| `Mods/<mod>/` and `ShaderFixes/` | JiggleForge | `<mod>/ShaderFixes/` |
| an `.ini` directly in `Mods/`, and `ShaderFixes/` | No Outlines | one mod named after the archive |
| `ShaderFixes/` and a readme | Censor Remover | one mod holding only `ShaderFixes/` |
| several mods and one `ShaderFixes/` | multi-character effect packs | each mod, and each without a `ShaderFixes/` of its own gets a copy |
| `<mod>/PUT THESE IN SHADERFIXES/` beside `<mod>/PICK ONE AND PUT IT IN MODS/<variant>/` and readmes | Move Agents in Menu | one mod with `ShaderFixes/`, its readmes and both variant folders |
| a shader folder under another name at the root, beside mod folders | – | as a root `ShaderFixes/` would, in the rows above |

At the root, a shader folder under another name is used only when there is no root `ShaderFixes/`, and only the first by name; any other stays a folder of its own, as it would be without this rule, and takes no copy.
Moved into a mod that already holds a folder of that name in any case, it is numbered (`Shaders (2)`), since ZZMI reads the two spellings as one folder; the import picker still names it as it is in the archive.

Beside several mods, each mod with no shader files of its own gets a copy, because nothing says which of them needs the files, and picking one would tie the others' shaders to its switch.
A mod that already has a `ShaderFixes/`, or a shader folder under another name that becomes one, keeps it as it is, since merging a second set into it risks two files of one name.
The copies are identical, so the mods can be on together, and the files leave ZZMI's folder with the last of them (§4).
Only a set no mod can take, because every mod already has shader files of its own, becomes a mod named `<archive> ShaderFixes`.
A shader-only folder counts as a mod: the import picker preselects it, and it raises no "no `.ini`" warning.

Import keeps each file's time from the archive, and copying into the library keeps it too, so a shipped `.bin` stays valid (§1).
Zip entries written with `\` are split into folders, since a Windows filename cannot contain one.

Updates, reinstalls and patch installs unpack through the same import, so a mod in the library gets its shader folder sorted on its next update.
A mod whose install recorded a root shader folder as a mod of its own finds no folder of that name in the archive any more ([`applying-updates.md`](applying-updates.md) §4):

- Beside several other mods, its update or reinstall reports a changed layout, and the user picks its folders once in the update's folder picker.
- Beside exactly one other mod, that mod's folder reads as the shader folder renamed upstream. Updating or reinstalling the shader mod on its own then writes the other mod's files into it without asking; updated together with that other mod, both are refused, since they claim one folder of the archive.

## 3. Switching a mod on

`ModManagerService.activateMod` places the mod's shader files before it creates the link, so a refusal leaves the mod off.

- Every file under `<mod>/ShaderFixes/` is copied to the same relative path in the shader folder, subfolders included,
  and given the source's modification time.
- **A target already holding the same bytes is used as it is**, not copied. When another mod placed it, this mod joins it.
  When the app does not know it, such as a file the user copied in by hand, it is adopted as external: the mod uses it and the app never deletes it (§4).
  A known file whose bytes changed since it was placed counts as unknown, so joining it marks it external too.
  One notice names the mod and says the files stay when it is off. The md5 is the proof, so nothing is asked.
- **All or nothing.** If any target holds different bytes, nothing is copied, unless the file is this mod's own earlier version and untouched since.
  The enable fails with `ShaderPlacementRefused`, naming the mod that placed the file, or saying no mod did, and the notice lists only the files that differ.
- What is already there comes from one listing of the folder, compared case-insensitively.
  Probing each name with `exists()` would miss a file that differs only in case on Linux, which ZZMI under Wine treats as the same file.
- **A link is never written through.** A link in the shader folder, live or dangling, at a target or as a folder on the way to one, is a conflict no mod placed, even when the file behind it holds the same bytes: a copy would write into a file the app did not place, wherever the link points. The notice says a link is in the way.
  Right before each file is written its path is checked for a link again, and one found then fails the copy as a copy that fails partway does.
- **Asked before anything else changes.** An enable from the library (`ApiService.enableMod`) calls `checkActivation`, a dry run, before One at a time switches the character's other mods off,
  so a refused enable leaves the mod that was on still on.
  The dry run does not count files held by the mods about to be turned off as free, so two mods with a shader file at the same path and different contents can't be swapped by turning the second on: it is refused, naming the first. A file at the same path with the same bytes is shared, and does not stop the swap ([`library-screen.md`](library-screen.md) §10).
- A record naming another mod for a file that is no longer there is stale and does not block. When that mod needed the same bytes, it keeps its hold on the copy put back, since the copy restores its shader too.
- A copy that fails partway leaves the mod off, and whatever it had copied or taken hold of is let go of again, as when its link cannot be made. What the mod's identity held before, such as a duplicated folder's files while that copy is on, stays.
  The file being written when the copy failed is not in the record yet, so it is deleted on the spot when it is the placement's own: a file that was not there before, or the mod's own earlier version once the copy has changed its bytes. Folders the delete leaves empty are removed too, as on a disable (§4). A file the app did not place, or a link, is never touched, and an earlier version the copy did not reach stays.
- Only targets that already exist are hashed, so an enable into an empty folder reads nothing but the mod's own files.
- With no `d3dx.ini` in the ZZMI folder there is nowhere trustworthy to copy to, so a mod with shader files is refused. Settings warn about this when the folder is picked, but do not block it.
  Mods without any are unaffected.
- Copies, not links: a Windows file symlink needs Developer Mode, and ZZMI's `.bin` caches would be written through a link into the library.

## 4. Switching a mod off

`deactivateMod` removes the link, then the shader files. `deleteMod` does the same before deleting the folder.

- Removal works in the folder each file was placed in, which is not necessarily the one the links folder points at now.
- **A file stays while anyone else holds it**: another mod that is on, or the user, when it was adopted as external. The mod only lets go of it.
- A file nobody else holds is deleted only while its md5 still matches what was copied. A file changed since is left in place and forgotten,
  after which it counts as unknown to the app.
- **The `.bin` beside a deleted `.txt` goes too**, whatever its bytes, unless someone else holds it.
  ZZMI writes that cache itself, and a lone `.bin` keeps the shader applied after the mod is off.
- **A placed `.ini` the XXMI Launcher renamed goes under its new name.** On every launch the Launcher walks the shader folder and renames `help.ini`, `mouse.ini`, `upscale.ini` and `3dvision2sbs.ini` to `DISABLED_<name>`, or `DISABLED_<stem>_<n>.ini` when that name is taken.
  When a placed `.ini` is gone, one copy of that shape in the same folder with the placed md5 is deleted instead.
  This covers any `.ini`, so it holds if the Launcher's list grows. Two identical copies mean ZZMI's own disabled file had the same bytes, so deleting either leaves the folder as it was before the mod; the highest counter goes.
  A copy with other bytes stays, and ZZMI never loads a `DISABLED_` file, so deleting one raises no restart notice.
- A file is forgotten only once its delete succeeded. One that could not be deleted, such as a file ZZMI holds open on Windows, stays in the record under this mod, so the next enable and disable takes it out.
  Deleting the mod forgets it anyway, since no mod is left to let go of it.
- Folders the deleted files were in are removed once empty. The shader folder itself never is.
- **A link is never deleted.** One put where a placed file was reads as that file gone, so the entry is forgotten and the link stays, and one where a cache or a renamed `.ini` would be is not looked at. Each delete checks its path for a link right before.
- Nothing else is touched: ZZMI's `Sucrose.png`, shader dumps, and files copied in by hand stay.
- With the ZZMI folder missing, nothing is removed and the record is kept, so the files are taken out once it is back.

## 5. The record

`<appData>/shader_fixes.json` lists each file the app keeps track of: the absolute shader folder it is in, its path relative to that folder,
the md5 its holders need, every holding mod's uid with its folder name at the time, and whether it is external, meaning it was already there.
It is per-install state, so it lives in app data and never in the sidecar, which describes the mod and travels with it.

- Holders are uids, so renaming a mod changes nothing. A duplicated mod folder shares its uid and therefore its holds ([`ModUid`](../mod_manager_flutter/lib/services/mod_uid.dart)):
  switching either copy off removes the shader files while the other copy is still on.
- Each holding uid also maps to the mod folder its files were last placed from, which is how a copy whose folder can't be read, such as one on an unplugged drive, is still known by the path its link names (§6).
  Every placement sets it, and it follows a rename of the mod and a library change that moves the mod. A holder with no folder recorded is never matched by a guessed one.
  A duplicated folder shares its uid, so the path is the copy that placed last. A copy on an unplugged drive that was not the last to place is therefore not recognised: turning a mod on over its link takes none of the files out, and a conflict with them refuses the enable. The files are the other copy's too, and they go when that copy is turned off.
- An entry counts only in the folder its file is in. Pointed at a second ZZMI install, a file of the same name there is not one the app knows.
- Losing app data makes every placed file unknown. The next enable of each mod adopts those of its files still identical as external, so they stay in place from then on; one the mod has since changed refuses the enable.
- Paths compare case-insensitively, since ZZMI runs on Windows or under Wine.
- Written to a temporary file and renamed over. Unreadable reads as empty, so previously placed files block a conflicting enable instead of being overwritten.

## 6. Where it runs

Every way a mod is switched on or off goes through `activateMod` / `deactivateMod`: the card, details panel and mod page switches, the All mods table's bulk Enable and Disable, One at a time, clearing all mods, and updates, reinstalls and patch installs, which switch an enabled mod off before writing and back on after (`ModActivationPort`).
A refusal on the way back on after an update leaves the mod off. The update result does not claim it was switched back on, and the refusal is shown as the same notice the card toggle gives, since nobody pressed anything to be told.

A change of the Mod library re-points links without switching anything off. A copy in the new library with another identity than the old one places its shader files first, as an enable does, and a refusal leaves its link as it was.
Once its link has followed, the old copy's shader files are taken out as its disable would, so only the new copy's load, unless another working link in the links folder still leads to it; a file both copies ship with the same bytes stays, held by the new copy. An old copy whose folder can't be read is known by its recorded folder (§5), and with none recorded its files stay.
A link that can't be changed lets go only of what the new copy's placement took hold of, never of what the mod still on in the old library placed ([`configuration.md`](configuration.md#changing-the-mod-library)).

Turning a mod on over a link of its name into another copy, such as one in a library the link still points into, takes that copy's shader files out as its disable would, when its identity is known and differs from this mod's. A copy with the same identity, such as a duplicated folder, shares its holds, so nothing is taken out.

- **The identity is read from the copy's folder.** For one that can't be read, such as one on an unplugged drive, it is the holder whose recorded folder (§5) is the link's target, when exactly one is. A link on an unplugged drive does not load the mod, so its shader files going is what the game needs.
- **With no identity known, nothing is taken out**, as for a copy the record keeps no folder for. A conflict with its files then refuses the enable, and since the holder has this mod's name, the notice says another copy of the mod, in a folder the app can't read, placed them.
- **A copy another link still keeps on keeps its files.** When another working link in the links folder leads to that copy's folder, or to a folder with its identity, such as one made by hand, nothing of it is taken out. A conflict with its files refuses the enable, and the notice names that link. A library change keeps the old copy's files the same way.
- **Renaming a mod that is on onto a dead link of the new name** takes the shader files of the copy that link led to out once the new link is made, by the same rules. A rename left off under its new name, because its link can't be made and its folder can't be renamed back, takes its own files out as turning it off would.

- **Without a conflict, its files go once this mod is on**, as a library change does: this mod's are placed, the link follows, then the other copy's are taken out. The game is never left with neither set, and a file both copies ship with the same bytes stays, held by this mod.
- **When the other copy's own files are what differ**, they have to go before this mod's can be placed. The dry run (§3) first plans the enable as if they were gone, so a refusal for any other file, such as one another mod placed, changes nothing and names only that file. Otherwise the other copy's files are taken out, this mod's placed, and the link made.
- **If any of that fails**, this mod's placement is let go of and the other copy's files are placed again from its folder, still held by it, so the game is back to the other copy with its link as it was.
  Each file goes back on its own. One whose place is taken, such as a file the user edited, which taking the copy's files out left where it was, is skipped rather than overwritten, and the rest still go back. A file that was taken out and could not be put back, as on a full disk or with the copy's folder unplugged, is logged and named in a warning.

`ShaderRestartNoticeHost`, mounted above the tabs, says once that the game needs a restart whenever placed files changed,
naming the mods. Changes arriving together, like an update's off-and-on, become one notice.

## 7. Known and not built

- **A shader folder inside a zip inside the archive** (Recolored Aegis addon) is not looked into: import unpacks one level, so the inner zip lands as an ordinary file and turning the mod on places nothing.
- **A folder dragged in, rather than an archive,** is installed as it is; only an unpacked archive goes through the shader-folder rule.
- **A "shader" folder the mod loads in any other way is moved.** Only an `.ini`'s `filename`, `include` and `include_recursive` lines hold a folder back, and a `filename` in a resource section nothing uses does not, so a folder loaded through `CustomShader`, `ShaderRegex` or any other key ends up in `ShaderFixes/` and the mod no longer finds it there; the measurement found no such folder.
- Placed copies are not counted in the Storage tab; they live in the ZZMI folder, not the app's.
- Not verified on Windows.
