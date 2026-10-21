# The library screen — the character view, the All mods table, the Updates page and their surfaces

**Scope:** the Library's three views. The character view: the character list, a character's header, the mod grid with its card and status badge, the row above the grid, One at a time, notes and the details panel. The All mods table with its filters, its Folder missing rows and its bulk actions. The Updates page with its coverage strip, its newer files and the mods it can't check. And what they reach: a mod's page with its History tab, and the dialogs reached from a mod.

Not in scope: the rules about origin *states* and what each answer may write ([`origin-tracking.md`](origin-tracking.md) §4–§5), the update comparator ([`update-checks.md`](update-checks.md)), or how an update is written to disk ([`applying-updates.md`](applying-updates.md)).
What follows is only what is specific to these widgets.

---

## 1. The page

The Library is one page with three views, picked by the sidebar's Characters, All mods and Updates rows (`AppDestination.characters`, `allMods` and `updates`). All three are the same keyed child of the page switcher, so moving between them keeps the page, and a mod's page (§15) opens over any of them. §2–§5, §7, §11 and §12 are the character view, §16 is the table and §17 the Updates page. §8 and §15 serve all three, and §13's dialogs are reached from all three too.
§6's status badge is drawn on the card and a mod's page, and its needs-attention set is also the table's Can't be checked filter and the Updates page's Can't be checked section. §10 governs the character view's switches and the table's Enable, and §14's resolve dialog opens from a card, the details panel, a mod's page and the table's Updates column. §9 is reached from the table and the Updates page.
The Updates page itself has no switches, no status badge and no resolve dialog.

The character view has three columns: the character list, the character on screen (their header, the row of filters, their mods), and the details panel for the mod selected among them.
The panel sits beside the mods while that leaves them at least 420px, room for one column of cards, and over them otherwise.

**The character's page scrolls as a whole**: the header, the row of filters and the grid are one scroll view, so the header and filters scroll away with the mods and a window at the minimum size still shows mods rather than only the two of them.

**Everything another surface needs is in a provider**, because the sidebar's pages are disposed on every switch ([`app-architecture.md`](app-architecture.md) §3):
the character on screen (`selectedCharacterIdProvider`), the selected mod (`selectedModIdProvider`), and both filters.
The page itself holds only the drag-and-drop state and the guard against two operations at once.

The panel shows a mod of the character on screen. Picking another character closes it, and the selection is kept, so going back to that character opens it again.
At the smallest window the panel is no wider than the page it is drawn over.
A mod's page (§15) takes the place of all three columns while it is open.

**Opening, closing or moving the panel leaves the page where it is in the tree.** The page is always the first child of the same stack, and the panel joins that stack or the row beside it.
A different parent for each would throw the page away on every press of a card, taking its scroll position and every card's state with it. The panel keeps its own state as it moves between beside and over, through a `GlobalKey`.

**Ctrl+V on the page imports the folders and the .zip, .7z and .rar archives whose paths are on the clipboard**, except while a text field has the caret: in the note or the filter field it is that field's paste.
A click outside a text field gives keyboard focus back to the page, so after typing a note or a filter the next Ctrl+V imports again.
The page takes focus back only from its own route's scope: focus at the root of the app is the window being inactive, which Flutter hands back to the field or dialog that had it when the window returns, and a dialog over the page keeps its focus.
A pasted archive is deleted once its mod is installed, as a dropped one is: the archive is the install's input, and the library keeps the mod.

## 2. The character list

**Every agent is listed, with or without mods**, under the four built-in categories and **Unassigned**. The five other types come first because they are few: a short block above the long roster stays in reach, where at its end it would be 64 rows down.
The list is the roster rather than a summary of the library: a character is found where they always are, and every row is a place to drop a mod onto.
Every row with no mods is dimmed and says "No mods yet", the categories and Unassigned as much as the agents, unless it is the row on screen or a card is being dragged over it. The sidebar's Characters count follows the list: the roster, or the agents with a mod while Hide empty is on.

- **A row** is the portrait on the agent's element tile (`CharacterTile`; initials when `CharacterAvatar.assetPathFor` has no portrait), the name, the mod and active counts, an amber dot when the last check found an update, and an accent diamond when a mod is on.
- **The name** is the real name where it is the short name made longer ("Ellen Joe", "Hoshimi Miyabi"), the short name otherwise: "Flora" is what Seed is called in the story, not what players call her (`CharacterData.fullName`).
- **Element, faction and role** are on the roster, `utils/zzz_characters.dart`. Sub-attributes (Frost, Honed Edge, Auric Ink) are recorded as the attribute they belong to. Belle and Wise don't fight, so they have a faction (Phaethon) but no attribute and no role, and sit on the neutral tile.
- **Unassigned** holds the mods with no character and the ones whose id neither the roster nor the categories know (`libraryGroupOf`), such as an id left behind by a roster rename.
  A mod is filed by the character stored for it, never by a guess from its name: "Zhao Nicole" reads as Nicole, and a mod the user dropped on Unassigned must stay there. An import works a character out from the name once and saves it, where the user sees the result.
  It is not called "Unknown", as on the design canvas: the row holds mods not assigned to anyone, which "Unknown" would misdescribe.
- **The filter field** matches names and the roster's detection aliases. The chips keep the rows with a mod on or with an update; Updates counts rows, not mods.
- **Hide empty**, a switch under the chips, is off by default and remembered (`hide_empty_characters`). On, it hides every row with no mods, the categories and Unassigned included, and a line under the agents says how many agents it hides, with a Show link that turns it back off.
  Only agents are counted: the line sits under them, and the five other types are always the same five. The count is of the agents the field and chips would otherwise show, so a chip that already leaves out the empty rows shows no line.
  The row on screen is kept, dimmed or not by the rule above: deleting a character's last mod doesn't take their row out from under their page. It goes once another row is picked.
  When everything the field matches is hidden and none of it is an agent, the list says "Only rows without mods match · Show" in place of "No character matches", which would be false.
  Until the first scan returns, every row reads as empty: the rows stay hidden, but neither the line nor the sidebar's count says so, and the count stays the roster. A Show pressed then would switch the preference off over a library that hadn't been read.
  It is a switch rather than a chip because it is a standing preference about the roster, where the chips are a look at one question that is set and cleared.
- **A card dropped on a row** files the mod under that row; Unassigned clears its character. A long press starts the drag, so a click on a card stays a click.
- **With nothing picked**, the page shows the first row with a mod in `libraryGroupIds` order: the agents in roster order, then UI, Texture, Audio and Misc, then Unassigned.
  That is not the list's own order, which puts the categories first. A library with no mods at all opens on the first agent.

## 3. A character's header

The character's element as a dotted ground with their initials outlined over it, the portrait, the attribute badge, faction and role, the name, and "4 mods · 1 active · 412 MB".

**The size is each mod's own files, measured on demand** (`modSizeProvider`): the folder minus its sidecar, which is how the Storage page counts Mods ([`disk-usage.md`](disk-usage.md)), apparent size, off the UI isolate.
A walk is about half a millisecond a mod, and only the mods on screen are measured. The total joins the line once every one of them has been, rather than growing as they arrive.

**Find mods** opens Browse. **Add mod**, and pressing the drop tile at the end of the grid, say how: drop or paste a folder or a .zip, .7z or .rar archive onto the page.
There is no "open character folder": the library is flat, so a character has no folder of their own.

**A mod dropped or pasted on a character the user picked is filed under that character**, which replaces working the character out from the name: where they dropped it is what they said.
Picked means clicked in the character list; a character the app put on screen does not count. The page shown before the user picks one is a fallback, and filing five archives for five agents under it would be the app's guess, not theirs.
There, on Unassigned and on the All mods table, the character is worked out from each mod's name. The drop tile says which of the two a drop will do.

## 4. A rescan only reaches the grid if the library came back different

The scan belongs to `libraryProvider` ([`app-architecture.md`](app-architecture.md) §3). It runs when the Library opens, whenever the window regains focus (§12), and after an action only a fresh read shows the result of: an import, moving a mod to another character, a bulk action, a write to where a mod came from, a reinstall, a restore, a patch taken out, saved keys, a switch that failed, a rename that left the mod off, and saved Settings. An install or an update invalidates the library, which reads it again.
A toggle or a rename that works, an edit, a favourite and a delete update the list in place without a scan. Most scans change one mod or nothing.
So `rescan()` keeps the list it already holds when the new one compares equal, and everything derived from it is rebuilt only when the library is actually replaced.

