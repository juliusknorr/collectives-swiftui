# Native Text session boundary

Implemented on `feat/text-collaboration`, 2026-11-05. This is the first
implementation batch of the [collaboration plan](text-collaboration.md).

The agreed UI scope is an explicit experimental mode with strict runtime/server
matching. The native compatibility gate is implemented; the UI is not enabled.

## Runtime compatibility

`CollectivesClient.verifyTextRuntime(expected:)` fetches the authenticated
`GET /index.php/apps/text/embedding` manifest with a 16 KiB response cap,
no-cache request and redirect rejection. It requires an exact match of format,
Text version, source revision, code digest, session API and update encoding.
Missing, malformed or incompatible metadata prevents session creation.

Only verification can produce the account-scoped proof required by the public
`textSession` factory. Every open, sync, push and save carries its verified digest
natively. The experimental Text branch checks it before processing the
session request and returns HTTP 412 after a build change. The client then
requires recovery. Close omits the digest so cleanup remains possible; successful
cleanup does not establish that unsaved edits reached DAV.

The endpoint, middleware, manifest generator and PHP tests are maintained in
Text's [feat/text-collaboration branch](https://github.com/nextcloud/text/tree/feat/text-collaboration),
based on the pinned upstream revision.
They are not merged into upstream main. The app pins the Text commit and archive
checksum rather than applying PHP patches. Text's own build tool generates the
same manifest for the native bundle and server,
including hashes of pinned JavaScript/CSS, PHP and app metadata. Deployment must
activate the code and generated manifest together. Verification trusts that server
assertion; it does not independently attest every remote asset. A manual change
to same-version server files without regenerating the manifest cannot be detected.
No server JavaScript is downloaded or executed by this gate.

## Native requests

`TextSessionClient` binds a native account client, file ID and editor lease UUID
for its lifetime. `TextSessionCommand` supports open, sync, push, save and close.
Commands contain document updates and versions; they cannot select a URL, file,
account, server session ID, authentication header or real session token.

Native code obtains and retains Text's session ID/token and base-version ETag.
Replies preserve the upstream payload structure but replace token fields with
an inert placeholder, including nested session arrays. The collaboration base
ETag is independent of the native document's current DAV ETag.

`TextSessionReply.saveConfirmed` is set only for save replies. HTTP 200 with a
saved version below the requested version returns `false`; it must never release
document ownership. A missing saved-version field is an invalid response.

The client has explicit idle, opening, active, closing, closed and
recovery-required states. It rejects foreign lease UUIDs, duplicate operations
in flight, overlapping push/save requests, and close while another request is
pending. Replies arriving after session invalidation are rejected. Lost open or
close replies leave recovery required and are never automatically replayed.
Authentication/session invalidation responses (401/403/404/412) also require
recovery; transient push/save failures retain the session for explicit retry.

## Shared bridge decoding

`TextSessionClient.sendBridgeRequest` decodes the pinned editor's JSON body into
the same typed commands. Both the harness and future app adapter use this path.
It checks the lease, document/session identity and collaboration base; rejects
unknown operations/fields, credential or URL overrides, share tokens and forced
saves; and distinguishes booleans from integers. Real tokens are added only
natively. Optional browser file paths never determine the native request target.

Creating a session accepts only an absent/null base ETag. Opening cached Yjs
state against a supplied base is deliberately unavailable until durable recovery
is implemented. The WebKit host must additionally verify the originating WebView,
main frame and local page before invoking this API, and retain the existing CSP
and navigation restrictions. A JSON parser cannot establish frame trust.

## Request and memory limits

The default encoded request and response limit is **4 MiB**, with at most 256
steps per push. Base64 inputs and versions are validated before networking.
Upstream request paths are constructed natively and redirects are rejected.

`URLSessionTransport` uses a reusable streaming data session for bounded requests.
It cancels an oversized declared response or stops appending when actual chunks
exceed the limit. Buffered chunks have one mutable owner to avoid copying the
entire accumulated body for each chunk. Cancellation propagates to the data task.
Custom `HTTPTransport` implementations inherit a post-response limit check and
should override the bounded overload to enforce limits during transfer.

At most one open/sync/push/save/close operation of each kind can be in flight per
client; push and save cannot overlap. The app currently reserves one collaboration
lease at a time and conservatively pauses native sync while it exists. This
matches the current rich-editor coordination; per-document concurrent native sync
is a future optimization. The limit applies to encoded wire messages, so large
documents need an explicit product decision before increasing it.

## App ownership and handoff

`AppSession.beginTextCollaboration` reserves a document for a window only after
native sync and persistence are idle, and no draft or conflict remains. The UI
orchestrator must flush pending native work before calling it. The returned lease
also supplies the UUID for `TextSessionClient`.

`TextDocumentOwnership` records local edit and checkpoint revisions separately.
Its handoff sequence is:

1. Freeze editor input and durably checkpoint the latest local revision.
2. Drain provider updates and record the required server version.
3. Begin handoff and confirm a save at or beyond that version.
4. Confirm server session closure.
5. Fetch canonical Markdown and a strong DAV ETag.
6. Persist the refreshed document base, then release ownership.

A session with no local edits can skip the outgoing Markdown save. It still
requires closure and canonical content/revision verification. Readable Markdown
must not be normalized merely by opening the editor.

`AppModel.completeCollaborationHandoff` validates the acknowledgement, persists
the canonical document, updates shared window snapshots, then releases ownership.
Storage failure keeps the lease. Source editing, native sync, and removal of the
leased account remain blocked through handoff and recovery. Source editor
generations change at acquisition and completion to reject queued callbacks from
before the session. Ownership remains registered if its originating window goes
away; window disappearance is not evidence that a session saved or closed.

## Verification and remaining work

Swift tests cover native credential confinement, message validation, response
stream limits, cancellation, lost replies, save-version checks, request races,
stale leases, checkpoint ordering, canonical revision checks, account isolation,
app sync/source guards, storage failure and stale editor callbacks.

Validation on 2026-11-06: **186 core tests and 59 app tests pass**. The rebuilt
native WebKit two-client suite also passes against the pinned Text 10.0.0-dev.3
and Nextcloud 36-dev fixture, including concurrent Unicode edits, reconnect,
explicit save/version and DAV verification, session rejection, and no-edit
source preservation. It also verifies manifest matching and HTTP 412 rejection
of incompatible digests on open, sync, push and save.

The native WebKit smoke target now imports the same `CollectivesCore` client used
by the app boundary. It still uses the spike's internal Axios/component adapter
on the JavaScript side. Replacing that adapter with a supported Text embedding
interface and the actual app UI orchestration remain the next parts of milestone 1. The regular rich editor
continues to use its existing offline draft path until those parts are ready.

Ownership and request state are currently in memory. Cold-restart Yjs recovery,
durable per-edit checkpoints and restoring pending ownership after a process
restart belong to milestone 2. Draft implementation PRs are open for
[Text](https://github.com/nextcloud/text/pull/9558) and the
[native app](https://github.com/juliusknorr/collectives-swiftui/pull/2).

The repository split is covered by five Python harness-build tests, four Text
manifest-generator tests and six PHP manifest tests. The harness's experimental
JavaScript staging adjustments remain until the embedding API work replaces them.
