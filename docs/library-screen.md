# The library screen — the character view and its surfaces

**Scope:** the Library's character view — the character list, a character's header, the mod grid with its card and status badge, the row above the grid with the library menu's bulk actions, One at a time, notes, the details panel, a mod's page with its History tab, and the dialogs reached from a mod.

Not in scope: the rules about origin *states* and what each answer may write ([`origin-tracking.md`](origin-tracking.md) §4–§5), the update comparator ([`update-checks.md`](update-checks.md)), or how an update is written to disk ([`applying-updates.md`](applying-updates.md)).
What follows is only what is specific to these widgets.

---

## 1. The page

Three columns: the character list, the character on screen (their header, the row of filters, their mods), and the details panel for the mod selected among them.
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
Picked means clicked in the character list; a character the app put on screen does not count. The page shown before the user picks one is a fallback, the sidebar's Updates button jumps to a character of its own choosing, and filing five archives for five agents under either would be the app's guess, not theirs.
There, and on Unassigned, the character is worked out from each mod's name. The drop tile says which of the two a drop will do.

## 4. A rescan only reaches the grid if the library came back different

The scan belongs to `libraryProvider` ([`app-architecture.md`](app-architecture.md) §3), and it runs after every toggle, rename, edit and import — most of which change one mod or nothing.
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
- **The line under the name** is the author and "file from <date>" once this session's update check holds the mod page and the file on record is confirmed, and "added <date>" otherwise. The sidecar records neither the file's name nor its upload date, and the card never fetches to find out. A file only worked out is not stated as the file.
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
| a file worked out, not confirmed (`versionGuessed`, `inferred`) | Guessed file | grey | the resolve dialog |
| no identity (`untracked`) | Not tracked | grey | the resolve dialog |
| the user marked it their own (`tracking: "off"`) | Local | grey | nothing |
| known exactly (`none`) | no badge | | |

**Amber is an update, blue asks for something, grey states a fact.** Amber is the only state carrying something the app went and fetched.
Blue is what one pass through the resolve dialog settles for good. Grey is what most of an older library is, and a loud mark on every card would teach the user to stop seeing the badge, after which the state that *does* ask could never be noticed either.

**The two update badges are keyed on the outcome, never on `isGuess`.** A mod recorded at `exact`/`exact` whose author published a newer file under a different label is `possiblyOutdated` with `isGuess` false;
read off `isGuess`, the card would say "Newer file" while the update dialog for the same mod says "possibly outdated".

**Local is not Not tracked.** Local is the user's own answer to "where is this from", shown back to them, and a mod marked so is never checked. A mod with no identity is merely untracked, and is never called local.
`tracking: "off"` is tested before everything else, so a Local mod never shows an update or asks for anything.

**Dated only and Guessed file are one state said two ways.** "Mark all as current" records a date and no file, and calling that a guessed file would describe a file nobody named.

**`secondIdentityUnknown` is its own state** rather than folded into Which file?, because that sentence would be false: a patch downloaded by this app knows its file exactly, and the unknown is the *other* mod in the folder.

**The "needs attention" filter counts `secondIdentityUnknown`**, because the user can finish it — naming the base mod clears it — and finishing it moves the count.
A filter whose number can never reach zero is noise.
The bulk "assume current" pass does **not** read the badge for its own eligibility: this state outranks `versionUnknown` there, and reading it would quietly stop that pass dating mods it dates.

## 7. The row above the grid

**The filter chips** — All, Active, Updates, Favorites — each with the count for the character on screen. **Needs attention** joins them while any mod here needs it, or while it is on: the answer is usually nothing or most of the library, and both are worth knowing before pressing rather than after.
One filter at a time, like the chips that set them.

**The Updates chips show no number until a check has run**, the one above the grid and the one in the character list alike. "0 updates" and "not checked" are different claims, and a zero before any check would make the first.

**The Updates filters switch themselves off** when the library has no updates left, keyed on the library rather than on the character: on the character's own count the filter would vanish whenever the user looked at someone with no updates of their own.

Then **One at a time** (§10), absent on Unassigned, the sort, and **the library menu**.

**The library menu holds the bulk actions** — check for updates, sort out tracking, mark all as current — each with the count of mods it would act on and disabled when it can do nothing, except *sort out tracking*, which is offered at zero because it runs the check itself rather than greying out the most useful entry on launch.
Grouping them is what gives the resolution screen a door to be re-opened from. The menu also reads the library again, `.ini` files included.

