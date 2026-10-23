#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/module-cache build/Tab-D.app/Contents/MacOS build/Tab-D.app/Contents/Resources
xcrun swift -module-cache-path "$PWD/build/module-cache" scripts/generate-mac-icon.swift \
 android/app/src/main/res/drawable/tabd_icon.xml build/TabD.iconset
xcrun iconutil -c icns build/TabD.iconset -o build/Tab-D.app/Contents/Resources/TabD.icns
xcrun clang -fobjc-arc -fmodules -fmodules-cache-path="$PWD/build/module-cache" \
 -Wall -Wextra -Werror -mmacosx-version-min=14.0 -c mac/Display/VirtualDisplayBridge.m -o build/VirtualDisplayBridge.o
xcrun clang -fobjc-arc -Wall -Wextra -Werror -mmacosx-version-min=14.0 \
 -framework Foundation -framework CoreGraphics mac/Display/DisplayInspector.m \
 -o build/Tab-D.app/Contents/MacOS/TabDDisplayInspector
xcrun swiftc -swift-version 5 -target arm64-apple-macosx14.0 \
 -module-cache-path "$PWD/build/module-cache" -import-objc-header mac/Display/VirtualDisplayBridge.h \
 -framework AppKit -framework SwiftUI -framework ScreenCaptureKit -framework VideoToolbox \
 -framework Network -framework Security -framework CoreGraphics \
 mac/TabDApp.swift mac/AppModel.swift mac/Session/*.swift mac/Video/*.swift \
 mac/Transport/*.swift mac/Input/*.swift build/VirtualDisplayBridge.o -o build/Tab-D.app/Contents/MacOS/Tab-D
python3 - <<'PY'
from pathlib import Path
import plistlib
root=Path.cwd()
info={'CFBundleExecutable':'Tab-D','CFBundleIdentifier':'xyz.kryp.app.tabd',
 'CFBundleName':'Tab-D','CFBundleDisplayName':'Tab-D','CFBundlePackageType':'APPL',
 'CFBundleShortVersionString':'0.6.1','CFBundleVersion':'8','CFBundleIconFile':'TabD.icns','LSMinimumSystemVersion':'14.0',
 'LSUIElement':True,'NSHighResolutionCapable':True,
 'NSLocalNetworkUsageDescription':'태블릿에 Mac 확장 화면을 보내기 위해 로컬 네트워크를 사용합니다.',
 'NSBonjourServices':['_tabd._tcp'],
 'NSScreenCaptureUsageDescription':'Tab-D 가상 화면을 태블릿에 표시하기 위해 화면 기록 권한이 필요합니다.',
 'TabDDevelopmentStateDirectory':str(root/'build/private')}
with (root/'build/Tab-D.app/Contents/Info.plist').open('wb') as f: plistlib.dump(info,f)
PY
python3 scripts/sign-mac.py