**The comparison is `ModInfo`'s own value equality, and that is the whole point.**
A hand-written field list fails silently for every field left out of it.
Without `origin`, resolving a mod writes the sidecar correctly, the rescan re-reads it correctly, the guard says "unchanged", and the mark stays on the card; without `keybinds`, an edited hotkey keeps showing the old key. Nothing throws in either case.

A field is covered by being a field — including everything inside the origin block, which is why `ModOrigin` has `==` at all.
`test/library_change_test.dart` holds the cases, and pins that adding a field to `ModInfo` without an equality case fails there rather than on someone's card.

### Two keys decide whether a rebuild is felt

**The character page is keyed on the character id, not on how many mods they have.**
The `AnimatedSwitcher` around it exists for one thing: the fade that says *you are looking at a different character now*.
A key carrying the mod count plays that fade over the whole page whenever a mod is imported, deleted or retagged out of the character.

**A card is keyed on its folder id, and nothing about its state.** A key carrying `isActive` re-creates the card on every toggle and discards its `State`, including the hover the pointer is still over.
Nothing needs the re-key: the card takes the mod as a prop and animates its own changes.
`test/mod_card_identity_test.dart` pins the surviving `State` rather than the key, since the surviving state is the property that matters.

The general rule both of these follow: **a key answers "is this the same thing?", never "has this thing changed?"**
Folding changing state into one turns every update into a teardown.

## 5. The card

The cover, or the character's dotted ground with the mod's initials when there is none; the Active badge and the status badge over its top-left, the favourite star top-right; the name; one line under it; the switch and the ⋯ menu along the bottom.

- **A press selects the mod**, which opens the details panel. The switch turns it on and off, the star favourites it, and a right-click or ⋯ opens the context menu.
  The card's border lightens under the pointer.
- **The line under the name** is the author and "file from <date>" once this session holds the mod page (§12) and a file is on record, and "added <date>" otherwise. The sidecar records neither the file's name nor its upload date, and the card never fetches to find out.
  A file on record is one confirmed or one worked out and accepted in the tracking screen (`namesFile`), and the two are named alike here and on every other surface: the user agreed to the guessed one, and whether it was guessed doesn't matter to them. A date with no file (Dated only) names none.
- **The card is a button to the keyboard and a screen reader too**: Tab reaches it, Enter or Space selects it, and a pressable badge is a button of its own.
- **A drop tile ends the grid**, and stays out of a filtered one, where it would read as a result, unless the character has no mods at all.
- **The Active badge is the switch shown on the cover**, not a status: it says what the switch says, where the artwork is.
- **Turning a mod on or off and starring it report only a failure** ([`notifications.md`](notifications.md) §1): the switch and the star are the feedback.

## 6. The status badge

`ModStatusSlot` is **one badge, one state, never a stack**. `modSlotStatus()` decides which, folding the origin block together with the session verdict, so precedence between "you have not sorted this mod out" and "this mod has an update" is one decision in one place.

| State | Badge | Colour | Press |
|---|---|---|---|
| an update, confirmed | Newer file | amber | the update dialog |
| an update, resting on a guess | Maybe newer | amber | the update dialog |
| identity known, file not (`versionUnknown`) | Which file? | blue | the resolve dialog |
| a patch whose base mod nobody named (`secondIdentityUnknown`) | Base unknown | blue | the resolve dialog |
| a date on record and no file (`versionGuessed`, `assumed_latest`) | Dated only | grey | the resolve dialog |
| no identity (`untracked`) | Not tracked | grey | the resolve dialog |
| the user marked it their own (`tracking: "off"`) | Local | grey | nothing |
| a file worked out and accepted in the tracking screen (`versionGuessed`, `inferred`) | no badge | | |
| known exactly (`none`) | no badge | | |

**Amber is an update, blue asks for something, grey states a fact.** Amber is the only state carrying something the app went and fetched.
Blue is what one pass through the resolve dialog settles for good. Grey is what most of an older library is, and a loud mark on every card would teach the user to stop seeing the badge, after which the state that *does* ask could never be noticed either.

**The two update badges are keyed on the outcome, never on `isGuess`.** A mod recorded at `exact`/`exact` whose author published a newer file under a different label is `possiblyOutdated` with `isGuess` false;
read off `isGuess`, the card would say "Newer file" while the update dialog for the same mod says "possibly outdated".

**Local is not Not tracked.** Local is the user's own answer to "where is this from", shown back to them, and a mod marked so is never checked. A mod with no identity is merely untracked, and is never called local.
`tracking: "off"` is tested before everything else, so a Local mod never shows an update or asks for anything.

**`versionGuessed` is two answers, and only one of them has a badge.** "Mark as current" records a date and no file, which is Dated only: the mod is checked by date, and the badge says that is all the app knows.
A file the tracking screen worked out is a file the user accepted there, so the card says nothing about it and names it as it names a confirmed one (§5). Reinstall is offered for a worked-out file as for a confirmed one ([`applying-updates.md`](applying-updates.md) §6). What still tells them apart is the update check: an update found against a worked-out file is a "Maybe newer" unless the archive's checksum matched ([`update-checks.md`](update-checks.md) §3).

**`secondIdentityUnknown` is its own state** rather than folded into Which file?, because that sentence would be false: a patch downloaded by this app knows its file exactly, and the unknown is the *other* mod in the folder.

**The needs-attention set counts `secondIdentityUnknown`**: the character view's Needs attention filter (§7) and the All mods table's Can't be checked filter (§16), which are one rule (`modInfoNeedsAttention`). The user can finish it — naming the base mod clears it — and finishing it moves the count.
A filter whose number can never reach zero is noise.
"Mark as current" does not date such a folder: a date for one layer leaves it asking, so it is settled by naming its base mod (§14), and the write declines it anyway ([`origin-tracking.md`](origin-tracking.md) §6).

## 7. The row above the grid

**The filter chips** — All, Active, Updates, Favorites — each with the count for the character on screen. **Needs attention** joins them while any mod here needs it, or while it is on: the answer is usually nothing or most of the library, and both are worth knowing before pressing rather than after.
One filter at a time, like the chips that set them.

**The Updates chips show no number until a check has run**, the one above the grid and the one in the character list alike. "0 updates" and "not checked" are different claims, and a zero before any check would make the first.

**The Updates filters here and in the character list switch themselves off** when the library has no updates left, keyed on the library rather than on the character: on the character's own count the filter would vanish whenever the user looked at someone with no updates of their own.
The listener is in `LibraryActionsHost`, above the pages, since the last update is often dealt with from the All mods table while the character view is not mounted.

Then **One at a time** (§10), absent on Unassigned, and the sort, and nothing else. This row is about one character; the actions over the whole library are elsewhere: checking it for updates on the All mods table (§16) and the Updates page (§17), and the tracking screen and marking every mod that asks Which file? as current on the Updates page.

## 8. Check results are session state

`modUpdateChecksProvider`, and the records behind a whole-library check's verdicts `modUpdateRecordsProvider` — **never persisted**.
A verdict restored from disk asserts something about a mod page nobody has looked at since.
Keeping the *records* is what lets the resolution screen be re-opened without a request, and what lets the card and the details panel name a file and an author without one.

Two scopes meet here deliberately: the check covers the whole library (its badges are drawn on every character), the filter covers the character on screen (that is all it can narrow).

**A check reports through one surface, not two.** With nothing to resolve it raises the summary notification; with mods whose origin can be sorted out it opens `dialogs/bulk_resolution_dialog.dart`, which states that summary itself.
Raising a notification behind a modal is how a user ends up reading neither.
The spinner is cleared **before** the dialog opens — the request is what it reports, and one turning behind a dialog says the app is still working while disabling the control they would press next.

