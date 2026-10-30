#!/usr/bin/env python3
"""Build the experimental native-transport runtime from pinned production assets."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tarfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BUILD = ROOT / '.build/text-collaboration'


def main():
    lock = json.loads((HERE / 'text.lock.json').read_text())
    archive = BUILD / 'text.tar.gz'
    if hashlib.sha256(archive.read_bytes()).hexdigest() != lock['archive_sha256']:
        raise SystemExit('Text archive checksum mismatch')
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
    (vendor / 'provenance.json').write_text(json.dumps({**lock,
        'experimental_adjustments': ['Native axios adapter', 'Read-only component hook for harness',
                                    'Local-file CSS preloading']}, indent=2) + '\n')
    print(runtime)


if __name__ == '__main__':
    main()
