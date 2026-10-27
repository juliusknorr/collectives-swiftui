# Offline Nextcloud Text prototype

This directory packages the actual Nextcloud Text editor inside the native app.
`vendor/provenance.json` pins the upstream source and documents build adjustments.
The source is available at the pinned GitHub URL; license texts and generated
third-party notices accompany the bundle in `vendor/`.

The generated `vendor/` directory is ignored by Git. `text.lock.json` pins the
upstream revision, source-archive SHA-256, and esbuild version. Generate it with:

```sh
make text-assets
```

`make build` / `make run` and the Xcode target generate these resources automatically.
The first generation requires Python 3, Node.js 22+ with npm/npx, and network access
to GitHub and npm. The recipe fetches a checksum-verified source archive and uses
Text's existing production assets, avoiding a full Text npm install. Source archives
are cached in `.build/embedded-text/`. Generated JavaScript, CSS, licenses, notices,
and provenance remain in `vendor/` locally and are packaged into the app.

A fingerprint of the recipe and lock file plus a manifest of all generated files
lets unchanged builds reuse the output, including offline and without invoking
Node.js. Missing or modified output triggers regeneration. `--force` regenerates
explicitly; a clean checkout at the pinned revision can optionally replace the
automatic source fetch:

```sh
python3 scripts/build-embedded-text.py --force
python3 scripts/build-embedded-text.py /path/to/nextcloud/text
```

The adapter and theme remain tracked outside vendor. The generated IIFE includes
dynamic imports; Vite retains CSS preloads only. The recipe adds a small
`resetMarkdownContent` embedding method to its staged copy of Text. It replaces
content without emitting an initial update, creates fresh ProseMirror plugin state
to clear undo/redo and selection, sets editability directly without emitting an
update, and refreshes headings/toolbar state. The idle document is empty and
noneditable; the editing toolbar stays mounted for subsequent sessions. The recipe
does not change the document schema, Markdown parser, or serializer. The original
Text checkout stays unchanged. The patch fails if its expected entry point changes.

The native app uses a nonpersistent WKWebView and local-file resources, with a
CSP that disallows network connections, external images, frames, and forms.
The web runtime receives Markdown and an opaque editor session UUID. It gets no
server URL, account identifier, credentials, cookies, or native file paths.
Native code owns drafts, account selection, persistence, and conditional sync.

The app warms one mounted editor at launch. Page changes use silent document
replacement and fresh plugin state rather than recreating Vue/Tiptap. Closing a
session normally clears its document and history while retaining the editor and
assets. Same-account page navigation instead freezes the old document and marks
its DOM inert, keeping it visible until atomic replacement. Other transitions,
including account switches, clear retained content even if no session is active. Inline
View/Edit/Rich Text transitions flush updates before changing pages or accounts.

The first session preserves the exact source in an optional per-account snapshot
backup. The Text menu can restore it. Opening and closing without editing must
not normalize source or create a draft. Rich edits may reserialize the entire
file and lose unsupported Markdown/HTML; use a test page first. Attachments,
mentions, external links, live collaboration, and server-side Text sessions are
outside this POC. Keep Markdown source editing as the fallback.
