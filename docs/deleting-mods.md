# Deleting mods

**Scope:** what Delete does to a mod's folder, link, settings and saved versions, how the folder reaches the system trash on each platform, what happens when it cannot, and the bulk Delete in All mods.

Delete moves the mod's folder to the system trash. It does not remove it from the disk, so a mistake is undone from the user's own file manager, which is where they already look.
The one question the dialog asks beyond "delete it?" is whether the mod's saved versions go too.

## 1. What is deleted, in order

One mod, one confirmation. After it, `ModManagerService.deleteMod` does these in this order, and the order is the design:

1. **Read the mod's uid.** It lives in the sidecar inside the folder, and the folder is about to move, so nothing can read it afterwards. Without it the saved versions can be neither deleted nor recognised as unclaimed.
2. **Remember whether the mod was on.**
3. **Remove the link** in ZZMI's mods folder. The game's loader may hold files open through it, and a link left pointing at a folder that has gone to the trash is a dead link the app never removes on its own.
4. **Remove the mod's shader files** from ZZMI's shader folder ([`shader-fixes.md`](shader-fixes.md)).
5. **Move the folder to the trash.**
6. **Only if that worked:** clear the mod's settings (active, favourite, note, character tag), drop its cached keybinds, and delete its saved versions when the box was ticked.

A trash that refuses leaves everything as it was: steps 3 and 4 are undone by turning the mod on again when it was on, and steps 1 and 6 touched nothing.
That is why the folder moves before any setting is cleared. A delete that clears settings first and then fails to move the folder leaves a mod that is still in the library with its favourite, note and character gone.

The caller owns the confirmation and the Working state on the button that asked, and reports a failure as one notification. A success is silent: the grid shows it ([`notifications.md`](notifications.md) §1).

## 2. The trash on each platform

`PlatformService.moveToTrash(path)` returns one of three results and never throws:

| Result | Means |
|---|---|
| `trashed` | The folder is in the trash. |
| `unavailable` | The folder is where it was and the platform has no trash for it. |
| `failed` | The folder is where it was, for another reason: Windows refused, or the user cancelled Windows' own prompt. |

### Linux: `gio trash`

`gio trash -- <path>`, run with an argument list and no shell. Exit 0 is `trashed`. GLib does the work the freedesktop trash specification asks of an implementation: the user's trash for a folder on the home volume, and `$mount/.Trash-$uid` for one on another drive.
`gio` ships with GLib, which the GTK the app already links depends on, so it is there on any desktop that runs the app.

Any other outcome is `unavailable`: a `gio` that is not installed, and every non-zero exit. The likeliest non-zero exit is a drive with no trash, such as a FAT or NTFS volume mounted without one, and `gio` says which in a message that is translated, so it cannot be told apart by reading it.
The message goes to the log and is never parsed. A permission failure also reads as `unavailable`; the offer that follows (§3) fails the same way if the folder really cannot be removed, and says so.
The command runs through an injected runner, so a test records the arguments and fakes each exit.

Rejected:

- **A `mod_manager/trash` method channel calling `g_file_trash_async` in the Linux runner**, as the clipboard does. It needs no `gio` binary, but it cannot be unit tested, and a change to it needs a full relaunch. The binary is always there.
- **Writing the trash specification by hand** (the `info` file, the `files` folder, the per-volume rules). GLib already does it and keeps up with the specification.
- **`trash-cli`.** An extra package for what `gio` already does.

### Windows: `SHFileOperationW` with `FOF_ALLOWUNDO`

Delete sends the folder to the Recycle Bin through `SHFileOperationW` (`FO_DELETE`), with `FOF_ALLOWUNDO | FOF_WANTNUKEWARNING | FOF_SILENT | FOF_NOERRORUI`, and not `FOF_NOCONFIRMATION`. The path is double-NUL-terminated, with backslashes, and the call runs in `Isolate.run`, since moving a large folder across drives blocks.

