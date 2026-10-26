import contextlib
import importlib.util
import io
from pathlib import Path
import unittest


spec = importlib.util.spec_from_file_location("seed", Path(__file__).parents[1] / "seed.py")
seed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(seed)


class FakeClient:
    username = "alice"

    def __init__(self):
        self.collectives = []
        self.pages = []
        self.bodies = {}
        self.writes = 0

    def ocs(self, method, path, body=None):
        if path == seed.API:
            if method == "GET":
                return {"collectives": self.collectives.copy()}
            collective = {"id": 1, "name": body["name"], "emoji": None}
            self.collectives.append(collective)
            self.pages.append({"id": 10, "title": "Landing page", "parentId": 0,
                               "fileName": "Readme.md", "filePath": "",
                               "collectivePath": "Collectives/Team handbook"})
            return {"collective": collective}
        if method == "PUT" and path.endswith("/emoji"):
            page_id = int(path.rsplit("/", 2)[1])
            next(p for p in self.pages if p["id"] == page_id)["emoji"] = body["emoji"]
            return {}
        if method == "PUT":
            self.collectives[0]["emoji"] = body["emoji"]
            return {}
        if method == "GET":
            return {"pages": [p.copy() for p in self.pages]}
        page = {"id": 10 + len(self.pages), "title": body["title"],
                "parentId": int(path.rsplit("/", 1)[1]), "fileName": body["title"] + ".md",
                "filePath": "", "collectivePath": "Collectives/Team handbook"}
        self.pages.append(page)
        return {"page": page}

    def request(self, method, path, body=None, headers=None):
        if method == "GET":
            return self.bodies.get(path, b""), {"ETag": '"version-1"'}
        if headers.get("If-Match") != '"version-1"':
            raise AssertionError("Seed attempted an unconditional write")
        self.bodies[path] = body
        self.writes += 1
        return b"", {}


class SeedTests(unittest.TestCase):
    def test_dav_joins_directory_filename_and_encodes_once(self):
        page = {"collectivePath": "Collectives/Team handbook", "filePath": "Offline guide",
                "fileName": "Grüße & 100%.md"}
        self.assertEqual(seed.dav_path("alice@example", page),
                         "/remote.php/dav/files/alice%40example/Collectives/Team%20handbook/"
                         "Offline%20guide/Gr%C3%BC%C3%9Fe%20%26%20100%25.md")

    def test_dav_requires_server_provided_mount_path(self):
        with self.assertRaises(ValueError):
            seed.dav_path("alice", {"fileName": "Readme.md"})

    def test_example_credentials_are_loopback_only(self):
        for url in ["https://example.com", "http://192.168.1.2", "http://localhost.evil.test",
                    "http://localhost@evil.test", "http://localhost/path", "http://localhost?query"]:
            with self.subTest(url=url), self.assertRaises(ValueError):
                seed.Client(url, "alice", "password")
        seed.Client("http://localhost:8080", "alice", "password")

    def test_repeat_seed_preserves_user_edits_and_ids(self):
        client = FakeClient()
        fixture = {"name": "Team handbook", "pages": [
            {"title": "Welcome", "file": "welcome.md"},
            {"title": "Offline guide", "file": "offline.md"},
            {"title": "Conflict practice", "parent": "Offline guide", "file": "conflicts.md"},
        ]}
        with contextlib.redirect_stdout(io.StringIO()):
            seed.seed_collective(client, fixture)
            ids = [p["id"] for p in client.pages]
            changed_path = seed.dav_path("alice", client.pages[1])
            client.bodies[changed_path] = b"User edited this page."
            seed.seed_collective(client, fixture)
        self.assertEqual([p["id"] for p in client.pages], ids)
        self.assertEqual(client.writes, 3)
        self.assertEqual(client.bodies[changed_path], b"User edited this page.")
        self.assertEqual(client.pages[-1]["parentId"], client.pages[-2]["id"])

    def test_deep_nesting_and_emoji_keep_user_choices(self):
        client = FakeClient()
        fixture = {"name": "Cooking club", "emoji": "🍳", "pages": [
            {"title": "Breads", "emoji": "🍞", "file": "welcome.md"},
            {"title": "Sourdough", "parent": "Breads", "file": "welcome.md"},
            {"title": "Starter", "parent": "Breads/Sourdough", "emoji": "🫙", "file": "welcome.md"},
        ]}
        with contextlib.redirect_stdout(io.StringIO()):
            seed.seed_collective(client, fixture)
            client.pages[1]["emoji"] = "🥖"
            seed.seed_collective(client, fixture)
        landing, breads, sourdough, starter = client.pages
        self.assertEqual(starter["parentId"], sourdough["id"])
        self.assertEqual(sourdough["parentId"], breads["id"])
        self.assertEqual([breads["emoji"], starter["emoji"]], ["🥖", "🫙"])
        self.assertEqual(client.collectives[0]["emoji"], "🍳")
        self.assertEqual(len(client.pages), 4)

    def test_interrupted_seed_initializes_empty_existing_page(self):
        client = FakeClient()
        fixture = {"name": "Team handbook", "pages": [{"title": "Welcome", "file": "welcome.md"}]}
        with contextlib.redirect_stdout(io.StringIO()):
            seed.seed_collective(client, fixture)
            client.bodies.clear()
            seed.seed_collective(client, fixture)
        self.assertEqual(len(client.pages), 2)
        self.assertEqual(client.writes, 2)


if __name__ == "__main__":
    unittest.main()
