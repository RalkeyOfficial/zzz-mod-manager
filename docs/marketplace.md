# The marketplace — the native GameBanana browser

**Scope:** `screens/marketplace_screen.dart` and `screens/components/marketplace/` — the grid the user browses GameBanana with, the pages opened over it, and what an install does on the way through.

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

The two webview packages that would also give one implementation lose on their own terms: `desktop_webview_window` opens the page in a separate popup window and intercepts downloads poorly,
and `webview_cef` embeds properly but ships ~150 MB+ of Chromium with the app.

**The grid, and two kinds of page over it**: a mod's page (§9) and a creator's page (§12), which the author's name on a mod's page opens. Everything else GameBanana hosts, comments and threads, is reached through a page's "Open on GameBanana".

Not verified on Windows. Browsing, downloading and installing have run end to end against the live API on Linux only;
nothing here branches on the platform, since links and opening a URL go through `PlatformService`.

## 2. State

State lives in `utils/marketplace_providers.dart`, **not** the central
`state_providers.dart` registry: it is one screen's browsing session rather than
app-wide state. The content filter *is* app-wide and stays in the registry,
hydrated from config in `ApiService.initialize`.

**The search box is a name filter on the one listing, not a second mode.** The submitted text goes to `Mod/Index` as `Generic_Name` beside the category and the sort, so all three combine.
The site-wide search endpoint is the rejected alternative: it matches any single word in any field, so the exact title of one mod returned 714 results where the site's own name lookup returns one ([`gamebanana-api.md`](gamebanana-api.md) §3).

**The chips are a character and a type, and the request takes one category.** `MarketplaceQuery` holds the type chip that is on (`typeId`, a root category) and the picked character (`character`, a Character Skins child with its name);
`categoryId` is the character's id when one is picked, else the type's, and that one id is what `Generic_Category` gets.

- **The character chip** is a pill with the picked agent's face and name, or "Any character", and opens a popover of the live roster (`categoryChildrenProvider(30305)`).
  Each agent is a portrait tile, mapped from the category name as an install maps it (`RemoteModMetadata.characterIdForCategory`): "Your characters", the agents with a mod in the library, sit above "Every agent, A to Z".
  A "Type a name" field narrows the tiles and Enter picks the first match; an A–Z rail on the side filters to one letter. Picking the picked agent again clears the pick.
  With a character picked, the chip carries an × that clears it; the rest of the chip reopens the popover.
- **The type chips** are one per root GameBanana lists (`rootCategoriesProvider`), which decides which types exist. Their order and short labels come from `kTypeChipLabelKeys`: Character (30305), Bangboo (30702), UI (30395), Misc (29874).
  A root the map doesn't know shows its live name, after these, in GameBanana's order. Single-select: the chip that is on turns off, back to every mod.
- Picking a character turns Character on; picking another type clears the character. Clearing the character leaves Character on.
- **The design's Texture, Audio and Unknown chips are not built.** They are the Library's own categories, and GameBanana has no category for any of them, so a chip could only send a filter the API cannot apply.

**An equal query reloads nothing.** `MarketplaceQuery` is value-equal and `MarketplaceQueryController` tells its listeners only when the query changes by value,
so re-picking the current sort, submitting the same search again, or a category link (§9) to the filter already shown neither starts the listing again nor scrolls to the top.

**Hide installed** is a switch on the right of the filter bar, off by default and remembered (`marketplace_hide_installed`, [`configuration.md`](configuration.md)).
It drops every record whose mod is in the library, by the same `installedModsIndexProvider` lookup the Installed badge uses, on the client: switching it re-filters the loaded pages without a request.
Both it and the content filter can leave a page with fewer cards than it fetched, which §8's infinite scroll accounts for.

**The Mature content menu** writes the same `content_filter` setting Settings shows, through the `ContentFilterWriter` seam:
Blur ("Thumbnails blurred, still listed"), Show without blur ("Listed like any other mod") and Hide entirely ("Left out of Browse"). Its button shows the current mode's icon.

**The Sort menu** offers six sorts in the design's order: Newest, Oldest, Most liked, Most downloaded, Most viewed, Recently updated.
`Generic_LatestComment` is a valid `_sSort` the menu leaves out, and a stored `latestComment` reads as the default (`parseMarketplaceSort`), so the menu never opens with nothing ticked.
Both menu buttons look pressed while their menu is open.

**The carousel shows whenever no search is typed**, whatever the chips say. A search names what the user is after, and a game-wide best-of list above it would push the answer down;
a chip narrows a browse the carousel still sits above.

