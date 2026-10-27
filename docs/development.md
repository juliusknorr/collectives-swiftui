# Development

[Back to README](../README.md)

Run all commands from the repository root. Use Swift 6 or newer.

## Build and run

For local Mac development, install Apple's Command Line Tools or full Xcode, plus Python 3, then run:

```sh
make build       # Build .build/Collectives.app
make run         # Build and open that bundle
make test        # Run Swift tests
```

**Quit the currently running Collectives app before `make run` to use the new build.** The command opens the built bundle using the normal app lifecycle; it does not force-quit the current process or start a second instance. Drafts already saved locally survive a restart. If the app reports a local-save failure, export that work before quitting.

`make build` uses SwiftPM, discovers the actual executable directory with `--show-bin-path`, and creates a signed Mac app bundle. Without a configured identity it uses ad hoc signing. Build output and module caches stay under `.build/`. Builds are incremental, and build/test use the same compiler flags so switching between them reuses compiled modules. Unchanged app bundles are reused without copying or signing again. SwiftPM still checks for source and dependency changes each time. The helper uses the developer tools selected with `xcode-select`. Full Xcode installations use their selected SDK normally. On incomplete preview Command Line Tools installations, it selects the installed macOS 26.5 SDK when the current SDK references missing SwiftUI macros, and explicitly loads the Testing plugin for tests. It does not install or download another SDK.

To override the SDK or build configuration:

```sh
COLLECTIVES_SDK=/path/to/MacOSX.sdk make build
COLLECTIVES_CONFIGURATION=release make build
```

For iPhone, iPad, or a normal Xcode Mac build, open `Collectives.xcodeproj`, choose the **Collectives** scheme, then select a device or simulator. Device builds require your development team in Signing & Capabilities. Initial deployment targets are iOS/iPadOS 17 and macOS 14; older-device compatibility still needs validation. The bundle identity is provisional.

The local bundle is for development. It is not notarized and does not validate Mac App Store sandbox behavior. Mac App Store and signed, notarized direct distribution remain release work.

## Local signing and Keychain prompts

Ad hoc signatures identify a particular build by its code hash. Rebuilding can therefore make macOS ask again before the app reads an existing Keychain credential. Use a persistent signing identity for development:

```sh
make signing-setup   # Once per checkout; requires OpenSSL 3
make build
```

This creates a self-signed development certificate in a private `.local-signing/` keychain and restricts signing-key access to Apple's command-line tools. It does not add system certificate trust. Subsequent builds reuse that certificate. Keep `.local-signing/` private and persistent; it is excluded from Git and separate from `.build/`. Do not delete or regenerate it as part of a clean build.

macOS may ask once when the newly signed app first reads credentials created by an older ad hoc build. Choose **Always Allow** if you want to retain that approval. A locked login keychain can still require unlocking. Release signing and App Store builds use Apple-issued identities separately.

To use an existing Apple development identity instead:

```sh
COLLECTIVES_SIGNING_IDENTITY="<certificate SHA-1 or exact name>" make build
# Optional: COLLECTIVES_SIGNING_KEYCHAIN=/path/to/signing.keychain-db
```

An explicitly selected identity overrides the local setup and becomes part of the build fingerprint. The helper refuses to silently fall back if a configured local identity is incomplete.

## Local document storage

Each account has a versioned manifest, separate page metadata, and one immutable
JSON file per cached document. A document keeps its Markdown base, ETag, draft,
and server conflict copy together. Edits write only that document and atomically
replace the manifest; sync checkpoints reuse unchanged files. Unreferenced files
from interrupted saves are cleaned up when the account next loads.

Old `<account UUID>.json` snapshots migrate automatically on first load and remain
as recovery backups. Once a manifest exists, invalid or unreadable active files
produce an error rather than falling back to stale backup content. Removing an
account deletes both formats, after checking for unsynced work. Older app builds
do not understand the new layout and would read the stale backup; do not use them
to edit a migrated library. Use one `LocalStore` actor per storage root.

## Local Nextcloud test server

Docker Compose v2 and Python 3 are required:

```sh
make server-up     # Start Nextcloud and seed example collectives
make server-test   # Integration checks against the running server
make server-down   # Stop the server, keeping its data
```

Connect the native app to `http://localhost:8080` and complete Nextcloud Login Flow v2 in your browser. Example users:

| User | Browser password | Collectives |
| --- | --- | --- |
| `alice` | `local-alice-only` | Team handbook, Project notes |
| `bob` | `local-bob-only` | Bob's notebook |

These are public credentials for the disposable, loopback-only development server. The app receives its own app password through Login Flow v2. Credentials are stored in Keychain. The example collectives include nested pages, Markdown samples, and offline/conflict exercises. Repeat setup preserves nonempty page bodies and existing edits.

Use `NEXTCLOUD_PORT=8081 make server-up` to select another local port; use the same variable for subsequent server commands. `make server-test` also accepts `NEXTCLOUD_URL`. The integration check creates and trashes temporary parent/child pages and checks stale-ETag rejection; it does not rewrite example page bodies. `make server-down` retains volumes. Deleting volumes is deliberately a separate, explicit command documented in [test server guide](../dev/README.md).

