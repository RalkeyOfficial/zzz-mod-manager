# The library screen — the Mods tab and its surfaces

**Scope:** the Mods tab — the card, its one status slot, the toolbar, the library
menu's bulk actions, and the dialogs reached from a mod's context menu.

Not in scope: the rules about origin *states* and what each answer may write
([`origin-tracking.md`](origin-tracking.md) §4–§5), the update comparator
([`update-checks.md`](update-checks.md)), or how an update is written to disk
([`applying-updates.md`](applying-updates.md)). What follows is only what is
specific to these widgets.

---

## 1. A rescan only reaches the grid if `modGroupsChanged()` says so

`utils/mod_group_diff.dart`. A scan runs after every toggle, rename, edit and
import, so `ModsScreen` guards `charactersProvider` behind a field-by-field
comparison to avoid rebuilding the whole grid each time.

**That list is hand-written, and anything `ModInfo` gains that any surface renders
has to be added to it.** It has already failed once exactly this way: `origin` was
missing, so resolving a mod wrote the sidecar correctly, the rescan re-read it
correctly, the guard said "unchanged", and the amber mark stayed on the card until
the user switched tabs. Nothing threw.

`origin` is now compared through `ModOrigin`'s value equality — which is why that
model has `==` at all — so new *origin* fields are covered automatically. Nothing
else on `ModInfo` is.

## 2. `ModStatusSlot`

**Bottom-left of the cover**, the one corner `ModCardWidget` had free (top-left is
details, top-right the enable switch, bottom-right the source link and favourite).

It keeps a **constant footprint across states**, so resolving a mod doesn't reflow
the artwork under it, and it uses a **literal amber** rather than a scheme colour —
the card paints its palette over *artwork*, so a themed colour would be the only
thing on it that moved. Passing no `onResolveOrigin` hides it, which is what the
drag-feedback copy of the card wants.

**The two muted states are told apart by shape, not colour** — a dot for untracked,
a clock for a version recorded only as a guess. Two muted colours at 9–15px are
indistinguishable, and stay so for anyone colourblind.

**`modSlotStatus()` is where the one slot is decided**, folding the origin block
together with the session verdict, so precedence between "you have not sorted this
mod out" and "this mod has an update" is one decision in one place. The
short-circuit that silences the slot is narrowly `tracking: "off"` and
`remote_missing`, **not** every route to `none`: a mod recorded at `exact` also
folds to `none` and is precisely the mod best placed to have a *confirmed* update.

## 3. The toolbar

**Two rows: search plus the library menu, then every filter.** Actions and filters
used to be interleaved — the check overloaded onto a filter toggle, "check again"
and "assume current" in a row that appeared only while some filter was on — which
left the bulk resolution screen with nowhere to be re-opened from. Row two is always
present: it costs a row of height and buys every control a fixed place.

**The needs-attention toggle carries a count and hides itself at zero.** The answer
is usually either nothing or most of the library, and both are worth knowing before
pressing rather than after landing on an empty grid.

**The library menu holds the three bulk actions** (check, sort out tracking, mark
all as current), each with the count of mods it would act on and disabled when it
can do nothing — except *sort out tracking*, which is offered at zero because it
runs the check itself rather than greying out the most useful entry on launch. Its
badge counts what that entry would open, the one whose work is otherwise invisible.
The `↑` toggle beside the other filters is **only** a filter.

## 4. Check results are session state

`modUpdateChecksProvider`, and the records behind them
`modUpdateRecordsProvider` — **never persisted**. A verdict restored from disk
asserts something about a mod page nobody has looked at since. Keeping the
*records* is what lets the resolution screen be re-opened without a request.

Two scopes meet here deliberately: the check covers the whole library (its badges
are drawn on every tab), the filter covers the current view (that is all it can
narrow).

**A check reports through one surface, not two.** With nothing to resolve it raises
the summary notification; with mods whose origin can be sorted out it opens
`dialogs/bulk_resolution_dialog.dart`, which states that summary itself. Raising a
notification behind a modal is how a user ends up reading neither. The spinner is
cleared **before** the dialog opens — the request is what it reports, and one
turning behind a dialog says the app is still working while disabling the control
they would press next.

## 5. Bulk "assume current" turns the filter on before it confirms

