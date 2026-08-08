---
name: review
description: Review the current changes (working tree, a branch, or a commit range) for bugs, concerns, untested code, stale comments, and bad documentation. Use when asked to "review the changes", "check my work", "look over this diff", or before opening a PR. Holds the project's invariants, doc-ownership rules and the plain-language bar that every review must check against.
---

# Reviewing changes

Report findings. **Do not fix anything** unless the user explicitly asks — a review
that silently rewrites code robs the user of the decision.

## 1. Gather the full picture

```bash
git status --short          # includes untracked files
git diff                    # tracked, unstaged
git diff --cached           # staged
git diff main...HEAD        # whole branch, when reviewing the branch
```

**`git diff` never shows untracked files.** New files are usually the largest and
least-reviewed part of a change — list them from `git status` and `Read` each one in
full. Skipping them is the most common way a review misses everything that matters.

Read the *surrounding* code too, not just the diff hunks. A hunk that looks correct
in isolation is frequently wrong against the function it now lives in.

## 2. What to look for

### Bugs and concerns
- Null / empty / missing-key handling on anything parsed from GameBanana or from a
  `metadata.json` on disk — both are untrusted input that changes shape without notice.
- Async: unawaited futures, `setState`/`ref` use after `dispose`, missing `mounted`
  guards, races between a scan and a UI action.
- Error paths: what happens on a thrown exception, a 404, a truncated download, a
  symlink that already exists, a permission failure.
- Silent failures — an empty `catch`, a swallowed error, a fallback that hides the
  real cause.
- Resource lifetime: HTTP clients, file handles, stream subscriptions, timers.
- Data loss: anything that writes or overwrites a user's `metadata.json`, config, or
  files inside the mods folder.

### Untested code
Name the specific *behaviour* that has no test, not just "add tests". Weigh:
new pure functions and parsers (should always be tested), new branches in existing
tested code, and bug fixes (a fix without a regression test invites the bug back).
Say when the gap is acceptable — UI-only wiring usually is.

### Comments
- Comments that no longer describe the code under them.
- Comments restating the code (`// increment i`) — noise.
- Missing *why* on anything non-obvious: a magic number, a workaround for a
  GameBanana quirk, a deliberate ordering.
- `TODO`/`FIXME` left in code that the change was supposed to complete.

### Documentation
Judged by three separate bars — check all three:

**Correct** — does it match what the code now does? A change that alters behaviour
covered by `docs/` must update that doc in the same change.

**Filed in the right place.** Each doc owns exactly one subject; the scope line at
the top of each file is what decides. A fact that fits none of them wants a *new*
file, not the nearest existing one.

| File | Owns |
|---|---|
| `docs/gamebanana-api.md` | GameBanana's *remote* protocol only — endpoints, fields, filtering, downloads. **Not** our client, and not what we do with the response. |
| `docs/metadata-schema.md` | Data about a **mod**: the `metadata.json` sidecar, its `origin` block, versioning, migration. |
| `docs/configuration.md` | The app's **own** settings: `config.json`, the SharedPreferences mirror. |
| `CLAUDE.md` files | Our architecture and conventions. |

The dividing line between the two data docs is *ownership*: if deleting it would
lose information about a mod, it belongs to `metadata-schema.md`.

**Plainly written.** Flag any sentence that only parses if you already know the
thing it explains. Concretely:
- Jargon or an internal term used before it is defined.
- A claim that depends on unstated nuance ("this is safe" — under which condition?).
- Long sentences stacking three clauses where three sentences would do.
- Vague quantities ("large", "slow", "often") where a number is knowable.
- A rule with no example when the example is what makes it usable.

Also: **docs must never reference `BUGS & TODO.md`.** Inline the substance so the
doc stands alone.

## 3. Project invariants — check every one

These are cheap to check and expensive to miss:

- **No `Platform.isX` branching** for platform behaviour in business logic. It goes
  on `PlatformService`, implemented in both `LinuxPlatformService` and
  `WindowsPlatformService`.
- **`characterAliases` is duplicated** in `_detectCharacterFromName` and
  `_findCharacterInText` (`mod_manager_service.dart`). A change to one that misses
  the other is a bug.
- **An archive md5 match is a matching key, never an integrity claim.** Reject any
  code, string or comment that presents a match as "verified".
- **Download timeouts are stall timeouts, never a total duration.** A legitimate
  transfer over a degraded CDN node runs ~25 minutes and must be allowed to.
