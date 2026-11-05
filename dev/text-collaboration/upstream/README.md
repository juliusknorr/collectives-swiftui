# Experimental server compatibility overlay

These PHP templates propose a minimal compatibility contract for the pinned Text
10 build. They have not been submitted or merged upstream. `build.py` applies
them to the disposable extracted archive under `.build`, never to the developer's
Text checkout. It restores pinned route, middleware and Composer map files before
each application so rebuilding is repeatable.

`GET /embedding` requires an authenticated user and returns six fields: format,
Text version, source revision, code digest, session API and update encoding.
Missing or invalid metadata, including a mismatch with `appinfo/info.xml`, yields
HTTP 503. Responses are marked `no-store`.

The digest fingerprints sorted paths and SHA-256 hashes of `.mjs`, `.css`, `.php`
and `.xml` files in `js`, `css`, `lib`, `appinfo` and `composer/composer`. The
generated JSON manifest excludes itself. The same manifest is bundled natively.
Code and metadata must be activated together; the manifest is a server assertion,
not a live scan or remote asset attestation. Editing a same-version deployment
without regenerating its metadata breaks this guarantee. Generating metadata at
build time avoids rehashing the editor's roughly 14 MB of JavaScript per request.

Session middleware optionally accepts `runtimeDigest`. A supplied incompatible
digest rejects create/sync/push/save with HTTP 412 before session handling. Native
clients always supply it. Existing browser clients without a digest retain their
behavior. Close remains available for cleanup after an upgrade and does not prove
that the document was saved.

The PHP tests use PHPUnit 9.6 without Nextcloud bootstrap:

```sh
php /path/to/phpunit --no-configuration --do-not-cache-result \
  dev/text-collaboration/upstream/tests/RuntimeManifestTest.php
```

The shared Swift client's account binding, digest propagation, unavailable and
incompatible manifests, and upgrade recovery are covered by `make test`. The
native WebKit smoke suite tests the authenticated endpoint and rejection on all
four guarded session operations against the real server.
