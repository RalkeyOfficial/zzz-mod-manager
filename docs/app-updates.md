# App updates

Whether a newer release of the app itself exists, how the app asks, and what it does with the answer, which is show it.

> Scope: Settings > About's **Check for updates** button, `services/app_update_service.dart`, and the line it feeds in the About card. Whether an installed *mod* has a newer version is [`update-checks.md`](update-checks.md), a separate question with a separate network call and a separate opt-in.

---

## 1. Manual only

The app contacts GitHub when the user presses Check for updates, and at no other time: not at launch, not on opening About, not on a timer.

The standing rule is that an update check runs only when the user presses a button for it, with one exception the user opts into: the mod update check at launch ([`update-checks.md`](update-checks.md) §5.1). That switch is worded and documented for mods, and it reaches GameBanana. It does not cover this call, which reaches a different host about a different thing, so there is no launch check for the app and no setting for one.

## 2. What it calls

One `GET` of `https://api.github.com/repos/RalkeyOfficial/zzz-mod-manager/releases/latest`, built from `AppConstants.repositoryUrl`, with the app's own `User-Agent` (`AppConstants.httpUserAgent`) and `Accept: application/vnd.github+json`. No token: the endpoint is public, and the unauthenticated limit of 60 requests an hour per address is far above what presses reach.

The request goes through the same `HttpTransport` seam as the GameBanana client, with a 15 second timeout over the whole request. The answer is a few kilobytes, so this is not the stall timeout that downloads use, which exists for transfers that legitimately run for many minutes.

`releases/latest` leaves out drafts and pre-releases. The check ignores them again on the response, so a change in that behaviour cannot offer one.

## 3. What it compares

The tag, with a leading `v` stripped, against `AppConstants.appVersion`, as `major.minor.patch` numbers. `2.10.0` is newer than `2.9.0`; the comparison is never textual.

- A tag with a pre-release part (`3.0.0-beta.1`), a release the response flags as `prerelease` or `draft`, and a release that is not newer all read as **up to date**: nothing stable is known to be newer.
- A tag that is not `major.minor.patch`, such as `v3` or `nightly`, or an answer that is not a release, reads as **couldn't check**. The check cannot say anything about it, and it does not guess.

The link behind Release notes is the response's `html_url`, and only when it is an `https://github.com/` page. Before any check, and after one that failed, Release notes opens the repository's releases list.

## 4. The three answers

| Answer | The About card says |
|---|---|
| Up to date | "You're on the latest version · checked 10 minutes ago". When the running build is itself a pre-release it says "Nothing newer than this pre-release is published as a stable release · checked 10 minutes ago" instead, because `releases/latest` never lists a pre-release and the check cannot say that nothing newer exists. The small card that ends the Settings page shows no status line in that case, rather than "You're on the latest version" |
| A newer version | "Version X is available · checked 10 minutes ago" |
| Couldn't check | One short line naming the reason: no connection, GitHub limiting requests (403, 429), no published release (404), or an answer the app cannot read |

The reason is a category chosen from the status or the failure, never the exception's text: a `SocketException` or a response body does not reach the screen. The exception goes to the log (`update.app`, [`logging.md`](logging.md)), where it is redacted like every other line.
Every failure is an `error` line carrying the url and, when GitHub answered, the status, and the head of the body (its first 120 characters with whitespace collapsed) when the answer could not be read, so a 500, a 502, a 403 and a 429 are told apart from the file alone.

The answer and its time are held for the session in `appUpdateResultProvider`, so leaving About and coming back shows the same line, and none of that is a press. They are not saved: the next launch starts with no line.

## 5. What it never does

It never downloads or installs anything. A newer version is a line of text and a link to the release page, where the user chooses what to fetch. Replacing a running app is a different feature with different risks, and automatic updating of the app is refused for the same reason as for mods ([`applying-updates.md`](applying-updates.md) §7).

It never retries on its own, never caches, and never runs unasked: a failed check waits for the next press.