**The checks and the tracking screen run in `LibraryActionsHost`, above the page switcher**, like the download queue's host. A check over a large library takes seconds, and the page is disposed on every page switch: owned by the page, a pass would lose its results and its report the moment the user looked elsewhere.
`libraryCheckRunningProvider` says a pass is running, and every control that would start another is disabled until it ends: the table's Check all for updates and the selection bar's Check for updates (§16), and the Updates page's Check all for updates, Check them now, Pick the files one by one and Sort out tracking… (§17).

## 9. Bulk "assume current" lists every mod it writes

`services/bulk_assume_current.dart`, `dialogs/assume_current_dialog.dart`. It is **Mark N as current** in the All mods table's selection bar (§16), there only while a ticked mod asks Which file? of its base and has a date added; N is how many do. It is also **Mark all as current…** on the Updates page (§17).
The rule is that the user must have *seen* the set being rewritten, and the confirmation enforces it: it lists every mod it would write, each with a box, all ticked.

**Its plan comes from the ticked rows the table shows**, the filter and the search together, as every bulk action's does (§16): a control that rewrites more mods than it displays is exactly what this rule exists to prevent.
On the Updates page the plan is every mod asking Which file?, which is the set the card above the button counts and names.

The confirmation, from the top:

- the title with the count, and "The mods showing" with the Which file? badge they share;
- what the action assumes: each mod is the file that was newest on its page on the day it was added;
- an example, the first mod's date added as the line between "uploaded by then: counts as the file you have" and "uploaded after: shows as an update";
- the list, under "N of M" and a box that ticks or clears all of it, each row with the mod's thumbnail, name, character or type, author once the page is in hand, and date added. Unticking a mod leaves it asking Which file?;
- "Left as they are:" with the ticked mods it will not touch, the ones not linked to GameBanana, the ones with no date added on record, and the ones whose base mod or patch file is still to be named in the tracking screen ([`origin-tracking.md`](origin-tracking.md) §6), so "12 mods" is never read as all of them;
- the caveat for mods copied in from another folder, shown only when a date about to be written is a proxy ([`origin-tracking.md`](origin-tracking.md) §6);
- "Nothing is downloaded", Cancel, and the confirm button with the count still ticked, disabled at zero.

Only the mods left ticked are written. See [`origin-tracking.md`](origin-tracking.md) §6 for the rules the write enforces.

## 10. One at a time, per character

The **One at a time** switch above a character's mods decides what turning one of them on does. On, the character's other mods go off; off, any number stay on together.

**It belongs to the character, not to the app.** One outfit per agent is the usual case, but a built-in category holds mods made to stack: a HUD mod beside a font mod, two texture packs that touch different things. One global switch makes the user flip it on the way into every such group and back on the way out.

- **The defaults:** on for every agent, off for the four built-in categories.
- **Unassigned mods have no switch.** They belong to no one character, so "the others" would be mods for anyone, and turning one on never turns another off.
- **Stored in `config.json` as `one_at_a_time`**, a map from group id to a bool, written only for a group the user has switched. The id is the canonical roster id or the category id. A choice is per install, like a favourite: whether two of Ellen's mods can be on together is this user's preference, and it is about the character rather than any one mod. The value is the user's explicit choice, never "differs from the default", so a later change to a default leaves every stored choice meaning what it meant.
- **Flipping the switch changes nothing on disk.** It governs the next time a mod is turned on. A character with three mods on keeps all three until the user turns on another; turning all but one off at the press would mean the app picking which one to keep.
- **A choice that could not be saved is reported**, and the switch stays where it was.

Every enable from the library goes through one path, `ApiService.enableMod`, whichever control was pressed (the card's switch, the details panel's switch):

1. The dry run (`checkActivation`), so a refused enable is raised before anything changes and the mod that was on stays on.
2. With the switch on, the character's other active mods are turned off.
3. The mod is turned on.

A failure in step 2 stops the enable rather than leaving two mods on under a switch that says one.
**A mod whose folder is being written is turned off in step 2 all the same**, by the switch and by bulk Enable alike: an update, a Reinstall, a patch installed or taken out and a restore all turn the mod off for their write, so its link may already be gone, and a link already gone is no failure. The mod is marked so its write leaves it off when it ends, with its shader files not placed again ([`applying-updates.md`](applying-updates.md) §1). Waiting for the write would hold the mod the user did press. A press on that mod's own switch, and bulk Disable on it, still wait or skip (§16). A failure anywhere is reported, and the page reads the disk again to show what is really on. A mod on a network folder that Windows can't link without Developer Mode is reported with that reason, by the switch and by bulk Enable alike ([`app-architecture.md`](app-architecture.md)).

**A mod is on when the link named after it in ZZMI's mods folder points at its own folder in the library** (`isModActive`): by path, or at the same real folder when the library path itself goes through a link.
Any other link of that name, into another folder or to one that is gone, reads as off, since the game is not loading this copy. Turning the mod on replaces that link with its own, as it makes one where there is none, with no prompt. A turn-on that fails leaves the old link as it was, a dead one that would come back with its drive included: on both platforms the new link is made under a temporary name before the old one is touched, one starting with `DISABLED` so ZZMI never loads it if a replace stops partway. Linux renames it over the old one; Windows, which can't rename a link over another, renames the old one aside and back again if the swap fails ([`configuration.md`](configuration.md#changing-the-mod-library)).
Turning a mod off or deleting it removes only its own link and never touches another of its name.
Renaming a mod that is on moves its link to the new name: a dead link of the new name is replaced, and a live one, or a folder of that name, refuses the rename, so two mods never share a name in ZZMI's mods folder. The copy a replaced dead link led to has its shader files taken out once the new link is made, as turning the mod on over it would ([`shader-fixes.md`](shader-fixes.md) §6).
A mod whose folder is being written, by an update, a Reinstall, a patch install or removal, or a restore, can't be renamed: the dialog says why, and its Rename button stays off until the write ends.
The folder is renamed first and the link moved after, so a folder that can't be renamed (a file in it open in the game) leaves the mod and its link as they were, and says so.
A link that can't be made under the new name (a read-only links folder, a path too long, a link Windows refuses) renames the folder back, which makes the old link live again: the mod keeps its old name and stays on, a dead link of the new name stays as it was, and an error says so. When the folder can't be renamed back either, the mod keeps its new name and is off, with its shader files taken out as turning it off would, its tick and the selection follow the new name, and the error says that instead.

**A limit: two mods with a shader file at the same path and different contents can't be swapped by turning the second on.** The dry run sees that path held by the first mod and refuses, naming the mod it was about to turn off. A file at the same path with the same bytes is shared, and does not stop the swap.
Turning the first off by hand, then the second on, works. The dry run treating files held only by mods about to be turned off as free is what lifting the limit would take ([`shader-fixes.md`](shader-fixes.md)).

## 11. Notes

The details panel and the Note tab of a mod's page (§15) have a **Note** field: free text the user writes about a mod for themselves ("use with the white hairpin").

**It is stored in `config.json` as `mod_notes`, a map from mod folder name to text, never in the sidecar.** A note is this user's opinion, like a favourite, and the sidecar travels with the folder when it is zipped or shared ([`metadata-schema.md`](metadata-schema.md) §1). Rejected: the sidecar, where a note would arrive in someone else's library and a snapshot restore would put back the note from before the snapshot.

What follows from the key being the folder name, the same as `favorite_mods`:

- an in-app rename moves the note with the mod;
- deleting the mod removes its note;
- a folder renamed outside the app leaves its note behind under the old name, where it comes back if the name does.

The note is saved when typing pauses, when the user clicks elsewhere, and when the panel moves to another mod or closes or the page's tab changes, so there is no Save button. Text that is empty once trimmed removes the entry.
It is published to `modNotesProvider` before it is written, so a field rebuilt for the same mod while the write is in flight shows what was typed.
A saved note is on screen as typed, so only a failed save is reported ([`notifications.md`](notifications.md) §1), including one made as the panel closed.

## 12. The details panel

`components/mod_details_panel.dart`, in place of a details dialog: a mod is looked at beside the others rather than over them.

