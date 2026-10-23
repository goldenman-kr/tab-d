#!/usr/bin/env python3
"""Opt-in real-device checks. Runs only against the single authorized USB tablet.
Uses its UI for session actions; saves app diagnostics and an owned test pattern.
"""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import subprocess
import time
import xml.etree.ElementTree as ET

from device import ROOT, PACKAGE, adb

OUT = ROOT / 'docs/validation'
HOST = ROOT / 'build/private/diagnostics.json'


def host():
    return json.loads(HOST.read_text())


def tablet():
    return json.loads(adb('shell', 'run-as', PACKAGE, 'cat', 'files/diagnostics.json').stdout)


def wait_host(test, timeout=18):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = host()
        if test(value):
            return value
        time.sleep(.25)
    raise AssertionError('Host state timeout: ' + json.dumps({k:host().get(k) for k in ['state','displayID','lastError']}))


def wait_tablet(test, timeout=12):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = tablet()
        if test(value):
            return value
        time.sleep(.3)
    raise AssertionError('Tablet state timeout')


def tap_text(text):
    adb('shell', 'uiautomator', 'dump', '/data/local/tmp/tabd-ui.xml')
    data = adb('shell', 'cat', '/data/local/tmp/tabd-ui.xml').stdout
    root = ET.fromstring(data)
    for node in root.iter('node'):
        if node.get('text') == text:
            match = re.fullmatch(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', node.get('bounds',''))
            if match:
                x1,y1,x2,y2 = map(int, match.groups())
                adb('shell', 'input', 'tap', str((x1+x2)//2), str((y1+y2)//2))
                return
    raise AssertionError('Visible Tab-D UI control not found: ' + text)


def launch():
    adb('shell', 'am', 'start', '-n', PACKAGE+'/.MainActivity')


def home():
    adb('shell', 'input', 'keyevent', 'KEYCODE_HOME')


def inventory():
    result = subprocess.run([str(ROOT/'build/Tab-D.app/Contents/MacOS/TabDDisplayInspector')], check=True, capture_output=True)
    return json.loads(result.stdout)['displays']


def check_baseline(baseline, active):
    current = inventory()
    assert len(current) == len(baseline) + (1 if active else 0), 'Unexpected display count'
    for original in baseline:
        observed = next((x for x in current if x['displayID'] == original['displayID']), None)
        assert observed == original, 'Existing display topology changed'
    return current


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--route', choices=['USB','무선'], default='USB')
    parser.add_argument('--cycles',type=int,default=3)
    parser.add_argument('--full',action='store_true',help='Also test process loss and explicit end')
    args=parser.parse_args()
    assert 1 <= args.cycles <= 20
    OUT.mkdir(parents=True,exist_ok=True)
    report={'route':args.route,'startedAt':datetime.now(timezone.utc).isoformat(),'checks':[]}
    path=OUT/('device-usb.json' if args.route=='USB' else 'device-lan.json')
    witness=None

    def record(name, **values):
        report['checks'].append({'check':name,'result':'PASS',**values})
        path.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
        print('PASS:',name,flush=True)

    try:
        baseline=inventory()
        assert not any(x['vendor']==0x5444 for x in baseline), 'End current Tab-D display before checking'
        launch()
        wait_host(lambda x:x['peerConnected'])
        wait_tablet(lambda x:x['authenticated'] and x['foreground'])
        tap_text('화면 연결')
        started=wait_host(lambda x:x['state']=='streaming')
        display_id=started['displayID']
        received=wait_tablet(lambda x:x['state']=='streaming' and x['fullscreen'] and x['frames']>0)
        assert started['route']==args.route and received['route']==args.route
        check_baseline(baseline, True)
        assert started['mode']['pixelWidth'] in (1920,3504)
        witness_path=ROOT/'build/private/window-witness.json'
        witness=subprocess.Popen([str(ROOT/'build/window-witness'),str(display_id),str(witness_path)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        time.sleep(3)
        window=json.loads(witness_path.read_text())
        assert window['unchanged']
        frame=window['frame']
        record('actual-stream-and-hardware',framesSentAtFirstPresentation=started['framesSent'],displayID=display_id,mode=started['mode'],android=received,hostVideo=host()['video'],windowFrame=frame)
        png=OUT/('device-usb-pattern.png' if args.route=='USB' else 'device-lan-pattern.png')
        png.write_bytes(adb('exec-out','screencap','-p').stdout)
        for cycle in range(args.cycles):
            home()
            paused=wait_host(lambda x:x['state']=='paused')
            wait_tablet(lambda x:not x['foreground'] and x['retained'])
            assert paused['displayID']==display_id
            time.sleep(2)
            held=host()
            assert held['framesSent']==paused['framesSent'], 'Capture continued while paused'
            assert held['displayID']==display_id
            check_baseline(baseline,True)
            assert json.loads(witness_path.read_text())['frame']==frame
            launch()
            resumed=wait_host(lambda x:x['state']=='streaming' and x['epoch']>paused['epoch'])
            fresh=wait_tablet(lambda x:x['fullscreen'] and x['epoch']==resumed['epoch'])
            assert resumed['displayID']==display_id
            assert json.loads(witness_path.read_text())['frame']==frame
            check_baseline(baseline,True)
            record('home-and-return',cycle=cycle+1,displayID=display_id,pauseEpoch=paused['epoch'],resumeEpoch=resumed['epoch'],framesHeld=held['framesSent'],renderedFrames=fresh['frames'],windowFrame=frame)
        # The explicit return button must obtain pauseAck before opening Home.
        adb('shell','input','keyevent','KEYCODE_BACK')
        bar_png=OUT/('android-control-bar-current.png' if args.route=='USB' else 'android-control-bar-lan.png')
        bar_png.write_bytes(adb('exec-out','screencap','-p').stdout)
        tap_text('태블릿으로 돌아가기')
        paused=wait_host(lambda x:x['state']=='paused')
        returned=wait_tablet(lambda x:not x['foreground'] and x['retained'] and not x['pendingHome'])
        assert paused['displayID']==display_id
        record('control-bar-return-with-pause-ack',displayID=display_id,android=returned)
        if args.full:
            adb('shell','am','force-stop',PACKAGE)
            wait_host(lambda x:not x['peerConnected'])
            time.sleep(4)
            assert host()['state']=='paused' and host()['displayID']==display_id
            check_baseline(baseline,True)
            launch()
            restored=wait_host(lambda x:x['state']=='streaming')
            assert restored['displayID']==display_id
            record('paused-android-process-death-retains-display',displayID=display_id,epoch=restored['epoch'])
            adb('shell','am','force-stop',PACKAGE)
            launch()
            recovered=wait_host(lambda x:x['state']=='streaming' and x['epoch']>restored['epoch'])
            assert recovered['displayID']==display_id
            time.sleep(4)
            assert host()['displayID']==display_id and host()['state']=='streaming'
            check_baseline(baseline,True)
            assert json.loads(witness_path.read_text())['frame']==frame
            record('quick-active-reconnect-survives-old-timeout',displayID=display_id,epoch=recovered['epoch'])
        else:
            launch(); wait_host(lambda x:x['state']=='streaming')
        # End from Android overflow, then reopening must not resurrect it.
        adb('shell','input','keyevent','KEYCODE_BACK')
        tap_text('⋯')
        tap_text('연결 종료')
        wait_host(lambda x:x['displayID']==0 and x['state'] in ['idle','ready'])
        wait_tablet(lambda x:not x['retained'] and not x['fullscreen'])
        if witness:
            witness.terminate(); witness.wait(timeout=5); witness=None
        deadline=time.monotonic()+6
        while time.monotonic()<deadline and len(inventory())!=len(baseline): time.sleep(.2)
        check_baseline(baseline,False)
        home(); launch(); time.sleep(3)
        assert host()['displayID']==0
        record('explicit-end-removes-display-and-does-not-resurrect')
        if args.full:
            tap_text('화면 연결')
            active=wait_host(lambda x:x['state']=='streaming')
            disconnected=time.monotonic()
            adb('shell','am','force-stop',PACKAGE)
            lost=wait_host(lambda x:not x['peerConnected'])
            wait_host(lambda x:x['displayID']==0)
            deadline=time.monotonic()+6
            while time.monotonic()<deadline and len(inventory())!=len(baseline): time.sleep(.1)
            elapsed=time.monotonic()-disconnected
            check_baseline(baseline,False)
            assert elapsed<6, 'Active failure cleanup exceeded test budget'
            record('unexpected-active-process-loss-cleans-display',removedDisplayID=active['displayID'],secondsIncludingDetectionAndObservation=round(elapsed,2))
            launch(); wait_host(lambda x:x['peerConnected']); time.sleep(2)
            assert host()['displayID']==0
            record('expired-session-does-not-resurrect')
        report['result']='PASS'
    except Exception as error:
        report['result']='FAIL'; report['failure']=str(error)
        report['hostOnFailure']=host()
        try: report['tabletOnFailure']=tablet()
        except Exception: pass
        raise
    finally:
        if witness:
            witness.terminate(); witness.wait(timeout=5)
        report['finishedAt']=datetime.now(timezone.utc).isoformat()
        path.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')

if __name__=='__main__':
    main()
