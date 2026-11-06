#!/usr/bin/env python3
"""Build the experimental native-transport runtime from pinned production assets."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BUILD = ROOT / '.build/text-collaboration'


def ensure_archive(archive, lock):
    def checksum(path):
        digest = hashlib.sha256()
        with path.open('rb') as contents:
            for chunk in iter(lambda: contents.read(1024 * 1024), b''):
                digest.update(chunk)
        return digest.hexdigest()
    if archive.exists() and checksum(archive) == lock['archive_sha256']:
        return
    archive.parent.mkdir(parents=True, exist_ok=True)
    url = 'https://codeload.github.com/' + lock['repository'] + '/tar.gz/' + lock['revision']
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=archive.parent, delete=False) as output:
            temporary = Path(output.name)
            with urllib.request.urlopen(url, timeout=120) as response:
                shutil.copyfileobj(response, output)
        if checksum(temporary) != lock['archive_sha256']:
            raise SystemExit('Text archive checksum mismatch')
        temporary.replace(archive)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def server_manifest(source, lock):
    subprocess.run(['python3', str(source / 'tools/native-embedding.py'),
                    '--source-revision', lock['revision']], check=True)
    manifest = json.loads((source / 'js/native-embedding.json').read_text())
    if manifest['sourceRevision'] != lock['revision'] or manifest['textVersion'] != lock['version']:
        raise SystemExit('Pinned Text source does not match its runtime manifest')
    return manifest


def main():
    lock = json.loads((HERE / 'text.lock.json').read_text())
    archive = BUILD / 'text.tar.gz'
    ensure_archive(archive, lock)
    upstream = BUILD / 'upstream'
    source = upstream / ('text-' + lock['revision'])
    if not source.exists():
        with tarfile.open(archive) as tar:
            for member in tar:
                path = Path(member.name)
                if path.is_absolute() or '..' in path.parts:
                    raise SystemExit('Unsafe archive path')
                if member.isfile() or member.isdir():
                    tar.extract(member, upstream)
                else:
                    raise SystemExit('Unexpected archive member')
    manifest = server_manifest(source, lock)
    stage = BUILD / 'staged'
    shutil.copytree(source / 'js', stage / 'js', dirs_exist_ok=True,
                    ignore=shutil.ignore_patterns('*.map'))
    preload = stage / 'js/modulepreload-polyfill-CBWYtosv.chunk.mjs'
    preload.write_text(preload.read_text().replace('c.map(r=>{', 'c.filter(r=>r.endsWith(".css")).map(r=>{')
                       .replace('s.crossOrigin="",', ''))
    entry = stage / 'js/text-editor.mjs'
    code = entry.read_text()
    target = 'destroy(){this.#e.unmount()}'
    if code.count(target) != 1:
        raise SystemExit('Pinned wrapper changed; review experimental component hook')
    entry.write_text(code.replace(target,
        'spikeComponent(){return this.#t.$.subTree.component.proxy}' + target))
    shutil.copyfile(HERE / 'runtime.mjs', stage / 'native.mjs')
    runtime = BUILD / 'runtime'
    vendor = runtime / 'vendor'
    vendor.mkdir(parents=True, exist_ok=True)
    subprocess.run(['npx', '--yes', lock['bundler'], str(stage / 'native.mjs'),
                    '--bundle', '--format=iife', '--platform=browser', '--minify',
                    '--define:import.meta.url=document.baseURI', '--legal-comments=eof',
                    '--outfile=' + str(vendor / 'text.js')], check=True)
    shutil.copytree(source / 'css', vendor / 'css', dirs_exist_ok=True)
    shutil.copytree(source / 'LICENSES', vendor / 'LICENSES', dirs_exist_ok=True)
    for notice in (source / 'js').glob('*.license'):
        shutil.copyfile(notice, vendor / notice.name)
    for name in ['bootstrap.js', 'nextcloud-theme.css', 'theme.css']:
        shutil.copyfile(ROOT / 'Resources/EmbeddedText' / name, runtime / name)
    html = (ROOT / 'Resources/EmbeddedText/index.html').read_text()
    html = html.replace('<script defer src="editor.js"></script>', '')
    (runtime / 'index.html').write_text(html)
    (runtime / 'compatibility.json').write_text(json.dumps(manifest, indent=2) + '\n')
    (vendor / 'provenance.json').write_text(json.dumps({**lock,
        'experimental_adjustments': ['Native axios adapter', 'Read-only component hook for harness',
                                    'Local-file CSS preloading']}, indent=2) + '\n')
    print(runtime)


if __name__ == '__main__':
    main()
