# Editing a mod's in-game keys

Reference for the **In-game keys** section of Edit info: where its rows come from, how a key combination is recorded, how a change is written into the mod's `.ini`, and how the author's own keys are kept so they can be put back.

> Scope: the keys section of the Edit info dialog and the file edits behind it. The rest of the dialog (name, cover, author, description, tags) is [`library-screen.md`](library-screen.md) §13; the sidecar fields are [`metadata-schema.md`](metadata-schema.md); what an update does to a mod's files is [`applying-updates.md`](applying-updates.md).

---

## 1. The rows

A row is a `[Key…]` section of a mod's `.ini` that has a `key` value. The rows are the keys the details panel and the mod's page list, in the same order, and they come from the same place: `IniParserService`, over the `.ini` files ZZMI loads ([`library-screen.md`](library-screen.md) §12 says which files those are; a file or folder whose name starts with `DISABLED` is never read, so it is never written either).

A parsed section carries where it came from: `KeybindInfo.file`, the path inside the mod folder with `/` separators, and `KeybindInfo.occurrence`, how many sections of that name, case-insensitively, come before it in the file. A write finds its section by file, name and occurrence, never by "the first file that has this name", so two files that each have a `[KeySwap]` stay two rows.

Each row has two fields the user edits: a **label** and the **keys**.

## 2. Labels

The label is what the row is called in Edit info, the details panel and the mod's page. It defaults to the section's own name without a leading `Key` (`KeyHair` is "Hair"). A mod's author chose that name for the `.ini`, not for a person, which is why it can be changed.

**A label is stored in `config.json` as `mod_keys`, never in the sidecar**: `{ "<mod folder>": { "labels": { "<section, lower case>": "Coat on / off" } } }`. A label is this user's own wording, and the sidecar travels with the folder when it is zipped or shared, the same reason a note is in `config.json` ([`library-screen.md`](library-screen.md) §11).

- A label is stored only when it differs from the default, and an empty one removes the entry, so a row the user never named costs nothing.
- It is keyed by folder name and section name, so it survives an update and applies again wherever the section still exists. An in-app rename moves the labels with the mod and a delete removes them. A folder renamed outside the app leaves its labels behind under the old name, as notes are.
- Two sections of one name in different files share a label. A mod that does that is rare, and a label per file would lose every label when an update moves the section to another file.

## 3. Recording a key combination

The keys button is not a text field. Pressing it, or Enter or Space while it has focus, starts **recording**: the button takes the keyboard, shows "Press a key combo…" and records the next key that goes down.

