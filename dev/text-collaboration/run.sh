#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."

python3 dev/text-collaboration/build.py
swift run --scratch-path .build/local TextCollaborationSmoke .build/text-collaboration/runtime "${TEXT_SPIKE_URL:-http://localhost:18081}"