- **`FOF_WANTNUKEWARNING` is the answer to a drive with no Recycle Bin.** A network or removable drive, or a folder too large for the bin, would be deleted for good by `FOF_ALLOWUNDO` alone. With the flag Windows asks first, in its own prompt, so the app never deletes for good without someone having agreed. A user who accepts it has chosen what "Delete for good" (§3) chooses, so Windows never needs `unavailable`.
- **`FOF_NOCONFIRMATION` is left off.** Whether the confirmation that remains for the Recycle Bin appears depends on the user's Explorer settings, and the app does not decide to hide it. A user who has "Display delete confirmation dialog" on is asked a second time, which is accepted.
- **A non-zero result, or `fAnyOperationsAborted`, is `failed`.** That covers a cancelled prompt, a file the game has open, and a path over `MAX_PATH`: `SHFileOperationW` takes no `\\?\` form, unlike the app's other Win32 calls, so a path over 260 characters is reported and not worked around.
- The Win32 calls sit behind `WindowsTrashCalls`, as the link calls sit behind `WindowsLinkCalls`, so the flags, the terminator and the mapping of results are tested on Linux.

Rejected: `IFileOperation`, the COM form of the same call. It handles long paths, and takes a page of COM boilerplate over FFI for a path length the mod library does not normally reach.
Rejected: deleting the folder with `dart:io` on Windows. There is no Recycle Bin in it.

**Not yet run on Windows.** What needs a Windows session: a mod trashed to the Recycle Bin and restorable from it; a mod on a mapped network drive raising Windows' own permanent-delete prompt; a folder with a file open in the game refused and left intact; a path over 260 characters reported; a user cancelling the prompt.

## 3. When the trash cannot take it

`unavailable` and `failed` both leave the mod as it was, turned back on if it was on, and raise one error notification: "Couldn't move the mod to the trash", with the mod's name and the likely reasons, and **Copy details**.

For `unavailable` the notification also carries **Delete for good…**. It opens a second confirmation, a compact dialog with the danger button, and then runs the permanent delete: the same steps as §1, with the folder removed from the disk instead of moved.
It is a second step on purpose. A drive with no trash is not the user's fault, and a delete that quietly becomes permanent is the one outcome worse than refusing. The second step is a deliberate choice that costs only a second dialog, so it has no checkbox.

`failed` never offers it. On Windows `failed` follows a prompt the user cancelled, or a refusal for an open file, and offering a permanent delete right after someone said no, or when the folder is in use, is wrong twice.

Rejected: falling back to a permanent delete without asking. It is the silent version of the same thing.

## 4. The saved versions

The dialog has one checkbox, **Also delete its N snapshots (size)**, shown only when the mod has saved versions and ticked by default. It uses the theme's checkbox, the accent one every other checkbox in the app is drawn with.

- **Ticked:** the mod's group in the saved-versions store is deleted after the folder has moved.
- **Unticked:** the group stays. No mod claims it now, so Settings' Storage section lists it as saved versions of a mod you no longer have, and "Clear versions of mods you no longer have" can take it ([`disk-usage.md`](disk-usage.md) §9).
  The uid is still in the sidecar of the folder in the trash, so a folder put back from the trash gets its history back, as long as that button has not been pressed.

The count comes from the store's manifests, and the size is the apparent size the manifests record ([`disk-usage.md`](disk-usage.md) §5). Both are read before the dialog opens.

## 5. The dialog

A compact `ZenithDialog`, 480 wide, an alert dialog to a screen reader.

- The header is the mod's cover thumbnail, "Delete <mod>?", and "<character> · <size>". The size is the mod's own files, measured on demand, and the line shows the character alone until it arrives.
- The body says the folder goes to the system trash. For a mod that is on it adds that the game stops using it: "<character> goes back to the default look until you turn another mod on" for an agent, and "the game stops using it" for a built-in type or an unassigned mod.
- **Cancel has the initial focus**, so pressing Enter on a dialog that just opened cancels it.
- The confirm button is the danger button, with a trash icon.

## 6. Delete in All mods

A ticked set of mods goes through the same steps one by one, with the same box: **Also delete their N snapshots (size)**, ticked by default, counted over the set.
The confirmation names the mods (six, then "and N more"), the total size when measured, and how many are on.

Each mod that cannot be trashed is left as it is, and one notification at the end names them all with **Copy details**. It does not offer Delete for good: a bulk permanent delete is a decision about a whole set that no one has looked at, and the single delete is where that choice is made.

## 7. What is not done

- **No emptying the trash and no restoring from inside the app.** The trash belongs to the user's file manager, which already does both.
- **No fallback to the app's own folder.** A "trash" the app keeps in its app data would hold a mod's files for good, off the drive the user thought they were freeing, and nothing would ever empty it.
- **A mod restored from the Recycle Bin or the trash keeps the name the system gave it.** On Windows the bin may rename it on a collision. The library reads it again when the window regains focus, and the mod shows up once its folder is back in the library.
