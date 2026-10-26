#!/usr/bin/env python3
"""Package generated PNGs into the standard PNG-based macOS ICNS container."""
from pathlib import Path
import struct

root = Path(__file__).resolve().parents[1]
icons = root / 'Resources/Assets.xcassets/AppIcon.appiconset'
entries = [('icp4', 16, 1), ('icp5', 32, 1), ('icp6', 32, 2),
           ('ic07', 128, 1), ('ic08', 256, 1), ('ic09', 512, 1), ('ic10', 512, 2),
           ('ic11', 16, 2), ('ic12', 32, 2), ('ic13', 128, 2), ('ic14', 256, 2)]
chunks = []
for kind, points, scale in entries:
    data = (icons / f'mac-{points}@{scale}x.png').read_bytes()
    chunks.append(kind.encode('ascii') + struct.pack('>I', len(data) + 8) + data)
body = b''.join(chunks)
(root / 'Resources/AppIcon.icns').write_bytes(b'icns' + struct.pack('>I', len(body) + 8) + body)
