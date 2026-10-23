#!/usr/bin/env python3
"""Development-only device setup. Never prints pairing secrets or device serials."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
ADB = os.environ.get('TABD_ADB', str(Path.home() / 'Library/Android/sdk/platform-tools/adb'))
PACKAGE = 'xyz.kryp.app.tabd'

def adb(*args, data=None, check=True):
    return subprocess.run([ADB, '-d', *args], input=data, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, check=check)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['install', 'pair', 'launch', 'diagnostics', 'home'])
    args = parser.parse_args()
    if args.action == 'install':
        result = adb('install', '-r', str(ROOT / 'android/app/build/outputs/apk/debug/app-debug.apk'))
        print(result.stdout.decode().strip())
    elif args.action == 'pair':
        config = json.loads((ROOT / 'build/private/pairing.json').read_text())
        # Do not overwrite an unrelated reverse mapping. This port belongs to Tab-D.
        mappings = adb('reverse', '--list').stdout.decode().splitlines()
        for line in mappings:
            fields = line.split()
            if len(fields) >= 3 and fields[-2] == 'tcp:49832' and fields[-1] != 'tcp:49832':
                raise RuntimeError('Tablet port 49832 is already mapped to another service')
        adb('reverse', 'tcp:49832', 'tcp:49832')
        adb('shell', 'run-as', PACKAGE, 'mkdir', '-p', 'files')
        adb('shell', 'run-as', PACKAGE, 'sh', '-c', "'cat > files/pairing.json'",
            data=json.dumps(config).encode())
        adb('shell', 'run-as', PACKAGE, 'chmod', '600', 'files/pairing.json')
        print('Private pairing and USB reverse configured; no secrets printed.')
    elif args.action == 'launch':
        adb('shell', 'am', 'start', '-n', PACKAGE + '/.MainActivity')
        print('Tab-D opened on tablet.')
    elif args.action == 'home':
        adb('shell', 'input', 'keyevent', 'KEYCODE_HOME')
        print('Android Home opened.')
    else:
        result = adb('shell', 'run-as', PACKAGE, 'cat', 'files/diagnostics.json', check=False)
        if result.returncode:
            raise RuntimeError('Tablet diagnostics not available yet')
        print(json.dumps(json.loads(result.stdout), ensure_ascii=False, indent=2))

if __name__ == '__main__':
    try:
        main()
    except subprocess.CalledProcessError as error:
        print('Device operation failed: ' + error.stderr.decode(errors='replace').strip(), file=sys.stderr)
        sys.exit(1)
    except Exception as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
