#!/usr/bin/env python3
"""Check the running real server, including stale-ETag rejection."""

import json
import os
from urllib.error import HTTPError
from urllib.parse import unquote, urlsplit
from uuid import uuid4
from xml.etree import ElementTree

from seed import API, Client, FIXTURES, USERS, dav_path, seed_collective


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def folder_etag(client, path):
    folder = path.rsplit("/", 1)[0] + "/"
    body, _ = client.request("PROPFIND", folder,
                            b'<d:propfind xmlns:d="DAV:"><d:prop><d:getetag/></d:prop></d:propfind>',
                            {"Depth": "1", "Content-Type": "application/xml", "Accept": "application/xml"})
    root = ElementTree.fromstring(body)
    for response in root.findall("{DAV:}response"):
        href = response.findtext("{DAV:}href", "")
        if unquote(urlsplit(href).path) != unquote(path):
            continue
        for propstat in response.findall("{DAV:}propstat"):
            if propstat.findtext("{DAV:}status", "").split()[1:2] == ["200"]:
                etag = propstat.findtext("{DAV:}prop/{DAV:}getetag")
                if etag:
                    return etag
    raise RuntimeError("Folder PROPFIND did not return the page's ETag.")


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
    destination = None
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
        parent_body, _ = alice.request("GET", dav_path("alice", page))
        old_child_path = dav_path("alice", child)
        new_title = "Renamed smoke 🌱 " + uuid4().hex[:8]
        renamed = alice.ocs("PUT", f"{endpoint}/{page['id']}", {"title": new_title})["page"]
        require(renamed["id"] == page["id"], "Renaming changed the page identity.")
        require(renamed["title"] == new_title, "Renamed page title was not returned.")
        refreshed = alice.ocs("GET", endpoint)["pages"]
        page = next(p for p in refreshed if p["id"] == page["id"])
        child = next(p for p in refreshed if p["id"] == child["id"])
        require(dav_path("alice", child) != old_child_path, "Renaming a parent did not update its child path.")
        renamed_body, _ = alice.request("GET", dav_path("alice", page))
        renamed_child_body, _ = alice.request("GET", dav_path("alice", child))
        require(renamed_body == parent_body, "Renaming rewrote the parent Markdown.")
        require(renamed_child_body == child_body, "Renaming rewrote the child Markdown.")
        path = dav_path("alice", page)
        _, headers = alice.request("GET", path)
        stale_etag = headers["ETag"]
        require(folder_etag(alice, path) == stale_etag,
                "Folder ETag differs from the downloaded revision.")
        require(folder_etag(alice, dav_path("alice", child)) == alice.request("GET", dav_path("alice", child))[1]["ETag"],
                "Nested page folder ETag differs from its downloaded revision.")
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
        require(folder_etag(alice, path) == headers["ETag"],
                "Folder metadata did not detect the changed content.")

        destination = alice.ocs("POST", f"{endpoint}/{landing['id']}", {
            "title": "Move destination " + uuid4().hex[:12],
        })["page"]
        old_child_path = dav_path("alice", child)
        moved = alice.ocs("PUT", f"{endpoint}/{page['id']}", {"parentId": destination["id"]})["page"]
        require(moved["id"] == page["id"] and moved["parentId"] == destination["id"],
                "Moving changed the page identity or returned the wrong parent.")
        refreshed = alice.ocs("GET", endpoint)["pages"]
        page = next(p for p in refreshed if p["id"] == page["id"])
        child = next(p for p in refreshed if p["id"] == child["id"])
        destination = next(p for p in refreshed if p["id"] == destination["id"])
        require(destination["fileName"] == "Readme.md", "Moving into a leaf did not update its path.")
        require(dav_path("alice", child) != old_child_path, "Moving did not update descendant paths.")
        require(alice.request("GET", dav_path("alice", page))[0] == expected,
                "Moving changed the page Markdown.")
        require(alice.request("GET", dav_path("alice", child))[0] == child_body,
                "Moving changed descendant Markdown.")
        for method, suffix, payload in [("PUT", str(page["id"]), {"parentId": landing["id"]}),
                                         ("DELETE", str(page["id"]), None)]:
            try:
                bob.ocs(method, f"{endpoint}/{suffix}", payload)
            except HTTPError as error:
                require(error.code in {403, 404}, "Unexpected structural permission response.")
            else:
                raise RuntimeError("Bob could change Alice's private pages.")
        alice.ocs("DELETE", f"{endpoint}/{page['id']}")
        active_ids = {p["id"] for p in alice.ocs("GET", endpoint)["pages"]}
        require(page["id"] not in active_ids and child["id"] not in active_ids,
                "Trashing a parent left its subtree active.")
        require(page["id"] in {p["id"] for p in alice.ocs("GET", endpoint + "/trash")["pages"]},
                "Trashed page was not listed for restore.")
        try:
            bob.ocs("PATCH", f"{endpoint}/trash/{page['id']}")
        except HTTPError as error:
            require(error.code in {403, 404}, "Unexpected restore permission response.")
        else:
            raise RuntimeError("Bob could restore Alice's private page.")
        restored = alice.ocs("PATCH", f"{endpoint}/trash/{page['id']}")["page"]
        require(restored["id"] == page["id"], "Restoring changed the page identity.")
        refreshed = alice.ocs("GET", endpoint)["pages"]
        page = next(p for p in refreshed if p["id"] == page["id"])
        child = next(p for p in refreshed if p["id"] == child["id"])
        require(alice.request("GET", dav_path("alice", page))[0] == expected,
                "Restore changed the parent Markdown.")
        require(alice.request("GET", dav_path("alice", child))[0] == child_body,
                "Restore lost or changed descendant Markdown.")
    finally:
        try:
            if child is not None:
                alice.ocs("DELETE", f"{endpoint}/{child['id']}")
        finally:
            try:
                alice.ocs("DELETE", f"{endpoint}/{page['id']}")
            finally:
                if destination is not None:
                    alice.ocs("DELETE", f"{endpoint}/{destination['id']}")

    # This checks initiation only; browser approval and token polling are manual.
    body, _ = alice.request("POST", "/index.php/login/v2")
    flow = json.loads(body)
    require(bool(flow.get("login")) and bool(flow.get("poll", {}).get("token"))
            and bool(flow.get("poll", {}).get("endpoint")), "Login Flow v2 initiation failed.")
    print("Real-server smoke checks passed: accounts, nested creation/rename/move/trash/restore, permissions, repeat seed, DAV, folder ETags, Login Flow v2 initiation.")


if __name__ == "__main__":
    main()
