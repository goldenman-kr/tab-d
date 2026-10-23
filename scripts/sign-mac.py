#!/usr/bin/env python3
"""Keep development code identity stable without modifying the login keychain."""
import hashlib
import os
from pathlib import Path
import secrets
import shlex
import subprocess
import sys

ROOT=Path(__file__).resolve().parents[1]
DIRECTORY=ROOT/'build/private/signing'
DIRECTORY.mkdir(parents=True,exist_ok=True,mode=0o700)
os.chmod(DIRECTORY,0o700)
KEYCHAIN=DIRECTORY/'tabd-development.keychain-db'
PASSWORD=DIRECTORY/'keychain-password'
CERT=DIRECTORY/'certificate.der'

def run(*args):
    result=subprocess.run(args,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    if result.returncode:
        # Command arguments may contain generated passwords; never print them.
        raise RuntimeError(f'{Path(args[0]).name} failed: '+result.stderr.decode(errors='replace').strip())
    return result.stdout

if not KEYCHAIN.exists():
    password=secrets.token_hex(32)
    PASSWORD.write_text(password); os.chmod(PASSWORD,0o600)
    config=DIRECTORY/'certificate.cnf'
    config.write_text('[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=Tab-D Local Development\n[ext]\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\nsubjectKeyIdentifier=hash\n')
    key=DIRECTORY/'private-key.pem'; pem=DIRECTORY/'certificate.pem'; p12=DIRECTORY/'identity.p12'
    run('/usr/bin/openssl','req','-new','-newkey','rsa:2048','-nodes','-x509','-days','3650','-sha256','-config',str(config),'-keyout',str(key),'-out',str(pem))
    run('/usr/bin/openssl','x509','-in',str(pem),'-outform','DER','-out',str(CERT))
    run('/usr/bin/openssl','pkcs12','-export','-inkey',str(key),'-in',str(pem),'-out',str(p12),'-passout','pass:'+password)
    for path in DIRECTORY.iterdir():
        if path.is_file(): os.chmod(path,0o600)
    run('/usr/bin/security','create-keychain','-p',password,str(KEYCHAIN))
    run('/usr/bin/security','set-keychain-settings','-lut','21600',str(KEYCHAIN))
    run('/usr/bin/security','unlock-keychain','-p',password,str(KEYCHAIN))
    run('/usr/bin/security','import',str(p12),'-k',str(KEYCHAIN),'-P',password,'-T','/usr/bin/codesign')
    run('/usr/bin/security','set-key-partition-list','-S','apple-tool:,apple:,codesign:','-s','-k',password,str(KEYCHAIN))
    key.unlink(); p12.unlink()
else:
    password=PASSWORD.read_text()
    run('/usr/bin/security','unlock-keychain','-p',password,str(KEYCHAIN))
identity=hashlib.sha1(CERT.read_bytes()).hexdigest().upper()
app=Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT/'build/Tab-D.app'
# codesign resolves the private key through the user search list even with
# --keychain. Add our isolated keychain for this operation and restore exactly.
original=shlex.split(run('/usr/bin/security','list-keychains','-d','user').decode())
try:
    run('/usr/bin/security','list-keychains','-d','user','-s',*original,str(KEYCHAIN))
    for path, identifier in [(app/'Contents/MacOS/TabDDisplayInspector','xyz.kryp.app.tabd.helper'),(app,'xyz.kryp.app.tabd')]:
        run('/usr/bin/codesign','--force','--timestamp=none','--keychain',str(KEYCHAIN),'--sign',identity,'--identifier',identifier,str(path))
finally:
    run('/usr/bin/security','list-keychains','-d','user','-s',*original)
os.chmod(KEYCHAIN,0o600)
run('/usr/bin/codesign','--verify','--deep','--strict',str(app))
print('Tab-D signed and verified with its stable local development identity.')
