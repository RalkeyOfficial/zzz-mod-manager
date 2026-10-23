# Downloads — fetching mod archives

**Scope:** `services/download/`, which fetches archives into `<appData>/downloads`, resumably — the isolate pump, resume policy, backpressure, the stall timeout — plus the **queue** above it, Pause, the panel that shows it, the install questions that wait in that panel, and archive passwords.

Separate from the JSON client (`services/gamebanana/`) because it needs streamed
bodies, byte ranges and socket backpressure. [`gamebanana-api.md`](gamebanana-api.md)
§8 has the remote-side measurements that shape it.

Not in scope: what an install does with the archive once it has landed
([`marketplace.md`](marketplace.md) §5), or how an update writes one over an
existing mod ([`applying-updates.md`](applying-updates.md)).

---

## 1. The shape

`DownloadService` — reached via `downloadServiceProvider`, which lives in
`download_queue.dart` beside its only consumer rather than in the
`state_providers.dart` registry, so the two do not import each other. Returns a
`DownloadHandle` (progress stream, `done` future, `cancel()`). **Every *decision*
lives here**; only the pump below does not.

`DownloadPump` / `PumpSession` is the seam, and it is **two-phase** because the
service must judge status and headers with `ResumePolicy` *before* a byte is
written. `IsolateDownloadPump` is production (one short-lived worker per
connection, building its own `IoDownloadTransport` so there is no second HTTP
config to drift); `InlineDownloadPump` is what every test gets through the
`transport:` argument, and the fallback if a spawn ever fails.

## 2. The pump runs on a spawned isolate, and that is worth 3 → 17 MB/s

On the root isolate the event loop *is* the Flutter engine's UI task runner, and
every socket read event costs ~2.3 ms there. Chunks arrive as ~8158-byte TLS
records — not something we choose, and not something a slow consumer makes larger
— so `8158 B ÷ 2.7 ms ≈ 3.0 MB/s` is a hard ceiling regardless of the network.
Our own callback is ~1% of wall clock, so there is nothing to optimise inside it.

Ruled out by measurement and not worth re-investigating: the backpressure pauses,
in-stream md5, debug-vs-release, the filesystem, the `User-Agent`, frame rendering
and the UI layer. Windows is expected to behave the same way — same engine
architecture — but that is **inferred, not measured**.

### The measurements

Release build, real CDN, four arms interleaved with the order rotated, six rounds
on the 27 MB test file (mod `700727`, file `1777422`):

| arm | body only | ms/chunk |
|---|---|---|
| `DownloadService`, **root isolate** | 2.84–2.97 MB/s | **2.62–2.74** |
| bare read-and-write loop, spawned | 12.5–16.2 MB/s | 0.48–0.62 |
| the same plus md5 and the flush brake | 8.9–16.6 MB/s | 0.47–0.87 |
| `DownloadService`, **spawned** | 8.5–14.2 MB/s | 0.55–0.91 |

Three things to read off it. The root-isolate row is *pinned* — six samples inside
0.13 MB/s while every spawned row swings by a factor of two — and that
consistency, not the absolute figure, is what identifies a fixed scheduling cost
rather than a slow network. The three spawned rows **overlap completely**, so
neither the in-stream md5 nor the backpressure brake nor the rest of the service
costs anything measurable; a single bad sample from any of them is the node, and
pooling fewer than ~5 rounds will mislead you. ~5× is the honest figure for the
**transfer**.

### End to end a user sees less, and the difference is not ours

Every arm above also paid a rock-steady **0.73–0.98 s of setup** — DNS plus three
TLS handshakes across GameBanana's two redirect hops, before a byte moves. On the
27 MB median-ish mod that turns ~14.5 MB/s of transfer into ~10 MB/s of wall
clock, i.e. ~3.9× rather than ~5×; on the 1.24 GB tail file it rounds to nothing.

Every figure in the table is **body only**, timed from the first byte. Comparing
one against a wall-clock figure is comparing two different quantities, which is how
this section first got written wrong.

### What the worker owns

**The worker owns the file writes, and reports a counter.** Forwarding chunks over
the port would pay the very ~2.3 ms cost being escaped — an elaborate way to change
nothing, while still looking correct, because the file and the md5 would come out
right. Progress is posted every 200 ms.

Consequently the stall timer resets only on an **increase**: the worker's timer
fires whether or not anything moved. It is also stopped on `bodyEnded`, *before*
the final flush — flushing a gigabyte takes real time, and a download that already
finished must not be able to time out.

**Considered and rejected: batching into ~1 MB blocks in the worker** while keeping
file I/O on the main isolate. It would capture most of the win (~1240 events ×
2.3 ms ≈ 2.9 s on a 1.24 GB file) for far less surgery. It loses on one decisive
point: it replaces `sub.pause(sink.flush())` — a proven mechanism whose
backpressure reaches the socket — with a hand-rolled credit window between two
isolates, whose failure mode is the invisible one below.

## 3. Backpressure is load-bearing, and fails invisibly on fast storage

A reader that pipes the response body to disk without awaiting the write and
without pausing the subscription buffers whatever the disk can't keep up with.

Measured against local disk at 20 MB/s it made no difference — peak RSS identical
at 217 MB either way — but against a deliberately slow consumer the two diverged
(**+57 MB vs +15 MB** above baseline). With files reaching 1.24 GB and CDN nodes
that serve at 0.08 MB/s, that is a real exposure on slow or contended storage.

It lives inside `pump_body.dart`'s `pumpResponseToFile`, which **both** pumps call
— but a shared function is only half the guard. Teardown, error fidelity and report
cadence differ between them and sit outside it, so
`test/download/pump_contract_test.dart` runs one body against both against a
loopback `HttpServer`. That is the mechanism; the shared function is the hope. (It
has already earned its keep: an `IOSink` refuses a second `flush()` while the
backpressure one is still in flight, and only the inline arm hit it.)

## 4. The transport and the resume policy

`DownloadTransport` / `IoDownloadTransport` — the network seam under the pump, and
the app's only remaining `dart:io HttpClient`. Two settings are load-bearing:
`autoUncompress = false` (or `Content-Length` and every range offset lies), and the
deliberate **absence** of `badCertificateCallback`. Because the worker constructs
its own, the isolate path cannot be pointed at a self-signed server — so its TLS
behaviour is deliberately untested rather than tested behind a hole in that rule.

`resume_policy.dart` — pure, and where the subtle bugs live. In particular **a
`200` answering a ranged request means *restart***: appending it would concatenate
two copies into a corrupt archive that still looks plausible.

