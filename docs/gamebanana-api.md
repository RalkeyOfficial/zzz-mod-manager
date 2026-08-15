# GameBanana API

Practical reference for talking to GameBanana from this app: which of the two APIs
to use, how to browse and filter, what every field we care about means, and where it
will bite you.

**Everything here was verified against the live API on 2026-08-01, and re-verified
against apiv13 on 2026-08-15**, anonymously, with no cookies and no account.
Requests are plain `GET`s that return JSON. Examples use the ZZZ game id
**`19567`**; a real mod (`698834`) and file (`1770600`) are used so you can paste
any of them into a terminal.

> Scope: the *remote* protocol only — what GameBanana serves and how to ask for it.
> **Not** our client, which lives in
> [`../mod_manager_flutter/CLAUDE.md`](../mod_manager_flutter/CLAUDE.md). How we store
> what comes back is [`metadata-schema.md`](metadata-schema.md); what we record about
> *which* remote file a local mod is, [`origin-tracking.md`](origin-tracking.md).

---

## 1. There are two APIs. Use apiv13.

| | **apiv13** | **Core API (legacy)** |
|---|---|---|
| Base | `https://gamebanana.com/apiv13` | `https://api.gamebanana.com` |
| Documented? | **No** — no `/apidocs` page exists | **Yes**, at <https://api.gamebanana.com/> (and self-describing, see [§10](#10-the-legacy-core-api)) |
| Who uses it | GameBanana's own site | Third-party apps, older tooling |
| Filtering | Rich (`_aFilters`, 7 sort aliases) | Almost none — 3 sorts, 1 filter |
| Shape | Purpose-built responses (`ProfilePage`, `DownloadPage`) | Field-picker (`?fields=a,b,c`) |

**Use apiv13 for everything.** It returns whole screens in one request, it's what the
website itself calls (so it won't rot quietly), and the legacy API's filtering is too
weak to build a browser on. The tradeoff — being undocumented — is why this file
exists.

The Core API is still worth knowing for two things: it's *self-describing* (it can
enumerate its own allowed fields and sorts), and it exposes a couple of things
apiv13 doesn't name as plainly. See [§10](#10-the-legacy-core-api).

### Versions, and why v13 rather than v11 or v12

`apiv11`, `apiv12` and `apiv13` all serve today, and **v11 carries no deprecation or
sunset header**, so nothing forces the move — but its `_aPreviewMedia` is a shape the
site itself no longer requests, which is exactly what rots quietly on an API with no
`/apidocs`.

**The entire difference between v11 and v13 is the preview-image field**, plus a new
`_sPayType` (`free`/`freemium`). Everything else was re-verified unchanged: sorts,
filters, the `_nPerpage` cap, the error envelope, `DownloadPage`, `Mod/Categories`,
`Game/<id>/ProfilePage`, `Subfeed`, `_aFiles`, and downloads.

| | v11 | v12 | v13 |
|---|---|---|---|
| `_aPreviewMedia` | ✅ | ✅ | ❌ removed |
| `_aPreviewContent` | ❌ | ✅ | ✅ |
| `_sPayType` | ❌ | ✅ | ✅ |
| `cache-control` | `max-age=600` | **none** | **none** |

