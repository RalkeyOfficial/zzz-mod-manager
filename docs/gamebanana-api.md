# GameBanana API

Practical reference for talking to GameBanana from this app: which of the two APIs
to use, how to browse and filter, what every field we care about means, and where it
will bite you.

**Everything here was verified against the live API on 2026-08-01**, anonymously,
with no cookies and no account. Requests are plain `GET`s that return JSON. Examples
use the ZZZ game id **`19567`**; a real mod (`698834`) and file (`1770600`) are used
so you can paste any of them into a terminal.

> This documents the *remote* API only. How we store what comes back is
> [`metadata-schema.md`](metadata-schema.md).

---

## 1. There are two APIs. Use apiv11.

| | **apiv11** | **Core API (legacy)** |
|---|---|---|
| Base | `https://gamebanana.com/apiv11` | `https://api.gamebanana.com` |
| Documented? | **No** — no `/apidocs` page exists | **Yes**, at <https://api.gamebanana.com/> (and self-describing, see [§10](#10-the-legacy-core-api)) |
| Who uses it | GameBanana's own site | Third-party apps, older tooling |
| Filtering | Rich (`_aFilters`, 7 sort aliases) | Almost none — 3 sorts, 1 filter |
| Shape | Purpose-built responses (`ProfilePage`, `DownloadPage`) | Field-picker (`?fields=a,b,c`) |

**Use apiv11 for everything.** It returns whole screens in one request, it's what the
website itself calls (so it won't rot quietly), and the legacy API's filtering is too
weak to build a browser on. The tradeoff — being undocumented — is why this file
exists.

The Core API is still worth knowing for two things: it's *self-describing* (it can
enumerate its own allowed fields and sorts), and it exposes a couple of things
apiv11 doesn't name as plainly. See [§10](#10-the-legacy-core-api).

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
| `_h…` / `_w…` | pixel height / width | `_hFile220`, `_wFile220` |

Two exceptions that will trip you up: **`_nStatus` is a string** (`"0"`), and a
`_ts…` of **`0` means "never"**, not 1970 — treat it as null.

### Request parameters

Query params only. Array params use PHP bracket syntax and **must be URL-encoded**:

```bash
# _aFilters[Generic_Game]=19567
curl 'https://gamebanana.com/apiv11/Mod/Index?_aFilters%5BGeneric_Game%5D=19567&_nPerpage=5'
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

Codes seen: `NO_SUCH_ROUTE` (404), `INPUT_ERRORS` (400) with a per-parameter
breakdown, `UNKNOWN_FILTER`, `INVALID_FILTER_VALUE`, `UNKNOWN_SORT`,
`VALUE_NOT_ALLOWED`, `INVALID_PERPAGE`. Errors **do not enumerate the valid values**
— "not recognized" is all you get, which is why [§4](#4-sorting-and-filtering)
lists them explicitly.

### Caching and rate limits

- Responses carry `cache-control: public, max-age=600`. **Mirror that 10-minute TTL**
  in our own cache rather than inventing one.
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
| `GET /apiv11/Game/<gameId>/ProfilePage` | Game info + **its sections and mod root categories** |
| `GET /apiv11/Mod/Categories?_idGameRow=<id>&_sSort=…` | Root categories for a game |
| `GET /apiv11/Mod/Categories?_idCategoryRow=<id>&_sSort=…` | **Subcategories** of a category |
| `GET /apiv11/Mod/Index?_aFilters[…]&_sSort=…` | Filtered, sorted mod list — the browse workhorse |
| `GET /apiv11/Game/<gameId>/Subfeed` | The game's activity feed (newest-ish, unfiltered) |
| `GET /apiv11/Util/Search/Results?_sModelName=Mod&_sSearchString=…` | Text search |
| `GET /apiv11/Mod/<id>/ProfilePage` | Everything for a mod detail screen, in one call |
| `GET /apiv11/Mod/<id>/DownloadPage` | Just the file lists — cheap, for update checks |
| `GET /apiv11/Mod/<id>/Updates` | The author's changelog entries |
| `GET /apiv11/Mod/Multi?_csvRowIds=…&_csvProperties=…` | **Many mods, chosen fields, one request** |

### Browsing — `Mod/Index`

The one to build the results grid on. Filter, sort and page:

```bash
# UI mods for ZZZ, most liked first
curl 'https://gamebanana.com/apiv11/Mod/Index?_aFilters%5BGeneric_Game%5D=19567\
&_aFilters%5BGeneric_Category%5D=30395&_sSort=Generic_MostLiked&_nPerpage=20&_nPage=1'
```

Records are the **compact mod shape** ([§5](#5-the-mod-object)) — enough for a card,
not enough for a detail view.

### `Subfeed` vs `Index`

`Game/<id>/Subfeed` is the site's activity feed: no filters, no sort control. Fine for
a "what's new" strip; use `Index` for anything the user controls.

### Search — `Util/Search/Results`

```bash
curl 'https://gamebanana.com/apiv11/Util/Search/Results?_sModelName=Mod\
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
_tsDateAdded _tsDateModified _tsDateUpdated
_aGame _aCategory _aSuperCategory _aSubmitter _aTags _aCredits _aContributingStudios
_aPreviewMedia _aFiles _aArchivedFiles _aEmbeddables _aLicenseChecklist
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

