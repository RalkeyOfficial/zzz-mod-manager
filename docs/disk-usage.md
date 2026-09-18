# Disk usage

**Scope:** what the Storage tab measures and how, and what the reclaim is allowed to delete.
Where each store lives and what it is *for* belongs to the doc that owns it — [`downloads.md`](downloads.md), [`applying-updates.md`](applying-updates.md) §4.2, [`metadata-schema.md`](metadata-schema.md), [`logging.md`](logging.md), [`configuration.md`](configuration.md).

## 1. Six categories, and why they are disjoint

| Category | Where | Measured by |
|---|---|---|
| Mods | `<modsPath>/<mod>/`, **minus** the sidecar | a walk |
| Covers & metadata | `<modsPath>/<mod>/.zzz-mod-manager/` | the same walk |
| Saved versions | `<appData>/backups/` | manifest sums |
| Downloads | `<appData>/downloads/` | one `stat` each |
| Logs | `<appData>/logs/` | one `stat` each |
| Leftovers | `<appData>/mod_images/` + `<systemTemp>/zzz_archive_extract_*` | a walk each |

**Mods and the sidecars are one traversal split by path, not two walks.** The sidecar lives *inside* the mod folder, so measuring the library whole and the sidecars again would make the slices sum past the total — and a chart whose parts exceed its whole is not reporting, it is lying. `StorageScanner` memoises the walk so whichever of the two providers asks second is free.

## 2. Every number here is apparent size

Sizes are the sum of file lengths. Free space is what the OS reports. **The two will not reconcile**, and on a compressed, sparse or copy-on-write volume they can differ by a lot — `<appData>/backups` is the worst case, since a snapshot copy may be reflinked and cost almost nothing.

Three consequences, all of them load-bearing:

- The page never says "delete these to free X".
- The reclaim reports the **measured** free-space delta where it can read one, and falls back to the apparent sum only when it cannot.
- A hardlinked file is counted once per path, and there is no fix — Dart's `FileStat` exposes no link count.

## 3. Zero and "could not look" are different states

`StorageRead` carries which: `ok`, `partial`, `unreadable`, `absent`, `notConfigured`. The reason this is not a nullable int is that **`0 B` beside Mods reads as "your mods are gone"**, which is a far more alarming statement than "no folder is chosen". A category with no measurement draws no slice at all rather than a zero-width one.

`partial` means the walk skipped something, so the byte count is a floor and the UI says "at least". One partial category makes the page total a floor too.

The import preflight treats partial differently and more strictly: `ModManagerService._bytesUnder` returns **null** rather than a smaller number, because a total short by one unreadable folder would approve a copy that then fills the disk.

## 4. The walk

`utils/directory_size.dart` is the one recursive size walk, shared by the snapshot capture, the import preflight and this page.

- **Catches per entity.** A folder deleted by a concurrent rescan must not end the walk and have the truncated total reported as fact.
- **Containment is decided by resolved path, not by entity type.** `followLinks: false` yields a symlink as a `Link` and skips it, but **a Windows junction comes back as a `Directory`** and the walk would descend it. Since mods are activated by linking them into the game folder, descending one either counts a mod twice or leaves the library; one pointing at an ancestor recurses until something gives. Resolving each directory before descending catches symlinks, junctions and bind mounts alike, at one syscall per directory. `PlatformService.isModLink` cannot be used here — its Windows implementation spawns a process per call.
- **Synchronous**, so `Isolate.run` takes it unchanged. A library of a few hundred thousand files is that many `stat` calls, and the async stream makes each one a microtask on the UI isolate.
- A mod folder that is a link contributes no bytes and is shown as "linked elsewhere", never as `0 B`.

`Isolate.run` cannot be cancelled, so there is deliberately no cancel button. One would need `Isolate.spawn` and a kept kill port.

## 5. Saved versions come from the manifests

`SnapshotService.totalBytes()` sums the size each snapshot recorded at capture, rather than re-walking. One `readdir` per group plus one small JSON each, against gigabytes this app already measured — and the drill-down's dates, reasons and version labels come free, which a raw walk would have to reconstruct by reading the same manifests anyway.

What it trades: `manifest.json` itself is uncounted, and the figure drifts if someone edits `<appData>/backups` by hand.

## 6. Free space is a list, not a slice

The library is routinely on a different disk than app data, so there is no single "free" number and it cannot be a wedge of the same ring. One line per volume, labelled by what it holds. Two probes answering identically collapse to one line — identity cannot be tested portably from Dart, since `parseDfAvailableBytes` keeps only the byte count, so equal free space is the available approximation and it errs towards one line rather than inventing a distinction.

On Windows the API needs an existing **directory**, so the probe is `<appData>` itself rather than a subfolder that may not have been created yet.

## 7. Freshness