## 4.1 The space preflights

Every write an install makes is refused up front if it provably will not fit, and
there are three of them on three different volumes: the transfer into
`<appData>/downloads`, the unpack into a temp directory, the copy into the mods
folder. None of the three is ever a guess — every number is read or measured
rather than estimated, which is the only reason a refusal is allowed at all.

### The transfer

A transfer is **refused before it opens a connection** when the volume holding
`<appData>/downloads` provably cannot hold what is still to be written. The user
hears "2.1 GB needed, 700 MB free" while looking at the button they pressed,
rather than a write error after twenty minutes — and `DownloadWriteException`,
which is what running out mid-transfer raises, says nothing about space at all.

**This is allowed to refuse only because the number is exact.** GameBanana's
`_nFilesize` is the eventual `Content-Length` to the byte
([`gamebanana-api.md`](gamebanana-api.md)), so what a transfer needs is that
minus whatever a partial already holds. Three things therefore skip the check
entirely, and none of them is a gap: an unknown free space, a file of unknown
size, and a resume that needs nothing. **Refusing a download that would have fit
is the one outcome worse than the failure this prevents**, so anything short of
certainty runs the transfer.

**It counts every transfer in flight, not just the one starting.** Two run at a
time into the same directory, so two 900 MB archives on a volume with 1 GB free
are each individually fine and together are not. A running transfer's remaining
bytes are already committed to the volume, so they are part of what the next one
has to fit beside — which is why the requirement in the message can exceed the
size of the file being asked for.

Free space itself comes from `PlatformService.freeSpaceBytes`, because Dart has
no portable API for it and the two platforms answer by different means: Linux
parses `df -kP` (POSIX flags, so busybox and toybox answer too, where
`--output=avail` is coreutils-only), Windows calls `GetDiskFreeSpaceExW` through
FFI. Windows has no `df` and no supported command that answers this — `wmic` is
gone from current releases and `dir` prints the number as localized prose — while
PowerShell would cost half a second of process startup per question, paid before
every download in a queue. The FFI call reads
`lpFreeBytesAvailableToCaller` rather than the total free bytes: a disk quota
reduces the former, and the write only gets what the former promises.

### The unpack

A separate question on a **different volume**, which is the part worth knowing:
the archive sits in `<appData>/downloads` and is unpacked into a temp directory,
which on most Linux desktops is a **tmpfs** — not the same disk at all, and
filling it fills memory. `ArchiveService.extractArchive` owns the check because
it owns the write, so an update applies through it too.

**The size is read from the archive without unpacking it, and both formats are
cheap enough to ask every time.** A zip carries every entry's uncompressed size
in its central directory, which `InputFileStream` reaches with a seek: **a 360 MB
zip is sized in 8 ms** with none of it read into memory. A rar or 7z is listed by
the same 7-Zip that will extract it — `7z l -slt` over a 360 MB `.7z` **returns
in 2 ms**, so what it costs is one process spawn. `-slt`'s one-field-per-line
output is parseable where the default table is column-aligned prose with a
localized summary. Of the three `Size` fields that output carries, only the bare
one counts: `Packed Size` is what the archive already holds and `Physical Size`
is the archive file itself.

**A listing that does not arrive whole answers nothing.** `-slt` prints a block
per entry, so output grows with file count — a few hundred files is past any cap
meant for a diagnostic banner, and a cut listing still parses, still exits 0 and
sums to less than the archive holds. That number would say an install fits when
it does not, which is the failure this check exists to prevent, so the probe
reports truncation (`ProbeResult.truncated`) and a truncated listing is treated
as an unknown size. The cap it runs under is 32 MB, past any real mod.

A refusal writes nothing, keeps the archive, and names both figures — the archive
is the way out, so an install that could not unpack is retried by clearing space
rather than by downloading again.

**An unpack that fails deletes the `zzz_archive_extract_*` directory it made**, whatever it failed at: the space check, a password, the unpack itself, an archive with no mod folder in it, or an error.
A destination the caller passed in is the caller's and is left alone.
On success the directory is handed to the caller (`ArchiveExtractionResult.extractionRoot`), which deletes the whole of it once done with the folders, never the parent of a folder: an archive laid out like ZZMI's folder comes out as `Mods/<mod>`, a level below it.

### The copy into the library

The third write, on a third volume, and the only one on the user's own mod disk.
`ModManagerService.importMods` and `importCombinedMod` refuse before copying, so
a full library volume leaves nothing behind rather than a folder that looks
installed and is missing files — which the scan would then badge and offer to
update.

**The size is measured, not read from a header.** The files are already unpacked
in the temp directory, so the requirement is a walk of exactly what the copy is
about to write. Only the folders that *will* be copied count: one the library
already has is skipped, and counting it would refuse an install over space
nothing was going to use.

**An import returns an `ImportResult`, and that is what a refusal needs.** A null
failure with nothing imported means a genuine duplicate — the one reason an
import installs nothing that is not a failure. A full disk, an unwritable
library and an unset mods folder each carry their own `ImportFailure` and their
own message (`import_failure_message.dart`), so none of them can be reported as
a duplicate, which would send the user looking for a mod that was never
installed.

## 5. The timeout is a stall timeout, never a total duration

A legitimate transfer over a degraded CDN node runs ~25 minutes and must be allowed
to. The progress UI is built for the same reality: a rate and an ETA rather than
just a bar, cancellable and resumable throughout.

## 6. Hashing

`services/archive_hash.dart` — md5 for archive fingerprinting. Free during a
download (hashed in-stream), one extra read on manual import. A **matching key,
never an integrity claim** — never render a match as "verified".

## 7. The queue

`DownloadQueue` (`download_queue.dart`, reached via `downloadQueueProvider`) owns
every transfer the app makes; `queue_policy.dart` holds the decisions, pure. The
download **service** below it is unchanged and still knows nothing about queues.

The queue exists because the tail measured in
[`gamebanana-api.md`](gamebanana-api.md) §8 is not a hypothetical. Archives reach
1.24 GB and a degraded node stretches one to twenty-five minutes, which is a long
time to hold the whole app behind a modal barrier.

**Two transfers at once, and the reason is not throughput.**
`gamebanana-api.md` §8 measured that node assignment is deterministic per file and
that more connections to *one* file do not make it arrive faster, so no claim is
made that concurrency speeds anything up. What it buys is that a file on a
degraded node does not hold up everything queued behind it. Two is the smallest
number that delivers that; higher was not measured, so it was not chosen — and
each connection costs a spawned isolate (§2).