- Every key is consumed while recording, including Tab, Enter and Space, which are recorded rather than acted on. Escape cancels the recording and keeps the old value; it never closes the dialog. A click elsewhere cancels too.
- Ctrl, Alt, Shift and the Windows key held when a key goes down become the modifiers `ctrl`, `alt`, `shift` and `windows`, in that order, followed by the key. A modifier pressed alone records nothing. Mouse buttons are not recorded.
- The key's name is 3DMigoto's own spelling. Letters and digits are the bare lower-case character. Function keys are `VK_F1` to `VK_F24`. The rest are `VK_UP`, `VK_DOWN`, `VK_LEFT`, `VK_RIGHT`, `VK_NUMPAD0` to `VK_NUMPAD9`, `VK_MULTIPLY`, `VK_ADD`, `VK_SUBTRACT`, `VK_DECIMAL`, `VK_DIVIDE`, `VK_SPACE`, `VK_RETURN`, `VK_TAB`, `VK_BACK`, `VK_DELETE`, `VK_INSERT`, `VK_HOME`, `VK_END`, `VK_PRIOR`, `VK_NEXT`, `VK_CAPITAL`, `VK_NUMLOCK`, `VK_SCROLL`, `VK_PAUSE`, `VK_SNAPSHOT`, and for punctuation `VK_OEM_1` (`;`), `VK_OEM_PLUS` (`=`), `VK_OEM_COMMA`, `VK_OEM_MINUS`, `VK_OEM_PERIOD`, `VK_OEM_2` (`/`), `VK_OEM_3` (`` ` ``), `VK_OEM_4` (`[`), `VK_OEM_5` (`\`), `VK_OEM_6` (`]`) and `VK_OEM_7` (`'`).
  The names come from 3DMigoto's key table (`VKMappings` in its `vkeys.h`, which also accepts them without the `VK_` prefix); the app writes one spelling for each key.
- A digit or punctuation key pressed with Shift reaches Flutter as the shifted character, so a key that has no name above is looked up again by its position on the keyboard. A key that has no name either is **refused** inline ("That key can't be written to an .ini.") and nothing is staged.
- The tokens `no_ctrl`, `no_alt`, `no_shift`, `no_windows` and `no_modifiers` say which modifier must **not** be held. They cannot be recorded, so the old value's are kept, except that a `no_` token for a modifier the new combination holds is dropped, and `no_modifiers` is dropped when the new combination holds any.
- A combination equal to the old one, compared by its tokens without case or `VK_`, is no change.

Not verified in the running game: the `windows` modifier's spelling, which is the one name here this app has no mod to measure it on.

## 4. Writing a change

Edit info stages every change and writes nothing until Save. For each `.ini` a change touches, `ini_key_editor.dart` rewrites the lines it must and leaves every other byte alone:

- the file's byte-order mark and each line's own ending (`\n` or `\r\n`) are kept;
- a `key = value ; comment` line keeps its comment, its spacing and its spelling of `Key` or `key`, and only the value changes;
- a file that is not valid UTF-8 is **refused**, not rewritten lossy: the file is reported and the others still write;
- the new text goes to a temporary file in the same folder and is renamed over the original, so a crash leaves the old file or the new one, never half of one.

The `key` line edited is the last one in the section, which is the one the parser shows. A section or occurrence a file no longer has when Save is pressed (the file changed meanwhile) is skipped and reported with its file. The whole save runs inside `whileWritingMod`, so an update or a restore cannot interleave ([`library-screen.md`](library-screen.md) §15, "One write at a time"). Every file written is logged under `fileops` with its path inside the mod, and a refusal under `ini`.

After a save that wrote keys, the mod's cached keys are dropped and the library is read again, so the card, the panel and the page show them. While the game runs and "Remind me to press F10" is on, a note says the keys are saved and the game needs F10 to read them.

## 5. The author's keys

Restoring "the author's keys" needs a baseline, and [`applying-updates.md`](applying-updates.md) §5 explains why the app has none for hand edits: after an install the `.ini` is the author's file and every later change, with nothing marking which is which. The baseline here is only for edits made through Edit info, and it is written by the app, into the file.

**The marker.** The first time Save changes a section's key, the line directly above the `key =` line becomes `;zenith: key = <the previous value>`, unless a marker is already there. The first edit's previous value is the author's, so later edits keep the marker and the author's value stays put. 3DMigoto and `IniParserService` both ignore comments. Setting the key back to the marker's value removes the marker.

Why a comment in the `.ini` and not a record in the sidecar or a copy of the file:

- It **travels with the file**: through a rename, a zip, a snapshot and a restore, each of which keeps the file and its marker together.
- It **dies with the rewrite**: an update replaces the `.ini`, and the author's keys are back along with the marker that described them. A sidecar record would outlive the file and claim a baseline for a file that no longer has it.
- It **validates itself**: a hand edit that removes the comment removes the claim. A hash or a stored value cannot tell a hand edit from a patch applied into the folder ([`applying-updates.md`](applying-updates.md) §5).
- It needs no schema and no migration.

**Remove.** The X on a row unbinds the key: Save comments the whole section out, each line prefixed `;zenith: `, header included. The row leaves the lists and the game stops reading the binding. The mod's variable keeps its default and nothing else in the file changes. Rejected: deleting the lines, which loses the author's section; and blanking the `key` line, which leaves a half-bound section whose behaviour depends on how 3DMigoto reads an empty key.

**Restore the author's keys.** A button above the rows, staged like any edit, which Cancel drops. It puts every row back to its marker's value, or to the value it had when the dialog opened when it has no marker yet, brings back every row removed in this dialog, and shows the sections an earlier Save commented out as rows again. On Save, each marked key goes back to its marker (and the marker is removed) and each `;zenith:` block is uncommented. Hand edits are not tracked and not undone, since the app never claimed them. The button is enabled only while something would change.

**What "was Alt 1" says.** The row's right-hand note is the marker's value when it differs from the current one, or the value at open for an edit made in this dialog.

## 6. No "Add a key"

The canvas draws an **Add a key** button. It is not built, and nothing replaces it.

A working key in a ZZMI mod is a `[Key…]` section (`key =`, `type = cycle`, `$var = 0,1`) that is wired into the mod's own logic through a variable the rest of the `.ini` reads. A section the app adds does nothing unless that variable is used somewhere, and the app cannot invent the logic that would use it. Rejected: writing such a section anyway, which gives a row in the list for a key that does nothing; and a note-only row stored in `config.json`, which would sit among the real keys and say a key does something it does not.

## 7. An update

An update replaces the `.ini` files, so key changes are replaced by the author's keys, and the markers go with the files they were in. The result dialog already names the keys the update moved ([`applying-updates.md`](applying-updates.md) §5), which is how the user finds out what changed. Labels live in `config.json` and apply again to every section the new files still have. Edit info's footer says so: "An update replaces key changes with the author's keys. The rest of your edits stay."
