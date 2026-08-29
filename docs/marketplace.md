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
It has **one** branch, "in library", and is meant to keep one.

### "Update available" here was considered and refused

Recorded because it is the obvious next idea, and because the case against it is
not visible from this file. **The marketplace answers *do I have this*; the
library answers *is mine current*.** Two screens, two questions, and moving the
second one here fails twice over:

- **The badge would be blank most of the time, and blank reads as "no update".**
  Rendering it needs no request at all — `modUpdateChecksProvider` is keyed by
  folder and `InstalledModsIndex.installsOfMod` turns a remote mod id into
  folders, so a card showing an installed mod is showing one a library-wide check
  already covered. But that map is **session state that is never persisted** (see
  [`library-screen.md`](library-screen.md) §4) and the launch check is **off by
  default** ([`update-checks.md`](update-checks.md) §5.1), so on a normal launch it
  is empty. An indicator that is usually absent teaches the user that absence
  means *no update*, when it means *nobody checked*. The library gets away with
  the same emptiness because the button that fills it is in its own toolbar.
- **The action behind it does not exist here, and cannot cheaply.** This screen's
  Download enqueues an install, and `ModManagerService.importMods` skips a folder
  that already exists — so pressing it on a mod you own downloads a whole archive
  and reports *"Nothing imported"*, or, when the author renamed the folder between
  versions, silently lands a **second copy** beside the first. Updating is
  `applyUpdateFlow`: snapshot, overwrite in place, keep the name, character,
  favourite and enabled state, reconcile moved keybinds, and ask first. §5 already
  says why those two are not folded together. So the badge without the action is a
  trap, and with it the whole update conversation moves into a browse screen.

What is actually missing is the opposite direction — a way to get **from** a
marketplace mod **to** its library entry. "In your library as …" is a dead label
today, and a link would be useful whether or not anything is out of date.

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
  view's notice, the file-row chips, the carousel — so it doesn't change hue
  between screens. `tertiary` is spoken for by the `obsolete` badge.

**The carousel answers the same question.** `TopSubs` returns its own DTO, so its
card is a separate widget from `GbModCard` — which is how it came to be the one
surface showing a mod without saying you already had it. It watches
`installedModsIndexProvider` and paints the same filled `primary` pill.

Where it differs from the grid card, and why:

- **Beside the period badge, not in a corner of its own.** The two pills are one
  top-left cluster in a single `Positioned`, laid out by a `Row` — their widths
  are their labels', which vary by period and by locale, so the second one's
  offset is not a number anyone can write down. The cluster sits **after** the
  reveal overlay in the `Stack`, so neither pill is dimmed by the scrim: which
  period this is the best of is no more adult content than owning the mod is.
- **No tooltip, and the cluster is inside an `IgnorePointer`.** The card is one
  big tap target laid *under* its overlays rather than around them, so anything
  up there that absorbs a hit carves a dead zone out of it — the bug the title
  and period badge already had to be `IgnorePointer`ed to fix.
  `test/gb_top_subs_carousel_test.dart` taps the badge's *position* to keep it
  that way.
- **It therefore names no folders.** They are one click away in the detail view's
  own notice, which is what the grid card's tooltip is standing in for anyway.

The grid card's "paints over the reveal overlay" rule is testable there because
the badge being underneath changes what a click does. Here both orders behave the
same under a tap, so the test pins only that the badge is **shown on a blurred
card at all** — the part that would be a wrong answer rather than a dim one.

## 8. Layout

**The grid sets `mainAxisExtent`, not `childAspectRatio`, and `GbModCard`'s cover
is an `Expanded`.** These two go together and are load-bearing. An aspect ratio
makes the tile *shorter as it gets narrower* while the text block under the cover
needs a constant height, so the card overflowed its bottom below ~179px wide — and
tile width ranges over roughly 150–300px with window and sidebar state. A fixed tile
height decouples them: the text always gets its room and the cover absorbs the
remainder, which also survives the OS text scale growing the title. Covered by
`test/gb_mod_card_test.dart` across the whole width range.

## 9. What the two screens say when they have nothing to show

`services/gamebanana/gb_failure.dart` decides, `components/marketplace/gb_state_view.dart`
renders. **One decision, one surface, both screens.** The grid and the detail view
each used to carry their own copy of the error state, and the copies had already
drifted: one drew a detail line under the heading and the other didn't.

