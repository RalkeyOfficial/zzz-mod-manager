# Notifications — how the app talks to the user in passing

**Scope:** everything raised through `context.notify` — whether a message exists at all, what it says, what it looks like, and how long it stays.
Owns `utils/notifications.dart`, `models/app_notification.dart` (`NotificationKind`, `NotificationAction`, `NotificationRepeat`, `NotificationLines`, `AppNotification`) and `screens/components/notification_overlay.dart`.

Not in scope: dialogs (a notification never asks a question), and the wording of any individual message, which lives in `assets/l10n/`.

**Never call `ScaffoldMessenger`.** `context.notify.<kind>(…)` — `working`, `done`, `note`, `updateAvailable`, `needsYou`, `warning`, `error`, or `show(kind, …)` — is the one way to raise a message, and `grep showSnackBar lib/` returning nothing is the check that it stayed that way.

---

## 1. Whether to raise one at all

> **A change the user can see reports only its *failure*. A change they cannot see may report its success.**

Enabling a mod flips a switch under their cursor and favouriting one fills a star, so neither says anything. Downloading a mod drops a file in a folder they would have to go and look at, so it does.

Deleting is the case worth remembering, because it looks like an exception and is not: the card disappears from the grid *and* they confirmed it in a dialog, so only the failure speaks.
That is also what keeps red meaning "it did not work" rather than being the colour of both outcomes of the same action.

Successes that survive this rule, and why: an archive downloaded (the path is the whole point), a mod installed (it lands in a tab you are not looking at), a backup restored (files on disk), settings saved, and every count-bearing bulk report — the count and any partial failure *are* the message.

**Work in progress is the other survivor, and it is a Working card rather than a message.** A background download has no visible effect until it lands, so it reports itself while it runs, non-blockingly, with a bar.
See [`downloads.md`](downloads.md) §9 for the download queue's card, and §6 below for the mechanism. Dragging a mod onto a row of the character list raises one too, with a sweep, for the moment the tag is written.

**The F10 reminder is not raised.** A Note with a keycap in its body and an Undo exists for "Ellen Swimsuit is on / Press F10 in game to load it", and a widget test draws that card.
Nothing raises it until the "Remind me to press F10" setting and the signal that the game is running exist, since turning a mod on is a change the user can see.

## 2. The two levels

> **`title` is what happened. `body` is what it happened to.**

Both are required at the API and non-nullable on the model. That is not ceremony: an optional headline is a headline nobody fills in, and then every card is a lone line and "Mod downloaded" never says which mod.

The body **names the subject; it does not describe the work.** The install confirmation is the case that shows it: listing the auto-tags and the metadata fields copied off the mod page makes the one fact being waited for the hardest line to find, and narrates the app's own bookkeeping about work whose result is on the card a second later.

| | |
|---|---|
| ✅ | `Mod installed` / `Ellen Swimsuit` |
| ❌ | `Mod installed` / `Auto-tagged Ellen, copied 4 fields from the mod page` |

Where a call site has no subject in hand, the body is **the single next step the user can take** — never a restatement of the title. If there is neither a subject nor a next step, that is a sign the notification shouldn't be raised at all.

What a caller genuinely cannot drop is what the user must *act* on (no `.ini`, a patch-shaped download, a sidecar that could not be written).
Each of those goes beside the success as **its own card with its own two levels**, never as more text under it: a broken install must not be reported in the same colour as a clean one, and three problems joined by newlines are three notifications, not one.
`NotificationLines` carries each one's kind, whether it stays, and a portrait of its own where it is about another mod than the install's (a patch written into an existing mod shows that mod's character, not the download's).

**A report may not open with a success the operation did not deliver.** The drag/drop import ends in a dialog of its own, and when a patch could not go into the mod the user picked it says *"Installed, but not as you asked"* over an amber mark, lists which of the reasons it was, and states what happened instead — the user asked for one thing and got another, and "Imported successfully" over that is the one sentence it must not print.
Its button drops to **"Got it"** as well: "Great!" is the app being pleased with itself about an install that did not do what it was told, and the only honest control over a warning acknowledges it.
It also stays shut when there is nothing new to report: with every folder written into a mod that already exists, no card appears in the library, and a dialog announcing "0 mods imported" is worse than none — the *patch applied* notification is that install's report.

The dialog carries the **headlines** (`patchRefusalHeadlines`) while the cards carry the full explanation and what to do about it. Two copies of one paragraph on screen at once is clutter; the same wording split by granularity is not.

**A warning stays until it is closed** (`stays: true`), rather than leaving after the Warning kind's eight seconds, in two cases. Every other warning leaves on its clock.

