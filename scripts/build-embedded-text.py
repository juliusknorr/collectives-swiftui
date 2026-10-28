#!/usr/bin/env python3
"""Generate the pinned offline Nextcloud Text assets, reusing verified local output."""
import argparse
import fcntl
import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
LOCK = ROOT / 'Resources/EmbeddedText/text.lock.json'
STAMP = '.build-inputs.json'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def manifest(directory):
    return {str(path.relative_to(directory)): digest(path)
            for path in sorted(directory.rglob('*')) if path.is_file() and path.name != STAMP}


def source_assets(lock, cache):
    archive = cache / (lock['revision'] + '.tar.gz')
    if not archive.is_file() or digest(archive) != lock['archive_sha256']:
        print('Fetching pinned Nextcloud Text assets…', flush=True)
        with tempfile.NamedTemporaryFile(dir=cache, delete=False) as download:
            temporary = Path(download.name)
            try:
                url = f"https://codeload.github.com/nextcloud/text/tar.gz/{lock['revision']}"
                with urllib.request.urlopen(url, timeout=120) as response:
                    shutil.copyfileobj(response, download)
                download.close()
                if digest(temporary) != lock['archive_sha256']:
                    raise SystemExit('Text source archive checksum mismatch; refusing to build.')
                temporary.replace(archive)
            finally:
                temporary.unlink(missing_ok=True)
    source = cache / ('source-' + lock['revision'])
    # Re-extract only the assets used by the recipe from the verified archive.
    if source.exists():
        shutil.rmtree(source)
    source.mkdir()
    with tarfile.open(archive) as upstream:
        for member in upstream:
            parts = PurePosixPath(member.name).parts[1:]
            if not parts or parts[0] not in ('js', 'css', 'LICENSES'):
                continue
            if any(part in ('..', '') for part in parts) or PurePosixPath(member.name).is_absolute():
                raise SystemExit('Invalid path in Text archive.')
            target = source.joinpath(*parts)
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            elif member.isfile():
                target.parent.mkdir(parents=True, exist_ok=True)
                with upstream.extractfile(member) as content, target.open('wb') as destination:
                    shutil.copyfileobj(content, destination)
            else:
                raise SystemExit('Unsupported link or special file in Text assets.')
    return source


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('text_checkout', type=Path, nargs='?', help='Optional clean checkout at the pinned revision')
    parser.add_argument('--force', action='store_true', help='Regenerate even if local output is current')
    args = parser.parse_args()
    lock = json.loads(LOCK.read_text())
    cache = ROOT / '.build/embedded-text'
    cache.mkdir(parents=True, exist_ok=True)
    with (cache / 'build.lock').open('w') as mutex:
        fcntl.flock(mutex, fcntl.LOCK_EX)
        build(lock, cache, args)


