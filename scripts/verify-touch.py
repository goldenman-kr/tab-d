#!/usr/bin/env python3
"""Real tablet taps must arrive as down/up events in our own Mac fixture window."""
import argparse
from datetime import datetime, timezone
import importlib.util
import json
import plistlib
from pathlib import Path
import re
import subprocess
import time
import xml.etree.ElementTree as ET
from device import ROOT, PACKAGE

spec=importlib.util.spec_from_file_location('verify_device',Path(__file__).with_name('verify-device.py'))
v=importlib.util.module_from_spec(spec); spec.loader.exec_module(v)

def wait(test,timeout=8):
    deadline=time.monotonic()+timeout
    while time.monotonic()<deadline:
        result=test()
        if result: return result
        time.sleep(.15)
    raise AssertionError('Touch assertion timed out')

def surface_bounds():
    v.adb('shell','uiautomator','dump','/data/local/tmp/tabd-ui.xml')
    tree=ET.fromstring(v.adb('shell','cat','/data/local/tmp/tabd-ui.xml').stdout)
    for node in tree.iter('node'):
        if node.get('class')=='android.view.SurfaceView':
            return tuple(map(int,re.fullmatch(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]',node.get('bounds')).groups()))
    raise AssertionError('Tab-D video surface not visible')

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--route',choices=['USB','무선'],default='USB')
    parser.add_argument('--placement',action='store_true',help='Move only the virtual display left/above, then restore it')
    args=parser.parse_args()
    path=ROOT/'docs/validation'/('touch-usb.json' if args.route=='USB' else 'touch-lan.json')
    report={'route':args.route,'startedAt':datetime.now(timezone.utc).isoformat(),'checks':[]}
    mac_info=plistlib.loads(Path('/Applications/Tab-D.app/Contents/Info.plist').read_bytes())
    package=v.adb('shell','dumpsys','package',PACKAGE).stdout.decode()
    report['versions']={'mac':mac_info['CFBundleShortVersionString'],
        'android':re.search(r'versionName=([^\s]+)',package).group(1),
        'androidBuild':int(re.search(r'versionCode=(\d+)',package).group(1))}
    fixture=ROOT/'build/private/click-witness.json'
    witness=None
    def record(name,**values):
        report['checks'].append({'check':name,'result':'PASS',**values})
        path.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
        print('PASS:',name,flush=True)
    def events(): return json.loads(fixture.read_text())
    def counts():
        result=events();return (result['downCount'],result['upCount'])
    def back(show):
        v.adb('shell','input','keyevent','KEYCODE_BACK')
        v.wait_tablet(lambda x:x['barVisible']==show and x['fullscreen'])
    try:
        baseline=v.inventory()
        assert not any(x['vendor']==0x5444 for x in baseline),'End existing display first'
        v.launch();v.wait_host(lambda x:x['peerConnected']);v.tap_text('화면 연결')
        h=v.wait_host(lambda x:x['state']=='streaming')
        a=v.wait_tablet(lambda x:x['fullscreen'] and x['epoch']==h['epoch'])
        v.wait_tablet(lambda x:x.get('systemBarsVisible') is False)
        assert h['route']==a['route']==args.route
        assert h['inputPermission'],'Approve macOS Accessibility for Tab-D before click tests'
        fixture.unlink(missing_ok=True)
        witness=subprocess.Popen([str(ROOT/'build/click-witness'),str(h['displayID']),str(fixture)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        wait(lambda:fixture.exists() and events()['ready'])
        time.sleep(1)
        bounds=surface_bounds();x0,y0,x1,y1=bounds
        report['surfaceBounds']=bounds;report['display']=h['mode'];report['fixture']=events()
        def tap(x,y):
            px=int(x0+(x1-x0)*x);py=int(y0+(y1-y0)*y)
            v.adb('shell','input','tap',str(px),str(py))
            return ((px-x0)/(x1-x0),(py-y0)/(y1-y0))
        for index,(x,y) in enumerate([(.25,.25),(.75,.25),(.25,.75),(.75,.75),(.5,.5)]):
            target=tap(x,y)
            wait(lambda:counts()==(index+1,index+1))
            result=events()
            for field in ['lastDown','lastUp']:
                actual=result[field]['localNormalized']
                assert all(abs(actual[i]-target[i])<.002 for i in range(2)),(target,result)
                assert result[field]['buttonNumber']==0 and result[field]['clickCount']==1
            android=v.wait_tablet(lambda z:z.get('lastClick',{}).get('status')=='accepted')
            assert android['fullscreen'] and not android['barVisible'] and v.host()['epoch']==h['epoch']
            record('actual-left-down-up-at-coordinate',target=target,received=result['lastUp'],android=android['lastClick'])
        if args.placement:
            def current_display(): return next(z for z in v.inventory() if z['displayID']==h['displayID'])
            original=current_display()['bounds']
            try:
                for label,origin in [('left',(-int(original[2]),0)),('above',(0,-int(original[3])))]:
                    subprocess.run([str(ROOT/'build/display-placement'),str(h['displayID']),*[str(n) for n in origin]],check=True,capture_output=True)
                    wait(lambda:current_display()['bounds'][:2]==list(origin))
                    time.sleep(1.3)
                    before=counts();target=tap(.25,.75)
                    wait(lambda:counts()==(before[0]+1,before[1]+1))
                    result=events();actual=result['lastUp']['localNormalized']
                    assert all(abs(actual[i]-target[i])<.002 for i in range(2)),(target,result)
                    v.check_baseline(baseline,True)
                    record('click-after-virtual-display-placement-change',placement=label,bounds=current_display()['bounds'],received=result['lastUp'])
            finally:
                subprocess.run([str(ROOT/'build/display-placement'),str(h['displayID']),str(int(original[0])),str(int(original[1]))],check=True,capture_output=True)
                wait(lambda:current_display()['bounds']==original);time.sleep(1.3)
        before=counts();epoch=v.host()['epoch']
        back(True);assert counts()==before and v.host()['epoch']==epoch and v.host()['state']=='streaming'
        record('back-button-shows-bar-without-click-or-pause',epoch=epoch)
        back(False);v.wait_tablet(lambda x:x.get('systemBarsVisible') is False);assert counts()==before
        edge_attempts=0
        for edge_attempts in range(1,3):
            v.adb('shell','input','swipe','1',str((y0+y1)//2),'450',str((y0+y1)//2),'400')
            time.sleep(.35)
            if v.tablet()['barVisible']: break
        v.wait_tablet(lambda x:x['barVisible'] and x['fullscreen'])
        assert counts()==before and v.host()['epoch']==epoch
        assert edge_attempts==1,'The first edge gesture did not open the control bar'
        record('edge-back-gesture-shows-bar-without-click-or-pause',swipes=edge_attempts)
        tap(.25,.25);v.wait_tablet(lambda x:not x['barVisible'] and x.get('systemBarsVisible') is False);assert counts()==before
        record('surface-tap-only-dismisses-visible-bar-and-restores-fullscreen')
        back(True);v.tap_text('화면 설정');time.sleep(.3)
        assert counts()==before and v.host()['state']=='streaming' and v.host()['epoch']==epoch
        v.tap_text('닫기')
        # Back toggles the bar closed after dismissing the modal settings dialog.
        if v.tablet()['barVisible']: back(False)
        v.wait_tablet(lambda x:x.get('systemBarsVisible') is False)
        record('settings-button-does-not-leak-mac-click')
        back(True)
        v.wait_tablet(lambda x:not x['barVisible'] and x.get('systemBarsVisible') is False,timeout=9)
        assert counts()==before and v.host()['epoch']==epoch
        record('bar-timeout-restores-fullscreen-without-click-or-pause')
        cx=int(x0+(x1-x0)*.4);cy=int(y0+(y1-y0)*.4)
        v.adb('shell','input','swipe',str(cx),str(cy),str(cx+400),str(cy+150),'180')
        v.adb('shell','input','swipe',str(cx),str(cy),str(cx),str(cy),'650')
        time.sleep(.5);assert counts()==before
        record('drag-and-long-press-do-not-click')
        png=path.with_suffix('.png');png.write_bytes(v.adb('exec-out','screencap','-p').stdout)
        v.home();paused=v.wait_host(lambda x:x['state']=='paused')
        assert paused['displayID']==h['displayID'];time.sleep(1);assert counts()==before
        v.launch();resumed=v.wait_host(lambda x:x['state']=='streaming' and x['epoch']>epoch)
        v.wait_tablet(lambda x:x['fullscreen'] and x['epoch']==resumed['epoch'])
        assert resumed['displayID']==h['displayID']
        tap(.25,.25);wait(lambda:counts()==(before[0]+1,before[1]+1))
        record('home-retains-display-and-return-click-works',oldEpoch=epoch,newEpoch=resumed['epoch'],received=events()['lastUp'])
        back(True);v.tap_text('태블릿으로 돌아가기')
        paused=v.wait_host(lambda x:x['state']=='paused');v.wait_tablet(lambda x:not x['foreground'] and x['retained'])
        assert paused['displayID']==h['displayID']
        v.launch();v.wait_host(lambda x:x['state']=='streaming' and x['epoch']>resumed['epoch'])
        v.wait_tablet(lambda x:x['fullscreen'])
        before=counts();tap(.75,.75);wait(lambda:counts()==(before[0]+1,before[1]+1))
        record('control-bar-return-keeps-display-and-click-after-resume')
        v.check_baseline(baseline,True)
        back(True);v.tap_text('⋯');v.tap_text('연결 종료')
        v.wait_host(lambda x:x['displayID']==0);v.wait_tablet(lambda x:not x['fullscreen'] and not x['retained'])
        wait(lambda:len(v.inventory())==len(baseline));v.check_baseline(baseline,False)
        v.home();v.launch();time.sleep(1);assert v.host()['displayID']==0
        record('explicit-end-removes-display-no-resurrection')
        report['result']='PASS';report['host']=v.host();report['tablet']=v.tablet()
    except Exception as error:
        report['result']='FAIL';report['failure']=str(error);report['hostOnFailure']=v.host()
        try: report['tabletOnFailure']=v.tablet()
        except Exception: pass
        if fixture.exists():report['fixtureOnFailure']=events()
        raise
    finally:
        if witness and witness.poll() is None:witness.terminate();witness.wait(timeout=5)
        report['finishedAt']=datetime.now(timezone.utc).isoformat()
        path.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')

if __name__=='__main__':main()