- **A mod that does not work until the user acts**, on both import paths and after a rename that left the mod off. Eight seconds is enough to read that something is wrong and not enough to do anything about it, and an install's card is raised beside the success line the user was actually waiting for.
  A patch is the case: until the mod it patches is in the folder with it, nothing happens in the game and there is no error anywhere to explain that. "The mod may be incomplete" does *not* stay — it describes a folder that is simply not a mod, where there is nothing to finish.
- **Something the next action will likely fail on until the user fixes it**, such as the DNS before a launch: the Launch game warning that names can't be looked up inside umu-launcher's container stays, since the game's anti-cheat will close the game until the DNS is fixed, and the user is looking at the game when the warning arrives.

**The result ends the burst.** `install_result_feedback` raises the **warnings first and the result last**, and a Working card turned into its result moves to the newest place, so the line that concludes an install is the lowest card whatever was raised while it ran.

## 3. The leading slot

Two tiers, answering "what is this about": the **portrait** of the mod's character, on its element tile (`CharacterTile`, 32px, radius 9), with the kind as an 18px **badge** on its bottom-right corner; else the **kind's icon** on its 28px tile.
An explicit `icon:` replaces the kind's icon and keeps its colours.

The badge is a 14px fill cut out of the portrait by a 2px ring in the card's ground (the error ground on an error card), so it reads against one known colour rather than against whichever pixels the artwork has at that corner.
A Working badge is the spinning arc, Done a check, Error a cross, Update an up arrow, Warning an exclamation mark, Needs you a down arrow, each 10px. A Note has no badge: there is nothing to add to the face.

A mod filed under a category (UI, Texture, Audio, Misc), Unknown or Unassigned has no portrait and gets the kind's plain icon; the category is not drawn.

`AppNotification` asserts `icon` and `characterId` are never both set — otherwise the icon wins and the portrait vanishes with nothing to explain it.

**A card about several mods gets no portrait.** A whole-library check, a bulk action or a counted repeat (§7) is *about a count*, so one arbitrary face would claim the message is about that mod — and which mod sorted first would change between runs.
A bulk report about exactly one mod does carry its portrait.

Portraits resolve through `CharacterAvatar.assetPathFor`, which returns null when there is no portrait. That check runs *before* a tile with an `Image` is chosen: `getCharacterAssetName` falls back to the id itself, so a category-filed mod would otherwise ask the bundle for `cat_misc.png` and hit `errorBuilder` on every render.

## 4. The kinds

**The kind is the only thing a call site decides about the look.** Colour, icon, badge and duration come from it in one place: `notificationLook` in the overlay, and `kNotificationDurations` on the model.
Chosen per call site they come from whatever is nearest, so the same kind of event looks different depending on which screen raised it.

| Kind | Means | Tile | Icon | Badge on a portrait | Stays |
|---|---|---|---|---|---|
| Working | work still running | `hover` / `textProse` | spinning arc | arc, `line` / `text` | until its owner ends it |
| Done | something asked for finished | accent 16% over the card / accent | check | check, `accent` / `onAccent` | 5s |
| Note | a plain fact, nothing at risk | `hover` / `textProse` | info | none | 5s |
| Update | newer files were found | `badgeUpdate` | circled up arrow | up arrow, `amber` / `onAccent` | 8s |
| Needs you | something waits on a decision | `badgeInfo` | download arrow | down arrow, `blue` / `onAccent` | until closed |
| Warning | it worked, but not all of it, or needs attention | `badgeUpdate` | triangle | exclamation, `amber` / `onAccent` | 8s, or until closed with `stays` (§2) |
| Error | it did not work | `badgeMissing` | circled cross | cross, `red` / `onRed` | until closed |

The card is `notification` (`notificationError` for an Error) with its border, 380 wide, radius 12, casting `notificationShadow`. Title `bodyMedium` w600 in `text`, body `bodySmall` in `text2`.

Picking a kind: a fact with nothing at risk is a Note even where it reads like a warning ("the clipboard is empty", "everything was already in the library").
A "warning" that reports an outright failure is an Error ("tracking not saved", "the game did not start"). An error after which the change partly happened is a Warning ("renamed, but left off").
An archive that held no mod folder is a Warning: the download worked, but nothing came of it.

**An Error stays until it is closed.** It is text the user has to read and possibly act on, and a run of them folds into "+N more" (§5) rather than filling the corner. Needs you stays for the same reason. Nothing raises Needs you yet; the Downloads panel's decisions will.

## 5. The stack and the clock