def build(lock, cache, args):
    PIN = lock['revision']
    output = ROOT / 'Resources/EmbeddedText/vendor'
    fingerprint = hashlib.sha256(Path(__file__).read_bytes() + LOCK.read_bytes()).hexdigest()
    stamp = output / STAMP
    if not args.force and stamp.is_file():
        try:
            saved = json.loads(stamp.read_text())
            if saved['recipe'] == fingerprint and saved['files'] == manifest(output):
                print('Embedded Text assets are up to date.')
                return
        except (OSError, ValueError, KeyError):
            pass
    if not shutil.which('npx'):
        raise SystemExit('Node.js with npm/npx is required to generate Text assets. Install Node.js 22+ and retry.')
    if args.text_checkout:
        source = args.text_checkout.resolve()
        revision = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
        if revision != PIN:
            raise SystemExit(f'Expected Text revision {PIN}, got {revision}')
        if subprocess.check_output(['git', '-C', str(source), 'status', '--porcelain', '--', 'js', 'css', 'LICENSES'], text=True).strip():
            raise SystemExit('Text built assets and licenses must be clean.')
    else:
        source = source_assets(lock, cache)
    with tempfile.TemporaryDirectory(dir=cache) as temporary:
        staging = Path(temporary)
        shutil.copytree(source / 'js', staging / 'js', ignore=shutil.ignore_patterns('*.map'))
        # Dynamic JS imports are folded into the IIFE. Retain Vite CSS loading only,
        # avoiding modulepreload requests from the local-file WKWebView origin.
        preload = staging / 'js/modulepreload-polyfill-CBWYtosv.chunk.mjs'
        code = preload.read_text()
        code = code.replace('c.map(r=>{', 'c.filter(r=>r.endsWith(".css")).map(r=>{')
        code = code.replace('s.crossOrigin="",', '')
        preload.write_text(code)
        # Pinned embedding extension: replace a standalone document without Vue/
        # Tiptap remounting, suppress initial updates and reset all plugin history.
        entry = staging / 'js/text-editor.mjs'
        original = 'setContent(e){return this.#n.content=e,this.#t.setContent?.(e),this}'
        reset = """freezeMarkdownContent(){this.#t.editor.setEditable(false,false)}
        resetMarkdownContent(e,editable=false){
            this.#t.setContent(e,{addToHistory:false});
            const n=this.#t.editor;
            n.view.updateState(n.state.constructor.create({schema:n.schema,doc:n.state.doc,plugins:n.state.plugins}));
            n.setEditable(editable,false);
            this.#t.updateHeadings?.();
            n.emit('transaction',{editor:n,transaction:n.state.tr,appendedTransactions:[]});
            n.emit('selectionUpdate',{editor:n,transaction:n.state.tr});
            return {canUndo:n.can().undo(),canRedo:n.can().redo(),editable:n.isEditable};
        }"""
        entry_code = entry.read_text()
        if entry_code.count(original) != 1:
            raise SystemExit('Pinned Text embedding entry changed; review reset adapter before packaging.')
        entry.write_text(entry_code.replace(original, original + reset))
        subprocess.run(['npx', '--yes', lock['bundler'], str(staging / 'js/text-editor.mjs'),
                        '--bundle', '--format=iife', '--platform=browser', '--minify',
                        '--define:import.meta.url=document.baseURI', '--legal-comments=eof',
                        f'--outfile={staging / "text.js"}'], check=True)
        generated = staging / 'vendor'
        generated.mkdir()
        shutil.copyfile(staging / 'text.js', generated / 'text.js')
        shutil.copytree(source / 'css', generated / 'css', dirs_exist_ok=True, ignore=shutil.ignore_patterns('*.map'))
        shutil.copytree(source / 'LICENSES', generated / 'LICENSES', dirs_exist_ok=True)
        notices = generated / 'notices'
        notices.mkdir(exist_ok=True)
        for notice in (source / 'js').glob('*.license'):
            shutil.copyfile(notice, notices / notice.name)
        (generated / 'provenance.json').write_text(json.dumps({
            'project': 'Nextcloud Text', 'version': '10.0.0-dev.0', 'revision': PIN,
            'source': f'https://github.com/nextcloud/text/tree/{PIN}',
            'license': 'AGPL-3.0-or-later', 'bundler': lock['bundler'],
            'adjustments': ['Fold dynamic imports into a classic IIFE', 'Preload CSS only without a crossorigin attribute for local-file WebKit',
                            'Resolve import.meta.url against the local document',
                            'Add resetMarkdownContent for silent document replacement with fresh plugin state',
                            'Add freezeMarkdownContent for inert retained-content page handoff']
        }, indent=2) + '\n')
        (generated / STAMP).write_text(json.dumps({'recipe': fingerprint, 'files': manifest(generated)}, sort_keys=True) + '\n')
        if output.exists():
            shutil.rmtree(output)
        output.parent.mkdir(parents=True, exist_ok=True)
        generated.replace(output)
    print(f'Generated embedded Text assets: {output}')


if __name__ == '__main__':
    main()
