#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/module-cache
xcrun swiftc -swift-version 5 -module-cache-path "$PWD/build/module-cache" \
 mac/Session/SessionMachine.swift mac/Tests/SessionMachineTests.swift -o build/session-tests
./build/session-tests
xcrun swiftc -swift-version 5 -warnings-as-errors -module-cache-path "$PWD/build/module-cache" \
 mac/Session/WakeRecovery.swift mac/Tests/WakeRecoveryTests.swift -o build/wake-recovery-tests
./build/wake-recovery-tests
xcrun swiftc -swift-version 5 -warnings-as-errors -module-cache-path "$PWD/build/module-cache" \
 -framework AppKit -framework CoreGraphics mac/Session/WakeRecovery.swift mac/Session/HostEnvironment.swift \
 mac/Tests/HostEnvironmentTests.swift -o build/host-environment-tests
./build/host-environment-tests
