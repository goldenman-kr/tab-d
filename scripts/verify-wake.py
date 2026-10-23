#!/usr/bin/env python3
"""Opt-in physical display-sleep checks; never unlocks or changes power settings.

Run after installing 0.6.0 on both devices, with the desired route already paired.
Uses pmset displaysleepnow and a short user-activity assertion to wake the screen.
If macOS requires a password, the user must unlock normally within --unlock-timeout.
Full system sleep and physical monitor power are separate manual checks.
"""
import argparse
from datetime import datetime, timezone
import importlib.util
import json
from pathlib import Path
import subprocess
import time

from device import ROOT

spec = importlib.util.spec_from_file_location("verify_device", Path(__file__).with_name("verify-device.py"))
v = importlib.util.module_from_spec(spec)
spec.loader.exec_module(v)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--route", choices=["USB", "무선"], default="USB")
    parser.add_argument("--unlock-timeout", type=int, default=180)
    args = parser.parse_args()
    output = ROOT / "docs/validation" / ("wake-usb.json" if args.route == "USB" else "wake-lan.json")
    report = {"route": args.route, "startedAt": datetime.now(timezone.utc).isoformat(), "checks": []}
    witness = None
    awake = None
    baseline = None

    def save():
        output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")

    def record(name, **values):
        report["checks"].append({"check": name, "result": "PASS", **values})
        save()
        print("PASS:", name, flush=True)

    def sleep_and_wake(expected_id, intent):
        previous = v.host()
        # Keep the CPU awake for this screen-only test; do not change pmset settings.
        nonlocal awake
        awake = subprocess.Popen(["/usr/bin/caffeinate", "-i", "-t", str(args.unlock_timeout + 20)])
        subprocess.run(["/usr/bin/pmset", "displaysleepnow"], check=True)
        sleeping = v.wait_host(lambda x: bool(x.get("wake", {}).get("blockers")), timeout=8)
        assert sleeping["displayID"] == expected_id, "Sleep removed the retained display"
        assert sleeping["wake"]["intent"] == intent
        assert not sleeping["pointer"]["held"], "Sleep left a Mac mouse button held"
        started_sleep=time.monotonic()
        early_wake=False
        while time.monotonic()-started_sleep < 3.5:
            held=v.host()
            if not held.get("wake",{}).get("blockers"):
                # Human keyboard/mouse input is a legitimate wake. Assert frame
                # quiescence only while the host is actually suspended.
                early_wake=True
                break
            assert held["framesSent"] == sleeping["framesSent"], "Capture continued while suspended"
            time.sleep(.1)
        suspension_sample_seconds=round(time.monotonic()-started_sleep,3)
        held = v.host()
        assert held["displayID"] == expected_id
        if held.get("wake",{}).get("blockers"):
            assert held["framesSent"] == sleeping["framesSent"], "Capture continued while suspended"
        subprocess.run(["/usr/bin/caffeinate", "-u", "-t", "2"], check=True)
        if "screenLocked" in v.host()["wake"]["blockers"]:
            print("WAITING_FOR_NORMAL_MAC_UNLOCK", flush=True)
        recovered = v.wait_host(lambda x: not x.get("wake", {}).get("blockers") and
                                (x["state"] == "streaming" if intent == "streaming" else not x["wake"]["pending"]),
                                timeout=args.unlock_timeout)
        awake.terminate(); awake.wait(timeout=5); awake = None
        assert recovered["displayID"] == expected_id
        if intent == "streaming":
            assert recovered["epoch"] > previous["epoch"]
            assert recovered["transport"]["acceptedPeers"] > previous["transport"]["acceptedPeers"]
            fresh = v.wait_tablet(lambda x:x["fullscreen"] and x["state"] == "streaming" and x["epoch"] == recovered["epoch"] and x["framesCurrentEpoch"] > 0)
            assert fresh["route"] == args.route
        return {"displayID":expected_id,"beforeEpoch":previous["epoch"],"afterEpoch":recovered["epoch"],
                "earlyUserWake":early_wake,"sampledSuspensionSeconds":suspension_sample_seconds,
                "blockersObserved":sleeping["wake"]["blockers"],"framesHeld":held["framesSent"],
                "acceptedPeersBefore":previous["transport"]["acceptedPeers"],
                "acceptedPeersAfter":recovered["transport"]["acceptedPeers"]}

    try:
        baseline = v.inventory()
        assert not any(x["vendor"] == 0x5444 for x in baseline), "End the current Tab-D session first"
        v.launch(); v.wait_host(lambda x:x["peerConnected"])
        v.wait_tablet(lambda x:x["authenticated"] and x["foreground"])
        v.tap_text("화면 연결")
        started = v.wait_host(lambda x:x["state"] == "streaming")
        assert started["route"] == args.route and started["selectedMode"] == 0
        display_id = started["displayID"]
        fixture = ROOT / "build/private/wake-window.json"
        fixture.unlink(missing_ok=True)
        witness = subprocess.Popen([str(ROOT/"build/window-witness"), str(display_id), str(fixture)],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline=time.monotonic()+6
        while not fixture.exists() and time.monotonic()<deadline: time.sleep(.1)
        time.sleep(2.5)
        frame=json.loads(fixture.read_text())["frame"]
        for cycle in range(2):
            values=sleep_and_wake(display_id,"streaming")
            v.check_baseline(baseline,True)
            assert json.loads(fixture.read_text())["frame"] == frame, "Owned window moved during wake"
            record("screen-sleep-automatic-stream-recovery",cycle=cycle+1,windowFrame=frame,**values)
        v.home(); v.wait_host(lambda x:x["state"] == "paused")
        v.wait_tablet(lambda x:not x["foreground"])
        values=sleep_and_wake(display_id,"paused")
        time.sleep(3)
        assert v.host()["state"] == "paused" and v.host()["displayID"] == display_id
        record("background-tablet-remains-paused-through-wake",**values)
        v.launch()
        restored=v.wait_host(lambda x:x["state"] == "streaming")
        assert restored["displayID"] == display_id
        v.wait_tablet(lambda x:x["fullscreen"])
        record("return-after-paused-wake-reuses-display",displayID=display_id,epoch=restored["epoch"])
        v.adb("shell","input","keyevent","KEYCODE_BACK")
        v.wait_tablet(lambda x:x["barVisible"])
        v.tap_text("⋯"); v.tap_text("연결 종료")
        v.wait_host(lambda x:x["displayID"] == 0 and not x.get("wake",{}).get("pending"))
        witness.terminate(); witness.wait(timeout=5); witness=None
        values=sleep_and_wake(0,"none")
        time.sleep(3)
        assert v.host()["displayID"] == 0 and v.host()["wake"]["intent"] == "none"
        v.check_baseline(baseline,False)
        record("explicit-stop-is-not-resurrected-by-wake",**values)
        report["result"]="PASS"
    except Exception as error:
        report["result"]="FAIL"; report["failure"]=str(error)
        report["hostOnFailure"]=v.host()
        try: report["tabletOnFailure"]=v.tablet()
        except Exception: pass
        raise
    finally:
        if witness: witness.terminate(); witness.wait(timeout=5)
        if awake: awake.terminate(); awake.wait(timeout=5)
        report["finishedAt"]=datetime.now(timezone.utc).isoformat(); save()


if __name__ == "__main__":
    main()