**A job is de-duplicated on the GameBanana file id, and that is correctness
rather than politeness.** Two runs of one file would write the same `.part` and
the same resume record in one shared directory, appending two streams into a
corrupt archive that still looks plausible — the same failure `resume_policy.dart`
exists to prevent, reached around the back. Only non-terminal jobs count, so
pressing Download again after a failure is a retry rather than a refused
duplicate.

**`retry` goes through the same gate**, and that is not belt-and-braces. A failed
row stays in the panel by design, so the user can perfectly well press Download
again — leaving two rows with the same mod name — and then press Retry on the
stale one. Without the check that is a second transfer of a file already in
flight, which is exactly what the rule above exists to prevent.

**A foreground job bypasses the cap on the way in, and counts against it afterwards.** An update's download (§9) is a wait the user sits in front of, for a file they asked for now,
so parked behind two background transfers its window would say it is waiting for a slot until a download it has nothing to do with ended.
Admitting it closes the door behind it rather than raising the ceiling, so the worst case is one over the cap and only while a dialog is open.

**Nothing is persisted.** A queue restored from disk would start re-fetching on
launch. The partials in `<appData>/downloads` are already the durable half: an
interrupted job is resumed by asking for it again.

Not verified against the live API: two large archives arriving while the user browses, and an install running while a second transfer is still coming in.
Not verified on Windows, for the queue or the transfer beneath it.

## 8. Where a download ends, and who finishes it

The queue moves bytes and stops. Unpacking, importing and reporting need
localized strings and can raise a dialog, and a `Notifier` has neither — so a
finished transfer parks in `downloaded` and **`DownloadQueueHost`** takes it from
there. `DownloadIntent`, fixed when the user presses the button, says which of
three things happens:

| intent | who finishes it |
|---|---|
| `install` | the host, through `dialogs/install_archive_flow.dart` (§10) |
| `keepArchive` | the host — one notification naming the path |
| `callerHandles` | the caller awaiting `completionOf`, i.e. `applyUpdateFlow`, which ends the job itself (§13) |

**What else a job carries is fixed at the same press**, for the same reason: the page that knew may be gone when the bytes land. Besides the file and the mod page (for the origin block and the autofill), an install job carries `characterId`, the character the mod page showed, which is the GameBanana category's, Unassigned when it names none, or the user's Install for pick, and the host hands it to the import as the character to file every new mod under; and `turnOn`, the mod page's Turn on after installing, after which the host turns each new mod on through `ApiService.enableMod` ([`marketplace.md`](marketplace.md) §5).
A retry keeps both. Installing a paused file again resumes its job with that press's intent, character and Turn on (`DownloadJob.pressedAgain`, §11), since the latest press is what the user asked for. A `keepArchive` job never turns anything on.

**Where the host is mounted is the whole design.** It wraps the tab switcher in
`main.dart`: the sidebar's pages are keyed `AnimatedSwitcher` children with no
keep-alive and are *disposed* as the user moves between them, so an install owned
by `MarketplaceScreen` dies on the first tab switch with the archive already on
disk. Owning it there is safe only behind a modal dialog that makes walking away
impossible, and removing that barrier is the whole point of a queue. It must also sit **below** the `Navigator`, unlike
`NotificationHost`, because `showDialog` needs one as an ancestor.

**An install that ends settles its job whether or not the host is still mounted**, through the app's container rather than the host's own `ref`: the queue outlives the widget, and a job left `installing` would hold the install slot and the Storage reclaim's gate for good.
Only what needs the host is skipped once it is gone, Turn on after installing and the result's card, so new mods stay installed and off.

**One install at a time.** Installing runs `7z` and writes into the mods folder through a service held as a singleton, and two of those interleaving would race on both. An install that needs an answer does not hold the slot while it waits for one (§10). Turn on after installing is part of the install, so the slot stays held while it waits for a running bulk action of the All mods table to end ([`marketplace.md`](marketplace.md) §5).

### The filename, and why it must not reach the mod

**A finished download never overwrites**, so a name already taken becomes
`mod (2).rar`, then `mod (3).rar`. That is not tidiness: two mods routinely
publish `main.zip`, and the queue transfers concurrently while installing one at a
time — so promoting over the file already there would make one install extract
another mod's bytes. It cannot tell the two apart at that moment, so it never
tries.

**But that name becomes the mod's name.** An archive with no folder inside it — a
flat pile of files — is wrapped in a folder named after the archive
(`ArchiveService`), and it is also the default name in the folder picker. So a
leftover archive would silently rename the user's mod to
`pulchra_bottom_heavy_reworked (2)`.

