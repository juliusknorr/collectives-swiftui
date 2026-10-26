#!/usr/bin/env python3
"""Create a persistent, project-local development signing identity."""
import hashlib
import json
import os
from pathlib import Path
import secrets
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
directory = root / '.local-signing'
directory.mkdir(mode=0o700, exist_ok=True)
os.chmod(directory, 0o700)
config = directory / 'identity.json'
if config.exists():
    print('Local signing is already configured. Keep .local-signing to preserve the identity.')
    raise SystemExit(0)
keychain = directory / 'development.keychain-db'
password_file = directory / 'keychain-password'
certificate = directory / 'certificate.pem'
if keychain.exists() or password_file.exists() or certificate.exists():
    raise SystemExit('Incomplete local signing setup exists. Inspect .local-signing before retrying; it may contain a signing key.')
password = secrets.token_hex(32)
password_file.write_text(password)
os.chmod(password_file, 0o600)
name = 'Collectives Local Development ' + hashlib.sha256(str(root).encode()).hexdigest()[:12]

def run(arguments, **options):
    result = subprocess.run(arguments, stdout=subprocess.PIPE, stderr=subprocess.PIPE, **options)
    if result.returncode:
        raise SystemExit('Local signing setup failed: ' + result.stderr.decode(errors='replace').strip())
    return result

with tempfile.TemporaryDirectory(prefix='identity-', dir=directory) as temporary:
    private_key = str(Path(temporary) / 'key.pem')
    archive = str(Path(temporary) / 'identity.p12')
    run(['openssl', 'req', '-x509', '-newkey', 'rsa:3072', '-sha256', '-days', '3650',
         '-nodes', '-keyout', private_key, '-out', str(certificate), '-subj', '/CN=' + name,
         '-addext', 'extendedKeyUsage=codeSigning', '-addext', 'keyUsage=critical,digitalSignature',
         '-addext', 'basicConstraints=critical,CA:FALSE'])
    env = dict(os.environ, COLLECTIVES_P12_PASSWORD=password)
    run(['openssl', 'pkcs12', '-export', '-legacy', '-inkey', private_key,
                    '-in', str(certificate), '-out', archive, '-name', name,
                    '-passout', 'env:COLLECTIVES_P12_PASSWORD'], env=env)
    run(['security', 'create-keychain', '-p', password, str(keychain)])
    run(['security', 'unlock-keychain', '-p', password, str(keychain)])
    run(['security', 'set-keychain-settings', '-l', '-u', '-t', '21600', str(keychain)])
    run(['security', 'import', archive, '-k', str(keychain), '-P', password,
         '-x', '-T', '/usr/bin/codesign'])
    # Only Apple's command-line signing tools may use the non-exportable signing key.
    run(['security', 'set-key-partition-list', '-S', 'apple-tool:', '-s', '-k', password, str(keychain)])
der = run(['openssl', 'x509', '-in', str(certificate), '-outform', 'DER']).stdout
identity = hashlib.sha1(der).hexdigest().upper()
config.write_text(json.dumps({'identity': identity}, indent=2) + '\n')
os.chmod(config, 0o600)
print('Local development signing identity created. No system certificate trust was changed.')
print('Keep .local-signing private and persistent; make build will reuse this certificate.')