`services/bulk_assume_current.dart`, `dialogs/assume_current_dialog.dart`. The rule
is that the user must have *seen* the set being rewritten, and it is enforced by
the action rather than by hiding the control until the filter happens to be on.
Flipping the filter cannot change which mods are eligible, only which are on
screen, so the count in the menu is the count that gets written.

Its plan comes from `visibleModsProvider`, the list the grid renders, **not** from
the wider list the `!` toggle counts: a control that rewrites more mods than it
displays is exactly what this rule exists to prevent. See
[`origin-tracking.md`](origin-tracking.md) §6 for the four rules it enforces.

## 6. Dialogs

- **`components/dialog_section.dart` is where these dialogs get their shape and
  type sizes.** They were loose `Text` widgets at hardcoded 10–12px, and both
  complaints that produced were the same: nothing marked where one idea ended and
  the next began, and none of it was readable. Sizes now come from the theme —
  `bodyLarge` (16) for anything meant to be read, `bodyMedium` (14) for the line
  explaining it, `titleMedium` for a heading — and a group of facts always arrives
  under a heading saying what the group is for. `DialogNotice(emphasis: true)` is
  the one "read this" state and uses the same literal amber as the card's status
  slot; **at most one per view**, or it stops being emphasis.
- **`bulk_resolution_dialog.dart`** groups rows by their *leading* question so a
  mod is listed once, and its intro states the one thing not visible from the
  controls — nothing is written until Save.
- **The update dialog's release notes are an accordion.** The first version dropped
  them into the middle with no boundary and no way to close them, so an author's
  three paragraphs pushed the verdict off the top of a scroll view nobody had asked
  to grow. The header doubles as the section divider and as the thing that
  *fetches* on the badge path, so one gesture does both.
- **`update_confirm_dialog.dart` is the last screen before a live install is
  touched**, and everything on it is something that cannot be said afterwards: the
  snapshot, the accepted keybind loss, a patch-shaped download, and the one
  question it asks. It offers **no way to proceed** against an unreconcilable
  layout — an "install anyway" there would invite the user to guess where the app
  refused to.
- **`mod_backups_dialog.dart`** is the rollback, reachable from the context menu
  only for mods that have a snapshot (`modBackupsProvider`, one readdir for the
  whole library).
- **`dialogs/download_with_progress.dart` is the app's last *foreground*
  download**, and the exception rather than the rule — every marketplace download
  runs in the background queue. Applying an update is a conversation (fetch, show
  what is about to be written over a live mod, write only if they agree), and
  holding that open across a tab switch would mean asking about a mod the user has
  navigated away from. It still goes through the queue, exempt from the
  concurrency cap on the way in — see [`downloads.md`](downloads.md) §7.
  Only the *download* is shared with the marketplace, deliberately: the
  marketplace imports an archive as a new mod folder while an update overwrites an
  existing one, and folding those together is what would produce a shared
  "install" that quietly does the wrong one.

## 7. The resolve dialog

`dialogs/resolve_origin_dialog.dart`.

- **The content filter degrades `hide` to `blur`, never to `omit`.** Dropping a
  flagged mod from a search the user is running to identify a mod they *already
  own* would make that mod permanently unresolvable, with no hint as to why.
- **Both lists are height-bounded and scroll inside themselves**, so the two escape
  hatches underneath stay one click away. Not hypothetical: a captured profile
  publishes six current files beside eight archived ones, and every one is a row.
  The file list's bound came down from 280 to 230 when the identity card grew its
  "currently tracked" lines — anything new in this dialog is paid for by the picker,
  which scrolls, never by the hatches, which have nowhere to go. A test taps them at
  the minimum window size for that reason.
- **It states what is already recorded before offering to change it**, and
  preselects the recorded file rather than leaving the answer invisible. Every
  selected row carries a chip naming what put it there, so "on record" and "our best
  guess" cannot be confused — the ambiguity worth removing is *what selected this*,
  not *that something is selected*. `_hasSomethingToSave` asks the write path
  (`OriginResolution.pickFile`) whether the result would differ rather than
  re-deriving the rule, because the interesting cases are not obvious: re-picking an
  `inferred` row looks like a no-op but is the confirmation that tier waits for.
- **`ResolveOriginGateway` is the local-side seam.** Calling `ApiService` straight
  from a dialog is this codebase's convention (delete, rename and edit all do) and
  the default keeps it — but `ApiService` lazily builds a `ConfigService` that
  writes the developer's **real** `<appData>/config.json`, so a widget test that
  merely mounted this dialog would clobber their library paths and favourites.
