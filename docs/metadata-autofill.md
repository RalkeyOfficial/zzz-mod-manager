# Metadata autofill at install

Reference for what a marketplace install copies from a mod's GameBanana page into the
new mod folder — description, character, tags and gallery — and the rules that keep
it from overwriting something better.

**This documents what the code does today.** Where behaviour is planned but not
implemented, it says so.

> Scope: the autofill pass only. The **shape** of the fields it writes is
> [`metadata-schema.md`](metadata-schema.md#2-metadatajson--the-per-mod-sidecar);
> the identity half of an install — which remote mod and file this is — is
> [`origin-tracking.md`](origin-tracking.md); the remote fields it reads from are
> [`gamebanana-api.md`](gamebanana-api.md#5-the-mod-object).

Related: [`../CLAUDE.md`](../CLAUDE.md) for the service/layer architecture.

---

## Why it exists

A mod installed from the marketplace used to arrive with an `origin` block and
nothing else — no description, no gallery, no tags, no link back to where it came
from, and a character only if its folder name happened to contain one. The mod page
it came from knows all five, and the profile response was already fetched to render
the file list, so four of them cost nothing.
`ModMetadataRepository.applyRemoteMetadata()` writes them, once, right after the
import.

## The units

Two pure units, plus the I/O layer around them — split this way so every judgement is
testable with no filesystem and no network:

| Unit | Owns |
|---|---|
| `services/gamebanana/remote_mod_metadata.dart` | Translating a `GbMod` into `RemoteModMetadata` — *what the page is worth*. Pure. |
| `services/metadata_autofill.dart` | `planMetadataAutofill()` — *what may be written*. Pure. |
| `ModMetadataRepository.applyRemoteMetadata()` | The I/O: fetch, store, save. |

## The one rule: fill absence, never displace

It is not politeness. A mod folder can arrive carrying somebody else's sidecar —
`_copyDirectory` copies `.zzz-mod-manager/` wholesale, and the sidecar format
deliberately *keeps* the user-facing half of an inbound one (only `origin` is
dropped, see [`origin-tracking.md`](origin-tracking.md#2-where-an-origin-comes-from)).
So "this field is already set" routinely means "the author wrote this", and their
text is better than the mod page's copy. Applied per field, so a folder with a
description still gets a gallery.

## What each field is filled from

| Field | Source | Notes |
|---|---|---|
| `description` | `_sText`, converted | HTML upstream, markdown here, through `utils/html_to_markdown.dart` — shared with the editors' paste-as-markdown so the two conversions can't drift. |
| `source_url` | the mod **id** | Not a field on the page. Built with `gameBananaModUrl(idRow)`, so it is the one form `gameBananaModIdFromUrl` parses back. |
| `character_id` | the **category** name | Not the mod name, not the tags. Under Character Skins the category is the character's full in-world name, picked from a list; `detectCharacterId()` resolves it. |
| `tags` | `_aTags`, flattened | All-or-nothing: a non-empty local list is a curation, and merging into it would produce a set nobody chose. |
| `images` | `_aPreviewContent`, fetched | The only field that needs the network, because our `images` are paths inside the mod folder. Comes from the mod's **profile**, which is what carries the full gallery — a listing record holds only the cover. |

Five decisions inside that are load-bearing rather than arbitrary:

- **The source url comes from the identity, not from `_sProfileUrl`.** The page
  publishes its own url and it says the same thing, but the canonical form is what
  the offline backfill's parse returns — so the url and `origin.mod_id` agree by
  construction and the backfill has nothing to revise
  ([`origin-tracking.md`](origin-tracking.md#2-where-an-origin-comes-from)). The two
  fields are kept rather than collapsed because they answer to different readers:
  `mod_id` is the machine handle, `source_url` is the link the user clicks. One
  consequence worth stating, because it looks like an oversight: `RemoteModMetadata`
  is now **never** `isEmpty` for a real mod page, since a page always has an id.
  That is the honest answer — a link back to where a mod came from is worth a
  sidecar on its own — and the cost is one metadata read per installed mod.

- **The character comes from the category because that mapping is exact, and
  measured.** All **60** children of Character Skins resolve to a roster id, and
  **none** of the 4 root categories or the 22 Bangboo categories falsely matches one.
  The install's existing folder-name detection still runs first and still wins — it
  is *per folder*, so when one archive becomes several mods it is the only signal
  that can differ between them — and this fills the case it cannot answer, a folder
  called `bikini` or `mod v2`. A test pins the 60/0 result as a canary: if GameBanana
  adds a character our roster doesn't know, it fails and names it.
- **`Software Used` tags are dropped.** `tags` is *structural* — it drives the filter
  chips in the mods toolbar — so noise there has a UI cost a noisy description does
  not, and this is not a marginal family: 3 of the 6 distinct tag values across the
  captured listings are it.
- **A shipped `Preview.png` keeps the cover slot.** When the gallery is imported, an
  author-shipped preview found at the folder root is written *first*, so nothing
  local is lost or demoted. Rare — 1 of 16 mods in a real library ships one — which
  is exactly why the autofill is worth having. The lookup is
  `utils/shipped_preview.dart`, shared with the scan's own cover fallback so the two
  cannot disagree.
- **Ten images, and the cap is not about bandwidth.** Measured: GameBanana's
  full-size screenshots are web-compressed at ~115–310 KB, so whole galleries of 15
  and 26 images came to 2.3 MB and 5.5 MB against a median mod archive of 21.9 MB.
  The cap is about what a gallery is *for* — the same real library's hand-built
  galleries run 1–7 images (median 3), and a 26-shot marketing gallery copied into
  every mod folder is clutter. Images are stored at full size for the same measured
  reason: only the *cover* publishes a smaller rung at all
  ([`gamebanana-api.md`](gamebanana-api.md#images)).

## Three properties of the I/O half

- **Each image is fetched once, however many mods the archive became.** One archive
  installing as five folders must not mean five downloads of the same screenshot; the
  fetch is a separate pass between planning and writing.
- **It re-reads and re-decides immediately before writing**, for the same reason the
  origin backfill does ([`origin-tracking.md`](origin-tracking.md#3-the-offline-backfill)):
  the fetch is a network await, and a scan runs after every toggle and rename, so a
  user's `save()` can land inside that window.
- **Best-effort, and it never writes an empty sidecar.** A mod arrives installed and
  working, so nothing here may fail an install: an unreachable image is skipped, and
  if *nothing* survives (every image failed and nothing else was missing) no file is
  written at all — the don't-litter rule
  ([`metadata-schema.md`](metadata-schema.md#dont-litter-empty-sidecars)) holds.

Measured end to end against the live API: profile fetch 366 ms, then 827 ms to fill
**two** sibling mods with the same 8-image gallery — 8 downloads, 16 files, 882 KB
per folder.

The bytes seam is `services/http/image_fetcher.dart`, deliberately separate from
`HttpTransport` (whose body is a decoded `String` because everything above it is
JSON) and from the file downloader (which earns its ranges and resume on
hundred-megabyte archives).

## How it reaches the sidecar

`applyRemoteMetadata()` writes through `ModMetadata.replaceUserFields()`, the same
method a user's `save()` goes through, with no `ModInfo` in sight — passing the
existing value for every field it is not filling. That is the save design working as
intended: a user-editable field is replaced wholesale by *whoever* writes, so the way
to leave one alone is to hand back what was already there, never to omit it. See
[`metadata-schema.md`](metadata-schema.md#save-semantics-three-classes-of-field).
