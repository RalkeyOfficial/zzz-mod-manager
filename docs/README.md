# Developer documentation

Reference material for people working *on* ZZZ Mod Manager. For using the app, see
the root [`README.md`](../README.md).

## Contents

| Document | Covers |
|---|---|
| [`metadata-schema.md`](metadata-schema.md) | The **file format** of a mod's `metadata.json` sidecar: every field, save and round-trip semantics, schema versioning and the migration hook |
| [`origin-tracking.md`](origin-tracking.md) | What the app **knows about where a mod came from**: the confidence model, every route that writes an `origin` block, the offline backfill, the resolve flow, and the installed-mods index |
| [`metadata-autofill.md`](metadata-autofill.md) | What a marketplace install **copies from a mod page** into the new mod: description, character, tags and gallery |
| [`configuration.md`](configuration.md) | The app's **own settings**: `config.json`, the SharedPreferences mirror, the dual-storage pattern, and how to add a setting |
| [`gamebanana-api.md`](gamebanana-api.md) | The **remote protocol**: which of the two APIs to use, browsing/filtering/sorting, the mod and file objects, NSFW handling, downloads, the category tree, and the gotchas |

## Related files outside this directory

| File | Covers |
|---|---|
| [`../CLAUDE.md`](../CLAUDE.md) | Architecture overview, layer structure, dev workflow (hot reload vs restart), the platform abstraction, and the version-bump checklist |
| [`../CHANGELOG.md`](../CHANGELOG.md) | Release history (Keep a Changelog / SemVer) |
| [`../BUILD_WINDOWS_GUIDE.md`](../BUILD_WINDOWS_GUIDE.md) | Windows build and packaging |

## Conventions

- **New developer docs go in this directory**, not the repo root. The root has
  accumulated a dozen one-off markdown files and is no longer navigable.
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
