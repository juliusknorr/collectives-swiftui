import argparse
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / 'build-embedded-text.py'
spec = importlib.util.spec_from_file_location('text_build', SCRIPT)
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)


class TextBuildTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.output = self.root / 'Resources/EmbeddedText/vendor'
        self.output.mkdir(parents=True)
        self.lock_path = self.root / 'text.lock.json'
        self.lock_path.write_text('{}')
        self.cache = self.root / 'cache'
        self.cache.mkdir()
        self.args = argparse.Namespace(force=False, text_checkout=None)

    def cached_output(self):
        (self.output / 'text.js').write_text('bundle')
        (self.output / 'text.css').write_text('styles')
        fingerprint = hashlib.sha256(SCRIPT.read_bytes() + self.lock_path.read_bytes()).hexdigest()
        (self.output / build.STAMP).write_text(json.dumps({'recipe': fingerprint, 'files': build.manifest(self.output)}))

    def run_cached(self):
        with patch.object(build, 'ROOT', self.root), patch.object(build, 'LOCK', self.lock_path), patch.object(build.shutil, 'which', return_value=None):
            build.build({'revision': 'test'}, self.cache, self.args)

    def test_verified_output_does_not_need_node_or_network(self):
        self.cached_output()
        with patch.object(build.urllib.request, 'urlopen', side_effect=AssertionError('Unexpected network')):
            self.run_cached()

    def test_missing_or_modified_assets_invalidate_cache(self):
        for damage in ('missing', 'modified'):
            with self.subTest(damage=damage):
                self.cached_output()
                asset = self.output / 'text.css'
                if damage == 'missing':
                    asset.unlink()
                else:
                    asset.write_text('corrupt')
                with self.assertRaisesRegex(SystemExit, 'Node.js'):
                    self.run_cached()

    def test_recipe_lock_change_invalidates_cache(self):
        self.cached_output()
        self.lock_path.write_text('{"revision":"new"}')
        with self.assertRaisesRegex(SystemExit, 'Node.js'):
            self.run_cached()

    def test_archive_checksum_mismatch_is_rejected(self):
        with patch.object(build.urllib.request, 'urlopen', return_value=io.BytesIO(b'untrusted')):
            with self.assertRaisesRegex(SystemExit, 'checksum mismatch'):
                build.source_assets({'revision': 'test', 'archive_sha256': 'wrong'}, self.cache)
        self.assertFalse((self.cache / 'test.tar.gz').exists())

    def test_verified_archive_cannot_write_outside_asset_directory(self):
        archive = self.cache / 'test.tar.gz'
        with tarfile.open(archive, 'w:gz') as contents:
            entry = tarfile.TarInfo('text-test/js/../../escape')
            entry.size = 1
            contents.addfile(entry, io.BytesIO(b'x'))
        with self.assertRaisesRegex(SystemExit, 'Invalid path'):
            build.source_assets({'revision': 'test', 'archive_sha256': build.digest(archive)}, self.cache)
        self.assertFalse((self.cache / 'escape').exists())


if __name__ == '__main__':
    unittest.main()
