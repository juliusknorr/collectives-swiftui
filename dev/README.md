# Real Collectives development server

Run from the repository root with Docker Compose v2+ and Python 3 installed:

```sh
./dev/setup.sh
```

This pulls one Nextcloud image, initializes SQLite, enables bundled Teams
(`circles`) and Text, installs checksum-verified Collectives, creates accounts,
and seeds example pages through the real OCS and WebDAV APIs. Allow several
minutes for the first startup. There is no custom Docker build.

Open [Collectives](http://localhost:8080/apps/collectives), or enter
`http://localhost:8080` as the server in the native app and complete Login Flow v2
in your browser. Use the regular test password in the browser. The app receives
its own app password through Login Flow v2.

| User | Local test password | Content |
| --- | --- | --- |
| `alice` | `local-alice-only` | Team handbook, Project notes and Cooking club |
| `bob` | `local-bob-only` | Bob's notebook |
| `admin` | `local-admin-only` | Server administration |

These public credentials are only for this disposable server. The published
port binds to loopback. Do not expose it to the internet or store real data here.

The Mac and iOS Simulator can use localhost. A physical iPhone cannot reach the
Mac through its own localhost. For device testing, provide a separate trusted
HTTPS endpoint and use non-example credentials; this setup deliberately does
not open a LAN port or weaken TLS validation.

## Fixtures and repeat runs

Alice has three collectives; Bob has a separate private collective. Duplicate page
titles across collectives and accounts exercise identity isolation. Team handbook
contains Markdown examples and an Offline guide with a nested Conflict practice
page. Follow the instructions on those pages to test draft persistence, account
switching, reconnect, and competing browser edits.

Cooking club is the large collective: over 60 recipe pages in eight sections,
nested up to five levels deep, with emojis on the collective and every page.
Titles like `Mac & cheese`, `100% rye bread` and `Crème brûlée` test long lists,
search, offline downloads and filename encoding.

The seed script reuses accounts, collectives, and pages. It preserves nonempty
existing page bodies, initializes newly created or empty pages, and uses ETags
for conditional writes. Fixture parent pages must appear before their children;
`parent` is a slash-separated title path such as `Breads/Sourdough loaf`. Fixture
emojis are only set where none is set yet.
If a run is interrupted, rerun setup. The script does not reset changed passwords,
remove user-created content, or overwrite edits to apply newer fixture text.

To test shared access and permission revocation, sign in as Alice in the web
interface and add Bob to the Team handbook team; initially Bob is isolated so
account leaks are easy to detect. Remove Bob again while the app has a draft
to check that a rejected save preserves that draft.

## Commands

```sh
# Use another local port, including on subsequent setup runs.
NEXTCLOUD_PORT=8081 ./dev/setup.sh

# Rerun just the seed, preserving edits.
python3 dev/seed.py

# For a non-default port:
NEXTCLOUD_URL=http://localhost:8081 python3 dev/seed.py

# Inspect status and logs.
docker compose -f dev/compose.yaml ps
docker compose -f dev/compose.yaml logs --tail=100 nextcloud

# Stop while retaining all server data.
docker compose -f dev/compose.yaml down

# Delete this project's server data and start from clean fixtures.
docker compose -f dev/compose.yaml down --volumes
./dev/setup.sh

# Lightweight checks without downloading images or starting Docker services.
docker compose -f dev/compose.yaml config --quiet
sh -n dev/setup.sh dev/bootstrap.sh
python3 -m unittest discover -s dev/tests -v

# Integration checks against the running server. Creates and trashes temporary parent/child
# pages and verifies stale-ETag rejection without modifying example page bodies.
python3 dev/smoke.py
```

## Versions and limits

- Nextcloud `33.0.10-apache`, the version in the official NC33 Dockerfile.
- Collectives `4.7.1`, supporting Nextcloud 32 through 35, with its release archive
  pinned to SHA-256 `6aef84674527393edbfc2915d58014e4ef72bfb27f3ca606b7c1faf985ae0879`.
- Text and Teams are bundled with that server image; no floating app-store installs.
- One container, 1.5 GiB memory limit, two CPUs, and 256 processes. SQLite and AJAX
  background jobs keep the development footprint small. This is not a production
  deployment or a performance-test configuration.
- Server data lives in the Compose project's named volume, outside the checkout.
- Runtime image tags are patch-pinned rather than digest-pinned. To upgrade, update
  the image version and Collectives archive checksum together after compatibility
  testing. Existing unexpected Collectives versions cause setup to fail explicitly.

The local validation checks exercise seed behavior with a simulated API. A full
fresh-server integration run still requires pulling the image and running setup.
The smoke check expects the initial isolated account memberships. Browser approval
and completion of Login Flow v2 remain manual end-to-end checks in the app.

Upstream references: [official Docker image](https://github.com/nextcloud/docker),
[Collectives release](https://github.com/nextcloud/collectives/releases/tag/v4.7.1),
[version compatibility](https://github.com/nextcloud/collectives/blob/v4.7.1/appinfo/info.xml),
[OCS API](https://github.com/nextcloud/collectives/blob/v4.7.1/openapi.json), and
[Login Flow v2](https://docs.nextcloud.com/server/latest/developer_manual/client_apis/LoginFlow/index.html#login-flow-v2).
