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
