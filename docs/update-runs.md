# Update runs

**Scope:** how several mods are updated at once, and one mod in the same way, as a run that goes on in the background: its phases, the surfaces that show it, what it asks and what it does without asking, how many things happen at once and why, what Undo, Skip, Try again and Remove from the list mean, and what is built from what.
What an update does to a folder is [`applying-updates.md`](applying-updates.md), whose mechanism a run uses unchanged. How an archive is fetched and queued is [`downloads.md`](downloads.md), and what the notification stack is is [`notifications.md`](notifications.md).

**This is a design and it is not built.** The code today runs Update N as a loop of modal windows, one mod after another ([`applying-updates.md`](applying-updates.md) §7), and every section here that says what a run does describes the design.
A part of the code that exists and that a run keeps says so. The picture is the board "Updating mods" (`design/v3/boards/UpdateRunToasts.dc.html`, `design/v3/renders/UpdateRunToasts*.png`); where this note and the board differ, §2, §5 and §10 say which wins and why.
[§14](#14-decisions-settled-and-decisions-not-yet-confirmed) lists what the user decided and what is only recommended, and [§13](#13-what-changes-in-the-docs-and-rules-when-the-code-lands) lists what this note replaces in the docs and rules that describe the built behaviour.

## 1. What a run is

A run is the set of download jobs that one press of Update N, or one mod's Update or Reinstall, puts in the download queue. It has no object of its own: the jobs are the run, and every surface reads the jobs.
There is no modal window anywhere in it. Pressing Update N closes the list, and the work shows on the Updates page's rows, in the Downloads panel, on the sidebar's Downloads badge and as notification cards, and goes on while the user moves between pages or leaves the app alone.

The queue already has what a run needs: a Downloads panel with Needs your attention, In progress and Finished groups, a badge, a deck of Working cards, an `updating` state, a `waiting` state that holds an unpacked archive and frees the install slot, and the split of an install into prepare, answer and finish ([`downloads.md`](downloads.md) §8, §10). A run is a second user of that split.

A run does not start by itself. It starts from a press, with the user's picks, which makes it an update the user is present for in the sense that matters: the user chose each mod and each file, and read the footer that says what an update does ([§3](#3-consent)). Updating with nobody having asked stays refused ([`applying-updates.md`](applying-updates.md) §7).

A layer of a mod (a base, or a patch on top of it) is in at most one job of a run at a time, and a job writes one or more folders:

- **One mod, one file:** the ordinary job.
- **Mods that share an archive** (the picks have the same GameBanana file id): one job with one download, one unpack and one write per folder, in order. Two transfers of one file would share a `.part` and corrupt it, so they cannot be two jobs ([`downloads.md`](downloads.md) §7).
- **A base and a patch of one folder** in one press: two jobs, one per layer, and the second does not start its write until the first has ended, since both write the same folder. A folder has one write pipeline at a time.

## 2. The phases, and what each means in the app

The board draws six phases. The app has real steps behind each, and where the board shows more precision than the app has, the app wins.

| Phase on the board | Job state | What is happening | What is shown |
|---|---|---|---|
| Waiting | `queued` | The job is in line for a download slot, or held back by the lookahead cap ([§4.1](#41-the-model)). | "Waiting to update" on the row. On the panel "<size> · downloads next" for the first in line and "N ahead of it" for the rest. No bar. |
| Downloading | `running` | Bytes are arriving, with a real rate from a 5 second window. | A mini bar, "Downloading", "79 of 233 MB · 4.1 MB/s". The rate is empty for the first second, so the row reads "Connecting..." until the estimator has a figure. The rate is per job. |
| Unpacking | `downloaded`, then `updating` with the step `unpacking` | Two steps in a row that report no progress: the unpack (listing, space check, `7z` or zip, md5) and the preview (the folder it goes into and the archive's folders are read, the layout is replayed, the patch scan runs). | An indeterminate state and "Checking what is in the file". Not a bar: one that pretended to know how far along it is would be worse than not saying ([`downloads.md`](downloads.md) §9). |
| Needs you | `waiting` | The prepare found something only the user can answer ([§6](#6-questions)). The job holds its unpacked folders and has left the unpack and install lanes. | "Needs you" with Answer. |
| Installing | `updating` with the step `writing` | The write: the mod is turned off if it was on, the old folder is saved as a snapshot, everything but the sidecar is deleted, the new files are copied, a recorded patch is put back, the new origin is recorded, the mod is turned on again if it was on, and old snapshots are pruned. | A sweep, not a percentage. Under it the sub-step that is true: "saving the old file as a snapshot", "replacing the files", and "linking it in" only for a mod that was on. |
| Updated, Patch added | `done` with the outcome `updated` or `patchAdded` | The write ended. | "Updated" or "Patch added", with Undo while Undo is offered ([§8](#8-undo)). |

**The write has no progress, and the percentage on the board's "Installing" is a simulation.** The write is one call that copies a folder and reports nothing until it ends. The sub-steps come from one small additive callback on the applier, called as it passes the snapshot, the clear-and-copy and the reactivation; the bar is a sweep that stays a sweep while the steps change under it.
"Linking it in" is drawn only for a mod that was on: a mod that was off has nothing to link, and a line naming a step that did not happen is a false line. The board shows the step for every mod, including one that is off, because its demo steps follow the percentage; that is a simplification of the board, and the app's rule wins.

**Unpacking is one state on the board and two real steps.** The row says one thing for both, as the wait modal does today ("Unpacking the download.", then "Checking what this changes in the mod folder."); no row ever claims which of the two it is in.

A job's states are the queue's existing ones: `queued`, `running`, `paused`, `downloaded`, `waiting`, `installing`, `updating`, `done` and `failed`. An update job uses `queued`, `running`, `downloaded`, `waiting`, `updating`, `done` and `failed`; `installing` is a Browse install's state. **An update job is not pausable in the first build**: the queue's `pausable` is true for a running job whose intent is not `callerHandles`, so the new update intent is excluded from it by the slice that adds the intent (U3), and Pause is not offered on an update row. The outcome of a finished job gains `patchAdded`, `skipped` and `undone`, since a skipped update and an undone one stay in the list as rows ([§9](#9-what-stays-in-the-list)).

## 3. Consent

**A run applies each update without asking about it first.** Pressing Update N, the file the user picked for each mod and the footer text are the consent. This is decided ([§14](#14-decisions-settled-and-decisions-not-yet-confirmed)): it replaces the per-mod confirmation window that precedes every write today.

What the confirmation window said does not disappear. It goes to one of three places:

| What the confirmation said | Where it goes | Does the run stop and ask? |
|---|---|---|
| The layout is unknown (nothing is recorded about how the mod was installed and the archive has more than one folder) or changed (something is recorded and the archive no longer matches it). | The folders question ([§6](#6-questions)). | **Yes.** The write cannot proceed without the answer. |
| The archive expands to no folders. | A failed row ([§10](#10-states-the-board-does-not-draw)). | No. It is a failure, not a question: there is nothing to pick. |
| The download is shaped like a patch. | The patch question. | **Yes.** A patch written by the wipe leaves a folder holding only the patch ([§6](#6-questions)). |
| A patch is in this folder and nothing records which files are its, so the wipe takes it. | A small question: update anyway (the saved copy keeps it) or skip. | **Yes.** It is the one loss no rule pays for, and the folder looks complete afterwards. |
| The archive is locked. | The password question. | **Yes.** |
| The snapshot, "everything in the folder is replaced", the hand edits and the keys the user rebound that the author's `.ini` replaces. | The footer of the Update N list and of the one-mod Update window: "Each update keeps the file you have now as a snapshot, then replaces the folder's contents", and a second sentence saying that hand edits and rebound keys are replaced by the author's. The Reinstall card says the same for Reinstall ([`applying-updates.md`](applying-updates.md) §6). | No. The press is the consent, as it is for Reinstall. |
| Folders of the archive the write leaves out ("the archive also contains X, which won't be installed"). | A line on the finished row. | No. |
| The members of a sibling group, with their cautions and refusals. | See [§9](#9-what-stays-in-the-list). | No. |
| After the write: files written, files dropped, hotkeys that changed, the mod left off because another was turned on. | Lines on the finished row ([§5](#5-the-surfaces)). | No. |
| "The old version is the way back". | Undo on the finished row, and the History tab. | No. |

**Why this is acceptable where it was not.** The argument against unattended writes is that none of the accepted losses announce themselves, and a recovery nobody knows to reach for is not a substitute for having seen the change ([`applying-updates.md`](applying-updates.md) §7). A run answers that in three ways. Every case that can hurt a folder in a way the snapshot does not announce still stops and asks. The two facts that were learned only from the confirmation, the rebound keys and the dropped files, are shown on the finished row, where the user finds out before the game. And Undo sits on that row.
It is still the user's act: the user pressed a button that names the number of mods, picked a file for each, and the snapshot is unconditional. Automatic updating, with no press, stays refused.

**A run the user does not watch needs safeguards the attended path got from the user's presence.** Those are listed in [§4.4](#44-what-must-be-true-before-a-run-goes-unwatched), and the run does not ship before they are built.

## 4. How many things happen at once

### 4.1 The model

A run is a pipeline of four stages, and each stage has its own limit, held as a constant in `queue_policy.dart` next to `kDownloadConcurrency`, as pure functions. There is no setting.

| Stage | Limit | What it covers |
|---|---|---|
| Download | **D = 3** update jobs `running` at once, in a pool of their own | The transfer. Browse downloads keep the queue's own cap of two, so the worst case is five connections. |
| Lookahead | **L = at most 3 archives or 1 GB** ahead of the install, **always admitting at least one** | What the downloads may run ahead of the installs. See the definition below. |
| Unpack | **U = 1** at a time, and **at most one unpacked archive waiting** while an install runs | The unpack and the preview. With U = 1 and one waiting, the temp folder holds about two archives whatever the size of the run. |
| Install | **I = 1**, one chain, shared with Browse installs and every other writer of a mods folder | The write: snapshot, wipe, copy, put the patch back, link, record, and prune. Prune is on the chain. |

D, L, U and I are the four numbers a changed verdict changes ([§4.5](#45-what-would-change-it)).

**Order.** The jobs start smallest first and largest last, by the file size the file lists on GameBanana, so the first mods are updated within seconds and a 1.2 GB file does not hold up the rest. A transfer that stalls ends at the stall timeout (never a total duration, [`downloads.md`](downloads.md) §5) and its job goes to the end of the line, so a degraded node costs only the job on it. The rows on the Updates page keep their order; only the order of work changes.

**What L counts.** An archive is ahead of the install from the moment its download starts until its install ends or its job is skipped, failed or removed. That covers a download still arriving, a landed archive, one being unpacked, an unpacked one waiting for the install, and one waiting on a question. L counts those jobs by number (at most 3) and by the size each file lists on GameBanana (at most 1 GB together, the job being admitted included), and a job is admitted to download only while both hold. **One job is always admitted when none is ahead**, so a 1.2 GB file, which is over the byte cap on its own, runs when nothing else is ahead and cannot wait forever. The count of 3 and the download pool D = 3 coincide: when the installs lag, the downloads stop at three archives ahead, and the pool is never the limit that matters. The pure-policy tests of U3 pin the definition, including the always-admit-one rule and a 1.2 GB file after smaller ones.

**What the picture looks like.** Five mods of 20, 40, 80, 200 and 300 MB. The first three start downloading together (140 MB, three ahead). The 20 MB archive lands first and is unpacked while the other two arrive; its install starts while the 40 MB archive is unpacked and waits and the 80 MB one is still downloading. The 200 MB download starts only when the 20 MB install has ended and a place has opened, and the 300 MB one when the next has. At every moment at most three archives are between the start of their download and the end of their install, and one mod is installing. A 1.2 GB file in the same run is the last to be admitted and runs alone. The user sees one mod installing at a time and the others in their earlier phases.

**Rules no limit changes.** A layer is in one job at a time, and a second press for a layer already in a run adds nothing. **The run serialises each folder itself**: a folder has one write pipeline at a time, and the second job of a folder does not start its finish until the first has ended. A mod whose folder is marked as being written by something else (a restore, Edit info, a patch) is skipped at its write, with a reason on its row, and is not waited for, so an update never lands over a restore pressed while it queued. `whileWritingMod` is that mark and nothing more: a counter and a set of folder ids, read by the History buttons, the switch, the bulk actions and the update check. It blocks no second writer, and not every writer of a folder is shown to use it, so it cannot be the run's serialisation, and U3 and U4 build the per-folder pipeline and the skip. A job that stops at a question leaves the unpack and install lanes and goes back in line ahead of the jobs that have not waited.

### 4.2 What is recommended, and what it rests on

The recommended default is the hybrid of the model above: three update downloads and a bounded lookahead, one unpack at a time with one waiting, and one install chain. It is a recommendation: the user has decided the mechanism (parameters held as constants, no setting, until measured) and has not yet confirmed these values ([§14](#14-decisions-settled-and-decisions-not-yet-confirmed)).

**The premises the model rests on.** The run has no per-mod confirmation, so the user is not the serial resource and the argument that one update at a time costs nothing, because a human answers each one in turn, does not apply. The only waits for the user are the questions of §6. The install service is not a singleton that has been shown unsafe to interleave: `downloads.md` §8 states that two installs would race on the `7z` run and on the mods folder, and for writes into existing folders that is stated and not shown ([§4.3](#43-stage-by-stage-what-the-code-allows-today)).

**Rejected alternatives.** One update at a time with only the next download overlapping the install keeps the network idle behind a degraded node, which is the one case where concurrency across different files pays. Several installs at once for different folders multiplies the half-written folders left by a close or a full disk, buys little on one disk, and rests on stages that are not shown safe. A user setting for the numbers adds a test and maintenance burden for values nobody has measured.

**The evidence**, from the code and from one session's sampling of GameBanana (`gamebanana-api.md` §8):
- **The only slow and unpredictable stage is the network.** A healthy GameBanana node serves 14 to 22 MB/s. Node assignment is deterministic per file, so a retry cannot leave a bad node, and four range connections to one file on a degraded node recovered only about 2 MB/s: more connections to one file do not help. A degraded node served 0.08 to 0.83 MB/s, up to about 25 minutes for 1.24 GB, and a node's speed swung tenfold within minutes. Only concurrency across different files routes around one bad node, and the queue's two slots exist for that.
- **Nothing above two concurrent transfers of different files has been measured**, and nothing on Windows. GameBanana publishes no limit; eight concurrent download starts all returned 206 and thirty concurrent API requests all returned 200. The figures are one session's sampling and are not settled properties of the service.
- **Install is disk-bound, and zip decode is single-threaded on the UI isolate**, so more installs and more unpacks buy little on one disk and multiply RAM and disk peaks. The sampled median archive is 21.9 MB, p90 95.7 MB and p99 358.9 MB, with a maximum of 1244.7 MB, so overlap matters for the large files and for degraded nodes.
- **Blast radius when unattended.** A killed app or a full disk leaves one half-written folder per install running, with nobody watching. One install at a time bounds that to one mod, and the safeguards of §4.4 are what make that one recoverable. The failure paths that parallel installs would multiply (no snapshot space check, a partial snapshot left behind, a one-unpack space check) are the same ones.
- **Practice elsewhere, from outside the repository and not verified here.** Package managers are reported to download in parallel and install in one locked transaction, and Vortex is reported to allow concurrent downloads and concurrent installs of different mods. None of it is evidence about GameBanana, and none says that installs of different mod folders are unsafe.

### 4.3 Stage by stage: what the code allows today

"Different folders" means two updates of two different mod folders.

**Safe to run concurrently today, by the code:**

| Stage | Why | Where |
|---|---|---|
| Download | Two transfers already run at once. The space check counts every transfer in flight. Only the cap, and the rule that an update's download bypasses it on the way in (`DownloadIntent.callerHandles`, `bypassesCap`), change. | `services/download/queue_policy.dart`, `download_service.dart` (`_requireSpaceFor`) |
| Unpack of a 7z or rar | Each call makes its own `zzz_archive_extract_*` directory and runs its own `7z` process (`Process.run`). | `services/archive_service.dart` |
| Preview | Read-only on the unpacked folders and the installed folder. | `UpdateApplier.preview`, `readFolderContents` |
| Snapshot capture | A unique directory per call and one group per mod uid; the sidecar write behind `uids.ensure` is locked per folder. | `services/backup/snapshot_service.dart` (`capture`, `_createSnapshotDir`), `mod_uid.dart`, `lockSidecar` |
| Wipe and copy | Inside that mod's own folder only; one sequential stream per update (`copyDirectory` awaits each file). | `UpdateApplier._wipe`, `utils/directory_copy.dart` |
| The per-folder write mark and the rescan | `whileWritingMod` is a counter per folder id plus a set of the folders being written, so writes on different folders at once are counted separately. It marks and blocks nothing: a second writer on the same folder is not stopped, and not every writer is shown to use it, so the run serialises each folder itself ([§4.1](#41-the-model)). A rescan during a scan joins it and walks once more; an update check skips a folder whose write count moved. | `utils/state_providers.dart` |
| The shader record | Its read-modify-write is serialised, and a shader file the app did not place is never overwritten. | `ShaderFixesService._serialised` |
| Prune | By reading: a double delete degrades to a logged warning (`delete` checks `exists` and catches), and a snapshot mid-copy is that mod's newest and never pruned. A mutex on the chain, as `ShaderFixesService._serialised` is, costs a few lines. | `SnapshotService.prune`, `retention.dart` |

**Not safe, or not shown:**

| Stage | What is true | Where |
|---|---|---|
| Unpack of a zip | The whole archive is read into memory (`readAsBytes`) and decoded on the UI isolate (`ZipDecoder().decodeBytes`); there is no isolate or `compute` in the file. A second zip unpack gains no CPU and doubles the RAM. | `archive_service.dart` (`_extractZip`) |
| The unpack's space check | It compares one unpack's listed size with the free space at that instant and counts neither unpacks in flight nor the unpacked folders of jobs waiting on a question, so two large unpacks, or one beside a waiting one, can each pass and jointly overflow a tmpfs, which is memory. | `archive_service.dart` (`_spaceShortfall`) |
| The snapshot's space check | There is none. | `snapshot_service.dart` (`capture`) |
| A failed capture | It logs critical and returns null, so no write happens, but the catch does not delete the directory it made, and `_read` accepts any directory with a `files/` folder as a snapshot, manifest or not. A partial snapshot can sit in History as the newest of its mod, and with one snapshot kept per mod the retention plan, which never prunes the newest, prunes the last good one. Read from the code; not run. | `snapshot_service.dart` (`capture`, `_read`), `retention.dart` |
| `config.json` | It is rewritten whole with a plain `writeAsString`, not atomically and not serialised, so a kill mid-write or two overlapping saves can leave it torn. Activating and deactivating a mod writes it. | `services/config_service.dart` (`_saveToFile`) |
| Closing the app | `onWindowClose` flushes the log and calls `exit(0)`: a write in flight is killed part-way, and the number killed is the number of installs running. | `main.dart` |
| Installs of different folders through `ModManagerService` | `downloads.md` §8 states that two installs interleaving would race on the `7z` run and on the mods folder. It is stated and not shown for writes into existing folders; the stages above are folder-local and disjoint. What is not shown: the links in the game's mods folder and One at a time's turn-offs with two writes at once, the size budget of prune counting a snapshot still being copied (the budget may be over by that much until the next prune), and the library rescan landing on the right final list. | `services/mod_manager_service.dart` (`activateMod`, `deactivateMod`), `SnapshotService.prune` |
| Windows | The queue, the transfer beneath it, and a deactivate against a file the game holds open have never been run there. | `docs/downloads.md` §7, `docs/applying-updates.md` §7 ("Known gaps") |

Disk per active update is about twice the mod's size beyond the library: the archive in `<appData>/downloads` until it is consumed, the unpacked archive in the temp folder, a snapshot of the old folder in `<appData>/backups`, and the new files in the folder while the wipe has freed the old ones. They can be three volumes.

Tests that would show the unshown: two `UpdateApplier.apply` calls at once on two folders in one temp library (`test/support/temp_library.dart`), asserting both folders, both snapshots, both sidecars and the shader record; `prune()` started while a `capture` of another mod is copying; two `activateMod` calls on different mods of one character with One at a time on; overlapping `whileWritingMod` calls (`test/support/held_write.dart`); a capture that throws part-way, asserting no directory is left in History; two extractions at once with a free-space function reporting the sum. A passing set is the licence for an install limit above one, and it still needs a Windows session.

### 4.4 What must be true before a run goes unwatched

Each of these is a real bug or gap in the code today, and a hands-off run is what makes them matter. The run does not ship before they are built, and where one is also a defect outside the run, it is filed as a follow-up ([`v3-rework-plan.md`](v3-rework-plan.md), Review follow-ups).

1. **A snapshot space check.** A write that cannot be given a snapshot does not start, with a refusal that names both figures, as the unpack's does.
2. **A failed capture deletes the directory it made**, so no partial snapshot can be the newest of its mod.
3. **The unpack's space check counts the unpacks in flight and the unpacked folders waiting** (the one for the install and the ones that wait on a question), not one unpack alone.
4. **A close guard.** Closing waits, bounded, for the write in flight, and never for downloads or questions. `downloads.md` §10 decided there is no "close anyway?" for a download, since closing loses only bytes that resume; a write killed part-way loses a folder.
5. **A halt on a disk-wide failure, reported on return.** A failure that every later job would share stops the run: not enough free space at the download, the unpack or the snapshot, a snapshot that cannot be taken, or a write that failed part-way. Jobs not started stay queued with "Stopped: the disk is full" in place of their wait, and the run offers Continue and Cancel all; an Error card stays until closed, and the rows say what stopped. A failure of one mod's own (its file was removed, a password nobody gave) does not stop the others.
6. **An atomic `config.json` write**: written to a temporary file in the same folder and renamed over the old one, and serialised.

### 4.5 What would change it

- Install time at least half the download time on an SSD, together with a clean test of two installs of different folders and a kill test: allow two installs for different folder ids, each folder keeping its own pipeline.
- One download stream far below the user's line: four update downloads.
- Three concurrent transfers throttled: back to two.
- Zip decode moved off the UI isolate: a second unpack lane.
- A Windows session that finds installs bound by something other than the disk (antivirus scanning is the suspect, and it is not measured): more install parallelism.
- Contention on a spinning disk: confirms one install.

**The measurement.** A 10-mod run on the existing sequential engine with a timer on each stage (download, unpack and preview, snapshot, wipe and copy, link and prune, and the seconds a job waited for the previous stage) on an SSD and an HDD, and a test of three concurrent transfers of different files. The fallback, when the run cannot be done first, is to ship 3, 1 and 1 with each stage's seconds logged by the app (`logging.md`), so the first real runs are the measurement.

### 4.6 What the limits do to the surfaces

The design draws no new state for any of these numbers. Up to three rows read Downloading at once, each with its own mini bar and its own rate (with several transfers sharing a link each figure is lower and their sum is the link; the rate is shown per row only). The panel group's heading says "Updating", never "one download at a time". A waiting row reads "downloads next" for the first in line and "N ahead of it" for the rest; a job held by the lookahead cap reads "waits for an install to finish" while any job ahead of it is moving, and "waits for your answers" when every job ahead of it is waiting on a question, since nothing will free a place until the user answers. The deck's front card is the job that is furthest along (installing, then unpacking, then the furthest-along download, then the first queued, ties by run order) and "N more updating" counts the others, so the card reads the same for any limit. The board's front card ranks installing, then downloading, then the first active job and has no unpacking step; the order here wins, since an unpacking job is further along than a download.
A stalled transfer frees its slot and its job goes to the end of the line.

## 5. The surfaces

Every surface reads the jobs; none holds a copy.

**The Updates page row.** The Update and Ignore buttons give way to a status cell while the mod is in a run: a mini bar and the phase, and Answer, Try again or Undo beside the phase where one applies, as the board draws (the board's "Retry" is the app's "Try again"). A mod that is not in a run keeps its Update and Ignore. The page also lists the run's finished jobs ([§9](#9-what-stays-in-the-list)).

**The Downloads panel.** Needs your attention holds each question and each failed update with its two buttons, as the board draws; an update question's are Answer and Skip update, a failure's Try again and Remove from the list (the app's words for the board's "Retry" and "Remove"). A failed update row is in Needs your attention and not in Finished, which is where a failed download is today. An Updating group holds the live jobs in the order of work. Finished holds the jobs that ended, with Undo. The footer line while any update row is present reads "Each update keeps the file it replaces as a snapshot."; with none, the panel's footer is the downloads one. A waiting row is dimmed, with its size.

**The sidebar badge.** The Downloads row's amber pill counts the jobs that need an answer, as it counts waiting installs; the count of live jobs in plain mono and the red pill for failures follow the rules of `downloads.md` §14 unchanged, with update jobs counted among the live and failed ones. The Updates row's count follows the verdicts and drops the moment a write removes a mod's mark. The board counts questions and failures together in one amber pill; the app keeps amber for the jobs waiting on an answer and the red pill for failures, and that rule wins.

**The notification deck and cards.** Update jobs deal a Working card each into a deck of their own, so a run and a Browse download are two slots. The front card is the job that is furthest along (§4.6), titled "Updating <mod>" with the step as its body ("Downloading · 79 of 233 MB", "Unpacking", "Installing · replacing the files") and a 3px bar along its bottom edge for a download and for the write; "N more updating" is its last line. A job leaves the deck on its own, as a download does.
A finished update's Done cards are counted on one card: "<mod> updated" with a portrait for one, "3 mods updated" for several, with the names under it and the action Show, which opens the Downloads panel. A failure is a card of its own, "Couldn't update <mod>", with Try again for a transfer failure. A question is the one Needs you card for every waiting update and install, with Answer (which opens the oldest question's window) and Open Downloads ([§6](#6-questions)). A halt ([§4.4](#44-what-must-be-true-before-a-run-goes-unwatched)) is one Error card that stays until closed.

**Three show and the rest fold.** The stack shows three slots and folds the rest into "+N more", oldest first ([`notifications.md`](notifications.md) §5). The deck is one slot, the Needs you card is one, the merged finished card is one, and each failure is one, so a long run never fills the three by itself. The board folds the finished card first; the stack's own rule, oldest first, stands, since a merged finished card is raised newest each time and sits at the newest end, and a question or an error, which stay until closed, are the ones that can pile up.

**What each surface says about the finished row.** The row and the panel's Finished line say, in this order and only what is true: the outcome ("Updated", "Patch added" with where it went), "the 12 Aug file is a snapshot", the number of files dropped ("14 old files removed"), the number of hotkeys that changed ("2 hotkeys changed", opening a small list of before and after), the folders of the archive left out, and "left off: another was turned on" when One at a time turned the mod off during its write. The hotkey line is the only place the accepted loss of rebound keys becomes visible before the game.

## 6. Questions

A question is a decision the prepare cannot make. There are five.

| Question | Found by | Asked in |
|---|---|---|
| The archive's password | The unpack's own listing, before anything is written. | The archive password dialog ([`downloads.md`](downloads.md) §12), asked again when the password did not open the archive. |
| The layout is unknown (no recorded layout and more than one folder in the archive) or changed (a recorded layout the archive no longer matches). | The layout replay in the preview (`planUpdateLayout`). | The folders window in its Update context: what the mod has now, the archive's folders with hints, nothing ticked; the button names the mod. |
| The download is shaped like a patch. | The patch scan of the incoming folders. | The patch window in its Update context. |
| A patch is in the folder and nothing records which files are its. | The recorded patch files against the folder. | A small question: update anyway, with the saved copy keeping the patch, or skip. |
| A change at the write (below). | The write's own re-read. | The question it has become. |

**The patch question.** A patch-shaped download for a mod's base layer cannot go through the update's write, which clears the folder: `UpdateApplier._write` calls `_wipe` with no branch on whether the download is patch-shaped, so a patch-shaped file written as a base update leaves a folder that holds only the patch's files (and the recorded patch put back, which `test/update_applier_patch_shaped_wipe_test.dart` pins), while the confirmation window today says "Only its .ini files are being replaced — everything else here is left as it is". A run never writes a patch-shaped file by the wipe path. The window's two answers write it as a layer by placement (`applyPatchInto`, as a patch installed into a mod is written):
- **Put it on top of <the mod this update is for>**, preselected, "Your files stay and the patch goes on top, so you can take it out again from History."
- **Add it to a different mod you have**, with a library search and a ranked list, nothing picked, "The files it replaces are kept, so you can take the patch out again."

The preselected first answer departs from the rule that a suggestion is never preselected ([`patch-destinations.md`](patch-destinations.md) §3). The mod is not a guess: the user picked this file for this mod, so it is evidence, not a ranking. This is not yet confirmed by the user ([§14](#14-decisions-settled-and-decisions-not-yet-confirmed)). The "install it as a new mod" answer of the install-time window is absent here, since an update has a mod.
After "Patch added" the base layer would still list the same file as newer, since its recorded file is the old one; the run records a dismissal on the base layer, the value Ignore writes for that check (`UpdateCheck.dismissableUpTo`: the date of the newest of the newer files the check lists), so the row does not offer the update again. It does not use `dismissalAfterTaking`, which writes the newest listed date only when a file newer than the one taken exists and returns null when the taken file is the newest listed, which is the common case here and would offer the same file again. The dismissal also silences any other file listed that is not newer than the newest, until something later is published. Whether the base should keep offering a newer base file is to be settled by a test against the verdicts of [`update-checks.md`](update-checks.md) §4 and §2. A patch added to a different mod writes a second folder: it is marked as being written for its duration, and the origin record and the Updates row of that mod change; the original mod's row reads "Skipped" or "Patch added elsewhere", and says which.

**The folders question** is the existing picker in its Update context. An update fills one mod that already exists, so there is nothing to name and no separate mods: the ticked folders replace what the mod has, together, and the mod keeps its name, its character and whether it is on.

**How questions queue.** A job that finds a question stops, keeps what it found, leaves the unpack and install lanes, and shows as Needs you. Several questions queue in the order they were found, and each one's Answer opens its own window; one window is open at a time, and after an answer the next is offered, not forced. Answering runs the questions after it in the same sitting, as an install does: Pick folders is followed by the patch scan of that selection. Closing a window without an answer leaves the question waiting; only Skip ends it. The answer goes back in line for the lanes ahead of the jobs that have not waited.
The merged Needs you card's Answer opens the oldest question's window. Its Open Downloads button stays. This reverses `notifications.md` §4's "the question is never asked from the card", whose reason was that an install's question needs its row's room, which a question that is a window does not.

**A question can arrive while nobody is looking.** The downloads and unpacks run ahead of the installs, so a patch, a folders or a password question can be found on a mod far down the run, minutes after the user stopped watching. A waiting question holds its archive (a password) or its unpacked folders in the temp folder, and **it keeps its place under the lookahead cap**: it counts as downloaded and not installed. It does not hold the unpack lane or the one unpacked archive allowed to wait for the install, so the mods behind it go on. The consequence is a bound: with the cap full of questions (three, or 1 GB) no further download starts, the installs already unpacked finish, and the run waits for the user's answers with the Needs you card saying how many are waiting. The questions are bounded by the cap and never accumulate without limit, and the user finds at most that many on return.

**What state a mod is in while its question waits.** Nothing has been written. The mod's folder is untouched, its link is in place, and it is not marked as being written, since the mark is made at the write. The unpacked folders sit in the temp folder, which is memory on a tmpfs, and the unpack's space check counts them ([§4.4](#44-what-must-be-true-before-a-run-goes-unwatched)).

**Staleness at the write.** The preview was made at the unpack, and a question, or the wait for the install lane, may take hours. At the write the job re-reads the mod by its uid and previews against the folder as it is now: a rename, a restore or a deletion can have landed in between. A changed verdict is a new question; a folder that is gone is "the mod is no longer there" on its row, and nothing is written.

**A restart.** The queue is not persisted, so a restart loses every pending answer, every unpacked folder and the record of what a closed run had finished, and the session's verdicts, so the Updates page reads "not checked" until a check. The only residue is a `.part`, which resumes if the file is asked for again within 7 days. A run killed during a write is the case the close guard exists for ([§4.4](#44-what-must-be-true-before-a-run-goes-unwatched)); a run journal that would let a relaunch tell a half-written folder from a finished one is not designed here.

## 7. Failure, Try again, Skip, Remove from the list, Cancel

**One mod failing does not stop the others.** A failed job has its own reason, its own row and its own card, and the run goes on. The exception is a disk-wide failure, which halts the run ([§4.4](#44-what-must-be-true-before-a-run-goes-unwatched), item 5): the next job would fail the same way, and a nearly full disk is how a folder is left half written.

| Control | Means | Offered |
|---|---|---|
| Try again | Fetch the file again, at the end of the line. | On a transfer failure only. After a failure past the unpack or at the write there is nothing a second download would change. |
| Remove from the list | Take a failed row off the list. Nothing is undone; it is already over. | On a failed row. |
| Skip (update) | Write nothing and leave the mod's update mark, so the row says "Skipped, still on the 15 Jul file" and an Update button returns. It is not Ignore, which writes a dismissal and is the user's explicit act on the Updates page and in the update window ([`update-checks.md`](update-checks.md) §4). | On a question, which deletes what the job kept. |
| Cancel | A queued job leaves the line. A downloading job is cancelled and its partial deleted. A job that is unpacking or writing is not cancellable, as today. | A row the control applies to. |
| Cancel all | Does the above for every cancellable job in the run and lets a write in flight finish. | A run with more than one live job. |
| Continue | Start the jobs a halt left queued, once the user has made room. | On a halted run. |

**Closing the app** stops the run: downloads keep their `.part`, waiting jobs lose their answers, and the write in flight is waited for, bounded, by the close guard ([§4.4](#44-what-must-be-true-before-a-run-goes-unwatched)).

## 8. Undo

Undo is on a finished row (the Updates page and the panel); it is not on the card itself.

- **A base update's Undo is a restore of the snapshot the write took** (`restoreSnapshotFlow`): the mod's current folder is saved as a snapshot first, so undoing is itself undoable; the old files are copied back, the sidecar included, and what was added since is removed, "a file added by hand since the snapshot goes too". The record goes back to the old file, so the mod's tracking is as it was. The write removes the folder's update mark, so the job keeps the mark it removed and puts it back on Undo, as the Updates page's own Undo folds verdicts back.
- **A patch layer's Undo is Take out** (`removePatchFlow`), since the patch keeps its displaced originals in `.zzz-mod-manager/replaced/<id>/`. It takes its own snapshot first.
- **A sibling group** has one Undo per folder and no "undo all", since each folder has its own snapshot.
- **A mod switched off and on meanwhile:** the restore deactivates and reactivates as the update did and leaves the on or off state as it is.

**When Undo is not offered.** Undo shows while the job's own snapshot is still the newest snapshot of the mod, the mod's write counter has not moved since the job's write (`modWritesStartedProvider`), and the folder still exists under the same id. Otherwise the row reads plain "Updated" and History is the way. This is the safety rule: a restore removes files added since, so a restore after something else wrote would silently erase that. Undo shows only while the row is in the list.
Its unavailable state is drawn as the plain row, its failure as "Couldn't undo" with the reason (the snapshot was pruned, the folder was renamed, the folder is being written), and the merged "3 mods updated" card counts down to "2 mods updated" when one is undone.

## 9. What stays in the list

**The Updates row outlives its verdict.** The Newer files list is the mods whose check says there is a newer file, and a successful write removes that mark, so the row would leave the moment it reads "Updated · Undo". The page lists the run's jobs as rows in addition to the verdicts, until the user clears the finished ones. A skipped mod keeps its verdict and so its row. The sidebar's Updates count follows the verdicts and drops at once.

**Finished rows stay** until Clear finished or a restart, on the panel and on the page, since a row that left on its own would take the only record of a failure and the only Undo with it. A cancelled job leaves, as a cancelled download does; a skipped update and an undone one stay.

**Update N while a run is going** is allowed. The list counts the mods that are not already in the run and adds them to the line. The button is never disabled by a run.

**A sibling group.** Picks that share an archive are one job. The run writes exactly the mods the user picked; a group member the user did not pick is not written and stays marked. A refusal is that mod's row with its reason: it is not what that folder is built on, it is already current, its folders no longer match, or two mods claim one folder. A member written along with another mod of its archive is skipped at its own turn as already current.

**One mod and Reinstall are a run of one.** The one-mod Update window and the Updates row's, Browse's Update ready and the mod page's Update become a picker whose button enqueues one job and closes; Reinstall keeps its card, which is the consent for its standard facts, and enqueues a job of the kind `reinstall` that stops only for what the card could not say. The board's "1 mod" variant is the same picture with one row. One path remains in the modal flow: the base a dropped patch names (`installNamedBase`), which runs inside an install's finish with its own window and keeps it until it can wait on a job.

## 10. States the board does not draw

Each is specified here in the board's idiom: a row status in the status cell's colour for its kind, a panel row in the Needs your attention group (amber) or the Finished group, a card of the kind named, the same two-button shape. Nothing below needs a new component.

- **The archive's password.** Needs you, "The archive asks for a password. Authors usually put it in the mod description." with Enter password and Open mod page; after a wrong one "That password didn't open the archive." Row: "Needs you · Answer".
- **An unrecorded patch.** Needs you, "This folder holds a patch as well, and nothing records which files came from it. The saved copy still has it." with Update anyway and Skip update. Card: the merged Needs you card.
- **An archive that expands to no folders** (`UpdateLayoutProblem.nothingToInstall`). A failed row, "The file has no mod folder in it. Nothing was changed.", with Remove from the list; no Try again, since the file is what it is.
- **A failure after the download.** "Couldn't unpack the file. It is kept in <folder>." (the archive stays, as an install's does) and "Couldn't save the old file as a snapshot. Nothing was changed.", each a failed row and an Error card with Remove from the list, and no Try again. The transfer reasons are the existing ones: stopped responding at 70 of 233 MB, couldn't reach GameBanana, not enough space (with both figures), the file was removed from GameBanana.
- **Failed part-way.** A copy that fails after the clear leaves the folder half old and half new. The row is amber-red: "The update stopped part-way. The folder is not as it was." with Restore, which is the snapshot restore without the Undo conditions, since this snapshot is the newest by construction. It is not "Nothing was changed", which is true only for a failure before the snapshot. It also halts the run.
- **A halted run.** The queued rows read "Stopped: the disk is full" (or the reason that stopped it) in place of their wait; the panel's Updating heading gains Continue and Cancel all; one Error card, "Updates stopped", says which mod and why and stays until closed.
- **Skip reasons**, each a Skipped row with its reason in place of "still on the 15 Jul file": "being changed by a restore", "no longer in the library", "ignored meanwhile", "already updated along with <mod>", "its folder was renamed".
- **A sibling group's refusals**, each a failed row: "not what this folder is built on", "already current", "its folders no longer match", "<mod> and <mod> claim one folder".
- **A shared archive.** One panel row, with the archive's file, and under it "Updating 3 mods from this file", each mod with its own sub-line as its write comes; each mod's Updates row reads its own phase.
- **A job held by the lookahead cap.** The panel row, in the dimmed Waiting style, reads "<size> · waits for an install to finish" while any job ahead of it is moving, and "<size> · waits for your answers" when every job ahead of it is waiting on a question and nothing will free a place until the user answers. Both are told apart from "downloads next".
- **Undo unavailable or failing.** [§8](#8-undo).
- **Cancel all.** A ghost button at the right of the Updating group's heading, "Cancel all", shown with more than one live job. A write in flight is named "will finish".
- **A space warning.** Before a run starts, when the picked files' sizes plus a snapshot of the largest folder exceed the free space, the Update N footer says so in the amber notice style, "These updates may not fit: 2.1 GB needed, 1.4 GB free." It is a warning and does not disable the button, since exact numbers are not known before the unpack, where the real checks refuse.
- **The run's own line.** "2 of 3 updated" over the Updates page's list while a run is going, and Clear finished beside it once something has ended.
- **Copy and layout:** a speed placeholder in the first second, narrow widths (the status cell drops under the file line below 760px, as the row's buttons do), the light theme and Ukrainian lengths are checked when the rows are built, not drawn here.

## 11. Architecture

**The state is the queue's list of jobs**, with a new intent `DownloadIntent.update` (not `callerHandles`, no cap bypass) carrying an update task: the mod id, the layer, the picked file, the check's published list, the kind (update or reinstall) and the other picked mods of the same archive. Derived providers read it: the job of a mod, a run summary (live, asking, done, failed), and the can-Undo predicate. The Updates row, the panel, the deck, the badge and the Needs you card all read these.

**The work is done by `DownloadQueueHost`**, mounted above the page switcher and below the `Navigator`, which already drains installs, owns the cards and opens questions from its own context. It gains the update drain beside the install drain. Work that outlives a press is owned by the host and providers, never a page.

**The same three-part split as an install**, with the first part in its own lane:
1. `prepareUpdate`, in the unpack lane: unpack, extract, preview (the folder and the siblings), test each question without asking it, stop at the first that needs an answer.
2. `answerUpdateQuestion`, from the row or the card: the window from the host's context; closing keeps the job waiting; Skip declines.
3. `writeUpdate`, in the install lane: re-read the mod, re-preview, `whileWritingMod`, snapshot, wipe, copy, put the patch back, record, prune, the keybind diff into an update report, rescan once.
Neither half takes a `BuildContext`. They take the app's `ProviderContainer` and say nothing in words: what a failure is called belongs to the caller.

**Parts 1 and 3 exist** as `prepareUpdate` (`services/update_apply/update_prepare.dart`) and `writeUpdate` (`update_write.dart`), and the modal flows are their only callers.
`prepareUpdate` unpacks, previews and returns what has to be answered as a value, never asking.
A password or a choice of the archive's folders stops it and it is called again with the answer, and the rest (a patch-shaped download, folders left out, a patch nothing records) are found together once the preview exists.
`writeUpdate` writes a base into the ticked folders or places a patch layer, and returns an `UpdateReport` holding what happened to each folder, the outcome it adds up to and the update marks it removed.
A patch write removes no marks and leaves the folder's verdict to the caller.
The sub-steps of §2 come from the applier's `onStep`.
Part 2, the re-read and re-preview at the write, and the questions' queue are not built.

**The report** (`UpdateReport`) is on the finished job: files written, dropped and restored, keybind changes, the snapshot id per folder, the mark the write removed (for Undo), the kind, and the folders of the archive left out. It is session state, like the verdicts.

**Seams for tests.** A stage seam, as `ArchiveInstaller` and `InstallQuestionAsker` are for installs, so the host's sequencing is tested without 7z, a mods folder or the network. The lane policy is a pure function with tests for D in 1 to 4, the lookahead cap (including the always-admit-one rule), U and I, in `test/download/queue_policy_test.dart`. `prepareUpdate` and `writeUpdate` run against real temp libraries, as `update_applier_test.dart` does.

| Piece | Fate |
|---|---|
| `UpdateApplier` (preview, `applyBaseThenPatch`, `applyPatchInto`, snapshots, the patch put back) and the files beside it (`update_layout`, `sibling_group`, `update_write_route`, `update_target`, `keybind_changes`, `dropped_files`) | Kept. One additive change: a step callback on the write. |
| `applyUpdateFlow` (about 460 lines of orchestration with its dialogs) | Split into `prepareUpdate` and `writeUpdate`; what remains is the `installNamedBase` path. |
| `applyPatchUpdateFlow` | Becomes the patch branch of `writeUpdate`, with no dialogs. |
| `applyModUpdate`, `updateWriteRoute` | The route decision is kept, read at enqueue and again at the write. |
| `runModUpdates`, `UpdateRunPosition`, the Next label, the "Updates stopped" note, `libraryUpdateRunProvider`, `ModUpdater`, `UpdateFlowOutcome.stopsRun` | Removed. The skip reasons become row statuses. |
| `update_confirm_dialog.dart`, `update_progress_dialog.dart`, `update_result_dialog.dart`, `download_with_progress.dart`, `ProgressModal` | Removed, except what `installNamedBase` needs. |
| `UpdateModal`, `UpdatePick`, `LibraryActions.updateMods`, `ModUpdateDialog`, `reinstall_dialog.dart` | Kept as pickers and consent cards. `updateMods` and each Update button enqueue. |
| `DownloadQueue`, `queue_policy.dart` | Changed: the intent, the per-intent pools, the lookahead cap, the order of work, the update states and outcomes, retained skipped and undone rows, refusal of a second job for a mod. |
| `DownloadsPanel`, `DownloadQueueHost`, the Updates page | Changed as §5 says. |
| `SnapshotService`, `ArchiveService`, `ConfigService`, `main.dart`'s close | Changed by the safeguards of §4.4. |
| `notification_overlay.dart` | Kept. |

## 12. The slices

Each slice ends green (tests, analyzer, docs, changelog, both l10n files, no `fontSize:` or `Color(0x…)` literals) and is reviewable alone. The intermediate slices need not be releasable, and none may write a patch-shaped file by the wipe path.

| # | Slice | Size | Risk |
|---|---|---|---|
| U0 | This note, and the board with the Update contexts of the patch and folders windows, landed in `design/v3/` and rendered. | S | Low. The risk is in the product decisions of §14. |
| U1 | The UI-free split: `prepareUpdate`, `writeUpdate`, the question type and the report out of `applyUpdateFlow` and `applyPatchUpdateFlow`, the modal flow as their only caller and behaving as today; the applier's step callback; a test that pins what the wipe does to a patch-shaped download. | M to L | High. This is the code whose order is the safety argument; the existing applier, drop and confirm tests pass unchanged. |
| U2 | The safeguards of §4.4 that exist outside the run: the snapshot space check, deleting a partial snapshot on a failed capture, the unpack's space check counting what is in flight and waiting, the atomic and serialised `config.json` write, the close guard. | M | Medium. Each is small and touches code every write uses. |
| U3 | Lanes in the queue: the intent, the update task, D, L, U and I as constants, the order of work, the skipped and undone outcomes, the refusal of a second job for a layer, one write pipeline per folder (a second job of a folder does not start its finish until the first has ended), the skip of a folder marked as being written elsewhere, the one job for a shared archive, the halt, and the update intent excluded from `pausable`. Pure policy tests for D in 1 to 4 and for L: the count, the size, the always-admit-one rule and a 1.2 GB file after smaller ones. No UI. | M | Medium. The admission, the host's pick, the row actions and the aggregates change together. |
| U4 | The smallest vertical piece: Update N runs on screen, asking only the password and the folder pick. The rows, the panel, the deck and the finished card show it. A job that needs any other decision waits as Needs you with only Skip, and a patch-shaped file is held and never written. The modal loop and its parts are removed here, `libraryUpdateRunProvider` with it, so Update N is no longer disabled by a run, and the per-folder pipeline and the skip are in use. | L | Medium to high: the first time engine, queue, host, three surfaces and the strings meet. |
| U5 | `PatchModal` and `FoldersModal` with their Update contexts (the board holds both), the unrecorded-patch question, the merged Needs you card with Answer, answering later, Skip, and the patch branch with the base's dismissal. | M to L | Medium. The windows are bounded; the layer write reuses the patch install. |
| U6 | Undo and the finished detail: the restore and Take out as Undo, the predicate, the mark put back, the hotkey list, the dropped and left-out lines. | M | Medium. A restore removes files added since, so the predicate decides the safety. |
| U7 | One mod and Reinstall on the engine; the confirm, progress and result windows and the wait modal are deleted. | M | Low to medium: large deletions and test churn. |
| U8 | Cancel, Try again and Continue: per-row Cancel, Cancel all, the Try again gate, the space warning. | S to M | Low to medium. |
| U9 | The measurement of §4.5 and any change of the constants it supports, with the tests and the Windows session an install limit above one needs. | S for a download or unpack limit, M to L for installs | Downloads low to medium; installs high. |

The run does not reach a user before U2 is built.

## 13. What changes in the docs and rules when the code lands

These describe what is built today and are not rewritten until the slice that lands the code. Each is changed in that slice, to say what the run does.

- **`applying-updates.md` §7**, "Updating several mods": its statements that "every update is asked about when its turn comes", that "the run keeps every question and spares only the walk back to the page for each mod", that "none opens while a run is under way", that "declining anywhere ends the run", the stopped note and its count, and the list "What the run does not do" ("It does not fetch archives ahead of their turns", "It does not combine the confirmations, because each folder has its own preview, its own patch put back and its own keybinds, and each needs its own consent", "It does not run in the background or with nobody at the keyboard"). §6, "The order", moves from a window's sequence to a job's three parts; the patch warning's text, which says only the `.ini` files are replaced, goes with the confirmation. **§1**, "The flows outlive the window that started them", describes `applyUpdateFlow` and `applyPatchUpdateFlow` reading the app's container so that a closed window leaves a write to finish; it changes in U4 and U7, where the flows and their windows go, and the rule it states (nothing after the write reads a widget's `ref`) carries into `prepareUpdate` and `writeUpdate`, which take no `BuildContext`.
- **The "user present" rule**, in `mod_manager_flutter/CLAUDE.md`, "Claims the UI may make": "No update is applied without the user present. Automatic updating is refused rather than unbuilt; checking is automatable and opt-in ([`applying-updates.md`](../docs/applying-updates.md) §7, [`update-checks.md`](../docs/update-checks.md) §5.1)." The root `CLAUDE.md` does not hold it. The sentence is also in `applying-updates.md` §7 ("No update is ever applied without the user present") and in `origin-tracking.md` §1 ("No update is applied without the user present, and that is refused rather than unbuilt"). The replacement says that an update is applied only by a run the user started, from a press that names the mods and the files the user picked, and that automatic updating, with no press, is still refused.
- **`downloads.md`:** §7 (the pools and the lookahead cap, and the foreground bypass that update jobs no longer use), §9 (the wait modal goes, and update cards), §10 (update questions, and the close guard against "no close anyway?"), §13 (the groups, Updating rows, Undo and the footer, and "Update downloads", which is a flow's window; a failed update row moves out of Finished into Needs your attention, with the existing labels, Try again and Remove from the list, where a failed download stays as it is), §14 (the badge counts update jobs), §4.1 (the unpack's space check counts what is in flight and waiting, and the snapshot's check is new).
- **`library-screen.md`:** §13 (the confirm, progress, result and wait dialogs leave the list; the update dialog's Update enqueues), §15 (History's restore is Undo's mechanism), §16 "The header" (Update N "is disabled, with a tooltip, while a run of updates is under way (`libraryUpdateRunProvider`)"; with a run in the background it stays pressable and adds the mods not already in the run, changed in U4), §17 (the row's status cell, run rows outliving the verdict, Update N during a run).
- **`notifications.md`:** §4 (the Needs you card gains Answer) and §6 (update cards in their own deck, the merged finished card).
- **`origin-tracking.md` §10** where a patch is added by an update, and **`update-checks.md` §4** for the base layer's dismissal after "Patch added".
- **`applying-updates.md` §5**, snapshots: a capture that fails leaves nothing behind, and a write needs room for its snapshot. **`configuration.md`**: `config.json` is written atomically.
- `mod_manager_flutter/CLAUDE.md`'s table and `docs/README.md` list this note once it is read for the code.
- `docs/v3-rework-plan.md` holds the phase. `CHANGELOG.md` gets one Added line, net against the last published release, in the slice that lands the first visible change.

## 14. Decisions settled and decisions not yet confirmed

### Settled by the user

A. **A run applies updates without a per-mod confirmation.** The press of Update N, the picked files and the footer text are the consent. The standard facts (a snapshot, the replaced contents, hand edits and rebound keys) are in the Update N and one-mod Update footers. The loss cases stop and ask (an unrecorded patch, a patch-shaped file, an unknown or changed layout, an archive password). The hotkey changes and the dropped files show on the finished row.
B. **Concurrency is built as parameters held as constants, with no setting, until measured.** What the numbers are is the recommendation in item 11 below.
C. **The update-run slices start now and the tracking window (`TrackingModal`) waits.** It is independent of them.

### Taken from the recommendation, not yet confirmed by the user

1. **The patch question's default:** "Put it on top of this mod" preselected (the board's), nothing preselected in the other list, and a dismissal recorded on the base layer so the patch's file is not offered again ([§6](#6-questions)).
2. **What Undo does and for how long:** a snapshot restore for a base update, Take out for a patch layer, per mod, only while the job's snapshot is the newest and nothing else has written to the mod, and only while the row is in the list ([§8](#8-undo)).
3. **Needs you on the notification stack:** one merged card with an added Answer action, against the board's card per question ([§6](#6-questions)).
4. **One mod and Reinstall as a run of one**, everything except the base a dropped patch names ([§9](#9-what-stays-in-the-list)).
5. **An unrecorded patch stays a question**, with Update anyway and Skip.
6. **Update N while a run is going** is allowed, adds to the line and counts only mods not already in it.
7. **What Skip means:** it leaves the update mark, the row says so for the session and an Update button returns; it is not Ignore.
8. **Closing the app during a write:** closing waits, bounded, for a write in flight, and never for downloads or questions ([§4.4](#44-what-must-be-true-before-a-run-goes-unwatched)).
9. **How long finished rows stay:** until Clear finished or a restart, on the panel and on the page.
10. **Sibling members the user did not pick** are not written by the run and stay marked.
11. **The concurrency values** of [§4.1](#41-the-model): three update downloads in a pool of their own, a lookahead of at most three archives or 1 GB (always admitting one), one unpack at a time with one unpacked archive waiting, one install chain with prune on it, smallest first with a stalled file to the end, and a waiting question keeping its place under the cap. They are the recommended default, pending the user's confirmation.
12. **A halt on a disk-wide failure**, with Continue and Cancel all, reported by one Error card that stays ([§4.4](#44-what-must-be-true-before-a-run-goes-unwatched)).
13. **Update jobs are not pausable in the first build.** A download the user started from Browse can be paused; an update run has Cancel, and Pause is added only if wanted. U3 excludes the update intent from the queue's `pausable` ([§2](#2-the-phases-and-what-each-means-in-the-app)).

Choices made in this note that neither the plan nor the user settled: update jobs deal their cards into a deck of their own; the panel's Updating heading drops "one download at a time"; the space warning, the held-by-the-cap row and the halted run are specified in §10 in the board's idiom; the safeguards are a slice of their own (U2).

## 15. Not verified

- That a failed capture leaves a partial snapshot that History lists as the newest of its mod. This is from reading `capture` and `_read`; not run.
- That a patch added by an update leaves the base layer listing that file as newer, and that the base layer's `dismissableUpTo` silences it without also silencing a newer base file the user would want to hear about.
- That `SnapshotService.prune` is safe against a capture in flight in another group, that two updates on different folders race on nothing in `ModManagerService`, and that links and One at a time's turn-offs come out right with two writes at once ([§4.3](#43-stage-by-stage-what-the-code-allows-today)).
- Three concurrent transfers of different files, and anything on Windows: the queue, a deactivate against a held file, and any concurrency.
- The numbers behind the concurrency recommendation are one session's sampling of GameBanana (`gamebanana-api.md` §8) and are not settled properties of the service.
