# Native host embedding demo

This fixture belongs to the native app tooling. Text supplies only a per-editor
transport, `exportState()` and `drain()`. The host implements checkpoint writes,
save-version checks and session closure using those public methods.

Use Node 24 and a Text worktree containing the small embedding seam, with its npm
dependencies installed. Start the disposable Nextcloud fixture from the parent
README, with this Text branch enabled, then run:

```sh
npm ci --prefix dev/text-collaboration/embedding
export TEXT_EMBEDDING_SOURCE=/path/to/text-worktree
npm --prefix dev/text-collaboration/embedding run demo
# Open http://127.0.0.1:8093/ and use the client A/B links.
npm --prefix dev/text-collaboration/embedding test
npm --prefix dev/text-collaboration/embedding run test:unit
```

The default server is `http://localhost:18081`, using disposable credentials
`spike` / `local-spike-only`. `TEXT_EMBEDDING_SERVER`, `TEXT_EMBEDDING_USER` and
`TEXT_EMBEDDING_PASSWORD` override those settings in the host process. It accepts
only loopback HTTP servers. Credentials and real session tokens stay outside the
page. Do not use production accounts.

The demo uses port 8093; tests use a separate host and file on 8094. Normal
shutdown closes sessions and removes the UUID-named test file and checkpoints.
Reconnect retains the same Y.Doc. Checkpoint decoding is tested, but restoring
into a fresh server session, per-edit durability and cold-restart recovery are
not implemented. The Swift/WebKit harness still uses its earlier pinned runtime
until its bundle and bridge migrate to this public API.