Tab entry re-reads only the cheap categories — saved versions, downloads, logs, leftovers, free space. **The library walk is not re-run**, because bouncing off the tab must not re-walk gigabytes; it sits behind an explicit Rescan, and the page compares the mod count it scanned against the current library to say "your library has changed since this scan" rather than quietly showing an old number.

The category providers are **not `autoDispose`**, and that is what makes the tab work: tabs are keyed `AnimatedSwitcher` children with no keep-alive, so the screen's `State` is disposed the moment the user switches away. A container-owned provider is not, so a walk finishes while the user is elsewhere and the answer is waiting on the way back. Nothing needs hosting above the switcher.

**Nothing watches `libraryProvider`.** Because these providers live for the session, that link would stay live all session: every mod toggle, rename and install anywhere in the app would kick off a multi-gigabyte re-walk for a user standing on the Mods tab who has never opened Storage.

## 8. The reclaim

`storage/reclaim_plan.dart` is a pure function over plain records and a clock; `ReclaimService` lists, deletes and reports, and decides nothing. The whole safety argument is therefore testable without arranging real races.

Six targets: completed archives, abandoned partials, temp extractions, legacy images, old logs, and saved-versions groups no mod claims. **The library and the sidecars are absent from the enum**, so no future edit here can reach them. `<appData>/backups` is reachable through the one target, and only for a group whose uid no mod in the library carries.

### The gate

`DownloadPaths.sweepCompleted` is documented safe at launch and nowhere else, because a completed archive is indistinguishable from one an install is about to consume. On demand the question is whether anything is in flight at all:

- **The queue** — a job that has finished transferring but has not been installed is still busy. Its archive is under its final name and is exactly what the sweep would take.
- **`ArchiveActivity`** — a drag-in or file-picker install unpacks with no download job anywhere, so the queue reads idle while an archive is being consumed. The counter is held for the unpack; the copy that follows is covered by the grace below.

**Filtering to "only the files no job will claim" has no correct implementation**, which is why a closed gate refuses the whole target and names it. A download's final name is chosen at the moment it lands, by collision resolution — a job that will become `mod (2).rar` is indistinguishable from one that will become `mod.rar` until it does.

The same gate covers the partials, which look safe and are not: a paused, resumable `.part` can be exactly as old as the staleness rule allows and be about to resume. If nothing is active, nothing can be resuming.

The gate is re-read immediately before the phase that depends on it. Nothing blocks `enqueue` for housekeeping — holding up a user's download for this is the worse trade, and the worst case of losing the race is a re-download.

### Two rules that are data-loss bugs if missed

- **Legacy images.** A mod with no sidecar still reaches its cover through `<appData>/mod_images`. Reachability is decided against the library, and `sweepLegacyImages` handed an empty list considers *every* image unreachable — so an unset, missing or unreadable library skips the target entirely rather than running against a list that cannot be trusted.
- **Saved versions.** The same edge: a group is unclaimed when no mod in the library carries its uid, so an unreadable library would make every group unclaimed and take every saved version the user has. It skips the target on the same condition as the images.
- **Logs.** Only names `isLogFileName` recognises: the user is invited into that folder to attach a log to a report and may have left something of their own. And **never the running session's file** — on Windows the delete fails; on Linux it succeeds, the sink writes on to an unlinked inode, no space returns until exit, and the user loses the log of the run they are about to report. `planLogRotation` reserves a slot for a file about to be opened, so `planLogReclaim` is a separate function rather than a reused one.

### The grace on an extraction directory

An hour, measured from **the newest write anywhere inside**, never from the directory's own timestamp. A directory's mtime stops changing once its top-level entries exist, while a deep extraction is still writing megabytes underneath — so the outside looks idle exactly when the inside is busiest. An hour rather than minutes because unpacking a multi-gigabyte archive genuinely runs that long, and because nothing locks `<appData>`: a second copy of the app shares it and cannot be asked what it is doing.

### The risk budget

What licenses accepting a millisecond race instead of building a lock: the sweep never touches `modsPath`, never deletes a file it does not recognise, and for everything but an unclaimed saved-versions group its worst outcome is a re-download.

## 9. Unclaimed saved versions go with the button, and only with the button

An unclaimed snapshot group — a mod deleted outside the app, a sidecar deleted by hand — is the one thing the sweep deletes that cannot be fetched again. It goes anyway, because nothing else can reach it: the saved-versions dialog opens from the mod's own row, and this mod has no row. Retention protects each group's newest entry forever, so without the button a deleted mod's history would sit in the store for good, counting against the 5 GB budget.

It is never swept on a schedule. The user presses the button, and the confirmation says that saved versions of mods no longer in the library are included. A mod moved out of the library and back in after the press has lost its history, and that is accepted: it takes three deliberate steps to arrive there, and a checkbox for it would cost every other user a decision.