**The check and the tracking screen run in `LibraryActionsHost`, above the page switcher**, like the download queue's host. A check over a large library takes seconds, and the page is rebuilt for every character and disposed on every page switch: owned by the page, a pass would lose its results and its report the moment the user looked elsewhere.
`libraryCheckRunningProvider` says a pass is running, and every control that would start another — the menu, the reminder's button — is disabled until it ends.

**A reminder sits under the row while any mod in the library needs attention**, saying how many and carrying the *sort out tracking* action, in the blue of tracking.
It counts the whole library rather than the character, since it is about the state of the user's mods and not about who they happen to be looking at.
Its close button records the dismissal in config, so it stays away across restarts; the **Updates** section in Settings has a switch that brings it back.
It is a strip rather than a dialog or a notification: a dialog would stand between the user and their mods on every launch until they acted, and a notification would be gone in eight seconds with nothing to press.

## 8. Check results are session state

`modUpdateChecksProvider`, and the records behind them `modUpdateRecordsProvider` — **never persisted**.
A verdict restored from disk asserts something about a mod page nobody has looked at since.
Keeping the *records* is what lets the resolution screen be re-opened without a request, and what lets the card and the details panel name a file and an author without one.

Two scopes meet here deliberately: the check covers the whole library (its badges are drawn on every character), the filter covers the character on screen (that is all it can narrow).

**A check reports through one surface, not two.** With nothing to resolve it raises the summary notification; with mods whose origin can be sorted out it opens `dialogs/bulk_resolution_dialog.dart`, which states that summary itself.
Raising a notification behind a modal is how a user ends up reading neither.
The spinner is cleared **before** the dialog opens — the request is what it reports, and one turning behind a dialog says the app is still working while disabling the control they would press next.

## 9. Bulk "assume current" turns the filter on before it confirms

`services/bulk_assume_current.dart`, `dialogs/assume_current_dialog.dart`. It acts on the character on screen.
The rule is that the user must have *seen* the set being rewritten, and it is enforced by the action: it turns the Needs attention filter on, then confirms, and puts the previous filter back if the user cancels.

**Its plan comes from `visibleModsProvider`, the list the grid renders once that filter is on**: a control that rewrites more mods than it displays is exactly what this rule exists to prevent.

**The menu's count is taken over the same set** (`characterAssumeCurrentCountProvider`), whichever filter is on when the menu opens. Only one filter is on at a time, so the grid at the press can show more or fewer of the character's mods than the action will; the count is planned over all of them, and every mod the plan can date needs attention, so it is the count that gets written.
See [`origin-tracking.md`](origin-tracking.md) §6 for the four rules it enforces.

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

A failure in step 2 stops the enable rather than leaving two mods on under a switch that says one. A failure anywhere is reported, and the page reads the disk again to show what is really on.

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
File and Uploaded also need the file on record to be confirmed (`exact` or `user`), as the card's "file from" does: a file only worked out is not stated as the file.

**The name is the type scale's `titleLarge`, 17px, where the canvas draws 18px.** The type scale has no 18px role, so the difference is kept on purpose rather than adding a size for one line.

| Fact | Shown |
|---|---|
| File | the recorded file's name, from the page in hand, for a confirmed file only |
| Variant | the recorded version label, when there is one |
| Uploaded | for a confirmed file only, the file's date, with "nothing newer" or "a newer file is out" when the last check said so about the base mod; a patch's verdict is never put on the base mod's file |
| Tracking | GameBanana · change, Not tracked · set up, or Local · change; the second half opens the resolve dialog |
| Added | the install date, whether the app saw the install or worked it out from the oldest file |
| Size | the mod's own files, as in the header |

- **Check for updates is offered only with an identity to check**, and not for a mod marked Local, which is never checked; for either the update dialog would say so and nothing else, and Tracking's "set up" or "change" is the way in.
- **Ignoring an update is not here.** It lives in the update dialog with its undo, where the finding is read before it is waved away ([`update-checks.md`](update-checks.md) §6). Taking one back is also on the History tab of the mod's page (§15).
- **Made of N mods lists the folder's stack** (`origin.downloads`), base first and patches on top, and is absent for a folder with one download ([`origin-tracking.md`](origin-tracking.md) §10).
  Each row has a Base or Patch badge, the name, which links to its page, and, once the session holds that layer's page, its author and, for a confirmed file, the file's name and upload date. A patch's file is never put on the base's row.
  The name is the page's when it is in hand, else the one saved with the layer (`ModDownload.name`), else the id. It is never the folder name for a layer with an id: a patch installed as its own folder names the folder after the patch's archive ([`origin-tracking.md`](origin-tracking.md) §10).
  "Manage in History" under the list opens the History tab of the mod's page (§15), where a patch is taken out, for every folder the list shows.