### Four failures, not two

`describeGbFailure` classifies anything an `AsyncValue.error` can hand over —
including a bug of ours, which arrives as a bare `Object` and still has to land
somewhere rather than throw while rendering an error.

| Kind | What the user is told to do |
|---|---|
| `offline` | Check the connection. The most common failure and not a bug. |
| `rateLimited` | Wait a moment. Temporary by definition, and `429`/`503` both arrive here. |
| `notFound` | Give up on this mod. The only failure that will still be true in an hour. |
| `generic` | Try again; we can't say more. |

The two that matter are the two that were missing. A back-off reported as
*"Something went wrong"* reads as a bug in the app, and a removed mod reported the
same way sends the user retrying forever.

**Retry is withheld on `notFound` and nowhere else**, and that is a property of
the classifier rather than of either widget — `GbFailure.canRetry`. It is absent
rather than disabled: a greyed-out button still says *this is the thing to press
once you fix something*, and there is nothing to fix. The three recoverable kinds
all keep it.

### No message from the wire reaches the screen

`models/gamebanana/gb_exceptions.dart` states the rule at the top of the file:
these exceptions carry **codes, never user-facing prose**, because the API's own
messages are server English that cannot be localized — and `GbException.message`
is marked *"Developer-facing detail. Not for display."*

The grid was breaking it, printing that field under the heading, so a back-off
rendered as the untranslated `Server asked us to back off (HTTP 429)`. It goes to
`debugPrint` now instead, which keeps the detail for a developer at a terminal and
off the screen. **The type is what enforces this**: `GbFailure` carries a kind and
nothing else, so there is nowhere to put a message even by accident.

The l10n keys are spelled out as literals in the widget's switch rather than built
from a stem, because `test/l10n_keys_test.dart` finds keys by scanning `lib/` for
single-quoted literals and cannot see an interpolated one.

### The empty states carry the control that acts on them

Two states, because *no results* and *your filter hid all of these* are different
claims and showing the wrong one sends the user hunting for a mod that was never
in the results. Each now offers what it can:

| State | Action |
|---|---|
| No results, while searching | **Clear search** — the same call as submitting an empty box, so `_FilterBar`'s existing listener empties the text field for free |
| No results, past page 1 | **Back to page 1** — a real dead end, since `pageCount` is null on some listings and the pager legitimately walks past the end |
| No results, page 1 of a browse | none — inventing a button here would send the user pressing something that cannot help |
| Everything filtered | **Blur them instead** |

**The filter action degrades `hide` to `blur`, never to `show`** — the same rule
the resolve dialog follows ([`library-screen.md`](library-screen.md) §7). `blur` is
the mode where the cards are on screen and each one can still be clicked through
individually, so it answers the complaint without turning a deliberate choice into
its opposite. Only `hide` can produce this state, so there is one transition and no
branch.

It writes through a **`ContentFilterWriter`** seam (the typedef
`components/settings/marketplace_section.dart` already defines, reused so there is
one signature for this write rather than two), defaulting to
`ApiService.setContentFilter`. Not optional: `ApiService` lazily builds a
`ConfigService` against the developer's real `<appData>/config.json`, so a widget
test that pressed that button without a seam would rewrite their own settings.

### What is deliberately silent, and stays so

Not everything that can fail should say so, and these are decisions rather than
gaps:

- **The category panel says nothing on error.** It fails exactly when the listing
  beside it fails, and that error is already on screen; two messages for one outage
  reads as two problems.
- **The carousel is absent rather than empty** on loading, error, or a filter that
  hides every entry. It is a decorative strip above the real content, and a spinner
  or an error box there reports a problem the user cannot act on and did not ask
  about.
- **Thumbnails have no per-tile spinner.** A grid of them flickering is worse than
  tiles that fill in; the container behind is already the right size and colour, so
  nothing reflows.
- **The detail header falls back to `#<modId>`, not to *Loading…*, once the profile
  has failed.** Left as the loading string it sat as a title over a message saying
  the load had failed.

## 10. Descriptions

`_sText` is HTML while every description this app renders is markdown, so it goes
through `utils/html_to_markdown.dart` — shared with the description editors'
paste-as-markdown so the two can't drift.