From the top: the gallery (the cover, with the rest as thumbnails; pressing the cover opens it large over a dark backdrop, and a tap anywhere closes it), the name and, once the session holds the page, its author;
the description, folded to three lines of its own text size, with More and Less; the tags, as badges; **Active in game** with its own switch; the in-game keys from the mod's `.ini`;
the shader-fixes line and, for a folder that holds more than one download, **Made of N mods**; the facts; the folder's path; the note. In the header: the favourite star, Edit info, the full-page button that opens the mod's page (§15), and Close. Along the bottom: Open folder, Check for updates, Delete.
The pieces it shares with the mod's page (description, Active box, keys, Made of, facts, note) live in `components/mod_detail_parts.dart`.

**It never fetches.** A mod is selected far more often than a dialog is opened, and a mod selected in passing should not spend a request nobody asked for.
So the facts that live only on the mod page (the file's name, its upload date, the author) appear once this session holds the page, and are absent before.
The session holds a page once an update check fetched it, or the install, a dialog or the mod's page did (`knownModPagesProvider`), so a mod installed a moment ago already names them.
File, Variant and Uploaded also need a file on record, confirmed or accepted in the tracking screen, as the card's "file from" does (§5).

**The name is the type scale's `titleLarge`, 17px, where the canvas draws 18px.** The type scale has no 18px role, so the difference is kept on purpose rather than adding a size for one line.

| Fact | Shown |
|---|---|
| File | the recorded file's name, from the page in hand |
| Variant | the recorded version label, when there is one and the file is named |
| Uploaded | the file's date, with "nothing newer" or "a newer file is out" when the last check said so about the base mod; a patch's verdict is never put on the base mod's file |
| Tracking | GameBanana · change, Not tracked · set up, or Local · change; the second half opens the resolve dialog |
| Added | the install date, whether the app saw the install or worked it out from the oldest file |
| Size | the mod's own files, as in the header |

- **Check for updates is offered only with an identity to check**, and not for a mod marked Local, which is never checked; for either the update dialog would say so and nothing else, and Tracking's "set up" or "change" is the way in.
- **Ignoring an update is not here.** It is in the update dialog, with its undo, and on the Updates page's Newer files rows (§17), which both show the file you have beside the newer one, so the finding is read before it is waved away ([`update-checks.md`](update-checks.md) §6). Taking one back is also on the History tab of the mod's page (§15).
- **Made of N mods lists the folder's stack** (`origin.downloads`), base first and patches on top, and is absent for a folder with one download ([`origin-tracking.md`](origin-tracking.md) §10).
  Each row has a Base or Patch badge, the name, which links to its page, and, once the session holds that layer's page, its author and, for a file on record, the file's name and upload date. A patch's file is never put on the base's row.
  The name is the page's when it is in hand, else the one saved with the layer (`ModDownload.name`), else the id. It is never the folder name for a layer with an id: a patch installed as its own folder names the folder after the patch's archive ([`origin-tracking.md`](origin-tracking.md) §10).
  "Manage in History" under the list opens the History tab of the mod's page (§15), where a patch is taken out, for every folder the list shows.
- **In-game keys leave out the `no_` tokens**, which name a modifier that must *not* be held, so the caps show what to press.
- **In-game keys come from the `.ini` files ZZMI loads.** ZZMI's `d3dx.ini` sets `exclude_recursive = DISABLED*`, so a file or folder whose name starts with `DISABLED`, in any letter case, adds no keys; nor does `desktop.ini`, or anything in the app's `.zzz-mod-manager/` folder.
  The files are read in order of their path inside the mod folder, and Change keys writes into the first of them that has the key's section, so it never edits a file the game ignores.
- **The keys follow the files, whatever changes them.** A mod's keys are kept with a stamp of those files: each one's path, size, modification time and status-change time.
  Every scan takes the stamp again and parses the files only when it differs, so an edit in another program, an update, a Restore or a patch taken out shows its keys on the next scan.
  Stamps are compared for equality, never for which is newer, since a Restore or an archive extraction puts back old modification times. Keys parsed while a file changed under them are not kept.
  A file modified within 2 seconds of the read leaves the mod to be parsed again on the next scan: FAT and exFAT keep modification times to 2 seconds, so a same-size edit such as `VK_1` to `VK_2` inside that window can leave the stamp as it was.
  A folder that cannot be read, as on an unmounted drive, keeps the keys it had. Keys are kept per library folder, so a mod of the same name in another library shows its own.
  The app's own rewrites of a folder (an update, a Reinstall, a patch installed or taken out, a Restore) also drop the mod's keys outright, whether or not the write succeeded, so the next scan parses them again. The stamp alone could miss these: a Restore puts back old modification times, and NTFS file-system tunnelling can give a file written in place of another the old one's times. Those calls are not redundant with the stamp.
- **The library is scanned again when the window regains focus**, so keys edited in another program show on return to the app. A scan that finds nothing changed keeps the list it has (§4).
- **The path is shortened to `~` inside the home folder**, as the status bar shortens it, and **copies itself in full when pressed**. That success is reported: the clipboard can't be seen.
- **Edit info** opens the edit dialog for character, description, tags and pictures.

## 13. Dialogs

- **`components/dialog_section.dart` is where these dialogs get their shape and type sizes.**
  Sizes come from the theme — `bodyMedium` for anything meant to be read, `bodySmall` for the line explaining it, `titleSmall` for a heading — and a group of facts always arrives under a heading saying what the group is for, since text with no marked boundary between ideas reads as one undifferentiated block.
  `DialogNotice(emphasis: true)` is the one "read this" state, in the palette's amber; **at most one per view**, or it stops being emphasis.
- **`bulk_resolution_dialog.dart`** groups rows by their *leading* question so a mod is listed once, and its intro states the one thing not visible from the controls — nothing is written until Save.
- **The update dialog's release notes are an accordion**, so an author's three paragraphs cannot push the verdict off the top of a scroll view nobody asked to grow.
  The header doubles as the section divider and as the thing that *fetches* on the badge path, so one gesture does both.
- **`update_confirm_dialog.dart` is the last screen before a live install is touched**, and everything on it is something that cannot be said afterwards: the snapshot, the accepted keybind loss, a patch-shaped download, and the one question it asks.
  It offers **no way to proceed** against an unreconcilable layout — an "install anyway" there would invite the user to guess where the app refused to.
- **`mod_backups_dialog.dart`** is the rollback, reachable from the context menu only for mods that have a snapshot (`modBackupsProvider`, one readdir for the whole library). The History tab of a mod's page (§15) restores one snapshot through the same `restoreSnapshotFlow`, and the confirmation says a restore removes what was added to the folder since, files the user put there included.
- **`dialogs/download_with_progress.dart` is the app's last *foreground* download**, and the exception rather than the rule — every marketplace download runs in the background queue.
  Applying an update is a conversation (fetch, show what is about to be written over a live mod, write only if they agree), and holding that open across a page switch would mean asking about a mod the user has navigated away from.
  It still goes through the queue, exempt from the concurrency cap on the way in — see [`downloads.md`](downloads.md) §7.
  Only the *download* is shared with the marketplace, deliberately: the marketplace imports an archive as a new mod folder while an update rewrites an existing one, and folding those together is what would produce a shared "install" that quietly does the wrong one.

## 14. The resolve dialog

`dialogs/resolve_origin_dialog.dart`.

- **The content filter degrades `hide` to `blur`, never to `omit`.** Dropping a flagged mod from a search the user is running to identify a mod they *already own* would make that mod permanently unresolvable, with no hint as to why.
- **Both lists are height-bounded and scroll inside themselves**, so the two escape hatches underneath stay one click away.
  Not hypothetical: a captured profile publishes six current files beside eight archived ones, and every one is a row.
  The file list's bound is 230 — anything new in this dialog is paid for by the picker, which scrolls, never by the hatches, which have nowhere to go.
  A test taps them at the minimum window size for that reason.
- **The search box and the file picker are their own widgets** (`components/resolve/`), because a second screen asks the same two questions about the *other* download in a mixed folder.
  Two hand-written copies of the file picker is how "on record" and "our best guess" come to mean different things on two screens.
- **Naming that other download is a pushed step, not a section.** One row appears — only when the folder is recorded as patch-shaped, or from its bottom layer once one has been named — and opens a dialog of its own.
  Inline, a second identity card spends the height budget again and pushes the hatches below the fold, which is the one thing this dialog must not do.
  What that step may write is [`origin-tracking.md` §10](origin-tracking.md#10-a-folder-that-holds-two-downloads).
- **It states what is already recorded before offering to change it**, and preselects the recorded file rather than leaving the answer invisible.
  Every selected row carries a chip naming what put it there, so "on record" and "our best guess" cannot be confused — the ambiguity worth removing is *what selected this*, not *that something is selected*.
  `_hasSomethingToSave` asks the write path (`OriginResolution.pickFile`) whether the result would differ rather than re-deriving the rule, because the interesting cases are not obvious: re-picking an `inferred` row looks like a no-op but is the confirmation that tier waits for.
- **`ResolveOriginGateway` is the local-side seam.** Calling `ApiService` straight from a dialog is this codebase's convention (delete, rename and edit all do) and the default keeps it — but `ApiService` lazily builds a `ConfigService` that writes the developer's **real** `<appData>/config.json`, so a widget test that merely mounted this dialog would clobber their library paths and favourites.

## 15. A mod's page

`mod_page/mod_page.dart` and `mod_page_history.dart`: one mod with the room the panel doesn't have. The details panel's full-page button opens it on Overview, and the panel's "Manage in History" on History. On the All mods table a row pressed opens it on Overview, and so does Details in the mod's menu, since the table has no panel (§16).

**It shows in place of the view it opened from, as state rather than a route.** `openModPageProvider` holds the mod and the tab it opened on, as the marketplace's open mod does; the view stays mounted under it in an `IndexedStack`, kept out of Tab's reach, so going back finds the grid scrolled where it was and the mod still in the panel, or the table as it was left.
The hidden view takes no drop and no Ctrl+V while the page shows: it still has its bounds, and an import there would land where the user can't see it.
The breadcrumb says which view is under it: "Characters / <character> / <mod>" over the character view, "All mods / <mod>" over the table and "Updates / <mod>" over the Updates page, each link going back.
The provider outlives the page, so leaving the Library and coming back through a Library row in the sidebar shows the same mod. The page's Back button, its breadcrumb and a Library row (Characters, All mods or Updates) pressed while a Library view is showing close it.
The page is keyed by what `ModPageRequest.pageKey` fixed when it opened, the folder's uid or its id when it has none yet, so neither a rename nor a uid the first snapshot assigns sends it back to its first tab or fetches again; a mod deleted or gone from a scan closes it.

**Opening it fetches.** The GameBanana page of each download in the folder and the base mod's update feed are fetched once, through the client's response cache, and the pages join `knownModPagesProvider`, so the details panel and the card name the file too. Each download's saved name is rewritten from its page, as after a check.
The panel never fetches because a mod is selected in passing far more often than looked at; opening this page is asking to look at it. A mod marked Local, or with no page, fetches nothing, and a page that fails to load leaves the facts it would have filled absent, with only a log line.
Tracking › change can point the mod at another page, mark it Local or set it up while the page is open, so a change to the tracking or to the pages its downloads name drops the post in hand and fetches again; a fetch that lands after such a change is dropped.

**The note follows the other field.** The panel's note field stays alive under the page, so each field takes the note the other saved whenever it isn't the one being typed in; otherwise the panel would show the note from before and save over the page's on the next keystroke.

**At the top**, the pictures one at a time with arrows and a count, a picture opening large when pressed; beside them the badges (Active, the status badge or "GameBanana" for a tracked mod with nothing to report, the character), the name in the type scale's 30px page title, the favourite star (framed whether starred or not), the author with the file's upload date and "installed on" the install date, the Active box, and Edit info, Open folder, Mod page (the GameBanana page, when there is one), Check for update and Delete.
In the Active box of an agent with One at a time on, the line under "Active in game" says turning it off "leaves the default look": the canvas's "leaves her on the default look" assumes a pronoun, which the app does not.

**The tabs**, with In the folder beside each tab's content once the content area is at least 848px wide, and under it below that:

- **Overview**: the description in full, the tags, the shader-fixes line, Made of N mods (its link switches to History) and the facts.
- **In-game keys**: every key the `.ini` binds, and Change keys, which opens the keybinds dialog, with a line saying a change needs F10 in game.
- **History**, below.
- **Note**: the note of §11, with room to write.

**In the folder** is the side column on every tab: what the sidecar keeps through an update and what the app keeps outside the folder, then Stored at (the library folder, shortened to `~`), Linked as (the link from the ZZMI folder down, `ZZMI/Mods/<folder>` as the canvas writes it, or "not linked" while off) and Tracking, with the file's name for a file on record.
The canvas's "Manager data holds your note, the source link and version history" is not drawn: the note lives in `config.json` (§11), the link is built from the mod id, and snapshots live in `<appData>/backups`.

### History

- **Installed files**: the file in use, then each snapshot newest first (`modSnapshotsProvider`, rebuilt whenever `modBackupsProvider` is invalidated).
  The file in use is named from the page in hand, for a file on record (§5), with "File not known yet" otherwise. Reinstall shows under the same gate as the right-click menu's, `canReinstall`: a recorded file id, confirmed or worked out, and tracking on ([`applying-updates.md`](applying-updates.md) §6).
  A snapshot is named by the file its own copy of the sidecar recorded, when that copy has a file on record and its page is in hand, and otherwise by the time it was saved, with why ("before an update", "before a restore", "before a patch was taken out") and its size. Restore runs `restoreSnapshotFlow`, the same confirmation and write as the backups dialog.
  The line above says only what holds whatever the retention does: older snapshots are cleared as the store fills, and the newest is always kept ([`applying-updates.md`](applying-updates.md) §5). The age floor, the count and the 5 GB budget can all prune, so no number is stated. Snapshots are of the whole folder, so the canvas's "an update keeps the file it replaces" is not said, and the canvas's "change" link has no setting to open.
- **Latest update post**: the newest post in the base mod's feed that has text or a change list, its title, change list and text folded to three lines.
- **Patches on top**, in stack order, "applied over the current file" as the canvas says: each patch's name, file, author, upload date, its files added and replaced counted from its file registry, and whether it is tracked. Take out shows only for a patch `removablePatches` lists and runs `removePatchFlow`; a patch with no file registry, or no page on record, says why it can't be taken out here ([`origin-tracking.md`](origin-tracking.md) §10).
- **Ignored update**, one row per download with `updates_dismissed_until`: the files this session's check listed, when it did, and "Ignoring files uploaded up to <date>". **Stop ignoring** takes the dismissal back (`stopIgnoringUpdate`): the same `withDismissal` write as the update dialog, and the session's verdict re-folded with `refoldDismissal` as the dialog's undo does, since the badge reads that verdict and a rescan alone would leave it quiet until the next check.
  Ignore is in the update dialog and on the Updates page's Newer files rows (§17), both of which show the file you have beside the newer one, so an update is read before it is waved away; it is never on a card or a badge. Taking it back costs nothing to undo, since the badge only comes back, so it is offered here too ([`update-checks.md`](update-checks.md) §6).
  The heading's note says the ignored files stay installable and anything newer brings the mark back. The canvas's "Ignored on <date> · these files won't be offered again" is not drawn: the sidecar stores the upload date the ignore covers up to, not the day it was pressed, and the files are offered again.
- **One write at a time.** A restore, a patch removal, Stop ignoring, an update or Reinstall, or a patch installed into the mod (from Browse or a drop) puts the mod in `modWritesInProgressProvider` while it writes, and History's buttons are held until it is done: a second write into the folder would snapshot it half done. Reinstall has its own progress dialog. The restore and removal flows read the app's container rather than the page's `ref`, so leaving the Library mid-write still reports the result, refreshes the snapshot list and rescans.
- **A restore and a patch taken out show a Working card while they write** ("Restoring a previous version…", "Taking the patch out…"), which becomes the result in place. Both results carry **Undo**, the partial removal's warning too, since both writes took a snapshot first: Undo writes that snapshot back through the same restore, so the Undo is itself a restore that can be undone from the snapshot list.
  Undo waits for a write already running in the folder rather than skipping, since a skip's warning would leave with the button. It says so when the snapshot has since been cleared or the folder renamed or deleted, rather than writing a folder back under the old name, and its own result has no Undo.

## 16. The All mods table

`all_mods/all_mods_view.dart` is the view, `all_mods_rows.dart` decides which rows there are and in what order (pure, so it is tested without a widget), and `all_mods_bulk.dart` holds the bulk actions.
It is every mod in the library in one table, for the questions about the whole library rather than one character: what is on, what has an update, what can't be checked, what to clear out.
Its filter, search, sort, grouping and ticked rows are providers (`allModsFilterProvider` and the ones beside it), like the character view's, since the page is disposed on every page switch.
When the library fails to load, the table shows what the character view shows in its place: why, and Try again.

### The sidebar's rows

- **All mods** opens the table and counts the mods in the library, with no number until the first scan returns.
- **Updates** opens the Updates page (§17). Its count is the mods the last check flagged, with no number at zero. The table's own Updates chip is a filter of the table and leaves All mods the current row.

### The header

"All mods", and under it "N mods across N characters · N active · <size> · updates checked <ago>", with Check all for updates beside it.

- **Characters are the agents with a mod**: the built-in categories and Unassigned are not characters, as the sidebar's Characters count leaves them out.
- **The size is every mod's own files, from one walk of the library** (`librarySizesProvider`): `measureLibrarySync` off the UI isolate, the walk the Storage page runs for Mods ([`disk-usage.md`](disk-usage.md) §4).
  The table shows every mod's size and their total at once, and the character view's per-mod measure (§3) would be an isolate per mod for the same answer.
  The library is walked again when a mod is added or removed or its origin changes, as an update or a restore changes it. A toggle or a favourite changes neither, so it walks nothing. The total joins the line once the walk returns.
- **"Updates checked <ago>" is there only after a check of the whole library finished this session** (`libraryCheckedAtProvider`), whether the user's Check all for updates or the startup check ([`update-checks.md`](update-checks.md) §5.1).
  A check of the ticked mods doesn't set it, and neither does a pass that aborted: either would say the library was checked when only part of it was. Like the verdicts (§8), it is never persisted.
  The line is redrawn every 30 seconds while the page is open, so "2 min ago" stays true.
- **Check all for updates** is the whole-library check ([`update-checks.md`](update-checks.md) §5), with a spinner while it runs, and disabled while any check runs or while no mod can be checked.

### Search, filters and grouping

- **The search matches the name and the character or type.** A Folder missing row is matched by its name. The author isn't searched: it is known only once the session holds the mod page, and nobody looks a mod up by who made it.
- **The chips are All, Active, Off, Updates, Folder missing, Favorites and Can't be checked**, one on at a time, each with its count over the whole table before the search narrows it.
  All counts mods, as the sidebar's All mods row and the header do: a Folder missing row is listed under All but isn't a mod, so it is counted on its own chip only.
  Updates shows no number before a check, as on the character view (§7). Folder missing and Can't be checked are hidden at zero unless on: a filter that can only show nothing is noise (§7), and a chip that is on must stay to be switched off.
- **Can't be checked is the needs-attention set** (§6): Which file?, Base unknown and Not tracked. Its count is blue, the colour of a badge that asks for something.
- **A Folder missing row is listed under All and Folder missing only.** It has no state to be on, off, starred or checked.
- **The table's Updates filter stays on when the last update is ignored**, unlike the character view's (§7): the table then says "No mods match" with Show all, which clears the search and the filter. An empty library says "No mods yet" and how to add one.
- **Group by** is Don't group or Character / type. The groups follow the character list's order (`libraryGroupIds`), with a Folder missing row under Unassigned, since its character is unknown. Each heading has the group's tile and count, and a group with no rows is left out. There is no grouping by status: sorting on the Status column puts Active, Off and Folder missing together the same way.
  Pressing a heading folds its rows away and pressing it again brings them back; the heading stays, with its count. Folds last for the session (`allModsCollapsedProvider`). A folded group's rows count as not shown: select-all, a Shift range and the bulk actions leave them alone, by the same rule as a filter or the search.

### The columns

Mod (the thumbnail, the name, a star for a favourite, and the author once the page is in hand), Character / type, Status (Active, Off or Folder missing), Updates, Size, Added, and ⋯.

- **Updates shows one state per cell** (`updatesCellOf`): the check's verdict wherever the app could check the mod, and what the tracking asks for where it couldn't. It is not the card's status badge (§6), which puts an update over every origin state and says Dated only where this column gives the verdict.

  | The mod | The cell | Press |
  |---|---|---|
  | marked as the user's own (`tracking: "off"`) | Local, grey text | nothing |
  | no identity (`untracked`) | Not tracked, a quiet underlined link | the resolve dialog |
  | identity known, file not (`versionUnknown`) | Which file?, blue | the resolve dialog |
  | a patch whose base nobody named (`secondIdentityUnknown`) | Base unknown, blue, unless the patch's own page has a live update, which shows as below | the resolve dialog |
  | a known file, a worked-out one or a date only, with no verdict this session | "—" | nothing |
  | … with an update, confirmed or resting on a guess | Newer file or Maybe newer, amber | the update dialog |
  | … with nothing newer, or an update the user ignored | Up to date, grey text | nothing |
  | … whose page is private, trashed, or withheld by more than a softhold | Not on GameBanana, grey text, saying why on hover | nothing |
  | … whose check had nothing to judge by (`indeterminate`) | Couldn't check, grey text, saying why on hover | nothing |

  **Which file? is always the prompt.** The check can't judge an unknown file, so the cell asks rather than repeat a verdict about a file nobody named. Base unknown gives way to a live update because the patch's page is one the app could check.
  **Up to date is never shown without a verdict.** A mod with no check this session, a check of ticked mods that didn't cover it, or a rename since ([`update-checks.md`](update-checks.md) §6) reads "—", as the table shows any missing value. A verdict about tracking the mod no longer has, such as one from before the user said which file they have, is no verdict either.
  **An ignored update reads Up to date.** An update is ignored because it isn't the user's file, a different variant say, so the mod is as up to date as it gets; the History tab of the mod's page (§15) still lists it as an Ignored update.
  **A mod marked as current reads Up to date with a tooltip** saying it was checked by the day it was added, not by its file, since "Mark as current" records a date and no file.
  **Grey text with a tooltip has a dotted underline** and the help cursor, so the hover text can be found. The solid underline is Not tracked's alone, since that one is a link.
  **In a folder of two downloads, the verdict is the folder's** ([`update-checks.md`](update-checks.md) §2): an ignored update on one layer counts as up to date, so a layer that couldn't be checked makes the cell Couldn't check, and a patch from a local folder, with no page to ask, is left out, so the cell reads what the mod under it says.
  Not on GameBanana and Couldn't check are grey: nothing in the app fixes either.
- **Size** is the mod's own files, "—" until the walk returns. **Added** is the install date.
- **Every column sorts** when its heading is pressed: the first press sorts by it, the second reverses the order, and the third clears the sort (`AllModsSort.next`), back to the default order with no heading marked. A heading too long for its column with the arrow beside it is shortened rather than overflowing.
  A column newly picked starts in its natural direction: names A to Z, Status as Active, Off, then Folder missing, Updates by need, numbers and dates largest and newest first. Updates by need is Newer file, Maybe newer, Which file?, Base unknown, Not tracked, Not on GameBanana, Couldn't check, Up to date, then Local. A row with no value for the column, "—" in Updates included, goes last whichever way it runs, then rows fall back to name order, so the order never shuffles between rebuilds.
  The default order, the one the table opens in, is newest added first, as the character view's (`AllModsSort.byDefault`).
- **Updates is 172px wide**, the longest state, Couldn't check in Ukrainian, with the cell's padding.
- **At narrow widths columns drop** in the order Added, Size, Updates, Character / type, once the Mod column would be narrower than 200px.

### The rows

- **A row pressed opens the mod's page** (§15). A right-click or ⋯ opens the mod's menu, the card's own; its Details opens the mod's page, since the table has no details panel.
- **The box ticks a mod for the bulk actions.** Shift-click ticks or clears every row from the last box pressed to this one. The heading's box covers the rows shown: it ticks them all unless all are ticked, then clears them, and shows a dash while some are.
- **Only the rows on screen are built**, the group headings and rows being one list, so a large library costs no more than a screenful.

### Folder missing rows

A Folder missing row is a link in ZZMI's mods folder whose target folder is missing and whose name is no mod in the library (`deadModLinksProvider`, over `PlatformService.listDeadModLinks`), read again after every scan, one that finds the library unchanged too (`libraryScansProvider`): a drive plugged in or unplugged changes only the links.
It shows the name, "points at <path>" with the whole path on hover, and the red Folder missing badge, with no box, no menu and no press. While one is listed, a note under the table, in the palette's `noteMissing`, says what it means: the link points at a folder that isn't there right now, for example on an unplugged drive, the link stays, and the mod works again the moment the folder is back.

- **It is read only.** The app never removes a dead link on its own or offers it for removal ([`disk-usage.md`](disk-usage.md) §8): the folder may be on a drive that is not mounted, and the link comes back to life when the drive does. Removing it would lose the fact that the mod was on.
  So the row is a statement with nothing to press, since the one thing to do about it is bring the folder back, and the app can't.
  The link changes only when the user turns on a mod of that name, renames a mod that is on to that name (§10), or when it follows a change of the Mod library to a library that has that mod ([`configuration.md`](configuration.md#changing-the-mod-library)).
- **A link named like a library mod is not a row of its own**: that mod already has its row, which reads as off while the link points anywhere but the mod's own folder (§10). Turning the mod on replaces the link; turning it off leaves it.
- **The path shown is the link's target made absolute**, a relative one resolved against the links folder, a Windows junction's `\??\` prefix dropped and a Windows network target read as its `\\server\share\…` path (`PlatformService.readModLinkTarget`), the same form the on check and a library change compare.
- **A candidate is an entry that lists as a link**, which on Windows takes in junctions and directory symlinks alike, since a listing that doesn't follow links reports every reparse point as one. It is kept only when following it finds nothing. Not yet run on Windows.

### The selection bar

While a ticked mod is shown, a bar floats over the bottom of the table, in the palette's `toast`: "N selected", Enable, Disable, Check for updates, Mark N as current, Delete, and a button that clears the ticks.
When the bar's widest labelled form doesn't fit with 24px to spare on each side, the actions are icons with their label as the tooltip. The widest form counts every mod the table shows as ticked, with Mark N as current showing, so the bar keeps one form whatever is ticked and changes only with the window or with how many mods are shown.
At the smallest window it is icons in English and Ukrainian alike; the labels show from a window about 880px wide in English and 990px in Ukrainian.

**Every bulk action acts only on the ticked rows the table shows.** A tick outlives a change of filter or search, so a mod ticked and then filtered out stays ticked, but it is left out of N and out of every action until it is shown again.
A tick follows its mod through a rename and goes with it on a delete, so a folder that later takes the old name doesn't come in ticked.
An action that reaches mods the user can't see is the failure §9 exists to prevent, and a filter changed between ticking and pressing is the ordinary way it would happen.

- **Enable** can be pressed while a ticked mod is off, **Disable** while one is on. Enable turns each mod on through `ApiService.enableMod`, as the switch does, so under One at a time a character's other mods go off (§10).
  **Two or more ticked mods of one character with One at a time on are all left off**, with a warning naming the characters and asking the user to turn on the one they want. Turning them on in turn would leave whichever came last, which is the app picking which mod stays on.
  A ticked mod of such a character on its own is turned on as the switch would.
- **Enable, Disable, Delete and Mark N as current show a Working card while they run** ("Turning on 3 mods…"), its bar filling per mod, its body the names and a portrait only for one mod. Delete raises it once the user has confirmed. Enable, Disable and Delete's card goes on success, since the table shows it; Mark N as current's becomes its report, "N mods marked as current". Otherwise each becomes the action's report in place, after the notices that come beside it.
- **Enable, Disable and Delete report only what didn't happen**, naming the mods: the table shows what did ([`notifications.md`](notifications.md) §1). Enable reports its failures, the characters it left off, and each mod the shader check refused with the reason, all the mods a missing shader folder kept off sharing one notice. Check for updates and Mark N as current report their outcome.
- **Check for updates checks only the ticked mods** (`LibraryActions.checkMods`) and reports the outcome as a notification. It never opens the tracking screen, which is about the whole library and opens after a whole-library check or from the Updates page (§17), and it doesn't set "updates checked <ago>". It is disabled while a check runs or when no ticked mod can be checked.
  The pages it fetches go to `fetchedModPagesProvider` and add no record to the check's (§8): a record there means the library was checked, and opening the tracking screen would then skip its check and call every other tracked mod unreached.
  A record the check already holds, and a page fetched before, is replaced with the fetched page unless that page is older, by its newest file or its last update. The same goes for every page the app fetches, a mod's page and the update dialog included: they read through the response cache, which the whole check bypasses, so a page fetched after the check can still be the older one.
- **Mark N as current** is §9.
- **Delete** asks first: the names (six, then "and N more"), the total size when the walk has it, how many are on in the game, and how many saved versions go with them, so there will be nothing left to restore.
  Each mod is deleted as the single delete does it, permanently and with its snapshots. The deleted mods' ticks are cleared, and so is the details panel's selection when it was one of them.
- **A ticked mod whose folder is being written is skipped** by Enable, Disable, Delete and Mark N as current: an update or Reinstall, a patch installed into it or taken out, or a restore (`modWritesInProgressProvider`, §15). Each is checked as its turn comes, the others are acted on at once, and one warning names the skipped mods so the user can do them again; a skipped mod stays ticked. Only the ticked mod itself counts: an Enable whose One at a time turns off another of the character's mods while that one is being written goes ahead, and that write leaves it off (§10). Waiting would hold the whole action for the length of someone else's write, and acting would race it: an Enable or Disable against the write's own turning off and back on, a Delete against files being copied in, a Mark against the record the write is about to put down. Check for updates writes nothing for the mods it checks, but the page names it saves afterwards (`ModDownload.name`) leave a mod being written out, silently, since the next fetch of its page saves them.
- **While an action runs the bar's action buttons are disabled** (`allModsBulkRunningProvider`), so a second can't start over the same folders. The flag outlives the page, so leaving for the character view and coming back mid-run doesn't free them. The actions read the app's container rather than the page's `ref`, so leaving the page mid-run still reports and rescans.
  A switch and a bulk Enable never run together, since under One at a time the two could leave two mods on. A mod's switch, on its card, in the details panel and on its page, is greyed out while a bulk action runs; a switch press greys out only the bar's actions (`libraryTogglesProvider`), until it lands.
  **A switch is never greyed out by a press**, its own or another's: a disabled switch drops keyboard focus, so the next Space would reach the card instead. Presses run one at a time in the order made, each on the library as the press before it left it, so two switches pressed together under One at a time leave the later one on; a press that waits for a write is the exception, below. A press asks for the opposite of what its switch showed, so pressing the same switch again before the first press lands does nothing more. A press is never dropped, an import running included.
  **A press on a mod whose folder is being written waits for that write**, then runs: an update or Reinstall, a patch installed into it from Browse or a drop (turn off, snapshot, place, turn back on), a patch taken out, or a restore. Turning the mod on or off in the middle would race the write's own turning off and back on, or link a folder that is half written. A press on another of the character's mods that One at a time makes turn this one off doesn't wait; the write then leaves this one off (§10). The switch is not greyed out, and the wait is outside the queue, so presses on other mods go ahead: such a press lands after the write, and a later press on another mod can land before it. Under One at a time that later mod is then turned off by it, so the mod whose write ended stays on. Keeping the order would hold every other switch for the length of the write. Every such write goes through `whileWritingMod`, which marks the mod in `modWritesInProgressProvider` (§15); Stop ignoring's sidecar write marks it too, for its moment. A press that reaches its turn while a new write has started on its mod waits for that one too.

### Sort these out on Updates

While Can't be checked is on, a **Sort these out on Updates** link under the table opens the Updates page (§17), where those mods are counted with the ways to settle them.

### Drop and paste

A folder or archive dropped or pasted on the table is imported with its character worked out from its name (§3): the table has no character on screen to file it under. Ctrl+V works as on the character view (§1), and in the search field it is the field's paste.

## 17. The Updates page

`updates/updates_page.dart` is the page, and `updates_coverage.dart` sorts the library into its pills and its newer files (pure, so it is tested without a widget).
It answers three questions: how much of the library the app can check for updates, which mods have a newer file, and what it would take to check the rest.
Its state that outlives the page is in providers, as the table's is (§16).

### The header

"Updates", and under it "Last checked <ago>" from `libraryCheckedAtProvider` (§16), redrawn every 30 seconds, or "Not checked since Zenith started" before a whole-library check has finished this session. Beside it, Check all for updates, the table's button.

### Coverage

"N of your M mods checked for updates", over the strip, and a legend with each state's count. A state no mod is in has no legend item.
Before any check the line says "None of your M mods have been checked for updates yet", and with every mod checked "All M of your mods have been checked for updates".

- **Checked means checked this session.** A mod the app can compare counts as "not checked yet" until the session holds an answer from its page: an update, up to date, or the page gone (`answeredByCheck`).
  A page the check can't compare, the mod's own or a patch's in the same folder, keeps the mod from filling in while the check runs: a withheld mod whose profile couldn't be fetched, or a page listing no current files. The verdict decides once it lands: such a mod stays not checked, unless another of its pages has an update, which answers it.
  Like the verdicts (§8), this is never persisted, so a restart leaves every mod the app can check not checked again; the questions still show.
- **A mod not checked yet has no pill of its own.** The strip is a pill per checked mod and per mod that can't be checked, with empty pills between the two to make 60 (`coveragePills`). Each mod checked takes an empty pill's place, and once those run out the strip grows a pill per mod, the pills narrowing as it does. A library with fewer than 60 mods keeps the empty pills it has left.
- **It builds as the check runs.** The check fetches pages 50 at a time and says after each batch which folders it has every page of (`libraryCheckProgressProvider`); their pills fill in then, before the verdicts land.
  The strip fills by position: a pill that changes colour fades from the colour its place shows on screen to its new one, and a place the strip didn't have fades from empty, each a moment after the one before and a batch after the batch before it, so the strip fills from the left. A Base unknown or Not tracked pill changes at once, and with reduced motion the whole strip does.
- **The pills, in this order:** Checked, solid accent; Dated only, the accent washed out; the empty pills; Which file?, blue; Base unknown, a thin accent cap for the checked patch, a gap and a blue body for the base nobody named, its legend item's tooltip saying "The patch is checked, the mod under it isn't"; Not tracked, hatched.
- **The questions are drawn from the start.** Which file?, Base unknown and Not tracked come from the mod's tracking, so no check is needed to know them.
- **Checked is a known file**: one the app downloaded, one the user named, or one worked out in the tracking screen and accepted there. A worked-out file is drawn as a known one, as everywhere: the user accepted it, and the difference changes nothing they do.
- **A folder can be checked only when every layer in it can** (`modOriginStatus`): a known base under a patch whose file isn't known is Which file?.
- **Dated only counts as checked** once a check has compared it by the day it was added. A mod just marked as current is not checked yet until Check them now or the next check.
- **Local mods have no pill and are not in M.** The user said they are never checked, and counting them would keep the line short of all of them for good. The legend says "N Local, not counted", so M can be read against the All mods count.
- Narrow pills lose their gaps, and a library too large for pills at all reads as a bar of segments in the same order.

### Newer files

Every mod the last check flagged (`UpdateCheck.hasUpdate`), the set the sidebar's Updates count covers, newest upload first. A row has:

- the thumbnail, the name, which opens the mod's page, and the character, with the author once the session holds the page;
- **You have**: the installed file and its upload date; "Marked as current" and "the newest on <date>" when the check compared by date, with no installed file named; or "No longer on its page" when the author took the file down;
- **Newer**, or **Maybe newer** when the verdict rests on a guess: the file the update dialog would pick, its upload date and its variant label; or "N newer files" with the newest upload date when no one file is its successor. With no newer file to name it reads "Its page changed": a mod compared by date whose page changed after that date, with "after <date>", or a taken-down file whose page lists only files released with it, with no date. An upload date shown is only ever a file's;
- **Ignore** and **Update**. Update opens the update dialog.

**Ignore writes what the update dialog's Ignore writes** (`ignoreUpdate`): a dismissal on the layer whose page has the update, up to the newest file the check reported, so anything uploaded after speaks up again ([`update-checks.md`](update-checks.md) §4). The row leaves the list, so only a failure is said, and Stop ignoring on the mod's History tab (§15) takes it back.
Ignore is here and in the update dialog because both show the file you have beside the newer one, so an update is read before it is waved away; it is never on a card or a badge.
The write goes through `whileWritingMod`. Ignore is disabled while a check runs, while the mod's folder is being written, and when the check names nothing to ignore; Update is disabled while the folder is being written.

With nothing flagged, the list is one line: before any check this session it says to check, and after one "No newer files since the last check."
Below 760px a row's two files go under its name and buttons.

### Can't be checked

The heading counts the needs-attention set (§6), Which file?, Base unknown and Not tracked, in blue, and shows the count only when there is one. **Hide** folds the section to "Can't be checked N · hidden" with Show, for the session (`updatesCantCheckHiddenProvider`): it is a to-do list, and seeing it again after a restart is the point.
Under the heading, "Zenith finds updates by comparing your file with the mod's GameBanana page. These can't be compared yet.", then two cards side by side, stacked below 760px. The section is left out while there is nothing to settle and no marking to undo.

- **Which file?**: the count with its badge, the portraits of up to five of their characters, the first three names and "and N more", and **See them**. Then what marking does, **Mark all as current…** (§9), and **Pick the files one by one**, which opens the tracking screen ([`origin-tracking.md`](origin-tracking.md) §7).
  Mark all as current… is disabled when none of them can be marked: none has a date added on record, or each asks which file of a patch.
- **"Zenith doesn't know where these came from"**, for both kinds the tracking screen settles: "N mods" Not tracked with the names and See them, "N patches" Base unknown with "Zenith doesn't know which mod they patch.", "Link each to its GameBanana page, or mark your own mods as Local.", and **Sort out tracking…**, which opens the tracking screen. A kind with no mods has no row.

**See them opens All mods on Can't be checked alone**: no search, no folded group and no mod's page left from before (`openAllModsFiltered`). The table has no filter for one of the three kinds, and its Updates column names each mod's.

**The tracking screen opens two ways**: by itself after a whole-library check that turns up something to ask, and on demand from this page's Pick the files one by one and Sort out tracking… ([`origin-tracking.md`](origin-tracking.md) §7). The two buttons run the check first when the session has nothing in hand to show, and are disabled while a check runs.

### Drop and paste

Ctrl+V imports as on the All mods table (§16), with each mod's character worked out from its name. A folder or archive dropped on the page does nothing.

### Undoing a marking

After Mark all as current…, once the library is read again, a card "N mods marked as current" with the Dated only badge comes first among the cards: "Anything uploaded after the day you added one now shows under Newer files.", **Check them now**, which checks only those mods, and **Undo**, disabled while a check runs. The Which file? card is under it while any mod still asks, and gone when none does.
What was written shows as that card. A failure is said, the mods skipped because their folder was being written are always named, and other skips are said only when nothing was written.

`lastMarkingProvider` holds the marking: each mod written, with its base download as it was and the date written. It lasts until Undo leaves nothing to undo, the next marking, or the app closing.

**Undo puts back each mod's base as it was before the marking** (`undoAssumeCurrent`), where the base still holds what the marking wrote. A mod given a file since, or marked again, is left as it is: the user answered it another way, and undoing the marking must not undo that.
A mod whose folder is being written is skipped and named. A write that fails, or a folder gone since the marking, is said in one notice, with a line for each of the two naming its mods. The skipped ones and the failed writes stay in the marking, so Undo can be pressed again, and the card goes once nothing is left to undo; a folder that is gone can't be found under that name again, so it leaves the marking.
The session's check by date on a mod put back goes with the date: a folder of one download loses its verdict, and in a mixed folder the base's verdict is taken back and the folder folded again, so a patch's own update stays and nothing about the base comes back on an Ignore. A base whose page was found gone or couldn't be compared keeps that verdict in either, since no file would change it.
