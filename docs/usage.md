# Using Collectives

[Back to README](../README.md)

## Navigation and settings

The sidebar groups collectives by account, labeled with the username and server URL. Select a collective or an account’s Home to activate that account automatically. Home, drafts, and the command palette use the selected account. Home shows the account sidebar and dashboard without a page-list column; selecting a collective restores page navigation. Use **Add Account…** in the sidebar or manage accounts in Settings. Cached collective lists remain visible offline; **Refresh All Collectives** updates every account. Offline content and credentials are isolated per account. Expand page groups with their disclosure arrows; selecting a parent page is independent of expanding its children. Search covers page titles and downloaded text in the selected collective, with ancestor context for nested results.

Press **Cmd+K** or use **Command Palette** in the toolbar to jump between locally indexed pages across all collectives in the active account. Search by page title, collective, or ancestor names; recently opened pages appear first with an empty search. Use **↑/↓** to select, **Enter** to open, and **Escape** to dismiss. Downloaded pages open offline without refreshing the collective; pages with only synced metadata need a connection to download their text. The Markdown editor uses **Cmd+Shift+K** to insert a link.

After approving a browser sign-in, return to Collectives to finish connecting. Polling pauses while the browser is active and temporary connection interruptions retry automatically. If finishing sign-in fails, **Retry Sign-In** can complete the existing approval without opening another browser flow.

The sidebar gear opens **Settings**, also available through **Collectives > Settings…** on Mac. Settings include:

- Default page mode: **Preview** or **Edit Markdown**. The preference applies when opening another page; changing modes for the current page does not change the default. Read-only pages remain in Preview.
- Automatically close the collective sidebar after switching collectives, keeping the page list available on larger screens.
- Foreground automatic sync for the active account.
- Add accounts, sign in again through Login Flow v2, export account source backups, and remove accounts from this device.

Removing an account requires confirmation and clears only that account's credentials, downloaded pages, and cached images. You can remove an account while sync is running: its sync is canceled, late responses are ignored, and other accounts continue syncing. Unsynced drafts or conflicts block removal until synced or resolved. Account backups include downloaded Markdown, drafts, and server conflict copies, without credentials; keep exported backups private. Server content is not deleted.

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
3. Reconnect and use **Sync** or **Sync All Accounts**. Startup performs a full sync of every account, including collective lists, page lists, and page text. Foreground automatic sync refreshes the active account every minute and retries saved drafts approximately every 30 seconds after at least five seconds without typing.
4. When the server page has changed, compare the retained draft with the server copy. **Review Changes…** opens a comparison of your changes and the server copy. **Keep My Changes** queues your draft against the reviewed server revision for the next sync. **Use Server Changes** asks for confirmation before discarding your draft. Closing the comparison keeps the conflict unresolved.

When the server advertises a same-origin notify_push WebSocket endpoint, the app authenticates with the account’s app password and listens for file and Collectives page-list changes. Collective sessions are refreshed every minute to receive page-list notifications. Push changes trigger a refresh; a 15-minute safety poll catches missed events. Connection or session failures restore one-minute polling and trigger reconnection attempts. Push connections close when the app leaves the foreground, automatic sync is disabled, or the active account changes.

Page downloads send the cached ETag in `If-None-Match`; HTTP 304 retains the local body without downloading it again. Pages without a cached revision need a full download. Startup sync runs even when ongoing automatic sync is disabled.

Disable automatic sync before practicing manual sync scenarios. Sync keeps navigation and editing available while requests are in progress, preserving changes typed during a request. Sync processes up to three pages in parallel, including collective downloads and pending draft uploads. During sync, a progress panel stays visible as you navigate. It shows the account, collective, current page, operation, and pages processed in that collective. Page counts advance after local checkpoints are saved; failures are counted separately. Use **Cancel** in the progress panel or sync details to stop the current run, including queued accounts and in-flight page requests. Completed saves and local drafts are kept. Automatic sync pauses for this session until you start a manual sync; restarting the app also restores your usual automatic-sync setting. Tap the sidebar sync status for details. The idle sync status shows pending drafts and conflicts; failures provide a retry action, and expired sign-in provides **Sign In Again…**. Network, authentication, and permission errors preserve local drafts. If the server provides no usable ETag, the app refuses to save unconditionally. Export source if server-side deletion or lost permissions prevent syncing.

Collective downloads include page text only, with incremental checkpoints and resumable retries that preserve drafts. They do not prefetch attachments or images. Local search excludes undownloaded page bodies. Retries use conditional downloads for clean cached pages. Offline page creation, move/trash/restore, background scheduling, attachment management, and live collaborative editing are not implemented. Mac windows currently share navigation and editing state.
