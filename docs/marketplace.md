# The marketplace — the native GameBanana browser

**Scope:** `screens/marketplace_screen.dart` and
`screens/components/marketplace/` — the two screens the user browses GameBanana
with, and what an install does on the way through.

Not in scope: GameBanana's wire protocol ([`gamebanana-api.md`](gamebanana-api.md)),
what an install copies from a mod page ([`metadata-autofill.md`](metadata-autofill.md)),
or the transfer itself ([`downloads.md`](downloads.md)).

---

## 1. What it is

A **native** browser, identical on both platforms. It replaced an embedded
webview on Windows and an open-your-real-browser-plus-Downloads-watcher fallback
on Linux — a split that could not solve three things: the watcher only ever saw *a
file appearing*, so a mod installed that way had no remote identity at all;
"finished downloading" was inferred by polling for a stable file size, which is a
guess about someone else's browser; and anything downloaded for unrelated reasons
was a false positive.

**Two screens only** — results grid and mod detail. Everything else GameBanana
hosts (comments, threads, member pages) is reached through "open in browser".

## 2. State

State lives in `utils/marketplace_providers.dart`, **not** the central
`state_providers.dart` registry: it is one screen's browsing session rather than
app-wide state. The content filter *is* app-wide and stays in the registry,
hydrated from config in `ApiService.initialize`.

**Browse and search are separate modes**, because they are separate endpoints with
different capabilities — search takes text but supports neither category filter nor
sort, so the sort control is disabled rather than silently ignored.

## 3. The two views are an `IndexedStack`, not a conditional

Swapping them meant disposing the browse view, and with it the scroll offset of a
grid the user may have paged deep into — so opening a mod and pressing back always
landed them at the top. Keeping it mounted keeps the *real* offset rather than a
remembered number, which is the only version that survives the grid being a
different height than when it was left (a content-filter change, a badge
appearing).

The **detail slot** is deliberately the one that stays empty while unused:
`GbDetailView` holds per-mod state (gallery index, reveal, archived files) that
must reset between mods, and it is keyed by mod id for the same reason.

`IndexedStack` hides a child from painting, hit-testing and semantics but **not**
from focus traversal — hence the `ExcludeFocus` around the grid, without which
tabbing on the detail view walks into an off-screen search box.

**`ref.invalidate` cannot be called from `initState`, unlike the rest of `ref`.**
`MarketplaceScreen` re-snapshots the library when it opens, and that call lives in
`didChangeDependencies` behind a once-per-`State` flag. `WidgetRef.invalidate`
resolves its container with `listen: true`, which registers an inherited-widget
dependency — forbidden during `initState`, and it throws for every mount, taking
the whole tab down. `read`, `refresh` and `listenManual` use `listen: false`
specifically so they *can* be called there; `invalidate` does not, and nothing in
its signature says so. `didChangeDependencies` still runs before the first build,
so nothing observes a stale snapshot. Covered by `test/marketplace_screen_test.dart`.

## 4. Where remote identity reaches the origin block

The webview could only intercept a CDN url, so every origin block it wrote had both
confidences at `unknown`. A native download knows mod id, file id, version and
variant label before the first byte and writes them at `exact`. See
[`origin-tracking.md`](origin-tracking.md) §2 for every route that writes a block
and the tier each one may claim.

## 5. What pressing Download actually does

`MarketplaceScreen._handleDownload` **enqueues and returns.** It does not wait and
it does not own what follows: the transfer runs in the background
([`downloads.md`](downloads.md) §7) and the install belongs to
`DownloadQueueHost`, mounted above the tabs.

That split is forced rather than tidy. This screen is *disposed* the moment the
user switches tabs, so an install owned by it dies there — which the old modal
progress dialog hid by making walking away impossible. What the screen still owns
is the one thing only it has: the **mod page**, which travels with the job and is
what lets the origin block land at `exact` (§4) and the autofill run at all.

The install itself is `dialogs/install_archive_flow.dart`. After the import it
hands the profile to `applyRemoteMetadata`, which fills the description, gallery
and tags the install would otherwise leave empty.

**The character is the exception: it is passed *into* the import.** The mod page's
category is the author's own filing, while folder-name detection is a substring
guess, and they disagree exactly where it hurts — a Zhao skin published as
`Zhao Nicole` detects as Nicole, since the longest matching term wins. It cannot be
corrected afterwards, because the autofill's one rule is *fill absence* and
detection has already filled the slot. So `importMods`/`importCombinedMod` take
`knownCharacters`/`knownCharacter` and skip detection for those folders. An
unassigned value falls back to detection, which is what keeps a mod filed under
`Other`/`Misc` working. See [`metadata-autofill.md`](metadata-autofill.md).

## 6. Where the origin block is first *read*

Cards and the detail view badge mods already in the library, file rows mark the one
you installed, and both ingest paths run `confirmArchiveNotDuplicate`
(`dialogs/duplicate_archive_dialog.dart`) before installing an archive whose hash is
already banked.

The badge is keyed on the **mod** and the row marker on the **file**, because those
are different questions with very different availability — see
[`origin-tracking.md`](origin-tracking.md) §9.

## 7. `GbModCard` has one status slot

`_statusSlot` returns at most one badge, never a stack — the same rule the library
card follows, since a card that can show three things at once shows none of them.
**"Update available" belongs in that method** as a second branch when it lands, so
precedence between the two states is one decision in one place rather than a second
badge elsewhere on the card.

It renders a **filled** pill top-right, opposite `obsolete` and above the reveal
overlay (owning a mod is not adult content, so it must read before the blur is
lifted).

- **The alternative was built and lost a side-by-side comparison**: a full-width
  strip along the bottom of the cover. Recorded so it isn't re-proposed as an
  obvious improvement. The two put the emphasis in different places — the strip was
  noticeable through *shape* and paid by covering a slice of artwork; the pill is
  noticeable through *fill*, which is the whole reason `_badge` has a `filled` mode,
  and occludes almost nothing.
- **"You already have this" is `primary` everywhere** — the card badge, the detail
  view's notice, the file-row chips — so it doesn't change hue between screens. The
  consequence for M3 is worth knowing in advance: "update available" has to differ
  by **hue at similar weight** rather than by being the louder of the two, and
  `tertiary` is already spoken for by the `obsolete` badge.

## 8. Layout

**The grid sets `mainAxisExtent`, not `childAspectRatio`, and `GbModCard`'s cover
is an `Expanded`.** These two go together and are load-bearing. An aspect ratio
makes the tile *shorter as it gets narrower* while the text block under the cover
needs a constant height, so the card overflowed its bottom below ~179px wide — and
tile width ranges over roughly 150–300px with window and sidebar state. A fixed tile
height decouples them: the text always gets its room and the cover absorbs the
remainder, which also survives the OS text scale growing the title. Covered by
`test/gb_mod_card_test.dart` across the whole width range.

## 9. Descriptions

`_sText` is HTML while every description this app renders is markdown, so it goes
through `utils/html_to_markdown.dart` — shared with the description editors'
paste-as-markdown so the two can't drift.
