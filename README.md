# Collectives

Native SwiftUI app for Nextcloud Collectives on iPhone, iPad, and Mac. This is an early development build, not a release-ready client.

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

Use `NEXTCLOUD_PORT=8081 make server-up` to select another local port; use the same variable for subsequent server commands. `make server-test` also accepts `NEXTCLOUD_URL`. The integration check creates and trashes temporary parent/child pages and checks stale-ETag rejection; it does not rewrite example page bodies. `make server-down` retains volumes. Deleting volumes is deliberately a separate, explicit command documented in [dev/README.md](dev/README.md).

Mac and iOS Simulator can reach the Mac's localhost. Physical devices require a separate reachable HTTPS server. Remote servers require HTTPS; the app permits HTTP only for loopback development addresses. See [dev/README.md](dev/README.md) for versions, limits, fixtures, logs, and manual test scenarios.

## Navigation and settings

The account menu at the top of the sidebar switches between accounts on the same or different servers. Offline content and credentials are isolated per account. Expand page groups with their disclosure arrows; selecting a parent page is independent of expanding its children. Search covers page titles and downloaded text in the selected collective, with ancestor context for nested results.

The sidebar gear opens **Settings**, also available through **Collectives > Settings…** on Mac. Settings include:

- Default page mode: **Preview** or **Edit Markdown**. The preference applies when opening another page; changing modes for the current page does not change the default. Read-only pages remain in Preview.
- Automatically close the collective sidebar after switching collectives, keeping the page list available on larger screens.
- Foreground automatic sync for the active account.
- Add accounts, sign in again through Login Flow v2, export account source backups, and remove accounts from this device.

Removing an account requires confirmation and clears only that account's credentials, downloaded pages, and cached images. Unsynced drafts or conflicts block removal until synced or resolved. Account backups include downloaded Markdown, drafts, and server conflict copies, without credentials; keep exported backups private. Server content is not deleted.

The home view provides recent pages and favorites stored locally per account. The app remembers the last account and page, expanded folders, and reading position on this device. Page headers show their emoji, editing information where available, and sync state. Emoji changes update Collectives on the server. Sync actions remain available separately from Settings; downloads and page refresh are in the collective actions menu.

## Creating and renaming pages

Use **New Page** in the page-list toolbar (⇧⌘N on Mac), or **New Subpage…** in a page's context menu. Choose a title and parent, then create the page online. The app refreshes page paths and downloads the new page for offline editing without replacing existing drafts. This action is available only in writable collectives.

If the server confirms creation but a later refresh or download fails, the page remains listed with a retry action. If creation itself is not confirmed, close the dialog and refresh pages before trying again; the app does not automatically repeat the creation request.

Use **Rename…** in a page's context menu, or **Rename Page…** in the collective actions menu for the current page. Rename updates navigation, the page header, and descendant paths without changing Markdown content, drafts, or base revisions. A leading Markdown H1 remains in the source; the native header displays the page name. Landing pages follow the collective name and cannot be renamed here. Renaming requires a connection; an unconfirmed result must be reviewed with Refresh Pages before retrying.

## Reading and editing

Pages open in **Preview** by default. Choose **Edit** for native Markdown source editing. Formatting controls work with the selected text and provide keyboard shortcuts. Switching modes preserves the source and any draft; the rendered view never rewrites Markdown. The reader provides a headings outline and find-in-page controls for longer documents.

The reader uses Swift Markdown 0.6.0 for CommonMark/GFM parsing and native SwiftUI views for headings, inline formatting, nested/task lists, tables, quotes, and code blocks. Tables and code blocks scroll horizontally; code blocks include a copy action. Task boxes in Preview are indicators; edit their source to change them. Known relative Markdown links open pages in the current collective, and heading anchors navigate within the page. Other supported web links open in the browser. Raw HTML is displayed as inert source; specialized Collectives extensions are not fully supported.

Images load automatically only from the signed-in account's DAV files on its own Nextcloud server. Viewed raster images are cached per account for offline reading. External images require an explicit Open action. SVG and other unsupported image formats show a placeholder with an Open action. Individual raster responses are limited to 12 MiB after download, and displayed images are downsampled to 2048 pixels. Cache eviction and streaming response limits remain follow-up work.

## Offline editing and sync

1. Open a page online to download it, or choose **Download for Offline Editing** in the collective actions menu to download all page text in that collective.
2. Disconnect, edit downloaded pages, and switch between accounts. Drafts persist across app restarts. The sidebar's **Drafts** list includes pending pages even when they are no longer present in the server page list.
3. Reconnect and use **Sync** or **Sync All Accounts**. Foreground automatic sync retries the active account approximately every 30 seconds after at least five seconds without typing.
4. When the server page has changed, compare the retained draft with the server copy. **Queue Local Version** rebases the draft against the reviewed server revision; the next sync attempts a conditional save. **Use Server Version** discards the local draft in favor of that reviewed copy.

Disable automatic sync before practicing manual sync scenarios. Network, authentication, and permission errors preserve local drafts. If the server provides no usable ETag, the app refuses to save unconditionally. Export source if server-side deletion or lost permissions prevent syncing.

Collective downloads include page text only, with incremental checkpoints and resumable retries that preserve drafts. They do not prefetch attachments or images. Local search excludes undownloaded page bodies. Retry currently refreshes clean downloaded pages rather than using conditional downloads. Offline page creation, move/trash/restore, background scheduling, attachment management, and live collaborative editing are not implemented. Mac windows currently share navigation and editing state.

## Validation

```sh
make test
python3 -m unittest discover -s dev/tests -v
make server-test  # Requires the running, seeded server
```

CI is configured to build native Mac and iOS simulator targets and provision the real server for integration checks. A configured workflow is not evidence of a completed remote CI run. iOS simulator/device behavior, release signing, and browser approval should be checked on an Xcode-equipped machine. The development helper does not run Docker during app builds or Swift tests.

Dependency versions are recorded in `Package.resolved`; bundled notices live in `ThirdParty/`. Current limitations and release validation are described above.
