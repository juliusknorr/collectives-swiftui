# Native Text collaboration spike

This standalone macOS WebKit harness proves two-client collaboration against a
real Text server. It is separate from the app's existing offline rich editor.

Validated on 2026-10-30 with:

- Text **10.0.0-dev.3**, revision `e3c02e800c15002323124ca118849316416faebb`.
- Nextcloud **36.0.0-dev**, revision `0a362acfb1a`.
- Matching Nextcloud 3rdparty revision `9a181f79a2ad8fa3be4b24a6bfbc0af57ed51e49`.
- The existing `nextcloud:33.0.10-apache` image supplies PHP/Apache only; its
  normal image installer is bypassed and the mounted server source is version 36.

The Text archive checksum and esbuild version are pinned in `text.lock.json`.
The server uses the original, unpatched upstream Text sources and compiled assets.
Only the harness's staged copy receives the native transport adapter and an
internal component accessor. Production app resources and its Text pin are unchanged.

## Start the isolated server

Create a clean Nextcloud server worktree and provide its matching 3rdparty checkout.
The following paths are examples matching this development session:

```sh
git -C ~/repos/nextcloud/server worktree add --detach \
  /private/tmp/collectives-text-collaboration-server 0a362acfb1a

mkdir -p .build/text-collaboration
curl --fail --location \
  https://codeload.github.com/nextcloud/text/tar.gz/e3c02e800c15002323124ca118849316416faebb \
  --output .build/text-collaboration/text.tar.gz
python3 dev/text-collaboration/build.py

export TEXT_SPIKE_SERVER_ROOT=/private/tmp/collectives-text-collaboration-server
export TEXT_SPIKE_THIRDPARTY_ROOT=$HOME/repos/nextcloud/server/3rdparty
export TEXT_SPIKE_TEXT_ROOT=$PWD/.build/text-collaboration/upstream/text-e3c02e800c15002323124ca118849316416faebb
docker compose -f dev/text-collaboration/compose.yaml up -d --pull never
docker exec --user www-data collectives-text-spike-nextcloud-1 php occ maintenance:install \
  --database sqlite --database-name text-spike --admin-user spike \
  --admin-pass local-spike-only --data-dir /var/www/html/data
docker exec --user www-data collectives-text-spike-nextcloud-1 php occ app:enable text
```

Run `maintenance:install` only for a new server worktree. Server configuration and
SQLite data stay in that worktree's ignored directories. This instance binds to
loopback port **18081** and uses public example credentials exclusively for
disposable test data. It does not use or modify the regular Collectives dev server.

## Run the native checks

```sh
bash dev/text-collaboration/run.sh
```

Requires macOS with an unlocked GUI session, Swift/WebKit, Python 3, Node.js and
npm. The first bundle uses the pinned esbuild package. `TEXT_SPIKE_URL` overrides
the loopback test endpoint. The harness obtains an app password in native code;
no real account credentials or Keychain access are needed.

The suite checks:

- Native app-password authentication and two independent nonpersistent WKWebViews.
- No-edit opening/closing preserves exact opaque HTML/comment source and sends
  no file-save request. This does not prove arbitrary unsupported content can
  safely be edited; upstream initialization can still exchange Yjs messages.
- The native bridge rejects another document/session identity.
- Concurrent Unicode edits converge through upstream's provider and real HTTP
  sessions, while withheld save requests leave DAV content unchanged.
- A simulated connection outage on one peer preserves local edits and converges
  with concurrent changes after reconnect.
- An explicit save confirms the saved version, exact canonical DAV Markdown and
  a fresh ETag. Session close then permits a conditional DAV write.
- Closing a session directly on the server causes a real HTTP 403/412 rejection;
  the rejected local work remains in a native Markdown/Yjs checkpoint.

Outputs are ignored under `.build/text-collaboration/`: `result.json`, native
recovery checkpoints, runtime assets, and executable. Recovery checkpoints contain
test document state, account identity and collaboration base identity, with no
passwords or session tokens. The harness cleans up its temporary DAV files.

## Boundaries and next step

Swift owns the fixed server URL, app password, real session token and HTTP client.
JavaScript receives an inert placeholder token and can request only create,
sync, push, save and close for its assigned file/session. The local-file CSP
blocks browser networking; native requests reject redirects. Each WebView has
its own session binding and in-memory browser storage.

The experimental adapter uses Text's internal Axios instance, not a supported
upstream transport API. Its component accessor is pinned to this compiled build.
Server-runtime export, cross-version compatibility, two different users,
cross-account isolation, permission revocation, crash/cold-restart Yjs recovery,
automatic durable checkpoints for interactive typing, App Store validation, and
integration with the app's draft queue remain open. The outage test keeps the
same Y.Doc alive; it is not a cold offline restart test.

Next: turn the experimental seam into an upstream transport/persistence contract,
then integrate the app's explicit draft/session ownership and durable recovery.

To stop this server, use the same environment variables above:

```sh
docker compose -f dev/text-collaboration/compose.yaml down
```
