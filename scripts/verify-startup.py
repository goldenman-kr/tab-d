#!/usr/bin/env python3
"""Repeated real-device starts with no animated test window. Ends each session."""
import argparse
from datetime import datetime, timezone
import importlib.util
import json
import time
from pathlib import Path
from device import ROOT

spec = importlib.util.spec_from_file_location("verify_device", Path(__file__).with_name("verify-device.py"))
v = importlib.util.module_from_spec(spec)
spec.loader.exec_module(v)

parser = argparse.ArgumentParser()
parser.add_argument("--cycles", type=int, default=5)
parser.add_argument("--route", choices=["USB", "무선"], default="USB")
args = parser.parse_args()
assert 1 <= args.cycles <= 20
path = ROOT / "docs/validation" / ("startup-usb.json" if args.route == "USB" else "startup-lan.json")
report = {"route":args.route,"startedAt":datetime.now(timezone.utc).isoformat(),"checks":[]}
baseline = v.inventory()
assert not any(x["vendor"] == 0x5444 for x in baseline), "End current display first"
try:
    v.launch()
    v.wait_host(lambda x:x["peerConnected"] and x["displayID"] == 0)
    for cycle in range(args.cycles):
        prior_frames = v.host()["framesSent"]
        v.tap_text("화면 연결")
        started = time.monotonic()
        h = v.wait_host(lambda x:x["state"] == "streaming")
        a = v.wait_tablet(lambda x:x["fullscreen"] and x["epoch"] == h["epoch"])
        assert h["route"] == args.route and a["route"] == args.route
        v.check_baseline(baseline, True)
        row = {"cycle":cycle+1,"result":"PASS","secondsAfterStartTapReturned":round(time.monotonic()-started,2),"displayID":h["displayID"],"framesSentAtObservation":h["framesSent"],"framesSentForStart":h["framesSent"]-prior_frames,"android":a}
        report["checks"].append(row)
        print("PASS: static start",cycle+1,flush=True)
        v.adb("shell","input","keyevent","KEYCODE_BACK")
        v.tap_text("⋯"); v.tap_text("연결 종료")
        v.wait_host(lambda x:x["displayID"] == 0 and x["state"] in ["ready","idle"])
        v.wait_tablet(lambda x:not x["retained"] and not x["fullscreen"])
        v.check_baseline(baseline,False)
    report["result"] = "PASS"
except Exception as error:
    report["result"]="FAIL";report["failure"]=str(error)
    report["hostOnFailure"]=v.host()
    try: report["tabletOnFailure"]=v.tablet()
    except Exception: pass
    raise
finally:
    report["finishedAt"]=datetime.now(timezone.utc).isoformat()
    path.write_text(json.dumps(report,ensure_ascii=False,indent=2)+"\n")
