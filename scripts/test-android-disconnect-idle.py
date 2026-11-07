#!/usr/bin/env python3
"""Opt-in real-device test: opens monitor sessions and ends them; leaves tablet idle."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import time
import xml.etree.ElementTree as ET

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--serial', required=True)
parser.add_argument('--routes', nargs='+', choices=['usb', 'wireless'], default=['usb'])
args = parser.parse_args()
adb = os.environ.get('TABD_ADB', str(Path.home() / 'Library/Android/sdk/platform-tools/adb'))
package = 'xyz.kryp.app.tabd'

def run(*command):
    return subprocess.check_output([adb, '-s', args.serial, *command], timeout=25).decode('utf-8')

def state():
    return json.loads(run('exec-out', 'run-as', package, 'cat', 'files/diagnostics.json'))

def wait_for(predicate, timeout=40):
    deadline = time.monotonic() + timeout
    latest = {}
    while time.monotonic() < deadline:
        latest = state()
        if predicate(latest):
            return latest
        time.sleep(.5)
    fields = ('state', 'connected', 'authenticated', 'connectionWorkEnabled', 'discovering', 'disconnectRequested', 'lastError')
    raise AssertionError({key: latest.get(key) for key in fields})

def launch():
    run('shell', 'input', 'keyevent', 'KEYCODE_WAKEUP')
    run('shell', 'wm', 'dismiss-keyguard')
    run('shell', 'am', 'start', '-n', package + '/.MainActivity')
    time.sleep(1)

def tap(text):
    run('shell', 'uiautomator', 'dump', '/data/local/tmp/tabd-idle-ui.xml')
    tree = ET.fromstring(run('exec-out', 'cat', '/data/local/tmp/tabd-idle-ui.xml'))
    for node in tree.iter('node'):
        if node.get('package') == package and node.get('text') == text and node.get('enabled') == 'true':
            bounds = [int(value) for value in re.findall(r'\d+', node.get('bounds', ''))]
            if len(bounds) == 4:
                left, top, right, bottom = bounds
                run('shell', 'input', 'tap', str((left + right)//2), str((top + bottom)//2))
                return
    raise AssertionError('Visible button not found: ' + text)

def idle(value):
    return not any(value.get(key) for key in ('connectionWorkEnabled', 'connected', 'authenticated', 'discovering', 'disconnectRequested', 'disconnectPending', 'retained', 'fullscreen', 'confirmedDisplay')) and value.get('state') == 'stopped'

def stop():
    if state().get('fullscreen'):
        run('shell', 'input', 'keyevent', 'KEYCODE_BACK')
        time.sleep(.5)
    tap('연결 종료')
    wait_for(idle)

def assert_stays_idle(seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        assert idle(state()), 'Connection work resumed without a button press'
        time.sleep(1)

launch()
current = state()
if current.get('retained') or current.get('fullscreen') or current.get('pendingStart'):
    stop()
for route in args.routes:
    button = '유선으로 연결' if route == 'usb' else '무선으로 연결'
    tap(button)
    wait_for(lambda value: value.get('fullscreen') and value.get('framesCurrentEpoch', 0) > 0)
    print(f'PASS {route}: explicit button connects and presents monitor frames', flush=True)
    stop()
    assert_stays_idle(10)
    print(f'PASS {route}: acknowledged stop closes transport and remains idle across retry intervals', flush=True)
    run('shell', 'input', 'keyevent', 'KEYCODE_HOME')
    time.sleep(1)
    launch()
    wait_for(idle)
    assert_stays_idle(4)
    run('shell', 'am', 'force-stop', package)
    launch()
    wait_for(idle)
    assert_stays_idle(4)
    print(f'PASS {route}: background return and fresh process preserve user-stopped state', flush=True)
    tap(button)
    wait_for(lambda value: value.get('fullscreen') and value.get('framesCurrentEpoch', 0) > 0)
    stop()
    assert_stays_idle(3)
    print(f'PASS {route}: explicit reconnect works; final state is fully stopped', flush=True)
print('PASS: no battery drain percentage claim; this test verifies stopped work and transport state', flush=True)
