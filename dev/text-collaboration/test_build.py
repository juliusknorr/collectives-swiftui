"""Regression checks for consuming the pinned Text branch without server patches."""
import importlib.util
import hashlib
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('text_build', Path(__file__).with_name('build.py'))
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


class TextBranchBuildTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.source = Path(self.directory.name)
        (self.source / 'tools').mkdir()
        (self.source / 'js').mkdir()
        self.lock = dict(revision='a' * 40, version='10.0.0-dev.3')

    def generator(self, version='10.0.0-dev.3', revision=None):
        # The fixture accepts the same revision argument as the Text-owned tool.
        script = '''import json, sys
from pathlib import Path
root = Path(__file__).resolve().parents[1]
revision = sys.argv[sys.argv.index('--source-revision') + 1]
'''
        script += 'manifest = ' + repr(dict(sourceRevision=revision, textVersion=version)) + '\n'
        if revision is None:
            script += "manifest['sourceRevision'] = revision\n"
        script += "(root / 'js/native-embedding.json').write_text(json.dumps(manifest))\n"
        (self.source / 'tools/native-embedding.py').write_text(script)

    def test_uses_text_owned_generator_with_pinned_revision(self):
        self.generator()
        metadata = builder.server_manifest(self.source, self.lock)
        self.assertEqual(self.lock['revision'], metadata['sourceRevision'])
        self.assertEqual(self.lock['version'], metadata['textVersion'])
        self.assertEqual({'tools', 'js'}, {path.name for path in self.source.iterdir()})

    def test_incorrect_source_metadata_is_rejected(self):
        for version, revision in [('other', None), ('10.0.0-dev.3', 'b' * 40)]:
            self.generator(version, revision)
            with self.assertRaises(SystemExit):
                builder.server_manifest(self.source, self.lock)

    def test_missing_text_generator_fails_without_creating_metadata(self):
        import subprocess
        with self.assertRaises(subprocess.CalledProcessError):
            builder.server_manifest(self.source, self.lock)
        self.assertFalse((self.source / 'js/native-embedding.json').exists())

    def test_archive_refreshes_when_switching_to_the_text_branch(self):
        archive = self.source / 'text.tar.gz'
        archive.write_bytes(b'old upstream archive')
        content = b'pinned branch archive'
        lock = dict(repository='example/text', revision='a' * 40,
                    archive_sha256=hashlib.sha256(content).hexdigest())
        with patch.object(builder.urllib.request, 'urlopen', return_value=io.BytesIO(content)) as fetch:
            builder.ensure_archive(archive, lock)
            fetch.assert_called_once_with('https://codeload.github.com/example/text/tar.gz/' + 'a' * 40, timeout=120)
        self.assertEqual(content, archive.read_bytes())
        with patch.object(builder.urllib.request, 'urlopen') as fetch:
            builder.ensure_archive(archive, lock)
            fetch.assert_not_called()

    def test_incorrect_download_never_replaces_existing_archive(self):
        archive = self.source / 'text.tar.gz'
        archive.write_bytes(b'old upstream archive')
        lock = dict(repository='example/text', revision='a' * 40, archive_sha256='b' * 64)
        with patch.object(builder.urllib.request, 'urlopen', return_value=io.BytesIO(b'incorrect download')):
            with self.assertRaises(SystemExit):
                builder.ensure_archive(archive, lock)
        self.assertEqual(b'old upstream archive', archive.read_bytes())
        self.assertEqual({'tools', 'js', 'text.tar.gz'}, {path.name for path in self.source.iterdir()})


if __name__ == '__main__':
    unittest.main()
