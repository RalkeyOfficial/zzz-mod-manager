# Logging

**What the app records about its own behaviour** — the levels, the source tags,
what each area logs, the file and its rotation, and the one guarantee the file
carries about the person who ran it.

Not in scope: what the app tells the *user*, which is
[`notifications.md`](notifications.md) — though every notification is also
logged, from one hook, so the two meet in §6. The Settings key itself belongs to
[`configuration.md`](configuration.md).

---

## 1. Why there is one at all

There wasn't. There were 223 `print` calls, 150 of them in Ukrainian, with no
timestamp, no level and no way to filter — and **nothing at all** in the
GameBanana client or the download path, which is where failures actually happen.
There was also no global error handling, so a crash left no trace anywhere.

The motivating case: GameBanana answered a valid request with `200` and an empty
body, the client cached that for ten minutes, and the only evidence was

```
GameBanana request failed (generic): GbFormatException: Response was not valid JSON: Unexpected end of input
```

No url, no status, no body length, no way to tell an empty body from a malformed
one. Any one of the four would have named the cause instantly. **The test of this
whole system is that the same failure is now a one-line diagnosis**, and there is
a test asserting exactly that (`gamebanana_client_test.dart`, "an empty 200 is
diagnosable from the file alone").

## 2. Levels

| Level | Means | Rule of thumb |
|---|---|---|
| `debug` | Narration of an attempt | Useful while reproducing, noise otherwise |
| `info` | Something a reader reconstructing the session wants | A download finished, a snapshot taken, a confirmation given |
| `warning` | A problem the app **handled** | A retry, a fallback, a skipped file; the operation still completed |
| `error` | An operation **did not happen** | Usually paired with something the user was told |
| `critical` | The app has no answer | An uncaught exception; a snapshot that failed *before* an overwrite |

The distinction that matters in practice is **warning vs error**: anything a user
would describe as "it didn't work" is `error` or above, because that is what
somebody reading a log for a bug report greps for first.

`critical` has exactly one non-crash site — `SnapshotService.capture` failing —
because the applier's contract is that nothing is written without a snapshot
first, and that is the moment the contract breaks.

`error` and `critical` flush the file immediately. Everything else is buffered:
flushing per line would make a library scan I/O-bound.

## 3. Call sites

```dart
final _log = Logger('gamebanana.client');   // one per file, at the top

_log.debug('request', fields: {'url': url, 'cache': 'miss'});
_log.warning('retrying', fields: {'reason': 'empty_body', 'attempt': 1});
_log.error('extraction failed', error: e, stack: s, fields: {'archive': name});
```

Three rules:

- **The message says what happened; the fields say what it happened to.** No
  interpolated values in the message — `'retrying'` with `attempt=1`, never
  `'retrying attempt 1'`. The same split as a notification's title and body, and
  what keeps the file greppable and its columns aligned.
- **Never interpolate an exception.** Pass it as `error:` so the formatter decides
  how an exception renders, once, instead of at 200 call sites.
- **Never pre-censor a path.** Redaction happens at the sink (§5); shortening a
  path at the call site hides the real one from the only code that knows how to
  shorten it properly.

`Logger` is synchronous and reachable with no `ref` and no `BuildContext` —
`FlutterError.onError` is a sync callback and `PlatformDispatcher.onError` must
*return a bool*, so a logger that had to be awaited could not be used for
crashes. An uninitialised `Log` is a working `Log`: it writes to the terminal at
`warning` and above, so a unit test needs no setup.

## 4. Tags

Dotted, one per file, chosen by **what owns the decision being reported** rather
than which file noticed it.

| Tag | Owns |
|---|---|
| `app` | Startup, the header, first run, a failed initialisation |
| `system` | The machine description (§7) |
| `gamebanana.client` | Requests, responses, retries, cache, parse failures |
| `download` | Resume decisions, stalls, collisions |
| `download.pump` / `download.worker` | The isolate arm, and lines relayed from inside it (§8) |
| `archive` | Extraction, 7-Zip, unsafe entries |
| `update.apply` | The applier's phases |
| `snapshot` | Capture, restore, retention |
| `metadata` | Sidecars, origins, autofill |
| `mods` | Library-level actions |
| `ini` | Parsing |
| `platform` | Symlinks, browser, folders, the system description |
| `fileops` | **Every mutation of the filesystem**, whoever made it |
| `ui.notify` | Every notification raised |
| `ui.confirm` | Every answer to a destructive prompt |
| `log` | The logger talking about itself |

`fileops` deliberately cuts across the others: symlinks are the central act of
this app, and "what did it do to my folders" has to be one filter rather than
four.

## 5. Redaction — the guarantee, and its limits

**The account name of the machine does not appear in the file.**

That is not achieved by careful call sites and could not be: every app-owned path
contains the name, and Dart bakes the offending path into
`FileSystemException.toString()`, so a call site passing only an exception leaks
it. Instead `LogRouter` renders the line, applies `redact()`, and only then hands
it to any sink. One function, one call, and **no sink can bypass it** — which is
also why the clipboard text and the in-memory buffer are censored by the same
guarantee rather than a second implementation.

Rules, in order: the home directory becomes `~`; then any `/home/<name>`,
`/Users/<name>` or `<drive>:\Users\<name>` becomes `~` — including other
people's, since a log can carry a path from another machine; then the bare
account name becomes `<user>`.

**A name shorter than three characters turns off that last rule.** An account
called `pi` appears inside "copying", "pinned", "pipe"; replacing all of them
would destroy the log to protect two characters. The header says
`username_token=skipped` when this applies, so a reader chasing a suspected leak
finds out at the top instead of guessing.

Placeholders are `~` and `<user>`, never `***`: `~/.local/share/…/downloads/x.rar`
is exactly as diagnostic as the original, and a redaction that destroys the
diagnostic has failed at the thing it was protecting.

**What it does not promise.** A mod folder someone named after themselves, a
GameBanana display name, a drive label — all still there. Anyone publishing a log
should still read it. Saying so is better than implying a guarantee this cannot
make.

Two things must therefore **never be logged**: an environment dump, and
`PlatformService.osUserName` itself.

## 6. Volume — the rules that keep it readable

A log nobody can read is a log nobody reads.

- **Mutations are itemised; reads are summarised.** A symlink or a copy gets a
  line each. A 71-mod library scan gets one summary line, never 71.
- **Filesystem queries are never logged.** `isModLink` alone runs once per mod
  per scan.
- **Download progress is never logged.** It fires twice a second; one legitimate
  25-minute transfer would be 3,000 lines.
- **Per-item loops become counts.** A drop of eight archives logs the batch.
- **The body of a response is never logged** — its length always, and 120
  characters of its head on a parse failure.

Notifications are logged from a single hook in `NotificationCenter.show`, so
every card the user sees is in the file with the failure that caused it, and no
call site has to remember. The text is already localized, so a Ukrainian UI
writes Ukrainian there — correct, because the point is to record what was on
screen.

Confirmations are logged where each answer is *consumed*, through
`logConfirmation` — an update applied, a mod deleted, a patch destination chosen.
**A decline is logged as loudly as an accept**, because an action that did not
happen leaves no other trace, and "I pressed the button and nothing happened" is
usually a prompt that was dismissed.

## 7. The file

`<appData>/logs/zzz-mod-manager_<yyyy-MM-dd_HH-mm-ss>.log`, **one per launch,
the newest seven kept**. Names sort chronologically, and ordering comes from the
name rather than the modification time — the running session rewrites its own
mtime, and a sync tool rewrites everyone's.

Pruning happens **at open, not at exit**: a process that crashes never reaches
exit, and a crash is when the directory most needs pruning. A file whose name
this app does not recognise is never deleted and never counted — the folder is
one the user is invited to open, and deleting a note they left there would be a
data-loss bug.

One session is capped at 16 MB. Past that the sink stops and says so; it does
**not** roll into a second file, because a runaway session that rotated would
evict all seven previous runs and destroy the history that answers "when did this
start?". Losing the tail of the broken run is the cheaper loss.

A failed write disables the file and reports once on the terminal. The logger may
never take down the app it is trying to report a failure for — including the
asynchronous failures an `IOSink` reports on `done` rather than at the write,
which is how a disk filling mid-session would otherwise drop the rest of the
session silently.

### The header

Two blocks, and the split is deliberate. The synchronous half — app version, OS,
Dart, locale, CPU count, the log's own path, what redaction is in force — is
written the moment the file opens and costs nothing. The rest spawns processes:
distro, display server, desktop, and every external tool with its version and
where it was found. That runs **unawaited after `runApp`**, because a `where 7z`
walking a cold Windows `PATH` is a visible pause, and paying for a diagnostic
with the startup it exists to protect is the wrong trade.

A missing tool is a `warning`, so a machine with no extractor says on its own
that archive imports cannot work. **Only tools the app actually runs are
probed.** Three window/input helpers were probed for years for a mod-reload
feature that no longer exists, and each put a `missing` warning in every log on
a machine that never needed it — a line that reads like a cause and is not one.

## 8. The download isolate

The worker shares no memory with the main isolate: it cannot reach `Log.router`,
and it must not open the file itself — a second writer would interleave halfway
through lines. Its diagnostics travel as data over the tagged wire protocol it
already has (`_kLog`), and are logged on arrival.

The timestamp is taken **in the worker**. Delivery is delayed by exactly the
event-loop congestion the isolate exists to escape, so stamping on arrival would
misattribute a stall to when it was noticed rather than when it happened. Worker
lines can therefore interleave out of order, which is another reason every line
leads with a full sortable timestamp.

## 9. Settings

Three rows under **Diagnostics**: the on/off switch, *Open folder*, and *Copy
diagnostics*.

**On by default.** A log reaches nothing and costs kilobytes, and is worthless if
it happened to be switched off on the run that broke — the opposite call from the
startup update check, which reaches the network unasked and is therefore opt-in.

**There is no level setting**, and that is a decision: letting the verbosity be
tuned means the one report you needed detail from is the one where it was turned
down. The file always gets everything; the terminal is the quieter one.

**Turning it off closes the file and leaves it on disk.** Deleting somebody's logs
as a side effect of a toggle would throw away the thing they may be about to
attach to a report. Turning it on opens a *new* file with its own header, rather
than appending to one whose header describes a run that already ended.

The switch is read from `config.json` **directly** at bootstrap, because
`SharedPreferences` does not exist until the first frame — long after the first
lines worth keeping. Any failure to read it means yes: a missing or corrupt
config is the state a first run and a broken install share, and both are exactly
when somebody wants the log.

*Copy diagnostics* is built from the in-memory ring buffer, not by reading the
file: it works with the file switched off, cannot be slow, and the lines are
already redacted.

## 10. Where it lives

| File | Owns |
|---|---|
| `services/log/log_level.dart` | The five levels and what each means |
| `services/log/log_record.dart` | One event, as data |
| `services/log/log_format.dart` | The two renderings — file and terminal |
| `services/log/log_redaction.dart` | §5, pure |
| `services/log/log_rotation.dart` | Which files survive, pure |
| `services/log/log_sinks.dart` | Terminal, file, and the memory ring |
| `services/log/logger.dart` | `Logger`, `LogRouter`, the static `Log` |
| `services/log/log_setup.dart` | The production router, the error hooks, the header |
| `services/log/system_report.dart` | The machine description and its parsers, pure |
| `services/log/system_probe.dart` | Gathering it |
| `services/log/confirmations.dart` | `logConfirmation` |
| `utils/process_probe.dart` | Running a command with a timeout that actually kills it |

`test/no_prints_test.dart` is the ratchet: `avoid_print` is enabled but does not
catch `debugPrint`, which is worse for a logger — it throttles at ~12.8 KB/s and
*defers* the overflow, so lines arrive reordered or not at all during exactly the
burst worth reading.

**Nothing inside the logger may log.** `PathHelper`, the redactor and the
settings read all run *during* logger construction; a log call from any of them
would recurse through a router that does not exist yet.
