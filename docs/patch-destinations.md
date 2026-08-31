# Patch destinations

**Which mod folder a patch is installed into, and how the app orders that
choice.** One question, asked once, at the moment an install finds a patch: the
prompt in `patch_install_prompt.dart` offers *its own folder* or *into a mod you
already have*, and the second answer needs a folder picked out of the whole
library.

Not in scope: how the app **decides** a download is a patch
([`applying-updates.md`](applying-updates.md) §2 — the two rules), where the
files **land** inside the folder once chosen (`patch_placement.dart`, same doc
§1), and what gets **recorded** afterwards
([`origin-tracking.md`](origin-tracking.md) §10).

---

## 1. The problem

The list is the library — 71 folders on the machine this was measured on, and
they are not evenly distributed: 16 are Remielle mods, 10 Yidhari, 10 Ye
Shunguang. The user knows which mod they mean. Finding it by reading folder names
is the cost, and the covers in the rows only help once the right row is on
screen.

So the folders that plausibly answer should be first. What makes this delicate is
that the failure is invisible: a picker that confidently ranks the wrong folder
first, on a question the user has to answer *before* anything is written, is
worse than a picker that ranks nothing.

## 2. The signals, and what each is worth

### The filename fingerprint

A patch names the files it replaces. An `.ini` patch ships no content, so what it
names is what its `.ini` files **reference**; an asset patch ships no `.ini`, so
what it names is the **assets it carries**. Either way, a folder holding those
names is a candidate — matched on basename, never path, because the author ships
files bare and has no idea what layout the folder ended up with.

Measured over the real 71-folder library, with the patch derived from each mod in
turn (§4):

| | `.ini` patch (67 cases) | asset patch (68 cases) |
|---|---|---|
| right folder **alone** at the top | 61 (91%) | 56 (82%) |
| right folder in the top tie | 64 | 68 (never below) |
| right folder within worst-case rank 3 | 67 (all) | 64 |
| top-tie size | median 1, worst 2 | median 1, worst 8 |

It works because ZZZ filenames are specific: assets come out of the extraction
tools as `<character><component><maptype>.<ext>`, so `EllenHairADiffuse.dds` is a
real discriminator in a way `body.dds` would not be. The three `.ini` misses are
all near-siblings of one mod — two variants of the same release, 96% against 97%.

### The author's own requirement

A mod page may declare what it needs (`_aRequirements` — see
[`gamebanana-api.md`](gamebanana-api.md)), and for a patch that is sometimes the
mod being patched, stated by the person who would know. Mod 605460 names
*Pulchra - Bottom Heavy* with its mod id in the url.

**High precision, low coverage, and not always the base mod:**

| Population | Declares any requirement | Links a GameBanana mod |
|---|---|---|
| 100 recently-modified ZZZ mods | 16% | 6%, every one a shader tool |
| 68 patch-sized ZZZ mods (≤ 12 MB) | 18% | 9% — four of six named the mod being patched, two a shared normal-map fix |

So it leads the order, and it is worded as the author's claim rather than as a
finding. It answers only for a library folder whose **recorded origin** is the mod
the author linked; an untracked folder cannot match one, because nothing on it
says what it is.

### The character — measured, and not used

It reads like an independent signal. It is not: in **every** measured case the
folders tied at the top already shared the subject's character, so narrowing to
the character removes nothing the fingerprint kept (median tie 1, worst 2 and 8 —
identical before and after). The fingerprint's ambiguity is always *within* one
character, which is the same thing said twice.

Its only remaining value is where the fingerprint is empty, and there the library
is already in its plain order. Coverage would also have to be handled: 56 of 71
folders carry a character tag, and a hand-dragged patch has no mod page and
therefore no character at all.

## 3. The rule: rank, never shorten, never preselect

Measure the case where the patch's real target is **not installed** — finding a
patch before the mod it patches is an ordinary way round. With the subject
removed from its own library, the best wrong folder still scores:

- **100%** in 3 of 67 `.ini` cases and **12 of 68** asset cases
- 90%+ in 8 and 12 respectively
- under 50% in 44 of each

A perfect score is therefore not evidence the right answer is in the list at all.
This settles the whole design:

- **the order changes; the list does not.** Every folder stays in it, including
  the ones matching nothing — that is what the user picks when they know better
  than the files do. There is no threshold and no filter.
- **nothing is preselected**, and the confirm button stays disabled until a folder
  is actually chosen. A preselected top row would be a wrong answer nobody looked
  at.
- **a row that is up there says why, once**, in the terms of what was observed —
  "Holds 2 of the 3 files this patch replaces", "The patch's author lists this mod
  as required" — never as a verdict about the folder. Rows with nothing going for
  them say nothing, so the reason means "this is why this row is here" rather than
  decorating every row alike.

A narrowing control, if one is ever added, is a visible toggle the user can switch
off — never the default state of the list.

## 4. How to re-derive any of this

**The library measurement** is `test/patch_destination_corpus_test.dart`, skipped
unless pointed at a real library:

```bash
ZZZ_LIBRARY=~/XXMI\ Launcher/ZZMI/_Mods \
ZZZ_CHARACTER_TAGS=~/.local/share/zzz-mod-manager/config.json \
  flutter test test/patch_destination_corpus_test.dart
```

It prints a line per case and the aggregates above. There is no corpus of real
patches paired with the mod each one patches, so it **derives** the patch from
each library mod: the `.ini` files alone for an `.ini` patch, three of the mod's
own assets for an asset patch.

**What that overstates**: a derived patch's names come from the same copy of the
mod on disk, while a real author works from a version that may have renamed or
restructured things. The `.ini` half shows that decay honestly — self-scores of
43%, 69%, 81%, 96% from the partial-`.ini` idiom — and still kept the answer
within rank 3 every time. The asset half scores itself 100% by construction, so
read its 82% as the optimistic end.

**The requirements measurement** is a sample of `Mod/Index` plus one `ProfilePage`
per mod, counting entries whose url matches `gamebanana.com/mods/<id>`. It needs
no fixture and no library; it is ~150 requests at a polite rate.

**The patch rules themselves** have their own corpus harness,
`test/patch_detection_corpus_test.dart`, over `ZZZ_PATCH_CORPUS`.

## 5. Where it lives

| File | Owns |
|---|---|
| `services/patch_destination_ranking.dart` | The fingerprint and the order. Pure — sets of names in, an order out |
| `services/library_file_index.dart` | The library walk: basenames per folder, no file contents |
| `screens/dialogs/patch_install_flow.dart` | `rankPatchDestinations` — composition, and the one judgement that a folder answers for a requirement when its recorded origin is the mod linked |
| `screens/dialogs/patch_install_prompt.dart` | The list, the reason line, and nothing selected |
| `models/gamebanana/gb_requirement.dart` | `_aRequirements`, and what a url has to look like to name a mod |

The fingerprint comes out of the **same walk the patch verdict was reached on**
(`PlannedPatchScan.contents`) rather than a second traversal: the temp folders are
still being written to on one path, so two walks are not guaranteed to agree.
