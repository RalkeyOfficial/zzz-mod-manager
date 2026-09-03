# Downloads — fetching mod archives

**Scope:** `services/download/`, which fetches archives into
`<appData>/downloads`, resumably — the isolate pump, resume policy,
backpressure, the stall timeout — plus the **queue** above it and the panel that
shows it.

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

**A foreground job bypasses the cap on the way in, and counts against it
afterwards.** The one modal download left (§8) runs behind a barrier that covers
the panel, so parking it behind two background transfers would leave the user
watching "waiting for a slot" with no way to reach what they would have to
cancel. Admitting it closes the door behind it rather than raising the ceiling,
so the worst case is one over the cap and only while a dialog is open.

**Nothing is persisted.** A queue restored from disk would start re-fetching on
launch. The partials in `<appData>/downloads` are already the durable half: an
interrupted job is resumed by asking for it again.

## 8. Where a download ends, and who finishes it

The queue moves bytes and stops. Unpacking, importing and reporting need
localized strings and can raise a dialog, and a `Notifier` has neither — so a
finished transfer parks in `downloaded` and **`DownloadQueueHost`** takes it from
there. `DownloadIntent`, fixed when the user presses the button, says which of
three things happens:

| intent | who finishes it |
|---|---|
| `install` | the host, through `dialogs/install_archive_flow.dart` |
| `keepArchive` | the host — one notification naming the path |
| `callerHandles` | the caller awaiting `completionOf`, i.e. `applyUpdateFlow` |

**Where the host is mounted is the whole design.** It wraps the tab switcher in
`main.dart`: the three tabs are keyed `AnimatedSwitcher` children with no
keep-alive and are *disposed* as the user moves between them, so an install owned
by `MarketplaceScreen` dies on the first tab switch with the archive already on
disk. Owning it there is safe only behind a modal dialog that makes walking away
impossible, and removing that barrier is the whole point of a queue. It must also sit **below** the `Navigator`, unlike
`NotificationHost`, because `showDialog` needs one as an ancestor.

**One install at a time.** Installing runs `7z`, writes into the mods folder
through a service held as a singleton, and can ask a question. Two of those
interleaving would race on all three, and two dialogs would stack.

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

The install therefore works from the name the download **asked for**
(`DownloadResult.requestedName` → `installArchiveFlow`'s `requestedName` →
`extractArchive`'s `nameHint`) rather than the name on disk. Exact, not a
heuristic: stripping a trailing ` (n)` would rename a mod genuinely called
`Ellen (2024)`. An archive nobody renamed — dragged in, or picked from a file
dialog — passes no hint and keeps its own name.

### Completed archives are swept at launch

An install deletes the archive it consumed, on every success path and on both
cancel paths. What is left in the directory is an archive whose install never
*ran*: extraction failed and it was kept so the user could unpack it by hand, the
mods path was unset, the app closed between the download landing and the install
starting, or the delete itself failed and was only logged.

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

Three surfaces, and they answer different questions. The **wait modal** says
*you are waiting for this, and it is still going*; the **notification** says
*something is happening in the background and here is how fast*; the **panel**
says *what, exactly, and let me change it*.

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
thing the user sees. Without a hold the download closes its own modal, which is
what the marketplace's own use wants — nothing follows the transfer there.

**The preparing phase is not cancellable, and the button goes rather than being
disabled.** Unpacking cannot be stopped half way and leave anything usable, and
a dead control invites the press that proves it is dead. The bar is
indeterminate for the same kind of reason: extraction reports no progress, and a
bar pretending to know how far along it is would be worse than not saying.

**The install path has the same wait without the first phase.** Its transfer ran
in the background queue ([§8](#8-where-a-download-ends-and-who-finishes-it)) and
the user was told it arrived, so `showPreparingModal` opens the window straight
into its second phase for the unpacking. That modal is the optional half: with
no live context there is nothing to draw on, and the unpacking still has to
happen.

### The pinned progress notification

Raised by `DownloadQueueHost` and kept in step with the queue. Backgrounding a
transfer takes away the modal dialog that used to *be* the progress report, and
a download nobody can see is one the user assumes failed — so the report moves to
the foreground without blocking it.

- **One card for the whole queue, never one per download.** The stack holds four
  and drops the oldest, so a card per job turns a five-mod queue into a wall and
  pushes off the messages that actually need reading. The card carries the
  aggregate (`aggregateProgress`); the panel is where the per-mod breakdown is.
- **Pinned, because the end of a download is an event rather than a moment.**
  That is the shape `NotificationCenter.pinned` exists for: the **body** is the
  stable subject and only the title is rewritten. It is dismissed when the queue
  empties — what is left to say about a finished install is said by the install.
- **A percentage, not two byte counts.** The card's title has no `maxLines`, and
  `5.0 MB / 21.9 MB · 14 MB/s · 2m left` costs a second line on a 360px card
  while saying less than `24%` does in a quarter of the width.
- **The ETA is the queue's, not any one job's** — remaining bytes over the
  *combined* rate, because the queue finishes when the last byte lands.
- **A count-bearing card gets no portrait**, the same rule the bulk reports
  follow: one arbitrary face would claim the message is about that mod, and
  which mod sorted first would change between runs. One download still gets its
  own.
- **Closing it sticks.** Nothing this app shows may be un-dismissable, so the
  card is *raised* only when a job it has not covered appears and merely
  *updated* thereafter. A card re-raised on the next progress tick would
  override the user; closing it therefore holds until they ask for something
  else, which is itself a request to be told about it.

This is also why `show()` evicts the oldest **dismissable** notification rather
than simply the oldest: an update to a pinned card that has been evicted is a
no-op, so dropping one silently throws away the only report of the work it was
tracking. See `notifications.md` §7.

### The panel

`DownloadsButton` in the sidebar, opening `DownloadsPanel`. Both are **absent
until there is something to report**: a control that is empty on every launch is
one nobody learns. In the sidebar rather than a tab because a transfer outlives
the screen that started it, so it cannot belong to one — and the sidebar is the
only chrome the app draws, the title bar being the window manager's
([`desktop-integration.md`](desktop-integration.md) §4).

- **Finished rows stay until they are cleared.** A row that vanished on its own
  would take the only record of a failure with it.
- **One control per row**, chosen by `rowAction`: cancel, retry, dismiss, or
  nothing at all while an install is between its unpack and its import, where
  there is no safe stopping point to offer. It reads the **whole queue**, not
  just the row, because two of those answers depend on it — a failure another
  job is already re-fetching offers no retry (`DownloadQueue.retry` would refuse
  it, and a button that silently does nothing is worse than a row that reads as
  history), and neither does an **install** failure, where the bytes were fine
  and re-fetching them hits the same `7z` error.
- **An install failure says what actually failed.** It travels as an
  `InstallFailure` rather than a bare string, so the row carries the install's
  own message instead of "Download failed" — which would name the one half that
  worked.
- **The ring reports bytes, not jobs** — a 1.2 GB archive and a 4 MB one are not
  half the work each — and goes indeterminate rather than inventing a number
  while any active job's size is unknown.
- **A cancel deletes what it stops**: the partial for a running transfer, and the
  whole archive for one cancelled after the bytes landed, since the install that
  would have consumed it is exactly what is being called off. It **records no
  error** — the user asked for it — so `DownloadJob.error` means "something went
  wrong" everywhere, and the downloads button does not turn red over a stop that
  worked. An *installing* job cannot be cancelled at all, and the refusal is in
  `DownloadQueue.cancel` rather than only in the button that declines to offer
  it: that same method's archive delete would otherwise pull the file out from
  under a running extraction.
