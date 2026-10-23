#!/usr/bin/env python3
"""Development fault injection: authenticated peer never acknowledges decoder readiness.
End any existing session and stop the Android app before running this check.
Pairing secrets stay in memory and are never written to the report.
"""
import hashlib
import importlib.util
import json
from pathlib import Path
import socket
import ssl
import struct
import time
from device import ROOT

spec = importlib.util.spec_from_file_location("verify_device", Path(__file__).with_name("verify-device.py"))
v = importlib.util.module_from_spec(spec)
spec.loader.exec_module(v)
baseline = v.inventory()
assert not any(x["vendor"] == 0x5444 for x in baseline), "End current display first"
v.wait_host(lambda x:not x["peerConnected"])
pairing = json.loads((ROOT / "build/private/pairing.json").read_text())
context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
context.check_hostname = False
context.verify_mode = ssl.CERT_NONE  # The exact private certificate is pinned below.
context.minimum_version = ssl.TLSVersion.TLSv1_2
report = {"test":"missing-decoder-ready", "result":"FAIL"}
output = ROOT / "docs/validation/decoder-readiness-timeout.json"
try:
    with socket.create_connection(("127.0.0.1",49832), timeout=3) as raw:
        with context.wrap_socket(raw, server_hostname="Tab-D") as peer:
            assert hashlib.sha256(peer.getpeercert(binary_form=True)).hexdigest() == pairing["pin"]
            def send(value):
                payload = b"\x01" + json.dumps(value).encode()
                peer.sendall(struct.pack(">I",len(payload)) + payload)
            send({"type":"hello","version":1,"token":pairing["token"],"visible":True,"device":"Tab-D readiness check"})
            v.wait_host(lambda x:x["peerConnected"])
            send({"type":"start"})
            started = time.monotonic()
            peer.settimeout(.2)
            buffer = bytearray()
            configuration_seen = False
            while time.monotonic()-started < 18:
                try:
                    chunk = peer.recv(65536)
                    if not chunk: break
                    buffer.extend(chunk)
                except socket.timeout:
                    pass
                while len(buffer) >= 4:
                    size = struct.unpack(">I",buffer[:4])[0]
                    assert 1 <= size <= 8*1024*1024
                    if len(buffer) < size+4: break
                    configuration_seen |= buffer[4] == 2
                    del buffer[:size+4]
                h = v.host()
                if h["state"] == "failed" and h["displayID"] == 0:
                    assert configuration_seen, "No decoder configuration was received"
                    v.check_baseline(baseline,False)
                    report.update(result="PASS",seconds=round(time.monotonic()-started,2),configurationReceived=True,displayRemoved=True)
                    print("PASS: missing decoderReady times out and removes the actual display.")
                    break
            assert report["result"] == "PASS", "Host did not clean up an unready decoder"
finally:
    output.write_text(json.dumps(report,ensure_ascii=False,indent=2)+"\n")