**The sort starts on newest submissions (`Generic_Newest`), by request, against the API doc's advice.** [`gamebanana-api.md`](gamebanana-api.md) §4 recommends `Generic_LatestModified`,
because `Generic_Newest` orders by first publication and an actively updated mod sinks: one sat 3rd on the site and more than 420 mods deep here.
The default is safe because the chosen sort persists (`kDefaultMarketplaceSort`, `marketplace_sort` in [`configuration.md`](configuration.md)), so it only decides a fresh install,
and "Recently updated" is one click away and remembered from then on. Neither order matches the site's own default, a "ripe" ranking no API exposes (same §4).

**A pasted mod link or a bare id shows that one mod.** `gameBananaModIdFromText`
recognises both, the profile is fetched, and it is shown as a one-record page,
ignoring the category and sort, since an id names a mod outright. A mod that is gone
or belongs to another game comes back as an empty page rather than an error, so the
grid offers the same "clear search" it offers a fruitless name. A file link
(`/dl/…`) is not an id, so it is searched as a name and finds nothing.

## 3. The pages are a stack in an `IndexedStack`, not a conditional

**The grid stays mounted under every page.** Swapping it out would dispose the browse view, and with it the scroll offset and the loaded pages of a grid the user may have scrolled deep into, so opening a mod and pressing back would land them at the top.
Keeping it mounted keeps the *real* offset rather than a remembered number, which is the only version that survives the grid being a different height than when it was left (a content-filter change, a badge appearing).

**Over it is a stack of pages**, `marketplaceRoutesProvider`: a list of `MarketplaceRoute`, a mod's page by mod id or a creator's page by member id, bottom first and empty while the grid shows. Grid → mod → creator → mod is three pages; back pops one.