Mac and iOS Simulator can reach the Mac's localhost. Physical devices require a separate reachable HTTPS server. Remote servers require HTTPS; the app permits HTTP only for loopback development addresses. See [test server guide](../dev/README.md) for versions, limits, fixtures, logs, and manual test scenarios.

## Validation

```sh
make test
python3 -m unittest discover -s dev/tests -v
make server-test  # Requires the running, seeded server
```

CI is configured to build native Mac and iOS simulator targets and provision the real server for integration checks. A configured workflow is not evidence of a completed remote CI run. iOS simulator/device behavior, release signing, and browser approval should be checked on an Xcode-equipped machine. The development helper does not run Docker during app builds or Swift tests.

Dependency versions are recorded in `Package.resolved`; bundled notices live in `ThirdParty/`. Current limitations and release validation are described above.

## Project layout

- `Sources/CollectivesApp/`: SwiftUI interface and app lifecycle.
- `Sources/CollectivesCore/`: networking, local storage, Markdown, and sync.
- `Tests/`: Swift tests for both modules.
- `dev/`: local Nextcloud server, fixtures, and integration checks.
- `scripts/`: Mac build, bundling, and local signing helpers.

## Experimental offline Nextcloud Text

The `poc/nextcloud-text` branch embeds a pinned Nextcloud Text build in a local
WKWebView on Mac and iOS. Build normally with `make run`, select a downloaded,
editable page, then select **Rich Text** beside **View / Edit** in the page toolbar.
It runs inline without a web server or network connection. Text edits save into
the same local Markdown drafts as source editing. Native sync pauses in Rich Text;
switch to View or Edit to resume. Page/account changes flush and persist editor
updates before navigating. The original-source recovery action remains in the
**Aa** menu.

The app prewarms one local WebKit runtime at launch and reuses its parsed modules
and styles across pages. A small pinned Text embedding extension replaces the
document in the mounted editor and resets its plugin state, selection and undo
history. During a same-account page switch, the previous document stays visible
but inert until the next document replaces it. Downloads keep the current page
on screen until the new page is available. Mode/account changes clear retained
content. This avoids blank frames and rebuilding Vue/Tiptap on every page switch. The web view stays mounted and visible; a loading indicator
appears only after 180 ms to avoid flashing during fast transitions. View and Edit
stay available during cold startup. Local offline WebKit checks measured about
13–18 ms for a subsequent page; actual time depends on the device and document. Settings let you choose the
default mode or remember your most recently selected mode.

Rich edits can normalize Markdown and discard unsupported syntax. Before the
first Text session on a page, the app saves the exact source in the account's
local snapshot. **Restore Source from Before Text Editing…** in the same menu
restores that copy as a draft. Opening without editing leaves the source alone.
Try this on sample pages first. Attachments, mentions, live collaboration, and
server-side Text sessions are not implemented in this prototype.

The bundled editor receives no credentials or server URL. Network connections
and external navigation are blocked. See
[the embedded editor notes](../Resources/EmbeddedText/README.md) for source revision,
licenses, build adjustments, and asset regeneration.

Generated vendor assets are ignored by Git. `make build` / `make run` and Xcode
prepare them on demand using Python 3 and Node.js 22+ with npm/npx. The first
build needs access to GitHub and npm; verified unchanged output is reused offline.
`make text-assets` prepares only the editor assets. CI caches them using the pinned
lock file and recipe. A full Text npm install is not needed.

Verification:

```sh
make test
python3 -m unittest discover -s scripts/tests -v
make text-assets
node scripts/test-embedded-text.cjs
node scripts/test-text-startup-diagnostics.cjs
xcrun swift scripts/test-embedded-text-webkit.swift Resources/EmbeddedText
# On incomplete preview CLT, add -sdk /path/to/compatible/MacOSX.sdk to xcrun swift.
```

The WebKit smoke uses a synthetic document, loads the actual bundled editor from
`file://`, verifies no initial source rewrite, and checks that a Unicode edit
serializes back to Markdown. It also measures startup and verifies a second page
opens in the same runtime without rewriting source or leaking edits. It does not
contact Nextcloud or modify pages.
iOS device and App Store sandbox validation remain separate checks.

The next experiment is collaboration through Text's existing Yjs provider and
session API. It needs authenticated create/push/sync/close transport, an exclusive
handoff from native WebDAV sync, and persisted CRDT state for offline reconnect.
A generic Yjs WebSocket endpoint is insufficient for Nextcloud Text's protocol.

Editor failures log bounded startup-stage and error-category diagnostics under the
`org.nextcloud.collectives` subsystem, `TextRuntime` category. They include only an
allowlisted bundle-source label and bounded line/column numbers. Markdown, arbitrary
JavaScript exception messages, account data, and file paths are excluded. These
diagnostics identify failures; they do not suppress or recover from them.

Startup restores the cached account and selected note before attempting network
refresh. Keychain reads and writes run away from the UI thread, and prepared API
clients are reused per account. Reauthentication and account removal invalidate
those clients. Restoring a rich-text note leaves server sync paused and does not
wait for credentials.