The install therefore works from the name the download **asked for** (`DownloadResult.requestedName` → `runArchiveInstall` → `extractArchive`'s `nameHint`) rather than the name on disk.
Exact, not a heuristic: stripping a trailing ` (n)` would rename a mod genuinely called `Ellen (2024)`. An archive nobody renamed — dragged in, or picked from a file dialog — passes no hint and keeps its own name.

### Completed archives are swept at launch

An install deletes the archive once it is unpacked, and a cancel or a Don't install deletes the archive it calls off. What is left in the directory is an archive whose install never *ran*: extraction failed and it was kept so the user could unpack it by hand, the mods path was unset, the app closed between the download landing and the install starting or while the archive waited for its password (§10), or the delete itself failed and was only logged.

Nothing swept those — `sweep` only ever looked at `.part` files and their records
— so the directory grew forever, and every leftover was a future collision.
`sweepCompleted` runs once at launch and deletes every complete archive.

**Launch is the only safe moment.** Nothing is queued or installing yet, so every
complete file is by definition finished with; run mid-session it would delete the
archive of an install still in progress. It is deliberately not folded into the
lazy `sweep` that runs on the first download of a session, for exactly that
reason. A `.part` and its record survive it — they are a resumable download.

One consequence to keep in mind: an archive kept because extraction failed is
gone after a restart. The message names its path, and that path is good for the
rest of the session.

## 9. What the user sees

Three surfaces, and they answer different questions. The **wait modal** says *you are waiting for this, and it is still going*; the **notification** says *something is happening in the background and here is how fast*; the **panel** says *what, exactly, and let me change it*. Only an update has a wait modal: an install runs in the background from the press to its result (§10).

### The wait modal: one window from the press to the question

`ProgressModal` covers the whole wait a foreground transfer puts the user in,
and it has **two phases and one window**:

1. the transfer — a rate and an ETA rather than only a bar, for the reason in
   [§5](#5-the-timeout-is-a-stall-timeout-never-a-total-duration): over a wait
   that can run 25 minutes a bare percentage does not answer the only question
   the user has;
2. **preparing** — unpacking the archive, and reading both it and the folder it
   is going into.

**Why the second phase exists.** A modal that closes is the same signal the user
gets when a job has *finished*, so closing it at the end of the transfer and
opening a confirmation seconds later reads as "that's done" followed by an
interruption. The wait between them is not short: extraction is the slow part
and it scales with the archive, which reaches 1.24 GB
([`gamebanana-api.md`](gamebanana-api.md) §8). There are also **two** slow steps
in a row, so a spinner bolted onto either still leaves a blank screen for the
other — which is why this is one window across the wait rather than a second
dialog after the first.

**Ownership is split, because neither side can do it alone.** Only the download
knows which queue job Cancel belongs to; only the caller knows when its question
is ready. So `downloadFileWithProgress` hands its closer to a `ProgressHold`
rather than using it, and the caller releases it immediately before the next
thing the user sees. Without a hold the download closes its own modal, for a caller where nothing follows the transfer.

**The preparing phase is not cancellable, and the button goes rather than being
disabled.** Unpacking cannot be stopped half way and leave anything usable, and
a dead control invites the press that proves it is dead. The bar is
indeterminate for the same kind of reason: extraction reports no progress, and a
bar pretending to know how far along it is would be worse than not saying.

**The install path has no wait modal.** Its transfer ran in the background queue ([§8](#8-where-a-download-ends-and-who-finishes-it)), and its unpack runs behind the download's Working card, since a window that opens by itself lands over whatever the user is doing minutes after they pressed Install (§10).

### The Working progress notification

Raised by `DownloadQueueHost` and kept in step with the queue. A backgrounded
transfer has no modal to *be* its progress report, and a download nobody can see
is one the user assumes failed — so the report sits in the foreground without
blocking it.

- **One card per download, dealt into one deck.** Every download's card joins the `downloads` deck (`notifications.md` §5), which the stack draws as one slot: the oldest download's card in front, "2 more downloading" as its last line, and the edges of up to two more above it. So a five-mod queue never takes every visible slot and folds an error under "+N more", and the notification doesn't change shape with the count: one download and five look the same. Hovering the deck spreads it into every download's card; the panel keeps the per-file view, speeds included.
- **A Working card, because the end of a download is an event rather than a moment.** It has no clock; its bar is that download's own share (`aggregateProgress` of the one job), and a sweep while its size is unknown.
  As the canvas draws it, the **title** names the download and stays ("Installing Victorian Ballgown", "Downloading …" for one kept as an archive or written by the update flow), and the **body** says where it is: "Waiting for a free slot", "Connecting...", "Downloading · 64.0 MB of 214.0 MB", then "Unpacking". Its portrait is the download's character.
- **Each download's card turns into its result as it lands**, without waiting for the rest of the queue. Its "Mod installed" or saved archive (with Open folder) takes the card over in place and is dealt on top of the deck, leaving on its own clock while the next card comes up; installs finishing in turn are counted on one card, "2 mods installed".
  What an install must still say, such as a patch or a missing `.ini`, is its own card beside the deck, raised before the result.
- **A failure leaves the deck as its own card.** The download's card becomes its Error and the stack shows it beside the deck, since a failure has to be read. A warning or a note an install ends in (an archive with no mod folder, every folder already in the library) leaves the same way, and so does a download that waits for an answer, as the one Needs you card for every waiting download (§10, `notifications.md` §4).
- **A failed transfer is said on a card.** "Couldn't download the mod" with the download's name, Try again when its panel row would offer a retry, and Open Downloads for the reason, which the row holds. The download's own card becomes it.
  Only a download that had a card: one that failed as it was queued (a link that won't parse) is reported by the button that queued it, a download the update flow owns by that flow, and an install failure, Open Downloads beside it, where the install ran.
- **A download that leaves the queue without a result takes its card with it**: one cancelled, and one the update flow owns once its bytes are handed over, since that flow reports it. A paused download's card goes too, and Resume raises a new one (§11).
- **No speed or time left on the card.** The canvas puts the bytes under the title and the share in the bar; the rate and the ETA are in the panel's rows.
- **Hiding it sticks.** Its close button reads "Hide": on the deck at rest it hides every download in the deck, and spread it hides that one. A card is *raised* when its download becomes active and merely *updated* thereafter.
  A card re-raised on the next progress tick would override the user; hiding therefore holds for the downloads hidden, while a new download raises its own card, which is itself a request to be told about it.
  A hidden card still comes back as its result, since hiding the progress never hides the outcome; a new download joining the deck changes nothing about the ones hidden.

This is also why the stack's backstop drops the oldest card **with a clock** rather than simply the oldest: an update to a Working card that has been dropped is a no-op, so dropping one silently throws away the only report of the work it was tracking. See `notifications.md` §7.

### The panel

`DownloadsNavItem`, the sidebar's **Downloads** row, opening `DownloadsPanel`, the side panel of §13, as a route on the root `Navigator` (`DownloadsPanelRoute`). The row is always there, under Browse, and its badge is §14's.
Overall progress is the Working notifications' job, not the row's. In the sidebar rather than on a page because a transfer outlives the page that started it, so it cannot belong to one.
A card's Open Downloads opens the panel through `downloadsPanelRequestProvider`, which the row answers, and Open mod page closes it through `downloadsPanelCloseRequestProvider`, which the panel answers (§13).

- **Finished rows stay until they are cleared.** A row that vanished on its own
  would take the only record of a failure with it.
- **Up to two controls per row**, chosen by `rowActions` per §13's table, and none at all while an install is between its unpack and its import, where there is no safe stopping point to offer. It reads the **whole queue**, not just the row, because two of its answers depend on it — a failure another job is already re-fetching offers no retry (`DownloadQueue.retry` would refuse it, and a button that silently does nothing is worse than a row that reads as history), and neither does an **install** failure, where the bytes were fine and re-fetching them hits the same `7z` error.
- **An install failure says what actually failed.** It travels as an
  `InstallFailure` rather than a bare string, so the row carries the install's
  own message instead of "Download failed" — which would name the one half that
  worked.
- **`aggregateProgress` reports bytes, not jobs** — a 1.2 GB archive and a 4 MB one are not half the work each — and goes indeterminate rather than inventing a number while any active job's size is unknown.
- **A cancel deletes what it stops**: the partial for a running or a paused transfer, and for a resumed one waiting in line, which Remove from queue cancels; the unpacked folders of an answered install waiting for the slot; and the whole archive for one cancelled after the bytes landed, since the install that would have consumed it is exactly what is being called off. It **records no error** and the row leaves the list — the user asked for it — so `DownloadJob.error` means "something went wrong" everywhere, and the sidebar shows no red pill over a stop that worked. An *installing* or *updating* job cannot be cancelled at all, and the refusal is in `DownloadQueue.cancel` rather than only in the button that declines to offer it: that same method's archive delete would otherwise pull the file out from under a running extraction.

## 10. Install questions wait in Downloads

**A background install never opens a window by itself**: no question dialog and no preparing modal. It unpacks behind its Working card, and where it needs the user it stops, waits in the panel's Needs your attention group, and frees the install slot for the next job.
A question that opened on its own would land over whatever the user is doing, minutes after they pressed Install, about a mod they may have stopped thinking about, and while it was open the job would hold the install slot, so every other install would wait behind it (`nextAwaitingHost`).

Four questions can wait, tested in this order:

| Question | Found by | The row says | Its buttons |
|---|---|---|---|
| Password | the unpack's own listing, before anything is written (§12) | "The archive asks for a password. Authors usually put it in the mod description." | Enter password · Open mod page |
| Already installed | the archive's md5 against the library, after the unpack (`installsOfArchiveNow`, the drop's test too) | "This archive is byte-identical to the one you installed as Ellen Swimsuit." | Install anyway · Don't install |
| Several folders | more than one folder unpacked | "The archive has 3 folders. Pick which to install and how." | Pick folders… · Don't install |
| A patch | the patch scan of the planned mods (`scanPlannedMods`) | "Looks like a patch for another mod. Choose what it should patch." | Choose… · Don't install |

- **The already-installed question waits like the others.** Declining it for the user turns a download into nothing that anyone asked for, and re-installing an identical archive is the repair the question exists to allow; installing it unasked is the answer the question exists to avoid. It has no dialog: its sentence fits on the row, and the row's two buttons are its two answers. The wording is "byte-identical", never "verified".
- The other buttons open their dialogs: the import selection dialog, the patch prompt, and §12's password dialog.

### Where the install splits

The install (`dialogs/install_archive_flow.dart`) is three parts, and only the middle one asks anything: `runArchiveInstall` runs the first and the last in the slot, and `answerInstallQuestion` the middle one.

1. **Prepare**, in the install slot, unattended: the mods-folder check, the unpack (with the password, once one is given), whose own listing refuses a locked archive before anything is written, the empty-archive check, then each question's test without asking it: the md5 lookup, the folder count and, for a single folder, the patch scan. The first question that needs asking parks the job in `waiting`, with what that question needs (`DownloadJob.wait`, and the `PreparedInstall` it kept), and the slot is released. With none, the same claim runs the finish.
2. **The answer**, from the row's button, which reaches the host through `downloadQuestionsProvider`. The host opens the question's dialog from its own context, which is below the `Navigator` and outlives the panel. Answering runs the questions after it in the same sitting, since the user is now at the screen: Pick folders… is followed by the patch scan of that selection and, when it finds a patch, the prompt. The answers are kept on the job, and it goes back in line for the slot, ahead of jobs that have not waited. A password is the exception: its archive still has to be unpacked, and a question that unpack finds waits again.
3. **Finish**, in the slot: the patch writes are planned from the kept answers, then the import, the metadata, the patch writes, the named base's download, Turn on after installing, and the result. `resolvePatchDestinations` runs here rather than at the answer, because the mod a patch goes into can change between the two; a folder gone by then is the `goneMod` refusal. The mods folder is read again rather than taken from the prepare. The base download keeps its window, since the user asked for it in the answer a moment before.

**A dialog closed without an answer puts the question back.** Escape, a click outside or its Cancel leaves the row waiting; only Don't install, on the row, in the password dialog or in the patch prompt, ends it. A dismissed dialog is neither consent nor refusal when the row is still there to come back to.

**Don't install** deletes what the job kept (below) and takes the row off the list, as a cancel does.

### What is kept, and when it goes

- **A password wait keeps the archive** in `<appData>/downloads` under its final name; nothing is unpacked yet.
- **Every other wait keeps the unpacked folders** in their `zzz_archive_extract_*` directory in the system temp folder. The archive is deleted once unpacked, as every install does, and the job holds the md5 and shader sources the unpack produced. On most Linux desktops the temp folder is a tmpfs, so a waiting install holds its unpacked size in memory for as long as it waits.
  - Rejected: keeping the archive and unpacking again at the answer. Extraction is the slow step and scales with the archive (1.24 GB at the tail), so the user would wait in front of a window at the moment they chose to act.
- **The temp folder goes when the job ends**: at Don't install, at a Cancel of an answered job still waiting for the slot, and at the end of the finish, once the import and the patch writes have read it, as the drop's import deletes its own.
  `ArchiveService.deleteExtraction` walks up from the folders to the nearest `zzz_archive_extract_*` directory and deletes that, so an archive laid out as `Mods/<mod>` leaves no empty `Mods` behind.
- **The Storage reclaim refuses the temp extractions while a job waits, installs or updates**: a waiting one with a skip reason of its own ("a download is waiting for your answer in Downloads"), an installing or updating one as any install in progress, since an update holds its unpack while it asks and writes. A waiting job's folder can be older than that target's one-hour grace, and so can the folder the finish is copying from after a long wait. The archive and partial targets need nothing more: a waiting job is not terminal, so `downloadsBusy` already closes their gate.
- **App exit loses a waiting job with its answers**, since the queue is not persisted; the download is asked for again from Browse. Nothing runs at close, which stays instant, as the log flush is bounded for the same reason. A password wait's archive goes at the next launch's sweep (§8). An unpacked folder is left to the reclaim's temp extractions, which take it once it is an hour old, and on a tmpfs a reboot takes it first. There is no "close anyway?" question: closing with a download waiting is the user's own doing.

### The drop asks directly

A drag-and-drop or paste import (`_importModsFromFolders` in `mods_screen.dart`) asks its questions as dialogs: the user is at the screen, has just dropped, and the import's own window follows. A dismissed dialog ends the import, since there is no row to come back to.
It shares the import selection dialog, the patch prompt and the password dialog with the rows. The already-installed question is the one it words on its own, as a dialog that ends "Install it again anyway?" (`confirmArchiveNotDuplicate`), where the row's sentence is the statement alone and its buttons the question.
It asks for passwords too: every dropped archive is listed before any is unpacked, so every password is asked up front, the locked ones one at a time, and then all are unpacked under the Working card.
Each listing goes on to its unpack (`ArchiveService.listArchive`, then `extractArchive(listing:)`), so an archive is listed once per drop; only one whose listing said nothing is listed again with its password: encrypted headers, a failed or timed-out listing, or no 7-Zip. A password that did not open its archive asks again during the unpack. A dropped archive has no mod page, so its dialog has no Open mod page.
A drop whose every password was declined shows no Unpacking card and no "Nothing to import": the user said no, and nothing else happened.

The update flows (`applyUpdateFlow`, `applyPatchUpdateFlow`) ask for a password the same way, over their own window, and again after one that did not open the archive: an update is a conversation the user is in. Don't install there ends the update, and so does Open mod page, which then closes every window over the pages, the update's own and the Downloads panel included, and opens the page in Browse.
A file an update is already writing can't be fetched by a second update: it says "Already downloading", since the job in flight belongs to the first, whose flow deletes the archive when it ends.

The Needs you card is [`notifications.md`](notifications.md) §4.

## 11. Pause

- **Pause stops a running transfer and keeps its partial.** The queue marks the job `paused`, then stops it with `DownloadHandle.cancel(deletePartial: false)`, the path the app's shutdown takes, so the `.part` and its record stay. The slot frees and the next queued job starts. Marking first is what makes the stop that comes back read as the pause rather than as a cancel. A transfer whose last byte lands as Pause is pressed finishes: the archive is on disk, and that wins.
- **Only a background transfer pauses**, an install or a saved archive. An update's download runs behind its own window, which has Cancel, and pausing a wait the user is sitting in means nothing. A queued job holds nothing to pause; Remove from queue is its control.
- **Resume puts it back in line** as `queued`, marked `resumed`, which puts it first of the queued jobs (`admissions`), and it starts when a slot is free. The service resumes from the partial under the resume policy (§4), where a `200` to the ranged request starts over.
  Pressing Install again for a paused file resumes the job the queue already has for that file id (§7), since the press asks for the file, and the job takes that press's intent, character and Turn on (`DownloadJob.pressedAgain`).
- **Resume pressed before the pause has taken effect waits for the stop**, then resumes: a transfer started at once would write into the `.part` the stopping one still holds. Cancel in that window takes the row off and deletes the partial once the stop lands, and the archive when the last byte landed instead.
  Progress, the finish and a failure are taken only from the job's current handle, so a stopping transfer's last callbacks cannot overwrite the job that replaced it.
- **A resumed transfer has no in-stream md5**, since the earlier bytes passed through another run; the unpack hashes the archive instead, the one extra read §6 describes.
- **The state** is not terminal and holds no connection. The sidebar counts it (§14): it is unfinished work the user will want to find again. `aggregateProgress` leaves it out, as nothing of it is moving. The reclaim's gate counts it as busy, which is what keeps its partial ([`disk-usage.md`](disk-usage.md) §8 names this case).
- **Its card goes.** Pausing dismisses the download's Working card, whose spinner and bar would claim work that is not happening, and Resume raises it again, as any download that becomes active does (§9). The pause itself says nothing: the button turned to Resume under the pointer.
- **App exit loses the job and keeps the partial.** Asking for the same file again resumes from it, since the partial is named after the file. The lazy sweep at a later session's first download deletes a partial not written for 7 days (`DownloadPaths.staleAfter`), and the reclaim's abandoned partials use the same 7 days, so a pause survives a restart for a week from its last write.
- Rejected: pausing by holding the response open (pausing the subscription). It keeps the connection and its isolate, the stall timer would have to be suspended, and a CDN closes an idle connection on its own. Resuming from the partial is the mechanism the service already trusts.

## 12. Archive passwords

### What 7-Zip and `package:archive` do with one

Measured 2026-10-21 with 7-Zip 26.04 (x64, Linux) and `package:archive` 3.6.1, on archives that 7-Zip made of one three-file mod: a 7z with its contents encrypted (`-pSECRET`), a 7z with its headers encrypted too (`-mhe=on`), a zip in ZipCrypto (`-tzip -pSECRET`) and one in AES-256 (`-mem=AES256`), plain controls, random bytes named `.7z` and `.zip`, and a 7z cut short. The commands ran from Dart the way the app runs them.

`7z x <archive> -o<dir> -y` through `Process.run`, which closes the child's stdin, as `ArchiveService` runs it:

| | no `-p` | `-pSECRET` | `-pWRONG`, or `-p` with nothing after it |
|---|---|---|---|
| plain 7z, plain zip | 0 | 0 | 0 |
| 7z, contents encrypted | **255**: stdout ends `Enter password:`, stderr `Break signaled`; nothing written | 0 | **2**: `ERROR: Data Error in encrypted file. Wrong password? : TestMod/body.dds`, one per file; nothing written |
| 7z, headers encrypted | **255**, the same; no directory created | 0 | **2**: `ERROR: <archive>` then `Cannot open encrypted archive. Wrong password?` |
| zip, ZipCrypto or AES | **255**, the same; a 0-byte `body.dds` left | 0 | **2**: `ERROR: Wrong password : TestMod/body.dds`, one per file; every file left at 0 bytes |

`7z l -slt <archive>`, the listing the unpack preflight runs (§4.1):

| | stdin open, as `ProcessProbe` runs it | stdin closed | `-p` with nothing after it, stdin closed |
|---|---|---|---|
| plain | 0, every entry `Encrypted = -` | 0 | 0 |
| 7z contents encrypted, either zip | 0, each file `Encrypted = +` | 0, the same | 0, the same |
| 7z headers encrypted | **hangs at `Enter password:` until the 10 s timeout kills it** (10 002 ms) | **255**, `Break signaled`, 2 ms | **2**: `ERROR: <archive> : Cannot open encrypted archive. Wrong password?` |
| random bytes, a cut 7z | not run | not run | **2**: `Open ERROR: Cannot open the file as [7z] archive`, then `Is not archive` or `Unexpected end of archive` |

With `-pSECRET` the header-encrypted 7z lists (0, `Encrypted = +`); with `-pWRONG` it fails as with an empty one. Writing `SECRET` and a newline to 7-Zip's stdin instead of passing `-p` extracts the 7z, the header-encrypted 7z and the ZipCrypto zip too (exit 0).

`package:archive` 3.6.1, listing as `_zipListing` does and decoding as `_extractZip` does (`decodeBytes(verify: true)`):

- **Listing works without a password.** Both encrypted zips report their unpacked size, and every encrypted file header has bit 0 of `generalPurposeBitFlag` set; AES entries carry method 99.
- **ZipCrypto fails with the right password**: `ArchiveException: FormatException: Invalid CRC for file in archive.`, as with none, a wrong or an empty one. Without `verify` it returns garbage bytes, and `FormatException: Filter error, bad data` on the deflated file. Python's `zipfile` reads the same archive with the same password, CRCs matching, so the archive is standard.
- **AES fails with the right password on one file of three**: `Exception: macs don't match` on the 200 000-byte stored file, while the other two decode. With no password it throws `_TypeError: Null check operator used on a null value`, with a wrong one `Exception: password error`, with an empty one `RangeError (end): Invalid value: Only valid value is 0: 32`.

And a `ProcessException` prints the whole command line: `ProcessException: No such file or directory`, then `Command: /nonexistent/7z x mod.7z -pSECRET`.

Not measured: rar (nothing on the machine writes one), a password outside ASCII, and anything on Windows, where Dart quotes the arguments for `CreateProcess` and 7-Zip splits them again by its own rules.

### Detecting one

- **A 7z or rar is asked about by the listing the preflight already runs, with stdin closed.** Exit 0 with any `Encrypted = +` means the files are locked; exit 255 means 7-Zip stopped at its password prompt, which only encrypted headers reach; exit 2 means it could not open the file, which is an extraction failure. An exit code and a field, so nothing depends on 7-Zip's English. For rar, 7-Zip's handler is expected to report the same field and to prompt the same way for encrypted headers; that is unmeasured.
- **`ProcessProbe` closes the child's stdin for every probe.** None of them writes to one, and an open stdin is how a tool that prompts hangs until the timeout, as the listing of a header-encrypted 7z does above.
- **A zip is asked about in-process**: bit 0 of any file header's flag, from the central directory the size listing already reads.
- **An unpack without a password that exits 255 needs one too**, the backstop for a listing that answered nothing.
- **An encrypted zip is extracted by 7-Zip, never by `package:archive`**, which garbles ZipCrypto even with the right password and fails AES (above). A plain zip stays in-process. With no 7-Zip installed an encrypted zip fails as a rar does, with the message that names 7-Zip.
  - Rejected: `package:archive` 4. Moving to it moves `image` too (`pubspec.yaml` says why), and its decryption is unmeasured.

### Asking for it

The row offers Enter password and Open mod page. Enter password opens a small dialog: the mod's name, one field, "Authors usually put it in the mod description." under it with Open mod page as a link, and Don't install beside Install, which is disabled while the field is empty; Enter submits.
The field shows what is typed: the password is copied from a public description, and seeing a typo matters more than hiding it. Open mod page, on the row or in the dialog, closes the panel and the dialog and opens the mod's page in Browse, with the row still waiting.
The dialog closes on Install and the password is tried in the install slot: for a 7z with only its contents encrypted, nothing short of the unpack tells a right password from a wrong one, and the unpack scales with the archive.

### Passing it to 7-Zip

- **As `-p<password>`, one element of `Process.run`'s argument list**, which reaches 7-Zip without a shell, with stdin still closed. A wrong password then exits 2 at once (measured), and 7-Zip never waits for input.
  - Rejected: writing it to 7-Zip's stdin. It works (measured), but it keeps stdin open and depends on 7-Zip asking exactly once, which is the shape of the listing's ten-second hang. The argument is visible to other local users (`ps`, `/proc`) while 7-Zip runs, and that costs nothing: the password is printed on the mod page.
- **A header-encrypted archive is listed again with the password**, so the unpack preflight has a size (measured: it lists), and a wrong password is caught there before anything is written.
- **The password never reaches the logger.** Redaction at the sink ([`logging.md`](logging.md) §5) knows paths and the account name and cannot recognise a password, so no rule there can be the guard. The argument list is never logged. The call that carries a password catches a `ProcessException` itself and logs only its message and error code, since its text carries the command line (measured) and `extractArchive`'s outer catch would otherwise log it as `error:`. The `7-Zip failed` line keeps its exit code and stderr, which name files and the archive and never the password (measured), plus `password: true` when one was given.

### A wrong one, and never storing it

- **A wrong password asks again and keeps the archive.** An unpack that fails with a password on an archive the listing marked encrypted, or a header listing that fails with one, brings the row back as "That password didn't open the archive." with Enter password. The unpack's directory is deleted, since a zip leaves 0-byte files behind (measured), and each try unpacks into a new one. 7-Zip cannot tell a wrong password from damaged encrypted data (its own message asks "Wrong password?"), so the row claims no more than that.
- **A password is never stored.** It is held on the job, in memory, from the dialog to the unpack it was given for, and dropped right after that unpack whatever the outcome (`DownloadQueue.dropPassword`); it is never written to the config, a sidecar or the log. An update of the same mod asks again.
  - Rejected: remembering it per mod, which saves one paste at the price of a store of passwords the user never sees.

## 13. The panel

**A side panel from the right**, 440 wide, under the title bar and over a scrim that covers the sidebar and the page. It is a route on the root `Navigator`, so the title bar stays live as it does over a dialog, and it opens above whatever is on screen, a dialog included, so a card's Open Downloads always shows it. Escape, the scrim and its close button close it, and the questions it opens are above it.
Its width is never more than the window's. A row's question opens from `DownloadQueueHost`'s context, on the root `Navigator` too, so its dialog lands above the panel, and Escape closes the dialog first. Anything that sends the user elsewhere closes the panel: Show closes it itself, and Open mod page, which the host or an update's flow answers from outside the panel, through `downloadsPanelCloseRequestProvider`. With a dialog above the panel it is taken out from under the dialog without an animation.

- Rejected: a `MenuAnchor` beside the sidebar. It paints in the page's overlay, so with a dialog up the panel would open behind its barrier.

The header has "Downloads", Clear finished while the Finished group has a row, and close. The footer says "Archives are deleted once they're installed.", which is true of every install: the archive goes once it is unpacked. With no row at all, the body says "Nothing is downloading."

**Four groups, in this order, each left out when empty**: Needs your attention with its count, In progress, Waiting, Finished. The first three are in queue order and Finished is newest first. A paused download stays in In progress where it was, so Resume comes up under the pointer that pressed Pause, and so does a resumed one while it waits for a slot, its line "Waiting for a free slot · 133 MB of 214 MB" and its bar still dimmed.

A row leads with a 56×42 thumbnail: the mod page's first preview, on the character's element tile while it loads or where there is none, the misc tile for a category or Unknown. A preview the content filter would hide is blurred instead, since the user asked for this download. A waiting row is amber and leads with its question's icon on an amber tile instead: a link for a patch, a folder, a lock, and two overlapping squares for an identical archive. Then the name, the file, a line, and the controls.
The file is which file of the mod page the row is: its name in mono, and the author's variant text in quotes beside it in grey, as the mod page's file list words it (`fileDisplayName`, `fileDisplayDetail`), on every row. Two files of one mod read the same by name alone, "Victorian Ballgown" twice, so it is what tells them apart; a long file name gives way before the variant text does.

| State | Group | The line | Controls |
|---|---|---|---|
| `waiting` | Needs your attention | the question's sentence (§10), or "That password didn't open the archive." | the question's two buttons |
| `running` | In progress | "133 MB of 214 MB · 4.1 MB/s · for Ellen Joe", with "62%" at the right; "Connecting..." before the first byte | Pause, Cancel |
| `paused` | In progress | "Paused · 133 MB of 214 MB", the bar dimmed | Resume, Cancel |
| `downloaded` | In progress | "214 MB · installs after the current one", the bar full | Cancel |
| `installing` | In progress | "Unpacking" until the import starts (`InstallStage`), then "Installing", with a sweep | none, as there is no safe stopping point (§9) |
| `updating` | In progress | "Updating" at the right, a sweep, and the step: "Unpacking the file from 2026-10-01 · old one kept as a snapshot", "Waiting for you to confirm", "Writing the file from 2026-10-01 · old one kept as a snapshot" | none |
| `queued` | Waiting | "156 MB · starts after the current download", or "Waiting for a free slot" while its size is unknown; the row at 75% | Remove from queue |
| `done`, one folder installed | Finished | "Installed · Ellen Joe · 9 minutes ago" | Turn on while that mod is off, Show once it is on |
| `done`, several folders | Finished | "3 mods installed · Ellen Joe · 9 minutes ago" | none |
| `done`, an update | Finished | "Updated to the file from 2026-09-28 · Ellen Joe · 2 minutes ago" | Show |
| `done`, an archive saved | Finished | "Saved to the app's downloads folder · 2 minutes ago" | Show, which opens the folder |
| `done`, nothing installed | Finished | the result's headline, such as "Nothing imported" | none |
| `failed` | Finished | the failure as §9 words it, in red | Try again where `rowActions` offers it, else Dismiss |

- **The running line drops the time left, as drawn.** The rate stays, since it is what tells a slow node from a dead one (§5). "for Ellen Joe" names an agent only: a category or Unknown says nothing about who a mod is for. The Finished line names where the install filed the mod by the name the Library's character list gives it, "Unassigned" included, since that is where to look for it; for a job with no character, the mod's own character is read from the library.
- **Both sizes carry their unit** ("133 MB of 214 MB"), unlike the canvas's "133 of 214 MB": the two differ in unit whenever a transfer crosses one, as 900 KB of 1.2 GB does.
- **Dates are the app's** (`2026-09-28`), not the canvas's "28 Sep". The relative time is the app's "9 minutes ago" (`relativeAgeLabel`), not the canvas's "9 min ago", and is redrawn each minute while the panel is open.
- **Turn on** runs the enable that Turn on after installing runs (`ApiService.enableMod` through the library's toggle, One at a time included), waits as it does for a running bulk action of the All mods table to end, and is not offered while the mod is being written. A refusal for the mod's shader files or for a network folder says why, as the Library's switch does, and any other failure says the mod couldn't be turned on. **Show** shows the mod in the Characters view with its details panel open (`showModInCharacters`), as the install card's Open does, with the same Note for a mod no longer there. Both are about one mod, so an install of several folders has neither.
- **A cancelled job leaves the list**, and so do one the user said Don't install to, a job removed from the queue and an update the user declined. Each did what the user asked and leaves nothing to read; a failure is what a row is kept for (§9).
- **A Finished row has no Dismiss**, as drawn: Clear finished takes them all. A failure keeps its own control, Try again or Dismiss.
- **Up to two controls on a row**, as drawn.

**What a job records** besides its transfer: when it finished; the folders an install created or an update wrote, and what it ended as (installed, updated, reinstalled, a patch's base installed, saved, or nothing installed with the result's headline); the character it was filed under, which is the job's `characterId` (the category's, Unassigned, or the user's pick with Install for); for an update, its file and the step its flow is on; and for a waiting job its question, what the question needs (the folder count, the names an identical archive was installed as, a password that failed) and the prepared install (the unpacked folders, the md5, the shader sources, the answers so far, and the password until it is used).

### Update downloads

**A download the update flow owns stays on the panel until the update ends**, as the canvas's Updating row draws it, rather than ending when its bytes land, which leaves a Finished row for an update the user may still decline.
Its bytes landing moves it to `updating`. The flow reports its steps (unpacking, the confirmation, writing) and ends the job in a `finally`, so no path leaves a row in progress: `done` with what it wrote, off the list when the user declined or cancelled, or `failed` with the flow's own headline and no Try again. A written update's row is Finished as its result window opens, not when that window is closed. Reinstall and the base fetched for a patch go through the same flow and say what they did (`JobOutcome.reinstalled`, `baseInstalled`). A transfer that fails before the handover stays as a failed row with Dismiss, since the flow that would consume a retry has already ended.
The flow's window and cards still report it, and the host raises no card for it after the handover. The row has no controls: the window has Cancel, and a write is not stopped half way.

- Rejected: leaving update downloads off the panel. The Waiting rows' "starts after the current download" would point at a download nobody can see, and the panel is the session's record of what changed.

## 14. The sidebar badge

One badge on the Downloads row at a time, the first of these that applies:

1. **Anything waiting**: an amber pill (`badgeUpdate`) with a 12px triangle and the count of waiting downloads, as the canvas draws it. Its tooltip, and what a screen reader says for it, is "3 downloads need your attention".
2. **Anything in progress or waiting for a slot, paused included**: the count in plain mono, `text3`.
3. **A failed row**: the same pill in `badgeMissing`, with a 12px circled cross and the count of failed rows, until they are dismissed or cleared.
4. **Nothing else**: no badge.

- Waiting outranks the count because it is the one state that needs the user; the deck already says how many are downloading.
- A failure ranks under the count: while downloads run the deck reports them and the failure is already an Error card that stays until closed, and once the queue is idle the pill keeps it findable. The row keeps its download arrow whatever the state, and a failure takes the same shape as a question in the colour of an error.
  - Rejected: swapping the row's icon for a warning. The row's arrow is what it is, and a pill says how many.
- A cancel shows nothing: it is what the user asked for.
