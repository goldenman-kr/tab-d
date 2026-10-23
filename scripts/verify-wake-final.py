#!/usr/bin/env python3
# coding: utf-8
"""Opt-in final-build USB/LAN video smoke, without OS sleep. Changes route settings."""
import sys,importlib.util,json,time,subprocess,re,xml.etree.ElementTree as ET
from datetime import datetime,timezone
sys.path.insert(0,str(__import__('pathlib').Path.cwd()/'scripts'))
s=importlib.util.spec_from_file_location('v','scripts/verify-device.py');v=importlib.util.module_from_spec(s);s.loader.exec_module(v)
from device import adb
route=sys.argv[1]
assert route in ('USB','무선'), 'Use USB or 무선'
report={'route':route,'startedAt':datetime.now(timezone.utc).isoformat(),'checks':[]}
path=v.OUT/('wake-final-smoke-'+('usb' if route=='USB' else 'lan')+'.json')
def check(name,**data):
 report['checks'].append({'check':name,'result':'PASS',**data});path.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n');print('PASS:',name,flush=True)
try:
 v.launch();v.wait_host(lambda x:x['peerConnected']);v.wait_tablet(lambda x:x['authenticated'] and x['foreground'])
 old=v.host()['transport']['acceptedPeers']
 v.tap_text('설정');adb('shell','uiautomator','dump','/data/local/tmp/tabd-ui.xml')
 root=ET.fromstring(adb('shell','cat','/data/local/tmp/tabd-ui.xml').stdout)
 node=next(n for n in root.iter('node') if n.get('class')=='android.widget.EditText')
 x1,y1,x2,y2=map(int,re.fullmatch(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]',node.get('bounds')).groups())
 adb('shell','input','tap',str((x1+x2)//2),str((y1+y2)//2));adb('shell','input','keycombination','113','29');adb('shell','input','keyevent','KEYCODE_DEL')
 if route=='무선':
  addr=subprocess.run(['ipconfig','getifaddr','en0'],check=True,capture_output=True,text=True).stdout.strip();adb('shell','input','text',addr)
 v.tap_text('주소 적용')
 v.wait_host(lambda x:x['peerConnected'] and x['route']==route and x['transport']['acceptedPeers']>old)
 v.wait_tablet(lambda x:x['authenticated'] and x['route']==route)
 check('final-build-authenticated-reconnect')
 baseline=v.inventory();assert not any(x['vendor']==0x5444 for x in baseline)
 v.tap_text('화면 연결');a=v.wait_host(lambda x:x['state']=='streaming')
 t=v.wait_tablet(lambda x:x['state']=='streaming' and x['fullscreen'] and x['epoch']==a['epoch'] and x['framesCurrentEpoch']>0)
 assert a['mode']['pixelWidth']==1920 and a['mode']['pixelHeight']==1200
 v.check_baseline(baseline,True)
 check('final-build-actual-video',displayID=a['displayID'],epoch=a['epoch'],renderedFrames=t['framesCurrentEpoch'],mode=a['mode'])
 v.home();p=v.wait_host(lambda x:x['state']=='paused');v.wait_tablet(lambda x:not x['foreground'] and x['retained'])
 assert p['displayID']==a['displayID'];time.sleep(.6);assert v.host()['framesSent']==p['framesSent']
 v.launch();r=v.wait_host(lambda x:x['state']=='streaming' and x['epoch']>p['epoch'])
 t=v.wait_tablet(lambda x:x['fullscreen'] and x['epoch']==r['epoch'] and x['framesCurrentEpoch']>0)
 assert r['displayID']==a['displayID'];v.check_baseline(baseline,True)
 check('final-build-home-return-same-display',displayID=r['displayID'],epoch=r['epoch'],renderedFrames=t['framesCurrentEpoch'])
 adb('shell','input','keyevent','KEYCODE_BACK');v.wait_tablet(lambda x:x['barVisible']);v.tap_text('⋯');v.tap_text('연결 종료')
 v.wait_host(lambda x:x['displayID']==0 and x['state'] in ['idle','ready'] and not x['wake']['pending'])
 v.wait_tablet(lambda x:not x['retained'] and not x['fullscreen']);time.sleep(.6);v.check_baseline(baseline,False)
 check('explicit-end-and-physical-baseline')
 report['result']='PASS'
except Exception as e:
 report['result']='FAIL';report['error']=str(e);raise
finally:path.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
