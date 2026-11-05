#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."

python3 - <<'PY'
import json
from pathlib import Path
import urllib.request
root = Path('dev/text-collaboration')
lock = json.loads((root / 'text.lock.json').read_text())
archive = Path('.build/text-collaboration/text.tar.gz')
archive.parent.mkdir(parents=True, exist_ok=True)
if not archive.exists():
    url = 'https://codeload.github.com/nextcloud/text/tar.gz/' + lock['revision']
    with urllib.request.urlopen(url, timeout=120) as response, archive.open('wb') as output:
        import shutil
        shutil.copyfileobj(response, output)
PY
python3 dev/text-collaboration/build.py
swift run --scratch-path .build/local TextCollaborationSmoke .build/text-collaboration/runtime "${TEXT_SPIKE_URL:-http://localhost:18081}"
