#!/usr/bin/env python3
"""Seed the loopback-only development server using real OCS and WebDAV APIs."""

import base64
import json
import os
from pathlib import Path
import sys
from urllib.error import HTTPError
from urllib.parse import quote, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener


FIXTURES = Path(__file__).parent / "fixtures"
API = "/ocs/v2.php/apps/collectives/api/v1.0/collectives"
USERS = {"alice": "local-alice-only", "bob": "local-bob-only"}


class NoRedirects(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class Client:
    def __init__(self, base_url, username, password):
        url = urlsplit(base_url)
        if (url.scheme != "http" or url.hostname not in {"localhost", "127.0.0.1", "::1"}
                or url.username or url.password or url.path not in {"", "/"}
                or url.query or url.fragment):
            raise ValueError("Seed credentials may only be used on a loopback HTTP server.")
        self.base_url = base_url.rstrip("/")
        self.username = username
        self.authorization = "Basic " + base64.b64encode(
            f"{username}:{password}".encode()).decode()
        self.opener = build_opener(NoRedirects())

    def request(self, method, path, body=None, headers=None):
        request_headers = {
            "Authorization": self.authorization,
            "OCS-APIRequest": "true",
            "Accept": "application/json",
        }
        request_headers.update(headers or {})
        if isinstance(body, dict):
            body = json.dumps(body).encode()
            request_headers["Content-Type"] = "application/json"
        request = Request(self.base_url + path, data=body,
                          headers=request_headers, method=method)
        with self.opener.open(request, timeout=60) as response:
            return response.read(), response.headers

    def ocs(self, method, path, body=None):
        payload, _ = self.request(method, path + "?format=json", body)
        ocs = json.loads(payload)["ocs"]
        if int(ocs["meta"]["statuscode"]) not in {100, 200}:
            raise RuntimeError(f"OCS failed: {ocs['meta']}")
        return ocs["data"]


def dav_path(username, page):
    # filePath is a relative directory, not the complete filename.
    parts = [page.get("collectivePath"), page.get("filePath"), page["fileName"]]
    if not parts[0]:
        raise ValueError("Page response is missing its collectivePath.")
    relative = "/".join(part.strip("/") for part in parts if part)
    return "/remote.php/dav/files/" + quote(username, safe="") + "/" + quote(relative, safe="/")


def ensure_users(admin):
    for username, password in USERS.items():
        path = "/ocs/v2.php/cloud/users/" + quote(username, safe="")
        try:
            admin.ocs("GET", path)
        except HTTPError as error:
            if error.code != 404:
                raise
            admin.ocs("POST", "/ocs/v2.php/cloud/users", {
                "userid": username, "password": password,
                "displayName": username.title() + " (local test)",
            })


def seed_collective(client, fixture):
    collectives = client.ocs("GET", API)["collectives"]
    matches = [item for item in collectives if item["name"] == fixture["name"]]
    if len(matches) > 1:
        raise RuntimeError(f"Ambiguous collective name: {fixture['name']}")
    collective = matches[0] if matches else client.ocs(
        "POST", API, {"name": fixture["name"]})["collective"]
    if fixture.get("emoji") and not collective.get("emoji"):
        client.ocs("PUT", f"{API}/{collective['id']}", {"emoji": fixture["emoji"]})
    endpoint = f"{API}/{collective['id']}/pages"
    pages = client.ocs("GET", endpoint)["pages"]
    landing = next(page for page in pages if page["parentId"] == 0)
    created = set()
    for item in fixture["pages"]:
        parent_id = resolve_parent_id(pages, item, landing)
        matching = [page for page in pages if page["title"] == item["title"]
                    and page["parentId"] == parent_id]
        if not matching:
            new_page = client.ocs("POST", f"{endpoint}/{parent_id}",
                                  {"title": item["title"]})["page"]
            created.add(new_page["id"])
            # Adding a child can convert its parent into a directory index page.
            pages = client.ocs("GET", endpoint)["pages"]

    for item in fixture["pages"]:
        parent_id = resolve_parent_id(pages, item, landing)
        page = next(page for page in pages if page["title"] == item["title"]
                    and page["parentId"] == parent_id)
        if item.get("emoji") and not page.get("emoji"):
            client.ocs("PUT", f"{endpoint}/{page['id']}/emoji", {"emoji": item["emoji"]})
        path = dav_path(client.username, page)
        existing, headers = client.request("GET", path)
        empty = existing.decode("utf-8").strip() in {"", "# " + item["title"]}
        if page["id"] in created or empty:
            etag = headers.get("ETag")
            if not etag:
                raise RuntimeError("WebDAV did not return an ETag; refusing an unconditional write.")
            client.request("PUT", path, (FIXTURES / item["file"]).read_bytes(), {
                "Content-Type": "text/markdown; charset=utf-8", "If-Match": etag,
            })
            print(f"Seeded {client.username}: {fixture['name']} / {item['title']}")
        else:
            print(f"Kept {client.username}: {fixture['name']} / {item['title']}")


def resolve_parent_id(pages, item, landing):
    # "parent" is a slash-separated title path below the landing page.
    parent_id = landing["id"]
    for title in filter(None, item.get("parent", "").split("/")):
        matching = [page for page in pages if page["title"] == title
                    and page["parentId"] == parent_id]
        if len(matching) != 1:
            raise RuntimeError(f"Fixture parent must already exist and be unique: {item['parent']}")
        parent_id = matching[0]["id"]
    return parent_id


def main():
    base_url = os.environ.get("NEXTCLOUD_URL", "http://localhost:8080")
    ensure_users(Client(base_url, "admin", "local-admin-only"))
    fixtures = json.loads((FIXTURES / "collectives.json").read_text())
    for fixture in fixtures:
        owner = fixture["owner"]
        seed_collective(Client(base_url, owner, USERS[owner]), fixture)


if __name__ == "__main__":
    try:
        main()
    except (HTTPError, RuntimeError, ValueError, OSError) as error:
        print(f"Seeding failed: {error}", file=sys.stderr)
        sys.exit(1)
