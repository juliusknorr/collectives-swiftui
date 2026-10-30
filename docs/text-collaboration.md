# Text collaboration investigation

Investigated 2026-10-30. This is a source review and proposed spike, with no
collaboration implementation or live-session verification yet.

The app branch is `research/text-collaboration`, based on `e11e999`. Upstream
`nextcloud/text` main resolved to `e3c02e800c15002323124ca118849316416faebb`.
The bundled editor remains pinned to `8830dfa3b7c4e8dc931e1ab3ea0ce69f14b0c6b5`.
Files were inspected through GitHub without downloading the full repository or
installing dependencies. The pinned revision also has the context-based create
route and the same public editor constructor options described below.

## Findings

### Embedding exists; native transport injection is missing

Text exposes `createMarkdownContentEditor` and `createCollaborativeEditor`.
The app currently uses the former. The collaborative constructor accepts a
document context and callbacks, but no transport, Y.Doc, or persistence adapter.
Internally, `CollaborativeEditor.vue` constructs its Y.Doc, IndexedDB persistence,
connection, sync service, and provider. Switching the app's constructor alone
would activate browser-oriented networking and persistence.

Sources: [constructors](https://github.com/nextcloud/text/blob/e3c02e800c15002323124ca118849316416faebb/src/createEditor.ts),
[collaborative component](https://github.com/nextcloud/text/blob/e3c02e800c15002323124ca118849316416faebb/src/components/CollaborativeEditor.vue).

The provider already accepts an internal `syncService` and uses a WebSocket
polyfill over HTTP polling. Its localhost WebSocket URL is a placeholder passed
to that polyfill, not a requirement to run a local WebSocket server. However,
`SyncService` directly imports HTTP helpers and constructs `PollingBackend`.
There is no supported public native transport seam in the inspected path.

Sources: [provider](https://github.com/nextcloud/text/blob/e3c02e800c15002323124ca118849316416faebb/src/services/SyncServiceProvider.js),
[sync service](https://github.com/nextcloud/text/blob/e3c02e800c15002323124ca118849316416faebb/src/services/SyncService.ts),
[polyfill](https://github.com/nextcloud/text/blob/e3c02e800c15002323124ca118849316416faebb/src/services/WebSocketPolyfill.ts).

### Session API and file saving are separate

Routes below are relative to `/index.php/apps/text` (or the equivalent rewritten
server URL). They are ordinary app routes, not OCS endpoints.

| Operation | Method and path | Relevant data |
| --- | --- | --- |
| Open | `PUT /session/{type}/{id}/create` | Context such as `file`, context ID, optional `baseVersionEtag` |
| Poll | `POST /session/{documentId}/sync` | Session ID/token, base version ETag, known step version |
| Push | `POST /session/{documentId}/push` | Session ID/token, base version ETag, version, encoded steps, awareness, optional recovery attempt |
| Save file | `POST /session/{documentId}/save` | Session ID/token, base version ETag, version, Markdown, encoded document state, force/manual flags |
| Close | `POST /session/{documentId}/close` | Session ID/token |

Create returns document/session metadata, permissions, and initial content or
document state. Treat returned document IDs as opaque strings. Polling and push
also maintain contact/awareness; no separate keepalive route appears here.

Sources: [routes](https://github.com/nextcloud/text/blob/e3c02e800c15002323124ca118849316416faebb/appinfo/routes.php),
[connect](https://github.com/nextcloud/text/blob/e3c02e800c15002323124ca118849316416faebb/src/apis/connect.ts),
[sync/push](https://github.com/nextcloud/text/blob/e3c02e800c15002323124ca118849316416faebb/src/apis/sync.ts),
[save](https://github.com/nextcloud/text/blob/e3c02e800c15002323124ca118849316416faebb/src/apis/save.ts).

The server stores pushed steps separately from saving the Markdown file. A save
can return HTTP 200 without advancing the saved version, for example when
throttled or locked. Close cleans up the session; it does not call save.
Therefore neither a successful push nor close proves that DAV contains the edits.
The native handoff needs a saved-version check plus canonical Markdown/ETag fetch.

Sources: [API service](https://github.com/nextcloud/text/blob/e3c02e800c15002323124ca118849316416faebb/lib/Service/ApiService.php),
[document saving](https://github.com/nextcloud/text/blob/e3c02e800c15002323124ca118849316416faebb/lib/Service/DocumentService.php),
[client save checks](https://github.com/nextcloud/text/blob/e3c02e800c15002323124ca118849316416faebb/src/services/SaveService.ts).

### Preserve Text's protocol and generation handling

Wire steps contain base64 protocol messages, while `documentState` is a base64
Yjs state update. These are different encodings. Reuse upstream framing,
initialization, recovery, and version tracking rather than sending arbitrary
raw Yjs updates as steps.

Sources: [Yjs helpers](https://github.com/nextcloud/text/blob/e3c02e800c15002323124ca118849316416faebb/src/helpers/yjs.ts),
[initialization](https://github.com/nextcloud/text/blob/e3c02e800c15002323124ca118849316416faebb/src/helpers/setInitialYjsState.ts).

Text's `baseVersionEtag` identifies the collaboration base and must not be
assumed equal to the current DAV ETag. Persist both. Upstream IndexedDB stores
that base and dirty state alongside the Y.Doc; its database name uses context
type/ID. Our native persistence must additionally isolate accounts and servers.
The existing nonpersistent WKWebView cannot provide durable offline recovery.

Sources: [connection handling](https://github.com/nextcloud/text/blob/e3c02e800c15002323124ca118849316416faebb/src/composables/useConnection.ts),
[IndexedDB adapter](https://github.com/nextcloud/text/blob/e3c02e800c15002323124ca118849316416faebb/src/composables/useIndexedDbProvider.ts),
[server checks](https://github.com/nextcloud/text/blob/e3c02e800c15002323124ca118849316416faebb/lib/Middleware/SessionMiddleware.php).

## Relevant upstream work

- [Offline mobile embedding, issue 3674](https://github.com/nextcloud/text/issues/3674)
  is open and directly covers bundling Text for native apps.
- [HTTP provider, issue 7283](https://github.com/nextcloud/text/issues/7283)
  is open. Its [implementation PR 7311](https://github.com/nextcloud/text/pull/7311)
  was closed without merging. Do not assume this replacement exists in main.
- [IndexedDB recovery, PR 7621](https://github.com/nextcloud/text/pull/7621)
  documents generation changes and reconnect scenarios worth reusing as tests.
- [Native/direct-editor close and lock cleanup, issue 8769](https://github.com/nextcloud/text/issues/8769)
  describes related lifecycle problems.

Searches for embedding, standalone, transport, and manifest work found no matching
native asset export/compatibility contract. This is a search result, not proof
that no such work exists. No upstream issues or comments were posted.

## Proposed upstream requests

1. Expose a transport interface across open, poll, push, save, and close, usable
   through the public constructor. Preserve upstream provider behavior while
   native Swift owns URLs, authentication, session tokens, and request limits.
2. Expose Y.Doc persistence hooks with a durable-write acknowledgement, generation
   identity, and safe recovery lifecycle. Keep credentials outside JavaScript.
3. Expose explicit drain/save/close acknowledgements and recoverable failure
   results. The wrapper currently exposes save and synchronous unmount, but no
   public durable-close contract suitable for native navigation.
4. Later, define runtime export assets with hashes, build identity, and explicit
   transport/schema/serializer capabilities. The inspected constructor and route
   contracts do not provide compatibility negotiation.

The local reset/freeze adapter is for standalone Markdown sessions. Do not apply
it to an active collaborative Y.Doc. An upstream standalone reset API remains
useful but is separate from live collaboration.

## Recommended first spike

Use the bundled, pinned runtime with an experimental transport seam. Defer server
runtime downloading. First establish the exact Text build on the test server and
verify app-password authentication, request headers/CSRF behavior, file-context
identity, and API shape using disposable fixtures. Source review alone does not
prove these integration details or compatibility across Text releases.

Keep source drafts and session writes mutually exclusive. On entry, quiesce and
flush the native queue before opening the server session. Initialize from server
state, never overwrite a live Y.Doc with the cached Markdown draft. On exit,
freeze edits, durably checkpoint, drain updates, confirm saved version, close,
then fetch canonical Markdown and DAV ETag before releasing native ownership.
Treat races with other participants and any ambiguous acknowledgement as pending
recovery, not successful completion.

Acceptance checks for that spike:

- Two clients converge, including simultaneous edits and reconnect.
- Pushed-but-unsaved changes cannot be mistaken for a completed handoff.
- Failed/late saves, close failures, expired sessions, and changed permissions
  retain recoverable local work.
- Opening unsupported content performs no normalization/deletion write.
- Source/session transitions prevent overlapping writes and stale callbacks.
- Same file IDs across accounts/servers cannot share state.
- Later offline phase: cold restart preserves acknowledged local Yjs state;
  deleted/replaced files and changed base generations require explicit recovery.

No app build or tests were run for this documentation-only investigation. Live
session, WebKit collaboration, and distribution validation remain open.
