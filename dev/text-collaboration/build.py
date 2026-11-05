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


def install_server_contract(source, archive, lock):
    # Always restore these pinned files before applying the repeatable overlay.
    with tarfile.open(archive) as tar:
        prefix = 'text-' + lock['revision'] + '/'
        for name in ['appinfo/routes.php', 'lib/Controller/SessionController.php', 'lib/Middleware/SessionMiddleware.php',
                     'composer/composer/autoload_classmap.php', 'composer/composer/autoload_static.php']:
            target = source / name
            with tar.extractfile(prefix + name) as contents:
                target.write_bytes(contents.read())
    for name, folder in [('RuntimeManifest.php', 'Service'), ('EmbeddingController.php', 'Controller')]:
        shutil.copyfile(HERE / 'upstream' / name, source / 'lib' / folder / name)
    routes = source / 'appinfo/routes.php'
    routes.write_text(routes.read_text().replace("'routes' => [", "'routes' => [\n\t\t['name' => 'Embedding#get', 'url' => '/embedding', 'verb' => 'GET'],", 1))
    middleware = source / 'lib/Middleware/SessionMiddleware.php'
    original = '\t\t$reflectionMethod = new \\ReflectionMethod($controller, $methodName);'
    replacement = '''\t\t$runtimeDigest = $this->request->getParam('runtimeDigest');
\t\tif ($runtimeDigest !== null && $methodName !== 'close'
\t\t\t&& (!is_string($runtimeDigest) || !(new \\OCA\\Text\\Service\\RuntimeManifest())->matches($runtimeDigest))) {
\t\t\tthrow new InvalidDocumentBaseVersionEtagException();
\t\t}

''' + original
    text = middleware.read_text()
    if text.count(original) != 1:
        raise SystemExit('Pinned middleware changed; review runtime gate')
    middleware.write_text(text.replace(original, replacement))
    # Text ships an authoritative Composer map for its production PHP classes.
    for name in ['autoload_classmap.php', 'autoload_static.php']:
        path = source / 'composer/composer' / name
        text = path.read_text()
        anchor = next(line for line in text.splitlines() if "OCA\\\\Text\\\\Controller\\\\SessionController'" in line)
        additions = []
        for cls, relative in [('Controller\\\\EmbeddingController', 'Controller/EmbeddingController'),
                              ('Service\\\\RuntimeManifest', 'Service/RuntimeManifest')]:
            additions.append(anchor.replace('Controller\\\\SessionController', cls).replace('Controller/SessionController', relative))
        path.write_text(text.replace(anchor, anchor + '\n' + '\n'.join(additions)))
    fingerprints = {}
    for folder in ['js', 'css', 'lib', 'appinfo', 'composer/composer']:
        for file in sorted((source / folder).rglob('*')):
            if file.is_file() and file.suffix in ['.mjs', '.css', '.php', '.xml']:
                fingerprints[str(file.relative_to(source))] = hashlib.sha256(file.read_bytes()).hexdigest()
    manifest = dict(format=1, textVersion=lock['version'], sourceRevision=lock['revision'],
                    codeDigest=hashlib.sha256(json.dumps(fingerprints, sort_keys=True, separators=(',', ':')).encode()).hexdigest(),
                    sessionAPI='context-v1', updateEncoding='yjs-sync-v1')
    (source / 'js/native-embedding.json').write_text(json.dumps(manifest, indent=2) + '\n')
    return manifest


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
    manifest = install_server_contract(source, archive, lock)
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