**Skip v12**: it is the transitional version that carries *both* image shapes, and
offers nothing v13 doesn't. The image change is [§5](#images); the missing
`cache-control` is [§2](#caching-and-rate-limits).

### No authentication, for anything we do

There is no API key, no OAuth, and no login for reading. Browsing, mod details, file
lists and **file downloads** all work fully anonymously — including adult/NSFW
submissions ([§7](#7-nsfw-and-content-ratings)). The Core API has an
`App/Authenticate` flow, but it exists for apps acting *as a user* (posting, likes);
nothing we do needs it.

---

## 2. Conventions you need before reading any response

### Field-name prefixes are types

GameBanana uses a Hungarian-ish prefix on every key. Once you know these, responses
read themselves:

| Prefix | Type | Example |
|---|---|---|
| `_id…` | row id (int) | `_idRow` |
| `_s…` | string | `_sName`, `_sProfileUrl` |
| `_n…` | number | `_nLikeCount`, `_nFilesize` |
| `_b…` | boolean | `_bIsObsolete` |
| `_a…` | array / object | `_aFiles`, `_aSubmitter` |
| `_ts…` | **Unix timestamp, seconds** | `_tsDateAdded` |
| `_ds…` | date *string* | `_dsReleaseDate` |
| `_csv…` | comma-separated input param | `_csvProperties` |
| `_h…` | pixel height | `_hFile220` |

Two exceptions that will trip you up: **`_nStatus` is a string** (`"0"`), and a
`_ts…` of **`0` means "never"**, not 1970 — treat it as null.

`_w…` (pixel width) was a prefix under apiv11 and **no longer appears anywhere in
apiv13** — image variants now ship a height only, because the width is the variant
size itself ([§5](#images)).

### Request parameters

Query params only. Array params use PHP bracket syntax and **must be URL-encoded**:

```bash
# _aFilters[Generic_Game]=19567
curl 'https://gamebanana.com/apiv13/Mod/Index?_aFilters%5BGeneric_Game%5D=19567&_nPerpage=5'
```

Common params: `_nPage` (1-based), `_nPerpage`, `_sSort`, `_aFilters[…]`,
`_csvProperties`.

### Pagination

Listing endpoints return `_aMetadata` beside `_aRecords`:

```json
{ "_aMetadata": { "_nRecordCount": 5149, "_nPerpage": 50, "_bIsComplete": false },
  "_aRecords": [ … ] }
```

- `_nRecordCount` — total matches, so you can compute page count up front.
- `_bIsComplete` — `false` means more pages exist.
- **`_nPerpage` caps at 50** on `Index`/`Subfeed` — asking for 100 is a hard error
  (`INVALID_PERPAGE`). **Search silently caps at 15** and does *not* error, so never
  trust the value you asked for; read it back from `_aMetadata`.

### Errors

HTTP status carries the class, the body carries the detail:

```json
{ "_sErrorCode": "INPUT_ERRORS",
  "_aErrorData": { "_sSort": { "_sErrorCode": "UNKNOWN_SORT",
                               "_sErrorMessage": "Sort alias not recognized" } } }
```

Codes seen: `NO_SUCH_RECORD` (404), `INPUT_ERRORS` (400) with a per-parameter
breakdown, `UNKNOWN_FILTER`, `INVALID_FILTER_VALUE`, `UNKNOWN_SORT`,
`UNKNOWN_PROPERTY`, `VALUE_NOT_ALLOWED`, `INVALID_PERPAGE`. Errors **do not
enumerate the valid values** — "not recognized" is all you get, which is why
[§4](#4-sorting-and-filtering) lists them explicitly.

**An unrecognised *route* is no longer a JSON error.** apiv11 and apiv12 answer
`/apiv1N/Mod/NoSuchRoute` with `404` + `{"_sErrorCode": "NO_SUCH_ROUTE"}`; **apiv13
returns `200` with a full HTML error page**, which a JSON client will hit as a parse
failure rather than a typed error. Worth knowing, but not worth defending against
with anything elaborate: routes are written by us, not by users.

What *users* can reach is a **missing mod id**, and that is unchanged —
`Mod/999999999/ProfilePage`, `/DownloadPage` and `/Updates` all still return `404`
with `{"_sErrorCode": "NO_SUCH_RECORD", "_sErrorMessage": "This Mod doesn't exist"}`.
So a "has this mod been removed?" check behaves identically on v13.

### Caching and rate limits

- **apiv13 sends no `cache-control` at all.** apiv11 answered every request with
  `public, max-age=600`, and the advice used to be "mirror that 10-minute TTL rather
  than inventing one". There is now nothing to mirror, so a client cache has to pick
  its own number — 10 minutes remains a defensible one, inherited from what v11 used
  to advertise, but be honest that it is a choice rather than the server's
  instruction. Honour a `max-age` if one reappears.
- **No published rate limit** — no `RateLimit-*`, no `Retry-After` on normal
  responses. 30 concurrent requests in a burst all returned `200` with no throttling.
  That is *not* a licence to hammer it: treat backoff as reactive (on `429`/`503`),
  keep the bulk update pass bounded and cancellable, and cache aggressively.
- Served through Cloudflare. Send a real, identifying `User-Agent` — an app name and
  version. Don't impersonate a browser.

---

## 3. The endpoints that matter

| Endpoint | Returns |
|---|---|
| `GET /apiv13/Game/<gameId>/ProfilePage` | Game info + **its sections and mod root categories** |
| `GET /apiv13/Mod/Categories?_idGameRow=<id>&_sSort=…` | Root categories for a game |
| `GET /apiv13/Mod/Categories?_idCategoryRow=<id>&_sSort=…` | **Subcategories** of a category |
| `GET /apiv13/Mod/Index?_aFilters[…]&_sSort=…` | Filtered, sorted mod list — the browse workhorse |
| `GET /apiv13/Game/<gameId>/Subfeed` | The game's activity feed (newest-ish, unfiltered) |
| `GET /apiv13/Game/<gameId>/TopSubs` | **"Best of period" — 3 mods × 7 time windows.** See [§3.1](#31-top-submissions--gameidtopsubs) |
| `GET /apiv13/Util/Search/Results?_sModelName=Mod&_sSearchString=…` | Text search |
| `GET /apiv13/Mod/<id>/ProfilePage` | Everything for a mod detail screen, in one call |
| `GET /apiv13/Mod/<id>/DownloadPage` | Just the file lists — cheap, for update checks |
| `GET /apiv13/Mod/<id>/Updates` | The author's changelog entries |
| `GET /apiv13/Mod/Multi?_csvRowIds=…&_csvProperties=…` | **Many mods, chosen fields, one request** |

### Browsing — `Mod/Index`

The one to build the results grid on. Filter, sort and page:

```bash
# UI mods for ZZZ, most liked first
curl 'https://gamebanana.com/apiv13/Mod/Index?_aFilters%5BGeneric_Game%5D=19567\
&_aFilters%5BGeneric_Category%5D=30395&_sSort=Generic_MostLiked&_nPerpage=20&_nPage=1'
```

Records are the **compact mod shape** ([§5](#5-the-mod-object)) — enough for a card,
not enough for a detail view.

### `Subfeed` vs `Index`

`Game/<id>/Subfeed` is the site's activity feed: no filters, no sort control. Fine for
a "what's new" strip; use `Index` for anything the user controls.

### 3.1 Top submissions — `Game/<id>/TopSubs`

Undocumented even by the standards of the rest of apiv13 — it appears in no field
list and was found by probing route names. It is the **only** way to get
period-ranked "best of" data, and worth knowing about before anyone tries to
synthesise it:

```bash
curl 'https://gamebanana.com/apiv13/Game/19567/TopSubs'
```

Returns a **bare array** of exactly **21 entries: three for each of seven windows**,
each tagged with `_sPeriod`:

`today` · `week` · `month` · `3month` · `6month` · `year` · `alltime`

- **Takes no parameters.** `_nPerpage` and `_sPeriod` are both ignored — the same
  21 entries come back regardless (see the silent-parameter gotcha in
  [§11](#11-gotchas)).
- **This cannot be built from `Mod/Index`.** There is no date-window filter, and
  the like counts everywhere else are *lifetime* totals, so "best of this week" is
  not derivable from any other endpoint.
- `cache-control: public, max-age=600`, same as everything else.
- **`content-type: text/html`** despite the body being JSON. Parse by content, not
  by header.

Its entry shape is its **own**, not a subset of the mod object:

| Field | Notes |
|---|---|
| `_idRow` | A normal mod id — opens through `Mod/<id>/ProfilePage` like anything else |
| `_sPeriod` | The window this entry won |
| `_sName`, `_sProfileUrl` | |
| `_aPreviewContent.screenshot` | The cover, as the **ordinary variant ladder** ([§5](#images)) — `_sFile` is the 800px render here rather than an original upload, with `_sFile220` beside it. Under apiv11 this was two finished urls (`_sImageUrl`, `_sThumbnailUrl`) with no size to negotiate; that difference is gone |
| `_sInitialVisibility` | Present on every entry, so the NSFW filter still applies |
| `_aSubmitter`, `_nLikeCount`, `_nPostCount` | |
| `_aRootCategory` | Root only — **no `_aSubCategory`**, so an entry cannot show a character name |
| `_sDescription` | A short tagline, present on only a minority (3 of 21 captured) |

One practical warning: for ZZZ this list skews heavily adult — **20 of 21 captured
entries were `warn`/`hide`**. A client that omits flagged mods will show almost
nothing here, so it needs to collapse gracefully rather than render empty headings.

### Search — `Util/Search/Results`

```bash
curl 'https://gamebanana.com/apiv13/Util/Search/Results?_sModelName=Mod\
&_sSearchString=ellen&_idGameRow=19567&_nPage=1'
```

`_sModelName` picks what you're searching (`Mod`, `Sound`, `Thread`, `Member`, …).
`_idGameRow` scopes it to one game. **Hard-capped at 15 per page** — page through it.
Note it's a *different* parameter style from `Index` (`_idGameRow`, not a filter),
which is easy to get wrong.

### Mod detail — `Mod/<id>/ProfilePage`

One request fills an entire detail screen. Top-level keys:

```
_idRow _sName _sText _sVersion _sProfileUrl _sDownloadUrl _sLicense _sCommentsMode
_sPayType
_tsDateAdded _tsDateModified _tsDateUpdated
_aGame _aCategory _aSuperCategory _aSubmitter _aTags _aCredits _aContributingStudios
_aPreviewContent _aFiles _aArchivedFiles _aEmbeddables _aLicenseChecklist
_aContentRatings _sInitialVisibility
_nLikeCount _nViewCount _nDownloadCount _nPostCount _nThanksCount _nSubscriberCount
_nUpdatesCount _bHasUpdates _nAllTodosCount _bHasTodos
_bIsObsolete _bIsPrivate _bIsTrashed _bIsWithheld _bIsPorted _bCreatedBySubmitter
_bAcceptsDonations _bAccessorIsSubmitter _bFollowLinks _bGenerateTableOfContents
_nStatus _sInitialVisibility _bShowRipePromo
```

### Update checks — `Mod/<id>/DownloadPage`

Returns `_aFiles` + `_aArchivedFiles` (plus `_bIsTrashed` / `_bIsWithheld`) and
nothing else. Much cheaper than `ProfilePage` when all you need is "did the file list
change?".

### Releases and changelogs — `Mod/<id>/Updates`

Paginated author update posts: `_idRow`, `_sName` (title, often the closest thing to
a real version number a mod page has — `Version 1.5`), `_tsDateAdded`, `_sProfileUrl`,
and the body in `_sText`. This is the changelog to show before updating — no scraping
needed.

**apiv13 dropped the pre-truncated body snippet.** apiv11 carried a ready-made teaser
at `_aPreviewMedia._aMetadata._sSnippet`; v13's `_aPreviewContent` here holds a stock
`DefaultEmbeddables/Update.jpg` illustration instead, and no snippet anywhere. Take
the teaser from `_sText` yourself.

**`_aFileRowIds` is the field that matters most, and it is easy to miss.** It lists
the files released *together* in that post, which is the only authoritative answer to
a question no comparison of `_sVersion` and `_sDescription` can settle: are these two
files a new version and an old one, or two variants of the same one? The author
already grouped them. Two measured examples:

```jsonc
// mod 549029, "Version 1.5"
"_aFileRowIds": [1484606, 1484607]   // SFW + NSFW, 90 seconds apart, one release
// mod 675945, "Orginal Proportions added"
"_aFileRowIds": [1701141, 1701140, 1701139, 1701164]  // four proportion variants
```

Three things to know:

- **`_nPerpage` defaults to 5** and a busy mod can have 50 posts (measured on
  `531649`). Page one is enough for an update check — the question is always about
  the *newest* release — but don't assume the feed is complete.
- `_aFiles` (full file records) is present on both the list route and
  `Update/<id>/ProfilePage`. `_bHasFiles` is unreliable: it reads `false` on a record
  whose `_aFileRowIds` names two files.
- Record shapes differ between mods, so parse leniently: one captured feed carries
  `_aChangeLog` (`[{text, cat}]`) and no `_sVersion`, another carries `_sVersion` and
  no `_aChangeLog`.

### Bulk — `Mod/Multi`

The most useful non-obvious endpoint. Fetch many mods at once **and pick the fields**:

```bash
curl 'https://gamebanana.com/apiv13/Mod/Multi?_csvRowIds=698834,605830\
&_csvProperties=_idRow,_sName,_sVersion,_tsDateUpdated,_aFiles,_bIsObsolete'
```

Returns a bare **array** (no `_aMetadata` wrapper) in the requested order. This is how
a bulk "check all mods for updates" pass is built: batches of ids in a handful of
requests instead of one request per mod. Four things to know, all measured rather than
assumed, and the last two will bite:

- `_csvProperties` is honoured **here but ignored by `Index`** — don't expect it to
  trim listing payloads.
- **`_csvProperties` accepts a narrower set than a profile carries.** `_aFiles`,
  `_sVersion`, the `_ts…` dates, `_bIsObsolete` / `_bIsPrivate` / `_bIsTrashed` /
  `_bIsWithheld`, `_sProfileUrl` and `_aPreviewContent` all work. `_aArchivedFiles`
  and `_bHasFiles` are rejected outright as `UNKNOWN_PROPERTY` — **as is
  `_aPreviewMedia` on v13 and `_aPreviewContent` on v11**, so this parameter is a
  place the version difference surfaces as a hard `400` rather than a missing field.
  `_sPayType` is rejected on both.
- **`_aFiles` here is the union of current *and* archived files**, unlike
  `ProfilePage` where they are two separate keys. Measured on mod `531649`: 14 entries
  from `Multi` against 6 + 8 from its profile, same ids. `_bIsArchived` is what tells
  them apart, and it is populated in both responses — so read that flag, never the key
  an entry arrived under. Losing `_aArchivedFiles` above therefore costs nothing.
- **One unknown id fails the whole batch.** A `_csvRowIds` list containing a single id
  the server doesn't recognise returns `400 INPUT_ERRORS` with
  `_csvRowIds: NO_SUCH_RECORD`, and the message names only the *first* offender, so
  there is nothing to skip and retry — only a range to narrow. Any caller handing it
  ids parsed out of user-typed urls must expect this and recover per id (halving the
  batch is what this app does). Distinguish it from a url-level error by which field
  `_aErrorData` names: anything other than `_csvRowIds` will fail identically for
  every subset.
- 60 ids in one url were verified to work; this app caps a batch at 50.

---

## 4. Sorting and filtering

Verified by brute force, since errors don't enumerate valid values.

### `_sSort` on `Mod/Index`

| Alias | Meaning |
|---|---|
| `Generic_MostLiked` | Likes, descending |
| `Generic_MostDownloaded` | Downloads |
| `Generic_MostViewed` | Views |
| `Generic_Newest` | Newest submissions |
| `Generic_Oldest` | Oldest submissions |
| `Generic_LatestModified` | Recently updated |
| `Generic_LatestComment` | Recent discussion |

Rejected (don't guess): `Generic_LatestAdded`, `Generic_Alphabetical`,
`Generic_Featured`, `Generic_Random`, `Generic_MostFollowed`, `Generic_MostPosts`,
and every lowercase form (`new`, `popular`, `updated`, …).

#### `Generic_Newest` is *submitted*, not *updated* — and it hides live mods

The single most misleading pair here. `Generic_Newest` orders by `_tsDateAdded`
(first published), so a mod submitted months ago and updated an hour ago sorts to
its **original** date. Measured on ZZZ: a mod submitted 2026-05-10 and updated
2026-08-05 was **more than 420 mods deep** under `Generic_Newest`, while
`Generic_LatestModified` put it on page 1. Anything that means "what's new" for a
user wants `Generic_LatestModified`.

#### There is no "ripe" sort, and this is the gap that will confuse you

GameBanana's **website defaults to its own "ripe" ranking**, which is not exposed by
either API:

- Every plausible alias is rejected with `UNKNOWN_SORT` — `Generic_Ripe`, `Ripe`,
  `Generic_MostRipe`, `Generic_Ripest`, `Generic_Hot`, `Generic_Trending`,
  `Generic_Popular`, `Generic_Best`, `Generic_Relevance`.
- The legacy Core API has no such sort either:
  `Core/List/Section/AllowedSorts?itemtype=Mod` returns exactly
  **`["id", "name", "udate"]`** ([§10](#10-the-legacy-core-api)).

> **Honesty about the strength of that second point.** The Core API enumerates
> *its own* surface, not apiv13's — apiv13 has seven `Generic_*` sorts that appear
> nowhere in that list. So it is corroboration, **not proof**: apiv13 has no
> discovery endpoint, so "no ripe sort exists there" rests on nine rejected guesses.
> (An earlier revision of this file overstated it as settled. It isn't.)

So **a listing built on `Mod/Index` cannot reproduce the order the user sees on the
site**, and a mod that looks prominent there can look absent in a client. Expect this
comparison to be made, because it is the obvious one.

What *is* available is period-ranked "best of" data, from a different endpoint
entirely — [`Game/<id>/TopSubs`](#31-top-submissions--gameidtopsubs). That is not a
sort you can apply to a listing, but it covers the "what's hot" case directly.

The closest reachable approximations:

| Want | Use | Caveat |
|---|---|---|
| What the site shows by default | `Game/<id>/Subfeed` | Mixes new + updated, but accepts **no filters and no sort** |
| Actively-maintained mods | `Mod/Index` + `Generic_LatestModified` | Sortable and filterable; ordering differs from the site |

For reference, the same mod that was 420-deep under `Generic_Newest` sat **3rd in
`Subfeed`** — which is why the site felt like it was showing something the API
wasn't.

### `_aFilters` on `Mod/Index`

| Filter | Value | Notes |
|---|---|---|
| `Generic_Game` | game id | `19567` for ZZZ. The one you always send. |
| `Generic_Category` | category id | Works on **root or sub** categories; a root category **includes its subcategories**. |
| `Generic_Submitter` | member id | Everything by one author. |
| `Generic_Name` | — | Exists, but rejects plain strings (`INVALID_FILTER_VALUE`). Use `Util/Search/Results` for text instead. |

Rejected: `Generic_Tag`, `Generic_ContentRating`, `Generic_HasFiles`,
`Generic_Featured`, `Generic_Section`, `Generic_RootCategory`. **There is no
server-side NSFW or tag filter** — both have to be applied client-side.

### `_sSort` on `Mod/Categories`

This endpoint **requires** `_sSort` and its own vocabulary — the `Generic_*` aliases
are rejected, and the default it applies internally (`most_items`) is itself invalid,
so omitting the parameter is always an error.

| Alias | Meaning |
|---|---|
| `a_to_z` | Alphabetical |
| `count` | Most items first |

---

## 5. The mod object

Listing endpoints return a compact record; `ProfilePage` returns the full one. Fields
we actually care about:

| Field | Where | Meaning |
|---|---|---|
| `_idRow` | both | **The mod id.** The stable handle — far better than a URL. |
| `_sName` | both | Title. |
| `_sProfileUrl` | both | `https://gamebanana.com/mods/<id>` — the human page. |
| `_sVersion` | both | Author's version string (`"v3.1.0"`, `"1.1"`). Free-form: **not** semver, sometimes absent. |
| `_sText` | profile | Description, **HTML** (not markdown). |
| `_tsDateAdded` | both | First published. |
| `_tsDateUpdated` | both | Last content update — the comparator for "is there something new". **Null on a mod that has never been updated** (a `_ts` of `0` means never), so it is not a safe stand-in for `_tsDateAdded`. The two routinely differ by a lot: the captured listing has mods added in 2024 and updated the same week it was taken. |
| `_tsDateModified` | both | Last *any* edit (including trivial ones). Noisier than `_tsDateUpdated`. |
| `_aSubmitter` | both | `_idRow`, `_sName`, `_sProfileUrl`, `_sAvatarUrl`. |
| `_aRootCategory` | list | The **top-level** category only — for a skin that is the bland "Character Skins". |
| `_aSubCategory` | list | The **specific** category, and the only place a listing names it. For ZZZ this is usually the *character* ("Ellen Joe"). Absent on mods filed directly under a root. |
| `_aCategory` | profile | The profile's spelling of the specific category. Carries `_idRow`; the two listing spellings do not (see [below](#three-spellings-of-category)). |
| `_aTags` | both | Author tags. **Two different wire shapes** — see below. Often empty; don't rely on it for character detection. |
| `_aPreviewContent` | both | Gallery — but **`screenshots` (array) on a profile and `screenshot` (one object) on a listing**. See below. |
| `_sPayType` | both | New in v12. `free` / `freemium` (43 / 7 in a 50-record sample). Not accepted by `Mod/Multi`. |
| `_nLikeCount`, `_nViewCount`, `_nPostCount` | both | Stats for the card. |
| `_nDownloadCount` | **profile only** | **Not on listing records.** A card cannot show a download count — see below. |
| `_bHasFiles` | list | Whether anything is downloadable. |
| `_bIsObsolete` | both | Author flagged it superseded — **not** the same as gone. |
| `_bIsPrivate`, `_bIsTrashed`, `_bIsWithheld` | profile | Upstream removal states. Read these instead of inferring from a 404. |
| `_bHasUpdates`, `_nUpdatesCount` | profile | Whether `Mod/<id>/Updates` has anything. |
| `_sInitialVisibility` | both | Content gating hint — [§7](#7-nsfw-and-content-ratings). |
| `_bHasContentRatings` | list | Boolean flag. Listings carry **this and not the ratings map**. |
| `_aContentRatings` | profile | The reasons map. **Absent from listings**, and absent entirely on unrated mods. |

### Which fields a listing actually omits

Re-checked against a live `Mod/Index` page and the captured fixtures, because getting
this wrong shows up as a card rendering a confident zero:

- **`_nDownloadCount` is profile-only.** Build cards on likes / views / posts. Model
  the counters as nullable and omit what you weren't given — "0 downloads" on a mod
  with 40 000 downloads is worse than no number.
- **`_aContentRatings` is profile-only.** A listing gets `_bHasContentRatings`, a bare
  boolean, so a **card can flag a mod but cannot say why**; only the detail view can
  name "Skimpy Attire". Don't design a card that promises the reason.
- **`_aArchivedFiles` is omitted, not empty,** when a mod has no superseded files. So
  `null` and `[]` genuinely both occur and mean different things (see
  [§6](#6-files--_afiles-and-_aarchivedfiles)).
- **The gallery is profile-only as of apiv13.** A listing's `_aPreviewContent` holds
  one `screenshot` object — the cover — where a profile holds the full `screenshots`
  array. A card is unaffected; anything wanting more than one image must fetch the
  profile ([§5](#images)).

### Three spellings of "category"

One concept, three keys, and no response carries more than two of them:

| Response | Specific category | Parent |
|---|---|---|
| `Mod/Index`, `Util/Search/Results` | `_aSubCategory` | `_aRootCategory` |
| `Mod/<id>/ProfilePage` | `_aCategory` | `_aSuperCategory` |

Only the profile's `_aCategory` includes `_idRow`. On a listing, **the id exists solely
inside `_sProfileUrl`** (`https://gamebanana.com/mods/cats/30341`), so recovering it
means parsing that url — which matters because the id is the only thing the
`Generic_Category` filter accepts. Code that wants "the most useful category label"
should try specific-then-parent rather than picking one key.

**Under Character Skins, the category name is the character's full in-world name** —
"Ellen Joe", "Anby Demara", "Von Lycaon", "Soldier 0 Anby" — not a short name and not
an id. That makes it the most reliable statement of *which character a mod is for*
that the API offers: the author picked it from a list, where `_sName` and `_aTags` are
free text. The names it is **not** are just as important, because they must not be
read as characters: the four roots ("Character Skins", "Bangboo Skins", "Other/Misc",
"UI") and the 22 children of Bangboo Skins ("Avocaboo", "Eous", "Sharkboo", …).

### `_aTags` has two shapes

The same field, spelled differently by endpoint — and the string form is the *only*
one a listing sends, so code written against a listing reads a profile's tags as
**empty** rather than failing:

| Response | Shape |
|---|---|
| `Mod/Index`, `Util/Search/Results` | flattened strings: `"Software Used: Blender"` |
| `Mod/<id>/ProfilePage` | objects: `{"_sTitle": "Software Used", "_sValue": "Blender"}` |

What the values actually *are* is worth knowing before treating them as keywords.
Authors fill both halves freely, so a tag is two loosely-related fragments —
`{"Ellen", "Chained school uniforms"}`, `{"cheongsam", "ellen"}` — and the single
most common title is `Software Used`, naming the author's toolchain rather than the
mod. Measured over the captured listings: **4 of 20 records carry any tag at all, and
3 of the 6 distinct values are the `Software Used` family.**

### Images

**This is the one thing apiv13 changed**, and it is what the version exists for —
GameBanana's own announcement calls it "unifying image and thumbnail URLs into a
single system". `_aPreviewMedia` is **gone**; `_aPreviewContent` replaces it.

```jsonc
// apiv11                                  // apiv13
"_aPreviewMedia": {                        "_aPreviewContent": {
  "_aImages": [{                             "screenshots": [{   // listing: "screenshot", one object
    "_sType": "screenshot",                    "_sBaseUrl": "https://images.gamebanana.com/img/ss/mods",
    "_sBaseUrl": "…/img/ss/mods",              "_sFile":    "6a6d7bb20324f.jpg",
    "_sFile":    "6a6d7bb20324f.jpg",          "_sFile220": "sgi_common_thumbs_6a6d7bb20324f_220.webp",
    "_sFile220": "220-90_6a6d7bb20324f.jpg",   "_hFile220": 137,
    "_wFile220": 220, "_hFile220": 137,        "_sFile220Sfw": "…_220_sfw.webp",  // new, see §7
  }]                                           "_hFile220Sfw": 137,
}                                            }]
                                           }
```

Five things changed inside it:

- **Two container spellings, and this is the trap.** A profile sends `screenshots`
  — the whole gallery, as an array. Every listing (`Mod/Index`,
  `Util/Search/Results`, `Subfeed`, `TopSubs`) sends a single `screenshot`
  **object**. Reading only one of the two keys fails *silently*, as an empty
  gallery rather than an error.
- **A listing now carries only the cover.** Measured over the same 50 records:
  apiv11 returned **420** images, apiv13 returns **50**. v11 was sending entire
  galleries to a response that only ever renders the first image; nothing that
  displays a card loses anything, but a gallery must come from a profile.
- **Variants are WebP**, named `sgi_common_thumbs_<hash>_<size>.webp` from a shared
  thumbnail store. `_sFile` is still the original JPEG. Measured over 8 covers:
  **81 KB WebP against 127 KB JPEG, i.e. 64%**. Old JPEG urls still resolve, so
  nothing already stored breaks.
- **`_wFileNNN` is gone**; `_hFileNNN` is present on every rung (388/388 sampled).
  The width is the rung number — `_wFileNNN == NNN` held in 534 of 534 apiv11
  samples — so nothing is actually lost.
- **`_sType` is gone.** The container key says what it is.

### The ladder is not uniform, and cannot be reconstructed

Never fabricate a variant filename. That rule was already true and apiv13 makes it
absolute: under apiv11 a variant name was *derivable* from the original
(`6a6d7bb20324f.jpg` → `530-90_6a6d7bb20324f.jpg`), so guessing at least produced a
plausible url. apiv13's thumbnail hash **has no relationship to `_sFile`**, so a
variant that was not published cannot be constructed at all — only fallen back from.
Discover variants by scanning `_sFileNNN` keys.

Which rungs actually appear, measured on 150 listing covers and 55 profile gallery
images (2026-08-15):

| | `_sFile` | 100 | 220 | 530 | 800 |
|---|---|---|---|---|---|
| Listing cover | 150/150 | — | 150/150 | 150/150 | — |
| Profile cover | 5/5 | — | 5/5 | 5/5 | — |
| Profile non-cover | 50/50 | 50/50 | — | — | — |

So: **a cover reliably has 220 and 530, and a secondary gallery image reliably has
only 100 and the original.** Note the cover no longer publishes `_sFile100` at all,
which apiv11 did — anything asking for a ~100px cover now gets the 220 rung.

Sizes are small enough not to optimise for: two whole galleries measured
`Content-Length` image by image came to **15 images = 2.3 MB and 26 images =
5.5 MB**, ~115–310 KB each. "Full-resolution original" means *web-compressed jpeg*,
not a raw screenshot — the **decode** is multi-megapixel and needs bounding, but the
**download** is trivial beside a 21.9 MB median mod archive
([§8](#8-downloading-a-file)).

Three practical consequences: pick the variant by the size you will *display*; bound
the decode independently, because the url you get back is not always the size you
asked for; and note that **the ladder makes progressive loading nearly free** — a
small variant already on screen elsewhere can stand in for a larger one while it
downloads, provided both requests are built identically so they share a cache entry.

---

## 6. Files — `_aFiles` and `_aArchivedFiles`

A mod has *many* files (variants, optional extras, older releases). Both arrays hold
the same object shape; `_aArchivedFiles` holds superseded ones that are **still
downloadable**.

| Field | Meaning |
|---|---|
| `_idRow` | **File id.** What `/dl/<id>` refers to; record this, not the filename. |
| `_sFile` | Original filename (`remielleswimlite.rar`). |
| `_nFilesize` | Bytes. **Exactly equals the eventual `Content-Length`** (checked on four files), so it's safe for a preflight disk-space check and for a progress bar's denominator. Can be large — see [§8](#8-downloading-a-file) for the real distribution. |
| `_tsDateAdded` | When this file was uploaded. The date comparator for update checks. |
| `_sVersion` | **Per-file version string.** Optional; distinct from the mod-level `_sVersion`. |
| `_sDescription` | Free-text label the author gave the file (`"Full Mod"`). This is the *variant* label ("white hair ver"), not a version. |
| `_sDownloadUrl` | `https://gamebanana.com/dl/<fileid>`. |
| `_sMd5Checksum` | **md5 of the archive as uploaded.** Lets you identify a file the user supplied by hand. |
| `_nDownloadCount` | Popularity signal for picking the "main" file. |
| `_bIsArchived` | `true` for a superseded file. **This flag is the authority, not which array the entry came in** — `Mod/Multi` returns both kinds together under `_aFiles` ([§3](#bulk--modmulti)). |
| `_sAvState` / `_sAvResult` | Virus scan (`done` / `clean`). |
| `_sAnalysisState` / `_sAnalysisResult` / `_sAnalysisResultVerbose` | Preliminary content analysis (`done` / `ok` / human-readable). |

### A file id cannot be turned back into a mod id

`GET /apiv13/File/<id>` exists and returns the file record in full — `_sFile`,
`_nFilesize`, `_tsDateAdded`, `_sMd5Checksum`, `_sDescription`, the AV and
analysis verdicts, even `_aArchiveFileTree` listing everything inside the
archive. What it does **not** return, anywhere, is the mod that owns it.

Probed exhaustively (2026-08-08), because a user pasting a
`gamebanana.com/dl/<fileid>` link is an obvious thing to want to support:

- `File/<id>` — no mod field of any kind.
- `File/Multi?_csvRowIds=…&_csvProperties=…` — accepts only `_idRow`,
  `_sModelName` and `_sProfileUrl`. `_aSubmission`, `_aMod`, `_idModRow`,
  `_aOwner` are all `UNKNOWN_PROPERTY`.
- `File/<id>/ProfilePage` — `200`, a burst of PHP warnings, and a three-field
  stub: `{_idRow, _nStatus, _bIsPrivate}`. A body, just a useless one — don't
  re-probe it expecting a 500.
- `_sProfileUrl` on a File comes back as the broken
  `https://gamebanana.com//<id>` — the section prefix is missing, so it is not
  a link to anything.
- The legacy Core API's self-describing `Data/AllowedFields?itemtype=File` lists
  nothing better; its `sModManagerDownloadUrl()` is just
  `gamebanana.com/mmdl/<id>`, another file-id url.

So `/dl/<fileid>` → mod is a dead end on both APIs. A file link is only useful
**once the mod is already known**, where the id picks a row out of that mod's
`_aFiles`/`_aArchivedFiles`. Anything that accepts a pasted url has to say so
rather than searching for the url as though it were a mod name.

### `_sVersion` and `_sDescription` are not reliably version-vs-variant

The table above describes what the two fields *mean*. What authors actually do with
them is looser, and anything that compares versions has to be built for the looser
reality. Measured across the captured profiles and a live one:

- **`_sVersion` is frequently null — including on *every* file of a mod.** One captured
  profile publishes ten current files, all with `_sVersion: null`, whose
  `_sDescription` values are `"v3.4"`, `"v3.3"`, `"v3.2"` … The version is there; it is
  just in the field nominally reserved for the variant label.
- **So `_sDescription` cannot be read as "variant" on its own.** In the same corpus it
  holds a genuine variant marker (`"Full Mod"`), a role marker
  (`"RabbitFX Fixer EXE Version"`, `"Glow demo"`), *and* a version (`"v3.4"`) — with
  nothing in the response distinguishing the three.
- **A mod's current files are often not one release.** Another captured profile offers,
  simultaneously: a `"Main file"` at 7.7, two patcher utilities at 1.0, and three
  unversioned demo archives. "The newest file" and "the highest version" are both wrong
  answers to "what should I install" there.

Two consequences, and they are the reason this section exists:

- **Do not order files by version string.** There is no ordering to take a maximum over
  — the strings are free-form, absent, or in the other field. Upload date is not a
  substitute: it picks the demo whenever a demo was uploaded last.
- **Never auto-select a file when a mod publishes more than one.** There is no field
  combination that reliably identifies "the main one", so the choice belongs to the
  user.

Two further consequences worth internalising:

- **Always look at `_aArchivedFiles` too.** An old local install matches a superseded
  file far more often than the current one, so ignoring it throws away the best
  chance of identifying what a user actually has. Note the key is **absent** rather
  than `[]` when there is nothing archived, so "no archived files" and "didn't ask for
  archived files" are distinguishable — and must be distinguished, or an update check
  concludes a mod has no files from a response it never asked.
- **`_sMd5Checksum` is a matching key, not a trust signal.** It identifies *which*
  file something is; it doesn't make it safe. md5 is cryptographically broken. If you
  want to show the user a safety indicator, show `_sAvResult` — that one actually
  means something. Never render an md5 match as "✓ verified" or attach a shield icon
  to it; the honest phrasing is "byte-identical to file X on the mod page". If real
  integrity checking is ever wanted, add sha256 alongside rather than reinterpreting
  this field.

---

## 7. NSFW and content ratings

**Adult content is not hidden from the API.** Anonymous callers get NSFW mods in
listings, get their full `ProfilePage`, and can download their files. There is
nothing to log into and no filter parameter — GameBanana ships a *rendering hint* and
expects the client to honour it:

| Field | Values |
|---|---|
| `_sInitialVisibility` | `show` — render normally · `warn` — render behind a warning · `hide` — don't show unless asked |
| `_bHasContentRatings` | quick boolean in listing records |
| `_aContentRatings` | map of reasons, e.g. `{"sc":"Sexual Content","nu":"Full Nudity","sa":"Skimpy Attire","pn":"Partial Nudity","st":"Sexual Themes"}` |
| `_sFile220Sfw` | **new in apiv13** — a server-rendered *pixelated* copy of the cover, inside `_aPreviewContent` ([§5](#images)) |

### `_sFile220Sfw` — GameBanana now censors the image for you

The blog post announcing apiv13 lists it as "content-warning overlays and pixelation
for mature content in previews", and it is real: same dimensions as the normal
thumbnail (220×137 on the sample checked), heavily mosaiced, **2.8 KB against
12.3 KB**.

Measured over 150 listing covers, it appears on **exactly** the records whose
`_sInitialVisibility` is `hide` (30) or `warn` (7) — 88 of 150 — and on none of the
`show` ones. Two limits matter before building on it:

- **Only the 220 rung has an SFW twin.** Nothing at 100, 530 or the original, across
  388 rungs sampled. So it can stand in for a client-side blur on a grid card and
  nowhere else.
- It is a *substitute image*, not a flag: using it means the explicit pixels are
  never downloaded until the user asks, which is the real argument for it.

**This app does not use it** — `GbThumbnail` applies its own blur, so the field is
parsed by nothing and `GbImage` deliberately ignores `_sFileNNNSfw` keys. Recorded
here because the omission is a decision, not an oversight.

So the filter is **ours to implement**, client-side, on every listing we render. For
ZZZ specifically this is not an edge case: in a sample of 45 recent submissions, 25
carried content ratings, and a live 6-record `Mod/Index` page returned three `show`,
one `warn` and two `hide`.

Three properties of the hint that shape any client-side filter:

- **`_sInitialVisibility` is on listing records**, not just profiles, so a listing can be
  filtered with no extra request.
- **`_aContentRatings` is not** ([§5](#5-the-mod-object)). A listing knows *that* a mod
  is flagged (`_bHasContentRatings`) but not *why*, so only a detail view can name
  "Skimpy Attire".
- **An absent `_sInitialVisibility` should be treated as `warn`, not `show`.** The field
  is present on every record observed so far, but failing the other way means the day it
  disappears upstream, adult content silently un-blurs.

Since the API returns flagged mods regardless, any filter necessarily runs on
already-fetched records — so `_nRecordCount` and the page count describe the **remote**
result set, not what survives filtering. A page can legitimately render fewer items than
the pager implies.

---

## 8. Downloading a file

`_sDownloadUrl` works with no session, no referer and no cookies:

```
GET https://gamebanana.com/dl/1770600
  → 302  https://files.gamebanana.com/mods/remielleswimlite.rar
  → 302  https://filecacheNN.gamebanana.com/mods/remielleswimlite.rar
  → 200/206  application/x-rar-compressed
```

- **Follow redirects** (two hops, cross-host) — a client that doesn't will get an
  empty 302 body. Dart's `HttpClient` does this by default
  (`response.redirects.length == 2`); no manual handling needed.
- The final filename comes from `_sFile`. There is **no `Content-Disposition`**
  header, so don't expect to learn it from the response.
- `HEAD` works on `/dl/<id>` and returns the full header set, so you can preflight
  size and existence without transferring anything.
- Archived files download the same way — `/dl/<archived file id>` works.
- 8 concurrent download starts all returned `206` with no throttling.

### How big do files actually get?

Sampled 694 files across 238 ZZZ mods (2026-08-01):

| median | p75 | p90 | p95 | p99 | max |
|---|---|---|---|---|---|
| 21.9 MB | 42.8 MB | 95.7 MB | 150.1 MB | 358.9 MB | **1244.7 MB** |

9.5% exceed 100 MB, 1.4% exceed 250 MB, and two files in the sample exceed 1 GB.
So the common case is small and quick, but the tail is long enough that a download
**cannot** be treated as a short operation. Dart handles >1 GB fine —
`contentLength` is a 64-bit int and reported `1244723883` correctly.

### Resume works, and it works from the `/dl/` link

This is the important one, because it means we never have to persist a resolved
CDN url.

- **`Range` survives both redirect hops.** Sending `Range: bytes=N-` to
  `gamebanana.com/dl/<id>` yields `206 Partial Content` from the filecache node
  with a correct `Content-Range: bytes N-M/total`. Resume by re-requesting the
  *original* `/dl/` link with a `Range` header.
- Open-ended (`bytes=N-`) and bounded (`bytes=N-M`) ranges both work. A range past
  EOF returns **`416`** with `Content-Range: bytes */<total>`.
- **`ETag` is stable and safe for `If-Range`.** It's nginx's
  `hex(mtime)-hex(size)` (`"6a6d2f6d-271697ec"` ⇒ size `655792108`) and is
  **identical across filecache nodes**, so a resume that lands on a different node
  won't spuriously restart. `Last-Modified` matches across nodes too.
- Verified end to end twice on a 655 MB file: three interruptions via `curl -C -`
  produced a file **byte-identical** to an uninterrupted download, and four
  interruptions through Dart's `HttpClient` produced an md5 equal to the published
  `_sMd5Checksum`. Resuming costs no throughput (17–20 MB/s across every pass).

The md5 can be computed **in-stream while downloading**, at no measurable cost to
throughput, and it matched the published `_sMd5Checksum` on every run. That matters
because the archive is normally deleted once extracted: the hash is the only residue
that survives, it cannot be reconstructed from the extracted files afterwards, and it
is what later lets you say *which* file on the mod page a local install came from.
So hash on the way past — there is no second chance.

### Throughput is per-node, and some nodes are badly degraded

The single biggest surprise of the measurement, and it shapes the whole retry design.

> **Every figure in this section was measured with a standalone `dart run`
> script, never through the app.** That distinction is not pedantry — it is where
> a real bug hid for a whole release. These numbers describe what the *network*
> will give you; what the *downloader* delivered was capped at ~3 MB/s by the
> isolate it ran on, entirely independently of anything here. If you are
> comparing an in-app rate against a number below, you are comparing two
> different things. See `mod_manager_flutter/CLAUDE.md` § "The download layer".
>
> **Treat these as samples, not as a node's settled property.** A later session
> watched the node serving one file swing **2.4 → 26 MB/s within ten minutes**,
> which is wider than the gap between "healthy" and "degraded" claimed below. The
> deterministic-assignment finding may well still hold — the retry design rests
> on it — but it rests on one session's sampling, and a second session could not
> reproduce the stability.

- A healthy node serves at **14–22 MB/s** (655 MB in ~35 s).
- `filecache43` served at **0.83 MB/s**, degrading to **~0.08 MB/s** over the same
  hour — 20–200× slower. It was slow for *every* file it served, including one that
  streams at 10 MB/s from `filecache30`/`filecache38`. So it's the **node**, not the
  file, and not our client.
- **Node assignment is deterministic per filename** — 10/10 samples for a given file
  resolved to the same node, and different files resolve to different nodes.
  **Therefore a retry cannot escape a degraded node.** Reconnecting to the same
  `/dl/` link lands you on the same slow machine every time.
- Opening 4 parallel range connections recovered only ~2 MB/s in total, so the limit
  is not per-connection and multi-part downloading doesn't rescue it.

What that means for anything downloading from here:

- **A total-duration timeout is always wrong.** The 1.24 GB file over a degraded node
  needs ~25 minutes at best, and got worse while being measured. Any fixed ceiling
  would cancel legitimate downloads; only a **stall timeout** — N seconds with *zero*
  bytes received — distinguishes a dead transfer from a slow one.
- **Retrying cannot route around a bad node, but it can catch a better moment on
  it.** Node choice really is deterministic per filename — mod `704111` resolved to
  `filecache31` on every sample — so a retry always lands on the same machine. What
  it does *not* mean is that the answer will be the same: that node served the same
  file at **~0.6 MB/s through the app one minute and ~12 MB/s the next**, with `curl`
  from outside the app measuring 10.35 and 12.14 MB/s across the same window. So a
  slow transfer is worth retrying later even though it cannot be rerouted, and a
  single slow download is **not** evidence of anything about the client. Resume from
  the current offset regardless — it costs nothing and it is what makes the retry
  cheap.
- *(Observation, not a recommendation: the same file fetched directly from another
  `filecacheNN` host is fast. Hard-coding node numbers is undocumented, discourteous
  and will break — don't build on it. Recorded only so the cause isn't
  re-investigated.)*

Our downloader's side of this — the stall timeout, resume policy, socket
backpressure, and why the transfer runs on a spawned isolate — is in
[`../mod_manager_flutter/CLAUDE.md`](../mod_manager_flutter/CLAUDE.md).

---

## 9. Sections and categories (how to build a filter tree)

`Game/<id>/ProfilePage` is the root of all navigation.

**`_aSections`** — the site areas for that game (`Mod`, `Sound`, `Wip`, `Thread`,
`Blog`, `Concept`, `Poll`, `Project`, `Question`, `Contest`, …), each with
`_sModelName`, `_nItemCount`, `_nCategoryCount`, `_sUrl`. We only care about `Mod`,
but this is how you'd discover the rest.

**`_aModRootCategories`** — the top-level mod categories. For ZZZ (2026-08-01):

| Id | Name | Items | Subcategories |
|---|---|---|---|
| `30305` | Character Skins | 4589 | 60 |
| `30702` | Bangboo Skins | 46 | 22 |
| `29874` | Other/Misc | 259 | 1 |
| `30395` | UI | 253 | 1 |

Drill into one for its children:

```bash
curl 'https://gamebanana.com/apiv13/Mod/Categories?_idCategoryRow=30305&_sSort=a_to_z&_nPerpage=50'
```

This returns a **bare array** (no `_aMetadata`) of `_idRow`, `_sName`, `_nItemCount`,
`_nCategoryCount`, `_sUrl`, `_sIconUrl`, `_bIsObsolete`.

For ZZZ, the 60 children of *Character Skins* **are the character roster** — "Ellen
Joe" (`30341`), "Hoshimi Miyabi" (`30579`), "Anby Demara" (`30336`) and so on, each
with a live mod count. That makes it the natural backing for a character filter, and
a cross-check against our hardcoded roster in `utils/zzz_characters.dart`. Fetch it at
runtime and cache it — new characters appear with every game patch, and a hardcoded
copy is exactly what goes stale. (Confirmed live: still exactly 60 children.)

> **A local list of character *names* cannot drive this filter.** `Generic_Category`
> accepts a category id and nothing else — `Generic_Name` exists but rejects plain
> strings ([§4](#4-sorting-and-filtering)). So filtering by character requires the ids
> from this endpoint; a name list can only produce filter values the API refuses.
> Filtering offline therefore means **persisting the fetched id↔name mapping**, not
> keeping a static roster.

---

## 10. The legacy Core API

Documented at <https://api.gamebanana.com/>. Weaker for browsing (3 sorts, 1 filter),
but genuinely useful for two things.

**It describes itself.** These endpoints answer "what can I ask for?" — for *this*
API, which is the important caveat. apiv13 has no equivalent, and the two surfaces do
not overlap: `AllowedSorts` here returns `["id", "name", "udate"]` while apiv13
accepts seven `Generic_*` aliases that appear in no such list, and `AllowedFilters`
returns only `["userid"]` against apiv13's three filters. So this is a useful
cross-check and a weak one — do **not** read an absence here as proof of absence in
apiv13 ([§4](#4-sorting-and-filtering) flags exactly that trap).

```bash
curl 'https://api.gamebanana.com/Core/Item/Data/AllowedItemTypes'
curl 'https://api.gamebanana.com/Core/Item/Data/AllowedFields?itemtype=Mod'   # 56 fields
curl 'https://api.gamebanana.com/Core/List/Section/AllowedSorts?itemtype=Mod'
curl 'https://api.gamebanana.com/Core/List/Section/AllowedFilters?itemtype=Mod'
```

**It's a field-picker**, so you can fetch exactly one thing:

```bash
curl 'https://api.gamebanana.com/Core/Item/Data?itemtype=Mod&itemid=698834\
&fields=name,Files().aFiles(),Nsfw().bIsNsfw()&format=json_min'
```

Notes: results come back as a **positional array matching your `fields` order** (not
an object), method-style fields end in `()`, and `Files().aFiles()` returns the same
file objects as apiv13 — md5 included — but **keyed by file id** rather than as a
list. `Nsfw().bIsNsfw()` is a plain boolean, which is occasionally handier than
interpreting `_sInitialVisibility`.

Other bits it offers: `Core/List/New` (newest submissions), `Core/Member/Identify`,
`Core/Item/IdentifyById`, and RSS feeds under `Rss/`.

---

## 11. Gotchas

Collected so nobody rediscovers them:

- **Unrecognised top-level parameters are silently ignored, not rejected.** This is
  the most dangerous gotcha here, because it makes a *successful* response look like
  confirmation. `_sPeriod`, `_nPeriod`, `_sTimePeriod`, `_sRange` and `_sDateRange`
  all returned `200` on `Mod/Index` with byte-identical results — the parameters do
  not exist. Only `_aFilters[…]` keys are validated (`UNKNOWN_FILTER`), and only
  `_sSort` values (`UNKNOWN_SORT`). **Never conclude a parameter works because the
  request succeeded** — change it and check the results actually differ.
  (Re-confirmed on apiv13: two junk params produced a byte-identical body, while a
  junk `_aFilters` key still errored.)
- **`_nPerpage` limits differ per endpoint** — 50 on `Index`/`Subfeed` (hard error
  above), **15 on Search, silently**. Always read `_aMetadata._nPerpage` back. Some
  endpoints (`TopSubs`) ignore it entirely.
- **`Generic_Newest` sorts by *submission* date, so actively-updated mods sink.** And
  the site's default "ripe" order is not available on either API, so a client's
  listing cannot match what the user sees on gamebanana.com
  ([§4](#4-sorting-and-filtering)).
- **`Mod/Categories` fails without `_sSort`**, because its internal default is a value
  it rejects. Send `a_to_z` or `count`.
- **`_csvProperties` only works on `Multi`.** `Index` ignores it.
- **Search takes `_idGameRow`; `Index` takes `_aFilters[Generic_Game]`.** Same idea,
  different spelling, no overlap.
- **Some endpoints return a bare array** (`Multi`, `Mod/Categories`) instead of the
  `_aMetadata`/`_aRecords` envelope. Don't write one generic response parser and
  assume it fits all.
- **Listing records omit `_nDownloadCount` and `_aContentRatings`.** Both are
  profile-only, so a card can neither show a download count nor explain *why* a mod is
  flagged ([§5](#5-the-mod-object)).
- **`_aPreviewContent` has two container spellings**: `screenshots` (array) on a
  profile, `screenshot` (single object) on every listing. Reading one key gives an
  *empty gallery*, not an error, so this fails silently ([§5](#images)).
- **A listing carries only the cover on apiv13** — 50 images across 50 records, where
  apiv11 sent 420. The gallery is profile-only now.
- **apiv13 sends no `cache-control`.** apiv11 sent `max-age=600`. A client TTL is now
  the client's own invention ([§2](#caching-and-rate-limits)).
- **An unknown *route* returns `200` + HTML on apiv13**, not `404` + `NO_SUCH_ROUTE`
  JSON, so it reaches a JSON client as a parse error. A missing *mod id* is
  unchanged (`404` + `NO_SUCH_RECORD`) ([§2](#errors)).
- **Never fabricate a variant filename.** apiv13 names thumbnails by a hash unrelated
  to `_sFile`, so a variant that wasn't published cannot be constructed — and the
  ladder is not uniform: covers carry 220/530, secondary images only 100
  ([§5](#images)).
- **`_sFileNNNSfw` is a censored *substitute*, not another size.** A key-scanning
  variant parser that accepts it will serve the pixelated image to users who asked to
  see everything ([§7](#7-nsfw-and-content-ratings)).
- **"Category" has three key names** and no response carries more than two; only the
  profile's `_aCategory` has an `_idRow`, and a listing hides the id inside
  `_sProfileUrl` ([§5](#three-spellings-of-category)).
- **`_sVersion` is often null on every file of a mod, with the version written into
  `_sDescription`** — the field that otherwise means "variant". Never sort files by
  version string, and never auto-pick among several files
  ([§6](#6-files--_afiles-and-_aarchivedfiles)).
- **`_aPreviewMedia` and `_sType` no longer exist**, and `_wFileNNN` is gone with
  them. Code written against apiv11's image shape reads an apiv13 response as having
  *no images at all* rather than failing ([§5](#images)).
- **`_aArchivedFiles` is absent rather than `[]`** when nothing is archived, so null
  ("not requested") and empty ("none exist") are both real and mean different things.
- **A file id does not lead back to its mod.** `File/<id>` returns the whole file
  record and no owner, `File/Multi` recognises no mod-shaped property, and a File's
  `_sProfileUrl` is the broken `gamebanana.com//<id>`. A pasted `/dl/` link is only
  resolvable once you already know the mod
  ([§6](#a-file-id-cannot-be-turned-back-into-a-mod-id)).
- **`_sText` is HTML**, while our own sidecar descriptions are markdown. Convert on
  import; don't dump raw HTML into a markdown widget.
- **`_aTags` is strings on a listing and `{_sTitle, _sValue}` objects on a profile.**
  A parser that handles only the string form returns a profile's tags as *empty*
  rather than throwing, which is invisible until someone counts
  ([§5](#_atags-has-two-shapes)).
- **`_ts…` of `0` means never.** `_nStatus` is a string.
- **A root-category filter includes subcategories**, so counts won't exactly match
  `_nItemCount` (4591 vs 4589 for ZZZ Character Skins — close, not equal).
- **Download speed is a property of the CDN node, not of your connection.** Node
  choice is deterministic per filename, so a slow file stays slow however often you
  retry. Don't read a 0.8 MB/s transfer as a bug in the client
  ([§8](#8-downloading-a-file)).
- **No `Content-Disposition` on downloads.** The filename only exists in `_sFile`.
- **Errors never list valid values.** If something is "not recognized", consult
  [§4](#4-sorting-and-filtering) rather than guessing; the guess-rate is low.
- **No `/apidocs` for apiv13.** The surface is discoverable only by probing, which is
  a standing argument for keeping our client's surface small: every endpoint and field
  we depend on is one more thing that can change without warning.

### Re-verifying this document

Every claim above came from a `curl` against the live API. To re-check after an API
change, the highest-value probes are: a bogus `_sSort` and a bogus `_aFilters[…]` key
(confirms the error shape), `_nPerpage=100` (confirms the cap), one
`Mod/<id>/ProfilePage` (confirms field names), and a ranged `GET` on a `/dl/` link
(confirms downloads are still open and resumable):

```bash
# resume still works? expect: 206 + "content-range: bytes 1000-.../<total>"
curl -sSI -L -r 1000-2000 'https://gamebanana.com/dl/1770254' \
  -H 'User-Agent: zzz-mod-manager/2.0' | grep -Ei 'HTTP/|content-range|etag'
```

**Add one probe for the version itself**, since a new one arrives with no
announcement beyond a blog post — walk the numbers until a `404` marks the ceiling,
then diff the top-level keys of one `ProfilePage` against the version below it. That
is exactly how the v11 → v13 difference was found, and it is two commands:

```bash
for v in 13 14 15; do
  printf 'apiv%s ' "$v"
  curl -so /dev/null -w '%{http_code}\n' "https://gamebanana.com/apiv$v/Mod/698834/ProfilePage"
done
# then, for two versions that both answered 200:
diff <(curl -s https://gamebanana.com/apiv11/Mod/698834/ProfilePage | python3 -c 'import json,sys;print("\n".join(sorted(json.load(sys.stdin))))') \
     <(curl -s https://gamebanana.com/apiv13/Mod/698834/ProfilePage | python3 -c 'import json,sys;print("\n".join(sorted(json.load(sys.stdin))))')
```

The download numbers in [§8](#8-downloading-a-file) are the perishable ones — node
health changes, and the size distribution drifts as mods are uploaded. The
*structural* claims (range support, redirect count, ETag stability, deterministic
node assignment) are the ones worth re-testing before trusting §8 again.