- **Why not Material's snackbar.** Two reasons, and the second cannot be styled away. A `ScaffoldMessenger` shows **one bar at a time and queues the rest**, so an install with three things to say would show them in sequence, each replacing the last.
  And the bar lives *inside* the `Scaffold`, so a modal dialog's barrier covers it — which is where a large share of these messages are raised from.
- **The host is mounted in `MaterialApp.builder`, above the `Navigator`.** That is what puts a notification over a dialog.
  It is also why the close button carries a **semantic label rather than a `Tooltip`**: a tooltip needs an `Overlay` ancestor, and this layer is a *sibling* of the navigator, so one throws "No Overlay widget found" the first time anything is raised. No `Tooltip` anywhere in this layer.
- **Bottom right, above the status bar.** The stack sits 14px from the right edge and 14px above the 28px status bar, newest at the bottom, 8px between cards. The first-run screen has no status bar and the stack sits at the same height there.
  A column taller than the window scrolls, reversed so the newest stays in view.
- **Three show; the rest fold into "+N more".** The pill sits at the top of the stack. Pressing it shows every card and reads "Show fewer"; pressing that folds back to three, and it folds by itself once three or fewer are left.
  A folded card is still built, offstage, so it keeps its clock: a Done runs out unseen and the count drops, while an Error waits. A card folded while it is leaving is taken off at once, since its exit can't play offstage.
- **The queue holds no timers; the card owns the clock.** The timer has to stop while the stack is being read, and only the widget knows where the pointer is. `NotificationCenter` therefore stays a synchronous list, and its tests assert about a list rather than about elapsed time.
- **Hovering holds the whole stack, folded cards included.** "Is the pointer here" is one fact, owned by `NotificationOverlay` and passed down as `paused`, with a single `MouseRegion` around the pill and the column — which also covers the gaps between cards, so travelling from one notification to the next never counts as leaving.
  Per-card pausing is wrong twice over: the third message expires while the pointer rests on the first, and the stack reflows out from under the pointer as it goes.
  A notification raised *while* the pointer is already there arrives held, and leaving **restarts the full duration** rather than resuming. A card's clock also restarts when its kind, title, body or count changes.
- **News during an exit keeps the card.** A repeat counted on a card that is leaving, or the result of a Working card the user just hid, calls the exit off, so what arrived is read rather than lost with the card. A Working card's own progress is not news.
- **Motion.** A card enters in 220ms (grow, fade, slide from the right) and leaves in 140ms. Under reduced motion there is no slide, grow or fade, so a card appears and leaves at once; the spinner and the sweep stand still, and the bar jumps.

## 6. Working cards, and `update`

`working(…)` raises a card with no clock and hands back a `NotificationHandle`. Its bar along the bottom edge is `progress`, 0 to 1; null draws a sweep for work of unknown size.
`update()` rewrites it in place (same id, so the same card and hover state) and `dismiss()` removes it.

**Changing the kind turns the card into its result.** `update(kind: done)` (or note, warning, error) drops the bar, takes the new kind's clock, and moves the card to the newest place, so it concludes the burst (§2).
A lone download's card becomes "Mod installed" this way, and a failed tag save becomes its error instead of raising a second card beside the first.
A result given a repeat that a card in the stack already holds is counted on that card instead (§7), so two lone downloads in a row end as one "2 mods installed".

**In a Working card the body is what stays put.** The drag-a-mod-onto-a-character flow raises "Saving tag… / Ellen Swimsuit" and, because the card visibly moves on success, simply `dismiss()`es. Where an update *is* wanted, it rewrites the title and the subject carries over untouched.

That is why **raising one requires both levels while every parameter of `update` is optional**: raising builds a whole statement, updating changes part of a statement that already exists. There is no `clearTitle` and no `clearBody`, because neither has a "back to nothing" state.

**Hiding a Working card never hides its result.** Its close button reads "Hide". `close(id)` keeps the card's last state aside: progress updates to it stay silent, `dismiss()` forgets it, and an update that turns it into a result raises that result as a card again.
The download queue only turns its card into a result when the card covered one job, so hiding the queue's card holds until a new download starts.

**The handle is safe to hold past the end.** The user can close any notification at any moment, so `update`/`dismiss` on one that is gone do nothing rather than throw.
Pass the character id into `working()` **up front** rather than reading it at the update line — that line runs after an await with no `mounted` check.

## 7. Repeats and de-duplication

**A repeat is counted on one card.** A raise carrying a `NotificationRepeat` whose key matches a card of the same kind takes that card's place: same id, its subjects added and the count raised by as many, moved to the newest place, its clock restarted.
The count is of subjects, not raises: an install counts its folders, so an archive of three and one more mod read "4 mods installed".

