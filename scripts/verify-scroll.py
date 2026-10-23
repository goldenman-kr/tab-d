#!/usr/bin/env python3
"""Real Android MotionEvents -> authenticated USB/LAN -> owned native Mac scroll view.

Default: Mac 0.5.0 build 6. --wake: Mac 0.6.0 build 7 / Android 0.6.0 code 6,
with wake-prefixed reports. Both modes run the existing scroll regression checks.
"""
import argparse
from datetime import datetime, timezone
import importlib.util
import json
from pathlib import Path
import plistlib
import re
import subprocess
import time
from device import PACKAGE, ROOT

spec = importlib.util.spec_from_file_location("touch", Path(__file__).with_name("verify-touch.py"))
touch = importlib.util.module_from_spec(spec); spec.loader.exec_module(touch)
v, wait = touch.v, touch.wait


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--route", choices=["USB", "무선"], default="USB")
    parser.add_argument("--wake", action="store_true", help="Test scroll regressions on 0.6.0 builds 7/6 with wake-prefixed reports")
    args = parser.parse_args()
    prefix = "wake-scroll" if args.wake else "scroll"
    output = ROOT / "docs/validation" / (prefix + ("-usb.json" if args.route == "USB" else "-lan.json"))
    fixture = ROOT / "build/private/scroll-witness.json"
    report = {"route": args.route, "startedAt": datetime.now(timezone.utc).isoformat(), "checks": [],
              "inputMethod": "ADB shell app_process injects native multi-pointer MotionEvents; actual NSScrollView applies Mac CG pixel-wheel events"}
    witness = None
    baseline = v.inventory()

    def save(): output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    def record(name, **values):
        report["checks"].append({"check": name, "result": "PASS", **values}); save()
        print("PASS:", name, flush=True)
    def events(): return json.loads(fixture.read_text())
    def counters(d): return [d[k] for k in ["leftDownCount", "leftUpCount", "rightDownCount", "rightUpCount", "draggedCount"]]
    def inject(mode="normal", dx=0, dy=-500, duration=450):
        v.adb("shell", "CLASSPATH=/data/local/tmp/tabd-touch-input.jar", "app_process", "/system/bin", "TabDTouch",
              mode, str(cx), str(cy), str(dx), str(dy), str(duration))
    def settled():
        v.wait_tablet(lambda d: d.get("pendingScrollCount") == 0 and not d.get("scrolling"))
        time.sleep(.35)
        return events()
    def no_leak(before, after):
        assert counters(before) == counters(after), (counters(before), counters(after))
        assert not after["leftButtonHeld"] and not after["rightButtonHeld"] and not v.host()["pointer"]["held"]
    def scroll(name, dy, mode="normal", duration=450, drag=False):
        before = events(); inject(mode=mode, dy=dy, duration=duration)
        wait(lambda: events()["scrollCount"] > before["scrollCount"])
        after = settled()
        total = after["scrollDeltaYTotal"] - before["scrollDeltaYTotal"]
        offset = after["contentOffsetY"] - before["contentOffsetY"]
        expected = dy / (bounds[3] - bounds[1]) * host["mode"]["logicalHeight"]
        assert total * dy > 0 and offset * dy < 0, (total, offset, dy)
        assert abs(total - expected) < max(4, abs(expected)*.03), (total, expected)
        assert abs(offset + total) < max(4, abs(total)*.03), (total, offset)
        if drag:
            assert after["leftDownCount"] == before["leftDownCount"]+1 and after["leftUpCount"] == before["leftUpCount"]+1
            assert after["rightDownCount"] == before["rightDownCount"] and after["rightUpCount"] == before["rightUpCount"]
        else: no_leak(before, after)
        recent = [e for e in after["recentScrollEvents"] if e["sequence"] > before["scrollCount"]]
        assert all(e["hasPreciseScrollingDeltas"] and not e["leftButtonHeldAtScroll"] and not e["rightButtonHeldAtScroll"] for e in recent)
        assert all(e["phase"] == e["momentumPhase"] == 0 for e in recent)
        anchor = after["lastScroll"]["localNormalized"]
        assert abs(anchor[0] - (cx-bounds[0])/(bounds[2]-bounds[0])) < .004
        assert abs(anchor[1] - (cy+dy+(100 if drag else 0)-bounds[1])/(bounds[3]-bounds[1])) < .015, anchor
        tablet = v.wait_tablet(lambda d: d.get("lastScroll", {}).get("status") == "accepted" and d.get("pendingScrollCount") == 0)
        record(name, packets=after["scrollCount"]-before["scrollCount"], expectedPixels=round(expected,3),
               receivedPixels=total, beforeOffset=before["contentOffsetY"], afterOffset=after["contentOffsetY"],
               actualDocumentMovement=offset, lastEvent=after["lastScroll"], tabletAccepted=tablet["lastScroll"]["status"])
    def back(show):
        v.adb("shell", "input", "keyevent", "KEYCODE_BACK")
        v.wait_tablet(lambda d:d["fullscreen"] and d["barVisible"] == show)
        if not show: v.wait_tablet(lambda d:d.get("systemBarsVisible") is False)
    def end_session():
        if v.host()["displayID"]:
            v.launch();v.wait_tablet(lambda d:d["fullscreen"])
            if not v.tablet()["barVisible"]: back(True)
            v.tap_text("⋯");v.tap_text("연결 종료");v.wait_host(lambda d:d["displayID"] == 0)

    try:
        assert not any(d["vendor"] == 0x5444 for d in baseline), "End existing Tab-D display first"
        info = plistlib.loads(Path("/Applications/Tab-D.app/Contents/Info.plist").read_bytes())
        expected_version, expected_build = ("0.6.0", "7") if args.wake else ("0.5.0", "6")
        assert info["CFBundleShortVersionString"] == expected_version and str(info["CFBundleVersion"]) == expected_build
        if args.wake:
            package = v.adb("shell", "dumpsys", "package", PACKAGE).stdout.decode()
            versions = {"mac": info["CFBundleShortVersionString"], "macBuild": str(info["CFBundleVersion"]),
                        "android": re.search(r"versionName=([^\s]+)", package).group(1),
                        "androidBuild": int(re.search(r"versionCode=(\d+)", package).group(1))}
            report["versions"] = versions
            assert versions == {"mac":"0.6.0","macBuild":"7","android":"0.6.0","androidBuild":6}, versions
        v.launch();v.wait_host(lambda d:d["peerConnected"])
        v.tap_text("화면 연결");host=v.wait_host(lambda d:d["state"] == "streaming")
        display_id, epoch=host["displayID"],host["epoch"]
        tablet=v.wait_tablet(lambda d:d["fullscreen"] and d["epoch"] == epoch and not d["barVisible"] and d.get("systemBarsVisible") is False)
        assert host["route"] == tablet["route"] == args.route and host["inputPermission"]
        report["version"]=expected_version; report["displayMode"]=host["mode"];report["displayID"]=display_id
        fixture.unlink(missing_ok=True)
        witness=subprocess.Popen([str(ROOT/"build/scroll-witness"),str(display_id),str(fixture)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        wait(lambda:fixture.exists() and events()["ready"]);time.sleep(1)
        bounds=touch.surface_bounds();report["surfaceBounds"]=bounds
        cx=(bounds[0]+bounds[2])//2;cy=(bounds[1]+bounds[3])//2
        scroll("two-finger-up-increases-native-document-offset", -500)
        scroll("two-finger-down-decreases-native-document-offset", 500)
        for name,mode,dx,dy,duration in [("stationary-two-finger-no-right-click","normal",0,0,750),
                ("horizontal-only-no-scroll-or-click","normal",400,0,450)]:
            before=events();inject(mode,dx,dy,duration);after=settled()
            assert before["scrollCount"] == after["scrollCount"], (before,after)
            no_leak(before,after)
            interrupted = v.host()["state"] == "paused"
            foreground_package = None
            if interrupted:
                window = v.adb("shell", "dumpsys", "window").stdout.decode()
                match = re.search(r"mCurrentFocus=.*?u0 ([\w.]+)/", window)
                foreground_package = match.group(1) if match else "unavailable"
            record(name,counts=counters(after),systemPaused=interrupted,interruptingPackage=foreground_package)
            if interrupted:
                v.wait_tablet(lambda d:not d["foreground"])
                v.launch();v.wait_host(lambda d:d["state"] == "streaming" and d["displayID"] == display_id)
                v.wait_tablet(lambda d:d["fullscreen"] and d["foreground"])
                if v.tablet()["barVisible"]:back(False)
        scroll("remaining-finger-after-pair-lift-does-not-click-or-drag",-300,mode="remaining")
        scroll("drag-to-two-fingers-releases-mouse-before-scroll",300,mode="drag",drag=True)
        scroll("system-cancel-leaves-no-held-input",-300,mode="cancel")
        before=events();time.sleep(.7);after=events();assert before["scrollCount"] == after["scrollCount"]
        record("no-scroll-after-fingers-lift-or-cancel",scrollCount=after["scrollCount"])
        back(True);before=events();inject(dy=-300);time.sleep(.4);after=events()
        assert before["scrollCount"] == after["scrollCount"];no_leak(before,after)
        assert v.tablet()["barVisible"];record("visible-control-bar-blocks-scroll-and-click")
        back(False)
        v.home();paused=v.wait_host(lambda d:d["state"] == "paused")
        v.wait_tablet(lambda d:not d["foreground"] and d["state"] == "paused")
        assert paused["displayID"] == display_id and not paused["pointer"]["held"]
        v.check_baseline(baseline,True)
        v.launch();resumed=v.wait_host(lambda d:d["state"] == "streaming" and d["epoch"] != epoch)
        v.wait_tablet(lambda d:d["fullscreen"] and d["epoch"] == resumed["epoch"])
        if v.tablet()["barVisible"]:back(False)
        scroll("home-resume-same-display-new-epoch-scroll-works",300)
        record("retained-display-and-physical-layout-preserved",sameDisplay=resumed["displayID"] == display_id,oldEpoch=epoch,newEpoch=resumed["epoch"])
        assert resumed["displayID"] == display_id
        # Lenovo can reserve three-finger input for a system screenshot overlay,
        # pausing Tab-D. Test cancellation last, then explicitly restore our app.
        before=events();inject("third",0,-200,450);after=settled()
        assert before["scrollCount"] == after["scrollCount"];no_leak(before,after)
        record("third-finger-cancels-without-click",systemPaused=v.host()["state"] == "paused")
        end_session();wait(lambda:len(v.inventory()) == len(baseline));v.check_baseline(baseline,False)
        record("explicit-disconnect-removes-only-tabd-display")
        report["result"]="PASS"
    except Exception as error:
        report["result"]="FAIL";report["failure"]=str(error)
        for key,fn in [("hostOnFailure",v.host),("tabletOnFailure",v.tablet),("fixtureOnFailure",events)]:
            try: report[key]=fn()
            except Exception: pass
        raise
    finally:
        try: end_session()
        except Exception as error:report["cleanupError"]=str(error)
        if witness and witness.poll() is None:
            witness.terminate()
            try:witness.wait(timeout=5)
            except subprocess.TimeoutExpired:witness.kill();witness.wait(timeout=3)
        report["finishedAt"]=datetime.now(timezone.utc).isoformat();save()


if __name__ == "__main__":main()
