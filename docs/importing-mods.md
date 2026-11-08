# Importing mods

**Scope:** what happens between a folder or archive being dropped or pasted and the mod being in the library — the order of the questions, the review step that shows each mod's name and character before anything is copied, Keep both, Update it, Turn on after import, and the progress dialog.
What a download from Browse does on the way in is [`marketplace.md`](marketplace.md) §5, and what is written over an installed mod when its author publishes a newer file is [`applying-updates.md`](applying-updates.md). This document stands on both, and Update it is the place they meet.

## 1. The order of the flow

A drop on the Library or the All mods table and Ctrl+V reach one function, and it asks in this order:

1. **Collect.** Every dropped or pasted path that is a folder or a `.zip`, `.7z` or `.rar` archive. A path that is neither is ignored.
2. **Passwords.** Every archive is listed before any is unpacked, and a locked one asks for its password. A password that is not given ends that archive's import.
3. **Unpack.** Every archive is unpacked to a temp directory before any question about it, so the Working card is down before the first question opens.
4. **Already installed.** An archive whose md5 matches a file the library already holds asks whether to install it again. It is a question about the archive, so it comes before anything about the mods in it.
5. **Folders.** Only when what came out holds more than one folder: which of them to install, and whether they become separate mods or one. It decides how many mods the next step lists.
6. **Review.** One row per mod about to be created, for every drop ([§2](#2-the-review)).
7. **Patch.** A folder that looks like a patch asks where it goes ([`origin-tracking.md`](origin-tracking.md) §10).
8. **Write.** The blocking Importing dialog is up. New mods are copied, then each Update it is written ([§5](#5-update-it)), then patches into existing mods.
9. **Turn on**, for the new mods, when the switch is on ([§6](#6-turn-on-after-import)).
10. **Report.**

Nothing is written before step 8. Cancelling at any question deletes the temp directories and leaves the library as it was, and a consumed archive is deleted only once its mod is installed.

The review comes after the folders question because that answer decides how many rows there are, and before the patch question because the review settles each mod's final name, which the patch question then uses to name it.
A row the user sets to Update it leaves the patch question: the user has said what that folder is for, and asking where it goes as well would give it two answers.

A download from Browse is not reviewed. The user picked a mod page and a file, so the name comes from the folder the archive holds and the character from the page, and the Library shows the result.

## 2. The review

The review is shown for every drop, a single folder with a known character and no clash included. The name and the character are guesses, and without the review the user sees them only once the mod is in the library.
Keeping the step out of the easy case would mean deciding which guesses are good enough to skip, and the dialog is one Enter away when they are right.

A row is the mod that will exist, not the folder that was dropped. A drop of three folders installed separately has three rows; the same three combined into one mod have one, named after the combined mod.

| Part | Rule |
|---|---|
| Source line | The archive's file name or the folder's, and the size of what will be copied in, which is the unpacked folder's for an archive too, so every row is measured the same way. |
| Character | The character the user dropped on, when they dropped on one they picked. Otherwise the app's guess from the name and the archive's name. Otherwise no answer, drawn in the amber needs-a-choice look. Unassigned is an answer. |
| Name | The folder the mod will be, defaulting to the dropped folder's name. It follows the rename rules (no `\ / < > : " | ? *`, no leading `.` or `__`), checked as the user types. |

Importing is enabled when every row has a character and no row has an empty, invalid or repeated name. The button names how many mods the press will write, updates included. While it is disabled, a line under the card names the first row that stops it, and how many more do.

**A name clash is library-wide.** The library is flat, so a folder of that name exists whatever character it is filed under, and the check ignores letter case, as the filesystem of the other platform would. Two rows with the same name are told apart the same way, and stop the import until one changes.
Where the filesystem tells `Foo` and `foo` apart and the library holds both, a row matches the folder spelled exactly like it. A name spelled a third way matches neither, rather than one picked at random, and is a new mod.

The guess is drawn as a plain answer the user can change, never locked in. Dropping on a character the user picked is the user saying where, and it replaces the guess.

## 3. A mod the user already has

A row whose name matches a folder in the library says so, with the character it is filed under and the date it was installed, and offers two answers: **Update it** and **Keep both**. Update it is selected.

That default is the user's decision. The argument against it is that a guess must never drive a write, and a name match is a guess. It is held anyway for three reasons: the user dropped the files and the dialog is the user being present, the dropped mod has the name of the one they have so an update is the likelier intent, and the snapshot taken before the write is the way back. Keep both is one press away and leaves the library as it is.

A mod whose folder is being written at that moment cannot be updated, so the segment is off for that row and the row says why. Keep both still works.

The check is made again when the update starts, since a write can begin on that mod from another screen while the review or the patch question is open, and the copy of the new mods runs first. A row whose mod is busy then is **skipped, not turned into Keep both**: a card names the mod and says the dropped files were not written into it, and the other rows go ahead. Keep both would install the mod under a new name after the user chose Update it, which is a second decision made for them, and the files are one drop away when the other write is done.

## 4. Keep both

The dropped mod is installed as a second folder named after the first free `Name (2)`, `Name (3)` and so on, free meaning not in the library and not a name another row will take. The row shows the name it will get. The existing mod is not touched.

## 5. Update it

Update it writes the dropped folder into the existing mod's folder, and it is an update in the sense of [`applying-updates.md`](applying-updates.md) §1 and nothing less: the same order, the same refusals, and the same safety argument. The existing mod is **not swapped for the dropped folder**. The folder stays where it is and is rewritten in place.

**What it does, in order:**

1. The mod is turned off for the duration (open file handles only) and put back exactly as it was.
2. **A snapshot of the whole folder is taken.** If it cannot be, nothing is written.
3. **Everything but the sidecar is deleted.** No file is kept because it looks like the user's, none is removed because it looks old, and nothing is overwritten file by file. What the folder holds afterwards is the dropped folder's contents and nothing of the old version, and a hand edit goes with it into the snapshot ([`applying-updates.md`](applying-updates.md) §1).
4. **The dropped folder's contents are copied in.** For a drop of several folders combined into one mod, each goes into a subfolder named after it, as a combined install lays them; two with the same name take `Name`, then `Name (2)`, so neither loses its files. A `.zzz-mod-manager/` inside the dropped folder is never copied, since it would replace the user's own metadata with a stranger's.
5. **A recorded patch is put back** on the new layout, by placement, as for any base update. When the patch is recorded and the placement cannot be settled, nothing is written, because a patch with nowhere to go is not a reason to lose it. When a patch is on the folder and its files are not recorded, it goes with the old version, and the row says so before the write.
6. The mod is turned back on if it was on.

The folder keeps its name, its active link, its favourite, note, character, cover, tags and description. The sidecar's origin block is the one thing that changes ([§5.1](#51-what-the-mod-is-recorded-as-afterwards)). Edit info's key changes are replaced with the author's, as after any update.

**The layout is the user's answer, not a replay.** An update from a download replays the layout recorded at install because there is an archive to compare it with and the user has already answered that question once. A dropped folder has nothing to compare: it is the mod, as the folders step and the drop itself established. So the mapping is built from the review rather than from the recorded `ingest`, and the record is rewritten to match it, so a later update from GameBanana replays what was just written.

Update it takes the existing mod's character, and the pill on that row shows it. The pill changes the mod's character only if the user changes it. A guess from the dropped name never moves a mod the user filed somewhere else.

### 5.1 What the mod is recorded as afterwards

The origin block says which remote mod the folder is and which of its files. The wipe changes which bytes are in the folder and nothing about which mod page the user said it belongs to, so the two kinds of fact are treated differently.

| Kept | Why |
|---|---|
| The layers of the stack, their mod ids, confidences and names | The identity was confirmed by the user or by a download, and a local update is no evidence against it. Dropping it would also stop the update check for a mod the user has tracked, and lose the patch layers that make a mixed folder rebuildable. |
| `tracking`, including Local | The user's own statement. |
| `updates_dismissed_until` | A statement about what the remote has published, which an update from a disk does not change. |
| Each patch layer's record, rewritten with where its files are now | As for any base update. |

| Cleared | Why |
|---|---|
| The base layer's `file_id`, `version` and `version_label`, its version confidence back to `unknown`, and `baseline_remote_date` | They describe the old bytes. Left in place they claim the folder holds a file it no longer holds. |
| The base layer's `archive_md5`, replaced by the dropped archive's when there was one | The old hash is a fact about an archive that is no longer what is in the folder. |
| `ingest.sibling_group` | The folder is no longer a member of the archive that installed it, and a group update would write that archive's folder over it. |

| Rewritten | |
|---|---|
| `provenance` | `imported_archive` or `imported_folder` for what was dropped, since the bytes in the folder now came from there. |
| `installed_at` | Now, observed, so not a proxy. |
| The base layer's `files` | What the copy wrote. |
| `ingest` | The layout just written. |

So a tracked mod that was on a known GameBanana file comes out as a mod on that page with no file on record, which the card shows as **Which file?** and the tracking screen answers like any other. A dropped archive's md5 is kept on the layer, so when the user opens that screen a file whose published checksum matches is found by the hash, as for any imported archive: a matching key, never a claim that the files are intact.
An untracked mod comes out as an untracked mod that was imported now.

A local update is never recorded as a tracked file. The app never decides which published file a dropped folder is from its name or the version in it, because a guess recorded as a file id would make the next check report a wrong verdict in a plain voice.

### 5.2 What was rejected

- **Leaving the record as it was.** The card would go on saying the mod is on a file it no longer holds, and an update the user has just taken by hand would be reported as outstanding, or its absence as certain.
- **Keeping the file as it was and marking it `inferred`.** A name that matches is not the evidence that a file id needs, and an `inferred` file is still offered Reinstall, which would write the old file over what the user just dropped.
- **Clearing the whole origin block.** It is the simplest, and it loses the identity the user confirmed, the update check for that mod and the patch layers, to record nothing the folder could not equally say with the identity kept.
- **Writing only the files that share a name.** It is a merge: files the new version dropped would stay and load beside their successors, which is what the wipe exists to prevent ([`applying-updates.md`](applying-updates.md) §1).
- **Keep both as the preselected answer.** It is safer, and the user decided otherwise ([§3](#3-a-mod-the-user-already-has)).
- **Refusing a dropped folder that looks like a patch.** The user chose Update it for it. The snapshot is the way back, and a patch dropped under the name of the mod it patches is rare; the patch question does not see a row set to Update it.

## 6. Turn on after import

A switch in the review's footer, off until the user turns it on and remembered after that (`import_turn_on_after` in `config.json`, [`configuration.md`](configuration.md)). It applies to the mods the import **created**, Keep both's included. A mod that was updated is put back as it was, on or off, since turning it off was never the user's wish.

The new mods are turned on one by one the way the Library's switch does it, so One at a time applies to them, and a shader refusal or a network-link refusal is reported as it is there. A mod that cannot be turned on stays imported and off, and a warning names it.

## 7. The Importing dialog and the report

The Importing dialog is blocking, because a copy of a large mod is the one moment the library is not in a state the user can act on. It names how many mods it is writing, updates included, with a note that it may take a moment.
It does not close on Escape or on a press outside it.

A mod that was created is listed in the existing success dialog. An update reports a success of its own, because a rewritten folder looks the same on the grid as it did before; a failed one reports the error and points at the History tab, where the snapshot is.
A refusal of the new mods' copy (no space, a folder that cannot be written) is reported by its own card whatever the updates came to, so neither hides the other.
