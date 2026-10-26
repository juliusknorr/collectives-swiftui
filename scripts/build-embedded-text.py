#!/usr/bin/env python3
"""Package a pinned Nextcloud Text build without installing its full toolchain."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

PIN = '8830dfa3b7c4e8dc931e1ab3ea0ce69f14b0c6b5'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('text_checkout', type=Path)
args = parser.parse_args()
source = args.text_checkout.resolve()
revision = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
if revision != PIN:
    raise SystemExit(f'Expected Text revision {PIN}, got {revision}')
if subprocess.check_output(['git', '-C', str(source), 'status', '--porcelain', '--', 'js', 'css'], text=True).strip():
    raise SystemExit('Text built assets must be clean.')
output = Path(__file__).resolve().parents[1] / 'Resources/EmbeddedText/vendor'
with tempfile.TemporaryDirectory() as temporary:
    staging = Path(temporary)
    shutil.copytree(source / 'js', staging / 'js', ignore=shutil.ignore_patterns('*.map'))
    # Dynamic JS imports are folded into the IIFE. Retain Vite CSS loading only,
    # avoiding modulepreload requests from the local-file WKWebView origin.
    preload = staging / 'js/modulepreload-polyfill-CBWYtosv.chunk.mjs'
    code = preload.read_text()
    code = code.replace('c.map(r=>{', 'c.filter(r=>r.endsWith(".css")).map(r=>{')
    preload.write_text(code)
    subprocess.run(['npx', '--yes', 'esbuild@0.25.12', str(staging / 'js/text-editor.mjs'),
                    '--bundle', '--format=iife', '--platform=browser', '--minify',
                    '--define:import.meta.url=document.baseURI', '--legal-comments=eof',
                    f'--outfile={staging / "text.js"}'], check=True)
    output.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(staging / 'text.js', output / 'text.js')
    shutil.copytree(source / 'css', output / 'css', dirs_exist_ok=True, ignore=shutil.ignore_patterns('*.map'))
    shutil.copytree(source / 'LICENSES', output / 'LICENSES', dirs_exist_ok=True)
    notices = output / 'notices'
    notices.mkdir(exist_ok=True)
    for notice in (source / 'js').glob('*.license'):
        shutil.copyfile(notice, notices / notice.name)
(output / 'provenance.json').write_text(json.dumps({
    'project': 'Nextcloud Text', 'version': '10.0.0-dev.0', 'revision': PIN,
    'source': f'https://github.com/nextcloud/text/tree/{PIN}',
    'license': 'AGPL-3.0-or-later', 'bundler': 'esbuild@0.25.12',
    'adjustments': ['Fold dynamic imports into a classic IIFE', 'Preload CSS only',
                    'Resolve import.meta.url against the local document']
}, indent=2) + '\n')
