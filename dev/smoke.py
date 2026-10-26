#!/usr/bin/env python3
"""Check the running real server, including stale-ETag rejection."""

import json
import os
from urllib.error import HTTPError
from uuid import uuid4

from seed import API, Client, FIXTURES, USERS, dav_path, seed_collective


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def main():
    base_url = os.environ.get("NEXTCLOUD_URL", "http://localhost:8080")
    clients = {name: Client(base_url, name, password) for name, password in USERS.items()}
    alice, bob = clients["alice"], clients["bob"]
    alice_collectives = alice.ocs("GET", API)["collectives"]
    bob_collectives = bob.ocs("GET", API)["collectives"]
    require({c["name"] for c in alice_collectives} >= {"Team handbook", "Project notes"},
            "Alice's example collectives are missing.")
    require("Bob's notebook" in {c["name"] for c in bob_collectives}, "Bob's notebook is missing.")
    require(not ({c["id"] for c in alice_collectives} & {c["id"] for c in bob_collectives}),
            "Fresh fixture accounts should have isolated collectives.")

    for fixture in json.loads((FIXTURES / "collectives.json").read_text()):
        client = clients[fixture["owner"]]
        collective = next(c for c in client.ocs("GET", API)["collectives"]
                          if c["name"] == fixture["name"])
        endpoint = f"{API}/{collective['id']}/pages"
        before = client.ocs("GET", endpoint)["pages"]
        seed_collective(client, fixture)
        after = client.ocs("GET", endpoint)["pages"]
        require({p["id"] for p in before} == {p["id"] for p in after},
                "Repeating the seed created duplicate pages.")
        for page in after:
            body, _ = client.request("GET", dav_path(client.username, page))
            body.decode("utf-8")
        if fixture["name"] == "Team handbook":
            offline = next(p for p in after if p["title"] == "Offline guide")
            require(any(p["title"] == "Conflict practice" and p["parentId"] == offline["id"]
                        for p in after), "Nested fixture page is missing.")

    collective = next(c for c in alice_collectives if c["name"] == "Team handbook")
    endpoint = f"{API}/{collective['id']}/pages"
    try:
        bob.ocs("GET", endpoint)
    except HTTPError as error:
        require(error.code in {403, 404}, f"Unexpected access-denied response: {error.code}")
    else:
        raise RuntimeError("Bob can read Alice's private collective.")

    pages = alice.ocs("GET", endpoint)["pages"]
    landing = next(p for p in pages if p["parentId"] == 0)
    page = alice.ocs("POST", f"{endpoint}/{landing['id']}", {
        "title": "Sync smoke " + uuid4().hex[:12],
    })["page"]
    child = None
    try:
        child = alice.ocs("POST", f"{endpoint}/{page['id']}", {
            "title": "Nested smoke 🌱 " + uuid4().hex[:8],
        })["page"]
        refreshed = alice.ocs("GET", endpoint)["pages"]
        page = next(p for p in refreshed if p["id"] == page["id"])
        child = next(p for p in refreshed if p["id"] == child["id"])
        require(child["parentId"] == page["id"], "Created subpage has the wrong parent.")
        child_body, _ = alice.request("GET", dav_path("alice", child))
        child_body.decode("utf-8")
        path = dav_path("alice", page)
        _, headers = alice.request("GET", path)
        stale_etag = headers["ETag"]
        expected = b"# Smoke test\n\nChanged remotely.\n"
        alice.request("PUT", path, expected, {
            "Content-Type": "text/markdown", "If-Match": stale_etag,
        })
        try:
            alice.request("PUT", path, b"stale client overwrite", {"If-Match": stale_etag})
        except HTTPError as error:
            require(error.code == 412, f"Expected HTTP 412, received {error.code}")
        else:
            raise RuntimeError("Server accepted a stale ETag; safe sync cannot rely on it.")
        body, headers = alice.request("GET", path)
        require(body == expected, "Rejected save changed the remote content.")
        require(headers["ETag"] != stale_etag, "Successful save did not change the ETag.")
    finally:
        try:
            if child is not None:
                alice.ocs("DELETE", f"{endpoint}/{child['id']}")
        finally:
            alice.ocs("DELETE", f"{endpoint}/{page['id']}")

    # This checks initiation only; browser approval and token polling are manual.
    body, _ = alice.request("POST", "/index.php/login/v2")
    flow = json.loads(body)
    require(bool(flow.get("login")) and bool(flow.get("poll", {}).get("token"))
            and bool(flow.get("poll", {}).get("endpoint")), "Login Flow v2 initiation failed.")
    print("Real-server smoke checks passed: accounts, nested page creation, repeat seed, DAV, ETags, Login Flow v2 initiation.")


if __name__ == "__main__":
    main()