- **In-game keys leave out the `no_` tokens**, which name a modifier that must *not* be held, so the caps show what to press.
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

`mod_page/mod_page.dart` and `mod_page_history.dart`: one mod with the room the panel doesn't have. The details panel's full-page button opens it on Overview, and the panel's "Manage in History" on History.

**It shows in place of the character view, as state rather than a route.** `openModPageProvider` holds the mod and the tab it opened on, as the marketplace's open mod does; the character view stays mounted under it in an `IndexedStack`, kept out of Tab's reach, so going back finds the grid scrolled where it was and the mod still in the panel.
The hidden view takes no drop and no Ctrl+V while the page shows: it still has its bounds, and an import there would be filed under a character the user can't see.
The provider outlives the page, so leaving the Library and coming back through the sidebar's Characters row shows the same mod. The page's Back button, its breadcrumb, the Characters row pressed while the Library is showing, and the Updates row close it, Updates because the characters with an update are what it shows.
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

**In the folder** is the side column on every tab: what the sidecar keeps through an update and what the app keeps outside the folder, then Stored at (the library folder, shortened to `~`), Linked as (the link from the ZZMI folder down, `ZZMI/Mods/<folder>` as the canvas writes it, or "not linked" while off) and Tracking, with the file's name for a confirmed file.
The canvas's "Manager data holds your note, the source link and version history" is not drawn: the note lives in `config.json` (§11), the link is built from the mod id, and snapshots live in `<appData>/backups`.

### History

- **Installed files**: the file in use, then each snapshot newest first (`modSnapshotsProvider`, rebuilt whenever `modBackupsProvider` is invalidated).
  The file in use is named from the page in hand, for a confirmed file only, with "File not known yet" otherwise. Reinstall shows under the same gate as the right-click menu's, `canReinstall`: a recorded file id that is confirmed, and tracking on ([`applying-updates.md`](applying-updates.md) §6).
  A snapshot is named by the file its own copy of the sidecar recorded, when that file is confirmed and its page is in hand, and otherwise by the time it was saved, with why ("before an update", "before a restore", "before a patch was taken out") and its size. Restore runs `restoreSnapshotFlow`, the same confirmation and write as the backups dialog.
  The line above says only what holds whatever the retention does: older snapshots are cleared as the store fills, and the newest is always kept ([`applying-updates.md`](applying-updates.md) §5). The age floor, the count and the 5 GB budget can all prune, so no number is stated. Snapshots are of the whole folder, so the canvas's "an update keeps the file it replaces" is not said, and the canvas's "change" link has no setting to open.
- **Latest update post**: the newest post in the base mod's feed that has text or a change list, its title, change list and text folded to three lines.
- **Patches on top**, in stack order, "applied over the current file" as the canvas says: each patch's name, file, author, upload date, its files added and replaced counted from its file registry, and whether it is tracked. Take out shows only for a patch `removablePatches` lists and runs `removePatchFlow`; a patch with no file registry, or no page on record, says why it can't be taken out here ([`origin-tracking.md`](origin-tracking.md) §10).
- **Ignored update**, one row per download with `updates_dismissed_until`: the files this session's check listed, when it did, and "Ignoring files uploaded up to <date>". **Stop ignoring** takes the dismissal back (`stopIgnoringUpdate`): the same `withDismissal` write as the update dialog, and the session's verdict re-folded with `refoldDismissal` as the dialog's undo does, since the badge reads that verdict and a rescan alone would leave it quiet until the next check.
  Ignoring stays in the update dialog only, where the finding is read before it is waved away; taking it back costs nothing to undo, since the badge only comes back, so it is offered here too ([`update-checks.md`](update-checks.md) §6).
  The heading's note says the ignored files stay installable and anything newer brings the mark back. The canvas's "Ignored on <date> · these files won't be offered again" is not drawn: the sidecar stores the upload date the ignore covers up to, not the day it was pressed, and the files are offered again.
- **One write at a time.** A restore, a patch removal or Stop ignoring puts the mod in `modWritesInProgressProvider` while it writes, and History's buttons are held until it is done: nothing else on screen shows the write is running, and a second write into the folder would snapshot it half done. Reinstall has its own progress dialog. The restore and removal flows read the app's container rather than the page's `ref`, so leaving the Library mid-write still reports the result, refreshes the snapshot list and rescans.
