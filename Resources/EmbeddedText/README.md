# Offline Nextcloud Text prototype

This directory packages the actual Nextcloud Text editor inside the native app.
`vendor/provenance.json` pins the upstream source and documents build adjustments.
The source is available at the pinned GitHub URL; license texts and generated
third-party notices accompany the bundle in `vendor/`.

Regenerate from a checkout at the pinned revision:

```sh
python3 scripts/build-embedded-text.py /path/to/nextcloud/text
```

This uses a pinned esbuild release through npx. It consumes Text's committed
production assets, avoiding a full Text dependency installation. The adapter
and theme live outside vendor. The generated IIFE includes dynamic imports;
Vite retains CSS preloads only. No Nextcloud Text source changes are required.

The native app uses a nonpersistent WKWebView and local-file resources, with a
CSP that disallows network connections, external images, frames, and forms.
The web runtime receives Markdown and an opaque editor session UUID. It gets no
server URL, account identifier, credentials, cookies, or native file paths.
Native code owns drafts, account selection, persistence, and conditional sync.

The first session preserves the exact source in an optional per-account snapshot
backup. The Text menu can restore it. Opening and closing without editing must
not normalize source or create a draft. Rich edits may reserialize the entire
file and lose unsupported Markdown/HTML; use a test page first. Attachments,
mentions, external links, live collaboration, and server-side Text sessions are
outside this POC. Keep Markdown source editing as the fallback.
