# Notifications — how the app talks to the user in passing

**Scope:** everything raised through `context.notify` — whether a message exists
at all, what it says, what it looks like, and how long it stays. Owns
`utils/notifications.dart`, `models/app_notification.dart` and
`screens/components/notification_overlay.dart`.

Not in scope: dialogs (a notification never asks a question), and the wording of
any individual message, which lives in `assets/l10n/`.

**Never call `ScaffoldMessenger`.** `context.notify.success(…)` / `.info` /
`.warning` / `.error` is the one way to raise a message, and
`grep showSnackBar lib/` returning nothing is the check that it stayed that way.

---

## 1. Whether to raise one at all

> **A change the user can see reports only its *failure*. A change they cannot
> see may report its success.**

Enabling a mod flips a switch under their cursor and favouriting one fills a
star, so neither says anything. Downloading a mod drops a file in a folder they
would have to go and look at, so it does.

Deleting is the case worth remembering, because it looks like an exception and is
not: the card disappears from the grid *and* they confirmed it in a dialog, so
only the failure speaks. That is also what keeps red meaning "it did not work"
rather than being the colour of both outcomes of the same action.

Successes that survive this rule, and why: an archive downloaded (the path is the
whole point), a mod installed (it lands in a tab you are not looking at), F10 sent
(it happens inside the game), a backup restored (files on disk), settings saved,
and every count-bearing bulk report — the count and any partial failure *are* the
message.

## 2. The two levels

> **`title` is what happened. `body` is what it happened to.**

Both are required at the API and non-nullable on the model. That is not ceremony:
the optional version shipped, and **not one of the ~58 call sites ever filled the
headline in**, so every card was a lone line and "Mod downloaded" never said which
mod.

The body **names the subject; it does not describe the work.** That distinction is
the whole rule, and the install confirmation is the case that taught it — it used
to carry the auto-tags and a list of the metadata fields copied off the mod page,
so the one fact being waited for was the hardest line to find, and the rest was
the app narrating its own bookkeeping about work whose result is on the card a
second later.

| | |
|---|---|
| ✅ | `Mod installed` / `Ellen Swimsuit` |
| ❌ | `Mod installed` / `Auto-tagged Ellen, copied 4 fields from the mod page` |

Where a call site has no subject in hand, the body is **the single next step the
user can take** — never a restatement of the title. If there is neither a subject
nor a next step, that is a sign the notification shouldn't be raised at all.

What a caller genuinely cannot drop is what the user must *act* on (no `.ini`, a
patch-shaped download, a sidecar that could not be written). Each of those goes
beside the success as **its own warning with its own two levels**, never as more
text under it: a broken install must not be reported in the same colour as a clean
one, and three problems joined by newlines are three notifications, not one.

**Ordering falls out of the four-card cap.** Three warnings plus a success is
exactly `kMaxVisibleNotifications`, so `install_result_feedback` raises the
**warnings first and the success last** — the other way round, the concluding line
is the one pushed off.

## 3. The leading slot

Three tiers, answering "what is this about": a character's **portrait**, else that
built-in **category's own icon** (`cat_ui` → `Icons.web_asset`), else the
**severity glyph**. An explicit `icon:` overrides all three.

`AppNotification` asserts `icon` and `characterId` are never both set — otherwise
the icon wins and the portrait vanishes with nothing to explain it.

**The slot is 40px wide in every tier.** Two lines of card text — a `titleSmall`
headline (20px line box) + 2 + one `bodyMedium` line at `height: 1.35` (19) — come
to 41px, so 40 is the largest slot that never makes a card taller than its own text
already did. A slot that changed width between cards would give the stack a ragged
left edge, so the severity glyph sits at 20px centred on a 40px tinted disc rather
than shrinking the slot.

Severity survives the portrait as a **2px ring** in the same `notificationColor`
the stripe uses — a third read of one value, not a second renderer of the severity
look. The 2px gap between ring and artwork is load-bearing: it puts the ring
against `surfaceContainerHigh`, one known colour per theme, rather than against
whichever pixels that character's silhouette has at the clip edge.

**Considered and rejected: a severity badge on the portrait's corner.** It sits
over 60 pieces of artwork, so it needs an opaque fill plus a card-coloured cut-out
ring to stay readable — three new painted elements. At 40px outer, a legible badge
is ≥14px, eating the chin or shoulder of every portrait. And it duplicates
`notificationIcon` into a second renderer at a second size.

**Bulk reports get no portrait.** A whole-library check or resolve is *about a
count*, so one arbitrary face would claim the message is about that mod — and
which mod sorted first would change between runs.

Portraits resolve through `CharacterAvatar.assetPathFor`, which returns null when
there is no portrait. That check must happen *before* an `Image` is built:
`getCharacterAssetName` falls back to the id itself, so a category-filed mod would
otherwise ask the bundle for `cat_misc.png` and hit `errorBuilder` on every render.

## 4. Severity

