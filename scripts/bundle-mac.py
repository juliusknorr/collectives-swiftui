#!/usr/bin/env python3
"""Wrap a SwiftPM executable in a local development Mac app bundle."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("executable", type=Path)
parser.add_argument("--output", type=Path, default=Path(".build/Collectives.app"))
args = parser.parse_args()
contents = args.output.resolve() / "Contents"
macos = contents / "MacOS"
notices = Path(__file__).resolve().parents[1] / "ThirdParty"
icon = Path(__file__).resolve().parents[1] / "Resources" / "AppIcon.icns"
embedded_text = Path(__file__).resolve().parents[1] / "Resources" / "EmbeddedText"
subprocess.run([sys.executable, str(Path(__file__).with_name("build-embedded-text.py"))], check=True)
signing_directory = Path(__file__).resolve().parents[1] / ".local-signing"
identity = os.environ.get("COLLECTIVES_SIGNING_IDENTITY")
keychain = os.environ.get("COLLECTIVES_SIGNING_KEYCHAIN")
local_signing = identity is None and (signing_directory / "identity.json").exists()
if local_signing:
    identity = json.loads((signing_directory / "identity.json").read_text())["identity"]
    keychain = str(signing_directory / "development.keychain-db")
    if not Path(keychain).is_file() or not (signing_directory / "keychain-password").is_file():
        raise SystemExit("Local signing identity is incomplete. Restore .local-signing; refusing to switch signing identity silently.")
identity = identity or "-"
fingerprint = hashlib.sha256()
fingerprint.update(json.dumps([identity, keychain]).encode())
for source in [Path(__file__), args.executable, icon] + sorted(path for path in notices.rglob("*") if path.is_file()) + sorted(path for path in embedded_text.rglob("*") if path.is_file()):
    fingerprint.update(str(source.resolve()).encode())
    fingerprint.update(b"\0")
    fingerprint.update(source.read_bytes())
expected_fingerprint = fingerprint.hexdigest()
stamp = contents / "Resources" / "development-build.sha256"
if stamp.is_file() and stamp.read_text() == expected_fingerprint:
    verified = subprocess.run(["codesign", "--verify", str(args.output.resolve())],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if verified.returncode == 0:
        print(f"App bundle is up to date: {args.output.resolve()}")
        raise SystemExit(0)
macos.mkdir(parents=True, exist_ok=True)
shutil.copy2(args.executable, macos / "Collectives")
with (contents / "Info.plist").open("wb") as file:
    plistlib.dump({
        "CFBundleExecutable": "Collectives",
        "CFBundleIdentifier": "org.nextcloud.collectives.community.development",
        "CFBundleName": "Collectives",
        "CFBundleIconFile": "AppIcon.icns",
        "CFBundleDisplayName": "Collectives",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "0.1.0",
        "CFBundleVersion": "1",
        "LSMinimumSystemVersion": "14.0",
        "NSHighResolutionCapable": True,
        "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True},
    }, file)
(contents / "Resources").mkdir(parents=True, exist_ok=True)
shutil.copy2(icon, contents / "Resources" / "AppIcon.icns")
shutil.copytree(embedded_text, contents / "Resources" / "EmbeddedText", dirs_exist_ok=True)
if notices.is_dir():
    def copy_notice(source, destination):
        target = Path(destination)
        target.unlink(missing_ok=True)
        shutil.copyfile(source, target)
        target.chmod(0o644)
        return str(target)
    shutil.copytree(notices, contents / "Resources" / "ThirdParty", dirs_exist_ok=True,
                    copy_function=copy_notice)
stamp.parent.mkdir(parents=True, exist_ok=True)
stamp.write_text(expected_fingerprint)
if local_signing:
    unlocked = subprocess.run(["security", "unlock-keychain", "-p",
                              (signing_directory / "keychain-password").read_text(), keychain],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if unlocked.returncode:
        raise SystemExit("Could not unlock the local signing keychain: " + unlocked.stderr.decode(errors="replace"))
signing = ["codesign", "--force", "--sign", identity, "--timestamp=none"]
if keychain:
    signing += ["--keychain", keychain]
subprocess.run(signing + [str(args.output.resolve())], check=True)
print(args.output.resolve())
