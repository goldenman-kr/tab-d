#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/module-cache
xcrun clang -fobjc-arc -fmodules -fmodules-cache-path="$PWD/build/module-cache" \
  -Wall -Wextra -Werror -framework Foundation -framework AppKit -framework CoreGraphics \
  mac/Display/VirtualDisplayBridge.m mac/Tests/DisplayProbe.m -o build/display-probe