**Severity is the only thing a call site decides.** Colour, icon and duration are
derived from it in one place (`notificationColor` / `notificationIcon` /
`kNotificationDurations`). They used to be chosen per call site from whatever was
nearest — `Colors.red` here, `colorScheme.error` there, `Colors.orange` for a
warning in one file and nothing in the next — so the same kind of event looked
different depending on which screen raised it.

## 5. The stack and the clock

- **Why not Material's snackbar.** Two reasons, and the second cannot be styled
  away. A `ScaffoldMessenger` shows **one bar at a time and queues the rest**, so
  an install with three things to say showed them in sequence, each replacing the
  last. And the bar lives *inside* the `Scaffold`, so a modal dialog's barrier
  covers it — which is where a large share of these messages are raised from.
- **The host is mounted in `MaterialApp.builder`, above the `Navigator`.** That is
  what puts a notification over a dialog. It is also why the close button carries
  a **semantic label rather than a `Tooltip`**: a tooltip needs an `Overlay`
  ancestor, and this layer is a *sibling* of the navigator, so one throws "No
  Overlay widget found" the first time anything is raised.
- **The queue holds no timers; the card owns the clock.** The auto-dismiss timer
  has to stop while the stack is being read, and only the widget knows where the
  pointer is. `NotificationCenter` therefore stays a synchronous list, and its
  tests assert about a list rather than about elapsed time.
- **Hovering holds the whole stack, not the card under the pointer.** "Is the
  pointer here" is one fact, owned by `NotificationOverlay` and passed down as
  `paused`, with a single `MouseRegion` around the column — which also covers the
  gaps between cards, so travelling from one notification to the next never counts
  as leaving. Per-card pausing was wrong twice over: the fourth message expires
  while the pointer rests on the first, and the stack reflows out from under the
  pointer as it goes. A notification raised *while* the pointer is already there
  arrives held, and leaving **restarts the full duration** rather than resuming.

## 6. Pinned notifications, and `update`

`pinned(…)` raises one with no duration and hands back a `NotificationHandle`;
`update()` rewrites it in place (same id, so the same card, position and hover
state) and `dismiss()` removes it. A pinned notification still has its close
button — nothing this app puts on screen may be un-dismissable.

**In a pinned notification the body is what stays put.** The drag-a-mod-onto-a-
character flow raises "Saving tag… / Ellen Swimsuit" and, because the card visibly
moves on success, simply `dismiss()`es. Where an update *is* wanted, it rewrites
the title alone and the subject carries over untouched.

That is why **raising one requires both levels while every parameter of `update`
is optional**: raising builds a whole statement, updating changes one level of a
statement that already exists. There is no `clearTitle` and no `clearBody`,
because neither has a "back to nothing" state.

**The handle is safe to hold past the end.** The user can close any notification
at any moment, so `update`/`dismiss` on one that is gone do nothing rather than
throw. Pass the character id into `pinned()` **up front** rather than reading it at
the update line — that line runs after an await with no `mounted` check.

## 7. De-duplication

Re-raising an identical **(severity, title, body)** moves it down the stack and
restarts its clock instead of stacking a duplicate. The stack is capped at
`kMaxVisibleNotifications` and drops the *oldest*, since a burst is usually one
action reporting several things and the last line concludes it.

`icon` and `characterId` are deliberately **not** in that key — they are pictures
of what a notification says, not part of what it says. So the same sentence about
the same mod with a different face is the same sentence, and the survivor is the
newer object and therefore carries the *current* face.

The predicate lives on the model as `saysTheSameAs` rather than inline in `show`,
so the next field added has to answer that question rather than silently join or
miss the key.

## 8. Call-site mechanics

- `context.notify` resolves through `ProviderScope.containerOf(listen: false)`, so
  it is legal in `initState`, in a dialog builder, and in a plain function handed a
  context. **Capture it in a local before an `await`** and the report survives the
  widget being disposed.
- **Capture the character id early too.** `ModsScreen` is *disposed* while the
  marketplace is up, so `modsProvider` will not contain a mod the marketplace just
  installed. Use the id the work already had (`remote.characterId`,
  `mod.characterId`) rather than looking one up at report time. Never fall back to
  `detectCharacterId(name)` — a substring guess this codebase refuses to trust.

## 9. Testing

- Widget tests get the host from `test/support/localized_harness.dart`, which
  mounts it exactly as `main.dart` does. A test that needs to read state back must
  pass its `ProviderContainer` as `pumpLocalized(container:)` rather than nesting
  an `UncontrolledProviderScope` **below** `home` — a nested container is a second,
  invisible queue, and the assertion would run against an empty screen.
- **Assert about a portrait through the `AssetImage`'s `assetName`, never through
  pixels.** `Image.asset` resolves asynchronously and `pumpAndSettle` does not wait
  for real async I/O, so a pixel assertion passes vacuously.
- `test/l10n_keys_test.dart` enforces that every `_body` key has a `_title`
  sibling, that en/uk stay at exact parity, and that no value is empty. A missing
  key renders as a raw dotted path on screen with no exception.
- `test/character_assets_test.dart` keeps the roster and `assets/characters/` in
  step, so a character added before its art fails CI rather than rendering a
  silhouette.