- **A mod opened from the grid replaces the stack** with that one page (`openFromGrid`), and so does a caller outside Browse.
- **A page opened from a page is pushed**, unless it is already in the stack: then the stack goes back to it (`open`). A mod's page opened from its own author's page goes back to the mod the author's page came from, and the creator's crumb on a mod opened from it goes back to the creator's page. This keeps the stack as deep as the distinct pages it holds, so a user clicking between an author and their mods never builds a stack to walk back through.
- **Every page in the stack stays mounted too**, each keyed by its route, so going back finds a page as it was left: a creator's page keeps its loaded mods, its tile and its scroll, a mod's page its picture and its picked files. A page gone back past is disposed, and its state with it, so a mod opened again starts afresh. `GbDetailView` holds per-mod state (the picture shown, the reveal, the older files, the files picked, the character picked over the category's) that belongs to that mod alone, which is why it is keyed by mod id.
- **The crumbs name the page under**: a mod opened from the grid reads "Browse / Ellen Joe / Victorian Ballgown", its category a link (§9); a mod opened from a creator's page reads "Browse / lacequeen / Victorian Ballgown"; a creator's page reads "Browse / Victorian Ballgown / lacequeen". Browse goes straight to the grid, the crumb after it back one page.
- **Escape, Alt+Left and the mouse's back button go back one page**, as the crumb before the page's own does, and do nothing on the grid. Only while Browse is the page the sidebar shows and nothing is over it: a dialog or the Downloads panel is a route over Browse's, so its Escape is its own and its barrier takes the mouse.
  The keys are read by a late key handler (`FocusManager.addLateKeyEventHandler`), which sees only a key nothing focused has taken. So whatever claims a key first keeps it: a text field takes Escape (to hide its toolbar) and Alt+Left (the line's start), and an open menu or popover takes Escape to close itself. A `Focus` around the screen would miss a key pressed while nothing on the page has focus, which is the usual case, since a click on a card or a link focuses nothing.
  A click focuses nothing on a menu button either, so a Sort or Mature content menu opened by one would leave its Escape to the back, and a creator's page would go back with its menu still open. Browse's menus (`_EscapableMenuAnchor`) move focus to a node around their button as they open, under the menu's own dismiss action, so Escape closes the menu and the next Escape goes back. The node is around the button rather than the button's own, which would draw its focus ring. The character popover focuses its search field as it opens, which closes it on Escape too.
  While a menu is open, Alt+Left and the back button go nowhere: the back button pressed outside the menu closes it, as any click outside does.
  The back button is read by a `Listener` around the stack, so it works anywhere over Browse's pages, their empty space included, but not over the sidebar, the title bar or an open menu. It has not been tried on a real mouse yet, only in tests.

The Library's update dialog opens a mod's page through `marketplaceOpenModProvider`, which writes the stack: an id makes that mod the only page, null goes back to the grid, and it reads back as the mod on top, or null while the grid or a creator's page shows.

`IndexedStack` wraps each child in a `Visibility`, which hides a child from painting, hit-testing, semantics and focus traversal, so tabbing on the page on top never reaches the search box of a grid that is not on screen.
The `ExcludeFocus` around the grid and every page but the top one states the same thing explicitly and is redundant with that. The carousel holds still while any page is open over it.

**The library is re-read after Browse's first frame, never during it.**
`MarketplaceScreen` re-reads the library each time it opens, from a post-frame callback behind a once-per-`State` flag.
The Library page fading out under the `AnimatedSwitcher` still watches `libraryProvider`, and the browse view's first build reads the library through `installedModsIndexProvider`, so an invalidate inside that build pass rebuilds the library mid-build and marks the fading page dirty, which throws.
Until the re-read lands, the "in library" badges show the cached library.
`ref.invalidate` is also never called from `initState`: unlike `read`, `refresh` and `listenManual`, it resolves its container with `listen: true`, which registers an inherited-widget dependency that `initState` forbids, and nothing in its signature says so.
Covered by `test/marketplace_screen_test.dart`.

## 4. Where remote identity reaches the origin block

The webview could only intercept a CDN url, so every origin block it wrote had both
confidences at `unknown`. A native download knows mod id, file id, version and
variant label before the first byte and writes them at `exact`. See
[`origin-tracking.md`](origin-tracking.md) §2 for every route that writes a block
and the tier each one may claim.

## 5. What pressing Install actually does

The mod page's Install queues each picked file as its own job, in the list's order, and Download without installing queues them the same way as archives to keep (`DownloadIntent.keepArchive`). There is no question in between: which files, which character and whether to turn them on are all on the page already, so a dialog asking "Download only or Download & install?" would ask what the page shows.

`MarketplaceScreen._queueFiles` **enqueues and returns.** It does not wait and it does not own what follows: the transfer runs in the background ([`downloads.md`](downloads.md) §7) and the install belongs to `DownloadQueueHost`, mounted above the tabs. Two picked files are two jobs, de-duplicated on the file id as every job is, and each becomes its own mod.

That split is forced rather than tidy. This screen is *disposed* the moment the
user switches tabs, so an install owned by it would die there. What the screen still owns
is the one thing only it has: the **mod page**, which travels with the job and is
what lets the origin block land at `exact` (§4) and the autofill run at all.

The install itself is `dialogs/install_archive_flow.dart`. After the import it
hands the profile to `applyRemoteMetadata`, which fills the description, gallery
and tags the install would otherwise leave empty.

**The character is the exception: it is passed *into* the import.** The mod page's category is the author's own filing, while folder-name detection is a substring guess,
and they disagree exactly where it hurts — a Zhao skin published as `Zhao Nicole` detects as Nicole, since the longest matching term wins.
It cannot be corrected afterwards, because the autofill's one rule is *fill absence* and detection has already filled the slot.
So `importMods`/`importCombinedMod` take `knownCharacters`/`knownCharacter` and skip detection for those folders. Unassigned is told too, and stored as absence: the mod is filed under Unassigned and its folder name is never read.
Only a folder given no character has its name read, which is what a drag-and-drop or a paste with no character picked does. See [`metadata-autofill.md`](metadata-autofill.md).

**The character told to the import is the one the page shows, and the job carries it.** The page starts on the category's character (§9), and the user's Change beats it: the category beats a folder name because it is the author's statement, and an explicit choice beats both, since it is the user's statement about this install.
It is fixed at the press and travels as `DownloadJob.characterId`, which `runArchiveInstall` reads off the job, never recomputed from the category when the bytes land. A page whose category names no character carries Unassigned (`unknown`), so its mods are filed there.
So does a Bangboo, UI or Misc mod whose category holds an agent's name: the type is decided first (`RemoteModMetadata.characterIdForMod`, through `GbMod.typeCategoryId`), and only a Character Skins mod maps to an agent. A record whose type is unknown, with no root id and a category that is no root, maps to none either. A card's Install takes the same mapping (`RemoteModMetadata.fromMod`).

**A later file of the same mod page never collides with an earlier one.** The picked variants of one mod often share an inner folder name, so a folder whose name an earlier download of that page installed, by a finished row still in the queue, goes in as `Name (variant)`, then `Name (variant) (2)`.
The variant is the file's label (`_sDescription`), else its file name, cleaned for a folder name and cut at 40 characters, and a number alone when neither leaves anything. A name taken by anything else is skipped, as any install skips a folder the library already has, and an install that put nothing in says "Nothing imported" with "The mod may already be in your library."

**Turn on after installing is carried the same way, as `DownloadJob.turnOn`.** After an install that put mods in, the host reads the library again and turns each new mod on through `ApiService.enableMod`, in turn and through `libraryTogglesProvider`, as the Library's switch does: dry run first, then One at a time turns the character's other mods off ([`library-screen.md`](library-screen.md) §10). Several files of one character with One at a time on therefore end with the last one on.
It runs in the host because the page that set it may be gone by the time the bytes land. It waits for a running bulk action of the All mods table to end, since an enable in the middle of one could break a character's One at a time, and the install slot stays held while it waits.
An enable refused for the mod's shader files or for a network folder says why, with the Library's own messages. Any other failed enable leaves the mod installed and off, and is said as a warning beside the install's result ("Installed, but not turned on" and the mod's name), not as an error, since the install worked; a failure part-way names every mod not yet turned on. The result keeps its one action, Open.
The switch is remembered (`marketplace_turn_on_after_install`, [`configuration.md`](configuration.md)) and applies to a card's and the carousel's Install too.

**A card's Install takes the same queue call.** When the page's enrichment (§7) says the mod has exactly one current file, Install queues it as an install (`installSoleFile`, `components/marketplace/marketplace_install_flow.dart`), for the category's character, Unassigned when it maps to none, and with the Turn on after installing setting. With several current files, none, or no enrichment, Install opens the mod page instead: a file is never picked for the user ([`gamebanana-api.md`](gamebanana-api.md) §6).
The carousel's Install is the same call.

- **The mod page is fetched first**, because the job needs it for the origin block and the autofill and a listing record carries neither the description nor the gallery. The card reads Queued meanwhile (`marketplacePendingInstallsProvider`).
- **The fetched page is checked again** with `selectDefaultFile(mod.allFiles)`, since the files may have changed since the listing was enriched: the file is queued only if the page still names exactly that one current file, and it is the page's own copy that goes to the queue.
  A page that fails to load, or no longer names that file alone, opens the detail view instead, which shows the failure with its Try again, or the files to choose from.
- **The flow runs on the app's container, not on the screen's `State`**, so switching page while the mod page is fetched does not lose the press: the file is still queued.
  Only the fallback needs Browse. The mod's page opens over the page the card is on, the grid or a creator's page, only while Browse is on screen and its pages are as they were at the press; otherwise nothing happens and nothing is said, since the card's button is still there to press again.

## 6. Where the origin block is first *read*

Cards badge mods already in the library and the mod page says so in its panel (§9), and file rows mark the one you installed.
An archive whose hash is already banked is asked about before it is installed, by one lookup (`installsOfArchiveNow`, `dialogs/duplicate_archive_dialog.dart`) and in two places:
a Browse download waits in the Downloads panel with the already-installed question ([`downloads.md`](downloads.md) §10), and the Library's drop and paste ask through `confirmArchiveNotDuplicate`.

The badge is keyed on the **mod** and the row marker on the **file**, because those
are different questions with very different availability — see
[`origin-tracking.md`](origin-tracking.md) §9.

## 7. The card

`GbModCard` is the design's card: a 4:3 cover, the name, "author · updated 3 days ago", likes and downloads, and one button.
**The cover and the name open the mod page; the card around them does not**, so the button acts on its own and a click beside it does nothing.
An age under a minute, or one in the future from a skewed server clock, reads "just now" (`relativeAge`).
On a creator's page every card has the same author, so the byline names the character instead, "Ellen Joe · updated 5 days ago" (`bylineSubject`), and the cover leaves out the character badge the byline carries (`showCategory`).

**Downloads come from `Mod/Multi`.** A listing carries no download count and no files ([`gamebanana-api.md`](gamebanana-api.md) §5),
so each page that arrives is enriched by one `Mod/Multi` for its ids, asking `_idRow`, `_nDownloadCount`, `_aCategory` and `_aFiles` (`modEnrichmentProvider`, keyed by the id list so a rebuild doesn't fetch again).
The carousel's entries get one of their own, which is also where a TopSubs entry finds its character.
A failed request leaves the cards as they are — no download count, Install opening the mod page — with no retry and no message: the client has logged it, and the cards work without it.
A withheld mod comes back blank and is left out of the map, so it reads as unenriched rather than as a mod with no files. A count shows only when the enrichment carried one; a mod a day old has a real zero, and shows it.

**The cover's top-left says what the library has**: Installed, filled in the accent, with the folders in its tooltip; or Update ready in the update badge's amber when a folder of the mod has a confirmed newer file;
and the grey Obsolete badge where the author flagged the mod, since the user acts on it. The top-right names the character or category.
All of them paint over the blur — owning a mod, or whose skin it is, is not adult content.
The top-left badges always show whole; the character name takes the rest of the row, cut with an ellipsis, and is left out when less than 48px is left for it.
The grey badges and the mature veil's title sit on artwork whatever the theme, so they keep their ink colours on the paper theme too (`badgeOverArt`, whose ground is `artworkBadge`, then `artworkLine` and `artworkTitle`).

**Mature content in blur mode** veils the cover with the crossed eye, "Mature content" and "Blurred in Settings".
The card has no click-to-reveal: a click opens the mod page, whose own reveal stays.

**One button, four states**, in this order:

| State | Button | Does |
|---|---|---|
| A job for any file of the mod is active in the queue, matched on the job's mod id, or its page is being fetched for an install | **Queued**, default, inert | nothing; the Downloads panel is where it is followed. Drawn as the default button rather than greyed, since nothing is wrong with it |
| A folder of the mod has a confirmed newer file in this session's verdicts (`UpdateOutcome.updateAvailable`, not dismissed; `modUpdateChecksProvider` through `installsOfMod`) | **Update**, default | opens the update dialog for the first such folder in library order, as the Updates page's Update does, and reads the library again when it wrote |
| The mod is in the library, including a folder the Library marks possibly outdated | **In library**, ghost | shows the mod in the Characters view with its details panel open (`showModInCharacters`), as the install notification's Open does |
| Otherwise | **Install**, primary | §5: queues the one current file, or opens the mod page |

**The update state follows the canvas.** The verdicts are this session's, the same ones the Library shows:
never persisted, and empty on a normal launch since the startup check is off by default ([`update-checks.md`](update-checks.md) §5.1).
So a card without Update ready means nobody has checked this session as often as it means nothing is newer — the Library's badges carry the same caveat.
The Update button opens the same dialog the Library does, so an update is written in place with its snapshot and its questions ([`applying-updates.md`](applying-updates.md)), never by downloading the mod again as a new install.

**Only a confirmed newer file counts.** A possibly outdated verdict is a guess, and Browse leaves the guess to the Library: such a mod reads Installed and In library here, never Update ready.

**The carousel** is `TopSubs`' own DTO and its own widget. Its info box says Install or In library with the same behaviour, and View mod; it has no Update or Queued state, as drawn.
It shows only the list's mods: `TopSubs` ranks every kind of submission, and a work in progress that wins a window is left out, since its id is not a mod id and the mod page would open whichever unrelated mod holds that number ([`gamebanana-api.md`](gamebanana-api.md) §3.1).
Its overlays are always on dark over artwork, so they are drawn in the ink theme whatever the app's theme is.
On a blurred slide, "Mature content" and "Click to reveal" sit in the space above the info box, scaled down when that space is short, and never under it.
Tab reaches the reveal and each dot in the position pill, and Enter or Space presses them.

## 8. Layout and paging

**One scroll view holds the page**: the title and search, the carousel, the filter bar and the grid.
The filter bar is a `PinnedHeaderSliver`, so it stays at the top once the carousel has scrolled away; it is sized to its content, which wraps to a second line in a narrow window, where a `SliverPersistentHeader` would need its height fixed in advance.
When it wraps, the chips keep the first line and Hide installed, Mature content, Sort and Refresh take a line of their own, still at the right (`_EndWrap`), which a `Wrap` cannot do since it aligns every line alike.
The divider after the character chip shows only when type chips are shown.

**The grid sets a fixed tile extent, never `childAspectRatio`, and `GbModCard`'s cover is an `Expanded`.** These two go together and are load-bearing.
An aspect ratio makes the tile *shorter as it gets narrower* while the text block under the cover needs a constant height, so the card would overflow its bottom at the narrow end.
`GbCardGridDelegate` lays out auto-fill columns of at least 230px with 18px gaps and sets each tile's extent from the column width:
the 4:3 cover (width × 3/4) plus the text block, whose height is fixed and computed from the type roles at the current text scale (`GbModCard.textBlockHeight`).
So the text always gets its room and the cover stays 4:3 at any width. Covered by `test/gb_mod_card_test.dart` at 230 to 400px.

**The grid scrolls forever rather than paging.** `marketplaceFeedProvider` holds the pages loaded so far; the next `Mod/Index` page is asked for when the scroll comes within one viewport of the end, and appended.
A mod already loaded is left out of a later page, since a listing shifts while it is read (new mods arrive at the top of Newest).
The last page is in on `_bIsComplete`, on the record count reached, or on a page that comes back empty, and then nothing is drawn under the grid. Four details are load-bearing:

- **The check also runs after every frame that built the grid**, not only on scroll: Hide installed and the content filter drop records on the client, so a page can add fewer cards than it fetched, or none, and leave nothing to scroll.
  While the loaded cards don't reach a viewport past the end and more pages exist, the next is asked for.
- **The grid delegate relays out when the card count changes.** A page appended beyond the built cards changes no child, so the grid would keep its old scroll extent and the check would read the end as near, asking for page after page.
- **A next page that lands after the query changed is dropped** (the feed counts its builds), so a slow page of the old listing is never appended to the new one.
- **Nothing loads under a failed first page.** When a new search, chip or sort fails on page 1, the failure and its Try again replace the grid (§10); Riverpod keeps the previous query's pages beside the error, and they never come back under it or get a page appended.

A query change — search, chip, sort — and Refresh start again at page 1 and scroll to the top.
Refresh asks for page 1 past the client's cache and then rebuilds the feed from it, so the cards stay up while the request is in flight.

**Every page after the first is fetched past the client's 10-minute cache**, in every listing and after a Refresh, so a Refresh is fresh all the way down: a later page from the cache could be minutes older than the page above it.
Page 1 of an ordinary filter change may come from the cache, which keeps flipping back to a chip instant.

## 9. The mod page

`GbDetailView` is the `BrowseMod` artboard. Under the title bar, a strip of crumbs, "Browse / Ellen Joe / Victorian Ballgown" (`PageCrumbs`, shared with the Library's mod page), with Open on GameBanana at its right. Under it a scrolling body of two columns: the main column grows from 520px and the panel from 340px, 3 to 2, and below the two side by side, which is the 800px window, the panel goes under the main column, in the artboard's order.

**The main column** holds, top to bottom:

- The notices: the mod is gone from GameBanana, flagged obsolete, or flagged as adult content with its reasons and a reveal.
- The gallery: a 16:9 picture with arrows that clamp at the ends, and every picture under it as a thumbnail, six to a row at 16:10, the one shown outlined in the accent and the rest faded. A mod with no pictures shows its character's dotted ground with its initials, as the Library's mod page does.
- About this mod: the description, the tags, and "Text and images come from the GameBanana page." Absent for a mod with neither text nor tags.
- Updates: the author's update posts from `Mod/<id>/Updates` (`modUpdatesProvider`), newest first, each its title, its changelog one entry per line (or its text with the markup taken out, for a post with no changelog) and its age. Only the first page, five posts, since the section is a summary and the full feed is on GameBanana.

**The panel** holds the type badge ("Character" for a Character Skins mod, else the type chip's label for its root) and the category's, the name, "by lacequeen · updated 5 days ago", likes, downloads and, for a mod with one current file, its size; then, top to bottom:

- **In your library** when a folder of the mod is: "In your library as Ellen Ballgown", or "as 2 mods", with Show, which shows the first in the Characters view as the card's In library does, and Update when one of them has a confirmed newer file this session, which opens the card's update dialog (§7).
- **Install for**: the character the install files its mods under, in a picked file row's look. It starts on the category's character, "Picked from the GameBanana category" (`RemoteModMetadata.characterIdForMod`, the mapping §5 relies on, which gives a mod of another type no character); Change opens the category picker, characters, the built-in categories and Unassigned, and the pick holds while the page is open, "Picked by you". Only an install's picker offers Unassigned; a mod's Edit dialog does not.
Picking what the category gives, its character or Unassigned when it names none, goes back to "Picked from the GameBanana category". A category that maps to no character reads "No character in the GameBanana category" over Unassigned, and the mods are filed there, as §5 says.
- **Files**: one row per current file, each a square check. **Nothing is picked unless the mod has exactly one current file**: which of several the user wants can't be told from what GameBanana publishes ([`gamebanana-api.md`](gamebanana-api.md) §6), so the button reads "Pick a file" until they choose. Several can be picked, and older files wait behind "Show N older files", pickable too. A picked older file keeps its row when Hide older files is pressed, until it is unpicked, since Install counts it; so the Show link counts only the older files still hidden, and is absent when there are none. A row says the file's variant text and upload age, and its size; a scan result other than clean is shown on it, and a clean one says nothing, since every captured file reads clean and a badge on each would be noise.
- **Turn on after installing**, remembered (§5).
- **Install N files**, with "It becomes a mod under Ellen Joe." or "Each file becomes its own mod under Ellen Joe." under it, and Download without installing.

The footnote names where the mods will be, Unassigned included, and the install files them exactly there (§5).

**The author's name is a link** (`ZenithLink`) to the creator's page (§12). It is cut out of the translated "by {author}", so it stays a link wherever a language puts the name.

### The character crumb is a link

Tapping it filters the grid by that category and goes back, which for a ZZZ mod
usually means *every other mod for this character* — the one piece of metadata a
reader is most likely to want more of. Browse, the crumb before it, goes back to the grid as it was. A mod opened from a creator's page names the creator there instead, which goes back to that page (§3).

**It sets the chips**, since the chips are what the grid filters by (`MarketplaceQuery.showingCategory`): a Character Skins child picks that character, which turns Character on;
a root, Character Skins included, turns its type on and clears a picked character, since the link names the whole category; and a child of another root, such as a Bangboo skin, turns its root on, since no chip names it.
The parent is the listing's `_aRootCategory` or the profile's `_aSuperCategory`, and a profile filed directly under a root has none, its category being the root.

**Plain text when the record carries no id.** A listing's `_aRootCategory` has no
`_idRow` and `GbCategoryRef.idRow` recovers it from `_sProfileUrl`, so a record
with neither would otherwise offer a link that filters by nothing — inert reads
better than broken.

The mod's **tags** are shown in the same `"Title: Value"` form the library stores: an install copies those strings straight onto the mod, so a tag has to read identically on the page and on the folder it became.

## 10. What the pages say when they have nothing to show

`services/gamebanana/gb_failure.dart` decides, `components/marketplace/gb_state_view.dart` renders.
**One decision, one surface, every page**, so the grid, a mod's page and a creator's page cannot drift apart in what an error says or how it is drawn.

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

The two that matter most are `rateLimited` and `notFound`.
A back-off reported as *"Something went wrong"* reads as a bug in the app, and a removed mod reported the same way sends the user retrying forever.

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

Printed under the heading, that field would render a back-off as the untranslated `Server asked us to back off (HTTP 429)`.
The detail goes to the log instead: the client logs the failed request where it happens, with the url and the status ([`logging.md`](logging.md)), and `GbFailureState` logs nothing, since a line in a `build` would repeat on every rebuild.
**The type is what enforces this**: `GbFailure` carries a kind and nothing else, so there is nowhere to put a message even by accident.

The l10n keys are spelled out as literals in the widget's switch rather than built
from a stem, because `test/l10n_keys_test.dart` finds keys by scanning `lib/` for
single-quoted literals and cannot see an interpolated one.

### The empty states carry the control that acts on them

Three claims, because *no results*, *your filter hid all of these* and *you have all of these* are different, and showing the wrong one sends the user hunting for a mod that was never in the results.
They show only once the last page is in: while more pages exist, a listing whose loaded cards were all dropped keeps loading (§8). Each offers what it can:

| State | Action |
|---|---|
| No results, while searching | **Clear search** — the same call as submitting an empty box, so the header's listener empties the text field for free |
| No results, browsing | none — inventing a button here would send the user pressing something that cannot help |
| Everything dropped, at least one by the content filter: "Every result is hidden by your adult-content filter.", or "…by your adult-content filter or by Hide installed." when Hide installed dropped the rest | **Blur them instead** |
| Everything dropped by Hide installed alone: "You have every one of these installed." | **Show installed**, which turns the switch off |

**"You have every one of these installed" needs Hide installed to have dropped every result.** A mod the content filter dropped is not known to be installed, so a mix of the two is the content filter's state, worded to name both.

**A first page that fails** on a new search, chip or sort replaces the grid with the failure and its Try again, and nothing more loads under it (§8).
A failed Refresh changes nothing on screen: its request runs before the feed is rebuilt, so the cards it had stay up.

**A next page that fails** keeps the cards already loaded and says "Couldn't load more" under them with Try again, in the spot where the loading ring was.
Nothing retries on its own: the scroll check waits until Try again is pressed, so a dead connection is not asked again on every frame.

**The filter action degrades `hide` to `blur`, never to `show`** — the same rule the resolve dialog follows ([`library-screen.md`](library-screen.md) §14).
`blur` is the mode where the cards are on screen and each one can still be clicked through individually, so it answers the complaint without turning a deliberate choice into its opposite.
Only `hide` can produce this state, so there is one transition and no branch.

It writes through a **`ContentFilterWriter`** seam (the typedef
`components/settings/marketplace_section.dart` already defines, reused so there is
one signature for this write rather than two), defaulting to
`ApiService.setContentFilter`. Not optional: `ApiService` lazily builds a
`ConfigService` against the developer's real `<appData>/config.json`, so a widget
test that pressed that button without a seam would rewrite their own settings.

### What is deliberately silent, and stays so

Not everything that can fail should say so, and these are decisions rather than
gaps:

- **The carousel is absent rather than empty** on loading, error, or a filter that
  hides every entry. It is a decorative strip above the real content, and a spinner
  or an error box there reports a problem the user cannot act on and did not ask
  about.
- **The type chips are absent while the roots load or when they fail**, and the character popover says only that the characters couldn't be loaded.
  Both fail exactly when the listing beside them fails, and that error is already on screen; two messages for one outage read as two problems.
- **A failed enrichment says nothing** (§7): the cards work without it.
- **Thumbnails have no per-tile spinner.** A grid of them flickering is worse than
  tiles that fill in; the container behind is already the right size and colour, so
  nothing reflows.
- **The mod page's last crumb falls back to `#<modId>`, not to *Loading…*, once the profile has failed.** Left as the loading string it would sit over a message saying the load had failed.
- **The mod page's Updates section is absent** while the posts load, when they fail, and for a mod with none, for the carousel's reason: it is a summary beside the real content, and an error there reports an outage the page's own error already covers, or one nobody asked about.

## 11. Descriptions

`_sText` is HTML while every description this app renders is markdown, so it goes
through `utils/html_to_markdown.dart` — shared with the description editors'
paste-as-markdown so the two can't drift.

## 12. The creator page

`GbCreatorView` is the `BrowseCreator` artboard: every Zenless Zone Zero mod one member published. The author's name on a mod's page opens it (§9), with the member the mod page's `_aSubmitter` names, so the name and the avatar are there before the listing loads.

Under the crumbs (§3) and Open on GameBanana, which opens the member's profile:

- **The header**: the avatar, 76px, over the member's initials on a dark gradient, which show while it loads and where it fails; the name in `displayMedium`; and "14 mods for Zenless Zone Zero. 2 of them are in your library.", both counted, "None of them are in your library." for none, and the second sentence left out until the library has been read. A member with one mod reads "It's in your library." or "It isn't in your library.", since "1 of them" names a group of one.
- **The character tiles**, a row that scrolls sideways: All mods first, with its count as a large outlined numeral, shrunk to fit the tile from four digits up, then one tile per group, most mods first and ties by name. A tile is 96 × 128: the portrait anchored near its top (`CharacterAvatar.assetPathFor`), or the initials outlined where there is none, a shade along the bottom with the name and "N mods", and a 3px bar in the element's colour, the neutral grey for a type, the accent on All mods while it is on. The tile that is on carries the accent border and ring, and its name is the accent lightened 30% towards white (`accentOnInk`), which reads on the dark tile whatever the accent, violet with the Paper accent; the other portraits dim. Pressing it again goes back to All mods. The tiles are drawn on the ink palette in both themes, since a portrait under a dark shade is artwork, as the carousel's overlays are (§7).
- **The bar**, pinned once the header scrolls away: what the grid shows, "All 14 mods", "5 mods for Ellen Joe" or "9 not installed", with "Show all 14" while a tile is on; and at the right Hide installed, the same remembered switch as Browse's, and the Sort menu.
- **The grid**: Browse's cards and grid (§7, §8), with the byline naming the character.
- **Under the grid**: the ring while later pages load, "Couldn't load more" with Try again when one failed, and "Showing the first 1000 mods." when the page stopped there.

**A group is a character or a type** (`utils/creator_cast.dart`). A Character Skins mod is its character, mapped from the category as an install maps it (`RemoteModMetadata.characterIdForMod`), under the roster's name, so the tile and the byline read as the Library does ("Nekomata" for GameBanana's "Nekomiya Mana"). A mod of another type, UI, Misc or Bangboo, is one tile under its type chip's label, whichever child it is filed under: an author's Bangboo skins are one Bangboo tile. The type is decided first, by the same `GbMod.typeCategoryId` the mod page and the install use, so a Bangboo or UI category whose name holds an agent's is never taken for that agent. A Character Skins child that maps to no roster character is a tile under its GameBanana name. Each category name is mapped once and the answer kept, since the mapping runs a pattern per roster term and the page asks for every loaded mod's group on each build. Measured on two captured listings, every Character Skins category maps and no mod of another type does (`test/creator_cast_test.dart`).

**Every page is loaded, up to 20.** The tiles and both counts are about the member's whole set, so the page does not scroll into it as Browse does. `creatorFeedProvider` answers with page 1, which shows the header and the tiles, and then fetches the rest one page at a time at `_nPerpage=50`, the cap, each appended as it lands, so the counts fill in. It stops at `_bIsComplete`, at the record count, or at 20 pages, 1000 mods, and then says it shows the first 1000; the rest are on GameBanana through Open on GameBanana. A later page that fails stops the loading, keeps what is in, and waits for Try again. Each page is enriched by one `Mod/Multi`, as Browse's are (§7). Every page goes through the client's 10-minute cache: the whole set is fetched within moments, so its pages are as old as each other.

**Filtering runs on what is loaded.** The content filter drops records first, as on Browse, so with Hide entirely a hidden mod counts nowhere: not in the header, not on a tile. A tile and Hide installed then narrow the grid. A tile counts the member's mods whatever Hide installed hides, so a tile whose mods are all installed still says how many it has; the grid under it says "You have every one of these installed." with Show installed. "Show all" names what pressing it shows, so with Hide installed on it counts the mods not installed.

**The sort is the page's own.** It starts from Browse's and is never saved, and a change fetches the listing again: GameBanana sorts, so a client-side sort of the loaded set would differ from the site's.
The header, the tiles, the bar's count and the tile that is on come from the last listing that finished loading (`_countedFeed`), since a new order is the same set of mods: the new sort's listing takes over once it has finished, or once it holds as many mods, while the grid already shows the new order as its pages land. Counted from the new listing's first pages, every number would drop to a page's worth and climb back.

**What it says when there is nothing to show**: a failed first page, `GbFailureState` with Try again (§10); a member with no Zenless Zone Zero mods, "lacequeen has no Zenless Zone Zero mods."; everything dropped by the content filter, Browse's state with Blur them instead; and everything a tile shows hidden by Hide installed, Browse's state with Show installed.
