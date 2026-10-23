#!/bin/bash
# Pure session/protocol checks; --hardware also probes the local VideoToolbox encoder.
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/test-session.sh
xcrun swiftc -swift-version 5 -warnings-as-errors -module-cache-path "$PWD/build/module-cache" \
 -framework CoreGraphics mac/Session/SessionMachine.swift mac/Input/*.swift mac/Tests/PointerInputTests.swift -o build/pointer-input-tests
build/pointer-input-tests
xcrun swiftc -swift-version 5 -module-cache-path "$PWD/build/module-cache" \
 -framework Network -framework Security \
 mac/Transport/HostServer.swift mac/Tests/HostTransportTests.swift -o build/host-transport-tests
build/host-transport-tests --identity
xcrun swiftc -swift-version 5 -D TABD_VIDEO_TESTING \
 -module-cache-path "$PWD/build/module-cache" \
 -framework AppKit -framework ScreenCaptureKit -framework VideoToolbox \
 mac/Video/*.swift mac/Tests/VideoPacketTests.swift -o build/video-packet-tests
build/video-packet-tests "$@"
