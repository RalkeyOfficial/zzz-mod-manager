# Developer documentation

Reference material for people working *on* ZZZ Mod Manager. For using the app, see
the root [`README.md`](../README.md).

## Contents

| Document | Covers |
|---|---|
| [`app-architecture.md`](app-architecture.md) | The **layers of `lib/`**: the service layer, the platform abstraction, our GameBanana client, and the one markdown style sheet |
| [`marketplace.md`](marketplace.md) | The **native GameBanana browser**: the grid and detail screens, the `IndexedStack`, the card's one status slot, and what an install does on the way through |
| [`library-screen.md`](library-screen.md) | The **Mods tab**: the card and its status slot, the two-row toolbar, the library menu's bulk actions, and the dialogs reached from a mod |
| [`notifications.md`](notifications.md) | **What the app tells the user in passing**: whether to speak at all, the headline-and-subject rule, the card's leading slot, the stack and its clock |
| [`downloads.md`](downloads.md) | **Fetching mod archives**: the spawned-isolate pump and the measurements behind it, resume policy, backpressure, the stall timeout, the background queue and the panel that shows it |
| [`metadata-schema.md`](metadata-schema.md) | The **file format** of a mod's `metadata.json` sidecar: every field, save and round-trip semantics, schema versioning and the migration hook |
| [`origin-tracking.md`](origin-tracking.md) | What the app **knows about where a mod came from**: the confidence model, every route that writes an `origin` block, the offline backfill, the resolve flow, and the installed-mods index |
| [`metadata-autofill.md`](metadata-autofill.md) | What a marketplace install **copies from a mod page** into the new mod: description, character, tags and gallery |
| [`update-checks.md`](update-checks.md) | How the app decides a mod **has a newer version published**: the comparator, the confidence-aware verdicts, the whole-library pass and the two surfaces that show a result |
| [`applying-updates.md`](applying-updates.md) | How a newer download is **written over an installed mod**: the overwrite, patch detection, orphaned `.ini` files, replaying the install layout, snapshots and rollback |
| [`patch-destinations.md`](patch-destinations.md) | **Which mod folder a patch is installed into**: the filename fingerprint, the author's declared requirement, what each is measured to be worth, and why the list is ordered rather than narrowed |
| [`configuration.md`](configuration.md) | The app's **own settings**: `config.json`, the SharedPreferences mirror, the dual-storage pattern, and how to add a setting |
| [`gamebanana-api.md`](gamebanana-api.md) | The **remote protocol**: which of the two APIs to use, browsing/filtering/sorting, the mod and file objects, NSFW handling, downloads, the category tree, and the gotchas |

## Related files outside this directory

| File | Covers |
|---|---|
| [`../CLAUDE.md`](../CLAUDE.md) | Repo-wide rules: language policy, dev workflow (hot reload vs restart), changelog conventions, the non-negotiables |
| [`../mod_manager_flutter/CLAUDE.md`](../mod_manager_flutter/CLAUDE.md) | The app's rules and the index into this directory. **Rules and pointers only** — anything that needs explaining belongs in a doc here |
| [`../CHANGELOG.md`](../CHANGELOG.md) | Release history (Keep a Changelog / SemVer) |
| [`../BUILD_WINDOWS_GUIDE.md`](../BUILD_WINDOWS_GUIDE.md) | Windows build and packaging |

## Conventions

- **New developer docs go in this directory**, not the repo root. The root has
  accumulated a dozen one-off markdown files and is no longer navigable.
- **The `CLAUDE.md` files carry context, rules and pointers — nothing else, and
  under 200 lines each.** They are loaded into context on every session, so length
  there is a running cost in a way length here is not. Anything that needs
  *explaining* — a measurement, a rejected alternative, the reasoning behind a
  rule — belongs in a doc in this directory, with `CLAUDE.md` stating the rule in
  a line or two and linking to it. The app's `CLAUDE.md` reached 771 lines by
  absorbing exactly that material.
- **English only**, per the language rule in `CLAUDE.md`. Some older root-level
  documents are in Ukrainian (`*_UK.md`) and predate that rule.
- **One subject per document, and the scope line at the top is what decides.** A fact
  that fits none of them wants a *new* file, not the nearest existing one. When a doc
  starts needing a section about something its scope line doesn't name, that section
  is the beginning of the next doc.
- **Document what the code does, in the present tense.** Mark anything planned clearly
  as planned, and only where it constrains what exists today. **No status logs** — a
  "what has shipped so far" section is a changelog, and
  [`../CHANGELOG.md`](../CHANGELOG.md) already owns that. A reference that quietly
  describes unbuilt behaviour is worse than no reference.
- **Every doc must stand on its own.** Don't cite temporary planning or scratch files
  for the substance of a claim — restate the rule or rationale here instead, quoting
  it if that's clearest. Planning files get deleted as their contents ship, taking
  the meaning (and leaving a dead link) with them. Linking to durable things — the
  code, `CLAUDE.md`, other docs in this directory — is fine.

## Legacy root-level documents

These predate this directory and are **not maintained**. They describe past
migrations and one-off investigations, and may be inaccurate about current
behaviour. Kept for history; don't treat them as reference:

`CHANGES_SUMMARY.md`, `IMPLEMENTATION_SUMMARY_UK.md`, `MARKETPLACE_IMPROVEMENTS.md`,
`LINUX_MARKETPLACE_SETUP.md`, `WINDOWS_COMPATIBILITY_ANALYSIS_UK.md`,
`WINDOWS_IMPLEMENTATION_GUIDE.md`, `QUICK_START_WINDOWS_UK.md`,
`GAMEBANANA_BODY.md`, and `mod_manager_flutter/KEYBINDS_*.md`.