### Changelogs — `Mod/<id>/Updates`

Paginated author update posts: `_idRow`, `_sName` (title), `_tsDateAdded`,
`_sProfileUrl`, and the body in `_aPreviewMedia._aMetadata._sSnippet`. This is the
changelog to show before updating — no scraping needed.

### Bulk — `Mod/Multi`

The most useful non-obvious endpoint. Fetch many mods at once **and pick the fields**:

```bash
curl 'https://gamebanana.com/apiv11/Mod/Multi?_csvRowIds=698834,605830\
&_csvProperties=_idRow,_sName,_sVersion,_tsDateUpdated,_aFiles,_bIsObsolete'
```

Returns a bare **array** (no `_aMetadata` wrapper) in the requested order. Two things
to know:

- `_csvProperties` is honoured **here but ignored by `Index`** — don't expect it to
  trim listing payloads.
- This is how a bulk "check all mods for updates" pass should be built: batches of
  ids in a handful of requests instead of one request per mod.

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
| `_tsDateUpdated` | both | Last content update — the comparator for "is there something new". |
| `_tsDateModified` | both | Last *any* edit (including trivial ones). Noisier than `_tsDateUpdated`. |
| `_aSubmitter` | both | `_idRow`, `_sName`, `_sProfileUrl`, `_sAvatarUrl`. |
| `_aRootCategory` / `_aCategory` | list / profile | Category, with `_sName`, `_sProfileUrl`, `_sIconUrl`. |
| `_aTags` | both | Author tags. Often empty — don't rely on it for character detection. |
| `_aPreviewMedia._aImages[]` | both | Gallery. See below. |
| `_nLikeCount`, `_nViewCount`, `_nDownloadCount`, `_nPostCount` | both | Stats for the card. |
| `_bHasFiles` | list | Whether anything is downloadable. |
| `_bIsObsolete` | both | Author flagged it superseded — **not** the same as gone. |
| `_bIsPrivate`, `_bIsTrashed`, `_bIsWithheld` | profile | Upstream removal states. Read these instead of inferring from a 404. |
| `_bHasUpdates`, `_nUpdatesCount` | profile | Whether `Mod/<id>/Updates` has anything. |
| `_sInitialVisibility`, `_aContentRatings` | both | Content gating hints — [§7](#7-nsfw-and-content-ratings). |

### Images

`_aPreviewMedia._aImages[]` gives a base url plus pre-rendered sizes; join them
yourself:

```
_sBaseUrl  = https://images.gamebanana.com/img/ss/mods
_sFile     = 6693f0120d40f.jpg          → full size
_sFile220  = 220-90_6693f0120d40f.jpg   → thumbnail (with _wFile220/_hFile220)
_sFile530  = …   _sFile800 = …
```

Only `_sFile` and `_sFile100` are guaranteed; **the larger variants may be missing**
on any given image, so fall back down the ladder rather than assuming `_sFile530`
exists.

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
| `_bIsArchived` | `true` for entries in `_aArchivedFiles`. |
| `_sAvState` / `_sAvResult` | Virus scan (`done` / `clean`). |
| `_sAnalysisState` / `_sAnalysisResult` / `_sAnalysisResultVerbose` | Preliminary content analysis (`done` / `ok` / human-readable). |

Two consequences worth internalising:

- **Always look at `_aArchivedFiles` too.** An old local install matches a superseded
  file far more often than the current one, so ignoring it throws away the best
  chance of identifying what a user actually has.
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

So the filter is **ours to implement**, client-side, on every listing we render. For
ZZZ specifically this is not an edge case: in a sample of 45 recent submissions, 25
carried content ratings.

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

Consequences for the download manager:

- **Never use a total-duration timeout.** The 1.24 GB file over a degraded node
  needs ~25 minutes at best, and got worse while being measured. Any fixed ceiling
  would cancel legitimate downloads. Use a **stall timeout** — abort only after N
  seconds with *zero* bytes received — and let slow-but-moving transfers run.
- Progress UI has to tolerate hour-long transfers: show a rate and an ETA, not just
  a bar, and keep the download cancellable and resumable throughout.
- Since a retry can't route around a bad node, retrying instantly and repeatedly
  achieves nothing. Resume from the current offset and keep going.
- *(Observation, not a recommendation: the same file fetched directly from another
  `filecacheNN` host is fast. Hard-coding node numbers is undocumented, discourteous
  and will break — don't build on it. Recorded only so the cause isn't
  re-investigated.)*

### A note on the client itself

The current inline downloader (`marketplace_screen.dart`, `_downloadToTemporaryFile`)
calls `sink.add(chunk)` without awaiting it and never pauses the subscription, so
nothing throttles the socket when the disk falls behind. In practice this was benign
— writing to local disk at 20 MB/s, peak RSS was identical (217 MB) with and without
backpressure. Forcing a deliberately slow consumer did separate them (+57 MB vs
+15 MB above baseline), so it's a latent risk rather than an observed failure. The
fix is free when the code moves into a service: `sub.pause(sink.addStream(...))`.

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
curl 'https://gamebanana.com/apiv11/Mod/Categories?_idCategoryRow=30305&_sSort=a_to_z&_nPerpage=50'
```

This returns a **bare array** (no `_aMetadata`) of `_idRow`, `_sName`, `_nItemCount`,
`_nCategoryCount`, `_sUrl`, `_sIconUrl`, `_bIsObsolete`.

For ZZZ, the 60 children of *Character Skins* **are the character roster** — "Ellen
Joe" (`30341`), "Hoshimi Miyabi" (`30579`), "Anby Demara" (`30336`) and so on, each
with a live mod count. That makes it the natural backing for a character filter, and
a cross-check against our hardcoded roster in `utils/zzz_characters.dart`. Fetch it at
runtime and cache it — new characters appear with every game patch, and a hardcoded
copy is exactly what goes stale.

---

## 10. The legacy Core API

Documented at <https://api.gamebanana.com/>. Weaker for browsing (3 sorts, 1 filter),
but genuinely useful for two things.

**It describes itself.** These endpoints answer "what can I ask for?" authoritatively,
which is something apiv11 can't do:

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
file objects as apiv11 — md5 included — but **keyed by file id** rather than as a
list. `Nsfw().bIsNsfw()` is a plain boolean, which is occasionally handier than
interpreting `_sInitialVisibility`.

Other bits it offers: `Core/List/New` (newest submissions), `Core/Member/Identify`,
`Core/Item/IdentifyById`, and RSS feeds under `Rss/`.

---

## 11. Gotchas

Collected so nobody rediscovers them:

- **`_nPerpage` limits differ per endpoint** — 50 on `Index`/`Subfeed` (hard error
  above), **15 on Search, silently**. Always read `_aMetadata._nPerpage` back.
- **`Mod/Categories` fails without `_sSort`**, because its internal default is a value
  it rejects. Send `a_to_z` or `count`.
- **`_csvProperties` only works on `Multi`.** `Index` ignores it.
- **Search takes `_idGameRow`; `Index` takes `_aFilters[Generic_Game]`.** Same idea,
  different spelling, no overlap.
- **Some endpoints return a bare array** (`Multi`, `Mod/Categories`) instead of the
  `_aMetadata`/`_aRecords` envelope. Don't write one generic response parser and
  assume it fits all.
- **`_sText` is HTML**, while our own sidecar descriptions are markdown. Convert on
  import; don't dump raw HTML into a markdown widget.
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
- **No `/apidocs` for apiv11.** The surface is discoverable only by probing, which is
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

The download numbers in [§8](#8-downloading-a-file) are the perishable ones — node
health changes, and the size distribution drifts as mods are uploaded. The
*structural* claims (range support, redirect count, ETag stability, deterministic
node assignment) are the ones worth re-testing before trusting §8 again.
