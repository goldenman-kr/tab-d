#!/usr/bin/env python3
"""Opt-in real-device gesture checks using only Tab-D and its owned Mac fixture.

Default: Mac 0.3.0 build 4 / Android 0.3.0 code 3. --double-click: 0.4.0 builds 5/4; --scroll: 0.5.0 builds 6/5;
--wake: Mac 0.6.0 build 7 / Android 0.6.0 code 6, with wake-prefixed reports. Requires pairing,
Accessibility consent, and no active Tab-D display. It does not request permissions.
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

from device import ADB, PACKAGE, ROOT

spec = importlib.util.spec_from_file_location("verify_touch", Path(__file__).with_name("verify-touch.py"))
touch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(touch)
v, wait, surface_bounds = touch.v, touch.wait, touch.surface_bounds

COUNTERS = ("downCount", "upCount", "rightDownCount", "rightUpCount", "draggedCount")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--route", choices=["USB", "무선"], default="USB")
    parser.add_argument("--double-click", action="store_true", help="Test 0.4.0 double taps plus gesture regressions")
    parser.add_argument("--scroll", action="store_true", help="Test existing gestures on 0.5.0 without replacing historical reports")
    parser.add_argument("--wake", action="store_true", help="Test gesture regressions on 0.6.0 builds 7/6 with wake-prefixed reports")
    args = parser.parse_args()
    prefix = "wake-gestures" if args.wake else "scroll-regression" if args.scroll else "doubleclick" if args.double_click else "gestures"
    double_click = args.double_click or args.scroll or args.wake
    output = ROOT / "docs/validation" / (prefix + ("-usb.json" if args.route == "USB" else "-lan.json"))
    fixture_path = ROOT / "build/private/gesture-witness.json"
    report = {"route": args.route, "startedAt": datetime.now(timezone.utc).isoformat(), "checks": []}
    witness = None
    injection = None
    finger = None
    baseline = None
    owns_session = False
    completed = False

    def save():
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")

    def record(name, **values):
        report["checks"].append({"check": name, "result": "PASS", **values})
        save()
        print("PASS:", name, flush=True)

    def events():
        return json.loads(fixture_path.read_text())

    def counts():
        value = events()
        return {key: value[key] for key in COUNTERS}

    def details(value):
        keys = (*COUNTERS, "leftButtonHeld", "rightButtonHeld", "lastEventType", "lastDown", "lastUp",
                "lastRightDown", "lastRightUp", "lastDragged", "currentCGDisplayBounds")
        return {key: value.get(key) for key in keys}

    def position(x, y):
        x0, y0, x1, y1 = bounds
        px, py = int(x0 + (x1 - x0) * x), int(y0 + (y1 - y0) * y)
        return (px, py), ((px - x0) / (x1 - x0), (py - y0) / (y1 - y0))

    def coordinate(event, expected, button, click_count=1):
        assert all(abs(actual - target) < .003 for actual, target in zip(event["localNormalized"], expected)), (event, expected)
        assert event["buttonNumber"] == button and event["clickCount"] == click_count, event
        cg = event["globalCGLocation"]
        display = events()["currentCGDisplayBounds"]
        target = [display[0] + expected[0] * (display[2] - 1), display[1] + expected[1] * (display[3] - 1)]
        assert all(abs(actual - wanted) < 4 for actual, wanted in zip(cg, target)), (cg, target)

    def result_counts(before, left=0, right=0, drag=False):
        expected = dict(before)
        expected["downCount"] += left
        expected["upCount"] += left
        expected["rightDownCount"] += right
        expected["rightUpCount"] += right
        def matches():
            value = events()
            if any(value[key] != expected[key] for key in COUNTERS if key != "draggedCount"):
                return False
            if drag and value["draggedCount"] <= before["draggedCount"]:
                return False
            if not drag and value["draggedCount"] != before["draggedCount"]:
                return False
            return value if not value["leftButtonHeld"] and not value["rightButtonHeld"] else False
        result = wait(matches)
        time.sleep(.3)
        assert counts() == {key: result[key] for key in COUNTERS}, "Unexpected delayed extra mouse events"
        assert not v.host()["pointer"]["held"], "Host still owns a held button"
        return result

    def motion(action, point):
        nonlocal finger
        if action == "DOWN":
            finger = point  # An unsuccessful command can still have injected DOWN.
        v.adb("shell", "input", "touchscreen", "motionevent", action, *map(str, point))
        if action == "UP":
            finger = None
        else:
            finger = point

    def release_finger():
        nonlocal finger
        if finger is not None:
            point = finger
            v.adb("shell", "input", "touchscreen", "motionevent", "UP", *map(str, point), check=False)
            finger = None

    def inject_gesture(action, start, end=None, duration=None):
        nonlocal finger
        finger = start
        command = ["shell", "input", "touchscreen", action, *map(str, start)]
        if end is not None:
            command.extend(map(str, end))
        if duration is not None:
            command.append(str(duration))
        v.adb(*command)
        finger = None

    def held_drag():
        before = counts()
        start, start_normalized = position(.25, .35)
        end, end_normalized = position(.65, .65)
        motion("DOWN", start)
        motion("MOVE", end)
        held = v.wait_host(lambda value: value["pointer"]["held"], timeout=2)
        received = wait(lambda: events() if events()["leftButtonHeld"] else False, timeout=2)
        assert received["downCount"] == before["downCount"] + 1 and received["upCount"] == before["upCount"]
        assert received["rightDownCount"] == before["rightDownCount"]
        coordinate(received["lastDown"], start_normalized, 0)
        return before, held, start_normalized, end_normalized

    def back(show):
        v.adb("shell", "input", "keyevent", "KEYCODE_BACK")
        return v.wait_tablet(lambda value: value["fullscreen"] and value["barVisible"] == show)

    def ensure_hidden():
        if v.tablet()["barVisible"]:
            back(False)
        v.wait_tablet(lambda value: value["fullscreen"] and not value["barVisible"] and value.get("systemBarsVisible") is False)

    try:
        info = plistlib.loads(Path("/Applications/Tab-D.app/Contents/Info.plist").read_bytes())
        package = v.adb("shell", "dumpsys", "package", PACKAGE).stdout.decode()
        versions = {"mac": info["CFBundleShortVersionString"], "macBuild": str(info["CFBundleVersion"]),
                    "android": re.search(r"versionName=([^\s]+)", package).group(1),
                    "androidBuild": int(re.search(r"versionCode=(\d+)", package).group(1))}
        report["versions"] = versions
        expected_versions = {"mac":"0.4.0","macBuild":"5","android":"0.4.0","androidBuild":4} if args.double_click else {"mac":"0.3.0","macBuild":"4","android":"0.3.0","androidBuild":3}
        if args.scroll:
            expected_versions = {"mac":"0.5.0","macBuild":"6","android":"0.5.0","androidBuild":5}
        if args.wake:
            expected_versions = {"mac":"0.6.0","macBuild":"7","android":"0.6.0","androidBuild":6}
        assert versions == expected_versions, versions
        baseline = v.inventory()
        assert not any(value["vendor"] == 0x5444 for value in baseline), "End existing Tab-D display first"
        assert v.host()["inputPermission"], "Allow Tab-D in macOS Accessibility before running this test"
        v.launch()
        v.wait_host(lambda value: value["peerConnected"])
        owns_session = True
        v.tap_text("화면 연결")
        host = v.wait_host(lambda value: value["state"] == "streaming")
        display_id, epoch = host["displayID"], host["epoch"]
        tablet = v.wait_tablet(lambda value: value["fullscreen"] and value["epoch"] == epoch)
        assert host["route"] == tablet["route"] == args.route
        ensure_hidden()
        fixture_path.unlink(missing_ok=True)
        witness = subprocess.Popen([str(ROOT / "build/click-witness"), str(display_id), str(fixture_path)],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        wait(lambda: fixture_path.exists() and events()["ready"])
        time.sleep(1)
        bounds = surface_bounds()
        report["surfaceBounds"] = bounds
        report["displayMode"] = host["mode"]

        before = counts()
        point, target = position(.25, .25)
        inject_gesture("tap", point)
        result = result_counts(before, left=1)
        coordinate(result["lastDown"], target, 0)
        coordinate(result["lastUp"], target, 0)
        record("short-tap-left-click", before=before, target=target, received=details(result))

        if double_click:
            def click_series(label, points, gap, expected_counts):
                # Each input command emits only one physical DOWN/UP pair.
                time.sleep(.45)
                before=counts()
                targets=[position(*point) for point in points]
                commands=[]
                for index,(pixel,_) in enumerate(targets):
                    if index: commands.append("sleep " + str(gap))
                    commands.append("input touchscreen tap %d %d" % pixel)
                v.adb("shell", "; ".join(commands))
                result=result_counts(before,left=len(points))
                received=[event for event in events()["recentEvents"] if event["type"] in ("leftMouseDown","leftMouseUp")][-2*len(points):]
                assert [event["clickCount"] for event in received] == [count for count in expected_counts for _ in range(2)], received
                for index,(_,target) in enumerate(targets):
                    coordinate(received[index*2],target,0,expected_counts[index])
                    coordinate(received[index*2+1],target,0,expected_counts[index])
                android=v.wait_tablet(lambda value:value.get("lastClick",{}).get("status")=="accepted")
                assert android["lastClick"]["clickCount"] == expected_counts[-1]
                assert android["fullscreen"] and not android["barVisible"]
                record(label,before=before,requestedGapSeconds=gap,received=received,android=android["lastClick"])
            click_series("two-quick-taps-deliver-one-double-click",[(.4,.3),(.4,.3)],.04,[1,2])
            x0,y0,x1,y1=bounds
            click_series("nearby-taps-allow-finger-jitter",[(.4,.3),(.4+8/(x1-x0),.3+8/(y1-y0))],.04,[1,2])
            click_series("slow-taps-remain-two-single-clicks",[(.4,.3),(.4,.3)],.45,[1,1])
            click_series("distant-taps-remain-two-single-clicks",[(.25,.25),(.75,.75)],.04,[1,1])
            click_series("third-tap-starts-new-single-click",[(.4,.3),(.4,.3),(.4,.3)],.04,[1,2,1])

        for duration in (700, 1500):
            before = counts()
            point, target = position(.7, .3)
            inject_gesture("swipe", point, point, duration)
            result = result_counts(before, right=1)
            coordinate(result["lastRightDown"], target, 1)
            coordinate(result["lastRightUp"], target, 1)
            record("stationary-long-press-one-right-click", durationMillis=duration, before=before,
                   target=target, received=details(result))

        for duration in (350, 3000):
            before = counts()
            start, start_target = position(.2, .45)
            end, end_target = position(.8, .7)
            command = [ADB, "-d", "shell", "input", "touchscreen", "swipe", *map(str, (*start, *end)), str(duration)]
            finger = start
            injection = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            samples = []
            started = time.monotonic()
            if duration == 3000:
                v.wait_host(lambda value: value["pointer"]["held"], timeout=2)
                wait(lambda: events()["leftButtonHeld"], timeout=2)
                while injection.poll() is None and time.monotonic() - started < 2.5:
                    state = v.host()
                    sample = {"elapsed": round(time.monotonic() - started, 3), "held": state["pointer"]["held"],
                              "lastReleaseReason": state["pointer"]["lastReleaseReason"]}
                    samples.append(sample)
                    assert sample["held"], "Drag released before the moving finger lifted"
                    time.sleep(.15)
                assert any(value["elapsed"] > 2 and value["held"] for value in samples), "No held sample beyond idle timeout"
            injection.communicate(timeout=8)
            assert injection.returncode == 0, "Android swipe injection failed"
            injection = None
            finger = None
            result = result_counts(before, left=1, drag=True)
            coordinate(result["lastDown"], start_target, 0)
            coordinate(result["lastUp"], end_target, 0)
            record("moving-drag-down-move-up", durationMillis=duration, before=before,
                   start=start_target, end=end_target, heldSamples=samples, received=details(result))

        before = counts()
        x0, y0, x1, y1 = bounds
        v.adb("shell", "input", "swipe", "1", str((y0+y1)//2), "450", str((y0+y1)//2), "400")
        v.wait_tablet(lambda value: value["fullscreen"] and value["barVisible"])
        assert counts() == before and v.host()["epoch"] == epoch
        record("first-edge-back-opens-bar-without-mac-input", counts=before)
        back(False)
        ensure_hidden()
        before = counts()
        back(True)
        time.sleep(.3)
        assert counts() == before and v.host()["epoch"] == epoch and v.host()["state"] == "streaming"
        record("back-opens-control-bar-without-input", counts=before, epoch=epoch)
        point, _ = position(.25, .25)
        inject_gesture("tap", point)
        ensure_hidden()
        time.sleep(.3)
        assert counts() == before
        record("surface-tap-dismisses-bar-only", counts=counts())

        before, held, start_target, end_target = held_drag()
        # Moving then holding must retain a left drag, without converting to right click.
        time.sleep(2.7)
        stationary = v.wait_host(lambda value: value["pointer"]["held"])
        assert stationary["pointer"]["sequence"] > held["pointer"]["sequence"] + 2
        assert events()["leftButtonHeld"] and events()["rightDownCount"] == before["rightDownCount"]
        record("stationary-drag-keepalive-past-two-seconds", pointer=stationary["pointer"], received=details(events()))
        cancellation_started = time.monotonic()
        v.home()
        released = v.wait_host(lambda value: not value["pointer"]["held"] and value["state"] == "paused", timeout=4)
        result = result_counts(before, left=1, drag=True)
        release_finger()
        assert released["displayID"] == display_id
        coordinate(result["lastUp"], end_target, 0)
        v.check_baseline(baseline, True)
        record("home-cancels-held-drag-and-retains-display", before=before, oldEpoch=epoch,
               elapsed=round(time.monotonic() - cancellation_started, 3), pointer=released["pointer"], received=details(result))
        v.launch()
        resumed = v.wait_host(lambda value: value["state"] == "streaming" and value["epoch"] > epoch)
        assert resumed["displayID"] == display_id
        v.wait_tablet(lambda value: value["fullscreen"] and value["epoch"] == resumed["epoch"])
        ensure_hidden()
        bounds = surface_bounds()
        before = counts()
        start, start_target = position(.25, .35)
        end, end_target = position(.65, .65)
        inject_gesture("swipe", start, end, 350)
        result = result_counts(before, left=1, drag=True)
        coordinate(result["lastDown"], start_target, 0)
        coordinate(result["lastUp"], end_target, 0)
        record("resume-new-epoch-drag-works", oldEpoch=epoch, newEpoch=resumed["epoch"], before=before, received=details(result))

        before, held, _, end_target = held_drag()
        current_epoch=v.host()["epoch"]
        back(True)
        released=v.wait_host(lambda value:not value["pointer"]["held"])
        result=result_counts(before,left=1,drag=True)
        release_finger()
        assert released["state"] == "streaming" and released["epoch"] == current_epoch
        coordinate(result["lastUp"],end_target,0)
        record("back-menu-cancels-held-drag-without-pause", pointer=released["pointer"],received=details(result))
        ensure_hidden()

        before, held, _, end_target = held_drag()
        stopped_at = time.monotonic()
        v.adb("shell", "am", "force-stop", PACKAGE)
        released = v.wait_host(lambda value: not value["pointer"]["held"], timeout=2.5)
        release_elapsed = time.monotonic() - stopped_at
        result = result_counts(before, left=1, drag=True)
        assert release_elapsed < 2.5, "Peer loss did not release the held button promptly"
        coordinate(result["lastUp"], end_target, 0)
        release_finger()
        recovering = v.wait_host(lambda value: not value["peerConnected"], timeout=2)
        assert recovering["state"] == "recovering" and recovering["displayID"] == display_id, "No active-loss recovery grace"
        record("force-stop-cancels-held-drag", before=before, releaseSeconds=round(release_elapsed, 3),
               pointer=released["pointer"], recoveryState=recovering["state"], received=details(result))
        v.wait_host(lambda value: value["displayID"] == 0, timeout=8)
        wait(lambda: len(v.inventory()) == len(baseline))
        v.check_baseline(baseline, False)
        removed_elapsed = time.monotonic() - stopped_at
        assert removed_elapsed >= 2.5, "Display disappeared before the recovery grace elapsed"
        record("active-peer-loss-removes-display-after-recovery", removedSeconds=round(removed_elapsed, 3))
        v.launch()
        v.wait_host(lambda value: value["peerConnected"] and value["displayID"] == 0)
        v.wait_tablet(lambda value: not value["fullscreen"] and not value["retained"])
        time.sleep(1)
        assert v.host()["displayID"] == 0
        v.check_baseline(baseline, False)
        record("ready-after-relaunch-no-resurrection", displayID=0)
        completed = True
        report["result"] = "PASS"
    except Exception as error:
        report["result"] = "FAIL"
        report["failure"] = str(error)
        for key, read in (("hostOnFailure", v.host), ("tabletOnFailure", v.tablet), ("fixtureOnFailure", events)):
            try:
                report[key] = read()
            except Exception:
                pass
        raise
    finally:
        cleanup_errors = []
        if injection and injection.poll() is None:
            injection.terminate()
            try:
                injection.wait(timeout=3)
            except subprocess.TimeoutExpired:
                injection.kill()
                injection.wait(timeout=3)
        try:
            release_finger()
        except Exception:
            cleanup_errors.append("Cannot lift injected finger")
        if owns_session and not completed:
            try:
                v.launch()
                v.wait_host(lambda value: value["peerConnected"])
                if v.host()["displayID"] != 0:
                    v.wait_tablet(lambda value: value["fullscreen"])
                    if not v.tablet()["barVisible"]:
                        back(True)
                    v.tap_text("⋯")
                    v.tap_text("연결 종료")
                    v.wait_host(lambda value: value["displayID"] == 0)
                wait(lambda: len(v.inventory()) == len(baseline))
                v.check_baseline(baseline, False)
                v.launch()
                v.wait_tablet(lambda value: not value["fullscreen"] and not value["retained"])
            except Exception:
                cleanup_errors.append("Cannot confirm session cleanup; check Mac Tab-D menu")
        if witness and witness.poll() is None:
            witness.terminate()
            try:
                witness.wait(timeout=5)
            except subprocess.TimeoutExpired:
                witness.kill()
                witness.wait(timeout=3)
        report["cleanupErrors"] = cleanup_errors
        report["finishedAt"] = datetime.now(timezone.utc).isoformat()
        save()


if __name__ == "__main__":
    main()