Counting more than one, the title is the repeat's counted title ("3 mods installed"). A body that says more than its subject keeps saying it, in its counted form, with the subject list ("A and B", "A, B and 1 more") under it: the patch and shader-file cards keep what was saved and what to do.
Where the body was only the subject, as on the install card, the subject list replaces it. The portrait and the actions go, since both were about one mod. The keys in use: `install-done`, `patch-applied`, `asset-patch` and `shader-adopted`.

**The same sentence again moves the card instead of stacking a copy.** Re-raising an identical **(kind, title, body)** without a repeat moves it to the newest place with a new id and restarts its clock.
`icon` and `characterId` are deliberately **not** in that key — they are pictures of what a notification says, not part of what it says, so the survivor is the newer object and carries the *current* face.
The predicate lives on the model as `saysTheSameAs` rather than inline in `show`, so the next field added has to answer that question rather than silently join or miss the key.

**The backstop.** Nothing is dropped for being old: the fold keeps the corner small. Past `kKeptNotifications` (20), the oldest card *with a clock* goes.
A card with no clock is waiting for something — an owner holding its handle, or a reader who has not seen an error yet — and dropping it throws away the only report of that. A stack of nothing but such cards still obeys the backstop.

## 8. Actions and the keycap

A card carries **at most two actions**, as flat text buttons 30px tall and 6px under the body, filled under the pointer. A button reaches 8px past its label on either side, so the label lines up with the title while the area that takes a press is larger than the text. The first is primary, in `link`, on every kind but a Note, where both are in `text`: a Note's action is an option, not the next step.
Pressing one runs it and closes the card, unless it was built with `closes: false`.

Actions reach the app through a `ProviderContainer` the call site captured when it raised the card, since this layer has no `Navigator` or `Overlay` above it and the widget that raised it may be gone. The ones in use:

- **Review** on an Update card from a library check or the startup check: clears any open mod page and opens the Updates page.
- **Open** on the install card for one folder: shows the installed mod in the Library's Characters view, its character's row selected and its details panel open (`showModInCharacters`).
  A mod removed or renamed since is not shown; a Note says it is no longer in the library. There is no "Turn on": Browse's "Turn on after installing" switch decides that before the install.

**A keycap in the body.** A body holding `{key}` with `keycap: 'F10'` draws a `Keycap` there (`keycapSentence`), so each language puts the key where its own word order wants it. The log writes the key in its place.

## 9. Call-site mechanics

- `context.notify` resolves through `ProviderScope.containerOf(listen: false)`, so it is legal in `initState`, in a dialog builder, and in a plain function handed a context. **Capture it in a local before an `await`** and the report survives the widget being disposed.
- **Capture the character id early too.** A mod the marketplace has just installed is not in `modsProvider` until something rescans, and the report is raised before that.
  Use the id the work already had (`remote.characterId`, `mod.characterId`) rather than looking one up at report time. Never fall back to `detectCharacterId(name)` — a substring guess this codebase refuses to trust.
- **Every notification is also logged**, once, from inside `NotificationCenter.show` — the funnel every raise and every repeat passes through — and again when an update turns a card into its result. Call sites do nothing for this.
  The line carries the kind, title and body as the user saw them, localized text and all, plus the repeat's key and count, so the log shows what was on screen beside the failure that put it there. See [`logging.md`](logging.md).

## 10. Testing

- Widget tests get the host from `test/support/localized_harness.dart`, which mounts it exactly as `main.dart` does. Pass `brightness: Brightness.light` to render on paper.
  A test that needs to read state back must pass its `ProviderContainer` as `pumpLocalized(container:)` rather than nesting an `UncontrolledProviderScope` **below** `home` — a nested container is a second, invisible queue, and the assertion would run against an empty screen.
- **A Working card never settles.** Its spinner and sweep repeat forever, so `pumpAndSettle` times out while one is on screen. Pump fixed durations, raise it after the harness has settled, or close it first. A test that leaves a Done or Note card up runs past its clock before ending.
- **Assert about a portrait through the `AssetImage`'s `assetName`, never through pixels.** `Image.asset` resolves asynchronously and `pumpAndSettle` does not wait for real async I/O, so a pixel assertion passes vacuously.
- `test/l10n_keys_test.dart` enforces that every `_body` key has a `_title` sibling, that en/uk stay at exact parity, and that no value is empty. A missing key renders as a raw dotted path on screen with no exception.
- `test/character_assets_test.dart` keeps the roster and `assets/characters/` in step, so a character added before its art fails CI rather than rendering a silhouette.
