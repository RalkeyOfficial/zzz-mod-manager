# Downloads — fetching mod archives

**Scope:** `services/download/`, which fetches archives into
`<appData>/downloads`, resumably. Owns the isolate pump, resume policy,
backpressure and the stall timeout.

Separate from the JSON client (`services/gamebanana/`) because it needs streamed
bodies, byte ranges and socket backpressure. [`gamebanana-api.md`](gamebanana-api.md)
§8 has the remote-side measurements that shape it.

---

## 1. The shape

`DownloadService` — reached via `downloadServiceProvider`. Returns a
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