- **English everywhere** — identifiers, comments, doc comments, strings. The only
  exceptions are `assets/l10n/*.json` and docs deliberately written in another
  language.
- **l10n stays in sync**: a new key in `en.json` needs the same key in `uk.json`.
  A hardcoded user-facing string that bypasses l10n is a finding.
- **`CHANGELOG.md` is updated** under `## [Unreleased]`, grouped under
  `### Added` / `### Changed` / `### Fixed` / `### Removed`, one line (two at most),
  describing behaviour and intent rather than implementation.
  Entries diff against the last *published* release — a bug introduced **and** fixed
  while still unreleased gets **no** entry. Flag those.
- **Version strings**: if the version changed, every spot in the `release` skill must
  have changed. `pubspec.yaml` alone is the recurring mistake.

## 4. Verify before reporting

Run these from `mod_manager_flutter/` and include the real output — never guess:

```bash
flutter analyze
flutter test
```

A finding you could not confirm should be labelled as a suspicion, with what would
confirm it. Never present a guess as a confirmed bug.

## 5. Report

Open with two or three sentences: what the change does, and the headline verdict.
Then the findings, grouped by severity, most serious first:

- **Bugs** — it is wrong; say what input produces the wrong result.
- **Concerns** — it works now but will break, or hides a failure.
- **Tests** — the specific untested behaviour.
- **Docs & comments** — stale, misfiled, or unclear, with the rewrite you'd suggest.
- **Nits** — collapse into a short list; never let these dominate.

State plainly when a category is clean. End with whether the change is ready to
commit, and if not, the shortest path to making it so.

## 6. How to format one finding

Every finding follows the same shape, so the user can scan a long review and stop
at the ones that matter. Number them so they are easy to refer back to.

````markdown
### 3. md5 mismatch is reported as a failed download

**File:** `lib/services/download/io_download_transport.dart:118`
**Also affects:** `assets/l10n/en.json` (`download.error.corrupt`)
**Severity:** Bug

The archive hash is compared against GameBanana's `_sMd5Checksum` and a mismatch
aborts the download as corrupt. GameBanana returns a stale hash whenever a mod
author re-uploads a file without bumping the file id, so a perfectly good archive
is thrown away.

```dart
if (digest.toString() != file.md5) {
  throw DownloadException('archive corrupt');   // ← not an integrity claim
}
```

An md5 match is a *matching key* — it tells us which mod an archive belongs to. It
was never an integrity guarantee, and this is the one place the codebase treats it
as one.

**Suggested fix** — keep the comparison, drop the abort:

```dart
final matchesCatalogue = digest.toString() == file.md5;
// Stale on re-upload; used only to link the archive to a known mod.
```

…and surface `matchesCatalogue` as a hint on the import screen rather than an error.
````

### The parts

| Part | Rule |
|---|---|
| **Title** | The defect in one line, not the symptom. "Empty tag list crashes the filter", not "problem in filter". |
| **File** | `path:line`, repo-relative so it is clickable. List every file the fix touches under **Also affects**. |
| **Severity** | One of the group names above. |
| **Summary** | One or two sentences: what the code does, and why that is wrong. A reader should be able to stop here. |
| **Code** | The smallest snippet that shows the problem, in a fenced block with the language tag. Point at the exact line with a trailing `// ←` comment. Quote the code as it actually is — never paraphrase it. |
| **Detail** | Only when the summary cannot carry it: the failure scenario as *concrete input → wrong output*, or the background the reader needs. Omit the heading entirely when it adds nothing. |
| **Suggested fix** | What you would do, as code where code is clearer than prose. Say when a fix is one of several reasonable options, and say when you are unsure it is right. |

### Keep it proportional

- A one-line nit gets one line — `constants.dart:31` — stray trailing whitespace.
  Do not inflate it into the full template.
- **Never invent a finding to fill a section.** A short review of a clean change is
  the correct output, not a failure.
- Repeats of the same defect across files are **one** finding with a file list, not
  five findings.
- If you would suggest a fix you are not confident in, say so in the finding rather
  than dropping it — an uncertain suggestion the user can judge beats silence.

## What not to flag

Reviews lose their value when padded. Skip:
- Style the linter already enforces (`analysis_options.yaml` is the authority).
- Rewrites that are a matter of taste, with no correctness or clarity gain.
- Pre-existing issues the diff merely touched — unless the change makes them worse,
  in which case say so explicitly and separately from the new findings.
- Speculative future requirements the user has not asked for.
